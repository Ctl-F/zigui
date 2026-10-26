//! Incremental syntax highlighting over a `Document`.
//!
//! The highlighter stores, for every line, the lexer state at the end of that
//! line (which is the next line's start state), plus a dirty flag. Tokens are
//! not stored: a line's spans are computed on demand from its text and its
//! start state, which is cheap for the few visible lines.
//!
//! Editing: `onChange` takes each `Document.Change` and splices the per-line
//! arrays to match (the lines an edit merged are replaced by the lines it
//! produced, all marked dirty). `ensureClean` relexes dirty lines in order; if
//! a relexed line ends in the state it ended in before, the following lines
//! are still right and relexing stops there (convergence). If the state
//! changed, the next line is marked dirty and so on, which is how opening a
//! block comment recolors everything below it, but only as far as it matters.
//! Lines below the viewport are not touched until something needs their state.

const std = @import("std");
const syntax = @import("syntax.zig");
const Document = @import("document.zig").Document;
const Change = @import("document.zig").Change;

const State = syntax.State;
const unknown: State = std.math.maxInt(State);

pub const Highlighter = struct {
    gpa: std.mem.Allocator,
    lang: *const syntax.Language,
    /// End state of each line; `unknown` where nothing is known yet.
    end_state: std.ArrayListUnmanaged(State) = .empty,
    dirty: std.ArrayListUnmanaged(bool) = .empty,
    /// Every line below this index is clean.
    min_dirty: usize = 0,
    /// Lines lexed so far (for tests and profiling).
    lexed: u64 = 0,

    pub fn init(gpa: std.mem.Allocator, lang: *const syntax.Language) Highlighter {
        return .{ .gpa = gpa, .lang = lang };
    }

    pub fn deinit(self: *Highlighter) void {
        self.end_state.deinit(self.gpa);
        self.dirty.deinit(self.gpa);
        self.* = undefined;
    }

    pub fn setLanguage(self: *Highlighter, lang: *const syntax.Language) void {
        self.lang = lang;
        self.invalidateAll();
    }

    /// Forget everything: all lines become dirty with unknown state.
    pub fn invalidateAll(self: *Highlighter) void {
        for (self.end_state.items) |*s| s.* = unknown;
        for (self.dirty.items) |*d| d.* = true;
        self.min_dirty = 0;
    }

    /// Resize to `line_count` lines, all dirty (used at load, and as a safety net
    /// if the arrays ever disagree with the document).
    pub fn reset(self: *Highlighter, line_count: usize) !void {
        try self.end_state.resize(self.gpa, line_count);
        try self.dirty.resize(self.gpa, line_count);
        self.invalidateAll();
    }

    /// Apply one document change. Changes must be applied in the order the
    /// document produced them.
    pub fn onChange(self: *Highlighter, change: Change) !void {
        const n = self.end_state.items.len;
        const s = change.start_line;
        const removed = change.removed_lines;
        const inserted = change.inserted_lines;
        if (s >= n or s + removed >= n) {
            // Out of sync with the document: start over.
            try self.reset(n);
            return;
        }
        // Lines [s, s + removed] merged into one, then split into inserted + 1.
        // The last new line corresponds to the last old one, so keep its old end
        // state: if it comes out the same, nothing below needs relexing.
        const old_last = self.end_state.items[s + removed];
        const new_len = inserted + 1;
        try self.end_state.replaceRange(self.gpa, s, removed + 1, &.{});
        try self.dirty.replaceRange(self.gpa, s, removed + 1, &.{});
        try self.end_state.ensureUnusedCapacity(self.gpa, new_len);
        try self.dirty.ensureUnusedCapacity(self.gpa, new_len);
        var i: usize = 0;
        while (i < new_len) : (i += 1) {
            self.end_state.insertAssumeCapacity(s + i, if (i + 1 == new_len) old_last else unknown);
            self.dirty.insertAssumeCapacity(s + i, true);
        }
        self.min_dirty = @min(self.min_dirty, s);
    }

    /// Bring every line before `upto` up to date, so the start state of line
    /// `upto` is known.
    pub fn ensureClean(self: *Highlighter, doc: *Document, upto: usize) !void {
        if (self.end_state.items.len != doc.lineCount()) try self.reset(doc.lineCount());
        const limit = @min(upto, self.end_state.items.len);
        while (true) {
            var j = self.min_dirty;
            while (j < limit and !self.dirty.items[j]) j += 1;
            if (j >= limit) {
                self.min_dirty = @max(self.min_dirty, limit);
                return;
            }
            const start: State = if (j == 0) 0 else self.end_state.items[j - 1];
            const text = try doc.lineText(j);
            const new = try syntax.lexLine(self.lang, start, text, null, self.gpa);
            self.lexed += 1;
            if (new != self.end_state.items[j]) {
                self.end_state.items[j] = new;
                if (j + 1 < self.dirty.items.len) self.dirty.items[j + 1] = true;
            }
            self.dirty.items[j] = false;
            self.min_dirty = j + 1;
        }
    }

    /// The lexer state at the start of `line`.
    pub fn startState(self: *Highlighter, doc: *Document, line: usize) !State {
        try self.ensureClean(doc, line);
        return if (line == 0) 0 else self.end_state.items[line - 1];
    }

    /// Fill `out` with the colored spans of `line` (cleared first).
    pub fn spansForLine(self: *Highlighter, doc: *Document, line: usize, out: *std.ArrayListUnmanaged(syntax.Span)) !void {
        out.clearRetainingCapacity();
        const start = try self.startState(doc, line);
        const text = try doc.lineText(line);
        _ = try syntax.lexLine(self.lang, start, text, out, self.gpa);
    }
};

