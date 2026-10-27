//! Document: a piece table plus the single edit path and change records.
//!
//! Every modification goes through `apply`, as an `Op` (insert or delete of
//! exact bytes at an offset). Ops are reversible by construction: a delete
//! names the bytes it removes, so `inverse` is just the opposite op. History
//! stores owned `Command`s (an Op with its own copy of the text), which keeps
//! undo independent of the piece table's buffers.
//!
//! Each applied op appends a `Change` (offset range plus the line range it
//! touched). Subscribers (the highlighter, the renderer's damage tracking, a
//! line-number gutter) drain `changes` once per frame and call `clearChanges`.
//!
//! Columns are counted in Unicode code points. A "\r\n" pair is one line
//! terminator: cursors never stop between the two.

const std = @import("std");
const PieceTable = @import("piece_table.zig").PieceTable;

pub const OpKind = enum { insert, delete };

/// A borrowed, reversible edit.
pub const Op = struct {
    kind: OpKind,
    offset: usize,
    /// Inserted text, or the exact text being removed.
    text: []const u8,

    pub fn inverse(self: Op) Op {
        return .{
            .kind = if (self.kind == .insert) .delete else .insert,
            .offset = self.offset,
            .text = self.text,
        };
    }
};

/// An op that owns its text (what history keeps).
pub const Command = struct {
    kind: OpKind,
    offset: usize,
    text: []u8,

    pub fn op(self: Command) Op {
        return .{ .kind = self.kind, .offset = self.offset, .text = self.text };
    }

    pub fn deinit(self: Command, gpa: std.mem.Allocator) void {
        gpa.free(self.text);
    }
};

/// What changed, for subscribers. Lines are 0-based and refer to the document
/// before the op for the removed side and after it for the inserted side; the
/// first affected line is the same in both.
pub const Change = struct {
    /// Byte offset where the edit happened.
    offset: usize,
    removed_len: usize,
    inserted_len: usize,
    /// First line touched.
    start_line: usize,
    /// Line breaks removed / inserted (the line count changes by the difference).
    removed_lines: usize,
    inserted_lines: usize,
    /// Document version after this change.
    version: u64,
};

pub const Error = error{OutOfMemory};
/// Editing can also fail while a mapped file is still being indexed.
pub const ApplyError = Error || error{Indexing};

