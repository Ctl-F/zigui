//! MenuBar: a row of menu titles. Clicking a title opens its `Menu` below it;
//! while one is open, moving over another title switches to it.
//!
//!     const bar = try MenuBar.create(&ui, parent, .{});
//!     defer bar.destroy();
//!     try bar.addMenu("File", &.{
//!         .{ .label = "Save", .command = "file.save" },
//!         .{ .separator = true },
//!         .{ .label = "Quit", .command = "app.quit" },
//!     }, null);
//!
//! Items with a `command` run it and show its shortcut; pass an `on_pick` hook
//! to be told the index of any picked item. Like `Form` and `Wizard`, the bar
//! is a heap object you `destroy` (which also removes its nodes).

const std = @import("std");
const Handle = @import("../core/handle.zig").Handle;
const Ui = @import("../core/ui.zig").Ui;
const event = @import("../core/event.zig");
const Style = @import("../core/style.zig").Style;
const Edges = @import("../core/style.zig").Edges;
const Length = @import("../core/length.zig").Length;
const Button = @import("button.zig").Button;
const Color = @import("../core/geometry.zig").Color;
const paint_ctx = @import("../core/paint_ctx.zig");
const PaintCtx = paint_ctx.PaintCtx;
const menu = @import("menu.zig");

const Top = struct {
    button: *Button,
    arena: std.heap.ArenaAllocator,
    items: []menu.Item,
    on_pick: ?menu.PickHook,
};

pub const MenuBar = struct {
    ui: *Ui,
    node: Handle,
    tops: std.ArrayListUnmanaged(*Top) = .empty,

    pub const Options = struct {
        style: Style = .{},
        /// The strip behind the titles; transparent for none.
        background: Color = Color.rgb(0x2b, 0x2d, 0x31),
    };

    pub fn create(ui: *Ui, parent: Handle, opts: Options) !*MenuBar {
        const self = try ui.gpa.create(MenuBar);
        errdefer ui.gpa.destroy(self);
        var style = opts.style;
        style.direction = .row;
        if (style.gap == .pixels and style.gap.pixels == 0) style.gap = Length.px(2);
        if (std.meta.eql(style.padding, .{})) style.padding = Edges.xy(4, 2);
        style.align_items = .center;
        const node = try ui.tree.create(.{ .style = style, .role = .panel, .visual = .{ .background = opts.background, .radius = 4 } });
        errdefer _ = ui.tree.destroySubtree(node);
        try ui.tree.appendChild(parent, node);
        try ui.tree.setLabel(node, "Menu bar");
        self.* = .{ .ui = ui, .node = node };
        return self;
    }

    pub fn destroy(self: *MenuBar) void {
        if (self.ui.menu) |m| {
            for (self.tops.items) |t| {
                if (m.owner.eql(t.button.node)) self.ui.closeMenu();
            }
        }
        _ = self.ui.tree.destroySubtree(self.node);
        for (self.tops.items) |t| {
            t.arena.deinit();
            self.ui.gpa.destroy(t);
        }
        self.tops.deinit(self.ui.gpa);
        self.ui.gpa.destroy(self);
    }

    /// Add a menu titled `label` (the items are copied).
    pub fn addMenu(self: *MenuBar, label: []const u8, items: []const menu.Item, on_pick: ?menu.PickHook) !void {
        const gpa = self.ui.gpa;
        const top = try gpa.create(Top);
        errdefer gpa.destroy(top);
        top.arena = std.heap.ArenaAllocator.init(gpa);
        errdefer top.arena.deinit();
        const a = top.arena.allocator();
        top.items = try a.alloc(menu.Item, items.len);
        for (items, top.items) |src, *dst| {
            dst.* = src;
            dst.label = try a.dupe(u8, src.label);
            if (src.command) |c| dst.command = try a.dupe(u8, c);
        }
        top.on_pick = on_pick;
        top.button = try self.ui.add(Button, self.node, .{
            .text = label,
            .variant = .flat,
            .style = .{ .padding = Edges.xy(10, 4), .shrink = 0 },
            .painter = titlePainter,
        });
        top.button.props.on_click = event.Callback.bind(self, onClick);
        try self.ui.tree.addListener(top.button.node, .{ .kind = .pointer_enter, .callback = event.Callback.bind(self, onHover) });
        try self.tops.append(gpa, top);
    }

    /// A title looks like text on the bar: no box until it is hovered or its menu is open.
    fn titlePainter(pc: *PaintCtx, b: *const Button) paint_ctx.Error!void {
        const open = if (b.ui.menu) |m| m.owner.eql(b.node) else false;
        if (open) {
            try pc.box(.{ .background = Color.rgba(255, 255, 255, 46), .radius = 3 });
        } else if (b.out.hovered) {
            try pc.box(.{ .background = Color.rgba(255, 255, 255, 26), .radius = 3 });
        }
        pc.text_color = b.ui.theme.text_color;
    }

    fn indexOf(self: *const MenuBar, h: Handle) ?usize {
        for (self.tops.items, 0..) |t, i| {
            if (t.button.node.eql(h)) return i;
        }
        return null;
    }

    fn openTop(self: *MenuBar, i: usize) void {
        const top = self.tops.items[i];
        const rect = self.ui.tree.absoluteRect(top.button.node) orelse return;
        self.ui.openMenu(top.items, rect.x, rect.bottom(), .{
            .anchor = .{ .x = rect.x, .y = rect.y, .w = 0, .h = rect.h },
            .owner = top.button.node,
            .on_pick = top.on_pick,
        }) catch {};
    }

    fn onClick(self: *MenuBar, ev: *event.Event) void {
        const i = self.indexOf(ev.current) orelse return;
        if (self.ui.menu_suppress.eql(self.tops.items[i].button.node)) {
            self.ui.menu_suppress = Handle.invalid;
            return;
        }
        self.openTop(i);
    }

    fn onHover(self: *MenuBar, ev: *event.Event) void {
        const i = self.indexOf(ev.current) orelse return;
        const m = self.ui.menu orelse return;
        if (m.owner.eql(self.tops.items[i].button.node)) return;
        // Only switch away from another title of this bar.
        for (self.tops.items) |t| {
            if (m.owner.eql(t.button.node)) return self.openTop(i);
        }
    }
};

