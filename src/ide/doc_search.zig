//! Search the documentation: describe what you want in words ("path from dir")
//! and get the functions and types whose names, signatures and `///` doc
//! comments match, from the project and the Zig standard library; the last row
//! searches the web for the same words.
//!
//!     const ds = try DocSearch.create(&ui, ui.tree.root, quick_open, .{ .on_open = OpenHook.bind(&app, App.openAt),
//!                                                                         .on_web = WebHook.bind(&app, App.openWeb) });
//!     defer ds.destroy();
//!     ds.show();            // the command
//!     ds.poll();            // each loop iteration (re-ranks when an index finished)
//!
//! Ranking is by words, not meaning: every word of the query is looked for
//! (as a whole word, a start of one, or a plural) among the words of the name
//! (camelCase and snake_case are split: `getEnvMap` is get, env, map), of the
//! signature and of the doc comment; name hits count most. Small words ("from",
//! "the", "how") are ignored. A result must match at least one word and ranks
//! higher the more of them it covers. IDE-level code; `rank` and `webSearchUrl`
//! are UI-free.

const std = @import("std");
const Handle = @import("../core/handle.zig").Handle;
const Ui = @import("../core/ui.zig").Ui;
const quick_pick = @import("../widgets/quick_pick.zig");
const output_panel = @import("output_panel.zig");
const quick_open = @import("quick_open.zig");
const symbol_index = @import("symbol_index.zig");

pub const OpenHook = output_panel.OpenHook;

/// Called with the query when the web row is picked.
pub const WebHook = struct {
    ctx: ?*anyopaque = null,
    call: *const fn (ctx: ?*anyopaque, query: []const u8) void,

    pub fn bind(ctx: anytype, comptime f: anytype) WebHook {
        const Ptr = @TypeOf(ctx);
        return .{
            .ctx = @ptrCast(ctx),
            .call = &struct {
                fn thunk(c: ?*anyopaque, query: []const u8) void {
                    f(@as(Ptr, @ptrCast(@alignCast(c.?))), query);
                }
            }.thunk,
        };
    }
};

// ---- ranking (UI-free) -----------------------------------------------------

const stop_words = [_][]const u8{ "a", "an", "the", "of", "to", "in", "on", "for", "from", "how", "do", "does", "i", "get", "with", "and", "or", "is", "it", "my", "can", "use", "using", "by", "at", "as" };

fn isStop(w: []const u8) bool {
    for (stop_words) |s| {
        if (std.ascii.eqlIgnoreCase(s, w)) return true;
    }
    return false;
}

pub const max_query_words = 8;

/// The words of a query, lowercase, small words dropped (all kept when nothing else is left).
pub fn queryWords(query: []const u8, out: *[max_query_words][]const u8, store: *[256]u8) []const []const u8 {
    var n: usize = 0;
    var used: usize = 0;
    var it = std.mem.tokenizeAny(u8, query, " \t,.;:/\\()[]{}\"'?!-_");
    var kept_stop: [max_query_words][]const u8 = undefined;
    var stops: usize = 0;
    while (it.next()) |w| {
        // One or two letters match too much to rank anything while typing.
        if (w.len < 3) continue;
        if (used + w.len > store.len) break;
        const lower = store[used .. used + w.len];
        for (w, 0..) |c, i| lower[i] = std.ascii.toLower(c);
        used += w.len;
        if (isStop(lower)) {
            if (stops < max_query_words) {
                kept_stop[stops] = lower;
                stops += 1;
            }
            continue;
        }
        if (n < max_query_words) {
            out[n] = lower;
            n += 1;
        }
    }
    if (n == 0) {
        for (kept_stop[0..stops], 0..) |w, i| out[i] = w;
        return out[0..stops];
    }
    return out[0..n];
}

