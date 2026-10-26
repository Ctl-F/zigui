//! Ui: ties the tree, layout, input, widgets, and theme together.
//!
//! Frame protocol (what an app's loop does):
//!
//!   1. Feed input:      ui.pointerMove / pointerButton / wheel
//!                       (handlers and `out` flags update immediately)
//!   2. App polls `out` flags / reacts to callbacks, sets props
//!   3. ui.update()      verify props against shadows, resolve widget looks
//!   4. if ui.isDirty(): ui.layoutAndPaint(size, &list), then render the list
//!   5. ui.endFrame()    clear frame-scoped flags and dirty bits

const std = @import("std");
const Handle = @import("handle.zig").Handle;
const tree_mod = @import("tree.zig");
const Tree = tree_mod.Tree;
const Pool = @import("pool.zig").Pool;
const geometry = @import("geometry.zig");
const DirtyFlags = @import("dirty.zig").DirtyFlags;
const Style = @import("style.zig").Style;
const Layout = @import("layout.zig").Layout;
const Input = @import("input.zig").Input;
const paint = @import("paint.zig");
const DrawList = @import("draw_list.zig").DrawList;
const shadow = @import("shadow.zig");
const button = @import("../widgets/button.zig");
const Theme = @import("../widgets/theme.zig").Theme;

const Button = button.Button;

const ButtonSlot = struct {
    block: Button,
    checker: shadow.Checker(Button.Props),
};

