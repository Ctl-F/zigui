//! SplitView: two panes with a draggable divider between them.
//!
//! The widget makes three child nodes, the first pane, the divider, and the
//! second pane, and keeps their sizes: the first pane is `first_size` pixels
//! along the split axis, the second takes what is left. Put content in
//! `firstNode()` and `secondNode()` (or, in a UI document, give the split view
//! two children). Dragging the divider changes `first_size` within `min_first`
//! and `min_second`.

const std = @import("std");
const common = @import("common.zig");
const Handle = @import("../core/handle.zig").Handle;
const shadow = @import("../core/shadow.zig");
const Color = @import("../core/geometry.zig").Color;
const Ui = @import("../core/ui.zig").Ui;
const event = @import("../core/event.zig");
const paint_ctx = @import("../core/paint_ctx.zig");
const PaintCtx = paint_ctx.PaintCtx;
const Style = @import("../core/style.zig").Style;
const Length = @import("../core/length.zig").Length;
const tree_mod = @import("../core/tree.zig");
const Node = tree_mod.Node;

pub const SplitView = struct {
    props: Props = .{},
    out: Out = .{},
    node: Handle,
    ui: *Ui,
    checker: shadow.Checker(Props),
    first: Handle = Handle.invalid,
    divider: Handle = Handle.invalid,
    second: Handle = Handle.invalid,
    dragging: bool = false,
    drag_from: f32 = 0,
    drag_size: f32 = 0,

    pub const Props = struct {
        /// Stack the panes top to bottom (the divider is horizontal) instead of
        /// side by side.
        vertical: bool = false,
        /// Size in pixels, along the split axis, of the anchored pane: the first
        /// one, or the second when `anchor_second` is set. The other pane takes
        /// what is left.
        first_size: f32 = 240,
        min_first: f32 = 48,
        min_second: f32 = 48,
        divider_size: f32 = 6,
        /// Keep the second pane at `first_size` and let the first one flex
        /// (a fixed-width inspector on the right, say).
        anchor_second: bool = false,

        pub const dirty_map = .{
            .anchor_second = shadow.Category.layout,
            .vertical = shadow.Category.layout,
            .first_size = shadow.Category.layout,
            .min_first = shadow.Category.layout,
            .min_second = shadow.Category.layout,
            .divider_size = shadow.Category.layout,
        };
    };

    pub const Out = struct {
        /// The divider is being dragged.
        dragging: bool = false,
    };

    pub const Options = struct {
        style: Style = .{},
        vertical: bool = false,
        first_size: f32 = 240,
        min_first: f32 = 48,
        min_second: f32 = 48,
        divider_size: f32 = 6,
        anchor_second: bool = false,
    };

    /// Context-menu commands for editors.
    pub const actions = [_]common.Action{
        .{ .label = "Make vertical", .toggle = "vertical", .label_when_on = "Make horizontal" },
        .{ .label = "Keep second pane fixed", .toggle = "anchor_second", .checkable = true },
    };

    pub const listened_kinds = [_]event.EventKind{};

    pub fn nodeTemplate(style: Style) Node {
        return .{ .role = .panel, .style = style, .flags = .{ .clip_children = true } };
    }

    pub fn init(ui: *Ui, node: Handle) SplitView {
        const props: Props = .{};
        return .{ .node = node, .ui = ui, .checker = shadow.Checker(Props).init(&props) };
    }

    pub fn deinit(self: *SplitView) void {
        _ = self;
    }

    pub fn apply(self: *SplitView, o: Options) !void {
        self.props = .{
            .vertical = o.vertical,
            .first_size = o.first_size,
            .min_first = o.min_first,
            .min_second = o.min_second,
            .divider_size = o.divider_size,
            .anchor_second = o.anchor_second,
        };
        const tree = &self.ui.tree;
        self.first = try tree.create(.{ .role = .panel, .flags = .{ .clip_children = true } });
        errdefer _ = tree.destroySubtree(self.first);
        try tree.appendChild(self.node, self.first);
        self.divider = try tree.create(.{ .role = .generic });
        errdefer _ = tree.destroySubtree(self.divider);
        try tree.appendChild(self.node, self.divider);
        self.second = try tree.create(.{ .role = .panel, .flags = .{ .clip_children = true } });
        errdefer _ = tree.destroySubtree(self.second);
        try tree.appendChild(self.node, self.second);

        const dv = tree.get(self.divider).?;
        dv.paint_hook = tree_mod.PaintHook.bind(self, paintDivider);
        for ([_]event.EventKind{ .pointer_down, .pointer_move, .pointer_up }) |kind| {
            try tree.addListener(self.divider, .{ .kind = kind, .callback = event.Callback.bind(self, onDivider) });
        }
        try tree.setLabel(self.divider, "Resize panes");
        self.applyLayout();
        self.checker.sync(&self.props);
    }

    /// The nodes to put content in.
    pub fn firstNode(self: *const SplitView) Handle {
        return self.first;
    }

    pub fn secondNode(self: *const SplitView) Handle {
        return self.second;
    }

    /// For UI documents: child 0 is the first pane, child 1 the second.
    pub fn contentNodeAt(self: *const SplitView, index: usize) ?Handle {
        return switch (index) {
            0 => self.first,
            1 => self.second,
            else => null,
        };
    }

    fn applyLayout(self: *SplitView) void {
        const tree = &self.ui.tree;
        const p = self.props;
        tree.get(self.node).?.style.direction = if (p.vertical) .column else .row;
        const fs = tree.get(self.first).?;
        const dv = tree.get(self.divider).?;
        const sc = tree.get(self.second).?;
        const flex_style: Style = .{ .direction = .column, .grow = 1, .shrink = 1 };
        const fixed_style: Style = .{ .direction = .column, .shrink = 0, .grow = 0 };
        fs.style = if (p.anchor_second) flex_style else fixed_style;
        sc.style = if (p.anchor_second) fixed_style else flex_style;
        dv.style = .{ .shrink = 0, .grow = 0 };
        const anchored = if (p.anchor_second) sc else fs;
        if (p.vertical) {
            anchored.style.height = Length.px(p.first_size);
            dv.style.height = Length.px(p.divider_size);
            dv.cursor = .resize_vertical;
        } else {
            anchored.style.width = Length.px(p.first_size);
            dv.style.width = Length.px(p.divider_size);
            dv.cursor = .resize_horizontal;
        }
        tree.markDirty(self.node, .{ .layout = true, .paint = true });
        tree.markDirty(self.first, .{ .layout = true, .paint = true });
        tree.markDirty(self.divider, .{ .layout = true, .paint = true });
        tree.markDirty(self.second, .{ .layout = true, .paint = true });
    }

    /// Set the first pane's size (clamped by the minimums).
    pub fn setFirstSize(self: *SplitView, size: f32) void {
        const tree = &self.ui.tree;
        const node = tree.get(self.node).?;
        const total = if (self.props.vertical) node.rect.h else node.rect.w;
        const min_anchored = if (self.props.anchor_second) self.props.min_second else self.props.min_first;
        const min_other = if (self.props.anchor_second) self.props.min_first else self.props.min_second;
        const room = total - self.props.divider_size - min_other;
        const clamped = std.math.clamp(size, min_anchored, @max(room, min_anchored));
        if (clamped == self.props.first_size) return;
        self.props.first_size = clamped;
        self.applyLayout();
    }

    fn paintDivider(self: *SplitView, pc: *PaintCtx) paint_ctx.Error!void {
        const hot = self.dragging;
        const c = if (hot) Color.rgb(64, 140, 255) else Color.rgba(255, 255, 255, 40);
        const r = pc.rect;
        // A thin line centered in the divider.
        if (self.props.vertical) {
            try pc.list.fillRect(.{ .x = r.x, .y = r.y + r.h / 2 - 1, .w = r.w, .h = 2 }, .{ .color = c });
        } else {
            try pc.list.fillRect(.{ .x = r.x + r.w / 2 - 1, .y = r.y, .w = 2, .h = r.h }, .{ .color = c });
        }
    }

    fn onDivider(self: *SplitView, ev: *event.Event) void {
        const along = if (self.props.vertical) ev.y else ev.x;
        switch (ev.kind) {
            .pointer_down => if (ev.button == 1) {
                self.dragging = true;
                self.out.dragging = true;
                self.drag_from = along;
                self.drag_size = self.props.first_size;
                ev.handled = true;
                self.ui.tree.markDirty(self.divider, .{ .paint = true });
            },
            .pointer_move => if (self.dragging) {
                const delta = along - self.drag_from;
                self.setFirstSize(if (self.props.anchor_second) self.drag_size - delta else self.drag_size + delta);
            },
            .pointer_up => if (self.dragging) {
                self.dragging = false;
                self.out.dragging = false;
                self.ui.tree.markDirty(self.divider, .{ .paint = true });
            },
            else => {},
        }
    }

    pub fn handleEvent(self: *SplitView, ev: *event.Event) void {
        _ = self;
        _ = ev;
    }

    pub fn paintHook(self: *SplitView, pc: *PaintCtx) paint_ctx.Error!void {
        _ = self;
        _ = pc;
    }

    pub fn prepare(self: *SplitView) void {
        _ = self;
    }

    /// Notice prop changes written directly (the inspector, a loaded document).
    pub fn update(self: *SplitView) void {
        self.ui.verifyProps(self.node, &self.checker, &self.props, "split_view");
        const fs = self.ui.tree.get(if (self.props.anchor_second) self.second else self.first) orelse return;
        const want = Length.px(self.props.first_size);
        const have = if (self.props.vertical) fs.style.height else fs.style.width;
        const anchor_ok = (fs.style.grow == 0);
        const dir_ok = (self.ui.tree.get(self.node).?.style.direction == .column) == self.props.vertical;
        if (!dir_ok or !anchor_ok or !std.meta.eql(have, want)) self.applyLayout();
    }

    pub fn endFrame(self: *SplitView) void {
        _ = self;
    }
};