// ---- tests -----------------------------------------------------------------

const testing = std.testing;
const Editor = @import("editor.zig").Editor;

/// Feed the document's pending changes to the highlighter, as the widget does.
fn sync(hl: *Highlighter, doc: *Document) !void {
    for (doc.changes.items) |c| try hl.onChange(c);
    doc.clearChanges();
}

fn fullStates(lang: *const syntax.Language, doc: *Document, out: *std.ArrayListUnmanaged(State)) !void {
    out.clearRetainingCapacity();
    var st: State = 0;
    for (0..doc.lineCount()) |i| {
        st = try syntax.lexLine(lang, st, try doc.lineText(i), null, testing.allocator);
        try out.append(testing.allocator, st);
    }
}

fn expectMatchesFullLex(hl: *Highlighter, doc: *Document) !void {
    var want: std.ArrayListUnmanaged(State) = .empty;
    defer want.deinit(testing.allocator);
    try fullStates(hl.lang, doc, &want);
    try hl.ensureClean(doc, doc.lineCount());
    try testing.expectEqual(want.items.len, hl.end_state.items.len);
    for (want.items, hl.end_state.items, 0..) |w, got, i| {
        if (w != got) {
            std.debug.print("state mismatch at line {d}: want {d}, got {d}\n", .{ i, w, got });
            return error.StateMismatch;
        }
    }
}

test "line states are computed lazily and only as far as asked" {
    var doc = try Document.initWithText(testing.allocator, "a\nb /* c\nd\ne */ f\ng\nh", false);
    defer doc.deinit();
    var hl = Highlighter.init(testing.allocator, &syntax.c);
    defer hl.deinit();
    try hl.reset(doc.lineCount());

    try testing.expectEqual(@as(State, 0), try hl.startState(&doc, 1));
    try testing.expectEqual(@as(u64, 1), hl.lexed); // only line 0 was needed
    try testing.expect(try hl.startState(&doc, 2) != 0); // inside the comment
    try testing.expect(try hl.startState(&doc, 3) != 0);
    try testing.expectEqual(@as(State, 0), try hl.startState(&doc, 4)); // closed on line 3
    try testing.expectEqual(@as(u64, 4), hl.lexed);
    _ = try hl.startState(&doc, 4); // cached
    try testing.expectEqual(@as(u64, 4), hl.lexed);
}

