//! Paint pass: walks the laid-out tree and emits draw commands.
//!
//! Per node, in order: its `Visual` (plain containers use this), then its
//! painter (`Node.paint_hook`, which widgets install to run the theme's
//! painter), then its text, then its children in sibling order. Nodes flagged
//! `clip_children` clip everything after their own box. The painter can recolor
//! the text through the `PaintCtx`.
//!
//! The list is always rebuilt in full (the renderer redraws only damaged areas;
//! see `damage.zig`), but a subtree rooted at a repaint boundary (`NodeFlags.
//! repaint_boundary`: code editors and canvases set it) is recorded once and
//! replayed, translated, until something inside it is dirty. See `Cache`.

const std = @import("std");
const Handle = @import("handle.zig").Handle;
const Tree = @import("tree.zig").Tree;
const DrawList = @import("draw_list.zig").DrawList;
const Paint = @import("draw_list.zig").Paint;
const Rect = @import("geometry.zig").Rect;
const layout_mod = @import("layout.zig");
const PaintCtx = @import("paint_ctx.zig").PaintCtx;

pub const Error = @import("paint_ctx.zig").Error;

/// Rebuild `list` from `tree`, with no caching. Resets the list first.
pub fn build(tree: *Tree, list: *DrawList) Error!void {
    list.reset();
    try paintNode(tree, tree.root, 0, 0, list, null);
}

/// Like `build`, replaying clean repaint-boundary subtrees from `cache`.
pub fn buildCached(tree: *Tree, list: *DrawList, cache: *Cache) Error!void {
    list.reset();
    cache.beginFrame(tree);
    try paintNode(tree, tree.root, 0, 0, list, cache);
}

const Command = draw_list.Command;
const Glyph = draw_list.Glyph;
const draw_list = @import("draw_list.zig");

/// Recorded draw commands for repaint-boundary subtrees, kept as drawn (window
/// coordinates) with the origin they were drawn at: replayed at the same origin
/// they are bit-identical, and elsewhere they are moved by the difference.
/// Buffers grow to what the subtree needs and are then reused, so steady-state
/// frames do not allocate.
pub const Cache = struct {
    gpa: std.mem.Allocator,
    entries: std.AutoHashMapUnmanaged(u64, Entry) = .empty,
    /// Subtrees replayed / re-recorded since `beginFrame`.
    hits: u32 = 0,
    misses: u32 = 0,

    const Entry = struct {
        cmds: std.ArrayListUnmanaged(Command) = .empty,
        glyphs: std.ArrayListUnmanaged(Glyph) = .empty,
        ox: f32 = 0,
        oy: f32 = 0,
        w: f32 = 0,
        h: f32 = 0,
        valid: bool = false,
    };

    pub fn init(gpa: std.mem.Allocator) Cache {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Cache) void {
        var it = self.entries.valueIterator();
        while (it.next()) |e| {
            e.cmds.deinit(self.gpa);
            e.glyphs.deinit(self.gpa);
        }
        self.entries.deinit(self.gpa);
    }

    fn key(h: Handle) u64 {
        return (@as(u64, h.index) << 32) | h.generation;
    }

    fn fromKey(k: u64) Handle {
        return .{ .index = @intCast(k >> 32), .generation = @intCast(k & 0xffff_ffff) };
    }

    /// Reset the counters and drop entries of nodes that no longer exist.
    fn beginFrame(self: *Cache, tree: *Tree) void {
        self.hits = 0;
        self.misses = 0;
        var stale: [16]u64 = undefined;
        var n: usize = 0;
        var it = self.entries.iterator();
        while (it.next()) |kv| {
            if (n == stale.len) break;
            if (!tree.isValid(fromKey(kv.key_ptr.*))) {
                stale[n] = kv.key_ptr.*;
                n += 1;
            }
        }
        for (stale[0..n]) |k| {
            if (self.entries.fetchRemove(k)) |kv| {
                var e = kv.value;
                e.cmds.deinit(self.gpa);
                e.glyphs.deinit(self.gpa);
            }
        }
    }

    pub fn count(self: *const Cache) usize {
        return self.entries.count();
    }
};

