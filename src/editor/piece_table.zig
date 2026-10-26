//! Piece table: the editor's text storage (design doc section 20).
//!
//! The document is a sequence of "pieces", each a slice of one of two buffers:
//! the original file (never copied or modified: borrowed, so huge files open
//! without duplicating them) and an append-only "add" buffer holding every
//! inserted byte. Edits only split, drop, and add pieces; no text moves.
//!
//! The pieces live in a treap (randomized balanced tree) keyed by position.
//! Every node caches its subtree's byte length and newline count, so finding
//! the Nth line, or the line of a byte offset, is O(log pieces) and never
//! scans text. Newlines inside a piece are counted by binary search over a
//! per-buffer sorted newline index (built once for the original, extended as
//! text is added), which is the "separate line index" from the design doc.
//!
//! Undo/redo history does not point in here: commands carry their own text
//! (see document.zig), so the buffers can be compacted or swapped later.
//!
//! Limits: offsets are `usize`; the original buffer's newline index costs 8
//! bytes per line, built by one scan at load. Adjacent typing coalesces into
//! one piece, so piece count tracks edit sites, not keystrokes. Undo followed
//! by redo appends the text to the add buffer again, so the add buffer only
//! grows (compaction is future work).

const std = @import("std");

const NIL: u32 = std.math.maxInt(u32);

const Buf = enum(u8) { original, add };

const Node = struct {
    buf: Buf,
    start: usize,
    len: usize,
    /// Newlines inside this piece.
    nl: usize,
    left: u32 = NIL,
    right: u32 = NIL,
    prio: u32,
    /// Totals for the subtree rooted here (including this node).
    sub_len: usize = 0,
    sub_nl: usize = 0,
};

const Pair = struct { l: u32, r: u32 };

fn lowerBound(table: []const usize, value: usize) usize {
    var lo: usize = 0;
    var hi: usize = table.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (table[mid] < value) lo = mid + 1 else hi = mid;
    }
    return lo;
}

