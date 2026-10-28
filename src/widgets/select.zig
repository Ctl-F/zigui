//! Select: a drop-down list. It shows the chosen option; clicking it (or Enter,
//! Space, Up, Down when focused) opens a `Menu` of the options below it.
//!
//! The options are kept as one text, one option per line (`props.options`), so
//! the registry, UI documents, and the builder can edit them like any text.
//! From code pass `.items = &.{ "a", "b" }`.
//!
//!     const align_pick = try ui.add(Select, parent, .{
//!         .items = &.{ "start", "center", "end" },
//!         .selected = 1,
//!         .on_change = .bind(&app, App.onAlign),
//!     });
//!     // later: align_pick.out.changed, align_pick.props.selected

const std = @import("std");
const common = @import("common.zig");
const Handle = @import("../core/handle.zig").Handle;
const shadow = @import("../core/shadow.zig");
const geometry = @import("../core/geometry.zig");
const Color = geometry.Color;
const Ui = @import("../core/ui.zig").Ui;
const event = @import("../core/event.zig");
const paint_ctx = @import("../core/paint_ctx.zig");
const PaintCtx = paint_ctx.PaintCtx;
const draw_list = @import("../core/draw_list.zig");
const DirtyFlags = @import("../core/dirty.zig").DirtyFlags;
const Style = @import("../core/style.zig").Style;
const Edges = @import("../core/style.zig").Edges;
const Length = @import("../core/length.zig").Length;
const Node = @import("../core/tree.zig").Node;
const Text = @import("common.zig").Text;
const theme_mod = @import("theme.zig");
const menu = @import("menu.zig");

/// Draws a select's box and arrow.
pub const Painter = *const fn (ctx: *PaintCtx, s: *const Select) paint_ctx.Error!void;

/// Room kept at the right for the arrow.
const arrow_room: f32 = 20;