// ---- tests -----------------------------------------------------------------

const testing = std.testing;
const draw_list = @import("../core/draw_list.zig");

const Rig = struct {
    ui: Ui,
    cmds: [256]draw_list.Command = undefined,
    glyphs: [64]draw_list.Glyph = undefined,
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
        try self.ui.layoutAndPaint(.{ .w = 600, .h = 400 }, &self.list);
        self.ui.endFrame();
    }

    fn split(self: *Rig, o: SplitView.Options) !*SplitView {
        var opts = o;
        opts.style = .{ .width = Length.px(400), .height = Length.px(200), .shrink = 0 };
        const s = try self.ui.add(SplitView, self.ui.tree.root, opts);
        try self.frame();
        return s;
    }
};

test "panes get the first size and the rest, with the divider between" {
    const r = try Rig.init();
    defer r.deinit();
    const s = try r.split(.{ .first_size = 150, .divider_size = 6 });
    const a = r.ui.tree.get(s.firstNode()).?.rect;
    const d = r.ui.tree.get(s.divider).?.rect;
    const b = r.ui.tree.get(s.secondNode()).?.rect;
    try testing.expectEqual(@as(f32, 150), a.w);
    try testing.expectEqual(@as(f32, 150), d.x);
    try testing.expectEqual(@as(f32, 6), d.w);
    try testing.expectEqual(@as(f32, 156), b.x);
    try testing.expectEqual(@as(f32, 400 - 156), b.w);
    try testing.expectEqual(@as(f32, 200), a.h); // panes fill the height
}

