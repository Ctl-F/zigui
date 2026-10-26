//! Editor core: a document, a selection list, and a reversible edit history.
//!
//! No UI, fonts, or platform: a widget drives it with key and mouse intents
//! and draws from `doc` and `sel`.
//!
//! Edits
//!   Every edit is a set of replace-ranges (one per selection) applied as
//!   commands through `Document.apply`. Commands carry their own text, so
//!   history never points into the piece table.
//! Transactions
//!   Commands from one user action form one undoable step. Consecutive edits
//!   of the same kind (typing, backspacing, deleting forward) join the open
//!   step; it closes on a pause (`pause_ms`), a cursor move or jump, a change
//!   of edit kind, a save, or `closeTransaction`. Each step records the
//!   selections before and after.
//! Cursor movement is not undoable. Undo restores the text and puts the
//! cursors back where the edit began; redo restores them as the edit left them.
//! Change records
//!   Each applied command (including undo and redo) appends to `doc.changes`;
//!   subscribers drain it once per frame.
//!
//! Error behavior: allocation failure while applying an edit may leave an
//! undo step partly applied; the history stays consistent with the text (every
//! applied command is recorded before the next one is attempted), so undo
//! still restores the original.

const std = @import("std");
const doc_mod = @import("document.zig");
const Document = doc_mod.Document;
const Command = doc_mod.Command;
const sel_mod = @import("selection.zig");
const Selection = sel_mod.Selection;
const SelectionSet = sel_mod.SelectionSet;
const line_editor = @import("../text/line_editor.zig");

pub const Error = doc_mod.Error;

pub const EditKind = enum { typing, delete_back, delete_fwd, other };

const Entry = struct {
    commands: std.ArrayListUnmanaged(Command) = .empty,
    before: []Selection,
    after: []Selection,
    kind: EditKind,
    last_ms: u64,
    id: u64,
};

/// Replace [start, end) with `text`. Edits passed to `replace` must be sorted
/// and must not overlap.
const Edit = struct { start: usize, end: usize, text: []const u8 };

const SelectionMode = enum {
    /// Collapse each selection to a caret after its replacement text.
    carets_after,
    /// Keep the selections, mapping their endpoints through the edits.
    map,
};

