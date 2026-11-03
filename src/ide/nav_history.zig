//! Back and forward through the places you jumped from: the list behind the
//! mouse's Back and Forward buttons (and Alt+Left / Alt+Right). No UI here.
//!
//!     var h: History = .init(gpa);
//!     defer h.deinit();
//!     h.record(.{ .path = "src/a.zig", .line = 10, .col = 5 });    // before jumping away from it
//!     if (h.back(here)) |loc| { ... open loc ... }                  // `here` is where you are now
//!     if (h.forward(here)) |loc| { ... }
//!
//! `record` is called with the place being left whenever the IDE jumps (go to
//! definition, a search hit, an error, quick open, opening a file). It drops the
//! forward list, like a browser. `back` and `forward` return null at the ends;
//! the place they are given (where you are now) is kept so the other button
//! returns to it. Locations are copied; the list is capped.

const std = @import("std");

pub const Location = struct {
    path: []const u8,
    line: u32,
    col: u32,
};

const max_entries = 100;

pub const History = struct {
    gpa: std.mem.Allocator,
    backs: std.ArrayListUnmanaged(Owned) = .empty,
    forwards: std.ArrayListUnmanaged(Owned) = .empty,
    /// Where `back`/`forward` last put you (returned to the caller, owned here until the next call).
    handed: ?Owned = null,

    const Owned = struct { path: []u8, line: u32, col: u32 };

    pub fn init(gpa: std.mem.Allocator) History {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *History) void {
        for (self.backs.items) |o| self.gpa.free(o.path);
        for (self.forwards.items) |o| self.gpa.free(o.path);
        self.backs.deinit(self.gpa);
        self.forwards.deinit(self.gpa);
        if (self.handed) |h| self.gpa.free(h.path);
    }

    fn own(self: *History, loc: Location) !Owned {
        return .{ .path = try self.gpa.dupe(u8, loc.path), .line = loc.line, .col = loc.col };
    }

    fn sameSpot(a: Owned, b: Location) bool {
        return a.line == b.line and std.mem.eql(u8, a.path, b.path);
    }

    /// Note that the user is about to leave `loc` for somewhere else.
    pub fn record(self: *History, loc: Location) void {
        if (loc.path.len == 0) return;
        for (self.forwards.items) |o| self.gpa.free(o.path);
        self.forwards.clearRetainingCapacity();
        if (self.backs.items.len > 0 and sameSpot(self.backs.items[self.backs.items.len - 1], loc)) return;
        const o = self.own(loc) catch return;
        if (self.backs.items.len == max_entries) {
            self.gpa.free(self.backs.orderedRemove(0).path);
        }
        self.backs.append(self.gpa, o) catch self.gpa.free(o.path);
    }

    fn take(self: *History, o: Owned) Location {
        if (self.handed) |h| self.gpa.free(h.path);
        self.handed = o;
        return .{ .path = o.path, .line = o.line, .col = o.col };
    }

    /// The place before the last jump (null when there is none). `here` is where you are now.
    pub fn back(self: *History, here: ?Location) ?Location {
        // Skip entries that are where we already are.
        while (self.backs.pop()) |o| {
            if (here) |h| {
                if (sameSpot(o, h)) {
                    self.gpa.free(o.path);
                    continue;
                }
            }
            if (here) |h| {
                if (self.own(h)) |mine| self.forwards.append(self.gpa, mine) catch self.gpa.free(mine.path) else |_| {}
            }
            return self.take(o);
        }
        return null;
    }

    /// The place you went back from (null when there is none).
    pub fn forward(self: *History, here: ?Location) ?Location {
        while (self.forwards.pop()) |o| {
            if (here) |h| {
                if (sameSpot(o, h)) {
                    self.gpa.free(o.path);
                    continue;
                }
            }
            if (here) |h| {
                if (self.own(h)) |mine| self.backs.append(self.gpa, mine) catch self.gpa.free(mine.path) else |_| {}
            }
            return self.take(o);
        }
        return null;
    }

    pub fn canBack(self: *const History) bool {
        return self.backs.items.len > 0;
    }

    pub fn canForward(self: *const History) bool {
        return self.forwards.items.len > 0;
    }
};

const testing = std.testing;

test "back returns to where a jump started, forward returns again, a new jump drops forward" {
    var h = History.init(testing.allocator);
    defer h.deinit();
    // At a:10, jump to b:3 (record the place left), then from b:3 jump to c:7.
    h.record(.{ .path = "a.zig", .line = 10, .col = 2 });
    h.record(.{ .path = "b.zig", .line = 3, .col = 1 });
    try testing.expect(h.canBack() and !h.canForward());

    var loc = h.back(.{ .path = "c.zig", .line = 7, .col = 1 }).?; // c -> b
    try testing.expectEqualStrings("b.zig", loc.path);
    try testing.expectEqual(@as(u32, 3), loc.line);
    loc = h.back(.{ .path = "b.zig", .line = 3, .col = 1 }).?; // b -> a
    try testing.expectEqualStrings("a.zig", loc.path);
    try testing.expectEqual(@as(u32, 10), loc.line);
    try testing.expect(h.back(.{ .path = "a.zig", .line = 10, .col = 2 }) == null);

    loc = h.forward(.{ .path = "a.zig", .line = 10, .col = 2 }).?; // a -> b
    try testing.expectEqualStrings("b.zig", loc.path);
    loc = h.forward(.{ .path = "b.zig", .line = 3, .col = 1 }).?; // b -> c
    try testing.expectEqualStrings("c.zig", loc.path);
    try testing.expect(h.forward(.{ .path = "c.zig", .line = 7, .col = 1 }) == null);

    // Going back and then jumping somewhere new forgets the way forward.
    _ = h.back(.{ .path = "c.zig", .line = 7, .col = 1 });
    try testing.expect(h.canForward());
    h.record(.{ .path = "b.zig", .line = 3, .col = 1 });
    try testing.expect(!h.canForward());
}

test "repeated and empty places are not recorded, and the list is capped" {
    var h = History.init(testing.allocator);
    defer h.deinit();
    h.record(.{ .path = "", .line = 1, .col = 1 });
    try testing.expect(!h.canBack());
    h.record(.{ .path = "a.zig", .line = 5, .col = 1 });
    h.record(.{ .path = "a.zig", .line = 5, .col = 9 });
    try testing.expectEqual(@as(usize, 1), h.backs.items.len);
    for (0..250) |i| h.record(.{ .path = "f.zig", .line = @intCast(i + 100), .col = 1 });
    try testing.expectEqual(@as(usize, 100), h.backs.items.len);
}
