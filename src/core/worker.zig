//! Work that happens off the UI thread posts its results here. The UI core is
//! single-threaded: worker threads never touch the tree. They `push` results
//! into a `Queue`, which calls the `wake` function (so a sleeping event loop
//! runs another iteration), and the UI thread `drain`s the queue once per frame
//! (or when woken) and applies the results.
//!
//!     var q: Queue(Line) = .{ .gpa = gpa, .wake = sdl.wake };
//!     // worker thread:   try q.push(line);
//!     // UI thread:       var batch: std.ArrayListUnmanaged(Line) = .empty;
//!     //                  q.drain(&batch);  ...handle...  batch.clearRetainingCapacity();
//!
//! The lock is a tiny spin lock (critical sections are an append or a swap), so
//! no `Io` instance is needed.

const std = @import("std");

pub fn Queue(comptime T: type) type {
    return struct {
        const Self = @This();

        gpa: std.mem.Allocator,
        /// Called after every push (from the pushing thread). `Ui.wake` in practice.
        wake: ?*const fn () void = null,
        items: std.ArrayListUnmanaged(T) = .empty,
        lock: std.atomic.Mutex = .unlocked,

        pub fn deinit(self: *Self) void {
            self.items.deinit(self.gpa);
        }

        fn acquire(self: *Self) void {
            while (!self.lock.tryLock()) std.atomic.spinLoopHint();
        }

        /// Add an item (any thread).
        pub fn push(self: *Self, item: T) !void {
            self.acquire();
            const r = self.items.append(self.gpa, item);
            self.lock.unlock();
            try r;
            if (self.wake) |w| w();
        }

        /// Move everything queued onto the end of `out` (the UI thread).
        pub fn drain(self: *Self, out: *std.ArrayListUnmanaged(T)) void {
            self.acquire();
            defer self.lock.unlock();
            out.appendSlice(self.gpa, self.items.items) catch return;
            self.items.clearRetainingCapacity();
        }

        /// True if something is waiting.
        pub fn pending(self: *Self) bool {
            self.acquire();
            defer self.lock.unlock();
            return self.items.items.len > 0;
        }
    };
}

// ---- tests -----------------------------------------------------------------

const testing = std.testing;

var wakes: std.atomic.Value(u32) = .init(0);

fn countWake() void {
    _ = wakes.fetchAdd(1, .monotonic);
}

fn producer(q: *Queue(u32), n: u32) void {
    for (0..n) |i| q.push(@intCast(i)) catch return;
}

test "items pushed from several threads arrive exactly once, and each push wakes the loop" {
    wakes.store(0, .monotonic);
    var q: Queue(u32) = .{ .gpa = testing.allocator, .wake = countWake };
    defer q.deinit();
    var threads: [4]std.Thread = undefined;
    for (&threads) |*t| t.* = try std.Thread.spawn(.{}, producer, .{ &q, 250 });
    for (threads) |t| t.join();
    var out: std.ArrayListUnmanaged(u32) = .empty;
    defer out.deinit(testing.allocator);
    q.drain(&out);
    try testing.expectEqual(@as(usize, 1000), out.items.len);
    try testing.expectEqual(@as(u32, 1000), wakes.load(.monotonic));
    try testing.expect(!q.pending());
    // Per-thread order is preserved: each value 0..249 appears four times.
    var counts: [250]u8 = @splat(0);
    for (out.items) |v| counts[v] += 1;
    for (counts) |c| try testing.expectEqual(@as(u8, 4), c);
}
