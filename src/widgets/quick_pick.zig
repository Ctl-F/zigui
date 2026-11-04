//! A quick-pick palette: a modal box near the top of the window with a query
//! field above a short list of the best matches among many items (files,
//! symbols, commands). Typing narrows and ranks the list, Up/Down move,
//! Enter or a double-click picks, Escape closes. The Ctrl+P / Ctrl+, "go to
//! anything" box of other editors.
//!
//!     const qp = try QuickPick.create(&ui, ui.tree.root);        // hidden until shown
//!     defer qp.destroy();
//!     qp.show(.{ .placeholder = "Go to file, function or type", .items = items,
//!                .on_pick = .bind(&app, App.picked) });             // fn (*App, index: usize) void
//!     qp.setItems(more);        // while open (e.g. a background index finished)
//!
//! `items` are borrowed: the slice and the strings in it must stay valid until
//! the next `setItems` or `close`. Matching is `completion.matchScore` on the
//! item's `label`, best first, then `group`, then shorter labels; an empty query
//! shows the first items in the given order. The hook gets the picked item's
//! index into `items`.

const std = @import("std");
const Handle = @import("../core/handle.zig").Handle;
const Ui = @import("../core/ui.zig").Ui;
const event = @import("../core/event.zig");
const Length = @import("../core/length.zig").Length;
const Edges = @import("../core/style.zig").Edges;
const Color = @import("../core/geometry.zig").Color;
const Label = @import("label.zig").Label;
const TextField = @import("text_field.zig").TextField;
const tree_view = @import("tree_view.zig");
const TreeView = tree_view.TreeView;
const matchScore = @import("completion.zig").matchScore;

pub const Item = struct {
    /// Matched against the query and shown first.
    label: []const u8,
    /// Shown after the label, dimmer in meaning (a path, a kind); not matched.
    detail: []const u8 = "",
    /// Breaks ties between equal matches: lower first (project before library).
    group: u8 = 0,
};