pub const PieceTable = struct {
    gpa: std.mem.Allocator,
    original: []const u8 = "",
    original_owned: bool = false,
    /// Sorted offsets of '\n' in `original`.
    original_nl: []usize = &.{},
    add: std.ArrayListUnmanaged(u8) = .empty,
    add_nl: std.ArrayListUnmanaged(usize) = .empty,
    nodes: std.ArrayListUnmanaged(Node) = .empty,
    free_list: std.ArrayListUnmanaged(u32) = .empty,
    root: u32 = NIL,
    rng: u64 = 0x9E3779B97F4A7C15,

    pub fn init(gpa: std.mem.Allocator) PieceTable {
        return .{ .gpa = gpa };
    }

    /// Start with `bytes` as the original text. If `owned`, the table frees it
    /// with `gpa` on deinit; otherwise it must outlive the table (for example
    /// a memory-mapped file). The bytes are never modified or copied.
    pub fn initWithOriginal(gpa: std.mem.Allocator, bytes: []const u8, owned: bool) !PieceTable {
        var t = init(gpa);
        errdefer t.deinit();
        t.original = bytes;
        t.original_owned = owned;

        var count: usize = 0;
        var pos: usize = 0;
        while (std.mem.indexOfScalarPos(u8, bytes, pos, '\n')) |i| : (pos = i + 1) count += 1;
        t.original_nl = try gpa.alloc(usize, count);
        var k: usize = 0;
        pos = 0;
        while (std.mem.indexOfScalarPos(u8, bytes, pos, '\n')) |i| : (pos = i + 1) {
            t.original_nl[k] = i;
            k += 1;
        }

        if (bytes.len > 0) {
            try t.nodes.ensureUnusedCapacity(gpa, 4);
            t.root = t.allocNode(.original, 0, bytes.len);
        }
        return t;
    }

    pub fn deinit(self: *PieceTable) void {
        if (self.original_owned) self.gpa.free(@constCast(self.original));
        self.gpa.free(self.original_nl);
        self.add.deinit(self.gpa);
        self.add_nl.deinit(self.gpa);
        self.nodes.deinit(self.gpa);
        self.free_list.deinit(self.gpa);
        self.* = undefined;
    }

    // ---- sizes ----------------------------------------------------------------

    pub fn len(self: *const PieceTable) usize {
        return self.subLen(self.root);
    }

    /// Number of lines: newlines + 1 (an empty document has one empty line).
    pub fn lineCount(self: *const PieceTable) usize {
        return self.subNl(self.root) + 1;
    }

    pub fn pieceCount(self: *const PieceTable) usize {
        return self.nodes.items.len - self.free_list.items.len;
    }

    fn subLen(self: *const PieceTable, n: u32) usize {
        return if (n == NIL) 0 else self.nodes.items[n].sub_len;
    }

    fn subNl(self: *const PieceTable, n: u32) usize {
        return if (n == NIL) 0 else self.nodes.items[n].sub_nl;
    }

    fn bufBytes(self: *const PieceTable, b: Buf) []const u8 {
        return switch (b) {
            .original => self.original,
            .add => self.add.items,
        };
    }

    fn bufNl(self: *const PieceTable, b: Buf) []const usize {
        return switch (b) {
            .original => self.original_nl,
            .add => self.add_nl.items,
        };
    }

    /// Newlines in bytes [start, start + n) of a buffer.
    fn countNl(self: *const PieceTable, b: Buf, start: usize, n: usize) usize {
        const t = self.bufNl(b);
        return lowerBound(t, start + n) - lowerBound(t, start);
    }

    // ---- treap internals --------------------------------------------------------

    fn nextPrio(self: *PieceTable) u32 {
        // xorshift64*
        self.rng ^= self.rng >> 12;
        self.rng ^= self.rng << 25;
        self.rng ^= self.rng >> 27;
        return @truncate((self.rng *% 0x2545F4914F6CDD1D) >> 32);
    }

    /// Capacity must have been reserved (`reserve`), so this cannot fail.
    fn allocNode(self: *PieceTable, b: Buf, start: usize, n: usize) u32 {
        const node: Node = .{
            .buf = b,
            .start = start,
            .len = n,
            .nl = self.countNl(b, start, n),
            .prio = self.nextPrio(),
            .sub_len = n,
            .sub_nl = self.countNl(b, start, n),
        };
        if (self.free_list.pop()) |idx| {
            self.nodes.items[idx] = node;
            return idx;
        }
        self.nodes.appendAssumeCapacity(node);
        return @intCast(self.nodes.items.len - 1);
    }

    fn reserve(self: *PieceTable) !void {
        // One edit allocates at most 2 nodes (two splits, or a split plus a new piece).
        try self.nodes.ensureUnusedCapacity(self.gpa, 4 -| self.free_list.items.len);
    }

    fn upd(self: *PieceTable, n: u32) void {
        const node = &self.nodes.items[n];
        var l = node.len;
        var c = node.nl;
        if (node.left != NIL) {
            const x = &self.nodes.items[node.left];
            l += x.sub_len;
            c += x.sub_nl;
        }
        if (node.right != NIL) {
            const x = &self.nodes.items[node.right];
            l += x.sub_len;
            c += x.sub_nl;
        }
        node.sub_len = l;
        node.sub_nl = c;
    }

    /// First `offset` bytes go left, the rest right. Splits a piece if needed.
    fn split(self: *PieceTable, n: u32, offset: usize) Pair {
        if (n == NIL) return .{ .l = NIL, .r = NIL };
        const node = self.nodes.items[n];
        const left_len = self.subLen(node.left);
        if (offset <= left_len) {
            const p = self.split(node.left, offset);
            self.nodes.items[n].left = p.r;
            self.upd(n);
            return .{ .l = p.l, .r = n };
        }
        const off = offset - left_len;
        if (off >= node.len) {
            const p = self.split(node.right, off - node.len);
            self.nodes.items[n].right = p.l;
            self.upd(n);
            return .{ .l = n, .r = p.r };
        }
        // Inside this piece: cut it in two.
        const rn = self.allocNode(node.buf, node.start + off, node.len - off);
        // The new half takes the place of part of `n`, so it must not outrank
        // `n`'s ancestors: draw its priority from [0, n.prio].
        self.nodes.items[rn].prio = @intCast(@as(u64, self.nodes.items[rn].prio) % (@as(u64, node.prio) + 1));
        const cur = &self.nodes.items[n];
        cur.len = off;
        cur.nl = self.countNl(node.buf, node.start, off);
        cur.right = NIL;
        self.upd(n);
        self.upd(rn);
        // The old right subtree goes under the new right half through `merge`,
        // which keeps the heap order by priority.
        return .{ .l = n, .r = self.merge(rn, node.right) };
    }

    fn merge(self: *PieceTable, a: u32, b: u32) u32 {
        if (a == NIL) return b;
        if (b == NIL) return a;
        if (self.nodes.items[a].prio > self.nodes.items[b].prio) {
            const r = self.merge(self.nodes.items[a].right, b);
            self.nodes.items[a].right = r;
            self.upd(a);
            return a;
        }
        const l = self.merge(a, self.nodes.items[b].left);
        self.nodes.items[b].left = l;
        self.upd(b);
        return b;
    }

    fn freeTree(self: *PieceTable, n: u32) void {
        if (n == NIL) return;
        const node = self.nodes.items[n];
        self.freeTree(node.left);
        self.freeTree(node.right);
        // If the free list cannot grow the node is simply leaked until deinit.
        self.free_list.append(self.gpa, n) catch {};
    }

    /// If the last piece of `tree` is the tail of the add buffer, grow it in
    /// place (typing at one spot stays one piece). Returns false otherwise.
    fn extendRightmost(self: *PieceTable, tree: u32, add_start: usize, n: usize, nl: usize) bool {
        var path: [128]u32 = undefined;
        var depth: usize = 0;
        var cur = tree;
        while (self.nodes.items[cur].right != NIL) {
            if (depth == path.len) return false;
            path[depth] = cur;
            depth += 1;
            cur = self.nodes.items[cur].right;
        }
        const node = &self.nodes.items[cur];
        if (node.buf != .add or node.start + node.len != add_start) return false;
        node.len += n;
        node.nl += nl;
        self.upd(cur);
        while (depth > 0) {
            depth -= 1;
            self.upd(path[depth]);
        }
        return true;
    }

    // ---- editing ----------------------------------------------------------------

    /// Insert `text` so it starts at `offset` (0..len).
    pub fn insert(self: *PieceTable, offset: usize, text: []const u8) !void {
        std.debug.assert(offset <= self.len());
        if (text.len == 0) return;
        try self.reserve();
        var nl_count: usize = 0;
        for (text) |c| nl_count += @intFromBool(c == '\n');
        try self.add.ensureUnusedCapacity(self.gpa, text.len);
        try self.add_nl.ensureUnusedCapacity(self.gpa, nl_count);

        const add_start = self.add.items.len;
        self.add.appendSliceAssumeCapacity(text);
        for (text, 0..) |c, i| {
            if (c == '\n') self.add_nl.appendAssumeCapacity(add_start + i);
        }

        const p = self.split(self.root, offset);
        var left = p.l;
        if (left == NIL or !self.extendRightmost(left, add_start, text.len, nl_count)) {
            const piece = self.allocNode(.add, add_start, text.len);
            left = self.merge(left, piece);
        }
        self.root = self.merge(left, p.r);
    }

    /// Remove `n` bytes starting at `offset`.
    pub fn delete(self: *PieceTable, offset: usize, n: usize) !void {
        const total = self.len();
        std.debug.assert(offset <= total);
        const count = @min(n, total - offset);
        if (count == 0) return;
        try self.reserve();
        const a = self.split(self.root, offset);
        const b = self.split(a.r, count);
        self.freeTree(b.l);
        self.root = self.merge(a.l, b.r);
    }

    // ---- reading ------------------------------------------------------------------

    /// The contiguous run of text starting at `offset` and ending at the end
    /// of its piece (null at or past the end). Zero-copy.
    pub fn chunkAt(self: *const PieceTable, offset: usize) ?[]const u8 {
        var n = self.root;
        var off = offset;
        while (n != NIL) {
            const node = &self.nodes.items[n];
            const ll = self.subLen(node.left);
            if (off < ll) {
                n = node.left;
            } else if (off - ll < node.len) {
                const o = off - ll;
                return self.bufBytes(node.buf)[node.start + o .. node.start + node.len];
            } else {
                off -= ll + node.len;
                n = node.right;
            }
        }
        return null;
    }

    pub fn byteAt(self: *const PieceTable, offset: usize) u8 {
        return self.chunkAt(offset).?[0];
    }

    /// Append bytes [start, end) to `out`.
    pub fn readInto(self: *const PieceTable, start: usize, end: usize, out: *std.ArrayListUnmanaged(u8), gpa: std.mem.Allocator) !void {
        var pos = start;
        const stop = @min(end, self.len());
        while (pos < stop) {
            const chunk = self.chunkAt(pos).?;
            const take = @min(chunk.len, stop - pos);
            try out.appendSlice(gpa, chunk[0..take]);
            pos += take;
        }
    }

    /// Bytes [start, end) as one slice: borrowed from the table when they lie
    /// in a single piece, otherwise copied into `scratch`. Valid until the next
    /// edit or the next use of `scratch`.
    pub fn slice(self: *const PieceTable, start: usize, end: usize, scratch: *std.ArrayListUnmanaged(u8), gpa: std.mem.Allocator) ![]const u8 {
        const stop = @min(end, self.len());
        if (start >= stop) return "";
        const first = self.chunkAt(start).?;
        if (first.len >= stop - start) return first[0 .. stop - start];
        scratch.clearRetainingCapacity();
        try self.readInto(start, stop, scratch, gpa);
        return scratch.items;
    }

    // ---- lines --------------------------------------------------------------------

    /// Number of newlines strictly before `offset`: the 0-based line of that offset.
    pub fn lineOfOffset(self: *const PieceTable, offset: usize) usize {
        var n = self.root;
        var off = @min(offset, self.len());
        var acc: usize = 0;
        while (n != NIL) {
            const node = &self.nodes.items[n];
            const ll = self.subLen(node.left);
            if (off <= ll) {
                n = node.left;
                continue;
            }
            acc += self.subNl(node.left);
            off -= ll;
            if (off <= node.len) {
                acc += self.countNl(node.buf, node.start, off);
                break;
            }
            acc += node.nl;
            off -= node.len;
            n = node.right;
        }
        return acc;
    }

    /// Offset of the first byte of `line` (clamped to the last line).
    pub fn lineStart(self: *const PieceTable, line: usize) usize {
        if (line == 0) return 0;
        var k = @min(line, self.subNl(self.root)); // find the k-th newline (1-based)
        if (k == 0) return 0;
        var n = self.root;
        var base: usize = 0;
        while (n != NIL) {
            const node = &self.nodes.items[n];
            const ln = self.subNl(node.left);
            if (k <= ln) {
                n = node.left;
                continue;
            }
            k -= ln;
            base += self.subLen(node.left);
            if (k <= node.nl) {
                const table = self.bufNl(node.buf);
                const first = lowerBound(table, node.start);
                return base + (table[first + k - 1] - node.start) + 1;
            }
            k -= node.nl;
            base += node.len;
            n = node.right;
        }
        return self.len();
    }

    /// Offset just past the last byte of `line`'s content, before its '\n'
    /// (and before a '\r' that precedes it).
    pub fn lineEnd(self: *const PieceTable, line: usize) usize {
        const last = self.lineCount() - 1;
        if (line >= last) return self.len();
        var end = self.lineStart(line + 1) - 1; // the '\n'
        if (end > self.lineStart(line) and self.byteAt(end - 1) == '\r') end -= 1;
        return end;
    }

    // ---- testing support ----------------------------------------------------------

    /// Check every structural invariant. For tests.
    pub fn validate(self: *const PieceTable) !void {
        _ = try self.validateNode(self.root);
    }

    fn validateNode(self: *const PieceTable, n: u32) !struct { len: usize, nl: usize } {
        if (n == NIL) return .{ .len = 0, .nl = 0 };
        const node = self.nodes.items[n];
        if (node.len == 0) return error.EmptyPiece;
        const l = try self.validateNode(node.left);
        const r = try self.validateNode(node.right);
        if (node.left != NIL and self.nodes.items[node.left].prio > node.prio) return error.HeapViolation;
        if (node.right != NIL and self.nodes.items[node.right].prio > node.prio) return error.HeapViolation;
        const total_len = l.len + node.len + r.len;
        const total_nl = l.nl + node.nl + r.nl;
        if (node.sub_len != total_len or node.sub_nl != total_nl) return error.BadAggregate;
        if (node.nl != self.countNl(node.buf, node.start, node.len)) return error.BadNewlineCount;
        return .{ .len = total_len, .nl = total_nl };
    }
};