test "vertical splits stack the panes" {
    const r = try Rig.init();
    defer r.deinit();
    const s = try r.split(.{ .vertical = true, .first_size = 60 });
    const a = r.ui.tree.get(s.firstNode()).?.rect;
    const b = r.ui.tree.get(s.secondNode()).?.rect;
    try testing.expectEqual(@as(f32, 60), a.h);
    try testing.expectEqual(@as(f32, 66), b.y);
    try testing.expectEqual(@as(f32, 200 - 66), b.h);
    try testing.expectEqual(@as(f32, 400), a.w);
    try testing.expect(r.ui.tree.get(s.divider).?.cursor == .resize_vertical);
}

test "dragging the divider resizes the first pane within the minimums" {
    const r = try Rig.init();
    defer r.deinit();
    const s = try r.split(.{ .first_size = 150 });
    const ui = &r.ui;
    const dv = ui.tree.absoluteRect(s.divider).?;
    const x = dv.x + 3;
    ui.pointerMove(x, 50);
    ui.pointerButtonEx(x, 50, 1, true, 1);
    try testing.expect(s.out.dragging);
    ui.pointerMove(x + 70, 50);
    try r.frame();
    try testing.expectEqual(@as(f32, 220), s.props.first_size);
    try testing.expectEqual(@as(f32, 220), ui.tree.get(s.firstNode()).?.rect.w);
    // The drag keeps going outside the divider (it holds the pointer) and clamps.
    ui.pointerMove(x + 900, 50);
    try r.frame();
    try testing.expectEqual(@as(f32, 400 - 6 - 48), s.props.first_size); // the second pane keeps its minimum
    ui.pointerMove(x - 900, 50);
    try r.frame();
    try testing.expectEqual(@as(f32, 48), s.props.first_size);
    ui.pointerButtonEx(x - 900, 50, 1, false, 1);
    try testing.expect(!s.out.dragging);
    ui.pointerMove(x + 100, 50); // no longer dragging
    try testing.expectEqual(@as(f32, 48), s.props.first_size);
}

