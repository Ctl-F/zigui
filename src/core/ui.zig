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
const label = @import("../widgets/label.zig");
const Text = @import("../widgets/common.zig").Text;
const font = @import("../text/font.zig");
const TextSystem = @import("../text/system.zig").TextSystem;
const text_block = @import("../text/block.zig");
const Color = geometry.Color;

const Button = button.Button;
const Label = label.Label;

const ButtonSlot = struct {
    block: Button,
    checker: shadow.Checker(Button.Props),
};

const LabelSlot = struct {
    block: Label,
    checker: shadow.Checker(Label.Props),
};

pub const Ui = struct {
    gpa: std.mem.Allocator,
    text: TextSystem,
    tree: Tree,
    layout: Layout,
    input: Input = .{},
    theme: Theme = .{},
    buttons: Pool(ButtonSlot, 64),
    labels: Pool(LabelSlot, 64),

    pub fn init(gpa: std.mem.Allocator) !Ui {
        var tree = try Tree.init(gpa);
        errdefer tree.deinit();
        return .{
            .gpa = gpa,
            .text = TextSystem.init(gpa),
            .tree = tree,
            .layout = Layout.init(gpa),
            .buttons = Pool(ButtonSlot, 64).init(gpa),
            .labels = Pool(LabelSlot, 64).init(gpa),
        };
    }

    pub fn deinit(self: *Ui) void {
        var it = self.buttons.iterator();
        while (it.next()) |e| self.freeText(&e.ptr.block.props.text);
        self.buttons.deinit();
        var lit = self.labels.iterator();
        while (lit.next()) |e| self.freeText(&e.ptr.block.props.text);
        self.labels.deinit();
        self.text.deinit();
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

    fn freeText(self: *Ui, t: *Text) void {
        if (t.ptr) |p| self.gpa.free(p[0..t.len]);
        t.* = .{};
    }

    /// Replace a widget's text with a toolkit-owned copy of `text`.
    fn replaceText(self: *Ui, t: *Text, text: []const u8) !void {
        const copy = try self.gpa.dupe(u8, text);
        self.freeText(t);
        t.* = .{ .ptr = copy.ptr, .len = copy.len };
    }

    /// Copy `text` into toolkit-owned storage; the caller may free its own copy.
    pub fn setButtonText(self: *Ui, b: *Button, text: []const u8) !void {
        try self.replaceText(&b.props.text, text);
        self.tree.markDirty(b.node, DirtyFlags.layout_and_paint);
    }

    // ---- labels -----------------------------------------------------------

    pub fn createLabel(self: *Ui, parent: Handle, style: Style, text: []const u8) !*Label {
        const node_h = try self.tree.create(.{ .role = .label, .style = style });
        errdefer _ = self.tree.destroySubtree(node_h);
        try self.tree.appendChild(parent, node_h);

        var blk: Label = .{ .node = node_h };
        const slot_h = try self.labels.create(.{ .block = blk, .checker = shadow.Checker(Label.Props).init(&blk.props) });
        errdefer _ = self.labels.destroy(slot_h);
        const slot = self.labels.get(slot_h).?;
        try self.replaceText(&slot.block.props.text, text);
        slot.checker.sync(&slot.block.props);
        return &slot.block;
    }

    pub fn setLabelText(self: *Ui, l: *Label, text: []const u8) !void {
        try self.replaceText(&l.props.text, text);
        self.tree.markDirty(l.node, DirtyFlags.layout_and_paint);
    }

    // ---- fonts ------------------------------------------------------------

    /// Register a font backend. The first font added becomes both theme fonts.
    pub fn addFont(self: *Ui, backend: font.Backend) !u32 {
        const id = try self.text.addFont(backend);
        if (id == 0) {
            self.theme.ui_font = 0;
            self.theme.mono_font = 0;
        }
        return id;
    }

    /// Shape `text` for the node and set its intrinsic size, if it changed.
    /// Silently keeps the old text if allocation fails or no font exists.
    fn syncText(self: *Ui, h: Handle, text: Text, f: u32, size: f32, color: Color, al: text_block.Align) void {
        if (f >= self.text.fonts.items.len) return;
        const node = self.tree.get(h) orelse return;
        const src = text.slice();

        if (node.text) |old| {
            const same = old.src_ptr == @intFromPtr(src.ptr) and old.src_len == src.len and old.font == f and old.size == size;
            if (same) {
                if (!std.meta.eql(old.color, color) or old.align_x != al) {
                    old.color = color;
                    old.align_x = al;
                    self.tree.markDirty(h, DirtyFlags.paint_only);
                }
                return;
            }
        } else if (src.len == 0) {
            return;
        }

        var glyphs: std.ArrayListUnmanaged(@import("../text/system.zig").Glyph) = .empty;
        const r = self.text.shape(f, size, src, &glyphs, self.gpa) catch {
            glyphs.deinit(self.gpa);
            return;
        };
        const m = self.text.metrics(f, size);
        const owned = glyphs.toOwnedSlice(self.gpa) catch {
            glyphs.deinit(self.gpa);
            return;
        };
        self.tree.setText(h, .{
            .glyphs = owned,
            .width = r.width,
            .ascent = m.ascent,
            .descent = m.descent,
            .line_height = m.lineHeight(),
            .font = f,
            .size = size,
            .color = color,
            .align_x = al,
            .subpixel = !self.text.isMonospace(f),
            .src_ptr = @intFromPtr(src.ptr),
            .src_len = src.len,
        }) catch return;
        node.intrinsic = .{ .w = r.width, .h = m.lineHeight() };
        self.tree.markDirty(h, DirtyFlags.layout_and_paint);
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
        self.sweep(&self.buttons);
        self.sweep(&self.labels);

        var it = self.buttons.iterator();
        while (it.next()) |e| {
            const b = &e.ptr.block;
            const node = self.tree.get(b.node).?;
            self.verifyProps(b.node, &e.ptr.checker, &b.props, "button");

            const look = self.theme.button_painter(b, &self.theme);
            if (!std.mem.eql(u8, std.mem.asBytes(&look), std.mem.asBytes(&node.visual))) {
                node.visual = look;
                self.tree.markDirty(b.node, DirtyFlags.paint_only);
            }
            const c = self.theme.button_colors[@min(@intFromEnum(b.props.variant), self.theme.button_colors.len - 1)];
            self.syncText(b.node, b.props.text, self.theme.ui_font, self.theme.font_size, if (b.props.enabled) c.text else c.text_disabled, b.props.text_align);
        }

        var lit = self.labels.iterator();
        while (lit.next()) |e| {
            const l = &e.ptr.block;
            self.verifyProps(l.node, &e.ptr.checker, &l.props, "label");
            const f = switch (l.props.font) {
                .ui => self.theme.ui_font,
                .mono => self.theme.mono_font,
            };
            const size = if (l.props.size > 0) l.props.size else self.theme.font_size;
            const color = if (l.props.color.a != 0) l.props.color else self.theme.text_color;
            self.syncText(l.node, l.props.text, f, size, color, l.props.text_align);
            if (self.tree.get(l.node).?.text) |t| {
                l.out.text_width = t.width;
                l.out.text_height = t.line_height;
            }
        }
    }

    /// Free blocks whose node was destroyed. Restarts after each removal: the
    /// pool must not be mutated mid-iteration.
    fn sweep(self: *Ui, pool: anytype) void {
        while (true) {
            var stale: ?Handle = null;
            var it = pool.iterator();
            while (it.next()) |e| {
                if (!self.tree.isValid(e.ptr.block.node)) {
                    stale = e.handle;
                    break;
                }
            }
            const h = stale orelse return;
            self.freeText(&pool.get(h).?.block.props.text);
            _ = pool.destroy(h);
        }
    }

    /// Shadow-check raw prop writes; fold any missing dirty bits into the tree.
    fn verifyProps(self: *Ui, h: Handle, checker: anytype, props: anytype, name: []const u8) void {
        const node = self.tree.get(h).?;
        var flags = node.dirty;
        checker.verify(props, &flags, name);
        const added = DirtyFlags.fromBits(flags.bits() & ~node.dirty.bits());
        if (!added.isClean()) self.tree.markDirty(h, added);
    }

    /// Glyph bitmap source for the renderer: `software.render(..., .{ .glyphs = ui.glyphProvider() })`.
    pub fn glyphProvider(self: *Ui) @import("../text/system.zig").GlyphProvider {
        return self.text.provider();
    }

    /// True if anything needs layout or repaint.
    pub fn isDirty(self: *Ui) bool {
        const root = self.tree.get(self.tree.root) orelse return false;
        return !root.dirty.isClean();
    }

    /// Lay out for a window of `size` (logical pixels) and rebuild `list`.
    pub fn layoutAndPaint(self: *Ui, size: geometry.Size, list: *DrawList) !void {
        self.text.atlas.beginFrame();
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
const Edges = @import("style.zig").Edges;
const draw_list = @import("draw_list.zig");

const Harness = struct {
    ui: Ui,
    cmds: [64]draw_list.Command = undefined,
    glyph_store: [256]draw_list.Glyph = undefined,
    list: DrawList = undefined,

    fn init() !*Harness {
        const h = try std.testing.allocator.create(Harness);
        h.ui = try Ui.init(std.testing.allocator);
        h.list = DrawList.init(&h.cmds, &h.glyph_store);
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

// ---- text integration tests -------------------------------------------------

const TextHarness = struct {
    h: *Harness,
    prop: font.TestFont = .{},
    mono: font.TestFont = .{ .monospace = true },

    fn init() !*TextHarness {
        const t = try std.testing.allocator.create(TextHarness);
        t.* = .{ .h = try Harness.init() };
        _ = try t.h.ui.addFont(t.prop.backend());
        t.h.ui.theme.mono_font = try t.h.ui.addFont(t.mono.backend());
        t.h.ui.theme.font_size = 20;
        return t;
    }

    fn deinit(self: *TextHarness) void {
        self.h.deinit();
        std.testing.allocator.destroy(self);
    }
};

test "a label measures its text and lays out at that size" {
    const t = try TextHarness.init();
    defer t.deinit();
    const l = try t.h.ui.createLabel(t.h.ui.tree.root, .{}, "Mi");
    try t.h.frame();
    const node = t.h.ui.tree.get(l.node).?;
    // M = 0.9em, i = 0.25em at 20px; line height = (0.8 + 0.2 + 0.1) * 20.
    try std.testing.expectApproxEqAbs(@as(f32, 23), node.rect.w, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 22), node.rect.h, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 23), l.out.text_width, 0.01);
}

test "labels reshape when text, size, or font change, and keep their text copy" {
    const t = try TextHarness.init();
    defer t.deinit();
    const ui = &t.h.ui;
    const l = try ui.createLabel(ui.tree.root, .{}, "ab");
    try t.h.frame();
    const w1 = l.out.text_width;

    var buf = [_]u8{ 'a', 'b', 'c' };
    try ui.setLabelText(l, &buf);
    buf[0] = 'Z'; // the toolkit copied it
    try t.h.frame();
    try std.testing.expect(l.out.text_width > w1);
    try std.testing.expectEqual(@as(u32, 'a'), ui.tree.get(l.node).?.text.?.glyphs[0].id);

    const w2 = l.out.text_width;
    l.props.size = 40; // raw write: the shadow checker or sync must pick it up
    try t.h.frame();
    try std.testing.expectApproxEqAbs(w2 * 2, l.out.text_width, 0.01);

    l.props.font = .mono;
    try t.h.frame();
    try std.testing.expect(!ui.tree.get(l.node).?.text.?.subpixel); // monospace snaps to pixels
    try std.testing.expectApproxEqAbs(@as(f32, 3 * 0.6 * 40), l.out.text_width, 0.01);
}

test "an auto-sized button wraps its label plus padding, and paints centered text" {
    const t = try TextHarness.init();
    defer t.deinit();
    const ui = &t.h.ui;
    ui.tree.get(ui.tree.root).?.style = .{ .align_items = .start };
    const b = try ui.createButton(ui.tree.root, .{ .padding = Edges.xy(10, 5) });
    try ui.setButtonText(b, "MM"); // 2 * 0.9 * 20 = 36 wide
    try t.h.frame();

    const node = ui.tree.get(b.node).?;
    try std.testing.expectApproxEqAbs(@as(f32, 56), node.rect.w, 0.01); // 36 + 2 * 10
    try std.testing.expectApproxEqAbs(@as(f32, 32), node.rect.h, 0.01); // 22 + 2 * 5

    var found = false;
    for (t.h.list.items()) |cmd| {
        if (cmd.kind != .glyph_run) continue;
        found = true;
        try std.testing.expectEqual(@as(u32, 2), cmd.b);
        const g = t.h.list.glyphItems()[cmd.a];
        try std.testing.expectApproxEqAbs(@as(f32, 10), g.x, 0.01); // content-box left
        // Baseline: padding 5 + half the 2px line gap + ascent 16.
        try std.testing.expectApproxEqAbs(@as(f32, 22), g.y, 0.01);
        try std.testing.expectEqual(ui.theme.button_colors[0].text, cmd.paint.color);
    }
    try std.testing.expect(found);
}

test "disabled buttons use the disabled text color" {
    const t = try TextHarness.init();
    defer t.deinit();
    const ui = &t.h.ui;
    const b = try ui.createButton(ui.tree.root, .{ .padding = Edges.all(4) });
    try ui.setButtonText(b, "x");
    ui.setButtonEnabled(b, false);
    try t.h.frame();
    try std.testing.expectEqual(ui.theme.button_colors[0].text_disabled, ui.tree.get(b.node).?.text.?.color);
}

test "destroying a node frees its text, and text outlives nothing" {
    const t = try TextHarness.init();
    defer t.deinit(); // leak-checked
    const ui = &t.h.ui;
    const l = try ui.createLabel(ui.tree.root, .{}, "temporary");
    const b = try ui.createButton(ui.tree.root, .{});
    try ui.setButtonText(b, "also temporary");
    try t.h.frame();
    _ = ui.tree.destroySubtree(l.node);
    t.h.ui.update();
    try std.testing.expectEqual(@as(u32, 0), ui.labels.count());
    try std.testing.expectEqual(@as(u32, 1), ui.buttons.count());
}

test "text renders through the software renderer" {
    const software = @import("../render/software.zig");
    const t = try TextHarness.init();
    defer t.deinit();
    const ui = &t.h.ui;
    ui.tree.get(ui.tree.root).?.visual.background = Color.white;
    const l = try ui.createLabel(ui.tree.root, .{}, "MMM");
    l.props.color = Color.black;
    try t.h.frame();

    var fb = try software.Framebuffer.init(std.testing.allocator, 400, 100);
    defer fb.deinit(std.testing.allocator);
    software.render(&fb, &t.h.list, .{ .clear = Color.white, .glyphs = ui.glyphProvider() });
    var ink: usize = 0;
    for (fb.pixels) |p| ink += @intFromBool(p.r < 128);
    try std.testing.expect(ink > 100);
    try std.testing.expect(ui.text.atlas.count() >= 1);
}