pub const Select = struct {
    props: Props = .{},
    out: Out = .{},
    node: Handle,
    ui: *Ui,
    checker: shadow.Checker(Props),

    pub const Props = struct {
        /// The options, one per line.
        options: Text = .{},
        /// Index of the chosen option.
        selected: u32 = 0,
        enabled: bool = true,
        on_change: ?event.Callback = null,
        painter: ?Painter = null,

        pub const dirty_map = .{
            .options = shadow.Category.layout,
            .selected = shadow.Category.layout,
            .enabled = shadow.Category.paint,
        };
    };

    pub const Out = struct {
        /// The user chose a different option this frame.
        changed: bool = false,
        change_count: u32 = 0,
        hovered: bool = false,
        focused: bool = false,
        /// Focused after keyboard use (painters draw a ring).
        focus_visible: bool = false,
        /// This select's menu is open.
        open: bool = false,
    };

    pub const Options = struct {
        style: Style = .{},
        /// The options (copied). Use `props.options` / the document for the
        /// newline-separated form.
        items: []const []const u8 = &.{},
        selected: u32 = 0,
        enabled: bool = true,
        on_change: ?event.Callback = null,
        painter: ?Painter = null,
    };

    pub const actions = [_]common.Action{
        .{ .label = "Enabled", .toggle = "enabled", .checkable = true },
    };

    pub const listened_kinds = [_]event.EventKind{ .pointer_enter, .pointer_leave, .click, .key_down, .focus_in, .focus_out };

    /// Inner spacing: the field's, with room for the arrow.
    pub fn themePadding(theme: *const theme_mod.Theme) Edges {
        var e = theme.field_padding;
        e.right = Length.px(switch (e.right) {
            .pixels => |v| v + arrow_room,
            else => arrow_room,
        });
        return e;
    }

    pub fn nodeTemplate(style: Style) Node {
        return .{ .role = .button, .flags = .{ .focusable = true }, .cursor = .pointer, .style = style };
    }

    pub fn init(ui: *Ui, node: Handle) Select {
        const props: Props = .{};
        return .{ .node = node, .ui = ui, .checker = shadow.Checker(Props).init(&props) };
    }

    pub fn deinit(self: *Select) void {
        self.ui.freeText(&self.props.options);
    }

    pub fn apply(self: *Select, o: Options) !void {
        self.props.selected = o.selected;
        self.props.enabled = o.enabled;
        self.props.on_change = o.on_change;
        self.props.painter = o.painter;
        if (o.items.len > 0) try self.setItems(o.items);
        self.checker.sync(&self.props);
    }

    // ---- options ----

    /// Replace the options (copied). The selection index is kept if it fits.
    pub fn setItems(self: *Select, items: []const []const u8) !void {
        var joined: std.ArrayListUnmanaged(u8) = .empty;
        defer joined.deinit(self.ui.gpa);
        for (items, 0..) |it, i| {
            if (i > 0) try joined.append(self.ui.gpa, '\n');
            try joined.appendSlice(self.ui.gpa, it);
        }
        try self.setOptionsText(joined.items);
    }

    /// Replace the options with one text, one option per line.
    pub fn setOptionsText(self: *Select, text: []const u8) !void {
        try self.ui.replaceText(&self.props.options, text);
        self.ui.tree.markDirty(self.node, DirtyFlags.layout_and_paint);
    }

    pub fn count(self: *const Select) usize {
        const b = self.props.options.bytes;
        if (b.len == 0) return 0;
        return std.mem.count(u8, b, "\n") + 1;
    }

    /// The label of option `i`, or "" past the end.
    pub fn itemLabel(self: *const Select, i: usize) []const u8 {
        var it = std.mem.splitScalar(u8, self.props.options.bytes, '\n');
        var n: usize = 0;
        while (it.next()) |line| : (n += 1) {
            if (n == i) return line;
        }
        return "";
    }

    pub fn selectedLabel(self: *const Select) []const u8 {
        return self.itemLabel(self.props.selected);
    }

    /// Choose option `i` (ignored if out of range); calls `on_change` if it changed.
    pub fn setSelected(self: *Select, i: usize) void {
        if (i >= self.count() or self.props.selected == i) return;
        self.props.selected = @intCast(i);
        self.out.changed = true;
        self.out.change_count +%= 1;
        self.ui.tree.markDirty(self.node, DirtyFlags.layout_and_paint);
        if (self.props.on_change) |cb| {
            var ev: event.Event = .{ .kind = .click, .target = self.node, .current = self.node };
            cb.invoke(&ev);
        }
    }

    pub fn setPainter(self: *Select, p: ?Painter) void {
        self.props.painter = p;
        self.ui.tree.markDirty(self.node, DirtyFlags.paint_only);
    }

    // ---- opening ----

    /// Open the drop-down (no-op if there are no options or it is disabled).
    pub fn openMenu(self: *Select) void {
        if (!self.props.enabled) return;
        const n = self.count();
        if (n == 0) return;
        const rect = self.ui.tree.absoluteRect(self.node) orelse return;
        const gpa = self.ui.gpa;
        const items = gpa.alloc(menu.Item, n) catch return;
        defer gpa.free(items);
        for (items, 0..) |*it, i| it.* = .{ .label = self.itemLabel(i), .checked = i == self.props.selected };
        self.ui.openMenu(items, rect.x, rect.bottom(), .{
            .anchor = rect,
            .owner = self.node,
            .min_width = rect.w,
            .focus_index = self.props.selected,
            .on_pick = menu.PickHook.bind(self, onPick),
        }) catch {};
    }

    fn onPick(self: *Select, index: usize) void {
        self.setSelected(index);
    }

    // ---- events ----

    pub fn handleEvent(self: *Select, ev: *event.Event) void {
        switch (ev.kind) {
            .focus_in => {
                self.out.focused = true;
                self.repaint();
            },
            .focus_out => {
                self.out.focused = false;
                self.repaint();
            },
            .pointer_enter => {
                self.out.hovered = true;
                self.repaint();
            },
            .pointer_leave => {
                self.out.hovered = false;
                self.repaint();
            },
            .click => {
                if (self.ui.menu_suppress.eql(self.node)) {
                    self.ui.menu_suppress = Handle.invalid;
                    return;
                }
                self.openMenu();
            },
            .key_down => if (!ev.repeat and (ev.key == .enter or ev.key == .space or ev.key == .down or ev.key == .up)) {
                ev.markHandled();
                self.openMenu();
            },
            else => {},
        }
    }

    fn repaint(self: *Select) void {
        self.ui.tree.markDirty(self.node, DirtyFlags.paint_only);
    }

    pub fn paintHook(self: *Select, pc: *PaintCtx) paint_ctx.Error!void {
        const p = self.props.painter orelse self.ui.theme.select_painter;
        try p(pc, self);
    }

    // ---- frame ----

    pub fn prepare(self: *Select) void {
        self.ui.tree.get(self.node).?.flags.focusable = self.props.enabled;
    }

    pub fn update(self: *Select) void {
        const ui = self.ui;
        ui.verifyProps(self.node, &self.checker, &self.props, "select");
        const open = if (ui.menu) |m| m.owner.eql(self.node) else false;
        const focus_visible = self.out.focused and ui.input.keyboard;
        if (open != self.out.open or focus_visible != self.out.focus_visible) {
            self.out.open = open;
            self.out.focus_visible = focus_visible;
            self.repaint();
        }
        const label: Text = .{ .bytes = self.selectedLabel() };
        ui.syncText(self.node, label, ui.theme.ui_font, ui.theme.font_size, ui.theme.text_color, .start);
    }

    pub fn endFrame(self: *Select) void {
        self.out.changed = false;
    }
};

