//! Boundary check: keeps C-convention code out of the Zig core.
//!
//! The core API is idiomatic Zig. `callconv(.c)`, `export`, and `extern`
//! types belong only in the C facade (`src/capi/`, when it exists) and in the
//! modules that import C libraries (`src/platform/`, `src/text/stb*`). A small
//! allow-list of value types stays `extern` so a facade can pass them by value.
//!
//! Run with `zig build check-boundary` (also part of `zig build test`). Comment
//! lines are ignored.

const std = @import("std");

/// Value types that may be `extern` anywhere.
const extern_allow = [_][]const u8{ "Handle", "Rect", "Vec2", "Size", "Color" };

const banned = [_][]const u8{ "callconv(.c)", "export fn", "export const", "export var", "extern enum", "extern union" };

/// Path prefixes (relative to `src/`) exempt from the check.
const exempt_prefixes = [_][]const u8{ "platform/", "capi/", "text/stb" };

pub const Violation = struct {
    line: usize,
    what: []const u8,
};

fn isExempt(path: []const u8) bool {
    for (exempt_prefixes) |p| if (std.mem.startsWith(u8, path, p)) return true;
    return false;
}

fn isAllowedExternStruct(line: []const u8) bool {
    for (extern_allow) |name| {
        var buf: [64]u8 = undefined;
        const want = std.fmt.bufPrint(&buf, "pub const {s} = extern struct", .{name}) catch continue;
        if (std.mem.indexOf(u8, line, want) != null) return true;
    }
    return false;
}

/// What is wrong with this source line, if anything.
pub fn checkLine(raw: []const u8) ?[]const u8 {
    const line = std.mem.trimStart(u8, raw, " \t");
    if (std.mem.startsWith(u8, line, "//")) return null;
    for (banned) |b| if (std.mem.indexOf(u8, line, b) != null) return b;
    if (std.mem.indexOf(u8, line, "extern struct") != null and !isAllowedExternStruct(line)) return "extern struct";
    return null;
}

/// Append every violation in `text` to `out`.
pub fn scanText(gpa: std.mem.Allocator, text: []const u8, out: *std.ArrayListUnmanaged(Violation)) !void {
    var n: usize = 0;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        n += 1;
        if (checkLine(line)) |what| try out.append(gpa, .{ .line = n, .what = what });
    }
}

pub fn main(init: std.process.Init) !u8 {
    const gpa = init.gpa;
    const io = init.io;

    var src = try std.Io.Dir.cwd().openDir(io, "src", .{ .iterate = true });
    defer src.close(io);
    var walker = try src.walk(gpa);
    defer walker.deinit();

    var failures: usize = 0;
    var scanned: usize = 0;
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.path, ".zig")) continue;
        if (isExempt(entry.path)) continue;
        const text = try entry.dir.readFileAlloc(io, entry.basename, gpa, .limited(16 * 1024 * 1024));
        defer gpa.free(text);
        scanned += 1;

        var found: std.ArrayListUnmanaged(Violation) = .empty;
        defer found.deinit(gpa);
        try scanText(gpa, text, &found);
        for (found.items) |v| {
            std.debug.print("boundary: src/{s}:{d}: `{s}` is not allowed outside the C facade and C-import modules\n", .{ entry.path, v.line, v.what });
            failures += 1;
        }
    }
    if (failures > 0) {
        std.debug.print("boundary check failed: {d} violation(s). See NOTES/zig-first-refactor.md.\n", .{failures});
        return 1;
    }
    std.debug.print("boundary check ok ({d} files)\n", .{scanned});
    return 0;
}

// ---- tests -----------------------------------------------------------------

test "flags C calling conventions, exports, and extern types" {
    try std.testing.expectEqualStrings("callconv(.c)", checkLine("fn f() callconv(.c) void {}").?);
    try std.testing.expectEqualStrings("export fn", checkLine("export fn zui_init() void {}").?);
    try std.testing.expectEqualStrings("extern struct", checkLine("pub const Thing = extern struct {").?);
    try std.testing.expectEqualStrings("extern union", checkLine("const U = extern union {").?);
}

test "the value-type allow-list passes" {
    for (extern_allow) |name| {
        var buf: [96]u8 = undefined;
        const line = try std.fmt.bufPrint(&buf, "pub const {s} = extern struct {{", .{name});
        try std.testing.expect(checkLine(line) == null);
    }
    try std.testing.expect(checkLine("pub const Handles = extern struct {") != null); // not a prefix match
}

test "comments and ordinary code are ignored" {
    try std.testing.expect(checkLine("    // callconv(.c) used to live here") == null);
    try std.testing.expect(checkLine("/// export fn is banned") == null);
    try std.testing.expect(checkLine("const x = callback.call(ctx, ev);") == null);
    try std.testing.expect(checkLine("") == null);
}

test "scanText reports line numbers" {
    var out: std.ArrayListUnmanaged(Violation) = .empty;
    defer out.deinit(std.testing.allocator);
    try scanText(std.testing.allocator, "const a = 1;\nfn f() callconv(.c) void {}\n// export fn x\nexport fn y() void {}\n", &out);
    try std.testing.expectEqual(@as(usize, 2), out.items.len);
    try std.testing.expectEqual(@as(usize, 2), out.items[0].line);
    try std.testing.expectEqual(@as(usize, 4), out.items[1].line);
}

test "exempt prefixes" {
    try std.testing.expect(isExempt("platform/sdl.zig"));
    try std.testing.expect(isExempt("text/stb.zig"));
    try std.testing.expect(isExempt("capi/zigui_c.zig"));
    try std.testing.expect(!isExempt("text/system.zig"));
    try std.testing.expect(!isExempt("core/ui.zig"));
}