/// Splits a string into words at non-letters/digits and at lower-to-upper
/// (camelCase) and digit boundaries: "getEnvMap" -> get, Env, Map.
const WordIter = struct {
    s: []const u8,
    i: usize = 0,

    fn next(self: *WordIter) ?[]const u8 {
        while (self.i < self.s.len and !std.ascii.isAlphanumeric(self.s[self.i])) self.i += 1;
        if (self.i >= self.s.len) return null;
        const start = self.i;
        self.i += 1;
        while (self.i < self.s.len and std.ascii.isAlphanumeric(self.s[self.i])) : (self.i += 1) {
            const prev = self.s[self.i - 1];
            const c = self.s[self.i];
            if (std.ascii.isLower(prev) and std.ascii.isUpper(c)) break; // camelCase
            if (std.ascii.isUpper(prev) and std.ascii.isUpper(c) and self.i + 1 < self.s.len and std.ascii.isLower(self.s[self.i + 1])) break; // HTTPServer -> HTTP, Server
        }
        return self.s[start..self.i];
    }
};

/// How `w` (lowercase query word) matches word `x`: 2 whole word (or plural), 1 start of it, 0 no.
fn wordMatch(w: []const u8, x: []const u8) u8 {
    if (std.ascii.eqlIgnoreCase(w, x)) return 2;
    // A plural either way: dirs/dir, paths/path.
    if (w.len > 2 and w[w.len - 1] == 's' and std.ascii.eqlIgnoreCase(w[0 .. w.len - 1], x)) return 2;
    if (x.len > 2 and x[x.len - 1] == 's' and std.ascii.eqlIgnoreCase(w, x[0 .. x.len - 1])) return 2;
    if (w.len >= 3 and x.len > w.len and std.ascii.eqlIgnoreCase(w, x[0..w.len])) return 1;
    return 0;
}

const Weights = struct { whole: f32, prefix: f32 };

/// The best a query word does among the words of `text`.
fn bestIn(w: []const u8, text: []const u8, weights: Weights) f32 {
    var best: f32 = 0;
    var it: WordIter = .{ .s = text };
    while (it.next()) |x| {
        const m = wordMatch(w, x);
        if (m == 2) return weights.whole;
        if (m == 1) best = @max(best, weights.prefix);
    }
    return best;
}

/// A cheap test before `score`: does every (`all`) or any query word (minus a
/// plural s) occur in the symbol's text? Symbols without prepared text pass.
fn mightMatch(sym: symbol_index.Symbol, words: []const []const u8, all: bool) bool {
    if (sym.hay.len == 0) return true;
    for (words) |w| {
        const stem = if (w.len > 3 and w[w.len - 1] == 's') w[0 .. w.len - 1] else w;
        const found = std.mem.indexOf(u8, sym.hay, stem) != null;
        if (all and !found) return false;
        if (!all and found) return true;
    }
    return all;
}

fn wordCount(text: []const u8) f32 {
    var n: f32 = 0;
    var it: WordIter = .{ .s = text };
    while (it.next()) |_| n += 1;
    return @max(n, 1);
}

/// How well `sym` answers the query words: 0 means it does not.
pub fn score(sym: symbol_index.Symbol, words: []const []const u8) f32 {
    if (sym.kind == .file or words.len == 0) return 0;
    // A name made of many words says less about any one of them (`createDirPathOpen`).
    const name_norm = 1.0 / (1.0 + 0.15 * (wordCount(sym.name) - 1));
    var total: f32 = 0;
    var covered: f32 = 0;
    var in_doc: usize = 0;
    for (words) |w| {
        var s = name_norm * bestIn(w, sym.name, .{ .whole = 10, .prefix = 6 });
        // Doc words count by how often they occur, a little.
        const d = bestIn(w, sym.doc, .{ .whole = 4, .prefix = 2 });
        if (d > 0) in_doc += 1;
        s = @max(s, d);
        // The file's own words ("std/fs/path.zig" says something about `dirname`).
        s = @max(s, bestIn(w, sym.shown, .{ .whole = 3, .prefix = 1 }));
        if (s > 0) covered += 1;
        total += s;
    }
    if (covered == 0) return 0;
    // A doc comment that mentions every word is the best evidence there is: the author wrote about this.
    if (words.len > 1 and in_doc == words.len) total += 12;
    const frac = covered / @as(f32, @floatFromInt(words.len));
    // Covering every word matters more than any one strong hit.
    return total * frac * frac;
}

pub const Hit = struct { index: u32, list: u8, score: f32 };

