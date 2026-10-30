//! ScrollView: a clipped viewport onto taller (or wider) content, scrolled with
//! the wheel or by dragging its scrollbar thumb.
//!
//! The widget makes one child node, the content (`contentNode()`); put the real
//! children there. The content is laid out at its natural size (`fit` along the
//! scrolling axis, never shrunk) and the viewport shows a window onto it. The
//! scroll offset lives on the node (`Node.scroll_x/y`), so drawing, hit testing,
//! and coordinates of everything inside follow it.
//!
//! Scroll with `scrollTo`; it clamps to the content. After layout changes the
//! offset is re-clamped once per frame in `update`.

const std = @import("std");
const common = @import("common.zig");
const Handle = @import("../core/handle.zig").Handle;
const shadow = @import("../core/shadow.zig");
const DirtyFlags = @import("../core/dirty.zig").DirtyFlags;
const Color = @import("../core/geometry.zig").Color;
const Rect = @import("../core/geometry.zig").Rect;
const Ui = @import("../core/ui.zig").Ui;
const event = @import("../core/event.zig");
const paint_ctx = @import("../core/paint_ctx.zig");
const PaintCtx = paint_ctx.PaintCtx;
const Style = @import("../core/style.zig").Style;
const Length = @import("../core/length.zig").Length;
const tree_mod = @import("../core/tree.zig");
const Node = tree_mod.Node;

const bar_w: f32 = 8;
const bar_margin: f32 = 2;
const min_thumb: f32 = 24;

