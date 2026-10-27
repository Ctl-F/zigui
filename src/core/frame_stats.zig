//! Per-frame cost tracking: a ring buffer of recent frames, an optional overlay,
//! and a handler time budget (design doc section 24).
//!
//! Costs come from a clock the platform supplies (`Ui.clock`, nanoseconds);
//! without one every timing reads zero and only the counts are recorded. The
//! ring never allocates.

const std = @import("std");
const draw_list = @import("draw_list.zig");
const Rect = @import("geometry.zig").Rect;
const Color = @import("geometry.zig").Color;

/// What one frame cost. Times are nanoseconds.
pub const Frame = struct {
    /// Widget `update` pass (and sweeping) since the previous frame.
    update_ns: u64 = 0,
    layout_ns: u64 = 0,
    /// Building the draw list from the tree.
    build_ns: u64 = 0,
    /// Backend begin, submit, and present.
    submit_ns: u64 = 0,
    /// Input handlers that ran since the previous frame.
    handler_ns: u64 = 0,
    total_ns: u64 = 0,
    commands: u32 = 0,
    glyphs: u32 = 0,
};

pub const capacity = 120;

/// A frame at or over this is drawn red in the overlay and counted as missed
/// (60 Hz).
pub const default_budget_ns: u64 = 16_666_667;

pub const FrameStats = struct {
    ring: [capacity]Frame = @splat(.{}),
    /// Total frames recorded; the newest is at `(count - 1) % capacity`.
    count: u64 = 0,
    /// Frames over `budget_ns`.
    missed: u64 = 0,
    budget_ns: u64 = default_budget_ns,

    pub fn push(self: *FrameStats, f: Frame) void {
        self.ring[@intCast(self.count % capacity)] = f;
        self.count += 1;
        if (self.budget_ns > 0 and f.total_ns > self.budget_ns) self.missed += 1;
    }

    /// Frames currently held (up to `capacity`).
    pub fn len(self: *const FrameStats) usize {
        return @intCast(@min(self.count, capacity));
    }

    /// The `i`th most recent frame (0 is the newest), or null past the history.
    pub fn recent(self: *const FrameStats, i: usize) ?Frame {
        if (i >= self.len()) return null;
        return self.ring[@intCast((self.count - 1 - i) % capacity)];
    }

    pub const Summary = struct {
        frames: usize,
        avg_total_ns: u64,
        max_total_ns: u64,
        avg_commands: u32,
        missed: u64,
    };

    /// Averages over the frames currently held.
    pub fn summary(self: *const FrameStats) Summary {
        const n = self.len();
        if (n == 0) return .{ .frames = 0, .avg_total_ns = 0, .max_total_ns = 0, .avg_commands = 0, .missed = self.missed };
        var total: u64 = 0;
        var cmds: u64 = 0;
        var worst: u64 = 0;
        for (0..n) |i| {
            const f = self.recent(i).?;
            total += f.total_ns;
            cmds += f.commands;
            worst = @max(worst, f.total_ns);
        }
        return .{
            .frames = n,
            .avg_total_ns = total / n,
            .max_total_ns = worst,
            .avg_commands = @intCast(cmds / n),
            .missed = self.missed,
        };
    }

    /// Draw a bar chart of recent frame times into the top-right corner of a
    /// window `window_w` logical pixels wide: one bar per frame, newest on the
    /// right, a line at the budget, bars over budget in red. Uses only rectangles
    /// (no text), so it works with no font loaded.
    pub fn drawOverlay(self: *const FrameStats, list: *draw_list.DrawList, window_w: f32) draw_list.Error!void {
        const bar_w: f32 = 2;
        const gap: f32 = 1;
        const chart_h: f32 = 48;
        const n = self.len();
        const width = @as(f32, @floatFromInt(capacity)) * (bar_w + gap);
        const x0 = @max(window_w - width - 8, 0);
        const y0: f32 = 8;
        // Scale so the budget sits at two thirds of the chart height.
        const budget = @as(f32, @floatFromInt(@max(self.budget_ns, 1)));
        const px_per_ns = (chart_h * 2.0 / 3.0) / budget;

        try list.fillRect(.{ .x = x0 - 4, .y = y0 - 4, .w = width + 8, .h = chart_h + 8 }, .{ .color = Color.rgba(0, 0, 0, 170) });
        for (0..n) |i| {
            const f = self.recent(i).?;
            const h = std.math.clamp(@as(f32, @floatFromInt(f.total_ns)) * px_per_ns, 1, chart_h);
            const over = self.budget_ns > 0 and f.total_ns > self.budget_ns;
            const x = x0 + width - @as(f32, @floatFromInt(i + 1)) * (bar_w + gap);
            try list.fillRect(.{ .x = x, .y = y0 + chart_h - h, .w = bar_w, .h = h }, .{
                .color = if (over) Color.rgb(230, 80, 80) else Color.rgb(90, 200, 120),
            });
        }
        const line_y = y0 + chart_h - budget * px_per_ns;
        try list.fillRect(.{ .x = x0, .y = line_y, .w = width, .h = 1 }, .{ .color = Color.rgba(255, 255, 255, 140) });
    }
};

// ---- tests -----------------------------------------------------------------

test "the ring keeps the newest frames and counts misses" {
    var s: FrameStats = .{ .budget_ns = 100 };
    try std.testing.expectEqual(@as(usize, 0), s.len());
    try std.testing.expect(s.recent(0) == null);
    var i: u64 = 0;
    while (i < capacity + 30) : (i += 1) s.push(.{ .total_ns = i * 10, .commands = 5 });
    try std.testing.expectEqual(@as(usize, capacity), s.len());
    try std.testing.expectEqual((capacity + 29) * 10, s.recent(0).?.total_ns);
    try std.testing.expectEqual((capacity + 30 - capacity) * 10, s.recent(capacity - 1).?.total_ns);
    try std.testing.expect(s.recent(capacity) == null);
    try std.testing.expectEqual(@as(u64, capacity + 30 - 11), s.missed); // totals above 100: frames 11.. of 150
}

test "summary averages what is held" {
    var s: FrameStats = .{};
    s.push(.{ .total_ns = 10, .commands = 4 });
    s.push(.{ .total_ns = 30, .commands = 8 });
    const sum = s.summary();
    try std.testing.expectEqual(@as(usize, 2), sum.frames);
    try std.testing.expectEqual(@as(u64, 20), sum.avg_total_ns);
    try std.testing.expectEqual(@as(u64, 30), sum.max_total_ns);
    try std.testing.expectEqual(@as(u32, 6), sum.avg_commands);
    try std.testing.expectEqual(@as(usize, 0), (FrameStats{}).summary().frames);
}

test "the overlay draws a bar per frame, in red when over budget, and keeps the list balanced" {
    var s: FrameStats = .{ .budget_ns = 1000 };
    s.push(.{ .total_ns = 500 });
    s.push(.{ .total_ns = 5000 });
    var cmds: [64]draw_list.Command = undefined;
    var glyphs: [1]draw_list.Glyph = undefined;
    var list = draw_list.DrawList.init(&cmds, &glyphs);
    try s.drawOverlay(&list, 800);
    // background + 2 bars + budget line
    try std.testing.expectEqual(@as(usize, 4), list.items().len);
    var red = false;
    var green = false;
    for (list.items()) |c| switch (c) {
        .fill_rect => |f| {
            if (f.paint == .color and f.paint.color.r == 230) red = true;
            if (f.paint == .color and f.paint.color.g == 200) green = true;
        },
        else => {},
    };
    try std.testing.expect(red and green);
    try std.testing.expect(list.isBalanced());
}
