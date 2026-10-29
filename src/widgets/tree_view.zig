//! TreeView: a scrolling outline of expandable items (file trees, document
//! outlines, symbol lists).
//!
//! Items are added from code and referred to by a stable `u32` id (`no_item`
//! means "none" or, as a parent, "the top level"). The widget keeps its own
//! copy of each item's text. Each visible item is one row node in a
//! `ScrollView`; the rows are rebuilt (in `prepare`) after a structural change
//! and only restyled for selection and hover, so a few thousand items are fine
//! but it is not virtualized.
//!
//! Mouse: click selects, click the arrow (or double-click) expands and
//! collapses. Keyboard (with the tree focused): Up/Down move the selection,
//! Left collapses or goes to the parent, Right expands or goes to the first
//! child, Home/End jump, Enter or Space activate.

const std = @import("std");
const Handle = @import("../core/handle.zig").Handle;
const shadow = @import("../core/shadow.zig");
const geometry = @import("../core/geometry.zig");
const Color = geometry.Color;
const Rect = geometry.Rect;
const Ui = @import("../core/ui.zig").Ui;
const event = @import("../core/event.zig");
const paint_ctx = @import("../core/paint_ctx.zig");
const PaintCtx = paint_ctx.PaintCtx;
const draw_list = @import("../core/draw_list.zig");
const Style = @import("../core/style.zig").Style;
const Length = @import("../core/length.zig").Length;
const tree_mod = @import("../core/tree.zig");
const Node = tree_mod.Node;
const Text = @import("common.zig").Text;
const Label = @import("label.zig").Label;
const ScrollView = @import("scroll_view.zig").ScrollView;

/// "No item": no selection, or the top level when used as a parent.
pub const no_item: u32 = std.math.maxInt(u32);

const arrow_w: f32 = 14;
const row_pad: f32 = 2;

const Item = struct {
    owner: *TreeView,
    id: u32,
    text: Text = .{},
    parent: u32 = no_item,
    children: std.ArrayListUnmanaged(u32) = .empty,
    expanded: bool = false,
    /// Part of the selection (the primary item is always picked).
    picked: bool = false,
    user: u64 = 0,
    /// The row node while the item is visible.
    row: Handle = Handle.invalid,

    /// The expand/collapse arrow, drawn as a chevron.
    fn paintArrow(self: *Item, pc: *PaintCtx) paint_ctx.Error!void {
        if (self.children.items.len == 0) return;
        const tc = self.owner.ui.theme.text_color;
        const paint = draw_list.Paint.solid(Color.rgba(tc.r, tc.g, tc.b, 190));
        const r = pc.rect;
        const cx = r.x + r.w / 2;
        const cy = r.y + r.h / 2;
        if (self.expanded) {
            try pc.list.line(.{ .x = cx - 4, .y = cy - 2 }, .{ .x = cx, .y = cy + 2 }, 1.6, paint);
            try pc.list.line(.{ .x = cx, .y = cy + 2 }, .{ .x = cx + 4, .y = cy - 2 }, 1.6, paint);
        } else {
            try pc.list.line(.{ .x = cx - 2, .y = cy - 4 }, .{ .x = cx + 2, .y = cy }, 1.6, paint);
            try pc.list.line(.{ .x = cx + 2, .y = cy }, .{ .x = cx - 2, .y = cy + 4 }, 1.6, paint);
        }
    }
};