test "spans for a line use the carried-in state" {
    var doc = try Document.initWithText(testing.allocator, "int a; /* open\nstill comment\nclose */ int b;", false);
    defer doc.deinit();
    var hl = Highlighter.init(testing.allocator, &syntax.c);
    defer hl.deinit();
    try hl.reset(doc.lineCount());
    var spans: std.ArrayListUnmanaged(syntax.Span) = .empty;
    defer spans.deinit(testing.allocator);

    try hl.spansForLine(&doc, 1, &spans);
    try testing.expectEqual(@as(usize, 1), spans.items.len);
    try testing.expectEqual(syntax.TokenKind.comment, spans.items[0].kind);
    try testing.expectEqual(@as(u32, 13), spans.items[0].end);
    try hl.spansForLine(&doc, 2, &spans);
    try testing.expectEqual(syntax.TokenKind.comment, spans.items[0].kind);
    try testing.expectEqual(syntax.TokenKind.type, spans.items[1].kind); // "int" after the close
}

test "opening a block comment recolors the lines below; closing it restores them" {
    var ed = try Editor.initWithText(testing.allocator, "a\nb\nc\nd\ne", false);
    defer ed.deinit();
    var hl = Highlighter.init(testing.allocator, &syntax.c);
    defer hl.deinit();
    try hl.reset(ed.doc.lineCount());
    try hl.ensureClean(&ed.doc, 5);
    const before = hl.lexed;

    ed.setCaret(1, false); // end of "a"
    _ = try ed.typeText("/*", 0);
    try sync(&hl, &ed.doc);
    try expectMatchesFullLex(&hl, &ed.doc);
    try testing.expect(hl.end_state.items[1] != 0); // the comment is open below line 0
    try testing.expect(hl.end_state.items[4] != 0);

    _ = try ed.typeText("*/", 1);
    try sync(&hl, &ed.doc);
    try expectMatchesFullLex(&hl, &ed.doc);
    try testing.expectEqual(@as(State, 0), hl.end_state.items[4]);
    try testing.expect(hl.lexed > before);
}

test "an edit that keeps the line's end state relexes just that line (convergence)" {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(testing.allocator);
    for (0..2000) |i| {
        var line: [64]u8 = undefined;
        try buf.appendSlice(testing.allocator, try std.fmt.bufPrint(&line, "int v{d} = {d}; /* c */\n", .{ i, i }));
    }
    var ed = try Editor.initWithText(testing.allocator, buf.items, false);
    defer ed.deinit();
    var hl = Highlighter.init(testing.allocator, &syntax.c);
    defer hl.deinit();
    try hl.reset(ed.doc.lineCount());
    try hl.ensureClean(&ed.doc, ed.doc.lineCount());
    try testing.expectEqual(@as(u64, 2001), hl.lexed);
    const before = hl.lexed;

    ed.setCaret(ed.doc.lineStart(1000) + 4, false);
    _ = try ed.typeText("xyz", 0);
    try sync(&hl, &ed.doc);
    try hl.ensureClean(&ed.doc, ed.doc.lineCount());
    try testing.expectEqual(@as(u64, 1), hl.lexed - before); // one line, then converged

    // Inserting and deleting whole lines also converges quickly.
    ed.setCaret(ed.doc.lineStart(500), false);
    _ = try ed.typeText("// new line\n", 1000);
    try sync(&hl, &ed.doc);
    try hl.ensureClean(&ed.doc, ed.doc.lineCount());
    try testing.expect(hl.lexed - before < 6);
    try expectMatchesFullLex(&hl, &ed.doc);
}

