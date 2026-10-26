//! Flex main-axis solver: the freeze-and-redistribute loop.
//!
//! Every item starts at its basis clamped to [min, max]. Leftover space is
//! shared by grow factors; overflow is taken back by shrink factors scaled by
//! basis (as in CSS flexbox). An item that hits its min or max is frozen at
//! that value and its share is redistributed among the rest. This repeats
//! until nobody new freezes, at most one pass per item.
//!
//! Pure function over slices: no allocation, no tree access. The caller
//! resolves `Length` values to pixels first (see length.zig).

const std = @import("std");
const clampSize = @import("length.zig").clampSize;

pub const Item = struct {
    /// Resolved basis in pixels.
    basis: f32,
    /// Resolved minimum (min wins over max on conflict).
    min: f32 = 0,
    /// Resolved maximum, unbounded by default.
    max: f32 = std.math.inf(f32),
    grow: f32 = 0,
    shrink: f32 = 1,
};

const eps: f32 = 1e-4;

fn factor(it: Item, growing: bool) f32 {
    if (growing) return @max(it.grow, 0);
    return @max(it.shrink, 0) * @max(it.basis, 0);
}

/// Compute main-axis sizes.
///
/// `available` is the container's content size on the main axis. `gap` is the
/// fixed space between adjacent items. `out` and `frozen` are caller-provided
/// scratch of the same length as `items`.
pub fn solve(items: []const Item, available: f32, gap: f32, out: []f32, frozen: []bool) void {
    std.debug.assert(out.len == items.len and frozen.len == items.len);
    if (items.len == 0) return;

    const gaps = gap * @as(f32, @floatFromInt(items.len - 1));
    const target = available - gaps;

    for (items, 0..) |it, i| {
        out[i] = clampSize(it.basis, it.min, it.max);
        frozen[i] = false;
    }

    var pass: usize = 0;
    while (pass <= items.len) : (pass += 1) {
        var used: f32 = 0;
        for (out) |s| used += s;
        const free = target - used;
        if (@abs(free) < eps) break;

        const growing = free > 0;
        var factor_sum: f32 = 0;
        for (items, 0..) |it, i| {
            if (frozen[i]) continue;
            const f = factor(it, growing);
            if (f <= 0) {
                frozen[i] = true; // cannot flex in this direction
            } else {
                factor_sum += f;
            }
        }
        if (factor_sum <= 0) break;

        var any_frozen = false;
        for (items, 0..) |it, i| {
            if (frozen[i]) continue;
            const want = out[i] + free * factor(it, growing) / factor_sum;
            const clamped = clampSize(want, it.min, it.max);
            out[i] = clamped;
            if (@abs(clamped - want) > eps) {
                frozen[i] = true;
                any_frozen = true;
            }
        }
        if (!any_frozen) break;
    }
}

fn expectSizes(expected: []const f32, actual: []const f32) !void {
    try std.testing.expectEqual(expected.len, actual.len);
    for (expected, actual) |e, a| try std.testing.expectApproxEqAbs(e, a, 0.01);
}

test "no flex: sizes are the clamped basis" {
    const items = [_]Item{ .{ .basis = 100 }, .{ .basis = 50, .min = 80 } };
    var out: [2]f32 = undefined;
    var frozen: [2]bool = undefined;
    solve(&items, 1000, 0, &out, &frozen);
    // Grow is 0 for both, so leftover space stays unused.
    try expectSizes(&.{ 100, 80 }, &out);
}

test "leftover space is shared by grow factors" {
    const items = [_]Item{
        .{ .basis = 0, .grow = 1 },
        .{ .basis = 0, .grow = 2 },
    };
    var out: [2]f32 = undefined;
    var frozen: [2]bool = undefined;
    solve(&items, 300, 0, &out, &frozen);
    try expectSizes(&.{ 100, 200 }, &out);
}

test "a grown item that hits max is frozen and its share is redistributed" {
    const items = [_]Item{
        .{ .basis = 0, .grow = 1, .max = 50 },
        .{ .basis = 0, .grow = 1 },
    };
    var out: [2]f32 = undefined;
    var frozen: [2]bool = undefined;
    solve(&items, 300, 0, &out, &frozen);
    try expectSizes(&.{ 50, 250 }, &out);
}

test "overflow is taken back by shrink, scaled by basis" {
    const items = [_]Item{
        .{ .basis = 200 },
        .{ .basis = 200 },
    };
    var out: [2]f32 = undefined;
    var frozen: [2]bool = undefined;
    solve(&items, 300, 0, &out, &frozen);
    try expectSizes(&.{ 150, 150 }, &out);
}

test "a shrunk item that hits min is frozen and the other absorbs the rest" {
    const items = [_]Item{
        .{ .basis = 200, .min = 180 },
        .{ .basis = 200 },
    };
    var out: [2]f32 = undefined;
    var frozen: [2]bool = undefined;
    solve(&items, 300, 0, &out, &frozen);
    try expectSizes(&.{ 180, 120 }, &out);
}

test "gaps reduce the space to distribute" {
    const items = [_]Item{
        .{ .basis = 0, .grow = 1 },
        .{ .basis = 0, .grow = 1 },
        .{ .basis = 0, .grow = 1 },
    };
    var out: [3]f32 = undefined;
    var frozen: [3]bool = undefined;
    solve(&items, 100, 10, &out, &frozen); // 100 - 2*10 = 80 shared three ways
    try expectSizes(&.{ 80.0 / 3.0, 80.0 / 3.0, 80.0 / 3.0 }, &out);
}

test "sidebar plus content" {
    const items = [_]Item{
        .{ .basis = 300, .min = 150, .max = 360 }, // sidebar: 20% of 1500, no grow
        .{ .basis = 0, .grow = 1 }, // content fills the rest
    };
    var out: [2]f32 = undefined;
    var frozen: [2]bool = undefined;
    solve(&items, 1500, 0, &out, &frozen);
    try expectSizes(&.{ 300, 1200 }, &out);
}

test "min wins when min exceeds max" {
    const items = [_]Item{.{ .basis = 50, .min = 200, .max = 100 }};
    var out: [1]f32 = undefined;
    var frozen: [1]bool = undefined;
    solve(&items, 500, 0, &out, &frozen);
    try expectSizes(&.{200}, &out);
}

test "when everything is at min and still overflows, sizes stay at min" {
    const items = [_]Item{
        .{ .basis = 100, .min = 100 },
        .{ .basis = 100, .min = 100 },
    };
    var out: [2]f32 = undefined;
    var frozen: [2]bool = undefined;
    solve(&items, 120, 0, &out, &frozen);
    try expectSizes(&.{ 100, 100 }, &out);
}

test "empty item list is a no-op" {
    var out: [0]f32 = .{};
    var frozen: [0]bool = .{};
    solve(&.{}, 100, 0, &out, &frozen);
}