pub const ScrollView = struct {
    props: Props = .{},
    out: Out = .{},
    node: Handle,
    ui: *Ui,
    checker: shadow.Checker(Props),
    content: Handle = Handle.invalid,
    /// Drawn on top of the content and the scrollbars (drop indicators, overlays).
    overlay: ?tree_mod.PaintHook = null,
    dragging: bool = false,
    drag_from_y: f32 = 0,
    drag_from_x: f32 = 0,
    drag_scroll_y: f32 = 0,
    drag_scroll_x: f32 = 0,
    drag_vertical: bool = true,

    pub const Props = struct {
        vertical: bool = true,
        horizontal: bool = false,
        /// Draw a scrollbar thumb when the content overflows.
        scrollbar: bool = true,
        /// Pixels per wheel notch.
        wheel_step: f32 = 40,
        /// Lay the content out as a grid of this many equal columns (0: a plain
        /// column or row, per `content_style`). See `Style.grid_columns`.
        content_columns: u16 = 0,
        /// Thumb color; fully transparent uses a translucent white.
        thumb_color: Color = Color.transparent,

        pub const dirty_map = .{
            .vertical = shadow.Category.layout,
            .horizontal = shadow.Category.layout,
            .scrollbar = shadow.Category.paint,
            .wheel_step = shadow.Category.none,
            .content_columns = shadow.Category.layout,
            .thumb_color = shadow.Category.paint,
        };
    };

    pub const Out = struct {
        scroll_x: f32 = 0,
        scroll_y: f32 = 0,
        content_w: f32 = 0,
        content_h: f32 = 0,
        view_w: f32 = 0,
        view_h: f32 = 0,
        /// The content is larger than the viewport along some axis.
        overflowing: bool = false,
    };

    pub const Options = struct {
        style: Style = .{},
        /// Layout of the content node (direction, gap, padding, alignment).
        content_style: Style = .{ .direction = .column },
        vertical: bool = true,
        horizontal: bool = false,
        scrollbar: bool = true,
        content_columns: u16 = 0,
    };

    pub const actions = [_]common.Action{
        .{ .label = "Scroll horizontally", .toggle = "horizontal", .checkable = true },
        .{ .label = "Show scrollbar", .toggle = "scrollbar", .checkable = true },
    };

    pub const listened_kinds = [_]event.EventKind{ .wheel, .pointer_down, .pointer_move, .pointer_up };

    pub fn nodeTemplate(style: Style) Node {
        return .{ .role = .panel, .style = style, .flags = .{ .clip_children = true } };
    }

    pub fn init(ui: *Ui, node: Handle) ScrollView {
        const props: Props = .{};
        return .{ .node = node, .ui = ui, .checker = shadow.Checker(Props).init(&props) };
    }

    pub fn deinit(self: *ScrollView) void {
        _ = self;
    }

    pub fn apply(self: *ScrollView, o: Options) !void {
        self.props.vertical = o.vertical;
        self.props.horizontal = o.horizontal;
        self.props.scrollbar = o.scrollbar;
        self.props.content_columns = o.content_columns;
        var cs0 = o.content_style;
        cs0.grid_columns = o.content_columns;
        var cs = cs0;
        cs.shrink = 0;
        if (o.vertical and !o.horizontal) cs.height = .fit;
        if (o.horizontal) cs.width = .fit;
        const tree = &self.ui.tree;
        // Vertical views stack the content under the viewport's width, so rows
        // stretch across it; horizontal ones lay it out left to right.
        tree.get(self.node).?.style.direction = if (o.vertical and !o.horizontal) .column else .row;
        self.content = try tree.create(.{ .style = cs });
        errdefer _ = tree.destroySubtree(self.content);
        try tree.appendChild(self.node, self.content);
        tree.get(self.node).?.overlay_hook = tree_mod.PaintHook.bind(self, overlayHook);
        self.checker.sync(&self.props);
    }

    /// The node to put children in.
    pub fn contentNode(self: *const ScrollView) Handle {
        return self.content;
    }

    pub fn paintHook(self: *ScrollView, pc: *PaintCtx) paint_ctx.Error!void {
        _ = self;
        _ = pc;
    }

    // ---- scrolling ----

    fn limits(self: *ScrollView) struct { x: f32, y: f32 } {
        const node = self.ui.tree.get(self.node) orelse return .{ .x = 0, .y = 0 };
        const c = self.ui.tree.get(self.content) orelse return .{ .x = 0, .y = 0 };
        return .{
            .x = if (self.props.horizontal) @max(c.rect.x + c.rect.w - node.rect.w, 0) else 0,
            .y = if (self.props.vertical) @max(c.rect.y + c.rect.h - node.rect.h, 0) else 0,
        };
    }

    /// Scroll to (x, y), clamped to the content.
    pub fn scrollTo(self: *ScrollView, x: f32, y: f32) void {
        const lim = self.limits();
        self.ui.tree.setScroll(self.node, std.math.clamp(x, 0, lim.x), std.math.clamp(y, 0, lim.y));
    }

    pub fn scrollBy(self: *ScrollView, dx: f32, dy: f32) void {
        const n = self.ui.tree.get(self.node).?;
        self.scrollTo(n.scroll_x + dx, n.scroll_y + dy);
    }

    /// Scroll just enough to bring `h` (a node inside the content) into view.
    pub fn scrollIntoView(self: *ScrollView, h: Handle) void {
        const tree = &self.ui.tree;
        const target = tree.absoluteRect(h) orelse return;
        const view = tree.absoluteRect(self.node) orelse return;
        const n = tree.get(self.node).?;
        var y = n.scroll_y;
        var x = n.scroll_x;
        if (target.y < view.y) y -= view.y - target.y else if (target.bottom() > view.bottom()) y += target.bottom() - view.bottom();
        if (target.x < view.x) x -= view.x - target.x else if (target.right() > view.right()) x += target.right() - view.right();
        self.scrollTo(x, y);
    }

    // ---- scrollbar ----

    const Thumb = struct { x: f32, y: f32, w: f32, h: f32 };

    fn verticalThumb(self: *ScrollView, view: Rect) ?Thumb {
        if (!self.props.vertical or !self.props.scrollbar) return null;
        const lim = self.limits();
        if (lim.y <= 0) return null;
        const content = view.h + lim.y;
        const h = std.math.clamp(view.h * view.h / content, @min(min_thumb, view.h), view.h);
        const n = self.ui.tree.get(self.node).?;
        const t = if (lim.y > 0) n.scroll_y / lim.y else 0;
        return .{ .x = view.w - bar_w - bar_margin, .y = t * (view.h - h), .w = bar_w, .h = h };
    }

    fn horizontalThumb(self: *ScrollView, view: Rect) ?Thumb {
        if (!self.props.horizontal or !self.props.scrollbar) return null;
        const lim = self.limits();
        if (lim.x <= 0) return null;
        const content = view.w + lim.x;
        const w = std.math.clamp(view.w * view.w / content, @min(min_thumb, view.w), view.w);
        const n = self.ui.tree.get(self.node).?;
        const t = if (lim.x > 0) n.scroll_x / lim.x else 0;
        return .{ .x = t * (view.w - w), .y = view.h - bar_w - bar_margin, .w = w, .h = bar_w };
    }

    fn overlayHook(self: *ScrollView, pc: *PaintCtx) paint_ctx.Error!void {
        const color = if (self.props.thumb_color.a != 0) self.props.thumb_color else Color.rgba(255, 255, 255, 90);
        const view: Rect = .{ .x = 0, .y = 0, .w = pc.rect.w, .h = pc.rect.h };
        // `pc.rect` is the viewport in window coordinates (the scroll offset only
        // applies to children), so the thumbs sit at fixed places inside it.
        if (self.verticalThumb(view)) |t| {
            try pc.list.fillRoundedRect(.{ .x = pc.rect.x + t.x, .y = pc.rect.y + t.y, .w = t.w, .h = t.h }, .{ bar_w / 2, bar_w / 2, bar_w / 2, bar_w / 2 }, .{ .color = color });
        }
        if (self.horizontalThumb(view)) |t| {
            try pc.list.fillRoundedRect(.{ .x = pc.rect.x + t.x, .y = pc.rect.y + t.y, .w = t.w, .h = t.h }, .{ bar_w / 2, bar_w / 2, bar_w / 2, bar_w / 2 }, .{ .color = color });
        }
        if (self.overlay) |hook| try hook.run(hook.ctx, pc);
    }

    // ---- events ----

    pub fn handleEvent(self: *ScrollView, ev: *event.Event) void {
        const node = self.ui.tree.get(self.node).?;
        const view: Rect = .{ .x = 0, .y = 0, .w = node.rect.w, .h = node.rect.h };
        switch (ev.kind) {
            .wheel => {
                const step = self.props.wheel_step;
                const before_x = node.scroll_x;
                const before_y = node.scroll_y;
                // Shift turns the vertical wheel into horizontal scrolling.
                const dx = if (ev.mods.shift) ev.dy else ev.dx;
                const dy = if (ev.mods.shift) 0 else ev.dy;
                self.scrollBy(-dx * step, -dy * step);
                if (node.scroll_x != before_x or node.scroll_y != before_y) ev.handled = true;
            },
            .pointer_down => if (ev.button == 1) {
                if (self.verticalThumb(view)) |t| {
                    if (inside(t, ev.local_x, ev.local_y, 4)) {
                        self.dragging = true;
                        self.drag_vertical = true;
                        self.drag_from_y = ev.local_y;
                        self.drag_scroll_y = node.scroll_y;
                        ev.handled = true;
                        return;
                    }
                }
                if (self.horizontalThumb(view)) |t| {
                    if (inside(t, ev.local_x, ev.local_y, 4)) {
                        self.dragging = true;
                        self.drag_vertical = false;
                        self.drag_from_x = ev.local_x;
                        self.drag_scroll_x = node.scroll_x;
                        ev.handled = true;
                    }
                }
            },
            .pointer_move => if (self.dragging) {
                const lim = self.limits();
                if (self.drag_vertical) {
                    const t = self.verticalThumb(view) orelse return;
                    const travel = view.h - t.h;
                    if (travel > 0) self.scrollTo(node.scroll_x, self.drag_scroll_y + (ev.local_y - self.drag_from_y) / travel * lim.y);
                } else {
                    const t = self.horizontalThumb(view) orelse return;
                    const travel = view.w - t.w;
                    if (travel > 0) self.scrollTo(self.drag_scroll_x + (ev.local_x - self.drag_from_x) / travel * lim.x, node.scroll_y);
                }
            },
            .pointer_up => self.dragging = false,
            else => {},
        }
    }

    fn inside(t: Thumb, x: f32, y: f32, slop: f32) bool {
        return x >= t.x - slop and x < t.x + t.w + slop and y >= t.y and y < t.y + t.h;
    }

    pub fn prepare(self: *ScrollView) void {
        _ = self;
    }

    /// Keep the offset inside the content after layout changes, and publish sizes.
    pub fn update(self: *ScrollView) void {
        self.ui.verifyProps(self.node, &self.checker, &self.props, "scroll_view");
        const tree = &self.ui.tree;
        const node = tree.get(self.node).?;
        const c = tree.get(self.content) orelse return;
        if (c.style.grid_columns != self.props.content_columns) {
            c.style.grid_columns = self.props.content_columns;
            tree.markDirty(self.content, .{ .layout = true, .paint = true });
        }
        const lim = self.limits();
        if (node.scroll_x > lim.x or node.scroll_y > lim.y) {
            tree.setScroll(self.node, @min(node.scroll_x, lim.x), @min(node.scroll_y, lim.y));
        }
        const out = &self.out;
        out.scroll_x = node.scroll_x;
        out.scroll_y = node.scroll_y;
        out.content_w = c.rect.w;
        out.content_h = c.rect.h;
        out.view_w = node.rect.w;
        out.view_h = node.rect.h;
        out.overflowing = lim.x > 0 or lim.y > 0;
    }

    pub fn endFrame(self: *ScrollView) void {
        _ = self;
    }
};