pub const Document = struct {
    gpa: std.mem.Allocator,
    table: PieceTable,
    /// Incremented by every applied op.
    version: u64 = 0,
    changes: std.ArrayListUnmanaged(Change) = .empty,
    /// Scratch for line reads.
    scratch: std.ArrayListUnmanaged(u8) = .empty,

    pub fn init(gpa: std.mem.Allocator) Document {
        return .{ .gpa = gpa, .table = PieceTable.init(gpa) };
    }

    /// Open `bytes` as the original text (see `PieceTable.initWithOriginal`).
    /// A document over borrowed, memory-mapped bytes whose newline index is built
    /// later (see `PieceTable.initMapped`).
    pub fn initMapped(gpa: std.mem.Allocator, bytes: []const u8) !Document {
        return .{ .gpa = gpa, .table = try PieceTable.initMapped(gpa, bytes) };
    }

    /// True while a mapped file is still being indexed (it cannot be edited yet).
    pub fn isIndexing(self: *const Document) bool {
        return self.table.indexing;
    }

    pub fn initWithText(gpa: std.mem.Allocator, bytes: []const u8, owned: bool) !Document {
        return .{ .gpa = gpa, .table = try PieceTable.initWithOriginal(gpa, bytes, owned) };
    }

    pub fn deinit(self: *Document) void {
        self.table.deinit();
        self.changes.deinit(self.gpa);
        self.scratch.deinit(self.gpa);
        self.* = undefined;
    }

    pub fn len(self: *const Document) usize {
        return self.table.len();
    }

    pub fn lineCount(self: *const Document) usize {
        return self.table.lineCount();
    }

    // ---- the one edit path ---------------------------------------------------------

    /// Apply an op and record its change. A delete must match the document's
    /// text at that range (checked in safe builds).
    pub fn apply(self: *Document, op: Op) ApplyError!void {
        const line = self.table.lineOfOffset(op.offset);
        var nl: usize = 0;
        for (op.text) |c| nl += @intFromBool(c == '\n');
        // Reserve the change record first so a failure cannot leave an
        // edit applied but unrecorded.
        try self.changes.ensureUnusedCapacity(self.gpa, 1);
        switch (op.kind) {
            .insert => try self.table.insert(op.offset, op.text),
            .delete => {
                if (std.debug.runtime_safety) self.assertText(op.offset, op.text);
                try self.table.delete(op.offset, op.text.len);
            },
        }
        self.version += 1;
        self.changes.appendAssumeCapacity(.{
            .offset = op.offset,
            .removed_len = if (op.kind == .delete) op.text.len else 0,
            .inserted_len = if (op.kind == .insert) op.text.len else 0,
            .start_line = line,
            .removed_lines = if (op.kind == .delete) nl else 0,
            .inserted_lines = if (op.kind == .insert) nl else 0,
            .version = self.version,
        });
    }

    fn assertText(self: *Document, offset: usize, expected: []const u8) void {
        const got = self.table.slice(offset, offset + expected.len, &self.scratch, self.gpa) catch return;
        std.debug.assert(std.mem.eql(u8, got, expected));
    }

    /// Build the command that deletes [start, end), capturing the removed text.
    pub fn makeDelete(self: *Document, start: usize, end: usize) Error!Command {
        const text = try self.gpa.alloc(u8, end - start);
        errdefer self.gpa.free(text);
        var tmp: std.ArrayListUnmanaged(u8) = .empty;
        defer tmp.deinit(self.gpa);
        try self.table.readInto(start, end, &tmp, self.gpa);
        @memcpy(text, tmp.items);
        return .{ .kind = .delete, .offset = start, .text = text };
    }

    pub fn makeInsert(self: *Document, offset: usize, text: []const u8) Error!Command {
        return .{ .kind = .insert, .offset = offset, .text = try self.gpa.dupe(u8, text) };
    }

    pub fn clearChanges(self: *Document) void {
        self.changes.clearRetainingCapacity();
    }

    // ---- reading ---------------------------------------------------------------------

    pub fn byteAt(self: *const Document, offset: usize) u8 {
        return self.table.byteAt(offset);
    }

    /// Bytes [start, end) (borrowed or copied into the document's scratch;
    /// valid until the next edit or read through this function).
    pub fn range(self: *Document, start: usize, end: usize) Error![]const u8 {
        return self.table.slice(start, end, &self.scratch, self.gpa);
    }

    /// Copy [start, end) into a new allocation owned by the caller.
    pub fn textAlloc(self: *Document, gpa: std.mem.Allocator, start: usize, end: usize) Error![]u8 {
        var out: std.ArrayListUnmanaged(u8) = .empty;
        errdefer out.deinit(gpa);
        try self.table.readInto(start, end, &out, gpa);
        return out.toOwnedSlice(gpa);
    }

    pub fn lineOfOffset(self: *const Document, offset: usize) usize {
        return self.table.lineOfOffset(offset);
    }

    pub fn lineStart(self: *const Document, line: usize) usize {
        return self.table.lineStart(line);
    }

    /// End of the line's content (before "\n" or "\r\n").
    pub fn lineEnd(self: *const Document, line: usize) usize {
        return self.table.lineEnd(line);
    }

    /// A line's text without its terminator.
    pub fn lineText(self: *Document, line: usize) Error![]const u8 {
        return self.range(self.lineStart(line), self.lineEnd(line));
    }

    // ---- code point navigation -------------------------------------------------------

    fn isCont(b: u8) bool {
        return b & 0xC0 == 0x80;
    }

    /// Start of the character before `offset` ("\r\n" counts as one).
    pub fn prevBoundary(self: *const Document, offset: usize) usize {
        if (offset == 0) return 0;
        var i = offset - 1;
        if (self.byteAt(i) == '\n' and i > 0 and self.byteAt(i - 1) == '\r') return i - 1;
        while (i > 0 and isCont(self.byteAt(i))) i -= 1;
        return i;
    }

    /// Start of the character after the one at `offset`.
    pub fn nextBoundary(self: *const Document, offset: usize) usize {
        const total = self.len();
        if (offset >= total) return total;
        if (self.byteAt(offset) == '\r' and offset + 1 < total and self.byteAt(offset + 1) == '\n') return offset + 2;
        var i = offset + 1;
        while (i < total and isCont(self.byteAt(i))) i += 1;
        return i;
    }

    /// Column (code points from the line start) of `offset`.
    pub fn columnOf(self: *Document, offset: usize) Error!usize {
        const line = self.lineOfOffset(offset);
        const s = try self.range(self.lineStart(line), offset);
        var col: usize = 0;
        for (s) |b| col += @intFromBool(!isCont(b));
        return col;
    }

    /// Offset at `column` code points into `line`, clamped to the line's end.
    pub fn offsetAtColumn(self: *Document, line: usize, column: usize) Error!usize {
        const start = self.lineStart(line);
        const s = try self.range(start, self.lineEnd(line));
        var col: usize = 0;
        var i: usize = 0;
        while (i < s.len and col < column) {
            i += 1;
            while (i < s.len and isCont(s[i])) i += 1;
            col += 1;
        }
        return start + i;
    }
};

// ---- tests -----------------------------------------------------------------

const testing = std.testing;

fn whole(d: *Document) ![]u8 {
    return d.textAlloc(testing.allocator, 0, d.len());
}