test "content in the panes and prop changes written directly both work" {
    const r = try Rig.init();
    defer r.deinit();
    const s = try r.split(.{ .first_size = 100 });
    const inner = try r.ui.tree.create(.{ .style = .{ .grow = 1 } });
    try r.ui.tree.appendChild(s.firstNode(), inner);
    try r.frame();
    try testing.expectEqual(@as(f32, 100), r.ui.tree.get(inner).?.rect.w);
    s.props.first_size = 200; // a raw write, as the inspector does
    r.ui.tree.markDirty(s.node, .{ .layout = true });
    try r.frame();
    try r.frame();
    try testing.expectEqual(@as(f32, 200), r.ui.tree.get(s.firstNode()).?.rect.w);
    s.props.vertical = true;
    r.ui.tree.markDirty(s.node, .{ .layout = true });
    try r.frame();
    try r.frame();
    try testing.expectEqual(@as(f32, 200), r.ui.tree.get(s.firstNode()).?.rect.h);
}

test "anchoring the second pane keeps it at its size while the first flexes; dragging moves it the other way" {
    const r = try Rig.init();
    defer r.deinit();
    const s = try r.split(.{ .first_size = 120, .anchor_second = true, .divider_size = 6 });
    const a = r.ui.tree.get(s.firstNode()).?.rect;
    const d = r.ui.tree.get(s.divider).?.rect;
    const b = r.ui.tree.get(s.secondNode()).?.rect;
    try testing.expectEqual(@as(f32, 120), b.w);
    try testing.expectEqual(@as(f32, 400 - 120 - 6), a.w);
    try testing.expectEqual(a.w, d.x);

    // Dragging right shrinks the anchored (second) pane.
    const ui = &r.ui;
    const x = ui.tree.absoluteRect(s.divider).?.x + 3;
    ui.pointerMove(x, 50);
    ui.pointerButtonEx(x, 50, 1, true, 1);
    ui.pointerMove(x + 40, 50);
    try r.frame();
    try testing.expectEqual(@as(f32, 80), s.props.first_size);
    try testing.expectEqual(@as(f32, 80), ui.tree.get(s.secondNode()).?.rect.w);
    ui.pointerButtonEx(x + 40, 50, 1, false, 1);
}