pub const Ui = struct {
    gpa: std.mem.Allocator,
    tree: Tree,
    layout: Layout,
    input: Input = .{},
    theme: Theme = .{},
    buttons: Pool(ButtonSlot, 64),

    pub fn init(gpa: std.mem.Allocator) !Ui {
        var tree = try Tree.init(gpa);
        errdefer tree.deinit();
        return .{
            .gpa = gpa,
            .tree = tree,
            .layout = Layout.init(gpa),
            .buttons = Pool(ButtonSlot, 64).init(gpa),
        };
    }

    pub fn deinit(self: *Ui) void {
        var it = self.buttons.iterator();
        while (it.next()) |e| self.freeText(&e.ptr.block);
        self.buttons.deinit();
        self.layout.deinit();
        self.tree.deinit();
        self.* = undefined;
    }

    // ---- buttons ----------------------------------------------------------

    /// Create a button node under `parent`. The returned pointer is stable
    /// until the button's node is destroyed (the block is reclaimed in `update`).
    pub fn createButton(self: *Ui, parent: Handle, style: Style) !*Button {
        const node_h = try self.tree.create(.{ .role = .button, .flags = .{ .focusable = true }, .style = style });
        errdefer _ = self.tree.destroySubtree(node_h);
        try self.tree.appendChild(parent, node_h);

        var block: Button = .{ .node = node_h };
        const slot_h = try self.buttons.create(.{ .block = block, .checker = shadow.Checker(Button.Props).init(&block.props) });
        const slot = self.buttons.get(slot_h).?;
        errdefer _ = self.buttons.destroy(slot_h);
        for (button.listened_kinds) |kind| {
            try self.tree.addListener(node_h, .{ .kind = kind, .callback = button.handleEvent, .user_data = &slot.block });
        }
        return &slot.block;
    }

    fn freeText(self: *Ui, b: *Button) void {
        if (b.props.text.ptr) |p| self.gpa.free(p[0..b.props.text.len]);
        b.props.text = .{};
    }

    /// Copy `text` into toolkit-owned storage; the caller may free its own copy.
    pub fn setButtonText(self: *Ui, b: *Button, text: []const u8) !void {
        const copy = try self.gpa.dupe(u8, text);
        self.freeText(b);
        b.props.text = .{ .ptr = copy.ptr, .len = copy.len };
        self.tree.markDirty(b.node, DirtyFlags.layout_and_paint);
    }

    pub fn setButtonEnabled(self: *Ui, b: *Button, enabled: bool) void {
        if (b.props.enabled == enabled) return;
        b.props.enabled = enabled;
        self.tree.markDirty(b.node, DirtyFlags.paint_only);
    }

    pub fn setButtonVariant(self: *Ui, b: *Button, variant: button.Variant) void {
        if (b.props.variant == variant) return;
        b.props.variant = variant;
        self.tree.markDirty(b.node, DirtyFlags.paint_only);
    }

    /// Show or hide a subtree. Hidden nodes take no space and are not painted or hit.
    pub fn setHidden(self: *Ui, h: Handle, hidden: bool) void {
        const node = self.tree.get(h) orelse return;
        if (node.flags.hidden == hidden) return;
        node.flags.hidden = hidden;
        self.tree.markDirty(h, DirtyFlags.layout_and_paint);
        self.tree.markDirty(node.parent, .{ .children = true });
    }

    // ---- input ------------------------------------------------------------

    pub fn pointerMove(self: *Ui, x: f32, y: f32) void {
        self.input.pointerMove(&self.tree, x, y);
    }

    pub fn pointerButton(self: *Ui, x: f32, y: f32, btn: u32, down: bool) void {
        self.input.pointerButton(&self.tree, x, y, btn, down);
    }

    pub fn wheel(self: *Ui, x: f32, y: f32, dx: f32, dy: f32) void {
        self.input.wheel(&self.tree, x, y, dx, dy);
    }

    // ---- frame ------------------------------------------------------------

    /// Reclaim blocks of destroyed buttons, check raw prop writes against the
    /// shadow copies (debug builds), and resolve each widget's look through
    /// the theme's painter.
    pub fn update(self: *Ui) void {
        // Reclaim stale blocks. Restart after each removal: the pool must not
        // be mutated mid-iteration.
        while (true) {
            var stale: ?Handle = null;
            var it = self.buttons.iterator();
            while (it.next()) |e| {
                if (!self.tree.isValid(e.ptr.block.node)) {
                    stale = e.handle;
                    break;
                }
            }
            const h = stale orelse break;
            self.freeText(&self.buttons.get(h).?.block);
            _ = self.buttons.destroy(h);
        }

        var it = self.buttons.iterator();
        while (it.next()) |e| {
            const b = &e.ptr.block;
            const node = self.tree.get(b.node).?;

            var flags = node.dirty;
            e.ptr.checker.verify(&b.props, &flags, "button");
            const added = DirtyFlags.fromBits(flags.bits() & ~node.dirty.bits());
            if (!added.isClean()) self.tree.markDirty(b.node, added);

            const look = self.theme.button_painter(b, &self.theme);
            if (!std.mem.eql(u8, std.mem.asBytes(&look), std.mem.asBytes(&node.visual))) {
                node.visual = look;
                self.tree.markDirty(b.node, DirtyFlags.paint_only);
            }
        }
    }

    /// True if anything needs layout or repaint.
    pub fn isDirty(self: *Ui) bool {
        const root = self.tree.get(self.tree.root) orelse return false;
        return !root.dirty.isClean();
    }

    /// Lay out for a window of `size` (logical pixels) and rebuild `list`.
    pub fn layoutAndPaint(self: *Ui, size: geometry.Size, list: *DrawList) !void {
        try self.layout.run(&self.tree, size);
        try paint.build(&self.tree, list);
    }

    /// End of frame: clear frame-scoped flags and dirty bits.
    pub fn endFrame(self: *Ui) void {
        var it = self.buttons.iterator();
        while (it.next()) |e| e.ptr.block.out.clicked = false;
        self.tree.clearDirty(self.tree.root);
    }
};

// ---- tests -----------------------------------------------------------------

const Length = @import("length.zig").Length;
const Color = geometry.Color;
const draw_list = @import("draw_list.zig");