// ---- tests -----------------------------------------------------------------

const testing = std.testing;

fn contents(t: *const PieceTable, out: *std.ArrayListUnmanaged(u8)) ![]const u8 {
    out.clearRetainingCapacity();
    try t.readInto(0, t.len(), out, testing.allocator);
    return out.items;
}

test "empty table" {
    var t = PieceTable.init(testing.allocator);
    defer t.deinit();
    try testing.expectEqual(@as(usize, 0), t.len());
    try testing.expectEqual(@as(usize, 1), t.lineCount());
    try testing.expectEqual(@as(usize, 0), t.lineStart(0));
    try testing.expectEqual(@as(usize, 0), t.lineEnd(0));
    try testing.expect(t.chunkAt(0) == null);
    try t.validate();
}

test "an original file is borrowed, not copied, and indexed by line" {
    const text = "alpha\nbeta\n\ngamma";
    var t = try PieceTable.initWithOriginal(testing.allocator, text, false);
    defer t.deinit();
    try testing.expectEqual(text.len, t.len());
    try testing.expectEqual(@as(usize, 4), t.lineCount());
    try testing.expectEqual(@as(usize, 0), t.lineStart(0));
    try testing.expectEqual(@as(usize, 6), t.lineStart(1));
    try testing.expectEqual(@as(usize, 11), t.lineStart(2));
    try testing.expectEqual(@as(usize, 12), t.lineStart(3));
    try testing.expectEqual(@as(usize, 5), t.lineEnd(0));
    try testing.expectEqual(@as(usize, 10), t.lineEnd(1));
    try testing.expectEqual(@as(usize, 11), t.lineEnd(2)); // empty line
    try testing.expectEqual(text.len, t.lineEnd(3));
    // Zero-copy: the chunk points into the original buffer.
    try testing.expectEqual(@as(*const u8, &text[0]), &t.chunkAt(0).?[0]);
    try testing.expectEqual(@as(usize, 1), t.pieceCount());
}