test "apply inserts and deletes, and inverse ops restore the text" {
    var d = try Document.initWithText(testing.allocator, "hello world", false);
    defer d.deinit();
    const ins: Op = .{ .kind = .insert, .offset = 5, .text = "," };
    try d.apply(ins);
    {
        const s = try whole(&d);
        defer testing.allocator.free(s);
        try testing.expectEqualStrings("hello, world", s);
    }
    try d.apply(ins.inverse());
    const del = try d.makeDelete(0, 6);
    defer del.deinit(testing.allocator);
    try testing.expectEqualStrings("hello ", del.text);
    try d.apply(del.op());
    try d.apply(del.op().inverse());
    const s = try whole(&d);
    defer testing.allocator.free(s);
    try testing.expectEqualStrings("hello world", s);
    try testing.expectEqual(@as(u64, 4), d.version);
}

test "changes record offsets and line ranges" {
    var d = try Document.initWithText(testing.allocator, "one\ntwo\nthree", false);
    defer d.deinit();
    try d.apply(.{ .kind = .insert, .offset = 4, .text = "a\nb\n" });
    try d.apply(.{ .kind = .delete, .offset = 0, .text = "one\n" });
    try testing.expectEqual(@as(usize, 2), d.changes.items.len);
    const c0 = d.changes.items[0];
    try testing.expectEqual(@as(usize, 4), c0.offset);
    try testing.expectEqual(@as(usize, 4), c0.inserted_len);
    try testing.expectEqual(@as(usize, 1), c0.start_line);
    try testing.expectEqual(@as(usize, 2), c0.inserted_lines);
    try testing.expectEqual(@as(usize, 0), c0.removed_len);
    const c1 = d.changes.items[1];
    try testing.expectEqual(@as(usize, 4), c1.removed_len);
    try testing.expectEqual(@as(usize, 1), c1.removed_lines);
    try testing.expectEqual(@as(usize, 0), c1.start_line);
    try testing.expectEqual(@as(u64, 2), c1.version);
    d.clearChanges();
    try testing.expectEqual(@as(usize, 0), d.changes.items.len);
}

test "line text and lookups" {
    var d = try Document.initWithText(testing.allocator, "alpha\r\nbeta\n\ngamma", false);
    defer d.deinit();
    try testing.expectEqual(@as(usize, 4), d.lineCount());
    try testing.expectEqualStrings("alpha", try d.lineText(0)); // no \r
    try testing.expectEqualStrings("beta", try d.lineText(1));
    try testing.expectEqualStrings("", try d.lineText(2));
    try testing.expectEqualStrings("gamma", try d.lineText(3));
}

test "boundaries step over multi-byte characters and CRLF" {
    var d = try Document.initWithText(testing.allocator, "a\u{e9}\u{4e2d}\r\nb", false);
    defer d.deinit();
    // bytes: a(0) é(1,2) 中(3,4,5) \r(6) \n(7) b(8)
    try testing.expectEqual(@as(usize, 1), d.nextBoundary(0));
    try testing.expectEqual(@as(usize, 3), d.nextBoundary(1));
    try testing.expectEqual(@as(usize, 6), d.nextBoundary(3));
    try testing.expectEqual(@as(usize, 8), d.nextBoundary(6)); // CRLF is one step
    try testing.expectEqual(@as(usize, 9), d.nextBoundary(8));
    try testing.expectEqual(@as(usize, 9), d.nextBoundary(9));
    try testing.expectEqual(@as(usize, 6), d.prevBoundary(8)); // back over CRLF
    try testing.expectEqual(@as(usize, 3), d.prevBoundary(6));
    try testing.expectEqual(@as(usize, 1), d.prevBoundary(3));
    try testing.expectEqual(@as(usize, 0), d.prevBoundary(1));
    try testing.expectEqual(@as(usize, 0), d.prevBoundary(0));
}

test "columns count code points and map back to offsets" {
    var d = try Document.initWithText(testing.allocator, "x\u{e9}y\nabc", false);
    defer d.deinit();
    try testing.expectEqual(@as(usize, 0), try d.columnOf(0));
    try testing.expectEqual(@as(usize, 2), try d.columnOf(3)); // after x and é
    try testing.expectEqual(@as(usize, 3), try d.columnOf(4));
    try testing.expectEqual(@as(usize, 1), try d.columnOf(6));
    try testing.expectEqual(@as(usize, 3), try d.offsetAtColumn(0, 2));
    try testing.expectEqual(@as(usize, 4), try d.offsetAtColumn(0, 99)); // clamps to line end
    try testing.expectEqual(@as(usize, 7), try d.offsetAtColumn(1, 2));
}

test "an empty document is one empty line" {
    var d = Document.init(testing.allocator);
    defer d.deinit();
    try testing.expectEqual(@as(usize, 1), d.lineCount());
    try testing.expectEqualStrings("", try d.lineText(0));
    try d.apply(.{ .kind = .insert, .offset = 0, .text = "x" });
    try testing.expectEqualStrings("x", try d.lineText(0));
}
