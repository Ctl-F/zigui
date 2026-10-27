//! Background newline indexing for memory-mapped files.
//!
//! A worker thread scans the mapped bytes in chunks and hands the newline
//! offsets of each chunk to the UI thread through a small ring. The UI thread
//! calls `take` (usually once a frame) and feeds the chunks to
//! `PieceTable.appendOriginalIndex`; nothing in the UI core is touched from the
//! worker. If the ring is full the worker waits, so a slow UI never makes it
//! buffer the whole file's index.
//!
//! `wake` is called from the worker after it posts a chunk: set it to something
//! that unblocks the platform event loop (the SDL shim's `wake`), so progress is
//! drawn even when the user is idle.

const std = @import("std");

/// Offsets of the '\n' bytes found in one stretch of the file, and how far the
/// scan has got (the end of that stretch).
pub const Chunk = struct {
    offsets: []usize,
    scanned_to: usize,
};

pub const ring_len = 32;
pub const default_chunk_bytes: usize = 4 * 1024 * 1024;

pub const Wake = struct {
    ctx: ?*anyopaque = null,
    call: *const fn (ctx: ?*anyopaque) void,
};

pub const Indexer = struct {
    gpa: std.mem.Allocator,
    bytes: []const u8,
    chunk_bytes: usize,
    wake: ?Wake,
    thread: ?std.Thread = null,
    cancel_flag: std.atomic.Value(bool) = .init(false),
    done_flag: std.atomic.Value(bool) = .init(false),
    lock: std.atomic.Mutex = .unlocked,
    ring: [ring_len]Chunk = undefined,
    ring_head: usize = 0,
    ring_count: usize = 0,
    /// Inline mode only: where the next chunk starts.
    next_pos: usize = 0,

    pub const Options = struct {
        chunk_bytes: usize = default_chunk_bytes,
        wake: ?Wake = null,
        /// Scan on the calling thread, a ring's worth at a time as `take` is
        /// called (single-threaded targets, and tests that want determinism).
        synchronous: bool = false,
    };

    /// Start scanning `bytes`, which must stay valid until `destroy`.
    pub fn start(gpa: std.mem.Allocator, bytes: []const u8, opts: Options) !*Indexer {
        const self = try gpa.create(Indexer);
        errdefer gpa.destroy(self);
        self.* = .{ .gpa = gpa, .bytes = bytes, .chunk_bytes = @max(opts.chunk_bytes, 1), .wake = opts.wake };
        if (opts.synchronous or @import("builtin").single_threaded) {
            self.fillInline();
        } else {
            self.thread = try std.Thread.spawn(.{}, run, .{self});
        }
        return self;
    }

    /// Stop the scan, wait for the worker, and free anything not yet taken.
    pub fn destroy(self: *Indexer) void {
        self.cancel_flag.store(true, .release);
        if (self.thread) |t| t.join();
        for (0..self.ring_count) |i| self.gpa.free(self.ring[(self.ring_head + i) % ring_len].offsets);
        self.gpa.destroy(self);
    }

    fn acquire(self: *Indexer) void {
        while (!self.lock.tryLock()) std.atomic.spinLoopHint();
    }

    /// The newline offsets in the chunk starting at `pos`, or null if memory ran out.
    fn scanChunk(self: *Indexer, pos: usize) ?Chunk {
        const end = @min(pos + self.chunk_bytes, self.bytes.len);
        var offsets: std.ArrayListUnmanaged(usize) = .empty;
        var at = pos;
        while (std.mem.indexOfScalarPos(u8, self.bytes[0..end], at, '\n')) |i| : (at = i + 1) {
            offsets.append(self.gpa, i) catch {
                offsets.deinit(self.gpa);
                return null;
            };
        }
        const owned = offsets.toOwnedSlice(self.gpa) catch {
            offsets.deinit(self.gpa);
            return null;
        };
        return .{ .offsets = owned, .scanned_to = end };
    }

    fn tryPush(self: *Indexer, chunk: Chunk) bool {
        self.acquire();
        defer self.lock.unlock();
        if (self.ring_count == ring_len) return false;
        self.ring[(self.ring_head + self.ring_count) % ring_len] = chunk;
        self.ring_count += 1;
        return true;
    }

    fn run(self: *Indexer) void {
        var pos: usize = 0;
        while (pos < self.bytes.len and !self.cancel_flag.load(.acquire)) {
            const chunk = self.scanChunk(pos) orelse break; // out of memory: stop indexing
            while (!self.tryPush(chunk)) {
                if (self.cancel_flag.load(.acquire)) {
                    self.gpa.free(chunk.offsets);
                    return;
                }
                std.Thread.yield() catch {};
            }
            if (self.wake) |w| w.call(w.ctx);
            pos = chunk.scanned_to;
        }
        self.done_flag.store(true, .release);
    }

    /// Inline mode: scan until the ring is full or the file is done.
    fn fillInline(self: *Indexer) void {
        while (self.next_pos < self.bytes.len) {
            if (self.ring_count == ring_len) return;
            const chunk = self.scanChunk(self.next_pos) orelse break;
            _ = self.tryPush(chunk);
            self.next_pos = chunk.scanned_to;
        }
        self.done_flag.store(true, .release);
    }

    /// Move every finished chunk into `out`, in order, and return how many. The
    /// caller owns each chunk's `offsets` and frees them with `gpa`. In inline
    /// mode this also scans the next ring's worth.
    pub fn take(self: *Indexer, out: *[ring_len]Chunk) usize {
        self.acquire();
        const n = self.ring_count;
        for (0..n) |i| out[i] = self.ring[(self.ring_head + i) % ring_len];
        self.ring_head = (self.ring_head + n) % ring_len;
        self.ring_count = 0;
        self.lock.unlock();
        if (self.thread == null and !self.done_flag.load(.acquire)) self.fillInline();
        return n;
    }

    /// The scan has produced everything (chunks may still be waiting for `take`).
    pub fn isFinished(self: *const Indexer) bool {
        return self.done_flag.load(.acquire);
    }
};