/// The default look: the text field's box with a chevron.
pub fn defaultPainter(pc: *PaintCtx, s: *const Select) paint_ctx.Error!void {
    const theme = &s.ui.theme;
    const c = theme.field;
    const ring = s.out.focus_visible and s.props.enabled;
    const bg = if (!s.props.enabled) c.background_disabled else if (s.out.hovered or s.out.open) Color.rgb(0x25, 0x27, 0x2b) else c.background;
    try pc.box(.{
        .background = bg,
        .border_color = if (ring or s.out.open) theme.focus_ring else c.border,
        .border_width = if (ring) theme.focus_ring_width else 1,
        .radius = theme.corner_radius,
    });
    pc.text_color = if (s.props.enabled) c.text else c.text_disabled;
    if (s.props.options.bytes.len == 0) return;
    const r = pc.rect;
    const cx = r.right() - 12;
    const cy = r.y + r.h / 2;
    const paint = draw_list.Paint.solid(if (s.props.enabled) c.text else c.text_disabled);
    try pc.list.line(.{ .x = cx - 4, .y = cy - 2 }, .{ .x = cx, .y = cy + 2 }, 1.6, paint);
    try pc.list.line(.{ .x = cx, .y = cy + 2 }, .{ .x = cx + 4, .y = cy - 2 }, 1.6, paint);
}

// ---- tests -----------------------------------------------------------------

const testing = std.testing;
const Length_ = Length;

const Rig = struct {
    ui: Ui,
    cmds: [2048]draw_list.Command = undefined,
    glyphs: [1024]draw_list.Glyph = undefined,
    list: draw_list.DrawList = undefined,
    changes: u32 = 0,
    picked: ?usize = null,
    ran: u32 = 0,
    prop: @import("../text/font.zig").TestFont = .{},

    fn init() !*Rig {
        const r = try testing.allocator.create(Rig);
        r.* = .{ .ui = try Ui.init(testing.allocator) };
        _ = try r.ui.addFont(r.prop.backend());
        r.list = draw_list.DrawList.init(&r.cmds, &r.glyphs);
        r.ui.tree.get(r.ui.tree.root).?.style = .{ .align_items = .start, .direction = .column };
        return r;
    }

    fn deinit(self: *Rig) void {
        self.ui.deinit();
        testing.allocator.destroy(self);
    }

    fn frame(self: *Rig) !void {
        self.ui.update();
        try self.ui.layoutAndPaint(.{ .w = 300, .h = 300 }, &self.list);
        self.ui.endFrame();
    }

    fn onChange(self: *Rig, _: *event.Event) void {
        self.changes += 1;
    }

    fn onPick(self: *Rig, i: usize) void {
        self.picked = i;
    }

    fn onRun(self: *Rig, _: *event.Event) void {
        self.ran += 1;
    }

    fn select(self: *Rig) !*Select {
        const s = try self.ui.add(Select, self.ui.tree.root, .{
            .items = &.{ "start", "center", "end" },
            .on_change = .bind(self, onChange),
            .style = .{ .width = Length_.px(120) },
        });
        try self.frame();
        return s;
    }

    fn click(self: *Rig, x: f32, y: f32) !void {
        self.ui.pointerMove(x, y);
        self.ui.pointerButtonEx(x, y, 1, true, 1);
        self.ui.pointerButtonEx(x, y, 1, false, 1);
        try self.frame();
    }

    fn centerOf(self: *Rig, h: Handle) [2]f32 {
        const r = self.ui.tree.absoluteRect(h).?;
        return .{ r.x + r.w / 2, r.y + r.h / 2 };
    }
};

