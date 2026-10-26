//! The `Length` type used by every sizing field (min, max, basis, padding,
//! margin, gap) and the resolve-then-clamp rule.
//!
//! Sizing rule: resolve the preferred size to pixels, then clamp it to
//! [min, max] in absolute terms. If min > max, min wins.

const std = @import("std");

pub const Unit = enum(u32) {
    /// Logical pixels.
    px = 0,
    /// Percent (0-100) of the parent's content box on this axis.
    percent = 1,
    /// Size to content, then flex rules apply.
    auto = 2,
    /// Take remaining space (basis 0, grow 1).
    fill = 3,
    /// Shrink-wrap children, clamped by constraints.
    fit_content = 4,
};

/// C-compatible tagged length: a tag plus one float.
pub const Length = extern struct {
    unit: Unit = .auto,
    value: f32 = 0,

    pub fn px(v: f32) Length {
        return .{ .unit = .px, .value = v };
    }

    /// `v` is in percent: pct(10) means 10 percent.
    pub fn pct(v: f32) Length {
        return .{ .unit = .percent, .value = v };
    }

    pub const auto: Length = .{ .unit = .auto, .value = 0 };
    pub const fill: Length = .{ .unit = .fill, .value = 0 };
    pub const fit: Length = .{ .unit = .fit_content, .value = 0 };

    pub fn isFixed(self: Length) bool {
        return self.unit == .px or self.unit == .percent;
    }
};

/// Context needed to resolve a length on one axis.
pub const ResolveCtx = struct {
    /// Parent's content-box size on this axis, or null if the parent is itself
    /// sized by its contents (a percent against it is circular).
    parent: ?f32,
    /// The node's own content size on this axis (for auto / fit_content).
    content: f32,
    /// Space left over for `fill`.
    remaining: f32 = 0,
};

pub const Resolved = struct {
    value: f32,
    /// True when a percent had no usable parent and fell back to auto.
    /// Callers should emit a debug warning.
    circular_percent: bool = false,
};

pub fn resolve(len: Length, ctx: ResolveCtx) Resolved {
    return switch (len.unit) {
        .px => .{ .value = len.value },
        .percent => if (ctx.parent) |p|
            .{ .value = p * len.value / 100.0 }
        else
            .{ .value = ctx.content, .circular_percent = true },
        .auto, .fit_content => .{ .value = ctx.content },
        .fill => .{ .value = @max(ctx.remaining, 0) },
    };
}

/// Clamp `preferred` to [min, max]. When min > max, min wins.
pub fn clampSize(preferred: f32, min: f32, max: f32) f32 {
    return @max(min, @min(preferred, max));
}

/// Resolve preferred, min, and max lengths and clamp. `min` defaults to 0 and
/// `max` to unbounded when given as `auto`.
pub fn resolveClamped(preferred: Length, min: Length, max: Length, ctx: ResolveCtx) Resolved {
    var out = resolve(preferred, ctx);
    const lo = if (min.unit == .auto) 0.0 else resolve(min, ctx).value;
    const hi = if (max.unit == .auto) std.math.inf(f32) else resolve(max, ctx).value;
    out.value = clampSize(out.value, lo, hi);
    return out;
}

test "px and percent resolve" {
    const ctx: ResolveCtx = .{ .parent = 800, .content = 50 };
    try std.testing.expectEqual(@as(f32, 120), resolve(Length.px(120), ctx).value);
    try std.testing.expectEqual(@as(f32, 160), resolve(Length.pct(20), ctx).value);
    try std.testing.expectEqual(@as(f32, 50), resolve(Length.auto, ctx).value);
}

test "percent against content-sized parent falls back to auto and flags it" {
    const ctx: ResolveCtx = .{ .parent = null, .content = 42 };
    const r = resolve(Length.pct(50), ctx);
    try std.testing.expectEqual(@as(f32, 42), r.value);
    try std.testing.expect(r.circular_percent);
}

test "sidebar example: 20 percent, min 150, max 360" {
    const min = Length.px(150);
    const max = Length.px(360);
    const pref = Length.pct(20);

    // Small window: 20% of 500 is 100, held up to the 150 minimum.
    const small = resolveClamped(pref, min, max, .{ .parent = 500, .content = 0 });
    try std.testing.expectEqual(@as(f32, 150), small.value);

    // Mid window: 20% of 1500 is 300, inside the bounds.
    const mid = resolveClamped(pref, min, max, .{ .parent = 1500, .content = 0 });
    try std.testing.expectEqual(@as(f32, 300), mid.value);

    // 4K window: 20% of 3840 is 768, capped at 360.
    const big = resolveClamped(pref, min, max, .{ .parent = 3840, .content = 0 });
    try std.testing.expectEqual(@as(f32, 360), big.value);
}

test "min wins when min is greater than max" {
    try std.testing.expectEqual(@as(f32, 200), clampSize(50, 200, 100));
    try std.testing.expectEqual(@as(f32, 200), clampSize(500, 200, 100));
}

test "auto min and max are unbounded" {
    const r = resolveClamped(Length.px(77), Length.auto, Length.auto, .{ .parent = 100, .content = 0 });
    try std.testing.expectEqual(@as(f32, 77), r.value);
}

test "fill uses remaining space and never goes negative" {
    try std.testing.expectEqual(@as(f32, 30), resolve(Length.fill, .{ .parent = 100, .content = 0, .remaining = 30 }).value);
    try std.testing.expectEqual(@as(f32, 0), resolve(Length.fill, .{ .parent = 100, .content = 0, .remaining = -5 }).value);
}

test "length is a small fixed-size extern struct" {
    try std.testing.expectEqual(@as(usize, 8), @sizeOf(Length));
}