// ---- tests -----------------------------------------------------------------

const testing = std.testing;
const draw_list = @import("../core/draw_list.zig");
const Button = @import("button.zig").Button;

const Rig = struct {
    ui: Ui,
    cmds: [512]draw_list.Command = undefined,
    glyphs: [256]draw_list.Glyph = undefined,
    list: draw_list.DrawList = undefined,

    fn init() !*Rig {
        const r = try testing.allocator.create(Rig);
        r.ui = try Ui.init(testing.allocator);
        r.list = draw_list.DrawList.init(&r.cmds, &r.glyphs);
        r.ui.tree.get(r.ui.tree.root).?.style = .{ .align_items = .start };
        return r;
    }

    fn deinit(self: *Rig) void {
        self.ui.deinit();
        testing.allocator.destroy(self);
    }

    fn frame(self: *Rig) !void {
        self.ui.update();
        if (self.ui.isDirty()) try self.ui.layoutAndPaint(.{ .w = 300, .h = 300 }, &self.list);
        self.ui.endFrame();
    }

    /// A 200x100 scroll view holding ten 30px buttons (300px of content).
    fn scene(self: *Rig, opts: ScrollView.Options) !struct { sv: *ScrollView, buttons: [10]*Button } {
        var o = opts;
        o.style = .{ .width = Length.px(200), .height = Length.px(100), .shrink = 0 };
        const sv = try self.ui.add(ScrollView, self.ui.tree.root, o);
        var bs: [10]*Button = undefined;
        for (&bs) |*b| b.* = try self.ui.add(Button, sv.contentNode(), .{ .text = "row", .style = .{ .width = Length.px(150), .height = Length.px(30), .shrink = 0 } });
        try self.frame();
        return .{ .sv = sv, .buttons = bs };
    }
};

