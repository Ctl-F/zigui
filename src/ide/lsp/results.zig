//! Reading what a language server answers, from parsed JSON (`std.json.Value`)
//! into plain structs. Servers differ in which of the allowed shapes they send,
//! so each reader accepts all of them. Strings point into the parsed JSON (valid
//! while it lives); lists are allocated from the arena you pass.

const std = @import("std");
const Value = std.json.Value;

pub const Position = struct { line: u32, character: u32 };
pub const Range = struct { start: Position, end: Position };
pub const Location = struct { uri: []const u8, range: Range };

pub const Severity = enum(u8) { err = 1, warning = 2, info = 3, hint = 4 };

pub const Diagnostic = struct {
    range: Range,
    severity: Severity,
    message: []const u8,
    source: []const u8 = "",
};

pub const CompletionItem = struct {
    label: []const u8,
    /// What to insert (`textEdit.newText`, else `insertText`, else the label).
    insert: []const u8,
    detail: []const u8,
    /// The LSP `CompletionItemKind` number (0 if absent).
    kind: u32,
};

pub const SignatureInfo = struct {
    label: []const u8,
    /// Byte ranges of the parameters inside `label` (empty if the server gave names only).
    params: []const [2]usize,
    active: usize,
};

fn field(v: Value, name: []const u8) ?Value {
    if (v != .object) return null;
    return v.object.get(name);
}

fn str(v: ?Value) []const u8 {
    const x = v orelse return "";
    return if (x == .string) x.string else "";
}

fn int(v: ?Value) i64 {
    const x = v orelse return 0;
    return switch (x) {
        .integer => |i| i,
        .float => |f| @intFromFloat(f),
        else => 0,
    };
}

fn position(v: ?Value) ?Position {
    const p = v orelse return null;
    if (p != .object) return null;
    return .{ .line = @intCast(@max(int(p.object.get("line")), 0)), .character = @intCast(@max(int(p.object.get("character")), 0)) };
}

fn range(v: ?Value) ?Range {
    const r = v orelse return null;
    return .{ .start = position(field(r, "start")) orelse return null, .end = position(field(r, "end")) orelse return null };
}

pub fn diagnostics(a: std.mem.Allocator, v: Value) ![]Diagnostic {
    var out: std.ArrayListUnmanaged(Diagnostic) = .empty;
    if (v != .array) return out.items;
    for (v.array.items) |d| {
        const r = range(field(d, "range")) orelse continue;
        const sev: u8 = @intCast(std.math.clamp(int(field(d, "severity")), 1, 4));
        try out.append(a, .{ .range = r, .severity = @enumFromInt(if (field(d, "severity") == null) 1 else sev), .message = str(field(d, "message")), .source = str(field(d, "source")) });
    }
    return out.items;
}

/// `completion` result: an array of items or `{ items: [...] }`.
pub fn completion(a: std.mem.Allocator, v: Value) ![]CompletionItem {
    var out: std.ArrayListUnmanaged(CompletionItem) = .empty;
    const items = switch (v) {
        .array => |arr| arr.items,
        .object => |o| if (o.get("items")) |it| (if (it == .array) it.array.items else &.{}) else &.{},
        else => &.{},
    };
    for (items) |it| {
        const label = str(field(it, "label"));
        if (label.len == 0) continue;
        var insert = str(field(it, "insertText"));
        if (field(it, "textEdit")) |te| {
            const nt = str(field(te, "newText"));
            if (nt.len > 0) insert = nt;
        }
        if (insert.len == 0) insert = label;
        try out.append(a, .{ .label = label, .insert = insert, .detail = str(field(it, "detail")), .kind = @intCast(@max(int(field(it, "kind")), 0)) });
    }
    return out.items;
}

/// A short tag for a `CompletionItemKind` (as `Completion` shows before the label).
pub fn kindTag(kind: u32) []const u8 {
    return switch (kind) {
        2, 3, 4 => "fn",
        5, 10 => "field",
        6, 12 => "var",
        7, 8, 22 => "type",
        9 => "mod",
        13, 20 => "enum",
        14 => "kw",
        21 => "const",
        else => "",
    };
}

