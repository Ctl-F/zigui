//! Selections: a sorted list of (anchor, head) byte ranges.
//!
//! A single cursor is a list of length one, so multi-cursor needs no special
//! case anywhere. `normalize` keeps the list sorted by position with no
//! overlaps: overlapping selections, and a caret touching or inside another
//! selection, merge into one.

const std = @import("std");

pub const Selection = struct {
    /// The fixed end of the selection.
    anchor: usize,
    /// The moving end; where the caret is drawn.
    head: usize,
    /// Column (code points) that vertical movement tries to return to; `unset`
    /// when the last move was not vertical.
    goal: usize = unset,
    /// The most recently added selection: scroll-follow and Escape use it.
    primary: bool = false,

    pub const unset = std.math.maxInt(usize);

    pub fn caret(at: usize) Selection {
        return .{ .anchor = at, .head = at };
    }

    pub fn start(self: Selection) usize {
        return @min(self.anchor, self.head);
    }

    pub fn end(self: Selection) usize {
        return @max(self.anchor, self.head);
    }

    pub fn isEmpty(self: Selection) bool {
        return self.anchor == self.head;
    }

    pub fn reversed(self: Selection) bool {
        return self.head < self.anchor;
    }

    fn lessThan(_: void, a: Selection, b: Selection) bool {
        if (a.start() != b.start()) return a.start() < b.start();
        return a.end() < b.end();
    }
};

pub const SelectionSet = struct {
    gpa: std.mem.Allocator,
    items: std.ArrayListUnmanaged(Selection) = .empty,

    pub fn init(gpa: std.mem.Allocator) SelectionSet {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *SelectionSet) void {
        self.items.deinit(self.gpa);
        self.* = undefined;
    }

    /// Replace everything with one selection.
    pub fn setSingle(self: *SelectionSet, anchor: usize, head: usize) !void {
        self.items.clearRetainingCapacity();
        try self.items.append(self.gpa, .{ .anchor = anchor, .head = head, .primary = true });
    }

    /// Add a selection and make it the primary one. Call `normalize` after.
    pub fn add(self: *SelectionSet, s: Selection) !void {
        for (self.items.items) |*x| x.primary = false;
        var sel = s;
        sel.primary = true;
        try self.items.append(self.gpa, sel);
    }

    pub fn assign(self: *SelectionSet, sels: []const Selection) !void {
        self.items.clearRetainingCapacity();
        try self.items.appendSlice(self.gpa, sels);
    }

    pub fn primaryIndex(self: *const SelectionSet) usize {
        for (self.items.items, 0..) |s, i| if (s.primary) return i;
        return self.items.items.len -| 1;
    }

    pub fn primary(self: *const SelectionSet) Selection {
        return self.items.items[self.primaryIndex()];
    }

    /// Copy for history (caller frees with `gpa`).
    pub fn clone(self: *const SelectionSet, gpa: std.mem.Allocator) ![]Selection {
        return gpa.dupe(Selection, self.items.items);
    }

    /// Sort, and merge overlapping selections (and carets touching one).
    pub fn normalize(self: *SelectionSet) void {
        const items = self.items.items;
        if (items.len < 2) {
            if (items.len == 1) items[0].primary = true;
            return;
        }
        std.mem.sort(Selection, items, {}, Selection.lessThan);
        var out: usize = 0;
        for (items[1..]) |next| {
            const cur = &items[out];
            const touching = next.start() == cur.end() and (next.isEmpty() or cur.isEmpty());
            if (next.start() < cur.end() or touching) {
                const s = cur.start();
                const e = @max(cur.end(), next.end());
                const rev = cur.reversed();
                cur.anchor = if (rev) e else s;
                cur.head = if (rev) s else e;
                cur.goal = Selection.unset;
                cur.primary = cur.primary or next.primary;
            } else {
                out += 1;
                items[out] = next;
            }
        }
        self.items.shrinkRetainingCapacity(out + 1);
        var any = false;
        for (self.items.items) |s| any = any or s.primary;
        if (!any) self.items.items[self.items.items.len - 1].primary = true;
    }
};

// ---- tests -----------------------------------------------------------------

const testing = std.testing;

fn set(sels: []const Selection) !SelectionSet {
    var s = SelectionSet.init(testing.allocator);
    try s.assign(sels);
    s.normalize();
    return s;
}

test "carets sort by position" {
    var s = try set(&.{ Selection.caret(9), Selection.caret(2), Selection.caret(5) });
    defer s.deinit();
    try testing.expectEqual(@as(usize, 3), s.items.items.len);
    try testing.expectEqual(@as(usize, 2), s.items.items[0].head);
    try testing.expectEqual(@as(usize, 9), s.items.items[2].head);
}

test "identical carets merge, and a caret inside or touching a selection is absorbed" {
    var s = try set(&.{ Selection.caret(4), Selection.caret(4), .{ .anchor = 10, .head = 20 }, Selection.caret(15), Selection.caret(20) });
    defer s.deinit();
    try testing.expectEqual(@as(usize, 2), s.items.items.len);
    try testing.expectEqual(@as(usize, 10), s.items.items[1].start());
    try testing.expectEqual(@as(usize, 20), s.items.items[1].end());
}

test "overlapping selections merge; touching non-empty selections stay separate" {
    var s = try set(&.{ .{ .anchor = 0, .head = 5 }, .{ .anchor = 3, .head = 8 }, .{ .anchor = 8, .head = 10 } });
    defer s.deinit();
    try testing.expectEqual(@as(usize, 2), s.items.items.len);
    try testing.expectEqual(@as(usize, 8), s.items.items[0].end());
    try testing.expectEqual(@as(usize, 8), s.items.items[1].start());
}

test "merging keeps the first selection's direction" {
    var s = try set(&.{ .{ .anchor = 6, .head = 2 }, .{ .anchor = 4, .head = 9 } });
    defer s.deinit();
    try testing.expectEqual(@as(usize, 1), s.items.items.len);
    try testing.expect(s.items.items[0].reversed());
    try testing.expectEqual(@as(usize, 2), s.items.items[0].start());
    try testing.expectEqual(@as(usize, 9), s.items.items[0].end());
}

test "the primary flag survives sorting and merging" {
    var s = SelectionSet.init(testing.allocator);
    defer s.deinit();
    try s.setSingle(10, 10);
    try s.add(Selection.caret(2)); // newest: primary
    s.normalize();
    try testing.expectEqual(@as(usize, 2), s.primary().head);
    try s.add(Selection.caret(2)); // merges into the existing caret at 2
    s.normalize();
    try testing.expectEqual(@as(usize, 2), s.items.items.len);
    try testing.expect(s.primary().head == 2);
}

test "clone and assign round-trip" {
    var s = try set(&.{ Selection.caret(1), .{ .anchor = 5, .head = 7 } });
    defer s.deinit();
    const copy = try s.clone(testing.allocator);
    defer testing.allocator.free(copy);
    try s.setSingle(0, 0);
    try s.assign(copy);
    try testing.expectEqual(@as(usize, 2), s.items.items.len);
    try testing.expectEqual(@as(usize, 7), s.items.items[1].end());
}