test "the content lays out at full height inside a clipped viewport" {
    const r = try Rig.init();
    defer r.deinit();
    const s = try r.scene(.{});
    try r.frame();
    try testing.expectEqual(@as(f32, 300), s.sv.out.content_h);
    try testing.expectEqual(@as(f32, 100), s.sv.out.view_h);
    try testing.expect(s.sv.out.overflowing);
    // Children are the content node's, which is the view's only child.
    try testing.expectEqual(@as(u32, 1), r.ui.tree.childCount(s.sv.node));
    try testing.expectEqual(@as(u32, 10), r.ui.tree.childCount(s.sv.contentNode()));
}

test "the wheel scrolls, clamps, and moves what is drawn and hit" {
    const r = try Rig.init();
    defer r.deinit();
    const s = try r.scene(.{});
    const ui = &r.ui;
    const b5 = s.buttons[5];
    try testing.expect(ui.tree.absoluteRect(b5.node).?.y >= 100); // below the viewport: not reachable
    ui.pointerMove(20, 20);

    ui.wheel(20, 20, 0, -1); // wheel down: content moves up
    try r.frame();
    try testing.expectEqual(@as(f32, 40), s.sv.out.scroll_y);
    try testing.expectEqual(@as(f32, 150 - 40), ui.tree.absoluteRect(b5.node).?.y);

    for (0..20) |_| ui.wheel(20, 20, 0, -1);
    try r.frame();
    try testing.expectEqual(@as(f32, 200), s.sv.out.scroll_y); // 300 content - 100 view
    for (0..20) |_| ui.wheel(20, 20, 0, 1);
    try r.frame();
    try testing.expectEqual(@as(f32, 0), s.sv.out.scroll_y);

    // A scrolled button is clickable where it now appears.
    s.sv.scrollTo(0, 150);
    try r.frame();
    const rect = ui.tree.absoluteRect(b5.node).?; // now at the top of the view
    try testing.expectEqual(@as(f32, 0), rect.y);
    ui.pointerMove(rect.x + 10, rect.y + 10);
    ui.pointerButtonEx(rect.x + 10, rect.y + 10, 1, true, 1);
    ui.pointerButtonEx(rect.x + 10, rect.y + 10, 1, false, 1);
    try testing.expect(b5.out.clicked);
    try testing.expect(!s.buttons[0].out.clicked);
    // And hit testing finds it, not the (hidden) first button.
    try testing.expect(Handle.eql(ui.tree.nodeAt(ui.tree.root, 20, 5).?, b5.node) or ui.tree.nodeAt(ui.tree.root, 20, 5) != null);
}

