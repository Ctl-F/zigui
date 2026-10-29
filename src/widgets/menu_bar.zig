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
const shadow = @import("../core/shadow.zig");
const tree_mod = @import("../core/tree.zig");
const Text = @import("common.zig").Text;
const PaintCtx = paint_ctx.PaintCtx;
const menu = @import("menu.zig");

const Top = struct {
    button: *Button,
    arena: std.heap.ArenaAllocator,
    items: []menu.Item,
    on_pick: ?menu.PickHook,
    /// Read from `props.menus` (and replaced when it changes), as opposed to `addMenu`.
    from_text: bool = false,
    /// The title, for re-creating its button.
    title: []const u8 = "",
};

pub const MenuBar = struct {
    props: Props = .{},
    out: Out = .{},
    node: Handle,
    ui: *Ui,
    checker: shadow.Checker(Props),
    tops: std.ArrayListUnmanaged(*Top) = .empty,
    /// The `props.menus` text the text-defined menus were last read from.
    seen_menus: []const u8 = "",

    pub const Props = struct {
        /// Menus as text, for documents and the builder. A line with no
        /// indentation titles a menu; indented lines are its items: `Label`,
        /// `Label = command.name` (picking runs the command), or `-` for a
        /// separator. A line indented one level further is an item of the
        /// previous item's submenu.
        ///
        ///     File
        ///       Open = file.open
        ///       -
        ///       Quit = app.quit
        ///     Edit
        ///       Undo = edit.undo
        menus: Text = .{},

        pub const dirty_map = .{
            .menus = shadow.Category.layout,
        };
    };

    pub const Out = struct {
        menu_count: u32 = 0,
    };

    pub const Options = struct {
        style: Style = .{},
        /// The strip behind the titles; transparent for none.
        background: Color = Color.rgb(0x2b, 0x2d, 0x31),
        /// Menus as text (see `Props.menus`); copied.
        menus: []const u8 = "",
    };

    pub const listened_kinds = [_]event.EventKind{};

    pub fn nodeTemplate(style: Style) tree_mod.Node {
        var s = style;
        s.direction = .row;
        if (s.gap == .pixels and s.gap.pixels == 0) s.gap = Length.px(2);
        if (std.meta.eql(s.padding, .{})) s.padding = Edges.xy(4, 2);
        s.align_items = .center;
        return .{ .style = s, .role = .panel, .visual = .{ .radius = 4 } };
    }

    pub fn init(ui: *Ui, node: Handle) MenuBar {
        const props: Props = .{};
        return .{ .node = node, .ui = ui, .checker = shadow.Checker(Props).init(&props) };
    }

    pub fn apply(self: *MenuBar, o: Options) !void {
        self.ui.tree.get(self.node).?.visual.background = o.background;
        try self.ui.tree.setLabel(self.node, "Menu bar");
        if (o.menus.len > 0) try self.ui.replaceText(&self.props.menus, o.menus);
        self.checker.sync(&self.props);
    }

    pub fn deinit(self: *MenuBar) void {
        for (self.tops.items) |t| {
            t.arena.deinit();
            self.ui.gpa.destroy(t);
        }
        self.tops.deinit(self.ui.gpa);
        self.ui.freeText(&self.props.menus);
    }

    /// Make a bar under `parent` (shorthand for `ui.add(MenuBar, parent, opts)`).
    pub fn create(ui: *Ui, parent: Handle, opts: Options) !*MenuBar {
        return ui.add(MenuBar, parent, opts);
    }

    /// Remove the bar's nodes (its memory is released at the next `Ui.update`).
    pub fn destroy(self: *MenuBar) void {
        if (self.ui.menu) |m| {
            for (self.tops.items) |t| {
                if (self.ui.tree.isValid(t.button.node) and m.owner.eql(t.button.node)) self.ui.closeMenu();
            }
        }
        _ = self.ui.tree.destroySubtree(self.node);
    }

    pub fn handleEvent(self: *MenuBar, ev: *event.Event) void {
        _ = self;
        _ = ev;
    }

    pub fn paintHook(self: *MenuBar, pc: *PaintCtx) paint_ctx.Error!void {
        _ = self;
        _ = pc;
    }

    pub fn prepare(self: *MenuBar) void {
        _ = self;
    }

    pub fn update(self: *MenuBar) void {
        self.ui.verifyProps(self.node, &self.checker, &self.props, "menu_bar");
    }

    pub fn endFrame(self: *MenuBar) void {
        _ = self;
    }

    /// Add a menu titled `label` (the items are copied).
    pub fn addMenu(self: *MenuBar, label: []const u8, items: []const menu.Item, on_pick: ?menu.PickHook) !void {
        const top = try self.newTop(label, items, on_pick, false);
        errdefer self.freeTop(top);
        try self.attach(top, label);
        try self.tops.append(self.ui.gpa, top);
        self.out.menu_count = @intCast(self.tops.items.len);
    }

    fn newTop(self: *MenuBar, label: []const u8, items: []const menu.Item, on_pick: ?menu.PickHook, from_text: bool) !*Top {
        const gpa = self.ui.gpa;
        const top = try gpa.create(Top);
        errdefer gpa.destroy(top);
        top.* = .{ .button = undefined, .arena = std.heap.ArenaAllocator.init(gpa), .items = &.{}, .on_pick = on_pick, .from_text = from_text };
        errdefer top.arena.deinit();
        top.items = try dupItems(top.arena.allocator(), items);
        top.title = try top.arena.allocator().dupe(u8, label);
        return top;
    }

    fn freeTop(self: *MenuBar, top: *Top) void {
        top.arena.deinit();
        self.ui.gpa.destroy(top);
    }

    fn attach(self: *MenuBar, top: *Top, label: []const u8) !void {
        top.button = try self.ui.add(Button, self.node, .{
            .text = label,
            .variant = .flat,
            .style = .{ .padding = Edges.xy(10, 4), .shrink = 0 },
            .painter = titlePainter,
        });
        top.button.props.on_click = event.Callback.bind(self, onClick);
        try self.ui.tree.addListener(top.button.node, .{ .kind = .pointer_enter, .callback = event.Callback.bind(self, onHover) });
    }

    fn dupItems(a: std.mem.Allocator, items: []const menu.Item) std.mem.Allocator.Error![]menu.Item {
        const out = try a.alloc(menu.Item, items.len);
        for (items, out) |src, *dst| {
            dst.* = src;
            dst.label = try a.dupe(u8, src.label);
            if (src.command) |c| dst.command = try a.dupe(u8, c);
            dst.submenu = try dupItems(a, src.submenu);
        }
        return out;
    }

    /// Re-read `props.menus` when it changed. `Ui.update` calls this before
    /// reclaiming destroyed widgets (the title buttons come and go).
    pub fn rebuildIfDirty(self: *MenuBar) void {
        if (!self.ui.tree.isValid(self.node)) return;
        const t = self.props.menus.bytes;
        if (t.ptr == self.seen_menus.ptr and t.len == self.seen_menus.len) return;
        self.seen_menus = t;
        self.ui.closeMenu();
        // Drop every title button; code-defined menus get new ones below.
        var i: usize = self.tops.items.len;
        while (i > 0) {
            i -= 1;
            const top = self.tops.items[i];
            _ = self.ui.tree.destroySubtree(top.button.node);
            if (top.from_text) {
                self.freeTop(top);
                _ = self.tops.orderedRemove(i);
            }
        }
        // Text menus first, then the ones added from code.
        const code = self.tops.toOwnedSlice(self.ui.gpa) catch return;
        defer self.ui.gpa.free(code);
        self.parseMenus(t);
        for (code) |top| {
            self.tops.append(self.ui.gpa, top) catch {};
        }
        for (self.tops.items) |top| self.attach(top, top.title) catch {};
        self.out.menu_count = @intCast(self.tops.items.len);
    }

    /// Build text-defined menus from `text` (see `Props.menus`).
    fn parseMenus(self: *MenuBar, text: []const u8) void {
        var scratch = std.heap.ArenaAllocator.init(self.ui.gpa);
        defer scratch.deinit();
        const a = scratch.allocator();
        const Entry = struct { item: menu.Item, subs: std.ArrayListUnmanaged(menu.Item) = .empty };
        var title: []const u8 = "";
        var entries: std.ArrayListUnmanaged(Entry) = .empty;
        var it = std.mem.splitScalar(u8, text, '\n');
        var pending = false;
        while (true) {
            const maybe = it.next();
            const raw = maybe orelse "";
            const trimmed = std.mem.trim(u8, raw, " \t\r");
            const indent = raw.len - std.mem.trimStart(u8, raw, " \t").len;
            const is_title = maybe != null and trimmed.len > 0 and indent == 0;
            if ((maybe == null or is_title) and pending) {
                // Close the menu being collected.
                const items = a.alloc(menu.Item, entries.items.len) catch return;
                for (entries.items, items) |e, *dst| {
                    dst.* = e.item;
                    dst.submenu = e.subs.items;
                }
                if (self.newTop(title, items, null, true)) |top| {
                    self.tops.append(self.ui.gpa, top) catch self.freeTop(top);
                } else |_| {}
                entries = .empty;
                pending = false;
            }
            if (maybe == null) break;
            if (trimmed.len == 0) continue;
            if (is_title) {
                title = trimmed;
                pending = true;
                continue;
            }
            if (!pending) continue;
            const item = parseItem(trimmed);
            if (indent >= 4 and entries.items.len > 0) {
                entries.items[entries.items.len - 1].subs.append(a, item) catch return;
            } else {
                entries.append(a, .{ .item = item }) catch return;
            }
        }
    }

    fn parseItem(line: []const u8) menu.Item {
        if (std.mem.eql(u8, line, "-")) return .{ .separator = true };
        if (std.mem.indexOfScalar(u8, line, '=')) |eq| {
            return .{
                .label = std.mem.trim(u8, line[0..eq], " \t"),
                .command = std.mem.trim(u8, line[eq + 1 ..], " \t"),
            };
        }
        return .{ .label = line };
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

test "menus text defines titles, items, commands, separators and submenus; code-added menus survive a change" {
    const r = try Rig.init();
    defer r.deinit();
    _ = try r.ui.registerCommand("t.save", .{ .title = "Save", .run = .bind(r, Rig.onSave) });
    const bar = try MenuBar.create(&r.ui, r.ui.tree.root, .{
        .menus = "File\n  Save = t.save\n  -\n  Recent\n    one\n    two\nEdit\n  Undo\n",
    });
    try bar.addMenu("Extra", &.{.{ .label = "x" }}, null);
    try r.frame();
    try r.frame();
    try testing.expectEqual(@as(usize, 3), bar.tops.items.len);
    try testing.expectEqualStrings("File", bar.tops.items[0].title);
    const file = bar.tops.items[0].items;
    try testing.expectEqual(@as(usize, 3), file.len);
    try testing.expectEqualStrings("t.save", file[0].command.?);
    try testing.expect(file[1].separator);
    try testing.expectEqual(@as(usize, 2), file[2].submenu.len);
    try testing.expectEqualStrings("Extra", bar.tops.items[2].title);

    // Running the command through the menu.
    const at = r.centerOf(bar.tops.items[0].button.node);
    try r.click(at[0], at[1]);
    try testing.expect(r.ui.menuOpen());
    try r.frame();
    const save = r.centerOf(r.ui.menu.?.entries[0].row);
    try r.click(save[0], save[1]);
    try testing.expectEqual(@as(u32, 1), r.saved);

    // New text replaces the text menus and keeps "Extra".
    try r.ui.replaceText(&bar.props.menus, "Only\n  one\n");
    try r.frame();
    try r.frame();
    try testing.expectEqual(@as(usize, 2), bar.tops.items.len);
    try testing.expectEqualStrings("Only", bar.tops.items[0].title);
    try testing.expectEqualStrings("Extra", bar.tops.items[1].title);
    const again = r.centerOf(bar.tops.items[1].button.node);
    try r.click(again[0], again[1]);
    try testing.expect(r.ui.menuOpen());
    r.ui.closeMenu();
}