// ---- tests -----------------------------------------------------------------

const testing = std.testing;
const draw_list = @import("../core/draw_list.zig");

const Rig = struct {
    ui: Ui,
    cmds: [2048]draw_list.Command = undefined,
    glyphs: [1024]draw_list.Glyph = undefined,
    list: draw_list.DrawList = undefined,
    prop: @import("../text/font.zig").TestFont = .{},
    saved: u32 = 0,
    picked: ?usize = null,

    fn init() !*Rig {
        const r = try testing.allocator.create(Rig);
        r.* = .{ .ui = try Ui.init(testing.allocator) };
        _ = try r.ui.addFont(r.prop.backend());
        r.list = draw_list.DrawList.init(&r.cmds, &r.glyphs);
        r.ui.tree.get(r.ui.tree.root).?.style = .{ .direction = .column, .align_items = .start };
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

    fn onSave(self: *Rig, _: *event.Event) void {
        self.saved += 1;
    }

    fn onPick(self: *Rig, i: usize) void {
        self.picked = i;
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

test "a menu bar opens its menus, switches on hover, runs commands, and toggles on a second click" {
    const r = try Rig.init();
    defer r.deinit();
    _ = try r.ui.registerCommand("t.save", .{ .title = "Save", .run = .bind(r, Rig.onSave) });
    const bar = try MenuBar.create(&r.ui, r.ui.tree.root, .{});
    defer bar.destroy();
    try bar.addMenu("File", &.{ .{ .label = "Save", .command = "t.save" }, .{ .label = "Other" } }, menu.PickHook.bind(r, Rig.onPick));
    try bar.addMenu("Edit", &.{.{ .label = "Undo" }}, null);
    try r.frame();

    const file = r.centerOf(bar.tops.items[0].button.node);
    try r.click(file[0], file[1]);
    try testing.expect(r.ui.menuOpen());
    try testing.expectEqual(@as(usize, 2), r.ui.menu.?.entries.len);
    try r.frame();
    const below = r.ui.tree.absoluteRect(r.ui.menu.?.panel).?;
    try testing.expect(below.y >= r.ui.tree.absoluteRect(bar.tops.items[0].button.node).?.bottom());

    // Hovering the next title switches menus.
    const edit = r.centerOf(bar.tops.items[1].button.node);
    r.ui.pointerMove(edit[0], edit[1]);
    try r.frame();
    try testing.expectEqual(@as(usize, 1), r.ui.menu.?.entries.len);
    try testing.expect(r.ui.menu.?.owner.eql(bar.tops.items[1].button.node));

    // Back to File and run the command.
    r.ui.pointerMove(file[0], file[1]);
    try r.frame();
    try r.frame();
    const save = r.centerOf(r.ui.menu.?.entries[0].row);
    try r.click(save[0], save[1]);
    try testing.expect(!r.ui.menuOpen());
    try testing.expectEqual(@as(u32, 1), r.saved);
    try testing.expectEqual(@as(?usize, 0), r.picked);

    // Clicking a title while its menu is open closes it.
    try r.click(file[0], file[1]);
    try testing.expect(r.ui.menuOpen());
    try r.click(file[0], file[1]);
    try testing.expect(!r.ui.menuOpen());
}