fn hitBetter(_: void, a: Hit, b: Hit) bool {
    return a.score > b.score;
}

/// The best `out.len` matches among `lists` (project first, then the library),
/// best first. Returns how many were written. Symbols whose text holds every
/// query word are scored first; only when those are few are the ones holding
/// just some of the words scored too (that pass is the slow one).
pub fn rank(lists: []const []const symbol_index.Symbol, query: []const u8, out: []Hit) usize {
    var wbuf: [max_query_words][]const u8 = undefined;
    var store: [256]u8 = undefined;
    const words = queryWords(query, &wbuf, &store);
    if (words.len == 0 or out.len == 0) return 0;
    var n: usize = 0;
    const passes: usize = if (words.len > 1) 2 else 1;
    for (0..passes) |pass| {
        const all = words.len > 1 and pass == 0;
        for (lists, 0..) |list, li| {
            for (list, 0..) |s, i| {
                if (s.kind == .file) continue;
                if (!mightMatch(s, words, all)) continue;
                // The second pass only adds symbols the first did not take.
                if (pass == 1 and mightMatch(s, words, true)) continue;
                var sc = score(s, words);
                if (sc <= 0) continue;
                // Ties and near-ties: project before library, shorter names before longer.
                if (!s.in_std) sc += 0.5;
                sc -= @as(f32, @floatFromInt(@min(s.name.len, 60))) * 0.01;
                const hit: Hit = .{ .index = @intCast(i), .list = @intCast(li), .score = sc };
                if (n < out.len) {
                    out[n] = hit;
                    n += 1;
                    if (n == out.len) std.mem.sort(Hit, out[0..n], {}, hitBetter);
                } else if (sc > out[n - 1].score) {
                    var k = n - 1;
                    out[k] = hit;
                    while (k > 0 and out[k].score > out[k - 1].score) : (k -= 1) std.mem.swap(Hit, &out[k], &out[k - 1]);
                }
            }
        }
        if (n < out.len) std.mem.sort(Hit, out[0..n], {}, hitBetter);
        if (n >= out.len / 2) break;
    }
    return n;
}

/// `https://www.google.com/search?q=zig+<query>` with the query percent-encoded.
pub fn webSearchUrl(a: std.mem.Allocator, query: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(a);
    try out.appendSlice(a, "https://www.google.com/search?q=zig");
    var it = std.mem.tokenizeAny(u8, query, " \t\r\n");
    while (it.next()) |w| {
        try out.append(a, '+');
        for (w) |c| {
            if (std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.' or c == '~') {
                try out.append(a, c);
            } else {
                try out.print(a, "%{X:0>2}", .{c});
            }
        }
    }
    return out.toOwnedSlice(a);
}

// ---- the box ---------------------------------------------------------------

const max_results = 30;

pub const Options = struct {
    on_open: ?OpenHook = null,
    on_web: ?WebHook = null,
};