pub const TreeView = struct {
    props: Props = .{},
    out: Out = .{},
    node: Handle,
    ui: *Ui,
    checker: shadow.Checker(Props),
    scroll: *ScrollView = undefined,
    items: std.ArrayListUnmanaged(?*Item) = .empty,
    roots: std.ArrayListUnmanaged(u32) = .empty,
    /// Visible items, top to bottom (kept in step with the rows).
    order: std.ArrayListUnmanaged(u32) = .empty,
    selected_id: u32 = no_item,
    /// Where a shift-click or shift-arrow range starts.
    anchor_id: u32 = no_item,
    hover_id: u32 = no_item,
    rows_dirty: bool = false,
    pending_scroll: u32 = no_item,
    /// The `props.items` text the items were last loaded from.
    seen_items: []const u8 = "",

    pub const Props = struct {
        /// Pixels of indentation per level.
        indent: f32 = 16,
        row_height: f32 = 22,
        /// The selection changed (read `out.selected`).
        on_select: ?event.Callback = null,
        /// Enter, Space, or a double-click on an item.
        on_activate: ?event.Callback = null,
        /// An item was expanded or collapsed.
        on_toggle: ?event.Callback = null,
        /// A double-click also expands or collapses an item that has children.
        /// Turn it off when double-click means something else (rename, open).
        activate_toggles: bool = true,
        /// Ctrl-click toggles items and Shift-click or Shift-arrows select a
        /// range. `out.selected` is then the item last clicked (the primary).
        multi_select: bool = false,
        /// The items as text, one per line, indented by two spaces (or a tab)
        /// per level: how documents and the builder describe a tree. Setting it
        /// replaces the items.
        items: Text = .{},
        /// Expand every item that has children when `items` is loaded.
        expand_all: bool = true,

        pub const dirty_map = .{
            .items = shadow.Category.layout,
            .expand_all = shadow.Category.none,
            .indent = shadow.Category.layout,
            .row_height = shadow.Category.layout,
        };
    };

    pub const Out = struct {
        /// The selected item, or `no_item`.
        selected: u32 = no_item,
        /// Selection changed this frame.
        changed: bool = false,
        /// An item was activated this frame (`activated_item` says which).
        activated: bool = false,
        activated_item: u32 = no_item,
        /// An item was expanded or collapsed this frame.
        toggled: bool = false,
        focused: bool = false,
        /// Items in the tree (visible or not).
        count: u32 = 0,
    };

    pub const Options = struct {
        style: Style = .{},
        /// Accessible name.
        label: []const u8 = "Tree",
        indent: f32 = 16,
        row_height: f32 = 22,
        on_select: ?event.Callback = null,
        on_activate: ?event.Callback = null,
        on_toggle: ?event.Callback = null,
        activate_toggles: bool = true,
        multi_select: bool = false,
        /// Items as indented text (see `Props.items`); copied.
        items: []const u8 = "",
        expand_all: bool = true,
    };

    pub const listened_kinds = [_]event.EventKind{ .pointer_down, .pointer_move, .pointer_leave, .key_down, .focus_in, .focus_out };

    pub fn nodeTemplate(style: Style) Node {
        var s = style;
        s.direction = .column;
        return .{ .role = .list, .style = s, .flags = .{ .focusable = true } };
    }

    pub fn init(ui: *Ui, node: Handle) TreeView {
        const props: Props = .{};
        return .{ .node = node, .ui = ui, .checker = shadow.Checker(Props).init(&props) };
    }

    pub fn deinit(self: *TreeView) void {
        for (self.items.items) |maybe| {
            const it = maybe orelse continue;
            self.ui.freeText(&it.text);
            it.children.deinit(self.ui.gpa);
            self.ui.gpa.destroy(it);
        }
        self.items.deinit(self.ui.gpa);
        self.roots.deinit(self.ui.gpa);
        self.order.deinit(self.ui.gpa);
        self.ui.freeText(&self.props.items);
    }

    pub fn apply(self: *TreeView, o: Options) !void {
        self.props.indent = o.indent;
        self.props.row_height = o.row_height;
        self.props.on_select = o.on_select;
        self.props.on_activate = o.on_activate;
        self.props.on_toggle = o.on_toggle;
        self.props.activate_toggles = o.activate_toggles;
        self.props.multi_select = o.multi_select;
        self.props.expand_all = o.expand_all;
        if (o.items.len > 0) try self.ui.replaceText(&self.props.items, o.items);
        try self.ui.tree.setLabel(self.node, o.label);
        self.scroll = try self.ui.add(ScrollView, self.node, .{
            .style = .{ .grow = 1 },
            .content_style = .{ .direction = .column, .padding = .{ .right = Length.px(10) } },
        });
        try self.ui.tree.setLabel(self.scroll.node, o.label);
        self.checker.sync(&self.props);
    }

    pub fn paintHook(self: *TreeView, pc: *PaintCtx) paint_ctx.Error!void {
        _ = self;
        _ = pc;
    }

    // ---- items ----

    fn get(self: *const TreeView, id: u32) ?*Item {
        if (id >= self.items.items.len) return null;
        return self.items.items[id];
    }

    fn listOf(self: *TreeView, parent: u32) *std.ArrayListUnmanaged(u32) {
        return if (parent == no_item) &self.roots else &self.get(parent).?.children;
    }

    /// Append an item under `parent` (`no_item` for the top level); returns its id.
    pub fn addItem(self: *TreeView, parent: u32, text: []const u8) !u32 {
        return self.addItemAt(parent, std.math.maxInt(usize), text);
    }

    /// Insert an item as child number `index` of `parent` (clamped to the end).
    pub fn addItemAt(self: *TreeView, parent: u32, index: usize, text: []const u8) !u32 {
        if (parent != no_item and self.get(parent) == null) return error.InvalidItem;
        const gpa = self.ui.gpa;
        const it = try gpa.create(Item);
        errdefer gpa.destroy(it);
        it.* = .{ .owner = self, .id = @intCast(self.items.items.len), .parent = parent };
        try self.ui.replaceText(&it.text, text);
        errdefer self.ui.freeText(&it.text);
        try self.items.append(gpa, it);
        errdefer _ = self.items.pop();
        const list = self.listOf(parent);
        try list.insert(gpa, @min(index, list.items.len), it.id);
        self.out.count += 1;
        self.rows_dirty = true;
        return it.id;
    }

    /// Remove an item and everything under it.
    pub fn removeItem(self: *TreeView, id: u32) void {
        const it = self.get(id) orelse return;
        const list = self.listOf(it.parent);
        for (list.items, 0..) |c, i| {
            if (c == id) {
                _ = list.orderedRemove(i);
                break;
            }
        }
        if (self.selected_id != no_item and self.isInside(self.selected_id, id)) self.setSelected(no_item, false);
        if (self.hover_id != no_item and self.isInside(self.hover_id, id)) self.hover_id = no_item;
        if (self.pending_scroll != no_item and self.isInside(self.pending_scroll, id)) self.pending_scroll = no_item;
        self.freeSubtree(id);
        self.rows_dirty = true;
    }

    fn freeSubtree(self: *TreeView, id: u32) void {
        const it = self.get(id) orelse return;
        for (it.children.items) |c| self.freeSubtree(c);
        self.ui.freeText(&it.text);
        it.children.deinit(self.ui.gpa);
        self.ui.gpa.destroy(it);
        self.items.items[id] = null;
        self.out.count -= 1;
    }

    /// True if `id` is `ancestor` or below it.
    fn isInside(self: *const TreeView, id: u32, ancestor: u32) bool {
        var cur = id;
        while (cur != no_item) {
            if (cur == ancestor) return true;
            cur = (self.get(cur) orelse return false).parent;
        }
        return false;
    }

    /// Replace the items with those described by `text` (see `Props.items`).
    fn loadItemsText(self: *TreeView, text: []const u8) void {
        self.clear();
        var stack: [32]u32 = undefined;
        var last_level: usize = 0;
        var any = false;
        var it = std.mem.splitScalar(u8, text, '\n');
        while (it.next()) |raw| {
            var depth: usize = 0;
            var spaces: usize = 0;
            var i: usize = 0;
            while (i < raw.len and (raw[i] == ' ' or raw[i] == '\t')) : (i += 1) {
                if (raw[i] == '\t') depth += 1 else spaces += 1;
            }
            depth = @min(depth + spaces / 2, 30);
            const label = std.mem.trim(u8, raw[i..], " \t\r");
            if (label.len == 0) continue;
            // A line indented deeper than its predecessor allows hangs off that predecessor.
            const level = @min(depth, if (any) last_level + 1 else 0);
            const parent: u32 = if (level == 0) no_item else stack[level - 1];
            const id = self.addItem(parent, label) catch return;
            if (level < stack.len) stack[level] = id;
            last_level = level;
            any = true;
        }
        if (self.props.expand_all) self.expandAll();
    }

    /// Remove every item.
    pub fn clear(self: *TreeView) void {
        while (self.roots.items.len > 0) self.removeItem(self.roots.items[0]);
    }

    pub fn exists(self: *const TreeView, id: u32) bool {
        return self.get(id) != null;
    }

    pub fn itemText(self: *const TreeView, id: u32) []const u8 {
        return if (self.get(id)) |it| it.text.bytes else "";
    }

    pub fn setItemText(self: *TreeView, id: u32, new_text: []const u8) !void {
        const it = self.get(id) orelse return error.InvalidItem;
        try self.ui.replaceText(&it.text, new_text);
        self.rows_dirty = true;
    }

    pub fn parentOf(self: *const TreeView, id: u32) u32 {
        return if (self.get(id)) |it| it.parent else no_item;
    }

    pub fn childCount(self: *const TreeView, parent: u32) usize {
        if (parent == no_item) return self.roots.items.len;
        return if (self.get(parent)) |it| it.children.items.len else 0;
    }

    /// Child number `index` of `parent`.
    pub fn childAt(self: *const TreeView, parent: u32, index: usize) u32 {
        const list = if (parent == no_item) self.roots.items else if (self.get(parent)) |it| it.children.items else return no_item;
        return if (index < list.len) list[index] else no_item;
    }

    /// An app-defined value stored with the item (a node id, a path index...).
    pub fn setUserData(self: *TreeView, id: u32, v: u64) void {
        if (self.get(id)) |it| it.user = v;
    }

    pub fn userData(self: *const TreeView, id: u32) u64 {
        return if (self.get(id)) |it| it.user else 0;
    }

    // ---- expansion and selection ----

    pub fn isExpanded(self: *const TreeView, id: u32) bool {
        return if (self.get(id)) |it| it.expanded else false;
    }

    pub fn setExpanded(self: *TreeView, id: u32, expanded: bool) void {
        const it = self.get(id) orelse return;
        if (it.expanded == expanded) return;
        it.expanded = expanded;
        self.rows_dirty = true;
        if (!expanded and self.selected_id != no_item and self.selected_id != id and self.isInside(self.selected_id, id)) {
            self.setSelected(id, true);
        }
        self.out.toggled = true;
        self.fire(self.props.on_toggle);
    }

    pub fn expandAll(self: *TreeView) void {
        for (self.items.items) |maybe| {
            const it = maybe orelse continue;
            if (it.children.items.len > 0 and !it.expanded) {
                it.expanded = true;
                self.rows_dirty = true;
            }
        }
    }

    pub fn collapseAll(self: *TreeView) void {
        for (self.items.items) |maybe| {
            const it = maybe orelse continue;
            if (it.expanded) {
                it.expanded = false;
                self.rows_dirty = true;
            }
        }
        if (self.selected_id != no_item) {
            var top = self.selected_id;
            while (self.parentOf(top) != no_item) top = self.parentOf(top);
            if (top != self.selected_id) self.setSelected(top, true);
        }
    }

    pub fn selected(self: *const TreeView) u32 {
        return self.selected_id;
    }

    /// Select `id` (or nothing with `no_item`), expanding its ancestors and
    /// scrolling it into view. Fires `on_select` if the selection changed.
    pub fn select(self: *TreeView, id: u32) void {
        if (id != no_item) {
            if (self.get(id) == null) return;
            self.ensureVisible(id);
        }
        self.setSelected(id, true);
    }

    /// Expand the ancestors of `id` and scroll to it.
    pub fn ensureVisible(self: *TreeView, id: u32) void {
        var cur = self.parentOf(id);
        while (cur != no_item) : (cur = self.parentOf(cur)) {
            const it = self.get(cur).?;
            if (!it.expanded) {
                it.expanded = true;
                self.rows_dirty = true;
            }
        }
        self.pending_scroll = id;
    }

    /// Select only `id` (or nothing with `no_item`).
    fn setSelected(self: *TreeView, id: u32, notify: bool) void {
        var changed = self.selected_id != id;
        for (self.items.items) |maybe| {
            const it = maybe orelse continue;
            if (it.picked and it.id != id) {
                it.picked = false;
                changed = true;
                self.restyle(it.id);
            }
        }
        if (id != no_item) {
            if (self.get(id)) |it| {
                if (!it.picked) {
                    it.picked = true;
                    changed = true;
                }
            }
        }
        const old = self.selected_id;
        self.selected_id = id;
        self.out.selected = id;
        self.anchor_id = id;
        if (!changed) return;
        self.out.changed = true;
        self.restyle(old);
        self.restyle(id);
        if (notify) self.fire(self.props.on_select);
    }

    /// Ctrl-click: add or remove `id` from the selection.
    fn togglePick(self: *TreeView, id: u32) void {
        const it = self.get(id) orelse return;
        it.picked = !it.picked;
        if (it.picked) {
            self.selected_id = id;
        } else if (self.selected_id == id) {
            self.selected_id = no_item;
            for (self.items.items) |maybe| {
                const o = maybe orelse continue;
                if (o.picked) self.selected_id = o.id;
            }
        }
        self.out.selected = self.selected_id;
        self.out.changed = true;
        self.anchor_id = id;
        self.restyle(id);
        self.fire(self.props.on_select);
    }

    /// Shift-click: select everything visible between the anchor and `id`.
    fn pickRange(self: *TreeView, id: u32) void {
        self.computeOrder();
        var a: ?usize = null;
        var b: ?usize = null;
        for (self.order.items, 0..) |o, i| {
            if (o == self.anchor_id) a = i;
            if (o == id) b = i;
        }
        const from = a orelse b orelse return;
        const to = b orelse return;
        const lo = @min(from, to);
        const hi = @max(from, to);
        for (self.items.items) |maybe| {
            const it = maybe orelse continue;
            var want = false;
            for (self.order.items[lo .. hi + 1]) |o| want = want or o == it.id;
            if (it.picked != want) {
                it.picked = want;
                self.restyle(it.id);
            }
        }
        self.selected_id = id;
        self.out.selected = id;
        self.out.changed = true;
        self.fire(self.props.on_select);
    }

    /// Replace the selection with `ids`, `primary` being the main one. Does not
    /// call `on_select` (the host is the one changing it).
    pub fn setSelection(self: *TreeView, ids: []const u32, primary: u32) void {
        for (self.items.items) |maybe| {
            const it = maybe orelse continue;
            var want = it.id == primary;
            for (ids) |i| want = want or i == it.id;
            if (it.picked != want) {
                it.picked = want;
                self.restyle(it.id);
            }
        }
        if (primary != no_item) self.ensureVisible(primary);
        self.selected_id = primary;
        self.out.selected = primary;
        self.anchor_id = primary;
    }

    pub fn isSelected(self: *const TreeView, id: u32) bool {
        return if (self.get(id)) |it| it.picked else false;
    }

    pub fn selectedCount(self: *const TreeView) usize {
        var n: usize = 0;
        for (self.items.items) |maybe| {
            if (maybe) |it| n += @intFromBool(it.picked);
        }
        return n;
    }

    /// The selected items in creation order, up to `buf.len` of them.
    pub fn selectedItems(self: *const TreeView, buf: []u32) []u32 {
        var n: usize = 0;
        for (self.items.items) |maybe| {
            const it = maybe orelse continue;
            if (it.picked and n < buf.len) {
                buf[n] = it.id;
                n += 1;
            }
        }
        return buf[0..n];
    }

    fn fire(self: *TreeView, cb: ?event.Callback) void {
        const c = cb orelse return;
        var ev: event.Event = .{ .kind = .click, .target = self.node, .current = self.node };
        c.invoke(&ev);
    }

    // ---- geometry (for hosts that add drag and drop) ----

    /// The row's rectangle in window coordinates, if the item is visible and laid out.
    pub fn rowRect(self: *TreeView, id: u32) ?Rect {
        const it = self.get(id) orelse return null;
        return self.ui.tree.absoluteRect(it.row);
    }

    /// The row node of a visible item (invalid until the row exists).
    pub fn rowNode(self: *const TreeView, id: u32) Handle {
        return if (self.get(id)) |it| it.row else Handle.invalid;
    }

    /// The item whose row contains the window point, if any.
    pub fn itemAt(self: *TreeView, x: f32, y: f32) u32 {
        const h = self.ui.tree.nodeAt(self.scroll.contentNode(), x, y) orelse return no_item;
        return self.itemOfRowNode(h);
    }

    /// Visible items from top to bottom (valid until the tree changes).
    pub fn visibleItems(self: *TreeView) []const u32 {
        self.computeOrder();
        return self.order.items;
    }

    pub fn depthOf(self: *const TreeView, id: u32) usize {
        var d: usize = 0;
        var cur = self.parentOf(id);
        while (cur != no_item) : (cur = self.parentOf(cur)) d += 1;
        return d;
    }

    fn itemOfRowNode(self: *TreeView, h: Handle) u32 {
        const tree = &self.ui.tree;
        const content = self.scroll.contentNode();
        var cur = h;
        while (tree.get(cur)) |n| {
            if (n.parent.eql(content)) {
                const tag = @intFromPtr(n.user_data);
                return if (tag == 0) no_item else @intCast(tag - 1);
            }
            cur = n.parent;
        }
        return no_item;
    }

    // ---- rows ----

    fn computeOrder(self: *TreeView) void {
        self.order.clearRetainingCapacity();
        for (self.roots.items) |r| self.appendVisible(r);
    }

    fn appendVisible(self: *TreeView, id: u32) void {
        self.order.append(self.ui.gpa, id) catch return;
        const it = self.get(id).?;
        if (it.expanded) for (it.children.items) |c| self.appendVisible(c);
    }

    fn rebuildRows(self: *TreeView) !void {
        const tree = &self.ui.tree;
        const content = self.scroll.contentNode();
        // Destroy the old rows.
        while (tree.get(content).?.first_child.isNull() == false) {
            _ = tree.destroySubtree(tree.get(content).?.first_child);
        }
        for (self.items.items) |maybe| {
            if (maybe) |it| it.row = Handle.invalid;
        }
        self.computeOrder();
        for (self.order.items) |id| try self.buildRow(id, content);
        tree.markDirty(content, .{ .layout = true, .paint = true });
    }

    fn buildRow(self: *TreeView, id: u32, content: Handle) !void {
        const tree = &self.ui.tree;
        const it = self.get(id).?;
        const depth: f32 = @floatFromInt(self.depthOf(id));
        const row = try tree.create(.{ .style = .{
            .direction = .row,
            .align_items = .center,
            .gap = Length.px(4),
            .height = Length.px(self.props.row_height),
            .shrink = 0,
            .padding = .{ .left = Length.px(row_pad + self.props.indent * depth) },
        }, .user_data = @ptrFromInt(@as(usize, id) + 1) });
        errdefer _ = tree.destroySubtree(row);
        try tree.appendChild(content, row);
        it.row = row;
        const arrow = try tree.create(.{ .style = .{ .width = Length.px(arrow_w), .height = Length.px(arrow_w), .shrink = 0 } });
        try tree.appendChild(row, arrow);
        tree.get(arrow).?.paint_hook = tree_mod.PaintHook.bind(it, Item.paintArrow);
        _ = try self.ui.add(Label, row, .{ .text = it.text.bytes });
        self.restyle(id);
    }

    /// Selection and hover colors for one row.
    fn restyle(self: *TreeView, id: u32) void {
        const it = self.get(id) orelse return;
        const n = self.ui.tree.get(it.row) orelse return;
        const theme = &self.ui.theme;
        const bg: Color = if (it.picked)
            (if (self.out.focused) theme.field.selection else Color.rgba(255, 255, 255, 40))
        else if (id == self.hover_id)
            Color.rgba(255, 255, 255, 18)
        else
            Color.transparent;
        n.visual.background = bg;
        n.visual.radius = 3;
        self.ui.tree.markDirty(it.row, .{ .paint = true });
    }

    // ---- events ----

    pub fn handleEvent(self: *TreeView, ev: *event.Event) void {
        switch (ev.kind) {
            .focus_in => {
                self.out.focused = true;
                self.restyle(self.selected_id);
            },
            .focus_out => {
                self.out.focused = false;
                self.restyle(self.selected_id);
            },
            .pointer_move => {
                const id = self.itemAt(ev.x, ev.y);
                if (id != self.hover_id) {
                    const old = self.hover_id;
                    self.hover_id = id;
                    self.restyle(old);
                    self.restyle(id);
                }
            },
            .pointer_leave => {
                const old = self.hover_id;
                self.hover_id = no_item;
                self.restyle(old);
            },
            .pointer_down => self.onPointerDown(ev),
            .key_down => self.onKey(ev),
            else => {},
        }
    }

    fn onPointerDown(self: *TreeView, ev: *event.Event) void {
        if (ev.button != 1) return;
        // We focus the tree ourselves (and an app may move focus again from an
        // activate callback), so the default focus action must not run after us.
        ev.markHandled();
        // Focusing can run app code (a text field losing focus applies its
        // edit and may rebuild the items), so look the item up afterwards.
        self.ui.setFocus(self.node);
        const id = self.itemAt(ev.x, ev.y);
        const it = self.get(id) orelse return;
        const row = self.ui.tree.absoluteRect(it.row) orelse return;
        const has_children = it.children.items.len > 0;
        const expanded = it.expanded;
        const arrow_end = row.x + row_pad + self.props.indent * @as(f32, @floatFromInt(self.depthOf(id))) + arrow_w;
        if (has_children and ev.x < arrow_end) {
            self.setExpanded(id, !expanded);
            return;
        }
        if (self.props.multi_select and (ev.mods.ctrl or ev.mods.gui)) return self.togglePick(id);
        if (self.props.multi_select and ev.mods.shift) return self.pickRange(id);
        self.setSelected(id, true);
        if (ev.clicks >= 2) {
            // Callbacks above may have changed the tree: only use `id` if it is still there.
            if (self.props.activate_toggles and self.exists(id) and has_children) self.setExpanded(id, !self.isExpanded(id));
            if (self.exists(id)) self.activate(id);
        }
    }

    fn activate(self: *TreeView, id: u32) void {
        self.out.activated = true;
        self.out.activated_item = id;
        self.fire(self.props.on_activate);
    }

    fn onKey(self: *TreeView, ev: *event.Event) void {
        if (ev.mods.any(.{ .ctrl = true, .alt = true, .gui = true })) return;
        self.computeOrder();
        const order = self.order.items;
        if (order.len == 0) return;
        var pos: ?usize = null;
        for (order, 0..) |id, i| {
            if (id == self.selected_id) pos = i;
        }
        const cur = self.selected_id;
        var go: ?u32 = null;
        switch (ev.key) {
            .down => go = if (pos) |p| order[@min(p + 1, order.len - 1)] else order[0],
            .up => go = if (pos) |p| order[if (p == 0) 0 else p - 1] else order[order.len - 1],
            .home => go = order[0],
            .end => go = order[order.len - 1],
            .left => {
                if (cur == no_item) return;
                if (self.isExpanded(cur)) {
                    self.setExpanded(cur, false);
                    ev.markHandled();
                    return;
                }
                const p = self.parentOf(cur);
                if (p != no_item) go = p;
            },
            .right => {
                if (cur == no_item) return;
                const it = self.get(cur).?;
                if (it.children.items.len == 0) return;
                if (!it.expanded) {
                    self.setExpanded(cur, true);
                    ev.markHandled();
                    return;
                }
                go = it.children.items[0];
            },
            .enter, .space => {
                if (cur == no_item) return;
                self.activate(cur);
                ev.markHandled();
                return;
            },
            else => return,
        }
        ev.markHandled();
        if (go) |id| {
            if (self.props.multi_select and ev.mods.shift) self.pickRange(id) else self.setSelected(id, true);
            self.pending_scroll = id;
        }
    }

    // ---- frame ----

    /// Rebuild the rows after structural changes. `Ui.update` calls this
    /// before it reclaims destroyed widgets, so the old rows' labels are swept
    /// in the same frame and the new ones are prepared and shaped in it.
    pub fn rebuildIfDirty(self: *TreeView) void {
        if (!self.ui.tree.isValid(self.node)) return; // destroyed; not swept yet
        const items = self.props.items.bytes;
        if (items.ptr != self.seen_items.ptr or items.len != self.seen_items.len) {
            self.seen_items = items;
            if (items.len > 0) self.loadItemsText(items);
        }
        if (self.rows_dirty) {
            self.rows_dirty = false;
            self.rebuildRows() catch {};
        }
    }

    pub fn prepare(self: *TreeView) void {
        _ = self;
    }

    pub fn update(self: *TreeView) void {
        self.ui.verifyProps(self.node, &self.checker, &self.props, "tree_view");
        if (self.pending_scroll != no_item) {
            if (self.get(self.pending_scroll)) |it| {
                if (self.ui.tree.get(it.row)) |rn| {
                    if (rn.rect.h > 0) {
                        self.scroll.scrollIntoView(it.row);
                        self.pending_scroll = no_item;
                    }
                }
            } else self.pending_scroll = no_item;
        }
    }

    pub fn endFrame(self: *TreeView) void {
        self.out.changed = false;
        self.out.activated = false;
        self.out.toggled = false;
    }
};