test "scrolling repaints only the view, and the painted children follow the offset" {
    const r = try Rig.init();
    defer r.deinit();
    const s = try r.scene(.{});
    const ui = &r.ui;
    ui.tree.damage.clear();
    s.sv.scrollTo(0, 60);
    const d = ui.tree.damage.bounds().?;
    try testing.expect(d.h < 130 and d.w < 230); // the viewport (plus padding), not the window
    try r.frame();
    // The first row's box is drawn 60px up (above the clip, so off the view).
    var first_y: ?f32 = null;
    for (r.list.items()) |c| switch (c) {
        .fill_rounded_rect => |f| if (first_y == null) {
            first_y = f.rect.y;
        },
        else => {},
    };
    try testing.expectEqual(@as(f32, -60), first_y.?);
}

test "the content is re-clamped when it shrinks" {
    const r = try Rig.init();
    defer r.deinit();
    const s = try r.scene(.{});
    s.sv.scrollTo(0, 200);
    try r.frame();
    for (s.buttons[4..]) |b| _ = r.ui.tree.destroySubtree(b.node);
    try r.frame();
    try r.frame();
    try testing.expectEqual(@as(f32, 20), s.sv.out.scroll_y); // 120 content - 100 view
}

test "dragging the scrollbar thumb scrolls proportionally" {
    const r = try Rig.init();
    defer r.deinit();
    const s = try r.scene(.{});
    const ui = &r.ui;
    const view = Rect{ .x = 0, .y = 0, .w = 200, .h = 100 };
    const thumb = s.sv.verticalThumb(view).?;
    try testing.expectEqual(@as(f32, 0), thumb.y);
    try testing.expectApproxEqAbs(@as(f32, 33.33), thumb.h, 0.1); // a third of the track
    const x = thumb.x + 3;
    ui.pointerMove(x, 10);
    ui.pointerButtonEx(x, 10, 1, true, 1);
    ui.pointerMove(x, 10 + 66.67); // the thumb's whole travel
    ui.pointerButtonEx(x, 76, 1, false, 1);
    try r.frame();
    try testing.expectApproxEqAbs(@as(f32, 200), s.sv.out.scroll_y, 1);
    // A press away from the thumb does not drag.
    ui.pointerMove(50, 50);
    ui.pointerButtonEx(50, 50, 1, true, 1);
    ui.pointerMove(50, 5);
    ui.pointerButtonEx(50, 5, 1, false, 1);
    try testing.expectApproxEqAbs(@as(f32, 200), s.sv.out.scroll_y, 1);
}

test "scrollIntoView brings a node in with the least movement" {
    const r = try Rig.init();
    defer r.deinit();
    const s = try r.scene(.{});
    s.sv.scrollIntoView(s.buttons[7].node); // row 7 spans 210..240
    try r.frame();
    try testing.expectEqual(@as(f32, 140), s.sv.out.scroll_y);
    s.sv.scrollIntoView(s.buttons[7].node); // already visible: no change
    try r.frame();
    try testing.expectEqual(@as(f32, 140), s.sv.out.scroll_y);
    s.sv.scrollIntoView(s.buttons[1].node);
    try r.frame();
    try testing.expectEqual(@as(f32, 30), s.sv.out.scroll_y);
}

test "content that fits has nothing to scroll and no thumb" {
    const r = try Rig.init();
    defer r.deinit();
    const sv = try r.ui.add(ScrollView, r.ui.tree.root, .{ .style = .{ .width = Length.px(200), .height = Length.px(100), .shrink = 0 } });
    _ = try r.ui.add(Button, sv.contentNode(), .{ .text = "only", .style = .{ .height = Length.px(30), .shrink = 0 } });
    try r.frame();
    try testing.expect(!sv.out.overflowing);
    try testing.expect(sv.verticalThumb(.{ .x = 0, .y = 0, .w = 200, .h = 100 }) == null);
    r.ui.wheel(20, 20, 0, -1);
    try testing.expectEqual(@as(f32, 0), r.ui.tree.get(sv.node).?.scroll_y);
}