pub const Editor = struct {
    gpa: std.mem.Allocator,
    doc: Document,
    sel: SelectionSet,

    undo_stack: std.ArrayListUnmanaged(Entry) = .empty,
    redo_stack: std.ArrayListUnmanaged(Entry) = .empty,
    /// Whether the top undo entry may absorb the next edit.
    merge_ok: bool = false,
    next_id: u64 = 1,
    /// Entry id that matches the file on disk (0 = as opened); null if unreachable.
    saved_id: ?u64 = 0,

    pause_ms: u64 = 1000,
    tab_width: usize = 4,
    auto_indent: bool = true,

    pub fn init(gpa: std.mem.Allocator) Editor {
        return fromDocument(gpa, Document.init(gpa));
    }

    /// Open `bytes` as the file contents (borrowed unless `owned`).
    pub fn initWithText(gpa: std.mem.Allocator, bytes: []const u8, owned: bool) !Editor {
        return fromDocument(gpa, try Document.initWithText(gpa, bytes, owned));
    }

    fn fromDocument(gpa: std.mem.Allocator, doc: Document) Editor {
        var e: Editor = .{ .gpa = gpa, .doc = doc, .sel = SelectionSet.init(gpa) };
        e.sel.setSingle(0, 0) catch {};
        return e;
    }

    pub fn deinit(self: *Editor) void {
        self.clearStack(&self.undo_stack);
        self.clearStack(&self.redo_stack);
        self.undo_stack.deinit(self.gpa);
        self.redo_stack.deinit(self.gpa);
        self.sel.deinit();
        self.doc.deinit();
        self.* = undefined;
    }

    fn freeEntry(self: *Editor, e: *Entry) void {
        for (e.commands.items) |c| c.deinit(self.gpa);
        e.commands.deinit(self.gpa);
        self.gpa.free(e.before);
        self.gpa.free(e.after);
    }

    fn clearStack(self: *Editor, stack: *std.ArrayListUnmanaged(Entry)) void {
        for (stack.items) |*e| self.freeEntry(e);
        stack.clearRetainingCapacity();
    }

    // ---- state -----------------------------------------------------------------------

    pub fn canUndo(self: *const Editor) bool {
        return self.undo_stack.items.len > 0;
    }

    pub fn canRedo(self: *const Editor) bool {
        return self.redo_stack.items.len > 0;
    }

    fn currentId(self: *const Editor) u64 {
        const n = self.undo_stack.items.len;
        return if (n == 0) 0 else self.undo_stack.items[n - 1].id;
    }

    /// True if the text differs from the last `markSaved` (or from as opened).
    pub fn isModified(self: *const Editor) bool {
        return self.saved_id == null or self.saved_id.? != self.currentId();
    }

    pub fn markSaved(self: *Editor) void {
        self.saved_id = self.currentId();
        self.merge_ok = false; // typing after a save starts a new step
    }

    /// Stop the open step from absorbing further edits.
    pub fn closeTransaction(self: *Editor) void {
        self.merge_ok = false;
    }

    /// The caret that scrolling and Escape follow.
    pub fn primaryHead(self: *const Editor) usize {
        return self.sel.primary().head;
    }

    // ---- the replace pipeline ---------------------------------------------------------

    fn cloneSel(self: *Editor) Error![]Selection {
        return self.sel.clone(self.gpa);
    }

    /// Map an old offset through ascending, non-overlapping edits.
    fn mapOffset(edits: []const Edit, offset: usize) usize {
        var delta: isize = 0;
        for (edits) |e| {
            if (e.end <= offset) {
                delta += @as(isize, @intCast(e.text.len)) - @as(isize, @intCast(e.end - e.start));
            } else if (e.start < offset) {
                // Inside a replaced range: land after the replacement text.
                return @intCast(@as(isize, @intCast(e.start + e.text.len)) + delta);
            } else break;
        }
        return @intCast(@as(isize, @intCast(offset)) + delta);
    }

    fn replace(self: *Editor, kind: EditKind, now: u64, edits: []const Edit, mode: SelectionMode) Error!bool {
        var any = false;
        for (edits) |e| any = any or e.end > e.start or e.text.len > 0;
        if (!any) return false;

        const can_merge = self.merge_ok and kind != .other and self.undo_stack.items.len > 0 and
            self.undo_stack.items[self.undo_stack.items.len - 1].kind == kind and
            now -% self.undo_stack.items[self.undo_stack.items.len - 1].last_ms <= self.pause_ms;

        // New selections, computed before the text changes.
        var new_sels = try self.gpa.alloc(Selection, if (mode == .carets_after) edits.len else self.sel.items.items.len);
        defer self.gpa.free(new_sels);
        switch (mode) {
            .carets_after => {
                var delta: isize = 0;
                for (edits, 0..) |e, i| {
                    const at: isize = @as(isize, @intCast(e.start + e.text.len)) + delta;
                    new_sels[i] = Selection.caret(@intCast(at));
                    delta += @as(isize, @intCast(e.text.len)) - @as(isize, @intCast(e.end - e.start));
                }
            },
            .map => for (self.sel.items.items, 0..) |s, i| {
                new_sels[i] = .{
                    .anchor = mapOffset(edits, s.anchor),
                    .head = mapOffset(edits, s.head),
                    .primary = s.primary,
                };
            },
        }

        var entry_ptr: *Entry = undefined;
        if (can_merge) {
            entry_ptr = &self.undo_stack.items[self.undo_stack.items.len - 1];
        } else {
            // A new step discards the redo history.
            if (self.saved_id) |sid| {
                for (self.redo_stack.items) |e| {
                    if (e.id == sid) self.saved_id = null;
                }
            }
            self.clearStack(&self.redo_stack);
            const before = try self.cloneSel();
            errdefer self.gpa.free(before);
            const after = try self.gpa.dupe(Selection, before);
            errdefer self.gpa.free(after);
            try self.undo_stack.append(self.gpa, .{ .before = before, .after = after, .kind = kind, .last_ms = now, .id = self.next_id });
            self.next_id += 1;
            entry_ptr = &self.undo_stack.items[self.undo_stack.items.len - 1];
        }
        const entry = entry_ptr;
        try entry.commands.ensureUnusedCapacity(self.gpa, edits.len * 2);

        // Apply back to front so earlier offsets stay valid.
        var i = edits.len;
        while (i > 0) {
            i -= 1;
            const e = edits[i];
            if (e.end > e.start) {
                const cmd = try self.doc.makeDelete(e.start, e.end);
                self.doc.apply(cmd.op()) catch |err| {
                    cmd.deinit(self.gpa);
                    return err;
                };
                entry.commands.appendAssumeCapacity(cmd);
            }
            if (e.text.len > 0) {
                const cmd = try self.doc.makeInsert(e.start, e.text);
                self.doc.apply(cmd.op()) catch |err| {
                    cmd.deinit(self.gpa);
                    return err;
                };
                entry.commands.appendAssumeCapacity(cmd);
            }
        }

        const after = try self.gpa.dupe(Selection, new_sels);
        self.gpa.free(entry.after);
        entry.after = after;
        entry.last_ms = now;
        try self.sel.assign(new_sels);
        self.sel.normalize();
        self.merge_ok = true;
        return true;
    }

    // ---- undo / redo ---------------------------------------------------------------------

    pub fn undo(self: *Editor) Error!bool {
        if (self.undo_stack.items.len == 0) return false;
        self.merge_ok = false;
        try self.redo_stack.ensureUnusedCapacity(self.gpa, 1);
        var entry = self.undo_stack.pop().?;
        var i = entry.commands.items.len;
        while (i > 0) {
            i -= 1;
            self.doc.apply(entry.commands.items[i].op().inverse()) catch |err| {
                // Put back what is left so history still matches the text.
                entry.commands.shrinkRetainingCapacity(i + 1);
                self.undo_stack.appendAssumeCapacity(entry);
                return err;
            };
        }
        try self.sel.assign(entry.before);
        self.sel.normalize();
        self.redo_stack.appendAssumeCapacity(entry);
        return true;
    }

    pub fn redo(self: *Editor) Error!bool {
        if (self.redo_stack.items.len == 0) return false;
        self.merge_ok = false;
        try self.undo_stack.ensureUnusedCapacity(self.gpa, 1);
        var entry = self.redo_stack.pop().?;
        for (entry.commands.items, 0..) |c, i| {
            self.doc.apply(c.op()) catch |err| {
                // Undo the part already redone so the entry is whole again.
                var j = i;
                while (j > 0) {
                    j -= 1;
                    self.doc.apply(entry.commands.items[j].op().inverse()) catch {};
                }
                self.redo_stack.appendAssumeCapacity(entry);
                return err;
            };
        }
        try self.sel.assign(entry.after);
        self.sel.normalize();
        self.undo_stack.appendAssumeCapacity(entry);
        return true;
    }

    // ---- editing intents -----------------------------------------------------------------

    fn isPlainTyping(text: []const u8) bool {
        if (text.len > 16) return false;
        for (text) |c| if (c < 0x20 or c == 0x7f) return false;
        return true;
    }

    /// Type (or paste) `text` at every selection, replacing selected text.
    /// Control characters other than newline are dropped.
    pub fn typeText(self: *Editor, text: []const u8, now: u64) Error!bool {
        if (text.len == 0) return false;
        const kind: EditKind = if (isPlainTyping(text)) .typing else .other;
        const edits = try self.gpa.alloc(Edit, self.sel.items.items.len);
        defer self.gpa.free(edits);
        for (self.sel.items.items, edits) |s, *e| e.* = .{ .start = s.start(), .end = s.end(), .text = text };
        return self.replace(kind, now, edits, .carets_after);
    }

    /// Paste: like `typeText`, but if the text has exactly as many lines as
    /// there are cursors, line i goes to cursor i.
    pub fn paste(self: *Editor, text: []const u8, now: u64) Error!bool {
        const n = self.sel.items.items.len;
        if (n > 1) {
            var lines: usize = 1;
            for (text) |c| lines += @intFromBool(c == '\n');
            if (lines == n) {
                const edits = try self.gpa.alloc(Edit, n);
                defer self.gpa.free(edits);
                var it = std.mem.splitScalar(u8, text, '\n');
                for (self.sel.items.items, edits) |s, *e| {
                    var part = it.next().?;
                    if (part.len > 0 and part[part.len - 1] == '\r') part = part[0 .. part.len - 1];
                    e.* = .{ .start = s.start(), .end = s.end(), .text = part };
                }
                return self.replace(.other, now, edits, .carets_after);
            }
        }
        const edits = try self.gpa.alloc(Edit, n);
        defer self.gpa.free(edits);
        for (self.sel.items.items, edits) |s, *e| e.* = .{ .start = s.start(), .end = s.end(), .text = text };
        return self.replace(.other, now, edits, .carets_after);
    }

    /// Enter: a newline at each cursor, keeping the current line's indentation
    /// when `auto_indent` is on.
    pub fn newline(self: *Editor, now: u64) Error!bool {
        const n = self.sel.items.items.len;
        const edits = try self.gpa.alloc(Edit, n);
        defer self.gpa.free(edits);
        var texts: std.ArrayListUnmanaged(u8) = .empty;
        defer texts.deinit(self.gpa);
        const spans = try self.gpa.alloc([2]usize, n);
        defer self.gpa.free(spans);

        for (self.sel.items.items, 0..) |s, i| {
            const begin = texts.items.len;
            try texts.append(self.gpa, '\n');
            if (self.auto_indent) {
                const line = self.doc.lineOfOffset(s.start());
                const ls = self.doc.lineStart(line);
                const upto = try self.doc.range(ls, s.start());
                var w: usize = 0;
                while (w < upto.len and (upto[w] == ' ' or upto[w] == '\t')) w += 1;
                try texts.appendSlice(self.gpa, upto[0..w]);
            }
            spans[i] = .{ begin, texts.items.len };
            edits[i] = .{ .start = s.start(), .end = s.end(), .text = "" };
        }
        for (edits, spans) |*e, sp| e.text = texts.items[sp[0]..sp[1]];
        return self.replace(.other, now, edits, .carets_after);
    }

    const spaces: [32]u8 = @splat(' ');

    /// Tab: spaces to the next tab stop at each caret. With a selection that
    /// spans lines, indents those lines instead.
    pub fn tab(self: *Editor, now: u64) Error!bool {
        for (self.sel.items.items) |s| {
            if (!s.isEmpty() and self.doc.lineOfOffset(s.start()) != self.doc.lineOfOffset(s.end())) {
                return self.indentLines(false, now);
            }
        }
        const n = self.sel.items.items.len;
        const edits = try self.gpa.alloc(Edit, n);
        defer self.gpa.free(edits);
        for (self.sel.items.items, edits) |s, *e| {
            const col = try self.doc.columnOf(s.start());
            const w = @min(self.tab_width - col % self.tab_width, spaces.len);
            e.* = .{ .start = s.start(), .end = s.end(), .text = spaces[0..w] };
        }
        return self.replace(.other, now, edits, .carets_after);
    }

    /// Shift+Tab: remove up to one tab width of leading whitespace from every
    /// line the selections touch.
    pub fn outdent(self: *Editor, now: u64) Error!bool {
        return self.indentLines(true, now);
    }

    fn indentLines(self: *Editor, outdent_: bool, now: u64) Error!bool {
        var edits: std.ArrayListUnmanaged(Edit) = .empty;
        defer edits.deinit(self.gpa);
        var last_line: ?usize = null;
        for (self.sel.items.items) |s| {
            var first = self.doc.lineOfOffset(s.start());
            var last = self.doc.lineOfOffset(s.end());
            // A selection ending at a line start does not include that line.
            if (!s.isEmpty() and last > first and self.doc.lineStart(last) == s.end()) last -= 1;
            if (last_line) |l| {
                if (first <= l) first = l + 1;
            }
            var line = first;
            while (line <= last) : (line += 1) {
                const ls = self.doc.lineStart(line);
                if (!outdent_) {
                    if (self.doc.lineEnd(line) > ls) try edits.append(self.gpa, .{ .start = ls, .end = ls, .text = spaces[0..@min(self.tab_width, spaces.len)] });
                } else {
                    const lead = try self.doc.range(ls, self.doc.lineEnd(line));
                    var n: usize = 0;
                    if (lead.len > 0 and lead[0] == '\t') {
                        n = 1;
                    } else while (n < lead.len and n < self.tab_width and lead[n] == ' ') n += 1;
                    if (n > 0) try edits.append(self.gpa, .{ .start = ls, .end = ls + n, .text = "" });
                }
            }
            last_line = last;
        }
        return self.replace(.other, now, edits.items, .map);
    }

    fn mergeRanges(list: *std.ArrayListUnmanaged(Edit)) void {
        if (list.items.len < 2) return;
        var out: usize = 0;
        for (list.items[1..]) |e| {
            const cur = &list.items[out];
            if (e.start <= cur.end) {
                cur.end = @max(cur.end, e.end);
            } else {
                out += 1;
                list.items[out] = e;
            }
        }
        list.shrinkRetainingCapacity(out + 1);
    }

    pub fn deleteBackward(self: *Editor, by_word: bool, now: u64) Error!bool {
        var edits: std.ArrayListUnmanaged(Edit) = .empty;
        defer edits.deinit(self.gpa);
        for (self.sel.items.items) |s| {
            if (!s.isEmpty()) {
                try edits.append(self.gpa, .{ .start = s.start(), .end = s.end(), .text = "" });
            } else if (s.head > 0) {
                const from = if (by_word) try self.wordLeft(s.head) else self.doc.prevBoundary(s.head);
                try edits.append(self.gpa, .{ .start = from, .end = s.head, .text = "" });
            }
        }
        mergeRanges(&edits);
        return self.replace(.delete_back, now, edits.items, .carets_after);
    }

    pub fn deleteForward(self: *Editor, by_word: bool, now: u64) Error!bool {
        var edits: std.ArrayListUnmanaged(Edit) = .empty;
        defer edits.deinit(self.gpa);
        for (self.sel.items.items) |s| {
            if (!s.isEmpty()) {
                try edits.append(self.gpa, .{ .start = s.start(), .end = s.end(), .text = "" });
            } else if (s.head < self.doc.len()) {
                const to = if (by_word) try self.wordRight(s.head) else self.doc.nextBoundary(s.head);
                try edits.append(self.gpa, .{ .start = s.head, .end = to, .text = "" });
            }
        }
        mergeRanges(&edits);
        return self.replace(.delete_fwd, now, edits.items, .carets_after);
    }

    /// Delete the selected text (cut). Does nothing for empty selections.
    pub fn deleteSelections(self: *Editor, now: u64) Error!bool {
        var edits: std.ArrayListUnmanaged(Edit) = .empty;
        defer edits.deinit(self.gpa);
        for (self.sel.items.items) |s| {
            if (!s.isEmpty()) try edits.append(self.gpa, .{ .start = s.start(), .end = s.end(), .text = "" });
        }
        return self.replace(.other, now, edits.items, .carets_after);
    }

    /// The selected text, one selection per line (for copy). Caller frees.
    pub fn selectedText(self: *Editor, gpa: std.mem.Allocator) Error![]u8 {
        var out: std.ArrayListUnmanaged(u8) = .empty;
        errdefer out.deinit(gpa);
        var first = true;
        for (self.sel.items.items) |s| {
            if (s.isEmpty()) continue;
            if (!first) try out.append(gpa, '\n');
            first = false;
            try self.doc.table.readInto(s.start(), s.end(), &out, gpa);
        }
        return out.toOwnedSlice(gpa);
    }

    pub fn hasSelectedText(self: *const Editor) bool {
        for (self.sel.items.items) |s| if (!s.isEmpty()) return true;
        return false;
    }

    // ---- motion ------------------------------------------------------------------------------

    fn wordLeft(self: *Editor, offset: usize) Error!usize {
        const line = self.doc.lineOfOffset(offset);
        const ls = self.doc.lineStart(line);
        if (offset == ls) return self.doc.prevBoundary(offset);
        const s = try self.doc.range(ls, self.doc.lineEnd(line));
        return ls + line_editor.wordLeft(s, offset - ls);
    }

    fn wordRight(self: *Editor, offset: usize) Error!usize {
        const line = self.doc.lineOfOffset(offset);
        const le = self.doc.lineEnd(line);
        if (offset >= le) return self.doc.nextBoundary(offset);
        const ls = self.doc.lineStart(line);
        const s = try self.doc.range(ls, le);
        return ls + line_editor.wordRight(s, offset - ls);
    }

    fn finishMove(self: *Editor) void {
        self.sel.normalize();
        self.merge_ok = false;
    }

    fn setHead(s: *Selection, head: usize, extend: bool) void {
        s.head = head;
        if (!extend) s.anchor = head;
        s.goal = Selection.unset;
    }

    pub fn moveLeft(self: *Editor, extend: bool, by_word: bool) Error!void {
        for (self.sel.items.items) |*s| {
            if (!s.isEmpty() and !extend) {
                setHead(s, s.start(), false);
            } else {
                const to = if (by_word) try self.wordLeft(s.head) else self.doc.prevBoundary(s.head);
                setHead(s, to, extend);
            }
        }
        self.finishMove();
    }

    pub fn moveRight(self: *Editor, extend: bool, by_word: bool) Error!void {
        for (self.sel.items.items) |*s| {
            if (!s.isEmpty() and !extend) {
                setHead(s, s.end(), false);
            } else {
                const to = if (by_word) try self.wordRight(s.head) else self.doc.nextBoundary(s.head);
                setHead(s, to, extend);
            }
        }
        self.finishMove();
    }

    /// Move up (negative) or down (positive) by `lines`. Remembers the column
    /// so a run of vertical moves returns to it across short lines. Moving up
    /// from the first line goes to the start, down from the last to the end.
    pub fn moveVertical(self: *Editor, lines: isize, extend: bool) Error!void {
        const last = self.doc.lineCount() - 1;
        for (self.sel.items.items) |*s| {
            const line = self.doc.lineOfOffset(s.head);
            const goal = if (s.goal != Selection.unset) s.goal else try self.doc.columnOf(s.head);
            const target: isize = @as(isize, @intCast(line)) + lines;
            var head: usize = undefined;
            if (target < 0) {
                head = 0;
            } else if (target > @as(isize, @intCast(last))) {
                head = self.doc.len();
            } else {
                head = try self.doc.offsetAtColumn(@intCast(target), goal);
            }
            s.head = head;
            if (!extend) s.anchor = head;
            s.goal = goal;
        }
        self.finishMove();
    }

    /// Home: first non-blank character, or the line start if already there.
    pub fn moveToLineStart(self: *Editor, extend: bool, smart: bool) Error!void {
        for (self.sel.items.items) |*s| {
            const line = self.doc.lineOfOffset(s.head);
            const ls = self.doc.lineStart(line);
            var target = ls;
            if (smart) {
                const body = try self.doc.range(ls, self.doc.lineEnd(line));
                var w: usize = 0;
                while (w < body.len and (body[w] == ' ' or body[w] == '\t')) w += 1;
                if (s.head != ls + w) target = ls + w;
            }
            setHead(s, target, extend);
        }
        self.finishMove();
    }

    pub fn moveToLineEnd(self: *Editor, extend: bool) Error!void {
        for (self.sel.items.items) |*s| {
            setHead(s, self.doc.lineEnd(self.doc.lineOfOffset(s.head)), extend);
        }
        self.finishMove();
    }

    pub fn moveToDocStart(self: *Editor, extend: bool) void {
        self.sel.assign(&.{.{ .anchor = if (extend) self.sel.primary().anchor else 0, .head = 0, .primary = true }}) catch return;
        self.finishMove();
    }

    pub fn moveToDocEnd(self: *Editor, extend: bool) void {
        const end = self.doc.len();
        self.sel.assign(&.{.{ .anchor = if (extend) self.sel.primary().anchor else end, .head = end, .primary = true }}) catch return;
        self.finishMove();
    }

    pub fn selectAll(self: *Editor) void {
        self.sel.assign(&.{.{ .anchor = 0, .head = self.doc.len(), .primary = true }}) catch return;
        self.finishMove();
    }

    /// Mouse: put a single caret at `offset`, or extend the primary selection to it.
    pub fn setCaret(self: *Editor, offset: usize, extend: bool) void {
        const o = @min(offset, self.doc.len());
        const anchor = if (extend) self.sel.primary().anchor else o;
        self.sel.assign(&.{.{ .anchor = anchor, .head = o, .primary = true }}) catch return;
        self.finishMove();
    }

    /// Alt+click: add another caret.
    pub fn addCaret(self: *Editor, offset: usize) void {
        self.sel.add(Selection.caret(@min(offset, self.doc.len()))) catch return;
        self.finishMove();
    }

    /// Drag with several cursors: move the primary selection's head.
    pub fn dragPrimaryTo(self: *Editor, offset: usize) void {
        const idx = self.sel.primaryIndex();
        self.sel.items.items[idx].head = @min(offset, self.doc.len());
        self.sel.items.items[idx].goal = Selection.unset;
        self.finishMove();
    }

    /// Add a caret one line above/below the primary cursor, same column.
    pub fn addCursorVertical(self: *Editor, delta: isize) Error!void {
        const p = self.sel.primary();
        const line = self.doc.lineOfOffset(p.head);
        const target: isize = @as(isize, @intCast(line)) + delta;
        if (target < 0 or target >= @as(isize, @intCast(self.doc.lineCount()))) return;
        const col = if (p.goal != Selection.unset) p.goal else try self.doc.columnOf(p.head);
        const off = try self.doc.offsetAtColumn(@intCast(target), col);
        try self.sel.add(.{ .anchor = off, .head = off, .goal = col });
        self.finishMove();
    }

    pub fn selectWordAt(self: *Editor, offset: usize) Error!void {
        const line = self.doc.lineOfOffset(offset);
        const ls = self.doc.lineStart(line);
        const s = try self.doc.range(ls, self.doc.lineEnd(line));
        if (s.len == 0) return self.setCaret(offset, false);
        const r = line_editor.wordRangeAt(s, offset - ls);
        self.sel.assign(&.{.{ .anchor = ls + r.start, .head = ls + r.end, .primary = true }}) catch return;
        self.finishMove();
    }

    /// Select the whole line (including its terminator).
    pub fn selectLineAt(self: *Editor, offset: usize) void {
        const line = self.doc.lineOfOffset(offset);
        const start = self.doc.lineStart(line);
        const end = if (line + 1 < self.doc.lineCount()) self.doc.lineStart(line + 1) else self.doc.len();
        self.sel.assign(&.{.{ .anchor = start, .head = end, .primary = true }}) catch return;
        self.finishMove();
    }

    /// Escape: keep only the primary selection, as a caret if you like.
    pub fn collapseToPrimary(self: *Editor) void {
        const p = self.sel.primary();
        self.sel.assign(&.{.{ .anchor = p.head, .head = p.head, .primary = true }}) catch return;
        self.finishMove();
    }
};