// ---- tests -----------------------------------------------------------------

const testing = std.testing;

const Rig = struct {
    ui: Ui,
    cmds: [2048]draw_list.Command = undefined,
    glyphs: [1024]draw_list.Glyph = undefined,
    list: draw_list.DrawList = undefined,

    fn init() !*Rig {
        const r = try testing.allocator.create(Rig);
        r.ui = try Ui.init(testing.allocator);
        r.list = draw_list.DrawList.init(&r.cmds, &r.glyphs);
        r.ui.tree.get(r.ui.tree.root).?.style = .{ .align_items = .start };
        return r;
    }

    fn deinit(self: *Rig) void {
        self.ui.deinit();
        testing.allocator.destroy(self);
    }

    fn frame(self: *Rig) !void {
        self.ui.update();
        if (self.ui.isDirty()) try self.ui.layoutAndPaint(.{ .w = 300, .h = 300 }, &self.list);
        self.ui.endFrame();
    }

    /// Two frames: rows are built in the first, laid out in the same one.
    fn settle(self: *Rig) !void {
        try self.frame();
        try self.frame();
    }

    fn tv(self: *Rig) !*TreeView {
        return self.ui.add(TreeView, self.ui.tree.root, .{ .style = .{ .width = Length.px(200), .height = Length.px(110), .shrink = 0 } });
    }

    fn click(self: *Rig, x: f32, y: f32, clicks: u32) void {
        self.ui.pointerMove(x, y);
        self.ui.pointerButtonEx(x, y, 1, true, clicks);
        self.ui.pointerButtonEx(x, y, 1, false, clicks);
    }
};