/// `hover` result as plain text: the contents' strings, with Markdown code
/// fences dropped, joined by newlines. Null if there is nothing to show.
pub fn hover(a: std.mem.Allocator, v: Value) !?[]const u8 {
    const contents = field(v, "contents") orelse return null;
    var out: std.ArrayListUnmanaged(u8) = .empty;
    try appendMarked(a, &out, contents);
    const trimmed = std.mem.trim(u8, out.items, "\n ");
    return if (trimmed.len == 0) null else trimmed;
}

fn appendMarked(a: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), v: Value) !void {
    switch (v) {
        .string => |s| try appendStripped(a, out, s),
        .object => |o| {
            if (o.get("value")) |x| if (x == .string) try appendStripped(a, out, x.string);
        },
        .array => |arr| for (arr.items) |x| try appendMarked(a, out, x),
        else => {},
    }
}

fn appendStripped(a: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), text: []const u8) !void {
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        const t = std.mem.trimEnd(u8, line, "\r");
        if (std.mem.startsWith(u8, std.mem.trimStart(u8, t, " "), "```")) continue;
        try out.appendSlice(a, t);
        try out.append(a, '\n');
    }
}

/// `signatureHelp` result: the active signature, its parameter ranges, and the
/// active parameter. Null when there are no signatures.
pub fn signature(a: std.mem.Allocator, v: Value) !?SignatureInfo {
    const sigs = field(v, "signatures") orelse return null;
    if (sigs != .array or sigs.array.items.len == 0) return null;
    const idx: usize = @intCast(@min(@max(int(field(v, "activeSignature")), 0), @as(i64, @intCast(sigs.array.items.len - 1))));
    const s = sigs.array.items[idx];
    const label = str(field(s, "label"));
    var params: std.ArrayListUnmanaged([2]usize) = .empty;
    if (field(s, "parameters")) |ps| if (ps == .array) {
        for (ps.array.items) |p| {
            const l = field(p, "label") orelse continue;
            switch (l) {
                .array => |pair| if (pair.items.len == 2) {
                    try params.append(a, .{ @intCast(@max(int(pair.items[0]), 0)), @intCast(@max(int(pair.items[1]), 0)) });
                },
                .string => |name| if (std.mem.indexOf(u8, label, name)) |at| try params.append(a, .{ at, at + name.len }),
                else => {},
            }
        }
    };
    const active_val = field(s, "activeParameter") orelse field(v, "activeParameter");
    return .{ .label = label, .params = params.items, .active = @intCast(@max(int(active_val), 0)) };
}

/// `definition` result: a Location, Location[] or LocationLink[].
pub fn locations(a: std.mem.Allocator, v: Value) ![]Location {
    var out: std.ArrayListUnmanaged(Location) = .empty;
    const one = struct {
        fn get(x: Value) ?Location {
            if (field(x, "targetUri")) |u| {
                if (u != .string) return null;
                const r = range(field(x, "targetSelectionRange")) orelse range(field(x, "targetRange")) orelse return null;
                return .{ .uri = u.string, .range = r };
            }
            const u = field(x, "uri") orelse return null;
            if (u != .string) return null;
            return .{ .uri = u.string, .range = range(field(x, "range")) orelse return null };
        }
    }.get;
    switch (v) {
        .array => |arr| for (arr.items) |x| {
            if (one(x)) |l| try out.append(a, l);
        },
        .object => if (one(v)) |l| try out.append(a, l),
        else => {},
    }
    return out.items;
}

// ---- tests -----------------------------------------------------------------

const testing = std.testing;

fn parse(arena: std.mem.Allocator, text: []const u8) !Value {
    return (try std.json.parseFromSliceLeaky(Value, arena, text, .{}));
}