// ---- tests -----------------------------------------------------------------

const testing = std.testing;

fn allText(e: *Editor) ![]u8 {
    return e.doc.textAlloc(testing.allocator, 0, e.doc.len());
}

fn expectText(e: *Editor, expected: []const u8) !void {
    const s = try allText(e);
    defer testing.allocator.free(s);
    try testing.expectEqualStrings(expected, s);
}

fn carets(e: *Editor, at: []const usize) !void {
    try testing.expectEqual(at.len, e.sel.items.items.len);
    for (at, e.sel.items.items) |want, got| {
        try testing.expectEqual(want, got.head);
        try testing.expect(got.isEmpty());
    }
}

fn editorWith(s: []const u8) !Editor {
    return Editor.initWithText(testing.allocator, s, false);
}

test "typing inserts at the caret and groups into one undo step" {
    var e = Editor.init(testing.allocator);
    defer e.deinit();
    for ("hello", 0..) |c, i| _ = try e.typeText(&.{c}, 100 + i * 50);
    try expectText(&e, "hello");
    try carets(&e, &.{5});
    try testing.expectEqual(@as(usize, 1), e.undo_stack.items.len);

    try testing.expect(try e.undo());
    try expectText(&e, "");
    try carets(&e, &.{0}); // the cursor goes back to where the edit began
    try testing.expect(try e.redo());
    try expectText(&e, "hello");
    try carets(&e, &.{5});
    try testing.expect(!try e.redo());
}