test "insert in the middle splits the original piece" {
    var t = try PieceTable.initWithOriginal(testing.allocator, "hello world", false);
    defer t.deinit();
    try t.insert(5, ",");
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(testing.allocator);
    try testing.expectEqualStrings("hello, world", try contents(&t, &out));
    try testing.expectEqual(@as(usize, 3), t.pieceCount());
    try t.validate();
}

test "typing at one spot coalesces into a single piece" {
    var t = try PieceTable.initWithOriginal(testing.allocator, "ab", false);
    defer t.deinit();
    try t.insert(1, "x");
    try t.insert(2, "y");
    try t.insert(3, "z");
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(testing.allocator);
    try testing.expectEqualStrings("axyzb", try contents(&t, &out));
    try testing.expectEqual(@as(usize, 3), t.pieceCount()); // "a", "xyz", "b"
    try t.validate();
}

test "delete across pieces, at the edges, and everything" {
    var t = try PieceTable.initWithOriginal(testing.allocator, "0123456789", false);
    defer t.deinit();
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(testing.allocator);
    try t.insert(5, "abc");
    try testing.expectEqualStrings("01234abc56789", try contents(&t, &out));
    try t.delete(3, 6); // "34abc5"
    try testing.expectEqualStrings("0126789", try contents(&t, &out));
    try t.delete(0, 2);
    try t.delete(t.len() - 1, 1);
    try testing.expectEqualStrings("2678", try contents(&t, &out));
    try t.delete(0, 100); // clamps
    try testing.expectEqual(@as(usize, 0), t.len());
    try testing.expectEqual(@as(usize, 0), t.pieceCount());
    try t.validate();
    try t.insert(0, "again");
    try testing.expectEqualStrings("again", try contents(&t, &out));
}

