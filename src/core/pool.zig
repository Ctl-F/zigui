//! Chunked object pool with stable addresses and generational handles.
//!
//! - Objects live in fixed-size chunks that are never moved or reallocated, so
//!   a `*T` obtained from the pool stays valid until that object is destroyed.
//!   (A plain ArrayList of T would dangle pointers on growth.)
//! - Freed slots are recycled through a free list. Each reuse bumps the slot's
//!   generation, so old handles to the slot stop resolving.
//! - Growth allocates one new chunk at a time. Pass `reserve` ahead of time if
//!   you need allocation-free creation in a hot path.

const std = @import("std");
const Handle = @import("handle.zig").Handle;

pub fn Pool(comptime T: type, comptime chunk_len: u32) type {
    comptime std.debug.assert(chunk_len > 0);

    return struct {
        const Self = @This();
        const none: u32 = std.math.maxInt(u32);

        const Slot = struct {
            value: T,
            generation: u32,
            occupied: bool,
            next_free: u32,
        };
        const Chunk = [chunk_len]Slot;

        allocator: std.mem.Allocator,
        chunks: std.ArrayListUnmanaged(*Chunk) = .empty,
        /// Number of slots ever handed out (occupied or on the free list).
        slots_used: u32 = 0,
        free_head: u32 = none,
        live: u32 = 0,

        pub fn init(allocator: std.mem.Allocator) Self {
            return .{ .allocator = allocator };
        }

        pub fn deinit(self: *Self) void {
            for (self.chunks.items) |chunk| self.allocator.destroy(chunk);
            self.chunks.deinit(self.allocator);
            self.* = undefined;
        }

        /// Number of live objects.
        pub fn count(self: *const Self) u32 {
            return self.live;
        }

        /// Total slots available without allocating.
        pub fn capacity(self: *const Self) u32 {
            return @intCast(self.chunks.items.len * chunk_len);
        }

        /// Ensure at least `total` slots exist so the next creates cannot allocate.
        pub fn reserve(self: *Self, total: u32) !void {
            while (self.capacity() < total) try self.addChunk();
        }

        fn addChunk(self: *Self) !void {
            const chunk = try self.allocator.create(Chunk);
            errdefer self.allocator.destroy(chunk);
            try self.chunks.append(self.allocator, chunk);
            for (chunk) |*slot| {
                slot.generation = 1; // generation 0 is reserved for invalid handles
                slot.occupied = false;
                slot.next_free = none;
            }
        }

        fn slotAt(self: *const Self, index: u32) *Slot {
            const chunk = self.chunks.items[index / chunk_len];
            return &chunk[index % chunk_len];
        }

        /// Create an object and return its handle.
        pub fn create(self: *Self, value: T) !Handle {
            var index: u32 = undefined;
            if (self.free_head != none) {
                index = self.free_head;
                self.free_head = self.slotAt(index).next_free;
            } else {
                if (self.slots_used == self.capacity()) try self.addChunk();
                index = self.slots_used;
                self.slots_used += 1;
            }
            const slot = self.slotAt(index);
            slot.value = value;
            slot.occupied = true;
            slot.next_free = none;
            self.live += 1;
            return .{ .index = index, .generation = slot.generation };
        }

        /// True if the handle refers to a live object.
        pub fn isValid(self: *const Self, h: Handle) bool {
            if (h.isNull() or h.index >= self.slots_used) return false;
            const slot = self.slotAt(h.index);
            return slot.occupied and slot.generation == h.generation;
        }

        /// Resolve a handle to a stable pointer, or null if it is stale.
        pub fn get(self: *Self, h: Handle) ?*T {
            if (!self.isValid(h)) return null;
            return &self.slotAt(h.index).value;
        }

        pub fn getConst(self: *const Self, h: Handle) ?*const T {
            if (!self.isValid(h)) return null;
            return &self.slotAt(h.index).value;
        }

        /// Destroy an object. Returns false if the handle was already stale.
        /// The caller is responsible for any cleanup the value itself needs.
        pub fn destroy(self: *Self, h: Handle) bool {
            if (!self.isValid(h)) return false;
            const slot = self.slotAt(h.index);
            slot.occupied = false;
            slot.generation +%= 1;
            if (slot.generation == 0) slot.generation = 1; // skip the reserved value on wrap
            slot.next_free = self.free_head;
            self.free_head = h.index;
            self.live -= 1;
            return true;
        }

        /// Iterate live objects in slot order. Do not create or destroy while iterating.
        pub const Iterator = struct {
            pool: *Self,
            next_index: u32 = 0,

            pub const Entry = struct { handle: Handle, ptr: *T };

            pub fn next(self: *Iterator) ?Entry {
                while (self.next_index < self.pool.slots_used) {
                    const i = self.next_index;
                    self.next_index += 1;
                    const slot = self.pool.slotAt(i);
                    if (slot.occupied) {
                        return .{
                            .handle = .{ .index = i, .generation = slot.generation },
                            .ptr = &slot.value,
                        };
                    }
                }
                return null;
            }
        };

        pub fn iterator(self: *Self) Iterator {
            return .{ .pool = self };
        }
    };
}