test "a pause, a cursor move, or a different edit kind starts a new step" {
    var e = Editor.init(testing.allocator);
    defer e.deinit();
    _ = try e.typeText("a", 0);
    _ = try e.typeText("b", 500);
    _ = try e.typeText("c", 500 + e.pause_ms + 1); // paused: new step
    try testing.expectEqual(@as(usize, 2), e.undo_stack.items.len);

    try e.moveLeft(false, false); // a cursor move closes the step
    _ = try e.typeText("d", 2000);
    try testing.expectEqual(@as(usize, 3), e.undo_stack.items.len);

    _ = try e.deleteBackward(false, 2010); // different kind
    try testing.expectEqual(@as(usize, 4), e.undo_stack.items.len);
    _ = try e.deleteBackward(false, 2020); // same kind joins
    try testing.expectEqual(@as(usize, 4), e.undo_stack.items.len);
    // "abc", caret moved to 2, typed d -> "abdc"; two backspaces remove d, then b.
    try expectText(&e, "ac");
}

test "backspace and delete work on whole characters and join" {
    var e = try editorWith("a\u{e9}\u{4e2d}b");
    defer e.deinit();
    e.moveToDocEnd(false);
    _ = try e.deleteBackward(false, 0);
    _ = try e.deleteBackward(false, 1);
    try expectText(&e, "a\u{e9}");
    try testing.expectEqual(@as(usize, 1), e.undo_stack.items.len);
    try e.moveToLineStart(false, false);
    _ = try e.deleteForward(false, 2);
    try expectText(&e, "\u{e9}");
    try testing.expect(!try e.deleteBackward(false, 3)); // at the start: nothing to do
    try testing.expect(try e.undo());
    try expectText(&e, "a\u{e9}");
    try testing.expect(try e.undo());
    try expectText(&e, "a\u{e9}\u{4e2d}b");
    try testing.expect(!try e.undo());
}

