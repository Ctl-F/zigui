//! Menu: a popup list of items shown over everything else, for context menus,
//! the menus of a menu bar, and the drop-down of a `Select`.
//!
//! Open one with `Ui.openMenu(items, x, y, opts)`. Only one menu is open at a
//! time. It closes when an item is picked, on Escape, or when the pointer is
//! pressed outside it. Items are copied, so the slice only needs to live for the
//! call. While it is open the menu holds keyboard focus (Up/Down/Home/End move,
//! Enter or Space pick, Tab stays inside) and gives it back when it closes.
//!
//!     try ui.openMenu(&.{
//!         .{ .label = "Cut", .command = "edit.cut" },
//!         .{ .separator = true },
//!         .{ .label = "Delete", .enabled = false },
//!     }, ev.x, ev.y, .{ .on_pick = menu.PickHook.bind(&app, App.onPick) });
//!
//! An item with a `command` runs it when picked, is enabled only while the
//! command is, and shows the command's shortcut. An item with a `submenu`
//! opens a nested menu beside it. A menu taller than the window scrolls
//! (wheel, scrollbar, or the arrow keys).

const std = @import("std");
const Handle = @import("../core/handle.zig").Handle;
const geometry = @import("../core/geometry.zig");
const Color = geometry.Color;
const Rect = geometry.Rect;
const Ui = @import("../core/ui.zig").Ui;
const event = @import("../core/event.zig");
const paint_ctx = @import("../core/paint_ctx.zig");
const PaintCtx = paint_ctx.PaintCtx;
const draw_list = @import("../core/draw_list.zig");
const Length = @import("../core/length.zig").Length;
const Edges = @import("../core/style.zig").Edges;
const tree_mod = @import("../core/tree.zig");
const Label = @import("label.zig").Label;
const ScrollView = @import("scroll_view.zig").ScrollView;

pub const Item = struct {
    label: []const u8 = "",
    /// Run this command when picked; the item follows the command's enabled
    /// state and shows its shortcut.
    command: ?[]const u8 = null,
    enabled: bool = true,
    /// A divider line (the other fields are ignored).
    separator: bool = false,
    /// Draw a check mark before the label.
    checked: bool = false,
    /// Yours; not used by the menu.
    user: usize = 0,
    /// Items of a submenu that opens beside this one (hover, Right, or Enter).
    /// An item with a submenu is not picked itself.
    submenu: []const Item = &.{},
    /// For a submenu's items: called with the item's index within that submenu.
    /// Without it the root menu's `on_pick` gets that index.
    on_pick: ?PickHook = null,
};

/// Called with the index of the picked item (after the menu has closed).
pub const PickHook = struct {
    ctx: ?*anyopaque = null,
    call: *const fn (ctx: ?*anyopaque, index: usize) void,

    pub const is_callback = true;

    /// `PickHook.bind(&app, App.onPick)` where `onPick` is `fn (*App, usize) void`.
    pub fn bind(ctx: anytype, comptime f: anytype) PickHook {
        const Ptr = @TypeOf(ctx);
        return .{
            .ctx = @ptrCast(ctx),
            .call = &struct {
                fn thunk(c: ?*anyopaque, index: usize) void {
                    f(@as(Ptr, @ptrCast(@alignCast(c.?))), index);
                }
            }.thunk,
        };
    }
};

pub const Options = struct {
    on_pick: ?PickHook = null,
    /// The widget the menu drops from (window coordinates): the menu opens
    /// below it, or above if there is no room, and is at least as wide.
    anchor: ?Rect = null,
    /// The node the anchor belongs to. A press on it that closes the menu does
    /// not re-open it (`Ui.menu_suppress`), so clicking the opener again toggles.
    owner: Handle = Handle.invalid,
    min_width: f32 = 0,
    /// Item to focus first (default: the first enabled one).
    focus_index: ?usize = null,
};

const panel_bg = Color.rgb(0x2b, 0x2d, 0x31);
const panel_border = Color.rgb(0x4a, 0x4d, 0x52);
const dim = Color.rgb(0x7a, 0x7d, 0x83);