fn shift(r: Rect, dx: f32, dy: f32) Rect {
    return .{ .x = r.x + dx, .y = r.y + dy, .w = r.w, .h = r.h };
}

fn shiftPaint(p: draw_list.Paint, dx: f32, dy: f32) draw_list.Paint {
    return switch (p) {
        .linear_gradient => |g| .{ .linear_gradient = shiftGradient(g, dx, dy) },
        .radial_gradient => |g| .{ .radial_gradient = shiftGradient(g, dx, dy) },
        else => p,
    };
}

fn shiftGradient(g: anytype, dx: f32, dy: f32) @TypeOf(g) {
    var out = g;
    out.from = .{ .x = g.from.x + dx, .y = g.from.y + dy };
    out.to = .{ .x = g.to.x + dx, .y = g.to.y + dy };
    return out;
}

/// `cmd` moved by (dx, dy). Glyph runs keep their `offset` (the caller fixes it
/// up) and only their bounds move.
fn translate(cmd: Command, dx: f32, dy: f32) Command {
    return switch (cmd) {
        .fill_rect => |f| .{ .fill_rect = .{ .rect = shift(f.rect, dx, dy), .paint = shiftPaint(f.paint, dx, dy) } },
        .stroke_rect => |s| blk: {
            var o = s;
            o.rect = shift(s.rect, dx, dy);
            o.paint = shiftPaint(s.paint, dx, dy);
            break :blk .{ .stroke_rect = o };
        },
        .fill_rounded_rect => |f| blk: {
            var o = f;
            o.rect = shift(f.rect, dx, dy);
            o.paint = shiftPaint(f.paint, dx, dy);
            break :blk .{ .fill_rounded_rect = o };
        },
        .line => |l| blk: {
            var o = l;
            o.from = .{ .x = l.from.x + dx, .y = l.from.y + dy };
            o.to = .{ .x = l.to.x + dx, .y = l.to.y + dy };
            o.paint = shiftPaint(l.paint, dx, dy);
            break :blk .{ .line = o };
        },
        .push_clip => |r| .{ .push_clip = shift(r, dx, dy) },
        .glyph_run => |g| blk: {
            var o = g;
            o.bounds = shift(g.bounds, dx, dy);
            break :blk .{ .glyph_run = o };
        },
        .image => |im| blk: {
            var o = im;
            o.rect = shift(im.rect, dx, dy);
            break :blk .{ .image = o };
        },
        .pop_clip, .push_opacity, .pop_opacity => cmd,
    };
}

/// Append `entry`'s commands to `list`, moved by (dx, dy).
fn replay(list: *DrawList, entry: *const Cache.Entry, dx: f32, dy: f32) Error!void {
    for (entry.cmds.items) |c| {
        var cmd = if (dx == 0 and dy == 0) c else translate(c, dx, dy);
        switch (cmd) {
            .push_clip => |r| try list.pushClip(r),
            .pop_clip => _ = try list.popClip(),
            .push_opacity => |o| try list.pushOpacity(o),
            .pop_opacity => _ = try list.popOpacity(),
            .glyph_run => |*g| {
                const src = entry.glyphs.items[g.offset..][0..g.count];
                if (list.glyph_len + src.len > list.glyphs.len) return error.GlyphBufferFull;
                const at = list.glyph_len;
                for (src, list.glyphs[at .. at + src.len]) |s, *d| d.* = if (dx == 0 and dy == 0) s else .{ .id = s.id, .x = s.x + dx, .y = s.y + dy };
                list.glyph_len += src.len;
                g.offset = @intCast(at);
                try list.push(cmd);
            },
            else => try list.push(cmd),
        }
    }
}

/// Copy what was appended to `list` since (`c0`, `g0`) into `entry`, drawn with
/// its origin at (ox, oy).
fn record(cache: *Cache, entry: *Cache.Entry, list: *const DrawList, c0: usize, g0: usize, ox: f32, oy: f32, w: f32, h: f32) Error!void {
    entry.valid = false;
    entry.cmds.clearRetainingCapacity();
    entry.glyphs.clearRetainingCapacity();
    try entry.cmds.ensureTotalCapacity(cache.gpa, list.len - c0);
    try entry.glyphs.ensureTotalCapacity(cache.gpa, list.glyph_len - g0);
    for (list.commands[c0..list.len]) |c| {
        var cmd = c;
        if (cmd == .glyph_run) cmd.glyph_run.offset -= @intCast(g0);
        entry.cmds.appendAssumeCapacity(cmd);
    }
    entry.glyphs.appendSliceAssumeCapacity(list.glyphs[g0..list.glyph_len]);
    entry.ox = ox;
    entry.oy = oy;
    entry.w = w;
    entry.h = h;
    entry.valid = true;
}

