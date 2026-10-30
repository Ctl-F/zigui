//! Popup: a small overlay that does not take keyboard focus, for completion
//! lists and tooltips. The widget that opens it keeps typing; it moves the
//! selection and picks with `Ui.popupMove` and `Ui.popupPick` (a completion
//! list) and closes it with `Ui.hidePopup`.
//!
//!     try ui.showPopup(&.{
//!         .{ .tag = "fn", .label = "print", .detail = "(fmt, args) void" },
//!         .{ .tag = "fn", .label = "printErr" },
//!     }, .{ .anchor = caret_rect, .on_pick = menu.PickHook.bind(&app, App.onPick) });
//!     ui.popupMove(1);                 // Down arrow
//!     _ = ui.popupPick();              // Enter or Tab: runs on_pick(index) and closes
//!
//!     try ui.showTip("Returns the length.\nO(1)", anchor_rect);   // a tooltip
//!
//! Only one popup is open at a time; opening another replaces it. A list
//! closes when the pointer is pressed outside it (the press still reaches
//! whatever is under it). Clicking a row picks it without moving focus. A
//! tooltip ignores the pointer completely. Rows are copied, so the slice only
//! needs to live for the call. The popup opens below `anchor` (window
//! coordinates), or above when there is no room, and stays inside the window.

const std = @import("std");
const Handle = @import("../core/handle.zig").Handle;
const geometry = @import("../core/geometry.zig");
const Color = geometry.Color;
const Rect = geometry.Rect;
const Ui = @import("../core/ui.zig").Ui;
const event = @import("../core/event.zig");
const paint_ctx = @import("../core/paint_ctx.zig");
const PaintCtx = paint_ctx.PaintCtx;
const Length = @import("../core/length.zig").Length;
const Edges = @import("../core/style.zig").Edges;
const tree_mod = @import("../core/tree.zig");
const Label = @import("label.zig").Label;
const ScrollView = @import("scroll_view.zig").ScrollView;
const PickHook = @import("menu.zig").PickHook;

pub const Row = struct {
    label: []const u8,
    /// Dimmed text after the label (a signature, a type).
    detail: []const u8 = "",
    /// A short dimmed tag before the label (`fn`, `var`, `type`).
    tag: []const u8 = "",
    /// Yours; read back with `Popup.userOf`.
    user: usize = 0,
};

pub const Kind = enum { list, tip };

pub const Options = struct {
    /// The rectangle (window coordinates) to open beside: the caret, a word.
    anchor: Rect = .{},
    kind: Kind = .list,
    /// Called with the picked row's index, after the popup has closed.
    on_pick: ?PickHook = null,
    /// Rows shown before the list scrolls.
    max_rows: u32 = 10,
    min_width: f32 = 0,
    /// Row selected first.
    selected: usize = 0,
};

const panel_bg = Color.rgb(0x2b, 0x2d, 0x31);
const panel_border = Color.rgb(0x4a, 0x4d, 0x52);
const dim = Color.rgb(0x7a, 0x7d, 0x83);

const Entry = struct {
    popup: *Popup,
    index: usize,
    row: Row,
    node: Handle = Handle.invalid,

    fn paintRow(self: *Entry, pc: *PaintCtx) paint_ctx.Error!void {
        if (self.popup.selected == self.index and self.popup.kind == .list) {
            try pc.box(.{ .background = Color.rgba(80, 140, 255, 70), .radius = 3 });
        }
    }

    fn onDown(self: *Entry, ev: *event.Event) void {
        if (ev.button != 1) return;
        // Keep focus where it is (the editor being typed in).
        ev.markHandled();
        self.popup.selectIndex(self.index);
        self.popup.pickSelected();
    }
};