test "create, get, destroy" {
    var pool = Pool(u32, 4).init(std.testing.allocator);
    defer pool.deinit();

    const a = try pool.create(10);
    const b = try pool.create(20);
    try std.testing.expectEqual(@as(u32, 2), pool.count());
    try std.testing.expectEqual(@as(u32, 10), pool.get(a).?.*);
    try std.testing.expectEqual(@as(u32, 20), pool.get(b).?.*);

    try std.testing.expect(pool.destroy(a));
    try std.testing.expectEqual(@as(u32, 1), pool.count());
    try std.testing.expect(pool.get(a) == null);
    try std.testing.expect(!pool.destroy(a)); // double destroy is rejected
}

test "stale handle is rejected after slot reuse" {
    var pool = Pool(u32, 4).init(std.testing.allocator);
    defer pool.deinit();

    const old = try pool.create(1);
    try std.testing.expect(pool.destroy(old));
    const fresh = try pool.create(2);

    // Same slot, different generation.
    try std.testing.expectEqual(old.index, fresh.index);
    try std.testing.expect(old.generation != fresh.generation);
    try std.testing.expect(pool.get(old) == null);
    try std.testing.expectEqual(@as(u32, 2), pool.get(fresh).?.*);
}

test "addresses stay stable across growth" {
    var pool = Pool(u64, 4).init(std.testing.allocator);
    defer pool.deinit();

    const first = try pool.create(111);
    const first_ptr = pool.get(first).?;

    // Force several new chunks.
    var i: u64 = 0;
    while (i < 100) : (i += 1) _ = try pool.create(i);

    try std.testing.expect(pool.get(first).? == first_ptr);
    try std.testing.expectEqual(@as(u64, 111), first_ptr.*);
}

test "reserve makes creation allocation-free" {
    var pool = Pool(u32, 8).init(std.testing.allocator);
    defer pool.deinit();

    try pool.reserve(20);
    try std.testing.expect(pool.capacity() >= 20);
    const cap_before = pool.capacity();

    var i: u32 = 0;
    while (i < 20) : (i += 1) _ = try pool.create(i);
    try std.testing.expectEqual(cap_before, pool.capacity());
}

test "free list recycles slots and iterator skips holes" {
    var pool = Pool(u32, 4).init(std.testing.allocator);
    defer pool.deinit();

    const a = try pool.create(1);
    const b = try pool.create(2);
    const c = try pool.create(3);
    _ = b;
    _ = pool.destroy(a);
    _ = pool.destroy(c);
    const d = try pool.create(4); // reuses the most recently freed slot (c's)
    try std.testing.expectEqual(@as(u32, 2), pool.count());
    try std.testing.expectEqual(c.index, d.index);

    var it = pool.iterator();
    var sum: u32 = 0;
    var seen: u32 = 0;
    while (it.next()) |e| {
        sum += e.ptr.*;
        seen += 1;
    }
    try std.testing.expectEqual(@as(u32, 2), seen);
    try std.testing.expectEqual(@as(u32, 6), sum); // 2 + 4
}