/// Window-space center of an item's row, nudged right of the arrow.
fn rowPoint(t: *TreeView, id: u32, dx: f32) struct { x: f32, y: f32 } {
    const r = t.rowRect(id).?;
    return .{ .x = r.x + dx, .y = r.y + r.h / 2 };
}

fn sample(t: *TreeView) !struct { a: u32, a1: u32, a2: u32, b: u32 } {
    const a = try t.addItem(no_item, "alpha");
    const a1 = try t.addItem(a, "one");
    const a2 = try t.addItem(a, "two");
    const b = try t.addItem(no_item, "beta");
    return .{ .a = a, .a1 = a1, .a2 = a2, .b = b };
}

test "collapsed items hide their children; expanding shows them" {
    const r = try Rig.init();
    defer r.deinit();
    const t = try r.tv();
    const s = try sample(t);
    try r.settle();
    try testing.expect(t.rowRect(s.a) != null);
    try testing.expect(t.rowRect(s.b) != null);
    try testing.expect(t.rowRect(s.a1) == null);
    try testing.expectEqual(@as(usize, 2), t.visibleItems().len);

    t.setExpanded(s.a, true);
    try r.settle();
    try testing.expectEqual(@as(usize, 4), t.visibleItems().len);
    // Children sit between their parent and the next top-level item, indented.
    const ya = t.rowRect(s.a).?;
    const y1 = t.rowRect(s.a1).?;
    const yb = t.rowRect(s.b).?;
    try testing.expect(y1.y > ya.y and yb.y > t.rowRect(s.a2).?.y);
    try testing.expectEqual(@as(usize, 1), t.depthOf(s.a1));
}