pub const Popup = struct {
    ui: *Ui,
    arena: std.heap.ArenaAllocator,
    panel: Handle = Handle.invalid,
    scroll: ?*ScrollView = null,
    entries: []Entry = &.{},
    kind: Kind,
    on_pick: ?PickHook,
    anchor: Rect,
    selected: usize = 0,
    x: f32 = 0,
    y: f32 = 0,
    placed: bool = false,
    closed: bool = false,

    pub fn open(ui: *Ui, rows: []const Row, opts: Options) !void {
        ui.hidePopup();
        const self = try ui.gpa.create(Popup);
        errdefer ui.gpa.destroy(self);
        self.* = .{
            .ui = ui,
            .arena = std.heap.ArenaAllocator.init(ui.gpa),
            .kind = opts.kind,
            .on_pick = opts.on_pick,
            .anchor = opts.anchor,
            .x = opts.anchor.x,
            .y = opts.anchor.bottom() + 2,
            .selected = if (rows.len > 0) @min(opts.selected, rows.len - 1) else 0,
        };
        errdefer self.arena.deinit();
        const a = self.arena.allocator();
        self.entries = try a.alloc(Entry, rows.len);
        for (rows, self.entries, 0..) |r, *e, i| {
            e.* = .{ .popup = self, .index = i, .row = .{
                .label = try a.dupe(u8, r.label),
                .detail = try a.dupe(u8, r.detail),
                .tag = try a.dupe(u8, r.tag),
                .user = r.user,
            } };
        }
        try self.build(opts);
        ui.popup = self;
    }

    fn build(self: *Popup, opts: Options) !void {
        const ui = self.ui;
        const tree = &ui.tree;
        self.panel = try tree.create(.{
            .style = .{
                .position = .absolute,
                .direction = .column,
                .padding = Edges.all(if (self.kind == .tip) 6 else 3),
                .shrink = 0,
                .min_width = Length.px(opts.min_width),
                .max_width = Length.px(if (self.kind == .tip) 480 else 640),
                .inset = .{ .left = Length.px(self.x), .top = Length.px(self.y) },
            },
            .visual = .{ .background = panel_bg, .border_color = panel_border, .border_width = 1, .radius = 5 },
            .role = .panel,
        });
        errdefer _ = tree.destroySubtree(self.panel);
        try tree.appendChild(tree.root, self.panel);
        try tree.setLabel(self.panel, if (self.kind == .tip) "Tooltip" else "Suggestions");

        if (self.kind == .tip) {
            for (self.entries) |*e| _ = try ui.add(Label, self.panel, .{ .text = e.row.label });
            return;
        }
        const row_h = ui.theme.font_size + 10;
        const rows_shown: f32 = @floatFromInt(@max(1, @min(self.entries.len, opts.max_rows)));
        const sv = try ui.add(ScrollView, self.panel, .{
            .style = .{ .max_height = Length.px(rows_shown * row_h + 2), .shrink = 1 },
            .content_style = .{ .direction = .column },
        });
        self.scroll = sv;
        try tree.setLabel(sv.node, "Suggestion list");
        for (self.entries) |*e| {
            const row = try tree.create(.{ .style = .{
                .direction = .row,
                .align_items = .center,
                .gap = Length.px(8),
                .padding = Edges.xy(6, 2),
                .shrink = 0,
            } });
            try tree.appendChild(sv.contentNode(), row);
            e.node = row;
            tree.get(row).?.paint_hook = tree_mod.PaintHook.bind(e, Entry.paintRow);
            if (e.row.tag.len > 0) _ = try ui.add(Label, row, .{ .text = e.row.tag, .color = dim, .style = .{ .width = Length.px(28), .shrink = 0 } });
            _ = try ui.add(Label, row, .{ .text = e.row.label, .font = .mono, .style = .{ .shrink = 0 } });
            if (e.row.detail.len > 0) _ = try ui.add(Label, row, .{ .text = e.row.detail, .color = dim, .font = .mono, .style = .{ .grow = 1 } });
            try tree.addListener(row, .{ .kind = .pointer_down, .callback = event.Callback.bind(e, Entry.onDown) });
        }
        self.scrollToSelected();
    }

    pub fn destroyClosed(self: *Popup) void {
        const gpa = self.ui.gpa;
        self.arena.deinit();
        gpa.destroy(self);
    }

    /// Close; the memory goes at the next `Ui.update`.
    pub fn close(self: *Popup) void {
        if (self.closed) return;
        self.closed = true;
        const ui = self.ui;
        if (ui.popup == self) ui.popup = null;
        _ = ui.tree.destroySubtree(self.panel);
        ui.popup_closed.append(ui.gpa, self) catch {};
    }

    pub fn count(self: *const Popup) usize {
        return self.entries.len;
    }

    pub fn selectedIndex(self: *const Popup) ?usize {
        if (self.kind != .list or self.entries.len == 0) return null;
        return self.selected;
    }

    pub fn userOf(self: *const Popup, index: usize) usize {
        return self.entries[index].row.user;
    }

    pub fn selectIndex(self: *Popup, index: usize) void {
        if (self.entries.len == 0) return;
        const next = @min(index, self.entries.len - 1);
        if (next == self.selected) return;
        const old = self.selected;
        self.selected = next;
        self.markRow(old);
        self.markRow(next);
        self.scrollToSelected();
    }

    /// Move the selection by `delta` rows, wrapping around.
    pub fn move(self: *Popup, delta: i32) void {
        const n: i64 = @intCast(self.entries.len);
        if (n == 0) return;
        const next = @mod(@as(i64, @intCast(self.selected)) + delta, n);
        self.selectIndex(@intCast(next));
    }

    fn markRow(self: *Popup, i: usize) void {
        const h = self.entries[i].node;
        if (self.ui.tree.isValid(h)) self.ui.tree.markDirty(h, .{ .paint = true });
    }

    fn scrollToSelected(self: *Popup) void {
        const sv = self.scroll orelse return;
        if (self.entries.len == 0) return;
        const h = self.entries[self.selected].node;
        if (self.ui.tree.isValid(h)) sv.scrollIntoView(h);
    }

    /// Pick the selected row: close, then call `on_pick(index)`.
    pub fn pickSelected(self: *Popup) void {
        if (self.kind != .list or self.entries.len == 0) return;
        const hook = self.on_pick;
        const index = self.selected;
        self.close();
        if (hook) |h| h.call(h.ctx, index);
    }

    /// True if the window point is over the popup.
    pub fn contains(self: *const Popup, x: f32, y: f32) bool {
        const r = self.ui.tree.absoluteRect(self.panel) orelse return false;
        return x >= r.x and x < r.right() and y >= r.y and y < r.bottom();
    }

    /// Keep the popup inside the window once its size is known.
    pub fn update(self: *Popup) void {
        if (self.placed) return;
        const tree = &self.ui.tree;
        const r = tree.get(self.panel).?.rect;
        if (r.w <= 0) return;
        self.placed = true;
        const win = tree.get(tree.root).?.rect;
        var x = self.x;
        var y = self.y;
        if (y + r.h > win.h and self.anchor.y - r.h - 2 >= 0) y = self.anchor.y - r.h - 2;
        x = @max(@min(x, win.w - r.w), 0);
        y = @max(@min(y, win.h - r.h), 0);
        if (x != self.x or y != self.y) {
            tree.get(self.panel).?.style.inset = .{ .left = Length.px(x), .top = Length.px(y) };
            tree.markDirty(self.panel, .{ .layout = true, .paint = true });
        }
    }
};

