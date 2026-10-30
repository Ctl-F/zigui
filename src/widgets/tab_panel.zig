//! TabPanel: a row of tabs over a stack of pages; only the active page shows.
//!
//! Each tab owns a page node (a column) that you fill like any container.
//!
//!     const tabs = try ui.add(TabPanel, parent, .{ .style = .{ .width = .fill, .height = .fill } });
//!     const files = try tabs.addTab("Files");        // the page node for that tab
//!     _ = try ui.add(Label, files, .{ .text = "..." });
//!     _ = try tabs.addTab("Search");
//!
//! The titles are kept as one text, one per line (`props.titles`), so UI
//! documents and the builder can edit them; the page nodes are the widget's
//! children in a document. Click a tab or use Left/Right on a focused tab to
//! switch, drag a tab to reorder it, and with `closable` each tab has an ×.
//! A `DragHook` is told about tab drags so a host (the dock) can tear tabs out.

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
const DirtyFlags = @import("../core/dirty.zig").DirtyFlags;
const Style = @import("../core/style.zig").Style;
const Edges = @import("../core/style.zig").Edges;
const Length = @import("../core/length.zig").Length;
const tree_mod = @import("../core/tree.zig");
const Node = tree_mod.Node;
const Text = @import("common.zig").Text;
const Label = @import("label.zig").Label;

pub const DragPhase = enum { begin, move, end };

/// Told about a tab being dragged: `index` is the tab's current position, (x, y)
/// the pointer in window coordinates. `move` repeats while the button is down;
/// `end` is the release.
pub const DragHook = struct {
    ctx: ?*anyopaque = null,
    call: *const fn (ctx: ?*anyopaque, panel: *TabPanel, index: usize, phase: DragPhase, x: f32, y: f32) void,

    pub const is_callback = true;

    /// `DragHook.bind(&app, App.onTabDrag)` where the function is
    /// `fn (*App, *TabPanel, usize, DragPhase, f32, f32) void`.
    pub fn bind(ctx: anytype, comptime f: anytype) DragHook {
        const Ptr = @TypeOf(ctx);
        return .{
            .ctx = @ptrCast(ctx),
            .call = &struct {
                fn thunk(c: ?*anyopaque, panel: *TabPanel, index: usize, phase: DragPhase, x: f32, y: f32) void {
                    f(@as(Ptr, @ptrCast(@alignCast(c.?))), panel, index, phase, x, y);
                }
            }.thunk,
        };
    }
};

const accent = Color.rgb(64, 140, 255);
const drag_threshold: f32 = 5;

const Page = struct {
    owner: *TabPanel,
    /// The node the app fills.
    node: Handle,
    /// This tab's node in the bar (rebuilt with the bar).
    tab: Handle = Handle.invalid,
    close: Handle = Handle.invalid,
    hovered: bool = false,
    close_hovered: bool = false,

    fn index(self: *const Page) usize {
        return self.owner.indexOfPage(self) orelse 0;
    }

    fn onClick(self: *Page, _: *event.Event) void {
        self.owner.activate(self.index(), true);
    }

    fn onHover(self: *Page, ev: *event.Event) void {
        self.hovered = ev.kind == .pointer_enter;
        self.owner.ui.tree.markDirty(self.tab, .{ .paint = true });
    }

    fn onCloseHover(self: *Page, ev: *event.Event) void {
        self.close_hovered = ev.kind == .pointer_enter;
        self.owner.ui.tree.markDirty(self.close, .{ .paint = true });
    }

    fn onCloseClick(self: *Page, ev: *event.Event) void {
        ev.stopPropagation();
        self.owner.closeTab(self.index());
    }

    fn onPointer(self: *Page, ev: *event.Event) void {
        self.owner.dragEvent(self, ev);
    }

    fn paintTab(self: *Page, pc: *PaintCtx) paint_ctx.Error!void {
        const active = self.owner.props.active == self.index();
        if (active) {
            try pc.box(.{ .background = Color.rgba(255, 255, 255, 30), .radius = 4 });
            const r = pc.rect;
            try pc.list.fillRect(.{ .x = r.x + 4, .y = r.bottom() - 2, .w = r.w - 8, .h = 2 }, draw_list.Paint.solid(accent));
        } else if (self.hovered) {
            try pc.box(.{ .background = Color.rgba(255, 255, 255, 16), .radius = 4 });
        }
    }

    fn paintClose(self: *Page, pc: *PaintCtx) paint_ctx.Error!void {
        const r = pc.rect;
        if (self.close_hovered) try pc.box(.{ .background = Color.rgba(255, 255, 255, 40), .radius = 3 });
        const tc = self.owner.ui.theme.text_color;
        const paint = draw_list.Paint.solid(Color.rgba(tc.r, tc.g, tc.b, 200));
        const cx = r.x + r.w / 2;
        const cy = r.y + r.h / 2;
        try pc.list.line(.{ .x = cx - 3, .y = cy - 3 }, .{ .x = cx + 3, .y = cy + 3 }, 1.4, paint);
        try pc.list.line(.{ .x = cx - 3, .y = cy + 3 }, .{ .x = cx + 3, .y = cy - 3 }, 1.4, paint);
    }
};