test "line index follows inserts and deletes of newlines" {
    var t = try PieceTable.initWithOriginal(testing.allocator, "one\ntwo\nthree", false);
    defer t.deinit();
    try testing.expectEqual(@as(usize, 3), t.lineCount());
    try t.insert(3, "\nextra"); // one / extra / two / three
    try testing.expectEqual(@as(usize, 4), t.lineCount());
    try testing.expectEqual(@as(usize, 4), t.lineStart(1));
    try testing.expectEqual(@as(usize, 10), t.lineStart(2));
    try testing.expectEqual(@as(usize, 1), t.lineOfOffset(4));
    try testing.expectEqual(@as(usize, 0), t.lineOfOffset(3)); // the newline itself ends line 0
    try testing.expectEqual(@as(usize, 1), t.lineOfOffset(9));
    try t.delete(3, 7); // remove "\nextra\n"
    try testing.expectEqual(@as(usize, 2), t.lineCount());
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(testing.allocator);
    try testing.expectEqualStrings("onetwo\nthree", try contents(&t, &out));
    try t.validate();
}

test "lineOfOffset and lineStart are inverse across the whole document" {
    var t = try PieceTable.initWithOriginal(testing.allocator, "a\nbb\n\nccc\n", false);
    defer t.deinit();
    try t.insert(4, "X\nY");
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(testing.allocator);
    const text = try contents(&t, &out);
    var line: usize = 0;
    for (0..text.len + 1) |off| {
        try testing.expectEqual(line, t.lineOfOffset(off));
        if (off < text.len and text[off] == '\n') line += 1;
    }
    for (0..t.lineCount()) |l| try testing.expectEqual(l, t.lineOfOffset(t.lineStart(l)));
}

