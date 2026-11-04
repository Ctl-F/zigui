//! Go to anything (Ctrl+,): a quick-pick box over every file and declaration in
//! the project, the packages and C headers its build brings in, and the Zig
//! standard library. Typing ranks the matches; Enter opens the file (or the
//! declaration's line). Library results open read-only.
//!
//!     const qo = try QuickOpen.create(&ui, ui.tree.root, &project, std_dir, .{ .on_open = OpenHook.bind(&app, App.openAt),
//!                                      .on_docs = DocsHook.bind(&app, App.docsFor), .modules = .{ ... }, .wake = sdl.wake });
//!     defer qo.destroy();
//!     qo.show();                // the command
//!     qo.poll();                // each loop iteration: take finished scans
//!
//! **Prefixes** narrow what is searched (several may be chained, `x:m:open`):
//!
//!     m:  functions (methods)        c:  constants        p:  the project only
//!     t:  types                      v:  variables        s:  the standard library only
//!     f:  files                      d:  documentation    x:  dependencies and C modules only
//!
//! `m:` `t:` `f:` `c:` `v:` choose kinds (several widen it); `p:` `s:` `x:` choose where
//! (several widen it). `d:` hands the rest to the documentation search. No prefix
//! searches everything.
//!
//! The project is scanned again each time the box opens (so new and saved files
//! show up); the library and the build's modules once, in the background, when
//! `QuickOpen` is created (the modules again when `build.zig` or `build.zig.zon`
//! changed). IDE-level code: it builds on `SymbolIndex` and `widgets.quick_pick`.

const std = @import("std");
const Handle = @import("../core/handle.zig").Handle;
const Ui = @import("../core/ui.zig").Ui;
const quick_pick = @import("../widgets/quick_pick.zig");
const matchScore = @import("../widgets/completion.zig").matchScore;
const output_panel = @import("output_panel.zig");
const project_mod = @import("project.zig");
const symbol_index = @import("symbol_index.zig");
const build_modules = @import("build_modules.zig");

pub const OpenHook = output_panel.OpenHook;