test "typing over a selection replaces it, and undo brings the selection back" {
    var e = try editorWith("hello world");
    defer e.deinit();
    e.setCaret(0, false);
    e.setCaret(5, true);
    _ = try e.typeText("HOWDY", 0);
    try expectText(&e, "HOWDY world");
    try carets(&e, &.{5});
    try testing.expect(try e.undo());
    try expectText(&e, "hello world");
    try testing.expectEqual(@as(usize, 0), e.sel.items.items[0].start());
    try testing.expectEqual(@as(usize, 5), e.sel.items.items[0].end());
}

test "multi-cursor typing and deleting, with correct caret positions" {
    var e = try editorWith("one\ntwo\nthree");
    defer e.deinit();
    e.setCaret(3, false);
    e.addCaret(7);
    e.addCaret(13);
    try testing.expectEqual(@as(usize, 3), e.sel.items.items.len);
    _ = try e.typeText("!", 0);
    try expectText(&e, "one!\ntwo!\nthree!");
    try carets(&e, &.{ 4, 9, 16 });
    _ = try e.deleteBackward(false, 1);
    try expectText(&e, "one\ntwo\nthree");
    try carets(&e, &.{ 3, 7, 13 });
    // One undo step for the whole multi-cursor typing run (typing and backspace are different kinds).
    try testing.expect(try e.undo());
    try expectText(&e, "one!\ntwo!\nthree!");
    try testing.expect(try e.undo());
    try expectText(&e, "one\ntwo\nthree");
    try testing.expectEqual(@as(usize, 3), e.sel.items.items.len);
}

