//! Damage tracking: which part of the window must be redrawn this frame.
//!
//! The tree adds a rect whenever something it owns changes how it looks (a
//! paint-dirty node's old and new area, a node that moved or resized). The
//! renderer then redraws only the union of those rects. It never allocates:
//! up to `max_rects` separate rects are kept, and beyond that they collapse
//! into their bounding box (still correct, just larger).

const std = @import("std");
const Rect = @import("geometry.zig").Rect;

/// Pixels added around every damaged rect: focus rings, antialiasing, and text
/// that overhangs its node are painted slightly outside the node's rect.
pub const pad: f32 = 3;

pub const max_rects = 8;

pub const DamageRegion = struct {
    rects: [max_rects]Rect = undefined,
    n: u8 = 0,
    /// Everything is damaged (first frame, resize, theme switch).
    all: bool = false,

    pub fn clear(self: *DamageRegion) void {
        self.n = 0;
        self.all = false;
    }

    pub fn isEmpty(self: *const DamageRegion) bool {
        return !self.all and self.n == 0;
    }

    pub fn markAll(self: *DamageRegion) void {
        self.all = true;
    }

    /// Add `r` (window coordinates, unpadded).
    pub fn add(self: *DamageRegion, r: Rect) void {
        if (self.all or r.isEmpty()) return;
        const g: Rect = .{ .x = r.x - pad, .y = r.y - pad, .w = r.w + 2 * pad, .h = r.h + 2 * pad };
        for (self.rects[0..self.n]) |e| {
            if (contains(e, g)) return;
        }
        if (self.n == max_rects) {
            self.rects[0] = self.boundsWith(g);
            self.n = 1;
            return;
        }
        self.rects[self.n] = g;
        self.n += 1;
    }

    fn contains(outer: Rect, inner: Rect) bool {
        return inner.x >= outer.x and inner.y >= outer.y and inner.right() <= outer.right() and inner.bottom() <= outer.bottom();
    }

    fn boundsWith(self: *const DamageRegion, extra: Rect) Rect {
        var b = extra;
        for (self.rects[0..self.n]) |e| b = b.unionWith(e);
        return b;
    }

    /// The bounding box of everything damaged, or null if nothing (or everything,
    /// see `all`) is.
    pub fn bounds(self: *const DamageRegion) ?Rect {
        if (self.all or self.n == 0) return null;
        return self.boundsWith(self.rects[0]);
    }
};

test "rects are padded, merged when contained, and collapse past the limit" {
    var d: DamageRegion = .{};
    try std.testing.expect(d.isEmpty());
    d.add(.{ .x = 10, .y = 10, .w = 20, .h = 20 });
    d.add(.{ .x = 12, .y = 12, .w = 5, .h = 5 }); // inside the first
    try std.testing.expectEqual(@as(u8, 1), d.n);
    const b = d.bounds().?;
    try std.testing.expectEqual(@as(f32, 10 - pad), b.x);
    try std.testing.expectEqual(@as(f32, 20 + 2 * pad), b.w);

    var i: u32 = 0;
    while (i < 20) : (i += 1) d.add(.{ .x = @as(f32, @floatFromInt(i)) * 100, .y = 0, .w = 5, .h = 5 });
    try std.testing.expect(d.n <= max_rects);
    const all = d.bounds().?;
    try std.testing.expect(all.x <= 10 - pad and all.right() >= 1900 + 5); // still covers every rect added
}

test "empty rects are ignored; markAll wins and bounds reports null" {
    var d: DamageRegion = .{};
    d.add(.{ .x = 1, .y = 1, .w = 0, .h = 5 });
    try std.testing.expect(d.isEmpty());
    d.add(.{ .x = 0, .y = 0, .w = 5, .h = 5 });
    d.markAll();
    try std.testing.expect(!d.isEmpty() and d.all and d.bounds() == null);
    d.add(.{ .x = 0, .y = 0, .w = 5, .h = 5 });
    d.clear();
    try std.testing.expect(d.isEmpty());
}