test "clicking selects; the arrow and a double-click toggle; callbacks fire" {
    const r = try Rig.init();
    defer r.deinit();
    const t = try r.tv();
    const s = try sample(t);
    try r.settle();

    const body = rowPoint(t, s.b, 60);
    r.click(body.x, body.y, 1);
    try testing.expectEqual(s.b, t.selected());
    try testing.expect(t.out.changed);
    try r.frame();
    try testing.expect(!t.out.changed);

    // The arrow of "alpha" expands it without selecting it.
    const arrow = rowPoint(t, s.a, 2 + 7);
    r.click(arrow.x, arrow.y, 1);
    try testing.expect(t.isExpanded(s.a));
    try testing.expectEqual(s.b, t.selected());
    try r.settle();

    // Double-click on the text collapses it again and activates it.
    const text = rowPoint(t, s.a, 60);
    r.click(text.x, text.y, 2);
    try testing.expect(!t.isExpanded(s.a));
    try testing.expect(t.out.activated);
    try testing.expectEqual(s.a, t.out.activated_item);
}

test "keyboard: arrows move, left and right collapse and expand, enter activates" {
    const r = try Rig.init();
    defer r.deinit();
    const t = try r.tv();
    const s = try sample(t);
    try r.settle();
    r.ui.setFocus(t.node);
    try r.frame();

    r.ui.key(.down, .{}, true, false);
    try testing.expectEqual(s.a, t.selected());
    r.ui.key(.right, .{}, true, false); // expands
    try testing.expect(t.isExpanded(s.a));
    try r.settle();
    r.ui.key(.right, .{}, true, false); // goes to the first child
    try testing.expectEqual(s.a1, t.selected());
    r.ui.key(.down, .{}, true, false);
    r.ui.key(.down, .{}, true, false);
    try testing.expectEqual(s.b, t.selected());
    r.ui.key(.up, .{}, true, false);
    r.ui.key(.left, .{}, true, false); // from a child: to the parent
    try testing.expectEqual(s.a, t.selected());
    r.ui.key(.left, .{}, true, false); // collapses
    try testing.expect(!t.isExpanded(s.a));
    try r.settle();
    r.ui.key(.enter, .{}, true, false);
    try testing.expect(t.out.activated);
    r.ui.key(.end, .{}, true, false);
    try testing.expectEqual(s.b, t.selected());
    r.ui.key(.home, .{}, true, false);
    try testing.expectEqual(s.a, t.selected());
}