test "inserted and removed lines shift the per-line arrays correctly" {
    var ed = try Editor.initWithText(testing.allocator, "one\ntwo\nthree\nfour", false);
    defer ed.deinit();
    var hl = Highlighter.init(testing.allocator, &syntax.c);
    defer hl.deinit();
    try hl.reset(ed.doc.lineCount());
    try hl.ensureClean(&ed.doc, 4);

    ed.setCaret(3, false);
    _ = try ed.typeText("\n/*\n\n", 0); // three new lines, the last of which opens a comment above "two"
    try sync(&hl, &ed.doc);
    try testing.expectEqual(ed.doc.lineCount(), hl.end_state.items.len);
    try expectMatchesFullLex(&hl, &ed.doc);

    ed.selectAll();
    _ = try ed.deleteSelections(10);
    try sync(&hl, &ed.doc);
    try testing.expectEqual(@as(usize, 1), hl.end_state.items.len);
    try expectMatchesFullLex(&hl, &ed.doc);

    try testing.expect(try ed.undo());
    try sync(&hl, &ed.doc);
    try expectMatchesFullLex(&hl, &ed.doc);
}

test "changing the language invalidates everything" {
    var doc = try Document.initWithText(testing.allocator, "/* x\n y */ int", false);
    defer doc.deinit();
    var hl = Highlighter.init(testing.allocator, &syntax.c);
    defer hl.deinit();
    try hl.reset(doc.lineCount());
    try testing.expect(try hl.startState(&doc, 1) != 0);
    hl.setLanguage(&syntax.plain);
    try testing.expectEqual(@as(State, 0), try hl.startState(&doc, 1)); // plain text has no comments
}

test "a mismatch with the document triggers a safe full reset" {
    var doc = try Document.initWithText(testing.allocator, "a\nb /*\nc", false);
    defer doc.deinit();
    var hl = Highlighter.init(testing.allocator, &syntax.c);
    defer hl.deinit();
    try hl.reset(1); // wrong size on purpose
    try testing.expect(try hl.startState(&doc, 2) != 0);
    try testing.expectEqual(@as(usize, 3), hl.end_state.items.len);
}

test "random edits: the incremental states always equal a full relex" {
    for ([_]u64{ 11, 22, 33, 0xFEED, 4242 }) |seed| {
        var ed = try Editor.initWithText(testing.allocator,
            \\#include <x.h>
            \\/* a block
            \\   comment */
            \\int main(void) {
            \\    return 0; // done
            \\}
            \\
        , false);
        defer ed.deinit();
        var hl = Highlighter.init(testing.allocator, &syntax.c);
        defer hl.deinit();
        try hl.reset(ed.doc.lineCount());

        var prng = std.Random.DefaultPrng.init(seed);
        const rand = prng.random();
        const snippets = [_][]const u8{ "/*", "*/", "\n", "x", " ", "\"", "//", "int ", "{}", "\n\n", "/* c */" };
        var now: u64 = 0;
        for (0..300) |step| {
            now += 2000;
            const len = ed.doc.len();
            switch (rand.uintLessThan(u8, 8)) {
                0, 1, 2 => {
                    ed.setCaret(rand.uintAtMost(usize, len), false);
                    _ = try ed.typeText(snippets[rand.uintLessThan(usize, snippets.len)], now);
                },
                3 => _ = try ed.deleteBackward(rand.boolean(), now),
                4 => _ = try ed.deleteForward(false, now),
                5 => _ = try ed.newline(now),
                6 => if (rand.boolean()) {
                    _ = try ed.undo();
                } else {
                    _ = try ed.redo();
                },
                else => {
                    ed.setCaret(rand.uintAtMost(usize, len), false);
                    ed.setCaret(rand.uintAtMost(usize, len), true);
                    _ = try ed.deleteSelections(now);
                },
            }
            try sync(&hl, &ed.doc);
            // Sometimes ask for a partial range first, to exercise laziness.
            if (step % 3 == 0) _ = try hl.startState(&ed.doc, rand.uintLessThan(usize, ed.doc.lineCount()));
            if (step % 7 == 0) try expectMatchesFullLex(&hl, &ed.doc);
        }
        try expectMatchesFullLex(&hl, &ed.doc);
    }
}
