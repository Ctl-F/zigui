//! Spacer: empty space in a row or column. By default it is flexible: it grows
//! to take whatever room the siblings leave (push a button to the far end of a
//! toolbar with one). With `size` it is a fixed gap of that many pixels along
//! the parent's main axis.
//!
//!     _ = try ui.add(Button, bar, .{ .text = "File" });
//!     _ = try ui.add(Spacer, bar, .{});                 // flexible
//!     _ = try ui.add(Button, bar, .{ .text = "Help" }); // pinned to the right
//!     _ = try ui.add(Spacer, bar, .{ .size = 12 });     // a 12px gap

const std = @import("std");
const Handle = @import("../core/handle.zig").Handle;
const shadow = @import("../core/shadow.zig");
const Ui = @import("../core/ui.zig").Ui;
const event = @import("../core/event.zig");
const paint_ctx = @import("../core/paint_ctx.zig");
const PaintCtx = paint_ctx.PaintCtx;
const Style = @import("../core/style.zig").Style;
const Length = @import("../core/length.zig").Length;
const Node = @import("../core/tree.zig").Node;

pub const Spacer = struct {
    props: Props = .{},
    out: Out = .{},
    node: Handle,
    ui: *Ui,
    checker: shadow.Checker(Props),
    /// The `size` the node's style was last set up for (null: not yet).
    applied: ?f32 = null,
    applied_row: bool = true,

    pub const Props = struct {
        /// 0: flexible (grows into free space). Otherwise a fixed length in
        /// pixels along the parent's main axis.
        size: f32 = 0,

        pub const dirty_map = .{
            .size = shadow.Category.layout,
        };
    };

    pub const Out = struct {};

    pub const Options = struct {
        style: Style = .{},
        size: f32 = 0,
    };

    pub const listened_kinds = [_]event.EventKind{};

    pub fn nodeTemplate(style: Style) Node {
        var s = style;
        // Flexible unless told otherwise; `apply` and `update` handle a fixed size.
        if (s.grow == 0 and s.width == .auto and s.height == .auto) s.grow = 1;
        return .{ .style = s };
    }

    pub fn init(ui: *Ui, node: Handle) Spacer {
        const props: Props = .{};
        return .{ .node = node, .ui = ui, .checker = shadow.Checker(Props).init(&props) };
    }

    pub fn deinit(self: *Spacer) void {
        _ = self;
    }

    pub fn apply(self: *Spacer, o: Options) !void {
        self.props.size = o.size;
        self.checker.sync(&self.props);
    }

    pub fn handleEvent(self: *Spacer, ev: *event.Event) void {
        _ = self;
        _ = ev;
    }

    pub fn paintHook(self: *Spacer, pc: *PaintCtx) paint_ctx.Error!void {
        _ = self;
        _ = pc;
    }

    pub fn prepare(self: *Spacer) void {
        _ = self;
    }

    /// Follow `props.size` and the parent's direction.
    pub fn update(self: *Spacer) void {
        self.ui.verifyProps(self.node, &self.checker, &self.props, "spacer");
        const tree = &self.ui.tree;
        const n = tree.get(self.node) orelse return;
        const parent_row = if (tree.get(n.parent)) |p| p.style.direction == .row else true;
        if (self.applied != null and self.applied.? == self.props.size and self.applied_row == parent_row) return;
        // The first update keeps what the style already says for a flexible spacer.
        const first = self.applied == null;
        self.applied = self.props.size;
        self.applied_row = parent_row;
        if (self.props.size > 0) {
            n.style.grow = 0;
            n.style.shrink = 0;
            n.style.width = if (parent_row) Length.px(self.props.size) else .auto;
            n.style.height = if (parent_row) .auto else Length.px(self.props.size);
        } else if (!first) {
            n.style.grow = 1;
            n.style.shrink = 1;
            n.style.width = .auto;
            n.style.height = .auto;
        }
        tree.markDirty(self.node, .{ .layout = true });
    }

    pub fn endFrame(self: *Spacer) void {
        _ = self;
    }
};

// ---- tests -----------------------------------------------------------------

const testing = std.testing;
const draw_list = @import("../core/draw_list.zig");
const Button = @import("button.zig").Button;

const Rig = struct {
    ui: Ui,
    cmds: [1024]draw_list.Command = undefined,
    glyphs: [512]draw_list.Glyph = undefined,
    list: draw_list.DrawList = undefined,
    prop: @import("../text/font.zig").TestFont = .{},

    fn init() !*Rig {
        const r = try testing.allocator.create(Rig);
        r.* = .{ .ui = try Ui.init(testing.allocator) };
        _ = try r.ui.addFont(r.prop.backend());
        r.list = draw_list.DrawList.init(&r.cmds, &r.glyphs);
        return r;
    }

    fn deinit(self: *Rig) void {
        self.ui.deinit();
        testing.allocator.destroy(self);
    }

    fn frame(self: *Rig) !void {
        self.ui.update();
        try self.ui.layoutAndPaint(.{ .w = 400, .h = 300 }, &self.list);
        self.ui.endFrame();
    }
};

fn rectOf(r: *Rig, h: Handle) @import("../core/geometry.zig").Rect {
    return r.ui.tree.get(h).?.rect;
}

test "a flexible spacer pushes the next widget to the end of a row" {
    const r = try Rig.init();
    defer r.deinit();
    r.ui.tree.get(r.ui.tree.root).?.style = .{ .direction = .row, .align_items = .start };
    const a = try r.ui.add(Button, r.ui.tree.root, .{ .text = "File", .style = .{ .width = Length.px(60) } });
    _ = try r.ui.add(Spacer, r.ui.tree.root, .{});
    const b = try r.ui.add(Button, r.ui.tree.root, .{ .text = "Help", .style = .{ .width = Length.px(60) } });
    try r.frame();
    try r.frame();
    try testing.expectEqual(@as(f32, 0), rectOf(r, a.node).x);
    try testing.expectEqual(@as(f32, 340), rectOf(r, b.node).x); // 400 - 60
}

test "a sized spacer is a fixed gap along the parent's axis, in rows and columns" {
    const r = try Rig.init();
    defer r.deinit();
    const root = r.ui.tree.root;
    r.ui.tree.get(root).?.style = .{ .direction = .row, .align_items = .start };
    const a = try r.ui.add(Button, root, .{ .text = "a", .style = .{ .width = Length.px(50), .height = Length.px(20) } });
    const sp = try r.ui.add(Spacer, root, .{ .size = 12 });
    const b = try r.ui.add(Button, root, .{ .text = "b", .style = .{ .width = Length.px(50), .height = Length.px(20) } });
    try r.frame();
    try r.frame();
    try testing.expectEqual(@as(f32, 12), rectOf(r, sp.node).w);
    try testing.expectEqual(rectOf(r, a.node).x + 50 + 12, rectOf(r, b.node).x);

    // In a column the same spacer is 12 tall.
    r.ui.tree.get(root).?.style.direction = .column;
    r.ui.tree.markDirty(root, .{ .layout = true });
    try r.frame();
    try r.frame();
    try testing.expectEqual(@as(f32, 12), rectOf(r, sp.node).h);
    try testing.expectEqual(rectOf(r, a.node).y + 20 + 12, rectOf(r, b.node).y);

    // Back to flexible.
    sp.props.size = 0;
    try r.frame();
    try r.frame();
    try testing.expectEqual(@as(f32, 1), r.ui.tree.get(sp.node).?.style.grow);
}