test "completion items from both result shapes, preferring textEdit text" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const items = try completion(a, try parse(a, "{\"isIncomplete\":false,\"items\":[{\"label\":\"print\",\"kind\":3,\"detail\":\"fn (fmt) void\"},{\"label\":\"x\",\"insertText\":\"xx\",\"textEdit\":{\"newText\":\"xyz\",\"range\":{}}},{\"nolabel\":1}]}"));
    try testing.expectEqual(@as(usize, 2), items.len);
    try testing.expectEqualStrings("print", items[0].insert);
    try testing.expectEqualStrings("fn (fmt) void", items[0].detail);
    try testing.expectEqualStrings("xyz", items[1].insert);
    try testing.expectEqualStrings("fn", kindTag(items[0].kind));
    const arr = try completion(a, try parse(a, "[{\"label\":\"a\"}]"));
    try testing.expectEqual(@as(usize, 1), arr.len);
    try testing.expectEqual(@as(usize, 0), (try completion(a, try parse(a, "null"))).len);
}

test "hover text from MarkupContent, MarkedString and arrays; fences are dropped" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const h1 = (try hover(a, try parse(a, "{\"contents\":{\"kind\":\"markdown\",\"value\":\"```zig\\nfn foo() void\\n```\\nDoes foo.\"}}"))).?;
    try testing.expectEqualStrings("fn foo() void\nDoes foo.", h1);
    const h2 = (try hover(a, try parse(a, "{\"contents\":[\"one\",{\"language\":\"zig\",\"value\":\"two\"}]}"))).?;
    try testing.expectEqualStrings("one\ntwo", h2);
    try testing.expect((try hover(a, try parse(a, "null"))) == null);
    try testing.expect((try hover(a, try parse(a, "{\"contents\":\"\"}"))) == null);
}

test "signature help with offset and name parameter labels" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const s1 = (try signature(a, try parse(a, "{\"signatures\":[{\"label\":\"f(a: u8, b: u8) void\",\"parameters\":[{\"label\":[2,7]},{\"label\":[9,14]}]}],\"activeParameter\":1}"))).?;
    try testing.expectEqualStrings("f(a: u8, b: u8) void", s1.label);
    try testing.expectEqual(@as(usize, 2), s1.params.len);
    try testing.expectEqualStrings("b: u8", s1.label[s1.params[1][0]..s1.params[1][1]]);
    try testing.expectEqual(@as(usize, 1), s1.active);
    const s2 = (try signature(a, try parse(a, "{\"signatures\":[{\"label\":\"g(x, y)\",\"parameters\":[{\"label\":\"x\"},{\"label\":\"y\"}],\"activeParameter\":0}]}"))).?;
    try testing.expectEqualStrings("y", s2.label[s2.params[1][0]..s2.params[1][1]]);
    try testing.expect((try signature(a, try parse(a, "{\"signatures\":[]}"))) == null);
}

test "locations and diagnostics" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const loc_json = "{\"uri\":\"file:///a.zig\",\"range\":{\"start\":{\"line\":3,\"character\":4},\"end\":{\"line\":3,\"character\":9}}}";
    const one = try locations(a, try parse(a, loc_json));
    try testing.expectEqual(@as(usize, 1), one.len);
    try testing.expectEqual(@as(u32, 3), one[0].range.start.line);
    const many = try locations(a, try parse(a, "[" ++ loc_json ++ "]"));
    try testing.expectEqualStrings("file:///a.zig", many[0].uri);
    const link = try locations(a, try parse(a, "[{\"targetUri\":\"file:///b.zig\",\"targetRange\":{\"start\":{\"line\":0,\"character\":0},\"end\":{\"line\":9,\"character\":0}},\"targetSelectionRange\":{\"start\":{\"line\":1,\"character\":2},\"end\":{\"line\":1,\"character\":5}}}]"));
    try testing.expectEqual(@as(u32, 2), link[0].range.start.character);
    const ds = try diagnostics(a, try parse(a, "[{\"range\":{\"start\":{\"line\":1,\"character\":0},\"end\":{\"line\":1,\"character\":3}},\"severity\":2,\"message\":\"unused\",\"source\":\"zls\"},{\"range\":{\"start\":{\"line\":0,\"character\":0},\"end\":{\"line\":0,\"character\":1}},\"message\":\"no severity\"}]"));
    try testing.expectEqual(@as(usize, 2), ds.len);
    try testing.expect(ds[0].severity == .warning);
    try testing.expect(ds[1].severity == .err);
    try testing.expectEqualStrings("zls", ds[0].source);
}