const Drag = struct {
    page: *Page,
    sx: f32,
    sy: f32,
    started: bool = false,
};

pub const TabPanel = struct {
    props: Props = .{},
    out: Out = .{},
    node: Handle,
    ui: *Ui,
    checker: shadow.Checker(Props),
    bar: Handle = Handle.invalid,
    body: Handle = Handle.invalid,
    pages: std.ArrayListUnmanaged(*Page) = .empty,
    /// The `props.titles` slice the bar was last built from.
    seen_titles: []const u8 = "",
    seen_closable: bool = false,
    bar_dirty: bool = true,
    drag: ?Drag = null,

    pub const Props = struct {
        /// The tab titles, one per line.
        titles: Text = .{},
        /// Index of the shown tab.
        active: u32 = 0,
        /// Each tab gets a close button.
        closable: bool = false,
        /// Closing a tab removes it (otherwise only `on_close` is called).
        close_removes: bool = true,
        /// The active tab changed (read `out.active`).
        on_change: ?event.Callback = null,
        /// A tab's close button was pressed (`out.closed_index` says which).
        on_close: ?event.Callback = null,
        /// Told about tab drags (see `DragHook`).
        drag_hook: ?DragHook = null,

        pub const ui = .{ .titles = .{ .multiline = true } };

        pub const dirty_map = .{
            .titles = shadow.Category.layout,
            .active = shadow.Category.layout,
            .closable = shadow.Category.layout,
            .close_removes = shadow.Category.none,
        };
    };

    pub const Out = struct {
        /// The user changed the active tab this frame.
        changed: bool = false,
        change_count: u32 = 0,
        /// A close button was pressed this frame.
        closed: bool = false,
        closed_index: u32 = 0,
        tab_count: u32 = 0,
    };

    pub const Options = struct {
        style: Style = .{},
        /// Tab titles (copied); each gets a page, see `pageNode`.
        titles: []const []const u8 = &.{},
        active: u32 = 0,
        closable: bool = false,
        close_removes: bool = true,
        on_change: ?event.Callback = null,
        on_close: ?event.Callback = null,
        drag_hook: ?DragHook = null,
    };

    pub const listened_kinds = [_]event.EventKind{};

    pub fn nodeTemplate(style: Style) Node {
        var s = style;
        s.direction = .column;
        return .{ .role = .panel, .style = s, .flags = .{ .clip_children = true } };
    }

    pub fn init(ui: *Ui, node: Handle) TabPanel {
        const props: Props = .{};
        return .{ .node = node, .ui = ui, .checker = shadow.Checker(Props).init(&props) };
    }

    pub fn deinit(self: *TabPanel) void {
        for (self.pages.items) |p| self.ui.gpa.destroy(p);
        self.pages.deinit(self.ui.gpa);
        self.ui.freeText(&self.props.titles);
    }

    pub fn apply(self: *TabPanel, o: Options) !void {
        self.props.active = o.active;
        self.props.closable = o.closable;
        self.props.close_removes = o.close_removes;
        self.props.on_change = o.on_change;
        self.props.on_close = o.on_close;
        self.props.drag_hook = o.drag_hook;
        const tree = &self.ui.tree;
        self.bar = try tree.create(.{
            .style = .{ .direction = .row, .gap = Length.px(2), .padding = .{ .left = Length.px(4), .top = Length.px(4), .right = Length.px(4) }, .shrink = 0 },
            .visual = .{ .background = Color.rgba(0, 0, 0, 50) },
        });
        errdefer _ = tree.destroySubtree(self.bar);
        try tree.appendChild(self.node, self.bar);
        try tree.setLabel(self.bar, "Tabs");
        try tree.addListener(self.bar, .{ .kind = .key_down, .callback = event.Callback.bind(self, onBarKey) });
        self.body = try tree.create(.{ .style = .{ .direction = .column, .grow = 1 } });
        errdefer _ = tree.destroySubtree(self.body);
        try tree.appendChild(self.node, self.body);
        if (o.titles.len > 0) {
            var joined: std.ArrayListUnmanaged(u8) = .empty;
            defer joined.deinit(self.ui.gpa);
            for (o.titles, 0..) |t, i| {
                if (i > 0) try joined.append(self.ui.gpa, '\n');
                try joined.appendSlice(self.ui.gpa, t);
            }
            try self.ui.replaceText(&self.props.titles, joined.items);
        }
        self.checker.sync(&self.props);
    }

    // ---- titles and pages ----

    fn lineCount(self: *const TabPanel) usize {
        const b = self.props.titles.bytes;
        return if (b.len == 0) 0 else std.mem.count(u8, b, "\n") + 1;
    }

    /// The title of tab `i`.
    pub fn title(self: *const TabPanel, i: usize) []const u8 {
        var it = std.mem.splitScalar(u8, self.props.titles.bytes, '\n');
        var n: usize = 0;
        while (it.next()) |line| : (n += 1) {
            if (n == i) return line;
        }
        return "";
    }

    pub fn tabCount(self: *const TabPanel) usize {
        return self.pages.items.len;
    }

    fn indexOfPage(self: *const TabPanel, p: *const Page) ?usize {
        for (self.pages.items, 0..) |q, i| {
            if (q == p) return i;
        }
        return null;
    }

    fn createPage(self: *TabPanel) !*Page {
        const gpa = self.ui.gpa;
        const page = try gpa.create(Page);
        errdefer gpa.destroy(page);
        const tree = &self.ui.tree;
        const node = try tree.create(.{ .style = .{ .direction = .column, .grow = 1 }, .role = .panel });
        errdefer _ = tree.destroySubtree(node);
        try tree.appendChild(self.body, node);
        page.* = .{ .owner = self, .node = node };
        try self.pages.append(gpa, page);
        self.bar_dirty = true;
        self.out.tab_count = @intCast(self.pages.items.len);
        return page;
    }

    /// Rewrite `props.titles` from `list` (each entry one title).
    fn setTitles(self: *TabPanel, list: []const []const u8) !void {
        var joined: std.ArrayListUnmanaged(u8) = .empty;
        defer joined.deinit(self.ui.gpa);
        for (list, 0..) |t, i| {
            if (i > 0) try joined.append(self.ui.gpa, '\n');
            try joined.appendSlice(self.ui.gpa, t);
        }
        try self.ui.replaceText(&self.props.titles, joined.items);
        self.bar_dirty = true;
        self.ui.tree.markDirty(self.node, .{ .layout = true, .paint = true });
    }

    fn titleList(self: *TabPanel, a: std.mem.Allocator) ![][]const u8 {
        const list = try a.alloc([]const u8, self.pages.items.len);
        for (list, 0..) |*t, i| t.* = self.title(i);
        return list;
    }

    /// Add a tab titled `name` at the end; returns its page node. A repeated
    /// or empty title is fine.
    pub fn addTab(self: *TabPanel, name: []const u8) !Handle {
        var arena = std.heap.ArenaAllocator.init(self.ui.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        const old = try self.titleList(a);
        const page = try self.createPage();
        errdefer self.removeTab(self.pages.items.len - 1);
        const list = try a.alloc([]const u8, old.len + 1);
        @memcpy(list[0..old.len], old);
        list[old.len] = if (name.len == 0) "Tab" else name;
        try self.setTitles(list);
        return page.node;
    }

    /// Insert an existing node as a new tab's page (used by docking to move a
    /// panel between tab groups). The node is re-parented into this panel.
    pub fn adoptTab(self: *TabPanel, name: []const u8, index: usize, content: Handle) !void {
        var arena = std.heap.ArenaAllocator.init(self.ui.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        const old = try self.titleList(a);
        const page = try self.createPage();
        errdefer self.removeTab(self.pages.items.len - 1);
        try self.ui.tree.appendChild(page.node, content);
        const at = @min(index, old.len);
        const list = try a.alloc([]const u8, old.len + 1);
        @memcpy(list[0..at], old[0..at]);
        list[at] = if (name.len == 0) "Tab" else name;
        @memcpy(list[at + 1 ..], old[at..]);
        try self.setTitles(list);
        // The page was created last; move it (and keep the order of titles).
        const last = self.pages.pop().?;
        try self.pages.insert(self.ui.gpa, at, last);
        const before = if (at + 1 < self.pages.items.len) self.pages.items[at + 1].node else Handle.invalid;
        try self.ui.tree.insertBefore(self.body, last.node, before);
        self.props.active = @intCast(at);
        self.out.tab_count = @intCast(self.pages.items.len);
    }

    /// Take the content out of tab `index`'s page (the first child) and
    /// remove the tab. Returns the content node, now parentless, or null.
    pub fn releaseTab(self: *TabPanel, index: usize) ?Handle {
        if (index >= self.pages.items.len) return null;
        const page = self.pages.items[index];
        const first = self.ui.tree.get(page.node).?.first_child;
        if (self.ui.tree.isValid(first)) self.ui.tree.detach(first);
        self.removeTab(index);
        return if (self.ui.tree.isValid(first)) first else null;
    }

    pub fn removeTab(self: *TabPanel, index: usize) void {
        if (index >= self.pages.items.len) return;
        var arena = std.heap.ArenaAllocator.init(self.ui.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        const titles = self.titleList(a) catch return;
        const page = self.pages.orderedRemove(index);
        _ = self.ui.tree.destroySubtree(page.node);
        self.ui.gpa.destroy(page);
        var list = std.ArrayListUnmanaged([]const u8).empty;
        for (titles, 0..) |t, i| {
            if (i != index) list.append(a, t) catch return;
        }
        self.setTitles(list.items) catch {};
        if (self.props.active > index or (self.props.active == index and self.props.active > 0 and self.props.active >= self.pages.items.len)) {
            self.props.active -|= 1;
        }
        self.out.tab_count = @intCast(self.pages.items.len);
        self.applyActive();
    }

    pub fn setTitle(self: *TabPanel, index: usize, name: []const u8) !void {
        if (index >= self.pages.items.len) return;
        var arena = std.heap.ArenaAllocator.init(self.ui.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        const list = try self.titleList(a);
        list[index] = name;
        try self.setTitles(list);
    }

    /// Move tab `from` so it ends up at position `to`.
    pub fn moveTab(self: *TabPanel, from: usize, to: usize) void {
        const n = self.pages.items.len;
        if (from >= n or to >= n or from == to) return;
        var arena = std.heap.ArenaAllocator.init(self.ui.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        const titles = self.titleList(a) catch return;
        const moved_title = titles[from];
        const page = self.pages.orderedRemove(from);
        self.pages.insert(self.ui.gpa, to, page) catch return;
        var list = std.ArrayListUnmanaged([]const u8).empty;
        for (titles, 0..) |t, i| {
            if (i != from) list.append(a, t) catch return;
        }
        list.insert(a, to, moved_title) catch return;
        // Re-order the tab nodes in the bar too, so a drag in progress keeps its node.
        const tree = &self.ui.tree;
        const before = if (to + 1 < n) self.pages.items[to + 1].tab else Handle.invalid;
        tree.insertBefore(self.bar, page.tab, before) catch {};
        tree.insertBefore(self.body, page.node, if (to + 1 < n) self.pages.items[to + 1].node else Handle.invalid) catch {};
        // Keep the active tab on the same page.
        const act: usize = self.props.active;
        if (act == from) self.props.active = @intCast(to) else if (from < act and to >= act) self.props.active -= 1 else if (from > act and to <= act) self.props.active += 1;
        // Update the titles text without rebuilding the bar.
        var joined: std.ArrayListUnmanaged(u8) = .empty;
        defer joined.deinit(self.ui.gpa);
        for (list.items, 0..) |t, i| {
            if (i > 0) joined.append(self.ui.gpa, '\n') catch return;
            joined.appendSlice(self.ui.gpa, t) catch return;
        }
        self.ui.replaceText(&self.props.titles, joined.items) catch return;
        self.seen_titles = self.props.titles.bytes;
        self.ui.tree.markDirty(self.bar, .{ .layout = true, .paint = true });
    }

    pub fn pageNode(self: *const TabPanel, index: usize) ?Handle {
        return if (index < self.pages.items.len) self.pages.items[index].node else null;
    }

    /// For UI documents: child `index` is page `index` (pages are created on demand).
    pub fn contentNodeAt(self: *TabPanel, index: usize) ?Handle {
        while (self.pages.items.len <= index) _ = self.createPage() catch return null;
        return self.pages.items[index].node;
    }

    pub fn activeTab(self: *const TabPanel) usize {
        return self.props.active;
    }

    /// Show tab `index` (does not call `on_change`).
    pub fn setActive(self: *TabPanel, index: usize) void {
        self.activate(index, false);
    }

    fn activate(self: *TabPanel, index: usize, by_user: bool) void {
        if (index >= self.pages.items.len) return;
        const changed = self.props.active != index;
        self.props.active = @intCast(index);
        self.applyActive();
        if (changed and by_user) {
            self.out.changed = true;
            self.out.change_count +%= 1;
            if (self.props.on_change) |cb| {
                var ev: event.Event = .{ .kind = .click, .target = self.node, .current = self.node };
                cb.invoke(&ev);
            }
        }
    }

    fn applyActive(self: *TabPanel) void {
        const n = self.pages.items.len;
        if (n > 0 and self.props.active >= n) self.props.active = @intCast(n - 1);
        for (self.pages.items, 0..) |p, i| {
            self.ui.setHidden(p.node, i != self.props.active);
            self.ui.tree.markDirty(p.tab, .{ .paint = true });
        }
        self.ui.tree.markDirty(self.node, .{ .layout = true, .paint = true });
    }

    fn closeTab(self: *TabPanel, index: usize) void {
        self.out.closed = true;
        self.out.closed_index = @intCast(index);
        if (self.props.on_close) |cb| {
            var ev: event.Event = .{ .kind = .click, .target = self.node, .current = self.node };
            cb.invoke(&ev);
        }
        if (self.props.close_removes) self.removeTab(index);
    }

    // ---- geometry ----

    /// Tab `i`'s rectangle in window coordinates (once laid out).
    pub fn tabRect(self: *TabPanel, i: usize) ?Rect {
        if (i >= self.pages.items.len) return null;
        return self.ui.tree.absoluteRect(self.pages.items[i].tab);
    }

    pub fn barRect(self: *TabPanel) ?Rect {
        return self.ui.tree.absoluteRect(self.bar);
    }

    /// The tab under a window point, if any.
    pub fn tabAt(self: *TabPanel, x: f32, y: f32) ?usize {
        for (0..self.pages.items.len) |i| {
            const r = self.tabRect(i) orelse continue;
            if (x >= r.x and x < r.right() and y >= r.y and y < r.bottom()) return i;
        }
        return null;
    }

    // ---- bar ----

    fn rebuildBar(self: *TabPanel) !void {
        const tree = &self.ui.tree;
        while (tree.get(self.bar).?.first_child.isNull() == false) {
            _ = tree.destroySubtree(tree.get(self.bar).?.first_child);
        }
        for (self.pages.items, 0..) |p, i| {
            p.hovered = false;
            p.close_hovered = false;
            const tab = try tree.create(.{ .style = .{
                .direction = .row,
                .align_items = .center,
                .gap = Length.px(6),
                .padding = Edges.xy(10, 5),
                .shrink = 0,
            } });
            try tree.appendChild(self.bar, tab);
            p.tab = tab;
            tree.get(tab).?.paint_hook = tree_mod.PaintHook.bind(p, Page.paintTab);
            _ = try self.ui.add(Label, tab, .{ .text = self.title(i) });
            p.close = Handle.invalid;
            if (self.props.closable) {
                const x = try tree.create(.{ .style = .{ .width = Length.px(14), .height = Length.px(14), .shrink = 0 } });
                try tree.appendChild(tab, x);
                p.close = x;
                tree.get(x).?.paint_hook = tree_mod.PaintHook.bind(p, Page.paintClose);
                try self.ui.makeClickable(x, .{ .label = "Close tab", .on_click = event.Callback.bind(p, Page.onCloseClick) });
                try tree.addListener(x, .{ .kind = .pointer_enter, .callback = event.Callback.bind(p, Page.onCloseHover) });
                try tree.addListener(x, .{ .kind = .pointer_leave, .callback = event.Callback.bind(p, Page.onCloseHover) });
            }
            try self.ui.makeClickable(tab, .{ .label = self.title(i), .on_click = event.Callback.bind(p, Page.onClick) });
            for ([_]event.EventKind{ .pointer_enter, .pointer_leave }) |k| {
                try tree.addListener(tab, .{ .kind = k, .callback = event.Callback.bind(p, Page.onHover) });
            }
            for ([_]event.EventKind{ .pointer_down, .pointer_move, .pointer_up }) |k| {
                try tree.addListener(tab, .{ .kind = k, .callback = event.Callback.bind(p, Page.onPointer) });
            }
        }
        tree.markDirty(self.bar, .{ .layout = true, .paint = true });
    }

    /// Bring pages and the bar up to date with `props.titles`. `Ui.update` calls
    /// this before reclaiming destroyed widgets (the bar's labels come and go).
    pub fn rebuildIfDirty(self: *TabPanel) void {
        if (!self.ui.tree.isValid(self.node)) return; // destroyed; not swept yet
        const titles = self.props.titles.bytes;
        const external = titles.ptr != self.seen_titles.ptr or titles.len != self.seen_titles.len;
        if (!self.bar_dirty and !external and self.seen_closable == self.props.closable) return;
        // Titles written from outside (a document, the inspector): one page per line.
        while (self.pages.items.len < self.lineCount()) _ = self.createPage() catch break;
        if (self.pages.items.len > self.lineCount()) {
            // Pages without a title (a document with more children than titles).
            var arena = std.heap.ArenaAllocator.init(self.ui.gpa);
            defer arena.deinit();
            const a = arena.allocator();
            const list = a.alloc([]const u8, self.pages.items.len) catch return;
            for (list, 0..) |*t, i| t.* = if (i < self.lineCount()) self.title(i) else std.fmt.allocPrint(a, "Tab {d}", .{i + 1}) catch "Tab";
            self.setTitles(list) catch return;
        }
        self.seen_titles = self.props.titles.bytes;
        self.seen_closable = self.props.closable;
        self.bar_dirty = false;
        self.rebuildBar() catch {};
        self.out.tab_count = @intCast(self.pages.items.len);
        self.applyActive();
    }

    fn onBarKey(self: *TabPanel, ev: *event.Event) void {
        if (ev.mods.any(.{ .ctrl = true, .alt = true, .gui = true })) return;
        const n = self.pages.items.len;
        if (n == 0) return;
        const cur = self.props.active;
        const next: usize = switch (ev.key) {
            .left => if (cur == 0) n - 1 else cur - 1,
            .right => (cur + 1) % n,
            else => return,
        };
        ev.markHandled();
        self.activate(next, true);
        self.ui.setFocus(self.pages.items[next].tab);
    }

    // ---- dragging tabs ----

    fn dragEvent(self: *TabPanel, page: *Page, ev: *event.Event) void {
        switch (ev.kind) {
            .pointer_down => if (ev.button == 1) {
                self.drag = .{ .page = page, .sx = ev.x, .sy = ev.y };
            },
            .pointer_move => {
                var d = self.drag orelse return;
                if (!d.started) {
                    if (std.math.hypot(ev.x - d.sx, ev.y - d.sy) < drag_threshold) return;
                    d.started = true;
                    self.drag = d;
                    self.callHook(d.page, .begin, ev);
                }
                // Reorder while the pointer is over the bar.
                if (self.barRect()) |br| {
                    if (ev.y >= br.y - 8 and ev.y < br.bottom() + 8) {
                        if (self.tabAt(ev.x, br.y + br.h / 2)) |over| {
                            const cur = self.indexOfPage(d.page) orelse return;
                            if (over != cur) self.moveTab(cur, over);
                        }
                    }
                }
                self.callHook(d.page, .move, ev);
            },
            .pointer_up => {
                const d = self.drag orelse return;
                self.drag = null;
                if (d.started) {
                    self.callHook(d.page, .end, ev);
                    ev.markHandled();
                }
            },
            else => {},
        }
    }

    fn callHook(self: *TabPanel, page: *Page, phase: DragPhase, ev: *event.Event) void {
        const hook = self.props.drag_hook orelse return;
        const i = self.indexOfPage(page) orelse return;
        hook.call(hook.ctx, self, i, phase, ev.x, ev.y);
    }

    // ---- widget plumbing ----

    pub fn handleEvent(self: *TabPanel, ev: *event.Event) void {
        _ = self;
        _ = ev;
    }

    pub fn paintHook(self: *TabPanel, pc: *PaintCtx) paint_ctx.Error!void {
        _ = self;
        _ = pc;
    }

    pub fn prepare(self: *TabPanel) void {
        _ = self;
    }

    pub fn update(self: *TabPanel) void {
        self.ui.verifyProps(self.node, &self.checker, &self.props, "tab_panel");
        const n = self.pages.items.len;
        if (n > 0) {
            // A prop edit (inspector, document) may have moved `active`.
            const want = self.props.active;
            const visible = for (self.pages.items, 0..) |p, i| {
                const hidden = self.ui.tree.get(p.node).?.flags.hidden;
                if (!hidden) break i;
            } else n;
            if (visible != @min(want, n - 1)) self.applyActive();
        }
    }

    pub fn endFrame(self: *TabPanel) void {
        self.out.changed = false;
        self.out.closed = false;
    }
};

// ---- tests -----------------------------------------------------------------

const testing = std.testing;
const Button = @import("button.zig").Button;

const Rig = struct {
    ui: Ui,
    cmds: [2048]draw_list.Command = undefined,
    glyphs: [1024]draw_list.Glyph = undefined,
    list: draw_list.DrawList = undefined,
    prop: @import("../text/font.zig").TestFont = .{},
    changes: u32 = 0,
    closes: u32 = 0,
    log: [16]struct { index: usize, phase: DragPhase } = undefined,
    log_n: usize = 0,

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
        try self.ui.layoutAndPaint(.{ .w = 400, .h = 300 }, &self.list);
        self.ui.endFrame();
    }

    fn onChange(self: *Rig, _: *event.Event) void {
        self.changes += 1;
    }

    fn onClose(self: *Rig, _: *event.Event) void {
        self.closes += 1;
    }

    fn onDrag(self: *Rig, _: *TabPanel, i: usize, phase: DragPhase, _: f32, _: f32) void {
        if (self.log_n < self.log.len) {
            self.log[self.log_n] = .{ .index = i, .phase = phase };
            self.log_n += 1;
        }
    }

    fn panel(self: *Rig, o: TabPanel.Options) !*TabPanel {
        var opts = o;
        opts.style = .{ .width = Length.px(300), .height = Length.px(200), .shrink = 0 };
        const t = try self.ui.add(TabPanel, self.ui.tree.root, opts);
        try self.frame();
        return t;
    }

    fn center(self: *Rig, h: Handle) [2]f32 {
        const r = self.ui.tree.absoluteRect(h).?;
        return .{ r.x + r.w / 2, r.y + r.h / 2 };
    }

    fn click(self: *Rig, x: f32, y: f32) !void {
        self.ui.pointerMove(x, y);
        self.ui.pointerButtonEx(x, y, 1, true, 1);
        self.ui.pointerButtonEx(x, y, 1, false, 1);
        try self.frame();
    }
};

fn shown(r: *Rig, t: *TabPanel, i: usize) bool {
    return !r.ui.tree.get(t.pageNode(i).?).?.flags.hidden;
}

test "tabs show one page at a time; clicking and Left/Right switch" {
    const r = try Rig.init();
    defer r.deinit();
    const t = try r.panel(.{ .titles = &.{ "One", "Two", "Three" }, .on_change = .bind(r, Rig.onChange) });
    try r.frame();
    try testing.expectEqual(@as(usize, 3), t.tabCount());
    try testing.expect(shown(r, t, 0) and !shown(r, t, 1) and !shown(r, t, 2));
    try testing.expectEqualStrings("Two", t.title(1));

    const second = r.center(t.pages.items[1].tab);
    try r.click(second[0], second[1]);
    try testing.expectEqual(@as(usize, 1), t.activeTab());
    try testing.expect(!shown(r, t, 0) and shown(r, t, 1));
    try testing.expectEqual(@as(u32, 1), r.changes);

    r.ui.setFocus(t.pages.items[1].tab);
    r.ui.key(.right, .{}, true, false);
    try testing.expectEqual(@as(usize, 2), t.activeTab());
    r.ui.key(.right, .{}, true, false); // wraps
    try testing.expectEqual(@as(usize, 0), t.activeTab());
    r.ui.key(.left, .{}, true, false);
    try testing.expectEqual(@as(usize, 2), t.activeTab());
    try r.frame();
    try testing.expect(shown(r, t, 2) and !shown(r, t, 0));
    // setActive is silent.
    const before = r.changes;
    t.setActive(1);
    try testing.expectEqual(before, r.changes);
}

test "addTab returns a page to fill; titles stay in props; remove and rename" {
    const r = try Rig.init();
    defer r.deinit();
    const t = try r.panel(.{});
    const a = try t.addTab("Files");
    const b = try t.addTab("Search");
    _ = try r.ui.add(Label, a, .{ .text = "in files" });
    _ = try r.ui.add(Label, b, .{ .text = "in search" });
    try r.frame();
    try testing.expectEqualStrings("Files\nSearch", t.props.titles.bytes);
    try testing.expect(shown(r, t, 0) and !shown(r, t, 1));
    try t.setTitle(1, "Find");
    try r.frame();
    try testing.expectEqualStrings("Find", t.title(1));

    t.setActive(1);
    t.removeTab(1);
    try r.frame();
    try testing.expectEqual(@as(usize, 1), t.tabCount());
    try testing.expectEqual(@as(usize, 0), t.activeTab());
    try testing.expect(shown(r, t, 0));
    try testing.expectEqualStrings("Files", t.props.titles.bytes);
}

test "closable tabs have a close button that removes the tab and reports it" {
    const r = try Rig.init();
    defer r.deinit();
    const t = try r.panel(.{ .titles = &.{ "A", "B" }, .closable = true, .on_close = .bind(r, Rig.onClose) });
    try r.frame();
    const x = r.center(t.pages.items[0].close);
    try r.click(x[0], x[1]);
    try testing.expectEqual(@as(u32, 1), r.closes);
    try testing.expectEqual(@as(usize, 1), t.tabCount());
    try testing.expectEqualStrings("B", t.title(0));
    try r.frame();
    try testing.expect(t.out.tab_count == 1);
}

test "dragging a tab along the bar reorders it and keeps the same page active" {
    const r = try Rig.init();
    defer r.deinit();
    const t = try r.panel(.{ .titles = &.{ "A", "B", "C" }, .drag_hook = .bind(r, Rig.onDrag) });
    try r.frame();
    const page_a = t.pages.items[0].node;
    const from = r.center(t.pages.items[0].tab);
    const to = r.center(t.pages.items[2].tab);
    r.ui.pointerMove(from[0], from[1]);
    r.ui.pointerButtonEx(from[0], from[1], 1, true, 1);
    for (1..7) |i| {
        const f = @as(f32, @floatFromInt(i)) / 6;
        r.ui.pointerMove(from[0] + (to[0] - from[0]) * f, from[1]);
        try r.frame();
    }
    r.ui.pointerButtonEx(to[0], to[1], 1, false, 1);
    try r.frame();
    try testing.expectEqualStrings("B\nC\nA", t.props.titles.bytes);
    try testing.expect(t.pages.items[2].node.eql(page_a));
    try testing.expectEqual(@as(usize, 2), t.activeTab()); // "A" was active and moved with its page
    try testing.expect(shown(r, t, 2));
    // The hook saw begin, moves, and end.
    try testing.expect(r.log_n >= 3);
    try testing.expect(r.log[0].phase == .begin and r.log[r.log_n - 1].phase == .end);
    try testing.expect(r.log[r.log_n - 1].index == 2);
}

test "pages are created on demand for documents, and titles pad to the page count" {
    const r = try Rig.init();
    defer r.deinit();
    const t = try r.panel(.{ .titles = &.{"Only"} });
    _ = t.contentNodeAt(2).?; // a document with three children
    try r.frame();
    try r.frame();
    try testing.expectEqual(@as(usize, 3), t.tabCount());
    try testing.expectEqualStrings("Only\nTab 2\nTab 3", t.props.titles.bytes);
}

test "adoptTab and releaseTab move content between panels" {
    const r = try Rig.init();
    defer r.deinit();
    const a = try r.panel(.{ .titles = &.{"x"} });
    const b = try r.panel(.{});
    const content = try r.ui.add(Label, a.pageNode(0).?, .{ .text = "moved" });
    try r.frame();
    const h = a.releaseTab(0).?;
    try testing.expectEqual(@as(usize, 0), a.tabCount());
    try b.adoptTab("Moved", 0, h);
    try r.frame();
    try testing.expectEqual(@as(usize, 1), b.tabCount());
    try testing.expectEqualStrings("Moved", b.title(0));
    try testing.expect(r.ui.tree.get(h).?.parent.eql(b.pageNode(0).?));
    try testing.expectEqualStrings("moved", content.props.text.bytes);
}