test "a select shows its option; clicking opens the menu; picking changes it" {
    const r = try Rig.init();
    defer r.deinit();
    const s = try r.select();
    try testing.expectEqual(@as(usize, 3), s.count());
    try testing.expectEqualStrings("start", s.selectedLabel());
    try testing.expect(r.ui.tree.get(s.node).?.text != null);

    const c = r.centerOf(s.node);
    try r.click(c[0], c[1]);
    try testing.expect(r.ui.menuOpen());
    try testing.expect(s.out.open);
    try r.frame();
    const m = r.ui.menu.?;
    try testing.expectEqual(@as(usize, 3), m.entries.len);
    // The menu drops below the select and is as wide.
    const sr = r.ui.tree.absoluteRect(s.node).?;
    const pr = r.ui.tree.absoluteRect(m.panel).?;
    try testing.expect(pr.y >= sr.bottom() and pr.w >= sr.w - 0.5);

    const second = r.centerOf(m.entries[1].row);
    try r.click(second[0], second[1]);
    try testing.expect(!r.ui.menuOpen());
    try testing.expectEqual(@as(u32, 1), s.props.selected);
    try testing.expectEqualStrings("center", s.selectedLabel());
    try testing.expectEqual(@as(u32, 1), r.changes);
    try testing.expect(!s.out.open);
}

test "clicking outside closes the menu without picking; clicking the select again toggles" {
    const r = try Rig.init();
    defer r.deinit();
    const s = try r.select();
    const c = r.centerOf(s.node);
    try r.click(c[0], c[1]);
    try testing.expect(r.ui.menuOpen());
    try r.click(280, 280);
    try testing.expect(!r.ui.menuOpen());
    try testing.expectEqual(@as(u32, 0), s.props.selected);
    try testing.expectEqual(@as(u32, 0), r.changes);

    try r.click(c[0], c[1]);
    try testing.expect(r.ui.menuOpen());
    try r.click(c[0], c[1]); // the opener again: closes, does not reopen
    try testing.expect(!r.ui.menuOpen());
}

test "keyboard: Down opens, arrows move, Enter picks, Escape closes and returns focus" {
    const r = try Rig.init();
    defer r.deinit();
    const s = try r.select();
    r.ui.setFocus(s.node);
    try r.frame();
    r.ui.key(.down, .{}, true, false);
    try r.frame();
    try testing.expect(r.ui.menuOpen());
    // The chosen option starts focused; Down moves to the next.
    r.ui.key(.down, .{}, true, false);
    r.ui.key(.down, .{}, true, false);
    r.ui.key(.enter, .{}, true, false);
    try r.frame();
    try testing.expect(!r.ui.menuOpen());
    try testing.expectEqual(@as(u32, 2), s.props.selected);
    try testing.expect(r.ui.tree.focused.eql(s.node));

    r.ui.key(.space, .{}, true, false);
    try r.frame();
    try testing.expect(r.ui.menuOpen());
    r.ui.key(.escape, .{}, true, false);
    try r.frame();
    try testing.expect(!r.ui.menuOpen());
    try testing.expectEqual(@as(u32, 2), s.props.selected);
    try testing.expect(r.ui.tree.focused.eql(s.node));
}