const Harness = struct {
    ui: Ui,
    cmds: [64]draw_list.Command = undefined,
    list: DrawList = undefined,

    fn init() !*Harness {
        const h = try std.testing.allocator.create(Harness);
        h.ui = try Ui.init(std.testing.allocator);
        h.list = DrawList.init(&h.cmds, &.{});
        h.ui.tree.get(h.ui.tree.root).?.style = .{ .align_items = .start, .gap = Length.px(10) };
        return h;
    }

    fn deinit(self: *Harness) void {
        self.ui.deinit();
        std.testing.allocator.destroy(self);
    }

    fn frame(self: *Harness) !void {
        self.ui.update();
        if (self.ui.isDirty()) try self.ui.layoutAndPaint(.{ .w = 400, .h = 100 }, &self.list);
        self.ui.endFrame();
    }

    fn click(self: *Harness, x: f32, y: f32) void {
        self.ui.pointerMove(x, y);
        self.ui.pointerButton(x, y, 1, true);
        self.ui.pointerButton(x, y, 1, false);
    }
};

fn box(w: f32, h: f32) Style {
    return .{ .width = Length.px(w), .height = Length.px(h), .shrink = 0 };
}

test "a click sets flags, bumps the counter, and runs the callback" {
    const t = try Harness.init();
    defer t.deinit();
    const Count = struct {
        var n: u32 = 0;
        fn cb(_: *event_mod.Event, user: ?*anyopaque) callconv(.c) void {
            const p: *u32 = @ptrCast(@alignCast(user.?));
            p.* += 1;
        }
    };
    Count.n = 0;
    const b = try t.ui.createButton(t.ui.tree.root, box(80, 30));
    b.props.on_click = Count.cb;
    b.props.on_click_user = &Count.n;
    try t.frame();

    t.click(10, 10);
    try std.testing.expect(b.out.clicked);
    try std.testing.expectEqual(@as(u32, 1), b.out.click_count);
    try std.testing.expectEqual(@as(u32, 1), Count.n);
    try std.testing.expect(!b.out.pressed);
    try std.testing.expect(b.out.hovered);

    try t.frame(); // endFrame clears the frame-scoped flag, not the counter
    try std.testing.expect(!b.out.clicked);
    try std.testing.expectEqual(@as(u32, 1), b.out.click_count);
}

test "clicking outside, or on a disabled button, does nothing" {
    const t = try Harness.init();
    defer t.deinit();
    const a = try t.ui.createButton(t.ui.tree.root, box(80, 30));
    const b = try t.ui.createButton(t.ui.tree.root, box(80, 30));
    t.ui.setButtonEnabled(b, false);
    try t.frame();

    t.click(300, 80); // empty space
    t.click(100, 10); // over b (x 90..170)
    try std.testing.expectEqual(@as(u32, 0), a.out.click_count);
    try std.testing.expectEqual(@as(u32, 0), b.out.click_count);
    try std.testing.expect(!b.out.pressed);
}

test "hover and press change the look and mark paint dirty" {
    const t = try Harness.init();
    defer t.deinit();
    const b = try t.ui.createButton(t.ui.tree.root, box(80, 30));
    try t.frame();
    const node = t.ui.tree.get(b.node).?;
    const c = t.ui.theme.button_colors[0];
    try std.testing.expectEqual(c.normal, node.visual.background);
    try std.testing.expect(!t.ui.isDirty());

    t.ui.pointerMove(10, 10);
    t.ui.update();
    try std.testing.expectEqual(c.hover, node.visual.background);
    try std.testing.expect(t.ui.isDirty());
    try t.frame();

    t.ui.pointerButton(10, 10, 1, true);
    t.ui.update();
    try std.testing.expectEqual(c.pressed, node.visual.background);
    t.ui.pointerButton(10, 10, 1, false);
    t.ui.pointerMove(300, 90);
    try t.frame();
    try std.testing.expectEqual(c.normal, node.visual.background);
}

test "setButtonText copies, so the caller can free; and frees on deinit" {
    const t = try Harness.init();
    defer t.deinit(); // the testing allocator reports leaks
    const b = try t.ui.createButton(t.ui.tree.root, box(80, 30));
    var buf = [_]u8{ 'h', 'i' };
    try t.ui.setButtonText(b, &buf);
    buf[0] = 'X';
    try std.testing.expectEqualStrings("hi", b.props.text.slice());
    try t.ui.setButtonText(b, "longer text"); // replaces and frees the old copy
    try std.testing.expectEqualStrings("longer text", b.props.text.slice());
}