// ---- tests -----------------------------------------------------------------

const testing = std.testing;
const Rig = @import("../core/test_rig.zig").Rig;
const TextField = @import("text_field.zig").TextField;

const Picked = struct {
    index: ?usize = null,
    fn pick(self: *Picked, i: usize) void {
        self.index = i;
    }
};

test "a list popup keeps focus where it was, moves and picks, and clicks pick" {
    const r = try Rig.init();
    defer r.deinit();
    const field = try r.ui.add(TextField, r.ui.tree.root, .{});
    r.ui.setFocus(field.node);
    try r.frame();
    var got: Picked = .{};
    try r.ui.showPopup(&.{
        .{ .tag = "fn", .label = "alpha", .detail = "() void", .user = 11 },
        .{ .label = "beta", .user = 22 },
        .{ .label = "gamma", .user = 33 },
    }, .{ .anchor = .{ .x = 10, .y = 10, .w = 8, .h = 16 }, .on_pick = .bind(&got, Picked.pick) });
    try r.frame();
    try testing.expect(r.ui.popupOpen());
    try testing.expect(r.ui.tree.focused.eql(field.node)); // focus untouched
    try testing.expectEqual(@as(?usize, 0), r.ui.popup.?.selectedIndex());
    r.ui.popupMove(1);
    r.ui.popupMove(1);
    r.ui.popupMove(1); // wraps
    try testing.expectEqual(@as(?usize, 0), r.ui.popup.?.selectedIndex());
    r.ui.popupMove(-1);
    try testing.expectEqual(@as(?usize, 2), r.ui.popup.?.selectedIndex());
    try testing.expectEqual(@as(usize, 33), r.ui.popup.?.userOf(2));
    try testing.expect(r.ui.popupPick());
    try testing.expectEqual(@as(?usize, 2), got.index);
    try testing.expect(!r.ui.popupOpen());
    try testing.expect(!r.ui.popupPick());
    try r.frame();

    // Clicking a row picks it, and the field keeps focus.
    got.index = null;
    try r.ui.showPopup(&.{ .{ .label = "one" }, .{ .label = "two" } }, .{ .anchor = .{ .x = 10, .y = 10, .w = 8, .h = 16 }, .on_pick = .bind(&got, Picked.pick) });
    try r.frame();
    const row = r.ui.popup.?.entries[1].node;
    const rr = r.ui.tree.absoluteRect(row).?;
    r.ui.pointerMove(rr.x + 4, rr.y + 4);
    r.ui.pointerButtonEx(rr.x + 4, rr.y + 4, 1, true, 1);
    r.ui.pointerButtonEx(rr.x + 4, rr.y + 4, 1, false, 1);
    try testing.expectEqual(@as(?usize, 1), got.index);
    try testing.expect(r.ui.tree.focused.eql(field.node));
    try r.frame();
}

test "a press outside closes a list, a tip ignores the pointer, and a new popup replaces the old" {
    const r = try Rig.init();
    defer r.deinit();
    try r.frame();
    try r.ui.showPopup(&.{.{ .label = "x" }}, .{ .anchor = .{ .x = 300, .y = 300, .w = 4, .h = 16 } });
    try r.frame();
    r.ui.pointerButtonEx(5, 5, 1, true, 1);
    r.ui.pointerButtonEx(5, 5, 1, false, 1);
    try testing.expect(!r.ui.popupOpen());
    try r.frame();

    try r.ui.showTip("Line one\nLine two", .{ .x = 50, .y = 50, .w = 10, .h = 16 });
    try r.frame();
    try testing.expect(r.ui.popupOpen());
    try testing.expectEqual(@as(?usize, null), r.ui.popup.?.selectedIndex());
    const panel = r.ui.popup.?.panel;
    try testing.expect(r.ui.tree.hitTest(60, 70) == null or !r.ui.tree.hitTest(60, 70).?.eql(panel));
    try r.ui.showPopup(&.{.{ .label = "y" }}, .{});
    try testing.expect(r.ui.popup.?.kind == .list);
    r.ui.hidePopup();
    try r.frame();
    try testing.expect(!r.ui.popupOpen());
}