test "collapsing an ancestor of the selection selects the ancestor" {
    const r = try Rig.init();
    defer r.deinit();
    const t = try r.tv();
    const s = try sample(t);
    t.select(s.a2); // expands "alpha" to show it
    try r.settle();
    try testing.expect(t.isExpanded(s.a));
    try testing.expectEqual(s.a2, t.selected());
    t.setExpanded(s.a, false);
    try testing.expectEqual(s.a, t.selected());
}

test "removing an item removes its subtree and clears a selection inside it" {
    const r = try Rig.init();
    defer r.deinit();
    const t = try r.tv();
    const s = try sample(t);
    t.select(s.a1);
    try r.settle();
    try testing.expectEqual(@as(u32, 4), t.out.count);
    t.removeItem(s.a);
    try testing.expectEqual(no_item, t.selected());
    try testing.expectEqual(@as(u32, 1), t.out.count);
    try testing.expect(!t.exists(s.a1));
    try r.settle();
    try testing.expectEqual(@as(usize, 1), t.visibleItems().len);
    t.clear();
    try r.settle();
    try testing.expectEqual(@as(usize, 0), t.visibleItems().len);
}

test "text, user data, insertion order, and child lookup" {
    const r = try Rig.init();
    defer r.deinit();
    const t = try r.tv();
    const a = try t.addItem(no_item, "a");
    const c = try t.addItem(no_item, "c");
    const b = try t.addItemAt(no_item, 1, "b");
    try testing.expectEqual(b, t.childAt(no_item, 1));
    try testing.expectEqual(c, t.childAt(no_item, 2));
    try testing.expectEqual(@as(usize, 3), t.childCount(no_item));
    try t.setItemText(a, "alpha");
    try testing.expectEqualStrings("alpha", t.itemText(a));
    t.setUserData(b, 42);
    try testing.expectEqual(@as(u64, 42), t.userData(b));
    try testing.expectError(error.InvalidItem, t.addItem(999, "x"));
}