// ---- tests -----------------------------------------------------------------

const testing = std.testing;
const PieceTable = @import("piece_table.zig").PieceTable;

fn sampleText(gpa: std.mem.Allocator, lines: usize) ![]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(gpa);
    for (0..lines) |i| {
        try buf.print(gpa, "line {d} xxxxxxx\n", .{i});
        if (i % 7 == 0) try buf.append(gpa, '\n'); // some empty lines
    }
    try buf.appendSlice(gpa, "no newline at the end");
    return buf.toOwnedSlice(gpa);
}

/// Feed everything the indexer has produced into `table`; true when it is complete.
fn pump(ix: *Indexer, table: *PieceTable) !bool {
    var chunks: [ring_len]Chunk = undefined;
    const n = ix.take(&chunks);
    for (chunks[0..n]) |c| {
        defer testing.allocator.free(c.offsets);
        try table.appendOriginalIndex(c.offsets, c.scanned_to);
    }
    return !table.indexing;
}

fn expectSameAsEager(text: []const u8, table: *const PieceTable) !void {
    var eager = try PieceTable.initWithOriginal(testing.allocator, text, false);
    defer eager.deinit();
    try testing.expectEqual(eager.lineCount(), table.lineCount());
    var line: usize = 0;
    while (line < eager.lineCount()) : (line += 1) {
        try testing.expectEqual(eager.lineStart(line), table.lineStart(line));
    }
    try testing.expectEqual(eager.lineOfOffset(text.len / 2), table.lineOfOffset(text.len / 2));
}

test "a background scan builds the same index as an eager one, chunk by chunk" {
    const text = try sampleText(testing.allocator, 3000);
    defer testing.allocator.free(text);
    var table = try PieceTable.initMapped(testing.allocator, text);
    defer table.deinit();
    const ix = try Indexer.start(testing.allocator, text, .{ .chunk_bytes = 1000 });
    defer ix.destroy();
    var spins: usize = 0;
    while (!try pump(ix, &table)) : (spins += 1) {
        try testing.expect(spins < 10_000_000);
        std.Thread.yield() catch {};
    }
    try testing.expect(ix.isFinished());
    try expectSameAsEager(text, &table);
    try table.validate();
}

test "an inline scan with a full ring continues across takes" {
    const text = try sampleText(testing.allocator, 2000);
    defer testing.allocator.free(text);
    var table = try PieceTable.initMapped(testing.allocator, text);
    defer table.deinit();
    // 64-byte chunks make far more than the ring holds.
    const ix = try Indexer.start(testing.allocator, text, .{ .chunk_bytes = 64, .synchronous = true });
    defer ix.destroy();
    var rounds: usize = 0;
    while (!try pump(ix, &table)) : (rounds += 1) try testing.expect(rounds < 10_000);
    try testing.expect(rounds > 2);
    try expectSameAsEager(text, &table);
}

test "the wake hook runs as chunks arrive" {
    const text = try sampleText(testing.allocator, 400);
    defer testing.allocator.free(text);
    const Counter = struct {
        var n: std.atomic.Value(u32) = .init(0);
        fn wake(_: ?*anyopaque) void {
            _ = n.fetchAdd(1, .monotonic);
        }
    };
    Counter.n.store(0, .monotonic);
    const ix = try Indexer.start(testing.allocator, text, .{ .chunk_bytes = 500, .wake = .{ .call = Counter.wake } });
    var table = try PieceTable.initMapped(testing.allocator, text);
    defer table.deinit();
    while (!try pump(ix, &table)) std.Thread.yield() catch {};
    ix.destroy();
    try testing.expect(Counter.n.load(.monotonic) >= text.len / 500);
}

test "destroying the indexer early stops the worker and frees what it made" {
    const text = try sampleText(testing.allocator, 20000);
    defer testing.allocator.free(text);
    var i: usize = 0;
    while (i < 20) : (i += 1) {
        const ix = try Indexer.start(testing.allocator, text, .{ .chunk_bytes = 256 });
        if (i % 2 == 0) {
            var chunks: [ring_len]Chunk = undefined;
            const n = ix.take(&chunks);
            for (chunks[0..n]) |c| testing.allocator.free(c.offsets);
        }
        ix.destroy(); // leak-checked
    }
}

test "an empty file has nothing to scan" {
    var table = try PieceTable.initMapped(testing.allocator, "");
    defer table.deinit();
    const ix = try Indexer.start(testing.allocator, "", .{});
    defer ix.destroy();
    var spins: usize = 0;
    while (!ix.isFinished()) : (spins += 1) try testing.expect(spins < 1_000_000);
    var chunks: [ring_len]Chunk = undefined;
    try testing.expectEqual(@as(usize, 0), ix.take(&chunks));
}