test "destroying a button's node reclaims its block" {
    const t = try Harness.init();
    defer t.deinit();
    const b = try t.ui.createButton(t.ui.tree.root, box(80, 30));
    try t.ui.setButtonText(b, "bye");
    try std.testing.expectEqual(@as(u32, 1), t.ui.buttons.count());
    _ = t.ui.tree.destroySubtree(b.node);
    t.ui.update();
    try std.testing.expectEqual(@as(u32, 0), t.ui.buttons.count());
}

test "a handler may destroy buttons and add nodes mid-click" {
    const t = try Harness.init();
    defer t.deinit();
    const Ctx = struct {
        ui: *Ui,
        victim: Handle,
        fn cb(_: *event_mod.Event, user: ?*anyopaque) callconv(.c) void {
            const c: *@This() = @ptrCast(@alignCast(user.?));
            _ = c.ui.tree.destroySubtree(c.victim);
        }
    };
    const a = try t.ui.createButton(t.ui.tree.root, box(80, 30));
    const victim = try t.ui.createButton(t.ui.tree.root, box(80, 30));
    var ctx: Ctx = .{ .ui = &t.ui, .victim = victim.node };
    a.props.on_click = Ctx.cb;
    a.props.on_click_user = &ctx;
    try t.frame();

    t.click(10, 10);
    try std.testing.expect(!t.ui.tree.isValid(victim.node));
    try t.frame();
    try std.testing.expectEqual(@as(u32, 1), t.ui.buttons.count());
}

test "raw prop writes are caught by the shadow checker and still repaint" {
    if (!shadow.enabled or shadow.strict) return error.SkipZigTest;
    const t = try Harness.init();
    defer t.deinit();
    const b = try t.ui.createButton(t.ui.tree.root, box(80, 30));
    try t.frame();
    try std.testing.expect(!t.ui.isDirty());

    b.props.variant = .primary; // raw write, no dirty marking
    t.ui.update(); // warns, self-corrects
    try std.testing.expect(t.ui.isDirty());
    try std.testing.expectEqual(t.ui.theme.button_colors[1].normal, t.ui.tree.get(b.node).?.visual.background);
}

test "variant setter marks paint and swaps colors" {
    const t = try Harness.init();
    defer t.deinit();
    const b = try t.ui.createButton(t.ui.tree.root, box(80, 30));
    try t.frame();
    t.ui.setButtonVariant(b, .danger);
    try std.testing.expect(t.ui.isDirty());
    try t.frame();
    try std.testing.expectEqual(t.ui.theme.button_colors[2].normal, t.ui.tree.get(b.node).?.visual.background);
}

const event_mod = @import("event.zig");

test "buttons paint into the draw list" {
    const t = try Harness.init();
    defer t.deinit();
    _ = try t.ui.createButton(t.ui.tree.root, box(80, 30));
    try t.frame();
    try std.testing.expect(t.list.items().len >= 1);
    try std.testing.expectEqual(Color.rgb(0x4a, 0x4d, 0x52), t.list.items()[0].paint.color);
}

test "setHidden relays out the parent" {
    const t = try Harness.init();
    defer t.deinit();
    const a = try t.ui.createButton(t.ui.tree.root, box(80, 30));
    const b = try t.ui.createButton(t.ui.tree.root, box(80, 30));
    try t.frame();
    try std.testing.expectEqual(@as(f32, 90), t.ui.tree.get(b.node).?.rect.x);
    t.ui.setHidden(a.node, true);
    try t.frame();
    try std.testing.expectEqual(@as(f32, 0), t.ui.tree.get(b.node).?.rect.x);
    t.click(10, 10); // the hidden button no longer takes the click; b is under it now
    try std.testing.expectEqual(@as(u32, 0), a.out.click_count);
    try std.testing.expectEqual(@as(u32, 1), b.out.click_count);
}
