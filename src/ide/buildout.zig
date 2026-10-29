//! Reading compiler output: turn lines like
//!
//!     src/main.zig:12:5: error: expected ';' after declaration
//!     /abs/path/file.zig:3:1: note: declared here
//!
//! into locations an IDE can jump to. This is Zig's format (also close to
//! GCC/Clang's); other tools can be added as further parsers. No UI here.

const std = @import("std");

pub const Severity = enum { err, warning, note };

pub const Diagnostic = struct {
    /// Slices of the line passed to `parseLine`.
    path: []const u8,
    /// 1-based, as printed.
    line: u32,
    col: u32,
    severity: Severity,
    message: []const u8,
};

const markers = [_]struct { text: []const u8, severity: Severity }{
    .{ .text = ": error: ", .severity = .err },
    .{ .text = ": warning: ", .severity = .warning },
    .{ .text = ": note: ", .severity = .note },
    .{ .text = ": info: ", .severity = .note },
};

/// Parse one line of output (no trailing newline, ANSI colors already removed
/// with `stripAnsi`); null if it is not a located diagnostic.
pub fn parseLine(line: []const u8) ?Diagnostic {
    // The earliest marker wins (a message may itself contain "error: ").
    var best: ?struct { at: usize, len: usize, severity: Severity } = null;
    for (markers) |m| {
        if (std.mem.indexOf(u8, line, m.text)) |at| {
            if (best == null or at < best.?.at) best = .{ .at = at, .len = m.text.len, .severity = m.severity };
        }
    }
    const b = best orelse return null;
    const location = line[0..b.at];
    // location = path:line:col  (the path may contain ':' on Windows: C:\x)
    const last = std.mem.lastIndexOfScalar(u8, location, ':') orelse return null;
    const col = std.fmt.parseInt(u32, location[last + 1 ..], 10) catch return null;
    const rest = location[0..last];
    const prev = std.mem.lastIndexOfScalar(u8, rest, ':') orelse return null;
    const ln = std.fmt.parseInt(u32, rest[prev + 1 ..], 10) catch return null;
    const path = rest[0..prev];
    if (path.len == 0) return null;
    return .{ .path = path, .line = ln, .col = col, .severity = b.severity, .message = line[b.at + b.len ..] };
}

/// Remove ANSI escape sequences (colors, cursor moves) from `text` into `out`.
pub fn stripAnsi(gpa: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), text: []const u8) !void {
    var i: usize = 0;
    while (i < text.len) {
        const c = text[i];
        if (c == 0x1b and i + 1 < text.len and text[i + 1] == '[') {
            i += 2;
            // Parameters and intermediates, then a final byte in 0x40..0x7e.
            while (i < text.len and (text[i] < 0x40 or text[i] > 0x7e)) i += 1;
            i += 1;
        } else if (c == 0x1b and i + 1 < text.len and text[i + 1] == ']') {
            // An operating-system command: up to BEL or ESC \.
            i += 2;
            while (i < text.len and text[i] != 0x07 and !(text[i] == 0x1b and i + 1 < text.len and text[i + 1] == '\\')) i += 1;
            i += if (i < text.len and text[i] == 0x07) 1 else 2;
        } else if (c == 0x1b and i + 1 < text.len and std.mem.indexOfScalar(u8, "()*+", text[i + 1]) != null) {
            i += 3; // select a character set
        } else if (c == 0x1b and i + 1 < text.len) {
            i += 2; // a two-byte escape
        } else {
            try out.append(gpa, c);
            i += 1;
        }
    }
}

// ---- tests -----------------------------------------------------------------

const testing = std.testing;

test "parseLine reads Zig diagnostics" {
    const d = parseLine("src/main.zig:12:5: error: expected ';' after declaration").?;
    try testing.expectEqualStrings("src/main.zig", d.path);
    try testing.expectEqual(@as(u32, 12), d.line);
    try testing.expectEqual(@as(u32, 5), d.col);
    try testing.expect(d.severity == .err);
    try testing.expectEqualStrings("expected ';' after declaration", d.message);

    const w = parseLine("/home/me/p/a.zig:3:1: warning: unused").?;
    try testing.expectEqualStrings("/home/me/p/a.zig", w.path);
    try testing.expect(w.severity == .warning);
    const n = parseLine("a.zig:1:2: note: declared here").?;
    try testing.expect(n.severity == .note);
    // The message may contain the marker text; the first marker is the severity.
    const e = parseLine("x.zig:9:9: error: unexpected token: error: here").?;
    try testing.expect(e.severity == .err);
    try testing.expectEqualStrings("unexpected token: error: here", e.message);
}

test "parseLine handles Windows paths and rejects non-diagnostics" {
    const d = parseLine("C:\\proj\\src\\main.zig:4:2: error: bad").?;
    try testing.expectEqualStrings("C:\\proj\\src\\main.zig", d.path);
    try testing.expectEqual(@as(u32, 4), d.line);
    try testing.expect(parseLine("error: the following command failed with 1 compilation errors:") == null);
    try testing.expect(parseLine("    foo bar") == null);
    try testing.expect(parseLine("") == null);
    try testing.expect(parseLine("file.zig:x:y: error: bad") == null);
    try testing.expect(parseLine(":1:2: error: no path") == null);
}

test "stripAnsi removes color and cursor sequences" {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(testing.allocator);
    try stripAnsi(testing.allocator, &out, "\x1b[31;1merror\x1b[0m: \x1b[2Kok\x1b(B!");
    try testing.expectEqualStrings("error: ok!", out.items);
}