/// Called with the rest of the query when a `d:` prefix hands over to the documentation search.
pub const DocsHook = struct {
    ctx: ?*anyopaque = null,
    call: *const fn (ctx: ?*anyopaque, query: []const u8) void,

    pub fn bind(ctx: anytype, comptime f: anytype) DocsHook {
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

pub const Options = struct {
    on_open: ?OpenHook = null,
    on_docs: ?DocsHook = null,
    wake: ?*const fn () void = null,
    /// Index the packages and C headers the build brings in (null: not).
    modules: ?build_modules.Config = null,
};

// ---- prefixes (UI-free) ----------------------------------------------------

pub const Filter = struct {
    /// Bit per `symbol_index.Kind`; all set when no kind prefix was given.
    kinds: u8 = 0b11111,
    /// Bit per `symbol_index.Origin`; all set when no place prefix was given.
    origins: u8 = 0b1111,
    /// `d:` was given: this is a documentation search.
    docs: bool = false,

    pub fn allows(self: Filter, s: symbol_index.Symbol) bool {
        return (self.kinds >> @intFromEnum(s.kind)) & 1 == 1 and (self.origins >> @intFromEnum(s.origin)) & 1 == 1;
    }
};

pub const Parsed = struct { filter: Filter, rest: []const u8 };

fn bit(comptime E: type, v: E) u8 {
    return @as(u8, 1) << @intFromEnum(v);
}

/// Split `m:t:rest` into the filter the prefixes make and the text after them.
pub fn parsePrefixes(query: []const u8) Parsed {
    var f: Filter = .{};
    var kinds: u8 = 0;
    var origins: u8 = 0;
    var rest = std.mem.trimStart(u8, query, " ");
    while (rest.len >= 2 and rest[1] == ':') {
        switch (rest[0]) {
            'm' => kinds |= bit(symbol_index.Kind, .function),
            't' => kinds |= bit(symbol_index.Kind, .type),
            'f' => kinds |= bit(symbol_index.Kind, .file),
            'c' => kinds |= bit(symbol_index.Kind, .constant),
            'v' => kinds |= bit(symbol_index.Kind, .variable),
            'p' => origins |= bit(symbol_index.Origin, .project),
            's' => origins |= bit(symbol_index.Origin, .std),
            'x' => origins |= bit(symbol_index.Origin, .dependency) | bit(symbol_index.Origin, .c),
            'd' => f.docs = true,
            else => break,
        }
        rest = std.mem.trimStart(u8, rest[2..], " ");
    }
    if (kinds != 0) f.kinds = kinds;
    if (origins != 0) f.origins = origins;
    return .{ .filter = f, .rest = rest };
}

const max_rows = quick_pick.max_rows;

pub const QuickOpen = struct {
    gpa: std.mem.Allocator,
    pick: *quick_pick.QuickPick,
    project_index: *symbol_index.SymbolIndex,
    lib_index: ?*symbol_index.SymbolIndex,
    mod_index: ?*symbol_index.SymbolIndex = null,
    planner: ?*build_modules.Planner = null,
    on_open: ?OpenHook,
    on_docs: ?DocsHook,
    project: *const project_mod.Project,
    /// The rows shown for the current query; strings live in `arena`.
    items: std.ArrayListUnmanaged(quick_pick.Item) = .empty,
    syms: std.ArrayListUnmanaged(symbol_index.Symbol) = .empty,
    arena: std.heap.ArenaAllocator,
    query: std.ArrayListUnmanaged(u8) = .empty,
    /// Counts up each time an index finished (others, like the documentation search, re-rank on it).
    generation: u32 = 0,
    /// The build files' modification times when the modules were last scanned.
    build_stamp: i128 = 0,
    /// How many symbols there are across the indexes (for the status line).
    total: usize = 0,

    pub fn create(ui: *Ui, parent: Handle, project: *const project_mod.Project, std_dir: ?[]const u8, opts: Options) !*QuickOpen {
        const self = try ui.gpa.create(QuickOpen);
        errdefer ui.gpa.destroy(self);
        const pick = try quick_pick.QuickPick.create(ui, parent);
        errdefer pick.destroy();
        const pidx = try symbol_index.SymbolIndex.start(ui.gpa, project, null, opts.wake);
        errdefer pidx.destroy();
        const lidx: ?*symbol_index.SymbolIndex = if (std_dir) |d| try symbol_index.SymbolIndex.startLibrary(ui.gpa, project, d, opts.wake) else null;
        errdefer if (lidx) |l| l.destroy();
        self.* = .{ .gpa = ui.gpa, .pick = pick, .project_index = pidx, .lib_index = lidx, .on_open = opts.on_open, .on_docs = opts.on_docs, .project = project, .arena = .init(ui.gpa) };
        if (opts.modules) |cfg| {
            const planner = try build_modules.Planner.create(ui.gpa, cfg);
            errdefer planner.destroy();
            self.planner = planner;
            self.mod_index = try symbol_index.SymbolIndex.startModules(ui.gpa, project, planner.planner(), opts.wake);
            self.build_stamp = self.buildStamp();
        }
        return self;
    }

    pub fn destroy(self: *QuickOpen) void {
        self.pick.destroy();
        self.project_index.destroy();
        if (self.lib_index) |l| l.destroy();
        if (self.mod_index) |m| m.destroy();
        if (self.planner) |p| p.destroy();
        self.items.deinit(self.gpa);
        self.syms.deinit(self.gpa);
        self.query.deinit(self.gpa);
        self.arena.deinit();
        self.gpa.destroy(self);
    }

    /// The modification times of `build.zig` and `build.zig.zon` summed (changes when either is saved).
    fn buildStamp(self: *const QuickOpen) i128 {
        var sum: i128 = 0;
        for ([_][]const u8{ "build.zig", "build.zig.zon" }) |name| {
            const st = self.project.dir.statFile(self.project.io, name, .{}) catch continue;
            sum += st.mtime.nanoseconds;
        }
        return sum;
    }

    pub fn isOpen(self: *const QuickOpen) bool {
        return self.pick.isOpen();
    }

    /// The project's symbols, then the build's modules', then the library's (valid until the next `poll`).
    pub fn symbolLists(self: *const QuickOpen) [3][]const symbol_index.Symbol {
        return .{
            self.project_index.symbols(),
            if (self.mod_index) |m| m.symbols() else &.{},
            if (self.lib_index) |l| l.symbols() else &.{},
        };
    }

    /// What the build brings in, as the latest module scan found it (for the module explorer).
    pub fn modRoots(self: *const QuickOpen) []const symbol_index.Root {
        return if (self.mod_index) |m| m.roots() else &.{};
    }

    /// Open the box, with `text` already typed (it may start with prefixes).
    pub fn show(self: *QuickOpen) void {
        self.showWith("");
    }

    pub fn showWith(self: *QuickOpen, text: []const u8) void {
        self.project_index.rescan();
        if (self.mod_index) |m| {
            const stamp = self.buildStamp();
            if (stamp != self.build_stamp) {
                self.build_stamp = stamp;
                m.rescan();
            }
        }
        self.pick.show(.{
            .placeholder = "Go to file, function or type  (m: t: f: c: v: p: s: x:  d: docs)",
            .query = text,
            .external = true,
            .on_query = .bind(self, onQuery),
            .on_pick = .bind(self, onPick),
        });
    }

    /// Call every loop iteration: take finished scans and refresh the open box.
    pub fn poll(self: *QuickOpen) void {
        var changed = self.project_index.poll();
        if (self.lib_index) |l| {
            if (l.poll()) changed = true;
        }
        if (self.mod_index) |m| {
            if (m.poll()) changed = true;
        }
        if (!changed) return;
        self.generation +%= 1;
        var total: usize = 0;
        for (self.symbolLists()) |l| total += l.len;
        self.total = total;
        if (self.pick.isOpen()) self.refresh();
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

    fn onQuery(self: *QuickOpen, query: []const u8) void {
        self.query.clearRetainingCapacity();
        self.query.appendSlice(self.gpa, query) catch {};
        const p = parsePrefixes(query);
        if (p.filter.docs) {
            // `d:` is the documentation search: close this box and give it what follows.
            self.pick.close();
            if (self.on_docs) |h| h.call(h.ctx, p.rest);
            return;
        }
        self.refresh();
    }

    const Hit = struct { list: u8, index: u32, score: u32 };

    fn better(self: *const QuickOpen, lists: *const [3][]const symbol_index.Symbol, a: Hit, b: Hit) bool {
        if (a.score != b.score) return a.score < b.score;
        const sa = lists[a.list][a.index];
        const sb = lists[b.list][b.index];
        if (@intFromEnum(sa.origin) != @intFromEnum(sb.origin)) return groupOf(sa) < groupOf(sb);
        _ = self;
        if (sa.name.len != sb.name.len) return sa.name.len < sb.name.len;
        return std.mem.lessThan(u8, sa.name, sb.name);
    }

    fn groupOf(s: symbol_index.Symbol) u8 {
        return switch (s.origin) {
            .project => 0,
            .dependency, .c => 1,
            .std => 2,
        };
    }

    fn refresh(self: *QuickOpen) void {
        _ = self.arena.reset(.retain_capacity);
        self.items.clearRetainingCapacity();
        self.syms.clearRetainingCapacity();
        const a = self.arena.allocator();
        const parsed = parsePrefixes(self.query.items);
        const q = std.mem.trim(u8, parsed.rest, " \t");
        const lists = self.symbolLists();

        var hits: [max_rows]Hit = undefined;
        var n: usize = 0;
        for (lists, 0..) |list, li| {
            for (list, 0..) |s, i| {
                if (!parsed.filter.allows(s)) continue;
                const score: u32 = if (q.len == 0) 0 else (matchScore(q, s.name) orelse continue);
                const hit: Hit = .{ .list = @intCast(li), .index = @intCast(i), .score = score };
                if (n < max_rows) {
                    hits[n] = hit;
                    n += 1;
                    var k = n - 1;
                    while (k > 0 and self.better(&lists, hits[k], hits[k - 1])) : (k -= 1) std.mem.swap(Hit, &hits[k], &hits[k - 1]);
                } else if (self.better(&lists, hit, hits[n - 1])) {
                    var k = n - 1;
                    hits[k] = hit;
                    while (k > 0 and self.better(&lists, hits[k], hits[k - 1])) : (k -= 1) std.mem.swap(Hit, &hits[k], &hits[k - 1]);
                }
            }
        }
        for (hits[0..n]) |h| {
            const s = lists[h.list][h.index];
            const detail = if (s.kind == .file)
                s.shown
            else
                std.fmt.allocPrint(a, "{s}  {s}:{d}", .{ kindText(s.kind), s.shown, s.line }) catch continue;
            self.items.append(self.gpa, .{ .label = s.name, .detail = detail, .group = groupOf(s) }) catch break;
            self.syms.append(self.gpa, s) catch {
                _ = self.items.pop();
                break;
            };
        }
        self.pick.setItems(self.items.items);
        var buf: [96]u8 = undefined;
        self.pick.setStatus(std.fmt.bufPrint(&buf, "{d} names{s}", .{ self.total, self.scanNote() }) catch "");
    }

    fn scanNote(self: *const QuickOpen) []const u8 {
        if (self.lib_index) |l| if (l.running()) return "  (indexing the standard library...)";
        if (self.mod_index) |m| if (m.running()) return "  (indexing dependencies...)";
        return "";
    }

    fn onPick(self: *QuickOpen, index: usize) void {
        if (index >= self.syms.items.len) return;
        const s = self.syms.items[index];
        const hook = self.on_open orelse return;
        hook.call(hook.ctx, s.path, s.line, s.col);
    }
};

// ---- tests -----------------------------------------------------------------

const testing = std.testing;

test "prefixes choose kinds and places, chain, and leave the rest of the query" {
    var p = parsePrefixes("m:append");
    try testing.expectEqualStrings("append", p.rest);
    try testing.expectEqual(@as(u8, 1 << @intFromEnum(symbol_index.Kind.function)), p.filter.kinds);
    try testing.expectEqual(@as(u8, 0b1111), p.filter.origins);

    p = parsePrefixes("t: m:ArrayList");
    try testing.expectEqualStrings("ArrayList", p.rest);
    try testing.expect(p.filter.kinds == (1 << @intFromEnum(symbol_index.Kind.type)) | (1 << @intFromEnum(symbol_index.Kind.function)));

    p = parsePrefixes("x:f:sdl");
    try testing.expectEqualStrings("sdl", p.rest);
    try testing.expectEqual(@as(u8, 1 << @intFromEnum(symbol_index.Kind.file)), p.filter.kinds);
    try testing.expect(p.filter.origins == (1 << @intFromEnum(symbol_index.Origin.dependency)) | (1 << @intFromEnum(symbol_index.Origin.c)));

    p = parsePrefixes("d:path from dir");
    try testing.expect(p.filter.docs);
    try testing.expectEqualStrings("path from dir", p.rest);

    // No prefix, an unknown letter, or a colon later in the text: nothing is taken.
    p = parsePrefixes("std.mem");
    try testing.expectEqualStrings("std.mem", p.rest);
    try testing.expectEqual(@as(u8, 0b11111), p.filter.kinds);
    p = parsePrefixes("z:thing");
    try testing.expectEqualStrings("z:thing", p.rest);
    p = parsePrefixes("a:b");
    try testing.expectEqualStrings("a:b", p.rest);

    // A filter lets through only what it names.
    const f = parsePrefixes("s:t:").filter;
    const ty: symbol_index.Symbol = .{ .name = "T", .kind = .type, .path = "", .shown = "", .line = 1, .col = 1, .origin = .std };
    const fun: symbol_index.Symbol = .{ .name = "f", .kind = .function, .path = "", .shown = "", .line = 1, .col = 1, .origin = .std };
    const proj_ty: symbol_index.Symbol = .{ .name = "T", .kind = .type, .path = "", .shown = "", .line = 1, .col = 1, .origin = .project };
    try testing.expect(f.allows(ty) and !f.allows(fun) and !f.allows(proj_ty));
}