test "adjacent carets deleting backward do not corrupt each other" {
    var e = try editorWith("abcdef");
    defer e.deinit();
    e.setCaret(2, false);
    e.addCaret(3);
    e.addCaret(4);
    _ = try e.deleteBackward(false, 0);
    try expectText(&e, "aef");
    try carets(&e, &.{1}); // the three deletions merged into one range
}

test "newline keeps indentation; Enter in the middle splits the line" {
    var e = try editorWith("    if (x) {");
    defer e.deinit();
    e.moveToDocEnd(false);
    _ = try e.newline(0);
    try expectText(&e, "    if (x) {\n    ");
    try carets(&e, &.{17});
    _ = try e.typeText("y", 1);
    e.setCaret(6, false);
    _ = try e.newline(2);
    try expectText(&e, "    if\n     (x) {\n    y"); // split after "if": new line gets the 4-space indent
    e.auto_indent = false;
    e.moveToDocEnd(false);
    _ = try e.newline(3);
    try testing.expectEqual(@as(usize, 4), e.doc.lineCount());
    try testing.expectEqualStrings("", try e.doc.lineText(3));
}

test "tab inserts to the next tab stop; selections spanning lines indent and outdent" {
    var e = try editorWith("ab\ncd\nef");
    defer e.deinit();
    e.setCaret(1, false);
    _ = try e.tab(0); // column 1 -> next stop at 4: three spaces
    try expectText(&e, "a   b\ncd\nef");

    e.setCaret(0, false);
    e.setCaret(e.doc.lineStart(2) + 1, true);
    _ = try e.tab(1);
    try expectText(&e, "    a   b\n    cd\n    ef");
    // The selection still covers the same text.
    try testing.expectEqualStrings("a   b\n    cd\n    e", try e.doc.range(e.sel.items.items[0].start(), e.sel.items.items[0].end()));
    _ = try e.outdent(2);
    try expectText(&e, "a   b\ncd\nef");
    try testing.expect(!try e.outdent(3)); // nothing left to remove: no edit, no history entry
    try testing.expect(try e.undo()); // undoes the outdent
    try expectText(&e, "    a   b\n    cd\n    ef");
}

test "paste: one text everywhere, or one line per cursor when the counts match" {
    var e = try editorWith("a\nb\nc");
    defer e.deinit();
    e.setCaret(1, false);
    e.addCaret(3);
    e.addCaret(5);
    _ = try e.paste("X\nY\nZ", 0);
    try expectText(&e, "aX\nbY\ncZ");
    _ = try e.paste("-", 1); // one value into all three cursors
    try expectText(&e, "aX-\nbY-\ncZ-");
    _ = try e.paste("1\n2", 2); // line count does not match: whole text at each
    try testing.expectEqual(@as(usize, 3), e.sel.items.items.len);
    const all = try allText(&e);
    defer testing.allocator.free(all);
    try testing.expectEqual(@as(usize, 3), std.mem.count(u8, all, "1\n2"));
}