/// A copy of `items` (strings and nested submenus included) in `a`.
fn dupItems(a: std.mem.Allocator, items: []const Item) std.mem.Allocator.Error![]Item {
    const out = try a.alloc(Item, items.len);
    for (items, out) |src, *dst| {
        dst.* = src;
        dst.label = try a.dupe(u8, src.label);
        if (src.command) |c| dst.command = try a.dupe(u8, c);
        dst.submenu = try dupItems(a, src.submenu);
    }
    return out;
}

const Entry = struct {
    menu: *Menu,
    index: usize,
    label: []const u8 = "",
    command: ?[]const u8 = null,
    shortcut: []const u8 = "",
    enabled: bool = true,
    separator: bool = false,
    checked: bool = false,
    user: usize = 0,
    sub: []const Item = &.{},
    on_pick: ?PickHook = null,
    row: Handle = Handle.invalid,
    hovered: bool = false,

    fn onHover(self: *Entry, ev: *event.Event) void {
        const entering = ev.kind == .pointer_enter;
        self.hovered = entering and self.enabled;
        self.menu.ui.tree.markDirty(self.row, .{ .paint = true });
        if (entering) self.menu.rowEntered(self);
    }

    fn onClick(self: *Entry, _: *event.Event) void {
        self.menu.pick(self);
    }

    fn paintRow(self: *Entry, pc: *PaintCtx) paint_ctx.Error!void {
        const ui = self.menu.ui;
        const focused = ui.input.keyboard and ui.tree.focused.eql(self.row);
        const sub_open = if (self.menu.child_entry) |ce| ce == self else false;
        if (self.enabled and (self.hovered or focused or sub_open)) {
            try pc.box(.{ .background = Color.rgba(255, 255, 255, 28), .radius = 3 });
        }
    }

    fn paintMark(self: *Entry, pc: *PaintCtx) paint_ctx.Error!void {
        if (!self.checked) return;
        const tc = self.menu.ui.theme.text_color;
        const paint = draw_list.Paint.solid(tc);
        const r = pc.rect;
        const cx = r.x + r.w / 2;
        const cy = r.y + r.h / 2;
        try pc.list.line(.{ .x = cx - 4, .y = cy }, .{ .x = cx - 1, .y = cy + 3 }, 1.6, paint);
        try pc.list.line(.{ .x = cx - 1, .y = cy + 3 }, .{ .x = cx + 4, .y = cy - 3 }, 1.6, paint);
    }

    fn paintArrow(self: *Entry, pc: *PaintCtx) paint_ctx.Error!void {
        const tc = self.menu.ui.theme.text_color;
        const paint = draw_list.Paint.solid(if (self.enabled) tc else dim);
        const r = pc.rect;
        const cx = r.x + r.w / 2;
        const cy = r.y + r.h / 2;
        try pc.list.line(.{ .x = cx - 2, .y = cy - 4 }, .{ .x = cx + 2, .y = cy }, 1.6, paint);
        try pc.list.line(.{ .x = cx + 2, .y = cy }, .{ .x = cx - 2, .y = cy + 4 }, 1.6, paint);
    }
};