test "a long tree scrolls the selection into view" {
    const r = try Rig.init();
    defer r.deinit();
    const t = try r.tv();
    var last: u32 = 0;
    for (0..30) |i| {
        var buf: [16]u8 = undefined;
        last = try t.addItem(no_item, std.fmt.bufPrint(&buf, "item {d}", .{i}) catch "x");
    }
    try r.settle();
    t.select(last);
    try r.settle();
    try r.settle();
    try testing.expect(r.ui.tree.get(t.scroll.node).?.scroll_y > 0);
    const view = r.ui.tree.absoluteRect(t.scroll.node).?;
    const row = t.rowRect(last).?;
    try testing.expect(row.bottom() <= view.bottom() + 0.5);
}

test "multi-select: ctrl toggles, shift selects a range, plain click collapses to one" {
    const r = try Rig.init();
    defer r.deinit();
    const t = try r.ui.add(TreeView, r.ui.tree.root, .{ .style = .{ .width = Length.px(200), .height = Length.px(200), .shrink = 0 }, .multi_select = true });
    const s = try sample(t);
    t.expandAll();
    try r.settle();
    // order: alpha, one, two, beta
    const p_a = rowPoint(t, s.a, 60);
    const p_two = rowPoint(t, s.a2, 60);
    const p_b = rowPoint(t, s.b, 60);
    r.click(p_a.x, p_a.y, 1);
    try testing.expectEqual(@as(usize, 1), t.selectedCount());
    r.ui.input.mods = .{ .ctrl = true };
    r.click(p_b.x, p_b.y, 1);
    try testing.expectEqual(@as(usize, 2), t.selectedCount());
    try testing.expect(t.isSelected(s.a) and t.isSelected(s.b));
    try testing.expectEqual(s.b, t.selected());
    r.click(p_a.x, p_a.y, 1); // ctrl-click again removes it
    try testing.expect(!t.isSelected(s.a) and t.selectedCount() == 1);
    r.ui.input.mods = .{ .shift = true };
    r.click(p_two.x, p_two.y, 1); // the anchor is alpha (last ctrl-clicked): alpha..two
    try testing.expectEqual(@as(usize, 3), t.selectedCount());
    try testing.expect(t.isSelected(s.a) and t.isSelected(s.a1) and t.isSelected(s.a2) and !t.isSelected(s.b));
    var buf: [8]u32 = undefined;
    try testing.expectEqual(@as(usize, 3), t.selectedItems(&buf).len);
    r.ui.input.mods = .{};
    r.click(p_a.x, p_a.y, 1);
    try testing.expectEqual(@as(usize, 1), t.selectedCount());
    try testing.expectEqual(s.a, t.selected());

    // Shift+Down extends from the anchor.
    r.ui.setFocus(t.node);
    try r.frame();
    r.ui.key(.down, .{ .shift = true }, true, false);
    r.ui.key(.down, .{ .shift = true }, true, false);
    try testing.expectEqual(@as(usize, 3), t.selectedCount());
    // setSelection replaces it without calling back.
    t.setSelection(&.{ s.a1, s.b }, s.b);
    try testing.expect(t.isSelected(s.a1) and t.isSelected(s.b) and !t.isSelected(s.a));
    try testing.expectEqual(@as(usize, 2), t.selectedCount());
}