test "menu items run commands, follow their enabled state, and report the picked index" {
    const r = try Rig.init();
    defer r.deinit();
    _ = try r.ui.registerCommand("t.run", .{ .title = "Run", .run = .bind(r, Rig.onRun) });
    _ = try r.ui.registerCommand("t.off", .{ .title = "Off", .run = .bind(r, Rig.onRun), .enabled = false });
    try r.ui.bindShortcut("ctrl+r", "t.run", .app, null);
    try r.ui.openMenu(&.{
        .{ .label = "Run", .command = "t.run" },
        .{ .separator = true },
        .{ .label = "Off", .command = "t.off" },
        .{ .label = "Plain" },
    }, 20, 20, .{ .on_pick = menu.PickHook.bind(r, Rig.onPick) });
    try r.frame();
    const m = r.ui.menu.?;
    try testing.expect(m.entries[0].enabled and !m.entries[2].enabled);
    try testing.expect(m.entries[0].shortcut.len > 0);

    // A disabled item does nothing.
    const off = r.centerOf(m.entries[2].row);
    try r.click(off[0], off[1]);
    try testing.expect(r.ui.menuOpen());
    try testing.expectEqual(@as(u32, 0), r.ran);

    const run = r.centerOf(m.entries[0].row);
    try r.click(run[0], run[1]);
    try testing.expect(!r.ui.menuOpen());
    try testing.expectEqual(@as(u32, 1), r.ran);
    try testing.expectEqual(@as(?usize, 0), r.picked);

    // A plain item reports its index.
    try r.ui.openMenu(&.{ .{ .label = "a" }, .{ .label = "b" } }, 20, 20, .{ .on_pick = menu.PickHook.bind(r, Rig.onPick) });
    try r.frame();
    const b = r.centerOf(r.ui.menu.?.entries[1].row);
    try r.click(b[0], b[1]);
    try testing.expectEqual(@as(?usize, 1), r.picked);
}

test "a menu near the edge is moved back inside the window" {
    const r = try Rig.init();
    defer r.deinit();
    try r.ui.openMenu(&.{ .{ .label = "one" }, .{ .label = "two" }, .{ .label = "three" } }, 295, 295, .{});
    try r.frame();
    try r.frame();
    const pr = r.ui.tree.absoluteRect(r.ui.menu.?.panel).?;
    try testing.expect(pr.right() <= 300.5 and pr.bottom() <= 300.5);
    try testing.expect(pr.x >= 0 and pr.y >= 0);
}

test "setItems keeps the selection when it fits, and setSelected ignores bad indexes" {
    const r = try Rig.init();
    defer r.deinit();
    const s = try r.select();
    s.setSelected(2);
    try testing.expectEqual(@as(u32, 1), r.changes);
    s.setSelected(9);
    try testing.expectEqual(@as(u32, 2), s.props.selected);
    try s.setItems(&.{ "a", "b" });
    try testing.expectEqual(@as(usize, 2), s.count());
    try testing.expectEqualStrings("", s.selectedLabel()); // index 2 no longer exists
    try testing.expectEqualStrings("b", s.itemLabel(1));
}

