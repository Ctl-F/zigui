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
//! command is, and shows the command's shortcut.

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

const Entry = struct {
    menu: *Menu,
    index: usize,
    label: []u8 = &.{},
    command: ?[]u8 = null,
    shortcut: []u8 = &.{},
    enabled: bool = true,
    separator: bool = false,
    checked: bool = false,
    user: usize = 0,
    row: Handle = Handle.invalid,
    hovered: bool = false,

    fn onHover(self: *Entry, ev: *event.Event) void {
        self.hovered = ev.kind == .pointer_enter;
        self.menu.ui.tree.markDirty(self.row, .{ .paint = true });
    }

    fn onClick(self: *Entry, _: *event.Event) void {
        self.menu.pick(self);
    }

    fn paintRow(self: *Entry, pc: *PaintCtx) paint_ctx.Error!void {
        const ui = self.menu.ui;
        const focused = ui.input.keyboard and ui.tree.focused.eql(self.row);
        if (self.enabled and (self.hovered or focused)) {
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
};

pub const Menu = struct {
    ui: *Ui,
    panel: Handle = Handle.invalid,
    entries: []Entry = &.{},
    on_pick: ?PickHook = null,
    anchor: ?Rect = null,
    owner: Handle = Handle.invalid,
    x: f32 = 0,
    y: f32 = 0,
    placed: bool = false,
    scoped: bool = false,

    /// Open a menu at window point (`x`, `y`) (or at `opts.anchor`).
    pub fn open(ui: *Ui, items: []const Item, x: f32, y: f32, opts: Options) !void {
        ui.closeMenu();
        const gpa = ui.gpa;
        const self = try gpa.create(Menu);
        errdefer gpa.destroy(self);
        self.* = .{ .ui = ui, .on_pick = opts.on_pick, .anchor = opts.anchor, .owner = opts.owner };
        errdefer self.freeStrings();
        self.entries = try gpa.alloc(Entry, items.len);
        for (self.entries) |*e| e.* = .{ .menu = self, .index = 0 };
        for (items, self.entries, 0..) |it, *e, i| {
            e.index = i;
            e.enabled = it.enabled;
            e.separator = it.separator;
            e.checked = it.checked;
            e.user = it.user;
            e.label = try gpa.dupe(u8, it.label);
            if (it.command) |c| {
                e.command = try gpa.dupe(u8, c);
                e.enabled = it.enabled and (if (ui.commands.find(c)) |h| ui.commands.isEnabled(h) else false);
                var buf: [64]u8 = undefined;
                if (ui.shortcutText(c, &buf)) |t| e.shortcut = try gpa.dupe(u8, t);
            }
        }

        const pos = if (opts.anchor) |a| .{ a.x, a.bottom() + 2 } else .{ x, y };
        self.x = pos[0];
        self.y = pos[1];
        const tree = &ui.tree;
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

        var any_checked = false;
        for (self.entries) |e| any_checked = any_checked or e.checked;
        for (self.entries) |*e| try self.buildRow(e, any_checked);

        self.scoped = ui.pushFocusScope(self.panel, false);
        if (opts.focus_index) |i| {
            if (i < self.entries.len and self.entries[i].enabled and !self.entries[i].separator) ui.setFocus(self.entries[i].row);
        }
        ui.menu = self;
    }

    fn buildRow(self: *Menu, e: *Entry, any_checked: bool) !void {
        const ui = self.ui;
        const tree = &ui.tree;
        if (e.separator) {
            const sep = try tree.create(.{
                .style = .{ .height = Length.px(1), .margin = .{ .top = Length.px(4), .bottom = Length.px(4) }, .shrink = 0 },
                .visual = .{ .background = panel_border },
            });
            try tree.appendChild(self.panel, sep);
            return;
        }
        const row = try tree.create(.{ .style = .{
            .direction = .row,
            .align_items = .center,
            .gap = Length.px(8),
            .padding = Edges.xy(8, 5),
            .shrink = 0,
        } });
        try tree.appendChild(self.panel, row);
        e.row = row;
        tree.get(row).?.paint_hook = tree_mod.PaintHook.bind(e, Entry.paintRow);
        if (any_checked) {
            const mark = try tree.create(.{ .style = .{ .width = Length.px(14), .height = Length.px(14), .shrink = 0 } });
            try tree.appendChild(row, mark);
            tree.get(mark).?.paint_hook = tree_mod.PaintHook.bind(e, Entry.paintMark);
        }
        _ = try ui.add(Label, row, .{ .text = e.label, .style = .{ .grow = 1 }, .color = if (e.enabled) Color.transparent else dim });
        if (e.shortcut.len > 0) _ = try ui.add(Label, row, .{ .text = e.shortcut, .color = dim });
        if (e.enabled) {
            try ui.makeClickable(row, .{ .label = e.label, .role = .button, .on_click = event.Callback.bind(e, Entry.onClick) });
            try tree.addListener(row, .{ .kind = .pointer_enter, .callback = event.Callback.bind(e, Entry.onHover) });
            try tree.addListener(row, .{ .kind = .pointer_leave, .callback = event.Callback.bind(e, Entry.onHover) });
        }
    }

    fn freeStrings(self: *Menu) void {
        const gpa = self.ui.gpa;
        for (self.entries) |*e| {
            gpa.free(e.label);
            if (e.command) |c| gpa.free(c);
            gpa.free(e.shortcut);
        }
        gpa.free(self.entries);
        self.entries = &.{};
    }

    /// Free a menu that has been closed (called by `Ui`).
    pub fn destroyClosed(self: *Menu) void {
        self.freeStrings();
        self.ui.gpa.destroy(self);
    }

    /// Close without picking. The memory is released at the next `Ui.update`,
    /// so a callback running inside the menu can still look at it.
    pub fn close(self: *Menu) void {
        const ui = self.ui;
        if (ui.menu != self) return;
        ui.menu = null;
        if (self.scoped) ui.popFocusScope();
        self.scoped = false;
        _ = ui.tree.destroySubtree(self.panel);
        ui.menu_closed.append(ui.gpa, self) catch {};
    }

    fn pick(self: *Menu, e: *Entry) void {
        const hook = self.on_pick;
        const index = e.index;
        const command = e.command;
        self.close();
        if (command) |c| _ = self.ui.invokeCommand(c);
        if (hook) |h| h.call(h.ctx, index);
    }

    /// True if the window point is over the menu.
    pub fn contains(self: *const Menu, x: f32, y: f32) bool {
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
        if (self.placed) return;
        const tree = &self.ui.tree;
        const r = tree.get(self.panel).?.rect;
        if (r.w <= 0) return;
        self.placed = true;
        const root = tree.get(tree.root).?.rect;
        var x = self.x;
        var y = self.y;
        if (self.anchor) |a| {
            if (y + r.h > root.h and a.y - r.h - 2 >= 0) y = a.y - r.h - 2;
        }
        x = @max(@min(x, root.w - r.w), 0);
        y = @max(@min(y, root.h - r.h), 0);
        if (x != self.x or y != self.y) {
            const n = tree.get(self.panel).?;
            n.style.inset = .{ .left = Length.px(x), .top = Length.px(y) };
            tree.markDirty(self.panel, .{ .layout = true, .paint = true });
        }
    }

    fn onKey(self: *Menu, ev: *event.Event) void {
        if (ev.mods.any(.{ .ctrl = true, .alt = true, .gui = true })) return;
        const ui = self.ui;
        switch (ev.key) {
            .escape => {
                ev.markHandled();
                self.close();
            },
            .down, .up, .home, .end => {
                ev.markHandled();
                var cur: ?usize = null;
                for (self.entries, 0..) |e, i| {
                    if (!e.separator and e.enabled and ui.tree.focused.eql(e.row)) cur = i;
                }
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
                    const e = self.entries[i];
                    if (!e.separator and e.enabled) {
                        ui.setFocus(e.row);
                        ui.input.keyboard = true;
                        ui.tree.markDirty(self.panel, .{ .paint = true });
                        return;
                    }
                }
            },
            else => {},
        }
    }
};
