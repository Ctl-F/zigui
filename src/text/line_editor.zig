//! Single-line text editing model: a gap buffer plus caret and selection.
//!
//! Offsets are byte offsets that always sit on UTF-8 code point boundaries.
//! The selection is `anchor..caret` (either order). Control characters,
//! including newline and tab, are never inserted: this is a one-line field.
//! No undo yet (the editor core's reversible command log will cover that).
//!
//! Pure data and logic: no tree, fonts, or platform, so it tests in isolation.

const std = @import("std");
const GapBuffer = @import("gap_buffer.zig").GapBuffer;

pub const Range = struct { start: usize, end: usize };

pub fn isContinuation(b: u8) bool {
    return b & 0xC0 == 0x80;
}

/// Start of the code point before `pos`.
pub fn prevBoundary(s: []const u8, pos: usize) usize {
    if (pos == 0) return 0;
    var i = pos - 1;
    while (i > 0 and isContinuation(s[i])) i -= 1;
    return i;
}

/// Start of the code point after the one at `pos`.
pub fn nextBoundary(s: []const u8, pos: usize) usize {
    if (pos >= s.len) return s.len;
    var i = pos + 1;
    while (i < s.len and isContinuation(s[i])) i += 1;
    return i;
}

const Class = enum { space, word, other };

fn classAt(s: []const u8, pos: usize) Class {
    const b = s[pos];
    if (b == ' ' or b == '\t') return .space;
    if (std.ascii.isAlphanumeric(b) or b == '_' or b >= 0x80) return .word;
    return .other;
}

pub const LineEditor = struct {
    buf: GapBuffer,
    caret: usize = 0,
    anchor: usize = 0,

    pub fn init(gpa: std.mem.Allocator) LineEditor {
        return .{ .buf = GapBuffer.init(gpa) };
    }

    pub fn deinit(self: *LineEditor) void {
        self.buf.deinit();
        self.* = undefined;
    }

    pub fn text(self: *LineEditor) []const u8 {
        return self.buf.contiguous();
    }

    pub fn hasSelection(self: *const LineEditor) bool {
        return self.caret != self.anchor;
    }

    pub fn selection(self: *const LineEditor) Range {
        return .{ .start = @min(self.caret, self.anchor), .end = @max(self.caret, self.anchor) };
    }

    pub fn selectedText(self: *LineEditor) []const u8 {
        const r = self.selection();
        return self.text()[r.start..r.end];
    }

    /// Replace the whole content (control characters dropped). Caret goes to the end.
    pub fn setText(self: *LineEditor, bytes: []const u8) !void {
        self.buf.clear();
        self.caret = 0;
        self.anchor = 0;
        _ = try self.insert(bytes);
    }

    /// Insert at the caret, replacing any selection. Invalid UTF-8 is rejected
    /// whole; control characters are skipped. Returns true if the text changed.
    pub fn insert(self: *LineEditor, bytes: []const u8) !bool {
        if (!std.unicode.utf8ValidateSlice(bytes)) return false;
        var changed = false;
        var i: usize = 0;
        while (i < bytes.len) {
            // A run of printable bytes (control characters are single ASCII bytes).
            var j = i;
            while (j < bytes.len and bytes[j] >= 0x20 and bytes[j] != 0x7f) j += 1;
            if (j > i) {
                if (self.hasSelection()) _ = self.deleteSelection();
                try self.buf.insert(self.caret, bytes[i..j]);
                self.caret += j - i;
                self.anchor = self.caret;
                changed = true;
            }
            i = j + 1;
        }
        return changed;
    }

    /// Delete the selection, if any. Returns true if something was deleted.
    pub fn deleteSelection(self: *LineEditor) bool {
        if (!self.hasSelection()) return false;
        const r = self.selection();
        self.buf.delete(r.start, r.end - r.start);
        self.caret = r.start;
        self.anchor = r.start;
        return true;
    }

    pub fn deleteBackward(self: *LineEditor, by_word: bool) bool {
        if (self.deleteSelection()) return true;
        if (self.caret == 0) return false;
        const s = self.text();
        const start = if (by_word) wordLeft(s, self.caret) else prevBoundary(s, self.caret);
        self.buf.delete(start, self.caret - start);
        self.caret = start;
        self.anchor = start;
        return true;
    }

    pub fn deleteForward(self: *LineEditor, by_word: bool) bool {
        if (self.deleteSelection()) return true;
        const s = self.text();
        if (self.caret >= s.len) return false;
        const stop = if (by_word) wordRight(s, self.caret) else nextBoundary(s, self.caret);
        self.buf.delete(self.caret, stop - self.caret);
        return true;
    }

    fn moveTo(self: *LineEditor, pos: usize, extend: bool) void {
        self.caret = pos;
        if (!extend) self.anchor = pos;
    }

    pub fn moveLeft(self: *LineEditor, extend: bool, by_word: bool) void {
        // With a selection and no extend, collapse to its left edge.
        if (self.hasSelection() and !extend) return self.moveTo(self.selection().start, false);
        const s = self.text();
        self.moveTo(if (by_word) wordLeft(s, self.caret) else prevBoundary(s, self.caret), extend);
    }

    pub fn moveRight(self: *LineEditor, extend: bool, by_word: bool) void {
        if (self.hasSelection() and !extend) return self.moveTo(self.selection().end, false);
        const s = self.text();
        self.moveTo(if (by_word) wordRight(s, self.caret) else nextBoundary(s, self.caret), extend);
    }

    pub fn home(self: *LineEditor, extend: bool) void {
        self.moveTo(0, extend);
    }

    pub fn end(self: *LineEditor, extend: bool) void {
        self.moveTo(self.buf.len(), extend);
    }

    pub fn selectAll(self: *LineEditor) void {
        self.anchor = 0;
        self.caret = self.buf.len();
    }

    /// Place the caret at `pos` (clamped, snapped to a boundary).
    pub fn setCaret(self: *LineEditor, pos: usize, extend: bool) void {
        const s = self.text();
        var p = @min(pos, s.len);
        while (p > 0 and p < s.len and isContinuation(s[p])) p -= 1;
        self.moveTo(p, extend);
    }

    /// Select the word (or run of spaces/punctuation) around `pos`.
    pub fn selectWordAt(self: *LineEditor, pos: usize) void {
        const s = self.text();
        if (s.len == 0) return;
        const r = wordRangeAt(s, pos);
        self.anchor = r.start;
        self.caret = r.end;
    }
};