pub const Menu = struct {
    ui: *Ui,
    arena: std.heap.ArenaAllocator,
    panel: Handle = Handle.invalid,
    scroll: *ScrollView = undefined,
    entries: []Entry = &.{},
    on_pick: ?PickHook = null,
    anchor: ?Rect = null,
    owner: Handle = Handle.invalid,
    x: f32 = 0,
    y: f32 = 0,
    placed: bool = false,
    scoped: bool = false,
    closed: bool = false,
    /// The menu this one opened from (a submenu), and its entry.
    parent: ?*Menu = null,
    parent_entry: ?*Entry = null,
    /// The open submenu, and the entry it belongs to.
    child: ?*Menu = null,
    child_entry: ?*Entry = null,

    /// Open a menu at window point (`x`, `y`) (or at `opts.anchor`).
    pub fn open(ui: *Ui, items: []const Item, x: f32, y: f32, opts: Options) !void {
        ui.closeMenu();
        const pos = if (opts.anchor) |a| .{ a.x, a.bottom() + 2 } else .{ x, y };
        const self = try create(ui, items, pos[0], pos[1], opts, null, null);
        ui.menu = self;
        // The opener may draw itself differently while its menu is open.
        if (ui.tree.isValid(opts.owner)) ui.tree.markDirty(opts.owner, .{ .paint = true });
    }

    fn create(ui: *Ui, items: []const Item, x: f32, y: f32, opts: Options, parent: ?*Menu, parent_entry: ?*Entry) !*Menu {
        const gpa = ui.gpa;
        const self = try gpa.create(Menu);
        errdefer gpa.destroy(self);
        self.* = .{ .ui = ui, .arena = std.heap.ArenaAllocator.init(gpa), .on_pick = opts.on_pick, .anchor = opts.anchor, .owner = opts.owner, .x = x, .y = y, .parent = parent, .parent_entry = parent_entry };
        errdefer self.arena.deinit();
        const a = self.arena.allocator();
        const copy = try dupItems(a, items);
        self.entries = try a.alloc(Entry, copy.len);
        for (copy, self.entries, 0..) |it, *e, i| {
            e.* = .{ .menu = self, .index = i, .label = it.label, .command = it.command, .enabled = it.enabled, .separator = it.separator, .checked = it.checked, .user = it.user, .sub = it.submenu, .on_pick = it.on_pick };
            if (it.command) |c| {
                e.enabled = it.enabled and (if (ui.commands.find(c)) |h| ui.commands.isEnabled(h) else false);
                var buf: [64]u8 = undefined;
                if (ui.shortcutText(c, &buf)) |t| e.shortcut = try a.dupe(u8, t);
            }
            if (it.submenu.len > 0) e.shortcut = "";
        }

        const tree = &ui.tree;
        const win = tree.get(tree.root).?.rect;
        const max_h: f32 = if (win.h > 40) win.h - 12 else 100000;
        self.panel = try tree.create(.{
            .style = .{
                .position = .absolute,
                .direction = .column,
                .padding = Edges.all(4),
                .shrink = 0,
                .min_width = Length.px(opts.min_width),
                .inset = .{ .left = Length.px(self.x), .top = Length.px(self.y) },
            },
            .visual = .{ .background = panel_bg, .border_color = panel_border, .border_width = 1, .radius = 6 },
            .role = .panel,
        });
        errdefer _ = tree.destroySubtree(self.panel);
        try tree.appendChild(tree.root, self.panel);
        try tree.setLabel(self.panel, "Menu");
        try tree.addListener(self.panel, .{ .kind = .key_down, .callback = event.Callback.bind(self, onKey) });
        // The rows live in a scroll view that is only as tall as they are, up to the window.
        self.scroll = try ui.add(ScrollView, self.panel, .{
            .style = .{ .max_height = Length.px(max_h), .shrink = 1 },
            .content_style = .{ .direction = .column },
        });
        try tree.setLabel(self.scroll.node, "Menu items");

        var any_checked = false;
        for (self.entries) |e| any_checked = any_checked or e.checked;
        for (self.entries) |*e| try self.buildRow(e, any_checked);

        self.scoped = ui.pushFocusScope(self.panel, false);
        if (opts.focus_index) |i| {
            if (i < self.entries.len and self.entries[i].enabled and !self.entries[i].separator) self.focusEntry(&self.entries[i]);
        }
        return self;
    }

    fn buildRow(self: *Menu, e: *Entry, any_checked: bool) !void {
        const ui = self.ui;
        const tree = &ui.tree;
        const host = self.scroll.contentNode();
        if (e.separator) {
            const sep = try tree.create(.{
                .style = .{ .height = Length.px(1), .margin = .{ .top = Length.px(4), .bottom = Length.px(4) }, .shrink = 0 },
                .visual = .{ .background = panel_border },
            });
            try tree.appendChild(host, sep);
            return;
        }
        const row = try tree.create(.{ .style = .{
            .direction = .row,
            .align_items = .center,
            .gap = Length.px(8),
            .padding = Edges.xy(8, 5),
            .shrink = 0,
        } });
        try tree.appendChild(host, row);
        e.row = row;
        tree.get(row).?.paint_hook = tree_mod.PaintHook.bind(e, Entry.paintRow);
        if (any_checked) {
            const mark = try tree.create(.{ .style = .{ .width = Length.px(14), .height = Length.px(14), .shrink = 0 } });
            try tree.appendChild(row, mark);
            tree.get(mark).?.paint_hook = tree_mod.PaintHook.bind(e, Entry.paintMark);
        }
        _ = try ui.add(Label, row, .{ .text = e.label, .style = .{ .grow = 1 }, .color = if (e.enabled) Color.transparent else dim });
        if (e.sub.len > 0) {
            const arrow = try tree.create(.{ .style = .{ .width = Length.px(14), .height = Length.px(14), .shrink = 0 } });
            try tree.appendChild(row, arrow);
            tree.get(arrow).?.paint_hook = tree_mod.PaintHook.bind(e, Entry.paintArrow);
        } else if (e.shortcut.len > 0) {
            _ = try ui.add(Label, row, .{ .text = e.shortcut, .color = dim });
        }
        if (e.enabled) {
            try ui.makeClickable(row, .{ .label = e.label, .role = .button, .on_click = event.Callback.bind(e, Entry.onClick) });
        }
        try tree.addListener(row, .{ .kind = .pointer_enter, .callback = event.Callback.bind(e, Entry.onHover) });
        try tree.addListener(row, .{ .kind = .pointer_leave, .callback = event.Callback.bind(e, Entry.onHover) });
    }

    /// Free a menu that has been closed (called by `Ui`).
    pub fn destroyClosed(self: *Menu) void {
        const gpa = self.ui.gpa;
        self.arena.deinit();
        gpa.destroy(self);
    }

    fn root(self: *Menu) *Menu {
        var m = self;
        while (m.parent) |p| m = p;
        return m;
    }

    /// Close this menu and any submenus. The memory is released at the next
    /// `Ui.update`, so a callback running inside the menu can still look at it.
    pub fn close(self: *Menu) void {
        if (self.closed) return;
        self.closed = true;
        const ui = self.ui;
        self.closeChild();
        if (self.parent) |p| {
            p.child = null;
            p.child_entry = null;
            ui.tree.markDirty(p.panel, .{ .paint = true });
        } else if (ui.menu == self) {
            ui.menu = null;
            if (ui.tree.isValid(self.owner)) ui.tree.markDirty(self.owner, .{ .paint = true });
        }
        if (self.scoped) ui.popFocusScope();
        self.scoped = false;
        _ = ui.tree.destroySubtree(self.panel);
        ui.menu_closed.append(ui.gpa, self) catch {};
    }

    fn closeChild(self: *Menu) void {
        if (self.child) |c| c.close();
    }

    /// Open the submenu of `e` beside its row.
    fn openSub(self: *Menu, e: *Entry) void {
        if (self.child_entry == e and self.child != null) return;
        self.closeChild();
        const ui = self.ui;
        const prow = ui.tree.absoluteRect(self.panel) orelse return;
        const rrow = ui.tree.absoluteRect(e.row) orelse return;
        const hook = e.on_pick orelse self.root().on_pick;
        const child = create(ui, e.sub, prow.right() - 2, rrow.y - 5, .{ .on_pick = hook, .owner = self.owner }, self, e) catch return;
        self.child = child;
        self.child_entry = e;
        ui.tree.markDirty(self.panel, .{ .paint = true });
        ui.tree.markDirty(e.row, .{ .paint = true });
    }

    /// The pointer entered a row: open its submenu, or close the open one.
    fn rowEntered(self: *Menu, e: *Entry) void {
        if (e.sub.len > 0 and e.enabled) {
            self.openSub(e);
        } else if (self.child != null) {
            self.closeChild();
        }
    }

    fn focusEntry(self: *Menu, e: *Entry) void {
        self.ui.setFocus(e.row);
        self.scroll.scrollIntoView(e.row);
    }

    fn pick(self: *Menu, e: *Entry) void {
        if (e.sub.len > 0) {
            self.openSub(e);
            return;
        }
        const hook = e.on_pick orelse self.root().on_pick;
        const index = e.index;
        const command = e.command;
        self.root().close();
        if (command) |c| _ = self.ui.invokeCommand(c);
        if (hook) |h| h.call(h.ctx, index);
    }

    /// True if the window point is over this menu or an open submenu.
    pub fn contains(self: *const Menu, x: f32, y: f32) bool {
        if (self.child) |c| {
            if (c.contains(x, y)) return true;
        }
        const r = self.ui.tree.absoluteRect(self.panel) orelse return false;
        return x >= r.x and x < r.right() and y >= r.y and y < r.bottom();
    }

    /// The pointer was pressed outside: close, remembering when that press was
    /// on the opener so the click that follows does not reopen the menu.
    pub fn dismissByPress(self: *Menu, x: f32, y: f32) void {
        const ui = self.ui;
        if (ui.tree.absoluteRect(self.owner)) |r| {
            if (x >= r.x and x < r.right() and y >= r.y and y < r.bottom()) ui.menu_suppress = self.owner;
        }
        self.close();
    }

    /// Keep the menu inside the window once its size is known.
    pub fn update(self: *Menu) void {
        if (self.child) |c| c.update();
        if (self.placed) return;
        const tree = &self.ui.tree;
        const r = tree.get(self.panel).?.rect;
        if (r.w <= 0) return;
        self.placed = true;
        const win = tree.get(tree.root).?.rect;
        var x = self.x;
        var y = self.y;
        if (self.anchor) |a| {
            if (y + r.h > win.h and a.y - r.h - 2 >= 0) y = a.y - r.h - 2;
        }
        if (self.parent) |p| {
            // A submenu goes to the left of its parent when there is no room on the right.
            if (x + r.w > win.w) {
                if (tree.absoluteRect(p.panel)) |pr| x = pr.x - r.w + 2;
            }
        }
        x = @max(@min(x, win.w - r.w), 0);
        y = @max(@min(y, win.h - r.h), 0);
        if (x != self.x or y != self.y) {
            const n = tree.get(self.panel).?;
            n.style.inset = .{ .left = Length.px(x), .top = Length.px(y) };
            tree.markDirty(self.panel, .{ .layout = true, .paint = true });
        }
    }

    fn focusedEntry(self: *Menu) ?*Entry {
        for (self.entries) |*e| {
            if (!e.separator and e.enabled and self.ui.tree.focused.eql(e.row)) return e;
        }
        return null;
    }

    fn onKey(self: *Menu, ev: *event.Event) void {
        if (ev.mods.any(.{ .ctrl = true, .alt = true, .gui = true })) return;
        const ui = self.ui;
        switch (ev.key) {
            .escape => {
                ev.markHandled();
                // Escape closes the innermost menu.
                self.close();
            },
            .left => if (self.parent != null) {
                ev.markHandled();
                self.close();
            },
            .right => {
                if (self.focusedEntry()) |e| {
                    if (e.sub.len > 0) {
                        ev.markHandled();
                        self.openSub(e);
                        if (self.child) |c| {
                            ui.input.keyboard = true;
                            if (c.firstEnabled()) |first| c.focusEntry(first);
                        }
                    }
                }
            },
            .down, .up, .home, .end => {
                ev.markHandled();
                const cur: ?usize = if (self.focusedEntry()) |e| e.index else null;
                const n = self.entries.len;
                if (n == 0) return;
                var i: usize = switch (ev.key) {
                    .home => n - 1,
                    .end => 0,
                    .down => cur orelse n - 1,
                    else => cur orelse 0,
                };
                const forward = ev.key == .down or ev.key == .home;
                for (0..n) |_| {
                    i = if (forward) (i + 1) % n else (i + n - 1) % n;
                    const e = &self.entries[i];
                    if (!e.separator and e.enabled) {
                        self.focusEntry(e);
                        ui.input.keyboard = true;
                        ui.tree.markDirty(self.panel, .{ .paint = true });
                        return;
                    }
                }
            },
            else => {},
        }
    }

    fn firstEnabled(self: *Menu) ?*Entry {
        for (self.entries) |*e| {
            if (!e.separator and e.enabled) return e;
        }
        return null;
    }
};