test "selected text joins selections with newlines; cut deletes them" {
    var e = try editorWith("alpha beta gamma");
    defer e.deinit();
    e.setCaret(0, false);
    e.setCaret(5, true);
    try e.sel.add(.{ .anchor = 11, .head = 16 });
    e.sel.normalize();
    const copy = try e.selectedText(testing.allocator);
    defer testing.allocator.free(copy);
    try testing.expectEqualStrings("alpha\ngamma", copy);
    try testing.expect(e.hasSelectedText());
    _ = try e.deleteSelections(0);
    try expectText(&e, " beta ");
}

test "horizontal motion: characters, words, selection extension, collapse" {
    var e = try editorWith("foo bar\nbaz");
    defer e.deinit();
    try e.moveRight(false, true);
    try carets(&e, &.{4});
    try e.moveRight(true, true);
    try testing.expectEqual(@as(usize, 4), e.sel.items.items[0].start());
    try testing.expectEqual(@as(usize, 7), e.sel.items.items[0].end());
    try e.moveRight(false, false); // collapse to the right edge
    try carets(&e, &.{7});
    try e.moveRight(false, false); // over the newline
    try carets(&e, &.{8});
    try e.moveLeft(false, true); // back to the end of the previous line
    try carets(&e, &.{7});
    try e.moveLeft(false, true);
    try carets(&e, &.{4});
    e.moveToDocStart(false);
    try e.moveLeft(false, false);
    try carets(&e, &.{0});
}

test "vertical motion remembers the column across short lines" {
    var e = try editorWith("abcdef\nab\nabcdef\n");
    defer e.deinit();
    e.setCaret(5, false); // column 5
    try e.moveVertical(1, false);
    try carets(&e, &.{9}); // clamped to the end of "ab"
    try e.moveVertical(1, false);
    try carets(&e, &.{15}); // back to column 5
    try e.moveVertical(1, false);
    try carets(&e, &.{17}); // the empty last line
    try e.moveVertical(1, false); // down from the last line: the end
    try carets(&e, &.{17});
    e.setCaret(3, false);
    try e.moveVertical(-1, false); // up from the first line: the start
    try carets(&e, &.{0});
}

test "home is smart about indentation; end goes to the line end" {
    var e = try editorWith("    code here\nnext");
    defer e.deinit();
    e.setCaret(8, false);
    try e.moveToLineStart(false, true);
    try carets(&e, &.{4}); // first non-blank
    try e.moveToLineStart(false, true);
    try carets(&e, &.{0}); // then the true start
    try e.moveToLineStart(false, true);
    try carets(&e, &.{4});
    try e.moveToLineEnd(false);
    try carets(&e, &.{13});
    try e.moveToLineEnd(true);
    try testing.expectEqual(@as(usize, 13), e.sel.items.items[0].head);
}

test "add cursors above and below, then type on all lines" {
    var e = try editorWith("one\ntwo\nthree");
    defer e.deinit();
    e.setCaret(1, false);
    try e.addCursorVertical(1);
    try e.addCursorVertical(1);
    try testing.expectEqual(@as(usize, 3), e.sel.items.items.len);
    _ = try e.typeText("_", 0);
    try expectText(&e, "o_ne\nt_wo\nt_hree");
    e.collapseToPrimary();
    try testing.expectEqual(@as(usize, 1), e.sel.items.items.len);
    try e.addCursorVertical(-5); // no line there: nothing happens
    try testing.expectEqual(@as(usize, 1), e.sel.items.items.len);
}

test "select word, line, and all" {
    var e = try editorWith("foo bar\nbaz qux");
    defer e.deinit();
    try e.selectWordAt(5);
    try testing.expectEqualStrings("bar", try e.doc.range(e.sel.items.items[0].start(), e.sel.items.items[0].end()));
    e.selectLineAt(9);
    try testing.expectEqualStrings("baz qux", try e.doc.range(e.sel.items.items[0].start(), e.sel.items.items[0].end()));
    e.selectLineAt(2);
    try testing.expectEqualStrings("foo bar\n", try e.doc.range(e.sel.items.items[0].start(), e.sel.items.items[0].end()));
    e.selectAll();
    try testing.expectEqual(@as(usize, 15), e.sel.items.items[0].end());
}

test "undo and redo cover replacement edits, and a new edit clears redo" {
    var e = try editorWith("0123456789");
    defer e.deinit();
    e.setCaret(2, false);
    e.setCaret(6, true);
    _ = try e.typeText("ab", 0);
    try expectText(&e, "01ab6789");
    try testing.expect(try e.undo());
    try expectText(&e, "0123456789");
    try testing.expect(e.canRedo());
    e.setCaret(0, false);
    _ = try e.typeText("Z", 10);
    try testing.expect(!e.canRedo());
    try testing.expect(try e.undo());
    try expectText(&e, "0123456789");
    try testing.expect(try e.undo() == false);
}

test "deep undo/redo round trip over many edits returns to each state" {
    var e = try editorWith("start");
    defer e.deinit();
    var states: std.ArrayListUnmanaged([]u8) = .empty;
    defer {
        for (states.items) |s| testing.allocator.free(s);
        states.deinit(testing.allocator);
    }
    try states.append(testing.allocator, try allText(&e));
    var now: u64 = 0;
    for (0..40) |i| {
        now += 5000; // every edit is its own step
        switch (i % 5) {
            0 => _ = try e.typeText("x", now),
            1 => _ = try e.newline(now),
            2 => _ = try e.deleteBackward(false, now),
            3 => {
                e.setCaret(i % 3, false);
                _ = try e.typeText("yz", now);
            },
            else => _ = try e.deleteForward(true, now),
        }
        try states.append(testing.allocator, try allText(&e));
    }
    var k = states.items.len - 1;
    while (k > 0) : (k -= 1) {
        try testing.expect(try e.undo());
        const s = try allText(&e);
        defer testing.allocator.free(s);
        try testing.expectEqualStrings(states.items[k - 1], s);
    }
    for (states.items[1..]) |want| {
        try testing.expect(try e.redo());
        const s = try allText(&e);
        defer testing.allocator.free(s);
        try testing.expectEqualStrings(want, s);
    }
}