/// The word (or run of spaces/punctuation) containing `pos` in `s`. `s` must be
/// non-empty; `pos` is clamped to the last character.
pub fn wordRangeAt(s: []const u8, pos: usize) Range {
    var p = @min(pos, s.len - 1);
    while (p > 0 and isContinuation(s[p])) p -= 1;
    const cls = classAt(s, p);
    var a = p;
    while (a > 0) {
        const pb = prevBoundary(s, a);
        if (classAt(s, pb) != cls) break;
        a = pb;
    }
    var b = nextBoundary(s, p);
    while (b < s.len and classAt(s, b) == cls) b = nextBoundary(s, b);
    return .{ .start = a, .end = b };
}

/// Start of the word to the left: skip spaces, then one run of a class.
pub fn wordLeft(s: []const u8, pos: usize) usize {
    var p = pos;
    while (p > 0 and classAt(s, prevBoundary(s, p)) == .space) p = prevBoundary(s, p);
    if (p == 0) return 0;
    const cls = classAt(s, prevBoundary(s, p));
    while (p > 0 and classAt(s, prevBoundary(s, p)) == cls) p = prevBoundary(s, p);
    return p;
}

/// End of the word to the right: one run of a class, then trailing spaces.
pub fn wordRight(s: []const u8, pos: usize) usize {
    var p = pos;
    if (p >= s.len) return s.len;
    const cls = classAt(s, p);
    if (cls != .space) {
        while (p < s.len and classAt(s, p) == cls) p = nextBoundary(s, p);
    }
    while (p < s.len and classAt(s, p) == .space) p = nextBoundary(s, p);
    return p;
}

// ---- tests -----------------------------------------------------------------

const testing = std.testing;

fn editor(initial: []const u8) !LineEditor {
    var e = LineEditor.init(testing.allocator);
    try e.setText(initial);
    return e;
}

test "typing inserts at the caret and advances it" {
    var e = try editor("");
    defer e.deinit();
    try testing.expect(try e.insert("abc"));
    e.setCaret(1, false);
    try testing.expect(try e.insert("X"));
    try testing.expectEqualStrings("aXbc", e.text());
    try testing.expectEqual(@as(usize, 2), e.caret);
    try testing.expect(!e.hasSelection());
}

test "typing over a selection replaces it" {
    var e = try editor("hello world");
    defer e.deinit();
    e.setCaret(0, false);
    e.setCaret(5, true);
    try testing.expectEqualStrings("hello", e.selectedText());
    _ = try e.insert("bye");
    try testing.expectEqualStrings("bye world", e.text());
    try testing.expectEqual(@as(usize, 3), e.caret);
}