test "without multi_select, ctrl-click just selects" {
    const r = try Rig.init();
    defer r.deinit();
    const t = try r.tv();
    const s = try sample(t);
    try r.settle();
    const p_a = rowPoint(t, s.a, 60);
    const p_b = rowPoint(t, s.b, 60);
    r.click(p_a.x, p_a.y, 1);
    r.ui.input.mods = .{ .ctrl = true };
    r.click(p_b.x, p_b.y, 1);
    try testing.expectEqual(@as(usize, 1), t.selectedCount());
    try testing.expectEqual(s.b, t.selected());
}

test "items text builds the tree: indentation is depth, blank lines are skipped, deeper jumps hang off the last item" {
    const r = try Rig.init();
    defer r.deinit();
    const t = try r.ui.add(TreeView, r.ui.tree.root, .{
        .style = .{ .width = Length.px(200), .height = Length.px(200), .shrink = 0 },
        .items = "src\n  main.zig\n  ui\n    layout.zig\n\ndocs\n      deep\n",
    });
    try r.settle();
    try testing.expectEqual(@as(usize, 2), t.childCount(no_item));
    const src = t.childAt(no_item, 0);
    try testing.expectEqualStrings("src", t.itemText(src));
    try testing.expectEqual(@as(usize, 2), t.childCount(src));
    const ui_dir = t.childAt(src, 1);
    try testing.expectEqualStrings("layout.zig", t.itemText(t.childAt(ui_dir, 0)));
    const docs = t.childAt(no_item, 1);
    try testing.expectEqualStrings("deep", t.itemText(t.childAt(docs, 0))); // over-indented: one level down
    try testing.expect(t.isExpanded(src)); // expand_all
    // Changing the prop replaces the items.
    try r.ui.replaceText(&t.props.items, "only");
    try r.settle();
    try testing.expectEqual(@as(usize, 1), t.childCount(no_item));
    try testing.expectEqualStrings("only", t.itemText(t.childAt(no_item, 0)));
}
