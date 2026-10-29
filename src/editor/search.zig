//! Text search over a `Document`: literal matching with case and whole-word
//! options. Used by the find bar (and project-wide search, which runs the same
//! matcher over files on worker threads). Matches are byte ranges.
//!
//! Queries without a line break are matched line by line, so a match never
//! spans lines and a huge document is never copied; a query containing '\n'
//! (a multi-line search) copies the document text once.

const std = @import("std");
const Document = @import("document.zig").Document;

pub const Options = struct {
    case_sensitive: bool = false,
    /// A match must not touch a letter, digit, or underscore on either side.
    whole_word: bool = false,
};

pub const Match = struct {
    start: usize,
    end: usize,
};

pub const Error = error{OutOfMemory};

fn isWordByte(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c >= 0x80;
}

/// The first match of `needle` in `hay` at or after `from`, as an offset into `hay`.
pub fn indexIn(hay: []const u8, needle: []const u8, from: usize, opts: Options) ?usize {
    if (needle.len == 0 or from > hay.len) return null;
    var at = from;
    while (at + needle.len <= hay.len) {
        const rest = hay[at..];
        const rel = (if (opts.case_sensitive) std.mem.indexOf(u8, rest, needle) else std.ascii.findIgnoreCase(rest, needle)) orelse return null;
        const s = at + rel;
        const e = s + needle.len;
        if (!opts.whole_word or ((s == 0 or !isWordByte(hay[s - 1])) and (e == hay.len or !isWordByte(hay[e])))) return s;
        at = s + 1;
    }
    return null;
}

/// Every match in the document, in order, up to `max`. The caller frees the slice.
pub fn findAll(doc: *Document, gpa: std.mem.Allocator, query: []const u8, opts: Options, max: usize) Error![]Match {
    var out: std.ArrayListUnmanaged(Match) = .empty;
    errdefer out.deinit(gpa);
    if (query.len == 0) return out.toOwnedSlice(gpa);
    if (std.mem.indexOfScalar(u8, query, '\n') != null) {
        const text = try doc.textAlloc(gpa, 0, doc.len());
        defer gpa.free(text);
        var at: usize = 0;
        while (out.items.len < max) {
            const s = indexIn(text, query, at, opts) orelse break;
            try out.append(gpa, .{ .start = s, .end = s + query.len });
            at = s + query.len;
        }
        return out.toOwnedSlice(gpa);
    }
    var line: usize = 0;
    const lines = doc.lineCount();
    while (line < lines and out.items.len < max) : (line += 1) {
        const ls = doc.lineStart(line);
        const text = doc.range(ls, doc.lineEnd(line)) catch return error.OutOfMemory;
        var at: usize = 0;
        while (out.items.len < max) {
            const s = indexIn(text, query, at, opts) orelse break;
            try out.append(gpa, .{ .start = ls + s, .end = ls + s + query.len });
            at = s + query.len;
        }
    }
    return out.toOwnedSlice(gpa);
}

/// Index of the first match starting at or after `offset` (wrapping to the
/// first match when none follows), or null for no matches.
pub fn nextIndex(matches: []const Match, offset: usize) ?usize {
    if (matches.len == 0) return null;
    for (matches, 0..) |m, i| {
        if (m.start >= offset) return i;
    }
    return 0;
}

/// Index of the last match that ends at or before `offset` (wrapping to the last).
pub fn prevIndex(matches: []const Match, offset: usize) ?usize {
    if (matches.len == 0) return null;
    var i = matches.len;
    while (i > 0) {
        i -= 1;
        if (matches[i].end <= offset) return i;
    }
    return matches.len - 1;
}

// ---- tests -----------------------------------------------------------------

const testing = std.testing;

fn docWith(text: []const u8) !Document {
    return Document.initWithText(testing.allocator, text, false);
}

test "indexIn: literal, case, and whole-word matching" {
    try testing.expectEqual(@as(?usize, 4), indexIn("the Cat sat", "cat", 0, .{}));
    try testing.expectEqual(@as(?usize, null), indexIn("the Cat sat", "cat", 0, .{ .case_sensitive = true }));
    try testing.expectEqual(@as(?usize, 4), indexIn("the Cat sat", "Cat", 0, .{ .case_sensitive = true }));
    // Whole word skips "category" and "scat" and finds the later "cat".
    try testing.expectEqual(@as(?usize, 16), indexIn("category scat x cat", "cat", 0, .{ .whole_word = true }));
    try testing.expectEqual(@as(?usize, null), indexIn("category", "cat", 0, .{ .whole_word = true }));
    try testing.expectEqual(@as(?usize, 2), indexIn("a_cat", "cat", 0, .{}));
    try testing.expectEqual(@as(?usize, null), indexIn("a_cat", "cat", 0, .{ .whole_word = true })); // underscore is a word byte
    try testing.expectEqual(@as(?usize, null), indexIn("abc", "", 0, .{}));
}

test "findAll: every occurrence per line, with offsets into the document" {
    var d = try docWith("one two\nTwo three two\n\ntwo");
    defer d.deinit();
    const m = try findAll(&d, testing.allocator, "two", .{}, 100);
    defer testing.allocator.free(m);
    try testing.expectEqual(@as(usize, 4), m.len);
    try testing.expectEqual(@as(usize, 4), m[0].start);
    try testing.expectEqual(@as(usize, 8), m[1].start);
    try testing.expectEqual(@as(usize, 18), m[2].start);
    try testing.expectEqual(@as(usize, 23), m[3].start);
    const sens = try findAll(&d, testing.allocator, "two", .{ .case_sensitive = true }, 100);
    defer testing.allocator.free(sens);
    try testing.expectEqual(@as(usize, 3), sens.len);
    const capped = try findAll(&d, testing.allocator, "two", .{}, 2);
    defer testing.allocator.free(capped);
    try testing.expectEqual(@as(usize, 2), capped.len);
    const none = try findAll(&d, testing.allocator, "zzz", .{}, 100);
    defer testing.allocator.free(none);
    try testing.expectEqual(@as(usize, 0), none.len);
}

test "findAll: a multi-line query" {
    var d = try docWith("a\nb\na\nb\nc");
    defer d.deinit();
    const m = try findAll(&d, testing.allocator, "a\nb", .{}, 100);
    defer testing.allocator.free(m);
    try testing.expectEqual(@as(usize, 2), m.len);
    try testing.expectEqual(@as(usize, 4), m[1].start);
    try testing.expectEqual(@as(usize, 7), m[1].end);
}

test "nextIndex and prevIndex wrap around" {
    const m = [_]Match{ .{ .start = 5, .end = 7 }, .{ .start = 20, .end = 22 } };
    try testing.expectEqual(@as(?usize, 0), nextIndex(&m, 0));
    try testing.expectEqual(@as(?usize, 1), nextIndex(&m, 6));
    try testing.expectEqual(@as(?usize, 0), nextIndex(&m, 30)); // wraps
    try testing.expectEqual(@as(?usize, 0), prevIndex(&m, 20));
    try testing.expectEqual(@as(?usize, 1), prevIndex(&m, 3)); // wraps to the last
    try testing.expectEqual(@as(?usize, null), nextIndex(&.{}, 0));
}
