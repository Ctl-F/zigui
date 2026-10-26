//! Paint pass: walks the laid-out tree and emits draw commands.
//!
//! Stopgap until painters and themes exist: every node draws its `Visual`
//! (background, then border), and nodes flagged `clip_children` clip their
//! subtree. Children paint after their parent, in sibling order. This is a full
//! repaint; damage-rect culling comes later.

const std = @import("std");
const Handle = @import("handle.zig").Handle;
const Tree = @import("tree.zig").Tree;
const DrawList = @import("draw_list.zig").DrawList;
const Paint = @import("draw_list.zig").Paint;
const Rect = @import("geometry.zig").Rect;
const layout_mod = @import("layout.zig");

pub const Error = @import("draw_list.zig").Error;

/// Rebuild `list` from `tree`. Resets the list first.
pub fn build(tree: *Tree, list: *DrawList) Error!void {
    list.reset();
    try paintNode(tree, tree.root, 0, 0, list);
}

fn paintNode(tree: *Tree, h: Handle, ox: f32, oy: f32, list: *DrawList) Error!void {
    const node = tree.get(h) orelse return;
    if (node.flags.hidden) return;

    const abs: Rect = .{ .x = ox + node.rect.x, .y = oy + node.rect.y, .w = node.rect.w, .h = node.rect.h };
    const v = node.visual;
    if (v.background.a != 0) {
        const paint = Paint.solid(v.background);
        if (v.radius > 0) {
            try list.fillRoundedRect(abs, .{ v.radius, v.radius, v.radius, v.radius }, paint);
        } else {
            try list.fillRect(abs, paint);
        }
    }
    if (v.border_width > 0 and v.border_color.a != 0) {
        try list.strokeRoundedRect(abs, v.border_width, v.radius, Paint.solid(v.border_color));
    }

    const clip = node.flags.clip_children;
    if (clip) try list.pushClip(abs);
    if (node.text) |block| try paintText(block, node.style.padding, abs, list);
    if (node.paint_hook) |hook| try hook.run(hook.ctx, abs, list);
    var it = tree.children(h);
    while (it.next()) |c| try paintNode(tree, c, abs.x, abs.y, list);
    if (clip) _ = try list.popClip();
}

/// Draw a node's text block in its content box: vertically centered, aligned
/// horizontally per the block. Text wider than the box is clipped to it.
fn paintText(block: *const @import("../text/block.zig").TextBlock, padding: @import("style.zig").Edges, abs: Rect, list: *DrawList) Error!void {
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
        try list.fillRect(.{ .x = origin_x + decor.sel_x0, .y = line_top, .w = decor.sel_x1 - decor.sel_x0, .h = block.line_height }, Paint.solid(decor.sel_color));
    }
    if (block.glyphs.len > 0) {
        try list.glyphRunAt(bounds, block.glyphs, .{ .x = origin_x, .y = baseline }, block.color, block.font, block.size, block.subpixel);
    }
    if (decor.caret_on) {
        // Whole logical pixels keep the caret crisp at 1x.
        try list.fillRect(.{ .x = @round(origin_x + decor.caret_x), .y = line_top, .w = 1, .h = block.line_height }, Paint.solid(decor.caret_color));
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
    try std.testing.expectEqual(@as(f32, 300), items[0].rect.w);
    try std.testing.expectEqual(@as(f32, 100), items[1].rect.w);
    try std.testing.expectEqual(@as(f32, 10), items[2].rect.x); // panel x + padding
    try std.testing.expectEqual(@as(f32, 80), items[2].rect.w);
    try std.testing.expectEqual(@as(f32, 4), items[2].params[0]);
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