test "control characters and invalid UTF-8 are not inserted" {
    var e = try editor("");
    defer e.deinit();
    try testing.expect(try e.insert("a\nb\tc\x7f"));
    try testing.expectEqualStrings("abc", e.text());
    try testing.expect(!(try e.insert("\n\n")));
    try testing.expect(!(try e.insert("\xff\xfe")));
    try testing.expectEqualStrings("abc", e.text());
}

test "backspace and delete step over whole code points" {
    var e = try editor("a\u{e9}\u{4e2d}b"); // 1 + 2 + 3 + 1 bytes
    defer e.deinit();
    try testing.expectEqual(@as(usize, 7), e.caret);
    try testing.expect(e.deleteBackward(false)); // b
    try testing.expect(e.deleteBackward(false)); // the 3-byte char
    try testing.expectEqualStrings("a\u{e9}", e.text());
    e.home(false);
    try testing.expect(e.deleteForward(false)); // a
    try testing.expectEqualStrings("\u{e9}", e.text());
    try testing.expect(e.deleteForward(false));
    try testing.expect(!e.deleteForward(false));
    try testing.expect(!e.deleteBackward(false));
}

test "arrows move by code point; shift extends; collapsing uses the selection edge" {
    var e = try editor("a\u{e9}b");
    defer e.deinit();
    e.moveLeft(false, false);
    try testing.expectEqual(@as(usize, 3), e.caret);
    e.moveLeft(false, false);
    try testing.expectEqual(@as(usize, 1), e.caret); // stepped over the 2-byte char
    e.moveRight(true, false);
    e.moveRight(true, false);
    try testing.expectEqual(@as(usize, 1), e.selection().start);
    try testing.expectEqual(@as(usize, 4), e.selection().end);
    e.moveLeft(false, false); // collapse to the left edge
    try testing.expectEqual(@as(usize, 1), e.caret);
    try testing.expect(!e.hasSelection());
    e.moveRight(false, false);
    e.moveRight(false, false);
    e.moveRight(false, false); // at the end stays put
    try testing.expectEqual(@as(usize, 4), e.caret);
}

test "home, end, and select all" {
    var e = try editor("hello");
    defer e.deinit();
    e.home(true);
    try testing.expectEqualStrings("hello", e.selectedText());
    e.end(false);
    try testing.expect(!e.hasSelection());
    e.selectAll();
    try testing.expectEqualStrings("hello", e.selectedText());
    try testing.expect(e.deleteBackward(false)); // deletes the selection
    try testing.expectEqualStrings("", e.text());
}

test "word movement and word deletion" {
    var e = try editor("foo bar_baz  qux.x");
    defer e.deinit();
    e.home(false);
    e.moveRight(false, true);
    try testing.expectEqual(@as(usize, 4), e.caret); // past "foo "
    e.moveRight(false, true);
    try testing.expectEqual(@as(usize, 13), e.caret); // past "bar_baz  "
    e.moveRight(false, true);
    try testing.expectEqual(@as(usize, 16), e.caret); // past "qux", stopping at "."
    e.moveLeft(false, true);
    try testing.expectEqual(@as(usize, 13), e.caret);
    e.moveLeft(false, true);
    try testing.expectEqual(@as(usize, 4), e.caret);

    e.end(false);
    try testing.expect(e.deleteBackward(true)); // "x"
    try testing.expect(e.deleteBackward(true)); // "."
    try testing.expectEqualStrings("foo bar_baz  qux", e.text());
    e.setCaret(4, false);
    try testing.expect(e.deleteForward(true)); // "bar_baz  "
    try testing.expectEqualStrings("foo qux", e.text());
}

test "selectWordAt picks the word, spaces, or punctuation under the point" {
    var e = try editor("ab  cd.ef");
    defer e.deinit();
    e.selectWordAt(1);
    try testing.expectEqualStrings("ab", e.selectedText());
    e.selectWordAt(2);
    try testing.expectEqualStrings("  ", e.selectedText());
    e.selectWordAt(5);
    try testing.expectEqualStrings("cd", e.selectedText());
    e.selectWordAt(6);
    try testing.expectEqualStrings(".", e.selectedText());
    e.selectWordAt(100); // clamps to the last word
    try testing.expectEqualStrings("ef", e.selectedText());
}

test "setCaret snaps into code point boundaries and clamps" {
    var e = try editor("a\u{e9}b");
    defer e.deinit();
    e.setCaret(2, false); // inside the 2-byte char
    try testing.expectEqual(@as(usize, 1), e.caret);
    e.setCaret(999, false);
    try testing.expectEqual(@as(usize, 4), e.caret);
}

test "selectWordAt on empty text is a no-op" {
    var e = try editor("");
    defer e.deinit();
    e.selectWordAt(0);
    try testing.expect(!e.hasSelection());
}