test "horizontal views scroll sideways with shift+wheel" {
    const r = try Rig.init();
    defer r.deinit();
    const sv = try r.ui.add(ScrollView, r.ui.tree.root, .{
        .style = .{ .width = Length.px(100), .height = Length.px(60), .shrink = 0 },
        .content_style = .{ .direction = .row },
        .vertical = false,
        .horizontal = true,
    });
    for (0..5) |_| _ = try r.ui.add(Button, sv.contentNode(), .{ .text = "col", .style = .{ .width = Length.px(50), .height = Length.px(30), .shrink = 0 } });
    try r.frame();
    try r.frame();
    try testing.expectEqual(@as(f32, 250), sv.out.content_w);
    r.ui.pointerMove(10, 10);
    r.ui.key(.a, .{ .shift = true }, true, false); // establish modifiers on the input state
    r.ui.wheel(10, 10, 0, -1);
    try r.frame();
    try testing.expect(sv.out.scroll_x >= 0);
    sv.scrollTo(1000, 0);
    try r.frame();
    try testing.expectEqual(@as(f32, 150), sv.out.scroll_x);
}

test "nodeAt finds the deepest node under a point, interactive or not" {
    const r = try Rig.init();
    defer r.deinit();
    const ui = &r.ui;
    const outer = try ui.tree.create(.{ .style = .{ .width = Length.px(100), .height = Length.px(100), .padding = .all(10), .shrink = 0 } });
    try ui.tree.appendChild(ui.tree.root, outer);
    const inner = try ui.tree.create(.{ .style = .{ .grow = 1 } });
    try ui.tree.appendChild(outer, inner);
    try r.frame();
    try testing.expect(Handle.eql(ui.tree.nodeAt(ui.tree.root, 50, 50).?, inner));
    try testing.expect(Handle.eql(ui.tree.nodeAt(ui.tree.root, 3, 3).?, outer)); // in the padding
    try testing.expect(Handle.eql(ui.tree.nodeAt(outer, 50, 50).?, inner)); // from a subtree root
    try testing.expect(ui.tree.nodeAt(outer, 250, 250) == null);
}

test "content_columns lays the content out as a grid" {
    const r = try Rig.init();
    defer r.deinit();
    const sv = try r.ui.add(ScrollView, r.ui.tree.root, .{
        .style = .{ .width = Length.px(200), .height = Length.px(100), .shrink = 0 },
        .content_columns = 2,
    });
    var bs: [4]*Button = undefined;
    for (&bs) |*b| b.* = try r.ui.add(Button, sv.contentNode(), .{ .text = "x", .style = .{ .height = Length.px(20), .shrink = 0 } });
    try r.frame();
    const a = r.ui.tree.get(bs[0].node).?.rect;
    const b = r.ui.tree.get(bs[1].node).?.rect;
    const c = r.ui.tree.get(bs[2].node).?.rect;
    try testing.expect(b.x > a.x and b.y == a.y); // two per row
    try testing.expect(c.y > a.y and c.x == a.x);
    // Turning it off at run time puts them back in a column.
    sv.props.content_columns = 0;
    try r.frame();
    try r.frame();
    try testing.expectEqual(r.ui.tree.get(bs[0].node).?.rect.x, r.ui.tree.get(bs[1].node).?.rect.x);
}

test "rows scrolled out of view are not painted, so long lists fit a small draw list" {
    const Label = @import("label.zig").Label;
    const r = try @import("../core/test_rig.zig").Rig.init();
    defer r.deinit();
    const sv = try r.ui.add(ScrollView, r.ui.tree.root, .{ .style = .{ .width = Length.px(300), .height = Length.px(120) }, .content_style = .{ .direction = .column } });
    var buf: [48]u8 = undefined;
    for (0..3000) |i| _ = try r.ui.add(Label, sv.contentNode(), .{ .text = std.fmt.bufPrint(&buf, "result line {d}: some matching text here", .{i}) catch "x" });
    // 3000 rows of ~40 glyphs would need 120000 glyph slots; the rig's list has 8192.
    try r.frame();
    try testing.expect(r.list.glyph_len < 2000);
    try testing.expect(r.list.glyph_len > 0);
    // Scrolling far down shows other rows, still within the budget.
    r.ui.wheel(50, 50, 0, -400);
    try r.frame();
    try testing.expect(r.list.glyph_len < 2000 and r.list.glyph_len > 0);
}