pub const DocSearch = struct {
    gpa: std.mem.Allocator,
    pick: *quick_pick.QuickPick,
    quick: *quick_open.QuickOpen,
    opts: Options,
    /// Rows shown for the current query; strings live in `arena`.
    arena: std.heap.ArenaAllocator,
    items: std.ArrayListUnmanaged(quick_pick.Item) = .empty,
    /// Per row: the symbol (copied, with its path) or null for the web row.
    rows: std.ArrayListUnmanaged(?symbol_index.Symbol) = .empty,
    query: std.ArrayListUnmanaged(u8) = .empty,
    seen_generation: u32 = 0,

    pub fn create(ui: *Ui, parent: Handle, quick: *quick_open.QuickOpen, opts: Options) !*DocSearch {
        const self = try ui.gpa.create(DocSearch);
        errdefer ui.gpa.destroy(self);
        const pick = try quick_pick.QuickPick.create(ui, parent);
        self.* = .{ .gpa = ui.gpa, .pick = pick, .quick = quick, .opts = opts, .arena = .init(ui.gpa) };
        return self;
    }

    pub fn destroy(self: *DocSearch) void {
        self.pick.destroy();
        self.items.deinit(self.gpa);
        self.rows.deinit(self.gpa);
        self.query.deinit(self.gpa);
        self.arena.deinit();
        self.gpa.destroy(self);
    }

    pub fn show(self: *DocSearch) void {
        self.quick.project_index.rescan();
        self.seen_generation = self.quick.generation;
        self.query.clearRetainingCapacity();
        self.pick.show(.{
            .placeholder = "Search documentation: describe what you want (e.g. path from dir)",
            .external = true,
            .on_query = .bind(self, onQuery),
            .on_pick = .bind(self, onPick),
        });
    }

    pub fn isOpen(self: *const DocSearch) bool {
        return self.pick.isOpen();
    }

    /// Call every loop iteration: an index that finished changes the answers.
    pub fn poll(self: *DocSearch) void {
        if (!self.pick.isOpen() or self.quick.generation == self.seen_generation) return;
        self.seen_generation = self.quick.generation;
        self.refresh();
    }

    fn onQuery(self: *DocSearch, query: []const u8) void {
        self.query.clearRetainingCapacity();
        self.query.appendSlice(self.gpa, query) catch {};
        self.refresh();
    }

    fn kindText(k: symbol_index.Kind) []const u8 {
        return switch (k) {
            .file => "file",
            .function => "fn",
            .type => "type",
            .constant => "const",
            .variable => "var",
        };
    }

    fn refresh(self: *DocSearch) void {
        _ = self.arena.reset(.retain_capacity);
        self.items.clearRetainingCapacity();
        self.rows.clearRetainingCapacity();
        const a = self.arena.allocator();
        const q = self.query.items;
        if (q.len > 0) {
            var hits: [max_results]Hit = undefined;
            const lists = self.quick.symbolLists();
            const n = rank(&lists, q, &hits);
            for (hits[0..n]) |h| {
                const s = lists[h.list][h.index];
                // What explains it best: the signature, else the doc line.
                const what: []const u8 = if (s.sig.len > 0) s.sig else s.doc;
                const detail = std.fmt.allocPrint(a, "{s}  {s}:{d}{s}{s}", .{
                    kindText(s.kind),
                    s.shown,
                    s.line,
                    if (what.len > 0) "  " else "",
                    what[0..@min(what.len, 110)],
                }) catch continue;
                const label = a.dupe(u8, s.name) catch continue;
                var copy = s;
                copy.name = label;
                copy.path = a.dupe(u8, s.path) catch continue;
                copy.doc = "";
                copy.sig = "";
                self.items.append(self.gpa, .{ .label = label, .detail = detail, .group = if (s.in_std) 1 else 0 }) catch break;
                self.rows.append(self.gpa, copy) catch {
                    _ = self.items.pop();
                    break;
                };
            }
            // The web row is always last.
            const label = std.fmt.allocPrint(a, "Search the web for \"{s}\"", .{q}) catch "Search the web";
            self.items.append(self.gpa, .{ .label = label, .detail = "opens google.com in your browser", .group = 2 }) catch {};
            self.rows.append(self.gpa, null) catch {
                _ = self.items.pop();
            };
        }
        self.pick.setItems(self.items.items);
        var buf: [96]u8 = undefined;
        self.pick.setStatus(if (q.len == 0)
            "type words describing what you are looking for"
        else
            std.fmt.bufPrint(&buf, "{d} matches in {d} names", .{ self.items.items.len -| 1, self.quick.items.items.len }) catch "");
    }

    fn onPick(self: *DocSearch, index: usize) void {
        if (index >= self.rows.items.len) return;
        if (self.rows.items[index]) |s| {
            const hook = self.opts.on_open orelse return;
            hook.call(hook.ctx, s.path, s.line, s.col);
        } else {
            const hook = self.opts.on_web orelse return;
            hook.call(hook.ctx, self.query.items);
        }
    }
};

// ---- tests -----------------------------------------------------------------

const testing = std.testing;

fn mk(name: []const u8, kind: symbol_index.Kind, sig: []const u8, doc: []const u8, in_std: bool) symbol_index.Symbol {
    return .{ .name = name, .kind = kind, .path = "p.zig", .shown = "p.zig", .line = 1, .col = 1, .in_std = in_std, .sig = sig, .doc = doc };
}