test "modified tracking follows saves, undo, and redo" {
    var e = Editor.init(testing.allocator);
    defer e.deinit();
    try testing.expect(!e.isModified());
    _ = try e.typeText("a", 0);
    try testing.expect(e.isModified());
    e.markSaved();
    try testing.expect(!e.isModified());
    _ = try e.typeText("b", 10); // joins nothing: a save closes the step
    try testing.expect(e.isModified());
    try testing.expect(try e.undo());
    try testing.expect(!e.isModified()); // back at the saved state
    try testing.expect(try e.undo());
    try testing.expect(e.isModified());
    try testing.expect(try e.redo());
    try testing.expect(!e.isModified());
    // Saving, undoing past it, then editing makes the saved state unreachable.
    try testing.expect(try e.undo());
    e.markSaved(); // saving the state we undid back to (empty text)
    try testing.expect(!e.isModified());
    _ = try e.typeText("q", 20);
    try testing.expect(try e.undo());
    try testing.expect(!e.isModified());
}

test "unreachable saved state is detected when redo is discarded" {
    var e = Editor.init(testing.allocator);
    defer e.deinit();
    _ = try e.typeText("a", 0);
    e.markSaved();
    try testing.expect(try e.undo()); // now before the saved state; "a" is in the redo stack
    _ = try e.typeText("b", 10); // discards redo, including the saved state
    try testing.expect(try e.undo());
    try testing.expect(e.isModified()); // can never get back to the saved text
}

test "every applied command appends a change record, including undo" {
    var e = try editorWith("ab\ncd");
    defer e.deinit();
    e.setCaret(2, false);
    _ = try e.typeText("X\nY", 0);
    try testing.expectEqual(@as(usize, 1), e.doc.changes.items.len);
    const c = e.doc.changes.items[0];
    try testing.expectEqual(@as(usize, 2), c.offset);
    try testing.expectEqual(@as(usize, 3), c.inserted_len);
    try testing.expectEqual(@as(usize, 1), c.inserted_lines);
    e.doc.clearChanges();
    try testing.expect(try e.undo());
    try testing.expectEqual(@as(usize, 1), e.doc.changes.items.len);
    try testing.expectEqual(@as(usize, 3), e.doc.changes.items[0].removed_len);
}

test "CRLF lines: motion and deletion treat the pair as one character" {
    var e = try editorWith("ab\r\ncd");
    defer e.deinit();
    e.setCaret(2, false);
    try e.moveRight(false, false);
    try carets(&e, &.{4}); // over the whole \r\n
    _ = try e.deleteBackward(false, 0);
    try expectText(&e, "abcd");
}

test "typing control characters is dropped by the caller; newline text is not typing" {
    var e = Editor.init(testing.allocator);
    defer e.deinit();
    _ = try e.typeText("a", 0);
    _ = try e.typeText("b\nc", 10); // contains a newline: its own step
    try testing.expectEqual(@as(usize, 2), e.undo_stack.items.len);
    try expectText(&e, "ab\nc");
}

test "random operations: undo restores the original, redo restores the final text" {
    for ([_]u64{ 1, 2, 3, 0xABCD, 777 }) |seed| {
        var e = try editorWith("fn main() {\n    return 0;\n}\n\nconst x = 1;\n");
        defer e.deinit();
        const original = try allText(&e);
        defer testing.allocator.free(original);

        var prng = std.Random.DefaultPrng.init(seed);
        const rand = prng.random();
        var now: u64 = 0;
        const snippets = [_][]const u8{ "a", "xyz", " ", "\n", "é", "{}", "two\nlines" };

        for (0..300) |_| {
            now += rand.uintLessThan(u64, 1500);
            const len = e.doc.len();
            switch (rand.uintLessThan(u8, 14)) {
                0, 1, 2 => _ = try e.typeText(snippets[rand.uintLessThan(usize, snippets.len)], now),
                3 => _ = try e.deleteBackward(rand.boolean(), now),
                4 => _ = try e.deleteForward(rand.boolean(), now),
                5 => _ = try e.newline(now),
                6 => _ = try e.tab(now),
                7 => _ = try e.outdent(now),
                8 => e.setCaret(rand.uintAtMost(usize, len), rand.boolean()),
                9 => e.addCaret(rand.uintAtMost(usize, len)),
                10 => try e.moveVertical(rand.intRangeAtMost(isize, -2, 2), rand.boolean()),
                11 => try e.moveRight(rand.boolean(), rand.boolean()),
                12 => _ = try e.deleteSelections(now),
                else => try e.addCursorVertical(rand.intRangeAtMost(isize, -1, 1)),
            }
            // Invariants after every operation.
            try e.doc.table.validate();
            const sels = e.sel.items.items;
            try testing.expect(sels.len >= 1);
            var prev_end: usize = 0;
            for (sels, 0..) |s, i| {
                try testing.expect(s.head <= e.doc.len() and s.anchor <= e.doc.len());
                if (i > 0) try testing.expect(s.start() >= prev_end);
                prev_end = s.end();
            }
        }
        const final = try allText(&e);
        defer testing.allocator.free(final);

        while (try e.undo()) {}
        const back = try allText(&e);
        defer testing.allocator.free(back);
        try testing.expectEqualStrings(original, back);
        try testing.expect(!e.isModified());

        while (try e.redo()) {}
        const again = try allText(&e);
        defer testing.allocator.free(again);
        try testing.expectEqualStrings(final, again);
    }
}