pub const PickHook = struct {
    ctx: ?*anyopaque = null,
    call: *const fn (ctx: ?*anyopaque, index: usize) void,

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

/// Called with the query text each time it changes, when the box does its own
/// ranking (`Options.external`): answer with `setItems`.
pub const QueryHook = struct {
    ctx: ?*anyopaque = null,
    call: *const fn (ctx: ?*anyopaque, query: []const u8) void,

    pub fn bind(ctx: anytype, comptime f: anytype) QueryHook {
        const Ptr = @TypeOf(ctx);
        return .{
            .ctx = @ptrCast(ctx),
            .call = &struct {
                fn thunk(c: ?*anyopaque, query: []const u8) void {
                    f(@as(Ptr, @ptrCast(@alignCast(c.?))), query);
                }
            }.thunk,
        };
    }
};

pub const Options = struct {
    /// The caller ranks: the box shows `items` as given (at most `max_rows`) and
    /// asks `on_query` for a new list whenever the query changes (it also runs at `show`).
    external: bool = false,
    on_query: ?QueryHook = null,
    placeholder: []const u8 = "Type to search",
    items: []const Item = &.{},
    /// Starting query text.
    query: []const u8 = "",
    on_pick: ?PickHook = null,
};

pub const max_rows = 40;

const Ranked = struct { index: u32, score: u32 };

pub const QuickPick = struct {
    gpa: std.mem.Allocator,
    ui: *Ui,
    node: Handle,
    panel: Handle,
    field: *TextField,
    list: *TreeView,
    status: *Label,
    items: []const Item = &.{},
    hook: ?PickHook = null,
    external: bool = false,
    query_hook: ?QueryHook = null,
    ranked: std.ArrayListUnmanaged(Ranked) = .empty,
    open: bool = false,
    scoped: bool = false,

    pub fn create(ui: *Ui, parent: Handle) !*QuickPick {
        const self = try ui.gpa.create(QuickPick);
        errdefer ui.gpa.destroy(self);
        const tree = &ui.tree;
        const node = try tree.create(.{
            .style = .{ .position = .absolute, .inset = .{ .left = Length.px(0), .top = Length.px(0), .right = Length.px(0), .bottom = Length.px(0) }, .direction = .column, .align_items = .center, .justify = .start, .padding = Edges.xy(0, 60) },
            .visual = .{ .background = Color.rgba(0, 0, 0, 90) },
            .flags = .{ .hidden = true },
            .role = .panel,
        });
        errdefer _ = tree.destroySubtree(node);
        try tree.appendChild(parent, node);
        try tree.setLabel(node, "Quick pick");
        try tree.addListener(node, .{ .kind = .pointer_down, .callback = .bind(self, onBackdrop) });
        const panel = try tree.create(.{
            .style = .{ .direction = .column, .gap = Length.px(6), .padding = Edges.all(10), .width = Length.px(640), .height = Length.px(420), .shrink = 1 },
            .visual = .{ .background = Color.rgb(0x2b, 0x2d, 0x31), .border_color = Color.rgb(0x4a, 0x4d, 0x52), .border_width = 1, .radius = 6 },
            .role = .panel,
        });
        try tree.appendChild(node, panel);
        try tree.addListener(panel, .{ .kind = .key_down, .callback = .bind(self, onKey) });
        const field = try ui.add(TextField, panel, .{
            .label = "Search",
            .style = .{ .shrink = 0 },
            .on_change = .bind(self, onChange),
            .on_submit = .bind(self, onSubmit),
        });
        const list = try ui.add(TreeView, panel, .{
            .style = .{ .grow = 1 },
            .label = "Matches",
            .activate_toggles = false,
            .on_activate = .bind(self, onActivate),
        });
        const status = try ui.add(Label, panel, .{ .text = "", .style = .{ .shrink = 0 } });
        self.* = .{ .gpa = ui.gpa, .ui = ui, .node = node, .panel = panel, .field = field, .list = list, .status = status };
        return self;
    }

    pub fn destroy(self: *QuickPick) void {
        if (self.scoped) self.ui.popFocusScope();
        self.ranked.deinit(self.gpa);
        self.gpa.destroy(self);
    }

    pub fn isOpen(self: *const QuickPick) bool {
        return self.open;
    }

    pub fn show(self: *QuickPick, o: Options) void {
        self.items = o.items;
        self.hook = o.on_pick;
        self.external = o.external;
        self.query_hook = o.on_query;
        self.field.setPlaceholder(o.placeholder) catch {};
        self.field.setText(o.query) catch {};
        if (!self.open) {
            self.open = true;
            self.ui.setHidden(self.node, false);
            self.scoped = self.ui.pushFocusScope(self.panel, true);
        }
        self.refilter();
        self.askOwner();
        self.ui.setFocus(self.field.node);
        // Typed-in starting text (a handed-over query) keeps the caret after it; otherwise the box starts clean.
        if (o.query.len > 0) self.field.editor.end(false) else self.field.editor.selectAll();
    }

    pub fn close(self: *QuickPick) void {
        if (!self.open) return;
        self.open = false;
        if (self.scoped) self.ui.popFocusScope();
        self.scoped = false;
        self.ui.setHidden(self.node, true);
        self.list.clear();
        self.items = &.{};
    }

    /// Replace the items while open; the query stays.
    pub fn setItems(self: *QuickPick, items: []const Item) void {
        self.items = items;
        if (self.open) self.refilter();
    }

    /// Show a note under the list ("indexing the standard library...").
    pub fn setStatus(self: *QuickPick, text: []const u8) void {
        self.status.setText(text) catch {};
    }

    fn lessRanked(self: *const QuickPick, a: Ranked, b: Ranked) bool {
        if (a.score != b.score) return a.score < b.score;
        const ia = self.items[a.index];
        const ib = self.items[b.index];
        if (ia.group != ib.group) return ia.group < ib.group;
        if (ia.label.len != ib.label.len) return ia.label.len < ib.label.len;
        return a.index < b.index;
    }

    fn refilter(self: *QuickPick) void {
        const q = std.mem.trim(u8, self.field.text(), " \t");
        self.ranked.clearRetainingCapacity();
        if (self.external or q.len == 0) {
            const n = @min(self.items.len, max_rows);
            for (0..n) |i| self.ranked.append(self.gpa, .{ .index = @intCast(i), .score = 0 }) catch break;
        } else {
            for (self.items, 0..) |it, i| {
                const sc = matchScore(q, it.label) orelse continue;
                self.ranked.append(self.gpa, .{ .index = @intCast(i), .score = sc }) catch break;
            }
            const Ctx = struct {
                qp: *const QuickPick,
                fn less(c: @This(), a: Ranked, b: Ranked) bool {
                    return c.qp.lessRanked(a, b);
                }
            };
            // Only the best `max_rows` matter: partial selection by sorting all is
            // fine at this size (tens of thousands), and simple.
            std.mem.sort(Ranked, self.ranked.items, Ctx{ .qp = self }, Ctx.less);
            if (self.ranked.items.len > max_rows) self.ranked.shrinkRetainingCapacity(max_rows);
        }
        self.list.clear();
        for (self.ranked.items, 0..) |r, i| {
            const it = self.items[r.index];
            var buf: [400]u8 = undefined;
            const text = if (it.detail.len > 0)
                (std.fmt.bufPrint(&buf, "{s}    {s}", .{ it.label, it.detail }) catch it.label)
            else
                it.label;
            const id = self.list.addItem(tree_view.no_item, text) catch break;
            self.list.setUserData(id, i);
        }
        if (self.ranked.items.len > 0) self.list.select(self.list.childAt(tree_view.no_item, 0));
    }

    /// The item index behind list row `id`.
    fn itemOf(self: *const QuickPick, id: u32) ?usize {
        if (id == tree_view.no_item or !self.list.exists(id)) return null;
        const row: usize = @intCast(self.list.userData(id));
        return if (row < self.ranked.items.len) self.ranked.items[row].index else null;
    }

    /// Pick the selected row (what Enter does).
    pub fn accept(self: *QuickPick) void {
        const index = self.itemOf(self.list.selected()) orelse return;
        const hook = self.hook;
        self.close();
        if (hook) |h| h.call(h.ctx, index);
    }

    fn move(self: *QuickPick, delta: i32) void {
        const n = self.list.childCount(tree_view.no_item);
        if (n == 0) return;
        const cur = self.list.selected();
        var at: i32 = 0;
        for (0..n) |i| {
            if (self.list.childAt(tree_view.no_item, i) == cur) at = @intCast(i);
        }
        const next: usize = @intCast(std.math.clamp(at + delta, 0, @as(i32, @intCast(n)) - 1));
        const id = self.list.childAt(tree_view.no_item, next);
        self.list.select(id);
        self.list.ensureVisible(id);
    }

    /// In external mode, ask the owner for the list that goes with the query.
    fn askOwner(self: *QuickPick) void {
        if (!self.external) return;
        const h = self.query_hook orelse return;
        h.call(h.ctx, std.mem.trim(u8, self.field.text(), " \t"));
    }

    fn onChange(self: *QuickPick, _: *event.Event) void {
        if (self.external) return self.askOwner();
        self.refilter();
    }

    fn onSubmit(self: *QuickPick, _: *event.Event) void {
        self.accept();
    }

    fn onActivate(self: *QuickPick, _: *event.Event) void {
        const index = self.itemOf(self.list.out.activated_item) orelse return;
        const hook = self.hook;
        self.close();
        if (hook) |h| h.call(h.ctx, index);
    }

    fn onBackdrop(self: *QuickPick, ev: *event.Event) void {
        // A press on the dimmed area closes the box; presses inside bubble through here too.
        if (ev.target.eql(self.node)) {
            self.close();
            ev.markHandled();
        }
    }

    fn onKey(self: *QuickPick, ev: *event.Event) void {
        switch (ev.key) {
            .escape => {
                self.close();
                ev.markHandled();
            },
            .down => {
                self.move(1);
                ev.markHandled();
            },
            .up => {
                self.move(-1);
                ev.markHandled();
            },
            .page_down => {
                self.move(10);
                ev.markHandled();
            },
            .page_up => {
                self.move(-10);
                ev.markHandled();
            },
            else => {},
        }
    }
};

// ---- tests -----------------------------------------------------------------

const testing = std.testing;
const Rig = @import("../core/test_rig.zig").Rig;

const Got = struct {
    index: ?usize = null,
    fn on(self: *Got, i: usize) void {
        self.index = i;
    }
};

const sample = [_]Item{
    .{ .label = "append", .detail = "std/array_list.zig", .group = 1 },
    .{ .label = "appendSlice", .detail = "std/array_list.zig", .group = 1 },
    .{ .label = "App", .detail = "src/app.zig" },
    .{ .label = "render", .detail = "src/render.zig" },
};

test "typing ranks the matches, arrows move, Enter picks the original index" {
    const r = try Rig.init();
    defer r.deinit();
    const qp = try QuickPick.create(&r.ui, r.ui.tree.root);
    defer qp.destroy();
    var got: Got = .{};
    try r.frame();
    qp.show(.{ .items = &sample, .on_pick = .bind(&got, Got.on) });
    try r.frame();
    try testing.expect(qp.isOpen());
    // Empty query: all items, in order.
    try testing.expectEqual(@as(usize, 4), qp.list.childCount(tree_view.no_item));
    r.ui.textInput("app");
    try r.frame();
    // "App" and "append" match; the case-exact-prefix and the project group first.
    try testing.expectEqual(@as(usize, 3), qp.list.childCount(tree_view.no_item));
    const first = qp.list.itemText(qp.list.childAt(tree_view.no_item, 0));
    try testing.expect(std.mem.startsWith(u8, first, "append") or std.mem.startsWith(u8, first, "App"));
    // "render" does not contain a-p-p in order.
    for (0..3) |i| try testing.expect(!std.mem.startsWith(u8, qp.list.itemText(qp.list.childAt(tree_view.no_item, i)), "render"));
    qp.accept();
    try testing.expect(got.index != null and got.index.? != 3);
    try testing.expect(!qp.isOpen());
}

test "setItems refilters while open and Escape closes" {
    const r = try Rig.init();
    defer r.deinit();
    const qp = try QuickPick.create(&r.ui, r.ui.tree.root);
    defer qp.destroy();
    try r.frame();
    qp.show(.{ .items = sample[0..1], .query = "ren" });
    try testing.expectEqual(@as(usize, 0), qp.list.childCount(tree_view.no_item));
    qp.setItems(&sample);
    try testing.expectEqual(@as(usize, 1), qp.list.childCount(tree_view.no_item));
    qp.close();
    try testing.expect(!qp.isOpen());
}
