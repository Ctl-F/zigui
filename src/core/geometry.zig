//! Basic geometry and color types. All extern: they cross the C ABI boundary.
//! Coordinates are floats in logical pixels; the renderer applies scale.

const std = @import("std");

pub const Vec2 = extern struct {
    x: f32 = 0,
    y: f32 = 0,
};

pub const Size = extern struct {
    w: f32 = 0,
    h: f32 = 0,
};

pub const Rect = extern struct {
    x: f32 = 0,
    y: f32 = 0,
    w: f32 = 0,
    h: f32 = 0,

    pub fn right(self: Rect) f32 {
        return self.x + self.w;
    }

    pub fn bottom(self: Rect) f32 {
        return self.y + self.h;
    }

    pub fn contains(self: Rect, p: Vec2) bool {
        return p.x >= self.x and p.y >= self.y and p.x < self.right() and p.y < self.bottom();
    }

    pub fn isEmpty(self: Rect) bool {
        return self.w <= 0 or self.h <= 0;
    }

    pub fn intersects(a: Rect, b: Rect) bool {
        return a.x < b.right() and b.x < a.right() and a.y < b.bottom() and b.y < a.bottom();
    }

    /// Smallest rect covering both. An empty operand is ignored.
    pub fn unionWith(a: Rect, b: Rect) Rect {
        if (a.isEmpty()) return b;
        if (b.isEmpty()) return a;
        const x0 = @min(a.x, b.x);
        const y0 = @min(a.y, b.y);
        const x1 = @max(a.right(), b.right());
        const y1 = @max(a.bottom(), b.bottom());
        return .{ .x = x0, .y = y0, .w = x1 - x0, .h = y1 - y0 };
    }

    /// Overlap of both, or an empty rect.
    pub fn intersection(a: Rect, b: Rect) Rect {
        const x0 = @max(a.x, b.x);
        const y0 = @max(a.y, b.y);
        const x1 = @min(a.right(), b.right());
        const y1 = @min(a.bottom(), b.bottom());
        if (x1 <= x0 or y1 <= y0) return .{};
        return .{ .x = x0, .y = y0, .w = x1 - x0, .h = y1 - y0 };
    }
};

/// Straight (non-premultiplied) RGBA, 8 bits per channel.
pub const Color = extern struct {
    r: u8 = 0,
    g: u8 = 0,
    b: u8 = 0,
    a: u8 = 255,

    pub fn rgb(r: u8, g: u8, b: u8) Color {
        return .{ .r = r, .g = g, .b = b, .a = 255 };
    }

    pub fn rgba(r: u8, g: u8, b: u8, a: u8) Color {
        return .{ .r = r, .g = g, .b = b, .a = a };
    }

    pub const transparent: Color = .{ .r = 0, .g = 0, .b = 0, .a = 0 };
    pub const black: Color = .{ .r = 0, .g = 0, .b = 0, .a = 255 };
    pub const white: Color = .{ .r = 255, .g = 255, .b = 255, .a = 255 };
};

test "rect union, intersection, contains" {
    const a: Rect = .{ .x = 0, .y = 0, .w = 10, .h = 10 };
    const b: Rect = .{ .x = 5, .y = 5, .w = 10, .h = 10 };

    const u = a.unionWith(b);
    try std.testing.expectEqual(@as(f32, 15), u.w);
    try std.testing.expectEqual(@as(f32, 15), u.h);

    const i = a.intersection(b);
    try std.testing.expectEqual(@as(f32, 5), i.x);
    try std.testing.expectEqual(@as(f32, 5), i.w);

    const far: Rect = .{ .x = 100, .y = 100, .w = 1, .h = 1 };
    try std.testing.expect(a.intersection(far).isEmpty());
    try std.testing.expect(!a.intersects(far));

    try std.testing.expect(a.contains(.{ .x = 0, .y = 0 }));
    try std.testing.expect(!a.contains(.{ .x = 10, .y = 10 })); // right/bottom edges are exclusive
}

test "empty rect is ignored by union" {
    const a: Rect = .{ .x = 2, .y = 3, .w = 4, .h = 5 };
    const empty: Rect = .{};
    try std.testing.expectEqual(a, a.unionWith(empty));
    try std.testing.expectEqual(a, empty.unionWith(a));
}

test "extern layout sizes" {
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(Rect));
    try std.testing.expectEqual(@as(usize, 4), @sizeOf(Color));
}