fn paintNode(tree: *Tree, h: Handle, ox: f32, oy: f32, list: *DrawList, cache: ?*Cache) Error!void {
    const node = tree.get(h) orelse return;
    if (node.flags.hidden) return;

    const abs: Rect = .{ .x = ox + node.rect.x, .y = oy + node.rect.y, .w = node.rect.w, .h = node.rect.h };

    // A repaint boundary: replay the recording while nothing inside changed.
    if (cache) |c| {
        if (node.flags.repaint_boundary and !Handle.eql(h, tree.root)) {
            const k = Cache.key(h);
            const dirty = node.dirty.needsPaint() or node.dirty.child_paint;
            if (c.entries.getPtr(k)) |e| {
                if (e.valid and !dirty and e.w == abs.w and e.h == abs.h) {
                    try replay(list, e, abs.x - e.ox, abs.y - e.oy);
                    c.hits += 1;
                    return;
                }
            }
            const c0 = list.len;
            const g0 = list.glyph_len;
            try paintSubtree(tree, h, node, abs, list, cache);
            // (Painting may have added entries for nested boundaries, so look up again.)
            const gop = try c.entries.getOrPut(c.gpa, k);
            if (!gop.found_existing) gop.value_ptr.* = .{};
            const entry = gop.value_ptr;
            try record(c, entry, list, c0, g0, abs.x, abs.y, abs.w, abs.h);
            c.misses += 1;
            return;
        }
    }
    try paintSubtree(tree, h, node, abs, list, cache);
}

fn paintSubtree(tree: *Tree, h: Handle, node: *@import("tree.zig").Node, abs: Rect, list: *DrawList, cache: ?*Cache) Error!void {
    var pc: PaintCtx = .{ .list = list, .rect = abs };
    try pc.box(node.visual);

    const clip = node.flags.clip_children;
    if (clip) try list.pushClip(abs);
    // The painter draws the node's own commands; it may recolor the text.
    if (node.paint_hook) |hook| try hook.run(hook.ctx, &pc);
    if (node.text) |block| try paintText(block, node.style.padding, &pc);
    var it = tree.children(h);
    while (it.next()) |c| try paintNode(tree, c, abs.x, abs.y, list, cache);
    if (clip) _ = try list.popClip();
}

/// Draw a node's text block in its content box: vertically centered, aligned
/// horizontally per the block. Text wider than the box is clipped to it.
/// Colors come from the painter's overrides, else from the block.
fn paintText(block: *const @import("../text/block.zig").TextBlock, padding: @import("style.zig").Edges, pc: *const PaintCtx) Error!void {
    const list = pc.list;
    const abs = pc.rect;
    const decor = block.decor;
    if (block.glyphs.len == 0 and !decor.sel_on and !decor.caret_on) return;
    const pad = layout_mod.resolveEdges(padding, null);
    const content: Rect = .{
        .x = abs.x + pad.l,
        .y = abs.y + pad.t,
        .w = @max(abs.w - pad.l - pad.r, 0),
        .h = @max(abs.h - pad.t - pad.b, 0),
    };
    const free = content.w - block.width;
    const dx: f32 = switch (block.align_x) {
        .start => 0,
        .center => @max(free / 2, 0),
        .end => @max(free, 0),
    };
    const gap = block.line_height - block.ascent - block.descent;
    const baseline = content.y + (content.h - block.line_height) / 2 + gap / 2 + block.ascent;
    const origin_x = content.x + dx - decor.scroll_x;
    const line_top = content.y + (content.h - block.line_height) / 2;
    const bounds: Rect = .{ .x = origin_x, .y = baseline - block.ascent, .w = block.width, .h = block.line_height };

    const clip = block.width > content.w or decor.active();
    if (clip) try list.pushClip(content);
    if (decor.sel_on and decor.sel_x1 > decor.sel_x0) {
        try list.fillRect(.{ .x = origin_x + decor.sel_x0, .y = line_top, .w = decor.sel_x1 - decor.sel_x0, .h = block.line_height }, Paint.solid(pc.selection_color));
    }
    if (block.glyphs.len > 0) {
        try list.glyphRunAt(bounds, block.glyphs, .{ .x = origin_x, .y = baseline }, pc.text_color orelse block.color, block.font, block.size, block.subpixel);
    }
    if (decor.caret_on) {
        // Whole logical pixels keep the caret crisp at 1x.
        try list.fillRect(.{ .x = @round(origin_x + decor.caret_x), .y = line_top, .w = 1, .h = block.line_height }, Paint.solid(pc.caret_color));
    }
    if (clip) _ = try list.popClip();
}