test "words are split at case changes, and small words are ignored" {
    var it: WordIter = .{ .s = "getEnvMap_fromHTTPServer2" };
    const want = [_][]const u8{ "get", "Env", "Map", "from", "HTTP", "Server2" };
    for (want) |w| try testing.expectEqualStrings(w, it.next().?);
    try testing.expect(it.next() == null);

    var wbuf: [max_query_words][]const u8 = undefined;
    var store: [256]u8 = undefined;
    const ws = queryWords("How to get the Path from Dir?", &wbuf, &store);
    try testing.expectEqual(@as(usize, 2), ws.len);
    try testing.expectEqualStrings("path", ws[0]);
    try testing.expectEqualStrings("dir", ws[1]);
    // Only small words: keep the ones long enough rather than search for nothing; one- and two-letter words are dropped.
    try testing.expectEqual(@as(usize, 1), queryWords("how to", &wbuf, &store).len);
    try testing.expectEqual(@as(usize, 0), queryWords("to a", &wbuf, &store).len);
}

test "\"path from dir\" finds the functions about a path and a directory first" {
    const syms = [_]symbol_index.Symbol{
        mk("fs.path.dirname", .function, "pub fn dirname(path: []const u8) ?[]const u8", "Returns the directory component of a path, or null when there is none.", true),
        mk("fs.Dir.realPath", .function, "pub fn realPath(self: Dir, out: []u8) !usize", "Obtains the absolute path of the directory.", true),
        mk("fs.path.basename", .function, "pub fn basename(path: []const u8) []const u8", "Returns the last component of a path.", true),
        mk("mem.eql", .function, "pub fn eql(a: []const u8, b: []const u8) bool", "Compares two slices.", true),
        mk("Dir", .type, "", "", true),
        mk("myPathFromDir", .function, "fn myPathFromDir() void", "", false),
    };
    const lists = [_][]const symbol_index.Symbol{&syms};
    var hits: [10]Hit = undefined;
    const n = rank(&lists, "path from dir", &hits);
    try testing.expect(n >= 3);
    // The three that cover both words (by name or by doc comment) are the top three.
    var found: [3]bool = .{ false, false, false };
    const wanted = [_][]const u8{ "myPathFromDir", "fs.path.dirname", "fs.Dir.realPath" };
    for (hits[0..3]) |h| {
        for (wanted, 0..) |w, k| {
            if (std.mem.eql(u8, syms[h.index].name, w)) found[k] = true;
        }
    }
    try testing.expect(found[0] and found[1] and found[2]);
    // mem.eql matches nothing and is absent.
    for (hits[0..n]) |h| try testing.expect(!std.mem.eql(u8, syms[h.index].name, "mem.eql"));
    // Covering both words beats covering one: basename has only "path".
    var seen_basename: ?usize = null;
    var seen_dirname: ?usize = null;
    for (hits[0..n], 0..) |h, i| {
        if (std.mem.eql(u8, syms[h.index].name, "fs.path.basename")) seen_basename = i;
        if (std.mem.eql(u8, syms[h.index].name, "fs.path.dirname")) seen_dirname = i;
    }
    try testing.expect(seen_dirname.? < seen_basename.?);
}

test "plurals and prefixes match; files and empty queries do not" {
    const syms = [_]symbol_index.Symbol{
        mk("listDirectories", .function, "", "", true),
        mk("main.zig", .file, "", "", false),
    };
    const lists = [_][]const symbol_index.Symbol{&syms};
    var hits: [4]Hit = undefined;
    try testing.expectEqual(@as(usize, 1), rank(&lists, "directory lists", &hits)); // lists/list, directory/directories? prefix of "Directories"
    try testing.expectEqual(@as(usize, 0), rank(&lists, "", &hits));
    try testing.expectEqual(@as(usize, 0), rank(&lists, "main", &hits)); // a file name is the quick-open box's job
}

test "the web address encodes the query" {
    const url = try webSearchUrl(testing.allocator, "path from dir & more?");
    defer testing.allocator.free(url);
    try testing.expectEqualStrings("https://www.google.com/search?q=zig+path+from+dir+%26+more%3F", url);
}