test "submenus open on hover and with Right, pick through their own hook, and close with Left, Escape, or outside" {
    const r = try Rig.init();
    defer r.deinit();
    const sub_items = [_]menu.Item{ .{ .label = "one" }, .{ .label = "two" } };
    try r.ui.openMenu(&.{
        .{ .label = "Plain" },
        .{ .label = "More", .submenu = &sub_items },
    }, 20, 20, .{ .on_pick = menu.PickHook.bind(r, Rig.onPick) });
    try r.frame();
    const root = r.ui.menu.?;
    try testing.expect(root.child == null);

    // Hovering the submenu item opens it beside the parent.
    const more = r.centerOf(root.entries[1].row);
    r.ui.pointerMove(more[0], more[1]);
    try r.frame();
    try r.frame();
    const child = root.child.?;
    try testing.expectEqual(@as(usize, 2), child.entries.len);
    const pr = r.ui.tree.absoluteRect(root.panel).?;
    const cr = r.ui.tree.absoluteRect(child.panel).?;
    try testing.expect(cr.x >= pr.right() - 4);
    try testing.expect(root.contains(cr.x + 5, cr.y + 5));

    // Hovering a plain item of the parent closes it again.
    const plain = r.centerOf(root.entries[0].row);
    r.ui.pointerMove(plain[0], plain[1]);
    try r.frame();
    try testing.expect(root.child == null);

    // Right opens it and focuses its first item; Down; Left goes back to the parent.
    r.ui.setFocus(root.entries[1].row);
    r.ui.input.keyboard = true;
    r.ui.key(.right, .{}, true, false);
    try r.frame();
    const c2 = root.child.?;
    try testing.expect(r.ui.tree.focused.eql(c2.entries[0].row));
    r.ui.key(.down, .{}, true, false);
    try testing.expect(r.ui.tree.focused.eql(c2.entries[1].row));
    r.ui.key(.left, .{}, true, false);
    try r.frame();
    try testing.expect(root.child == null);
    try testing.expect(r.ui.menuOpen());
    try testing.expect(r.ui.tree.focused.eql(root.entries[1].row));

    // Escape closes only the submenu; a second Escape closes the menu.
    r.ui.key(.right, .{}, true, false);
    try r.frame();
    try testing.expect(root.child != null);
    r.ui.key(.escape, .{}, true, false);
    try r.frame();
    try testing.expect(root.child == null and r.ui.menuOpen());
    r.ui.key(.escape, .{}, true, false);
    try r.frame();
    try testing.expect(!r.ui.menuOpen());

    // Pick a submenu item: the root's hook gets its index within the submenu.
    try r.ui.openMenu(&.{.{ .label = "More", .submenu = &sub_items }}, 20, 20, .{ .on_pick = menu.PickHook.bind(r, Rig.onPick) });
    try r.frame();
    const m = r.centerOf(r.ui.menu.?.entries[0].row);
    r.ui.pointerMove(m[0], m[1]);
    try r.frame();
    try r.frame();
    const two = r.centerOf(r.ui.menu.?.child.?.entries[1].row);
    try r.click(two[0], two[1]);
    try testing.expect(!r.ui.menuOpen());
    try testing.expectEqual(@as(?usize, 1), r.picked);

    // A press outside closes the whole chain.
    try r.ui.openMenu(&.{.{ .label = "More", .submenu = &sub_items }}, 20, 20, .{});
    try r.frame();
    const m2 = r.centerOf(r.ui.menu.?.entries[0].row);
    r.ui.pointerMove(m2[0], m2[1]);
    try r.frame();
    try r.frame();
    try testing.expect(r.ui.menu.?.child != null);
    try r.click(290, 290);
    try testing.expect(!r.ui.menuOpen());
}

test "a menu taller than the window scrolls instead of overflowing" {
    const r = try Rig.init();
    defer r.deinit();
    try r.frame(); // the window size is known to the menu
    var items: [40]menu.Item = undefined;
    var labels: [40][8]u8 = undefined;
    for (&items, 0..) |*it, i| {
        const l = std.fmt.bufPrint(&labels[i], "item {d}", .{i}) catch "x";
        it.* = .{ .label = l };
    }
    try r.ui.openMenu(&items, 10, 10, .{ .on_pick = menu.PickHook.bind(r, Rig.onPick) });
    try r.frame();
    try r.frame();
    const m = r.ui.menu.?;
    const pr = r.ui.tree.absoluteRect(m.panel).?;
    try testing.expect(pr.bottom() <= 300.5 and pr.y >= 0);
    try testing.expect(m.scroll.out.overflowing);

    // The wheel scrolls it.
    r.ui.wheel(pr.x + 20, pr.y + 40, 0, -3);
    try r.frame();
    try testing.expect(r.ui.tree.get(m.scroll.node).?.scroll_y > 0);

    // Keyboard navigation to the end scrolls the focused row into view.
    r.ui.key(.end, .{}, true, false);
    try r.frame();
    try r.frame();
    const last = r.ui.tree.absoluteRect(m.entries[39].row).?;
    const view = r.ui.tree.absoluteRect(m.scroll.node).?;
    try testing.expect(last.bottom() <= view.bottom() + 0.5);
    r.ui.key(.enter, .{}, true, false);
    try r.frame();
    try testing.expectEqual(@as(?usize, 39), r.picked);
}