test "paints backgrounds in tree order with absolute coordinates" {
    const Color = @import("geometry.zig").Color;
    const Layout = @import("layout.zig").Layout;
    const Length = @import("length.zig").Length;

    var tree = try Tree.init(std.testing.allocator);
    defer tree.deinit();
    var layout = Layout.init(std.testing.allocator);
    defer layout.deinit();

    tree.get(tree.root).?.visual.background = Color.white;
    const panel = try tree.create(.{ .style = .{ .width = Length.px(100), .height = Length.px(50), .padding = .all(10) } });
    try tree.appendChild(tree.root, panel);
    tree.get(panel).?.visual.background = Color.rgb(1, 2, 3);
    const inner = try tree.create(.{ .style = .{ .grow = 1 } });
    try tree.appendChild(panel, inner);
    tree.get(inner).?.visual = .{ .background = Color.rgb(9, 9, 9), .radius = 4 };

    try layout.run(&tree, .{ .w = 300, .h = 200 });

    var cmds: [16]@import("draw_list.zig").Command = undefined;
    var list = DrawList.init(&cmds, &.{});
    try build(&tree, &list);
    const items = list.items();
    try std.testing.expectEqual(@as(usize, 3), items.len);
    try std.testing.expectEqual(@as(f32, 300), items[0].fill_rect.rect.w);
    try std.testing.expectEqual(@as(f32, 100), items[1].fill_rect.rect.w);
    try std.testing.expectEqual(@as(f32, 10), items[2].fill_rounded_rect.rect.x); // panel x + padding
    try std.testing.expectEqual(@as(f32, 80), items[2].fill_rounded_rect.rect.w);
    try std.testing.expectEqual(@as(f32, 4), items[2].fill_rounded_rect.radii[0]);
}

test "clip_children brackets the subtree" {
    var tree = try Tree.init(std.testing.allocator);
    defer tree.deinit();
    tree.get(tree.root).?.flags.clip_children = true;
    const c = try tree.create(.{ .visual = .{ .background = .{ .r = 1, .g = 1, .b = 1, .a = 255 } } });
    try tree.appendChild(tree.root, c);

    var cmds: [16]@import("draw_list.zig").Command = undefined;
    var list = DrawList.init(&cmds, &.{});
    try build(&tree, &list);
    try std.testing.expect(list.isBalanced());
    try std.testing.expectEqual(@as(usize, 3), list.items().len); // push, fill, pop
}

/// Equality for draw commands and glyphs that tolerates the rounding a move
/// introduces (floats within 1/1000 px).
pub fn approxEql(a: anytype, b: anytype) bool {
    const T = @TypeOf(a);
    switch (@typeInfo(T)) {
        .float => return @abs(a - b) <= 1e-3,
        .@"struct" => |s| {
            inline for (s.field_names) |n| if (!approxEql(@field(a, n), @field(b, n))) return false;
            return true;
        },
        .@"union" => {
            if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
            switch (a) {
                inline else => |payload, tag| return approxEql(payload, @field(b, @tagName(tag))),
            }
        },
        .array => {
            for (a, b) |x, y| if (!approxEql(x, y)) return false;
            return true;
        },
        .optional => {
            if (a == null or b == null) return a == null and b == null;
            return approxEql(a.?, b.?);
        },
        else => return std.meta.eql(a, b),
    }
}