test "CRLF: the line end excludes the carriage return" {
    var t = try PieceTable.initWithOriginal(testing.allocator, "ab\r\ncd\r\n", false);
    defer t.deinit();
    try testing.expectEqual(@as(usize, 2), t.lineEnd(0));
    try testing.expectEqual(@as(usize, 4), t.lineStart(1));
    try testing.expectEqual(@as(usize, 6), t.lineEnd(1));
}

test "slice borrows within a piece and copies across pieces" {
    var t = try PieceTable.initWithOriginal(testing.allocator, "hello world", false);
    defer t.deinit();
    var scratch: std.ArrayListUnmanaged(u8) = .empty;
    defer scratch.deinit(testing.allocator);
    const within = try t.slice(0, 5, &scratch, testing.allocator);
    try testing.expectEqualStrings("hello", within);
    try testing.expectEqual(@as(usize, 0), scratch.items.len); // no copy was needed
    try t.insert(5, "!!");
    try testing.expectEqualStrings("lo!! w", try t.slice(3, 9, &scratch, testing.allocator));
    try testing.expectEqualStrings("", try t.slice(4, 4, &scratch, testing.allocator));
}

test "random edits match a naive model, and every invariant holds" {
    for ([_]u64{ 0xC0FFEE, 1, 0xDEADBEEF, 42, 987654321 }) |seed| try randomRun(seed);
}

fn randomRun(seed: u64) !void {
    var t = try PieceTable.initWithOriginal(testing.allocator, "the quick brown fox\njumps over\nthe lazy dog\n", false);
    defer t.deinit();
    var model: std.ArrayListUnmanaged(u8) = .empty;
    defer model.deinit(testing.allocator);
    try model.appendSlice(testing.allocator, "the quick brown fox\njumps over\nthe lazy dog\n");

    var prng = std.Random.DefaultPrng.init(seed);
    const rand = prng.random();
    const snippets = [_][]const u8{ "x", "ab", "\n", "line\n", "\n\n", "zzz zzz", "é", "" };
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(testing.allocator);

    for (0..1500) |step| {
        if (rand.boolean() or model.items.len == 0) {
            const at = rand.uintAtMost(usize, model.items.len);
            const s = snippets[rand.uintLessThan(usize, snippets.len)];
            try t.insert(at, s);
            try model.insertSlice(testing.allocator, at, s);
        } else {
            const at = rand.uintLessThan(usize, model.items.len);
            const n = rand.uintAtMost(usize, @min(8, model.items.len - at));
            try t.delete(at, n);
            model.replaceRangeAssumeCapacity(at, n, "");
        }
        try testing.expectEqual(model.items.len, t.len());
        if (step % 25 == 0) {
            try testing.expectEqualStrings(model.items, try contents(&t, &out));
            try t.validate();
            // Line index agrees with a scan of the model.
            var nls: usize = 0;
            for (model.items) |c| nls += @intFromBool(c == '\n');
            try testing.expectEqual(nls + 1, t.lineCount());
            var line: usize = 0;
            var start: usize = 0;
            for (model.items, 0..) |c, i| {
                if (c == '\n') {
                    line += 1;
                    start = i + 1;
                    try testing.expectEqual(start, t.lineStart(line));
                }
            }
            const probe = rand.uintAtMost(usize, model.items.len);
            var expect_line: usize = 0;
            for (model.items[0..probe]) |c| expect_line += @intFromBool(c == '\n');
            try testing.expectEqual(expect_line, t.lineOfOffset(probe));
        }
    }
    try testing.expectEqualStrings(model.items, try contents(&t, &out));
    try t.validate();
}

test "many edits keep the tree shallow (no pathological degeneration)" {
    var t = try PieceTable.initWithOriginal(testing.allocator, "x", false);
    defer t.deinit();
    // Alternate insert positions so pieces cannot coalesce.
    for (0..4000) |i| try t.insert(if (i % 2 == 0) 0 else t.len(), "ab");
    try t.validate();
    var scratch: std.ArrayListUnmanaged(u8) = .empty;
    defer scratch.deinit(testing.allocator);
    // Exercise deep queries; they must be fast enough to finish instantly.
    var acc: usize = 0;
    for (0..4000) |i| acc += t.lineOfOffset(i) + (t.chunkAt(i * 2) orelse @as([]const u8, "")).len;
    try testing.expect(acc > 0);
    try testing.expect(t.pieceCount() > 1000);
}
