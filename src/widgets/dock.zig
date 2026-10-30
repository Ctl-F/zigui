//! Dock: panels you can arrange. Panels sit in tabbed groups, groups sit in
//! resizable splits, and any panel (or whole group) can be dragged to another
//! group (as a tab, or to an edge to split it), floated into a window of its own
//! inside the dock, and dragged back in.
//!
//!     const dock = try Dock.create(&ui, parent, .{ .style = .{ .width = .fill, .height = .fill } });
//!     defer dock.destroy();
//!     const files = try dock.addPanel("Files");           // files.content is yours to fill
//!     const editor = try dock.addPanel("Editor");
//!     try dock.dockTab(editor, null);                      // the first group
//!     try dock.dockSplit(files, editor, .left, 220);       // a column at the left
//!
//! Dragging a tab: over a group's middle drops it in as a tab, over an edge
//! splits that group, Shift held floats it where it was dropped, and dropping
//! outside the dock floats it too. A floating window has a title strip to drag
//! (drop it on a group to dock all its tabs) and a handle to resize. Right-click
//! a tab for Float / Close. Closed panels are hidden, not destroyed; bring them
//! back with `showPanel`. The layout lives in a model that is rebuilt into
//! `TabPanel`s and `SplitView`s after each change; panel contents are re-parented
//! and keep their state.

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
const Style = @import("../core/style.zig").Style;
const Edges = @import("../core/style.zig").Edges;
const Length = @import("../core/length.zig").Length;
const tree_mod = @import("../core/tree.zig");
const Label = @import("label.zig").Label;
const SplitView = @import("split_view.zig").SplitView;
const tab_panel = @import("tab_panel.zig");
const TabPanel = tab_panel.TabPanel;
const menu = @import("menu.zig");
const shadow = @import("../core/shadow.zig");
const Text = @import("common.zig").Text;
const DirtyFlags = @import("../core/dirty.zig").DirtyFlags;

pub const Side = enum { left, right, top, bottom };

pub const State = enum { hidden, docked, floating };

/// Asked when the user closes a panel (the tab's x, or "Close" in its menu).
/// Return true if the host took care of it (hid it, destroyed it later, or
/// refused); return false to let the dock hide the panel. Do not destroy the
/// panel from inside the hook; queue it and do it from your loop.
pub const CloseHook = struct {
    ctx: ?*anyopaque = null,
    call: *const fn (ctx: ?*anyopaque, panel: *Panel) bool,

    pub fn bind(ctx: anytype, comptime f: anytype) CloseHook {
        const Ptr = @TypeOf(ctx);
        return .{
            .ctx = @ptrCast(ctx),
            .call = &struct {
                fn thunk(c: ?*anyopaque, panel: *Panel) bool {
                    return f(@as(Ptr, @ptrCast(@alignCast(c.?))), panel);
                }
            }.thunk,
        };
    }
};

const accent = Color.rgb(64, 140, 255);
const float_bg = Color.rgb(0x2b, 0x2d, 0x31);
const float_border = Color.rgb(0x4a, 0x4d, 0x52);
const strip_h: f32 = 22;
const min_float = 120;

pub const Panel = struct {
    dock: *Dock,
    title: []u8,
    /// The node holding the panel's contents; it is yours to fill.
    content: Handle,
    state: State = .hidden,
    /// The group (docked or floating) the panel is in, if any.
    group: ?*Node = null,
    /// The last group it was docked in, to come back to.
    last_group: ?*Node = null,
    /// Yours.
    user: usize = 0,
};

const Node = struct {
    dock: *Dock,
    parent: ?*Node = null,
    is_split: bool = false,
    // group
    panels: std.ArrayListUnmanaged(*Panel) = .empty,
    active: usize = 0,
    tabs: ?*TabPanel = null,
    float: ?*Float = null,
    // split
    vertical: bool = false,
    a: ?*Node = null,
    b: ?*Node = null,
    size: f32 = 240,
    /// `size` is the second pane's size.
    anchor_second: bool = false,
    split: ?*SplitView = null,

    fn onTabDrag(self: *Node, _: *TabPanel, index: usize, phase: tab_panel.DragPhase, x: f32, y: f32) void {
        self.dock.tabDrag(self, index, phase, x, y);
    }

    fn onChange(self: *Node, _: *event.Event) void {
        if (self.tabs) |t| self.active = t.activeTab();
    }

    fn onClose(self: *Node, _: *event.Event) void {
        const t = self.tabs orelse return;
        const i = t.out.closed_index;
        if (i < self.panels.items.len) self.dock.requestClose(self.panels.items[i]);
    }

    fn onBarPointer(self: *Node, ev: *event.Event) void {
        if (ev.button != 3) return;
        const t = self.tabs orelse return;
        const i = t.tabAt(ev.x, ev.y) orelse return;
        if (i >= self.panels.items.len) return;
        self.dock.tabMenu(self.panels.items[i], ev.x, ev.y);
    }
};

const Float = struct {
    dock: *Dock,
    group: *Node,
    rect: Rect,
    frame: Handle = Handle.invalid,
    strip: Handle = Handle.invalid,
    grip: Handle = Handle.invalid,
    title: ?*Label = null,
    drag: ?struct { dx: f32, dy: f32 } = null,
    resize: ?struct { sx: f32, sy: f32, w: f32, h: f32 } = null,

    fn onFrame(self: *Float, ev: *event.Event) void {
        // Raise it on any press.
        if (ev.kind == .pointer_down) self.dock.raise(self);
    }

    fn onStrip(self: *Float, ev: *event.Event) void {
        switch (ev.kind) {
            .pointer_down => if (ev.button == 1) {
                self.drag = .{ .dx = ev.x - self.rect.x, .dy = ev.y - self.rect.y };
                self.dock.raise(self);
            },
            .pointer_move => if (self.drag) |d| {
                self.rect.x = ev.x - d.dx;
                self.rect.y = ev.y - d.dy;
                self.dock.applyFloatRect(self);
                self.dock.setDrop(self.dock.computeDrop(ev.x, ev.y, self.group.panels.items, self.group));
            },
            .pointer_up => if (self.drag != null) {
                self.drag = null;
                self.dock.floatDragEnd(self, ev.x, ev.y);
            },
            else => {},
        }
    }

    fn onGrip(self: *Float, ev: *event.Event) void {
        switch (ev.kind) {
            .pointer_down => if (ev.button == 1) {
                self.resize = .{ .sx = ev.x, .sy = ev.y, .w = self.rect.w, .h = self.rect.h };
                self.dock.raise(self);
            },
            .pointer_move => if (self.resize) |r| {
                self.rect.w = @max(r.w + (ev.x - r.sx), min_float);
                self.rect.h = @max(r.h + (ev.y - r.sy), min_float);
                self.dock.applyFloatRect(self);
            },
            .pointer_up => self.resize = null,
            else => {},
        }
    }

    fn paintGrip(self: *Float, pc: *PaintCtx) paint_ctx.Error!void {
        _ = self;
        const r = pc.rect;
        const paint = draw_list.Paint.solid(Color.rgba(255, 255, 255, 90));
        try pc.list.line(.{ .x = r.right() - 3, .y = r.bottom() - 9 }, .{ .x = r.right() - 9, .y = r.bottom() - 3 }, 1.2, paint);
        try pc.list.line(.{ .x = r.right() - 3, .y = r.bottom() - 5 }, .{ .x = r.right() - 5, .y = r.bottom() - 3 }, 1.2, paint);
    }
};

const Zone = enum { tab, left, right, top, bottom };

const Drop = struct {
    /// The group dropped on (null: the empty dock, or floating).
    group: ?*Node,
    zone: Zone,
    /// Float the panels instead.
    float: bool = false,
    preview: Rect = .{},
    /// Position among the target's tabs.
    index: usize = std.math.maxInt(usize),
};

pub const Dock = struct {
    props: Props = .{},
    out: Out = .{},
    node: Handle,
    ui: *Ui,
    checker: shadow.Checker(Props),
    gpa: std.mem.Allocator,
    /// The dock's own node (`node`).
    host: Handle,
    area: Handle = Handle.invalid,
    root: ?*Node = null,
    floats: std.ArrayListUnmanaged(*Float) = .empty,
    panels: std.ArrayListUnmanaged(*Panel) = .empty,
    drop: ?Drop = null,
    /// The tab drag in progress: the panels being dragged and where they came from.
    dragging: std.ArrayListUnmanaged(*Panel) = .empty,
    drag_src: ?*Node = null,
    /// The panel a tab context menu is open for.
    menu_panel: ?*Panel = null,
    /// The `props.titles` slice the panels' names were last taken from.
    seen_titles: []const u8 = "",
    /// Set while `contentNodeAt` or title syncing is adding panels.
    syncing: bool = false,
    /// Consulted when the user closes a panel (see `CloseHook`).
    close_hook: ?CloseHook = null,

    pub const Props = struct {
        /// For documents: the panels' titles, one per line. Each child of a
        /// `dock` node is a panel, first docked together as tabs.
        titles: Text = .{},

        pub const ui = .{ .titles = .{ .multiline = true } };

        pub const dirty_map = .{
            .titles = shadow.Category.layout,
        };
    };

    pub const Out = struct {
        panel_count: u32 = 0,
    };

    pub const Options = struct {
        style: Style = .{},
        /// Panels to create up front (see `panels`); you still dock them.
        titles: []const []const u8 = &.{},
    };

    pub const listened_kinds = [_]event.EventKind{};

    pub fn nodeTemplate(style: Style) tree_mod.Node {
        var s = style;
        s.direction = .column;
        return .{ .role = .panel, .style = s };
    }

    pub fn init(ui: *Ui, node: Handle) Dock {
        const props: Props = .{};
        return .{ .node = node, .ui = ui, .gpa = ui.gpa, .host = node, .checker = shadow.Checker(Props).init(&props) };
    }

    pub fn apply(self: *Dock, o: Options) !void {
        const tree = &self.ui.tree;
        try tree.setLabel(self.node, "Dock");
        self.area = try tree.create(.{ .style = .{ .direction = .column, .grow = 1 } });
        errdefer _ = tree.destroySubtree(self.area);
        try tree.appendChild(self.node, self.area);
        tree.get(self.node).?.overlay_hook = tree_mod.PaintHook.bind(self, paintOverlay);
        if (o.titles.len > 0) {
            var joined: std.ArrayListUnmanaged(u8) = .empty;
            defer joined.deinit(self.gpa);
            for (o.titles, 0..) |t, i| {
                if (i > 0) try joined.append(self.gpa, '\n');
                try joined.appendSlice(self.gpa, t);
            }
            try self.ui.replaceText(&self.props.titles, joined.items);
        }
        self.checker.sync(&self.props);
    }

    /// Make a dock under `parent` (shorthand for `ui.add(Dock, parent, opts)`).
    pub fn create(ui: *Ui, parent: Handle, opts: Options) !*Dock {
        return ui.add(Dock, parent, opts);
    }

    /// Remove the dock and its panels' contents. The dock's memory is released
    /// at the next `Ui.update`.
    pub fn destroy(self: *Dock) void {
        self.ui.closeMenu();
        _ = self.ui.tree.destroySubtree(self.node);
    }

    pub fn deinit(self: *Dock) void {
        // Hidden panels' contents have no parent: free them with the panels.
        for (self.panels.items) |p| self.freePanel(p);
        self.panels.deinit(self.gpa);
        self.dragging.deinit(self.gpa);
        for (self.floats.items) |f| self.gpa.destroy(f);
        self.floats.deinit(self.gpa);
        if (self.root) |r| self.freeNode(r);
        self.ui.freeText(&self.props.titles);
    }

    // ---- documents: children are panels ----

    /// For UI documents: child `index` is panel `index` (created and docked as
    /// a tab in the first group on demand).
    pub fn contentNodeAt(self: *Dock, index: usize) ?Handle {
        while (self.panels.items.len <= index) {
            const i = self.panels.items.len;
            var name_buf: [24]u8 = undefined;
            const name = self.titleLine(i) orelse (std.fmt.bufPrint(&name_buf, "Panel {d}", .{i + 1}) catch "Panel");
            const p = self.addPanel(name) catch return null;
            self.dockTab(p, null) catch return null;
        }
        return self.panels.items[index].content;
    }

    fn titleLine(self: *const Dock, i: usize) ?[]const u8 {
        var it = std.mem.splitScalar(u8, self.props.titles.bytes, '\n');
        var n: usize = 0;
        while (it.next()) |line| : (n += 1) {
            if (n == i) return if (line.len > 0) line else null;
        }
        return null;
    }

    /// Keep panel names in step with `props.titles` (a document, the inspector).
    /// `Ui.update` calls this before reclaiming destroyed widgets.
    pub fn rebuildIfDirty(self: *Dock) void {
        if (!self.ui.tree.isValid(self.node)) return;
        const t = self.props.titles.bytes;
        if (t.ptr == self.seen_titles.ptr and t.len == self.seen_titles.len) return;
        self.seen_titles = t;
        var changed = false;
        for (self.panels.items, 0..) |p, i| {
            const line = self.titleLine(i) orelse continue;
            if (std.mem.eql(u8, p.title, line)) continue;
            const copy = self.gpa.dupe(u8, line) catch continue;
            self.gpa.free(p.title);
            p.title = copy;
            changed = true;
        }
        // Titles for panels that have no content yet.
        var i = self.panels.items.len;
        while (self.titleLine(i) != null) : (i += 1) {
            _ = self.contentNodeAt(i);
            changed = true;
        }
        if (changed) self.rebuild() catch {};
        self.out.panel_count = @intCast(self.panels.items.len);
    }

    pub fn handleEvent(self: *Dock, ev: *event.Event) void {
        _ = self;
        _ = ev;
    }

    pub fn paintHook(self: *Dock, pc: *PaintCtx) paint_ctx.Error!void {
        _ = self;
        _ = pc;
    }

    pub fn prepare(self: *Dock) void {
        _ = self;
    }

    pub fn update(self: *Dock) void {
        self.ui.verifyProps(self.node, &self.checker, &self.props, "dock");
    }

    pub fn endFrame(self: *Dock) void {
        _ = self;
    }

    fn freePanel(self: *Dock, p: *Panel) void {
        // A hidden panel's content has no parent: free it with the panel.
        if (self.ui.tree.isValid(p.content)) {
            const n = self.ui.tree.get(p.content).?;
            if (n.parent.isNull()) _ = self.ui.tree.destroySubtree(p.content);
        }
        self.gpa.free(p.title);
        self.gpa.destroy(p);
    }

    fn freeNode(self: *Dock, n: *Node) void {
        if (n.a) |a| self.freeNode(a);
        if (n.b) |b| self.freeNode(b);
        n.panels.deinit(self.gpa);
        self.gpa.destroy(n);
    }

    fn newNode(self: *Dock) !*Node {
        const n = try self.gpa.create(Node);
        n.* = .{ .dock = self };
        return n;
    }

    // ---- panels ----

    /// A new panel (hidden until docked). Fill `panel.content`.
    pub fn addPanel(self: *Dock, title: []const u8) !*Panel {
        const p = try self.gpa.create(Panel);
        errdefer self.gpa.destroy(p);
        const t = try self.gpa.dupe(u8, title);
        errdefer self.gpa.free(t);
        const content = try self.ui.tree.create(.{ .style = .{ .direction = .column, .grow = 1 }, .role = .panel });
        errdefer _ = self.ui.tree.destroySubtree(content);
        p.* = .{ .dock = self, .title = t, .content = content };
        try self.panels.append(self.gpa, p);
        return p;
    }

    pub fn state(self: *const Dock, p: *const Panel) State {
        _ = self;
        return p.state;
    }

    /// Show `panel` as a tab in `near`'s group (or the first group, or a new
    /// root group when the dock is empty).
    pub fn dockTab(self: *Dock, panel: *Panel, near: ?*Panel) !void {
        self.takeOut(panel);
        var g: ?*Node = null;
        if (near) |n| {
            g = n.group;
            if (g == null) {
                if (n.last_group) |lg| {
                    if (self.isLive(lg)) g = lg;
                }
            }
        }
        if (g == null) g = self.firstGroup();
        if (g == null) {
            const n = try self.newNode();
            self.root = n;
            g = n;
        }
        try self.addToGroup(g.?, panel, std.math.maxInt(usize));
        try self.rebuild();
    }

    /// Dock `panel` in a new group beside `near`'s group, on `side`; `size` is
    /// the new group's size in pixels along the split.
    pub fn dockSplit(self: *Dock, panel: *Panel, near: *Panel, side: Side, size: f32) !void {
        const target = near.group orelse return error.NotDocked;
        if (target.float != null) return error.NotDocked;
        self.takeOut(panel);
        try self.splitAt(target, &.{panel}, side, size);
        try self.rebuild();
    }

    /// Dock `panel` in a new group along one whole side of the dock (beside
    /// every other group); `size` is its size in pixels.
    pub fn dockRoot(self: *Dock, panel: *Panel, side: Side, size: f32) !void {
        self.takeOut(panel);
        const target = self.root orelse {
            const n = try self.newNode();
            self.root = n;
            try self.addToGroup(n, panel, std.math.maxInt(usize));
            return self.rebuild();
        };
        try self.splitAt(target, &.{panel}, side, size);
        try self.rebuild();
    }

    /// Float `panel` in a window of its own at `rect` (dock coordinates).
    pub fn floatPanel(self: *Dock, panel: *Panel, rect: Rect) !void {
        self.takeOut(panel);
        try self.makeFloat(&.{panel}, rect);
        try self.rebuild();
    }

    /// Bring `panel` forward if it is a tab of a group.
    pub fn activatePanel(self: *Dock, panel: *Panel) void {
        _ = self;
        const g = panel.group orelse return;
        const i = std.mem.indexOfScalar(*Panel, g.panels.items, panel) orelse return;
        g.active = i;
        if (g.tabs) |t| t.setActive(i);
    }

    /// What the user's close gesture does: ask `close_hook`, else hide the panel.
    pub fn requestClose(self: *Dock, panel: *Panel) void {
        if (self.close_hook) |h| {
            if (h.call(h.ctx, panel)) return;
        }
        self.closePanel(panel);
    }

    /// Rename a panel (its tab updates without rebuilding the dock).
    pub fn setTitle(self: *Dock, panel: *Panel, title: []const u8) !void {
        const t = try self.gpa.dupe(u8, title);
        self.gpa.free(panel.title);
        panel.title = t;
        const g = panel.group orelse return;
        const i = std.mem.indexOfScalar(*Panel, g.panels.items, panel) orelse return;
        if (g.tabs) |tabs| try tabs.setTitle(i, t);
    }

    /// Hide `panel` (its contents stay alive; `showPanel` brings it back).
    pub fn closePanel(self: *Dock, panel: *Panel) void {
        self.takeOut(panel);
        self.rebuild() catch {};
    }

    /// Dock a hidden panel again where it last was (or the first group).
    pub fn showPanel(self: *Dock, panel: *Panel) !void {
        if (panel.state != .hidden) return;
        var near: ?*Panel = null;
        if (panel.last_group) |g| {
            if (self.isLive(g) and g.panels.items.len > 0) near = g.panels.items[0];
        }
        try self.dockTab(panel, near);
    }

    /// Remove `panel` for good and destroy its contents.
    pub fn destroyPanel(self: *Dock, panel: *Panel) void {
        self.takeOut(panel);
        if (std.mem.indexOfScalar(*Panel, self.panels.items, panel)) |i| _ = self.panels.orderedRemove(i);
        self.rebuild() catch {};
        _ = self.ui.tree.destroySubtree(panel.content);
        panel.content = Handle.invalid;
        self.freePanel(panel);
    }

    pub fn panelNamed(self: *const Dock, title: []const u8) ?*Panel {
        for (self.panels.items) |p| {
            if (std.mem.eql(u8, p.title, title)) return p;
        }
        return null;
    }

    // ---- the model ----

    fn isLive(self: *Dock, g: *Node) bool {
        if (self.root) |r| {
            if (nodeContains(r, g)) return true;
        }
        for (self.floats.items) |f| {
            if (f.group == g) return true;
        }
        return false;
    }

    fn nodeContains(n: *Node, target: *Node) bool {
        if (n == target) return true;
        if (n.a) |a| if (nodeContains(a, target)) return true;
        if (n.b) |b| if (nodeContains(b, target)) return true;
        return false;
    }

    fn firstGroup(self: *Dock) ?*Node {
        const r = self.root orelse return null;
        return firstGroupIn(r);
    }

    fn firstGroupIn(n: *Node) ?*Node {
        if (!n.is_split) return n;
        if (n.a) |a| if (firstGroupIn(a)) |g| return g;
        if (n.b) |b| if (firstGroupIn(b)) |g| return g;
        return null;
    }

    fn addToGroup(self: *Dock, g: *Node, p: *Panel, index: usize) !void {
        const at = @min(index, g.panels.items.len);
        try g.panels.insert(self.gpa, at, p);
        g.active = at;
        p.group = g;
        p.last_group = g;
        p.state = if (g.float != null) .floating else .docked;
    }

    /// Remove `p` from its group (collapsing an empty group) and hide it.
    fn takeOut(self: *Dock, p: *Panel) void {
        const g = p.group orelse {
            p.state = .hidden;
            return;
        };
        if (std.mem.indexOfScalar(*Panel, g.panels.items, p)) |i| {
            _ = g.panels.orderedRemove(i);
            if (g.active >= g.panels.items.len and g.active > 0) g.active = g.panels.items.len - 1;
        }
        p.group = null;
        p.state = .hidden;
        if (g.panels.items.len == 0) self.collapse(g);
    }

    /// An empty group goes away; its parent split is replaced by the sibling.
    fn collapse(self: *Dock, g: *Node) void {
        // Panels that remember this group as their last home must forget it.
        for (self.panels.items) |p| {
            if (p.last_group == g) p.last_group = null;
        }
        if (g.float) |f| {
            if (std.mem.indexOfScalar(*Float, self.floats.items, f)) |i| _ = self.floats.orderedRemove(i);
            self.destroyFloatWidgets(f);
            self.gpa.destroy(f);
            g.panels.deinit(self.gpa);
            self.gpa.destroy(g);
            return;
        }
        const p = g.parent orelse {
            if (self.root == g) self.root = null;
            g.panels.deinit(self.gpa);
            self.gpa.destroy(g);
            return;
        };
        const sibling = if (p.a == g) p.b.? else p.a.?;
        sibling.parent = p.parent;
        self.replaceChild(p, sibling);
        g.panels.deinit(self.gpa);
        self.gpa.destroy(g);
        self.gpa.destroy(p);
    }

    /// Put `new` where `old` is in the tree.
    fn replaceChild(self: *Dock, old: *Node, new: *Node) void {
        if (old.parent) |pp| {
            if (pp.a == old) pp.a = new else pp.b = new;
        } else if (self.root == old) {
            self.root = new;
        }
    }

    fn splitAt(self: *Dock, target: *Node, panels: []const *Panel, side: Side, size: f32) !void {
        const g = try self.newNode();
        errdefer self.gpa.destroy(g);
        const sp = try self.newNode();
        errdefer self.gpa.destroy(sp);
        for (panels) |p| try self.addToGroup(g, p, std.math.maxInt(usize));
        sp.is_split = true;
        sp.vertical = side == .top or side == .bottom;
        const new_first = side == .left or side == .top;
        sp.a = if (new_first) g else target;
        sp.b = if (new_first) target else g;
        sp.size = size;
        sp.anchor_second = !new_first;
        sp.parent = target.parent;
        self.replaceChild(target, sp);
        target.parent = sp;
        g.parent = sp;
    }

    /// A group's size along an axis. Before it has been laid out (panels docked
    /// in a row without a frame in between) fall back to the dock's own size,
    /// or a plain default.
    fn groupExtent(self: *Dock, g: *Node, vertical: bool) f32 {
        if (g.tabs) |t| {
            if (self.ui.tree.absoluteRect(t.node)) |r| {
                const v = if (vertical) r.h else r.w;
                if (v > 0) return v;
            }
        }
        const h = self.hostRect();
        const v = if (vertical) h.h else h.w;
        if (v > 0) return v;
        const root = self.ui.tree.get(self.ui.tree.root).?.rect;
        const rv = if (vertical) root.h else root.w;
        return if (rv > 0) rv else 800;
    }

    fn makeFloat(self: *Dock, panels: []const *Panel, rect: Rect) !void {
        const f = try self.gpa.create(Float);
        errdefer self.gpa.destroy(f);
        const g = try self.newNode();
        errdefer self.gpa.destroy(g);
        g.float = f;
        f.* = .{ .dock = self, .group = g, .rect = rect };
        try self.floats.append(self.gpa, f);
        for (panels) |p| try self.addToGroup(g, p, std.math.maxInt(usize));
    }

    // ---- building the widgets from the model ----

    /// Remember sizes and active tabs the user changed since the last build.
    fn capture(self: *Dock) void {
        if (self.root) |r| captureNode(r);
        for (self.floats.items) |f| captureNode(f.group);
    }

    fn captureNode(n: *Node) void {
        if (n.split) |s| n.size = s.props.first_size;
        if (n.a) |a| captureNode(a);
        if (n.b) |b| captureNode(b);
    }

    fn clearWidgets(n: *Node) void {
        n.tabs = null;
        n.split = null;
        if (n.a) |a| clearWidgets(a);
        if (n.b) |b| clearWidgets(b);
    }

    fn destroyFloatWidgets(self: *Dock, f: *Float) void {
        _ = self.ui.tree.destroySubtree(f.frame);
        f.frame = Handle.invalid;
    }

    /// Regenerate the widget tree from the model.
    pub fn rebuild(self: *Dock) !void {
        self.capture();
        const tree = &self.ui.tree;
        // Take the contents out so tearing the old widgets down spares them.
        for (self.panels.items) |p| {
            if (tree.isValid(p.content)) tree.detach(p.content);
        }
        // Destroy the old widgets.
        // (Destruction is deferred while an event is being dispatched, so walk the
        // children once instead of waiting for the first one to disappear.)
        var child = tree.get(self.area).?.first_child;
        while (tree.get(child)) |cn| {
            const next = cn.next;
            _ = tree.destroySubtree(child);
            child = next;
        }
        for (self.floats.items) |f| {
            if (tree.isValid(f.frame)) _ = tree.destroySubtree(f.frame);
            f.frame = Handle.invalid;
            clearWidgets(f.group);
        }
        if (self.root) |r| clearWidgets(r);

        if (self.root) |r| try self.buildNode(r, self.area);
        for (self.floats.items) |f| try self.buildFloat(f);
        tree.markDirty(self.host, .{ .layout = true, .paint = true });
    }

    fn buildNode(self: *Dock, n: *Node, parent: Handle) !void {
        if (n.is_split) {
            const sv = try self.ui.add(SplitView, parent, .{
                .style = .{ .width = .fill, .height = .fill },
                .vertical = n.vertical,
                .first_size = n.size,
                .anchor_second = n.anchor_second,
                .min_first = 80,
                .min_second = 80,
                .divider_size = 6,
            });
            n.split = sv;
            try self.buildNode(n.a.?, sv.firstNode());
            try self.buildNode(n.b.?, sv.secondNode());
            return;
        }
        try self.buildGroup(n, parent);
    }

    fn buildGroup(self: *Dock, n: *Node, parent: Handle) !void {
        const t = try self.ui.add(TabPanel, parent, .{
            .style = .{ .width = .fill, .height = .fill },
            .closable = true,
            .close_removes = false,
            .on_change = event.Callback.bind(n, Node.onChange),
            .on_close = event.Callback.bind(n, Node.onClose),
            .drag_hook = tab_panel.DragHook.bind(n, Node.onTabDrag),
        });
        n.tabs = t;
        try self.ui.tree.addListener(t.bar, .{ .kind = .pointer_down, .callback = event.Callback.bind(n, Node.onBarPointer) });
        for (n.panels.items, 0..) |p, i| {
            try t.adoptTab(p.title, i, p.content);
        }
        if (n.panels.items.len > 0) t.setActive(@min(n.active, n.panels.items.len - 1));
    }

    fn buildFloat(self: *Dock, f: *Float) !void {
        const tree = &self.ui.tree;
        f.frame = try tree.create(.{
            .style = .{
                .position = .absolute,
                .direction = .column,
                .width = Length.px(f.rect.w),
                .height = Length.px(f.rect.h),
                .inset = .{ .left = Length.px(f.rect.x), .top = Length.px(f.rect.y) },
                .shrink = 0,
            },
            .visual = .{ .background = float_bg, .border_color = float_border, .border_width = 1, .radius = 6 },
            .role = .panel,
        });
        errdefer _ = tree.destroySubtree(f.frame);
        tree.get(f.frame).?.flags.clip_children = true;
        try tree.appendChild(self.host, f.frame);
        try tree.setLabel(f.frame, "Floating panel");
        try tree.addListener(f.frame, .{ .kind = .pointer_down, .capture = true, .callback = event.Callback.bind(f, Float.onFrame) });
        f.strip = try tree.create(.{
            .style = .{ .direction = .row, .height = Length.px(strip_h), .padding = Edges.xy(8, 0), .align_items = .center, .shrink = 0 },
            .visual = .{ .background = Color.rgba(255, 255, 255, 22) },
            .cursor = .pointer,
        });
        try tree.appendChild(f.frame, f.strip);
        f.title = try self.ui.add(Label, f.strip, .{ .text = if (f.group.panels.items.len > 0) f.group.panels.items[0].title else "" , .size = 12 });
        for ([_]event.EventKind{ .pointer_down, .pointer_move, .pointer_up }) |k| {
            try tree.addListener(f.strip, .{ .kind = k, .callback = event.Callback.bind(f, Float.onStrip) });
        }
        const body = try tree.create(.{ .style = .{ .direction = .column, .grow = 1 } });
        try tree.appendChild(f.frame, body);
        try self.buildGroup(f.group, body);
        // The resize handle sits over the bottom-right corner.
        f.grip = try tree.create(.{
            .style = .{ .position = .absolute, .width = Length.px(14), .height = Length.px(14), .inset = .{ .right = Length.px(0), .bottom = Length.px(0) } },
            .cursor = .resize_horizontal,
        });
        try tree.appendChild(f.frame, f.grip);
        tree.get(f.grip).?.paint_hook = tree_mod.PaintHook.bind(f, Float.paintGrip);
        for ([_]event.EventKind{ .pointer_down, .pointer_move, .pointer_up }) |k| {
            try tree.addListener(f.grip, .{ .kind = k, .callback = event.Callback.bind(f, Float.onGrip) });
        }
    }

    fn applyFloatRect(self: *Dock, f: *Float) void {
        const n = self.ui.tree.get(f.frame) orelse return;
        n.style.width = Length.px(f.rect.w);
        n.style.height = Length.px(f.rect.h);
        n.style.inset = .{ .left = Length.px(f.rect.x), .top = Length.px(f.rect.y) };
        self.ui.tree.markDirty(f.frame, .{ .layout = true, .paint = true });
        self.ui.tree.markDirty(self.host, .{ .paint = true });
    }

    fn raise(self: *Dock, f: *Float) void {
        const last = self.floats.items[self.floats.items.len - 1];
        if (last == f) return;
        if (std.mem.indexOfScalar(*Float, self.floats.items, f)) |i| {
            _ = self.floats.orderedRemove(i);
            self.floats.append(self.gpa, f) catch return;
        }
        self.ui.tree.appendChild(self.host, f.frame) catch {};
    }

    // ---- dragging ----

    fn hostRect(self: *Dock) Rect {
        return self.ui.tree.absoluteRect(self.host) orelse .{};
    }

    fn groupRect(self: *Dock, g: *Node) ?Rect {
        const t = g.tabs orelse return null;
        return self.ui.tree.absoluteRect(t.node);
    }

    /// Where dropping `panels` (from group `src`) at the window point would go.
    fn computeDrop(self: *Dock, x: f32, y: f32, panels: []const *Panel, src: ?*Node) ?Drop {
        _ = panels;
        const host = self.hostRect();
        const inside_host = x >= host.x and x < host.right() and y >= host.y and y < host.bottom();
        if (!inside_host) return .{ .group = null, .zone = .tab, .float = true, .preview = .{ .x = x - 60, .y = y - 12, .w = 280, .h = 200 } };
        // Floating windows are on top, last one first.
        var i = self.floats.items.len;
        while (i > 0) {
            i -= 1;
            const f = self.floats.items[i];
            if (f.group == src) continue;
            const r = self.groupRect(f.group) orelse continue;
            if (x >= r.x and x < r.right() and y >= r.y and y < r.bottom()) {
                return .{ .group = f.group, .zone = .tab, .preview = r, .index = tabIndexAt(f.group, x, y, r) };
            }
        }
        if (self.root) |root| {
            if (self.findGroupAt(root, x, y)) |g| {
                const r = self.groupRect(g) orelse return null;
                const bar = if (g.tabs) |t| (t.barRect() orelse r) else r;
                // Over its own tab bar: reordering is the tab bar's job.
                if (g == src and y < bar.bottom()) return null;
                const zone = zoneOf(r, bar, x, y);
                if (g == src and (zone == .tab or g.panels.items.len <= 1)) return null;
                return .{ .group = g, .zone = zone, .preview = previewOf(r, zone), .index = if (zone == .tab) tabIndexAt(g, x, y, r) else std.math.maxInt(usize) };
            }
        } else {
            const area = self.ui.tree.absoluteRect(self.area) orelse return null;
            if (x >= area.x and x < area.right() and y >= area.y and y < area.bottom()) {
                return .{ .group = null, .zone = .tab, .preview = area };
            }
        }
        return null;
    }

    fn tabIndexAt(g: *Node, x: f32, y: f32, r: Rect) usize {
        const t = g.tabs orelse return std.math.maxInt(usize);
        const bar = t.barRect() orelse return std.math.maxInt(usize);
        if (y < r.y or y >= bar.bottom()) return std.math.maxInt(usize);
        var i: usize = 0;
        while (i < g.panels.items.len) : (i += 1) {
            const tr = t.tabRect(i) orelse continue;
            if (x < tr.x + tr.w / 2) return i;
        }
        return g.panels.items.len;
    }

    fn findGroupAt(self: *Dock, n: *Node, x: f32, y: f32) ?*Node {
        if (!n.is_split) {
            const r = self.groupRect(n) orelse return null;
            return if (x >= r.x and x < r.right() and y >= r.y and y < r.bottom()) n else null;
        }
        if (n.a) |a| if (self.findGroupAt(a, x, y)) |g| return g;
        if (n.b) |b| if (self.findGroupAt(b, x, y)) |g| return g;
        return null;
    }

    fn zoneOf(r: Rect, bar: Rect, x: f32, y: f32) Zone {
        if (y < bar.bottom()) return .tab;
        const nx = (x - (r.x + r.w / 2)) / r.w; // -0.5 .. 0.5
        const ny = (y - (r.y + r.h / 2)) / r.h;
        if (@abs(nx) < 0.2 and @abs(ny) < 0.2) return .tab;
        if (@abs(nx) > @abs(ny)) return if (nx < 0) .left else .right;
        return if (ny < 0) .top else .bottom;
    }

    fn previewOf(r: Rect, zone: Zone) Rect {
        return switch (zone) {
            .tab => r,
            .left => .{ .x = r.x, .y = r.y, .w = r.w / 2, .h = r.h },
            .right => .{ .x = r.x + r.w / 2, .y = r.y, .w = r.w / 2, .h = r.h },
            .top => .{ .x = r.x, .y = r.y, .w = r.w, .h = r.h / 2 },
            .bottom => .{ .x = r.x, .y = r.y + r.h / 2, .w = r.w, .h = r.h / 2 },
        };
    }

    fn setDrop(self: *Dock, d: ?Drop) void {
        const same = if (self.drop != null and d != null) std.meta.eql(self.drop.?, d.?) else self.drop == null and d == null;
        if (same) return;
        self.drop = d;
        self.ui.tree.markDirty(self.host, .{ .paint = true });
    }

    fn paintOverlay(self: *Dock, pc: *PaintCtx) paint_ctx.Error!void {
        const d = self.drop orelse return;
        const r = d.preview;
        try pc.list.fillRect(r, draw_list.Paint.solid(Color.rgba(64, 140, 255, 70)));
        try pc.list.strokeRect(r, 2, draw_list.Paint.solid(accent));
    }

    fn tabDrag(self: *Dock, g: *Node, index: usize, phase: tab_panel.DragPhase, x: f32, y: f32) void {
        switch (phase) {
            .begin => {
                self.dragging.clearRetainingCapacity();
                if (index < g.panels.items.len) self.dragging.append(self.gpa, g.panels.items[index]) catch return;
                self.drag_src = g;
            },
            .move, .end => {
                if (self.dragging.items.len == 0) return;
                const p = self.dragging.items[0];
                // The tab bar reorders tabs as you drag: follow it in the model.
                if (std.mem.indexOfScalar(*Panel, g.panels.items, p)) |cur| {
                    if (cur != index and index < g.panels.items.len) {
                        _ = g.panels.orderedRemove(cur);
                        g.panels.insert(self.gpa, index, p) catch {};
                    }
                }
                if (phase == .move) {
                    self.setDrop(self.computeDrop(x, y, self.dragging.items, self.drag_src));
                } else {
                    self.finishTabDrag(g, x, y);
                }
            },
        }
    }

    fn finishTabDrag(self: *Dock, g: *Node, x: f32, y: f32) void {
        var drop = self.computeDrop(x, y, self.dragging.items, self.drag_src);
        self.setDrop(null);
        const shift = self.ui.input.mods.shift;
        const p = self.dragging.items[0];
        self.dragging.clearRetainingCapacity();
        self.drag_src = null;
        _ = g;
        if (shift and (drop == null or !drop.?.float)) {
            // Shift floats it where it was dropped.
            drop = .{ .group = null, .zone = .tab, .float = true, .preview = .{ .x = x - 60, .y = y - 12, .w = 320, .h = 220 } };
        }
        const d = drop orelse return;
        self.applyDrop(&.{p}, d) catch {};
    }

    fn floatDragEnd(self: *Dock, f: *Float, x: f32, y: f32) void {
        const d = self.computeDrop(x, y, f.group.panels.items, f.group);
        self.setDrop(null);
        const dd = d orelse return;
        if (dd.float) return; // dropped outside: it stays where it is
        // Move all of the window's tabs.
        var list: [32]*Panel = undefined;
        const n = @min(f.group.panels.items.len, list.len);
        @memcpy(list[0..n], f.group.panels.items[0..n]);
        self.applyDrop(list[0..n], dd) catch {};
    }

    fn applyDrop(self: *Dock, panels: []const *Panel, d: Drop) !void {
        // Copy the panels first: removing them edits the lists they came from.
        var list: [32]*Panel = undefined;
        const n = @min(panels.len, list.len);
        @memcpy(list[0..n], panels[0..n]);
        const ps = list[0..n];
        if (d.float) {
            for (ps) |p| self.takeOut(p);
            try self.makeFloat(ps, .{ .x = d.preview.x - self.hostRect().x, .y = d.preview.y - self.hostRect().y, .w = d.preview.w, .h = d.preview.h });
            return self.rebuild();
        }
        const target = d.group;
        // Sizes are needed before the source collapses.
        const extent = if (target) |t| self.groupExtent(t, d.zone == .top or d.zone == .bottom) else 400;
        for (ps) |p| self.takeOut(p);
        if (target == null) {
            const g = try self.newNode();
            self.root = g;
            for (ps) |p| try self.addToGroup(g, p, std.math.maxInt(usize));
            return self.rebuild();
        }
        const t = target.?;
        if (!self.isLive(t)) { // the target collapsed with the source: dock at the root
            const g = self.firstGroup() orelse blk: {
                const g = try self.newNode();
                self.root = g;
                break :blk g;
            };
            for (ps) |p| try self.addToGroup(g, p, std.math.maxInt(usize));
            return self.rebuild();
        }
        switch (d.zone) {
            .tab => {
                var at = d.index;
                for (ps) |p| {
                    try self.addToGroup(t, p, at);
                    if (at != std.math.maxInt(usize)) at += 1;
                }
            },
            .left, .right, .top, .bottom => {
                const side: Side = switch (d.zone) {
                    .left => .left,
                    .right => .right,
                    .top => .top,
                    else => .bottom,
                };
                try self.splitAt(t, ps, side, extent / 2);
            },
        }
        try self.rebuild();
    }

    // ---- tab context menu ----

    fn tabMenu(self: *Dock, p: *Panel, x: f32, y: f32) void {
        const items = [_]menu.Item{
            .{ .label = if (p.state == .floating) "Dock" else "Float" },
            .{ .label = "Close" },
        };
        self.menu_panel = p;
        self.ui.openMenu(&items, x, y, .{ .on_pick = menu.PickHook.bind(self, onMenuPick) }) catch {};
    }

    fn onMenuPick(self: *Dock, index: usize) void {
        const p = self.menu_panel orelse return;
        self.menu_panel = null;
        switch (index) {
            0 => if (p.state == .floating) {
                self.dockTab(p, null) catch {};
            } else {
                const host = self.hostRect();
                const g = p.group;
                var r: Rect = .{ .x = 80, .y = 80, .w = 320, .h = 220 };
                if (g) |gg| if (self.groupRect(gg)) |gr| {
                    r = .{ .x = gr.x - host.x + 24, .y = gr.y - host.y + 24, .w = @max(gr.w * 0.6, 240), .h = @max(gr.h * 0.6, 160) };
                };
                self.floatPanel(p, r) catch {};
            },
            else => self.requestClose(p),
        }
    }
};

// ---- tests -----------------------------------------------------------------

const testing = std.testing;

const Rig = struct {
    ui: Ui,
    cmds: [8192]draw_list.Command = undefined,
    glyphs: [4096]draw_list.Glyph = undefined,
    list: draw_list.DrawList = undefined,
    prop: @import("../text/font.zig").TestFont = .{},

    fn init() !*Rig {
        const r = try testing.allocator.create(Rig);
        r.* = .{ .ui = try Ui.init(testing.allocator) };
        _ = try r.ui.addFont(r.prop.backend());
        r.list = draw_list.DrawList.init(&r.cmds, &r.glyphs);
        r.ui.tree.get(r.ui.tree.root).?.style = .{ .direction = .column };
        return r;
    }

    fn deinit(self: *Rig) void {
        self.ui.deinit();
        testing.allocator.destroy(self);
    }

    fn frame(self: *Rig) !void {
        self.ui.update();
        try self.ui.layoutAndPaint(.{ .w = 800, .h = 500 }, &self.list);
        self.ui.endFrame();
    }

    fn settle(self: *Rig) !void {
        try self.frame();
        try self.frame();
        try self.frame();
    }

    fn dock(self: *Rig) !*Dock {
        const d = try Dock.create(&self.ui, self.ui.tree.root, .{ .style = .{ .width = .fill, .height = .fill } });
        return d;
    }

    fn drag(self: *Rig, from: [2]f32, to: [2]f32) !void {
        self.ui.pointerMove(from[0], from[1]);
        self.ui.pointerButtonEx(from[0], from[1], 1, true, 1);
        try self.frame();
        for (1..9) |i| {
            const f = @as(f32, @floatFromInt(i)) / 8;
            self.ui.pointerMove(from[0] + (to[0] - from[0]) * f, from[1] + (to[1] - from[1]) * f);
            try self.frame();
        }
        self.ui.pointerButtonEx(to[0], to[1], 1, false, 1);
        try self.settle();
    }
};

fn centerOf(r: *Rig, h: Handle) [2]f32 {
    const b = r.ui.tree.absoluteRect(h).?;
    return .{ b.x + b.w / 2, b.y + b.h / 2 };
}

fn tabCenter(r: *Rig, p: *Panel) [2]f32 {
    _ = r;
    const t = p.group.?.tabs.?;
    const i = std.mem.indexOfScalar(*Panel, p.group.?.panels.items, p).?;
    const b = t.tabRect(i).?;
    return .{ b.x + b.w / 2, b.y + b.h / 2 };
}

test "panels dock as tabs and as splits, and their contents are re-parented" {
    const r = try Rig.init();
    defer r.deinit();
    const d = try r.dock();
    defer d.destroy();
    const ed = try d.addPanel("Editor");
    const out = try d.addPanel("Output");
    const files = try d.addPanel("Files");
    _ = try r.ui.add(Label, files.content, .{ .text = "tree" });
    try testing.expect(files.state == .hidden);

    try d.dockTab(ed, null);
    try d.dockTab(out, ed);
    try d.dockSplit(files, ed, .left, 200);
    try r.settle();
    try testing.expect(d.root.?.is_split);
    try testing.expect(files.group != ed.group and ed.group == out.group);
    try testing.expectEqual(@as(usize, 2), ed.group.?.panels.items.len);
    try testing.expect(files.state == .docked);
    // Each content sits in its group's page, and the left group is 200 wide.
    try testing.expect(r.ui.tree.get(files.content).?.parent.eql(files.group.?.tabs.?.pageNode(0).?));
    const lw = r.ui.tree.absoluteRect(files.group.?.tabs.?.node).?.w;
    try testing.expect(lw > 195 and lw < 205);
    // The Output tab is behind the Editor tab (the group's active page).
    try testing.expectEqual(@as(usize, 1), ed.group.?.tabs.?.activeTab()); // Output was added last, so it is shown
    try testing.expectEqualStrings("Editor\nOutput", ed.group.?.tabs.?.props.titles.bytes);
}

test "closing hides a panel; showing docks it again; empty groups collapse" {
    const r = try Rig.init();
    defer r.deinit();
    const d = try r.dock();
    defer d.destroy();
    const a = try d.addPanel("A");
    const b = try d.addPanel("B");
    try d.dockTab(a, null);
    try d.dockSplit(b, a, .right, 200);
    try r.settle();
    try testing.expect(d.root.?.is_split);
    d.closePanel(b);
    try r.settle();
    try testing.expect(!d.root.?.is_split); // the split collapsed to A's group
    try testing.expect(b.state == .hidden and b.group == null);
    try testing.expect(r.ui.tree.isValid(b.content)); // alive, parentless
    try d.showPanel(b);
    try r.settle();
    try testing.expect(b.state == .docked);
    try testing.expectEqual(@as(usize, 2), a.group.?.panels.items.len);
    d.closePanel(a);
    d.closePanel(b);
    try testing.expect(d.root == null);
    try r.settle();
}

test "dragging a tab to a group's edge splits it; dragging it back into the tabs merges" {
    const r = try Rig.init();
    defer r.deinit();
    const d = try r.dock();
    defer d.destroy();
    const a = try d.addPanel("A");
    const b = try d.addPanel("B");
    try d.dockTab(a, null);
    try d.dockTab(b, a);
    try r.settle();
    try testing.expect(!d.root.?.is_split);

    // Drag B's tab to the right edge of the group.
    const grp = r.ui.tree.absoluteRect(a.group.?.tabs.?.node).?;
    try r.drag(tabCenter(r, b), .{ grp.right() - 20, grp.y + grp.h / 2 });
    try testing.expect(d.root.?.is_split);
    try testing.expect(!d.root.?.vertical);
    try testing.expect(a.group != b.group);
    try testing.expect(d.root.?.b.? == b.group.?); // B is on the right

    // Drag it onto A's tab bar: back into one group, as a tab.
    const bar = a.group.?.tabs.?.barRect().?;
    try r.drag(tabCenter(r, b), .{ bar.x + 30, bar.y + bar.h / 2 });
    try testing.expect(!d.root.?.is_split);
    try testing.expectEqual(@as(usize, 2), a.group.?.panels.items.len);
    try testing.expect(a.group == b.group);
    try testing.expect(r.ui.tree.get(b.content).?.parent.eql(b.group.?.tabs.?.pageNode(std.mem.indexOfScalar(*Panel, b.group.?.panels.items, b).?).?));
}

test "Shift-dropping floats a panel; dragging the window's strip onto a group docks it again" {
    const r = try Rig.init();
    defer r.deinit();
    const d = try r.dock();
    defer d.destroy();
    const a = try d.addPanel("A");
    const b = try d.addPanel("B");
    const c = try d.addPanel("C");
    try d.dockTab(a, null);
    try d.dockTab(b, a);
    try d.dockSplit(c, a, .left, 200);
    try r.settle();

    r.ui.input.mods = .{ .shift = true };
    const grp = r.ui.tree.absoluteRect(a.group.?.tabs.?.node).?;
    // Hold shift through the drag (the mods are read when it is released).
    try r.drag(tabCenter(r, b), .{ grp.x + grp.w / 2, grp.y + grp.h / 2 });
    r.ui.input.mods = .{};
    try testing.expect(b.state == .floating);
    try testing.expectEqual(@as(usize, 1), d.floats.items.len);
    try testing.expect(a.state == .docked and a.group.?.panels.items.len == 1);
    const f = d.floats.items[0];
    try testing.expect(r.ui.tree.isValid(f.frame));

    // Drag the float's strip onto the left group: B becomes a tab there.
    const left = r.ui.tree.absoluteRect(c.group.?.tabs.?.node).?;
    try r.drag(centerOf(r, f.strip), .{ left.x + left.w / 2, left.y + left.h / 2 });
    try testing.expect(b.state == .docked);
    try testing.expect(b.group == c.group);
    try testing.expectEqual(@as(usize, 0), d.floats.items.len);
}

test "floating, resizing, and dragging a float window by its strip" {
    const r = try Rig.init();
    defer r.deinit();
    const d = try r.dock();
    defer d.destroy();
    const a = try d.addPanel("A");
    const b = try d.addPanel("B");
    try d.dockTab(a, null);
    try d.floatPanel(b, .{ .x = 100, .y = 80, .w = 300, .h = 200 });
    try r.settle();
    const f = d.floats.items[0];
    const fr = r.ui.tree.absoluteRect(f.frame).?;
    const host = r.ui.tree.absoluteRect(d.host).?;
    try testing.expectApproxEqAbs(host.x + 100, fr.x, 0.5);
    try testing.expectApproxEqAbs(@as(f32, 300), fr.w, 0.5);

    // Drag the strip out past the dock's edge: the window follows and stays floating.
    const s = centerOf(r, f.strip);
    r.ui.pointerMove(s[0], s[1]);
    r.ui.pointerButtonEx(s[0], s[1], 1, true, 1);
    r.ui.pointerMove(s[0] + 600, s[1] + 20);
    try r.frame();
    r.ui.pointerButtonEx(s[0] + 600, s[1] + 20, 1, false, 1);
    try r.frame();
    try testing.expectEqual(@as(usize, 1), d.floats.items.len);
    try testing.expectApproxEqAbs(@as(f32, 700), f.rect.x, 1);
    try testing.expectApproxEqAbs(@as(f32, 100), f.rect.y, 1);
    f.rect.x = 200;
    d.applyFloatRect(f);
    try r.settle();

    // Resize with the grip.
    const g = centerOf(r, f.grip);
    r.ui.pointerMove(g[0], g[1]);
    r.ui.pointerButtonEx(g[0], g[1], 1, true, 1);
    r.ui.pointerMove(g[0] + 40, g[1] + 30);
    r.ui.pointerButtonEx(g[0] + 40, g[1] + 30, 1, false, 1);
    try r.frame();
    try testing.expectApproxEqAbs(@as(f32, 340), f.rect.w, 1);
    try testing.expectApproxEqAbs(@as(f32, 230), f.rect.h, 1);
    // Closing the float's only panel removes the window.
    d.closePanel(b);
    try r.settle();
    try testing.expectEqual(@as(usize, 0), d.floats.items.len);
}

test "the tab context menu floats and closes panels; destroyPanel frees everything" {
    const r = try Rig.init();
    defer r.deinit();
    const d = try r.dock();
    defer d.destroy();
    const a = try d.addPanel("A");
    const b = try d.addPanel("B");
    try d.dockTab(a, null);
    try d.dockTab(b, a);
    try r.settle();
    // Right-click B's tab.
    const t = tabCenter(r, b);
    r.ui.pointerMove(t[0], t[1]);
    r.ui.pointerButtonEx(t[0], t[1], 3, true, 1);
    r.ui.pointerButtonEx(t[0], t[1], 3, false, 1);
    try r.frame();
    try testing.expect(r.ui.menuOpen());
    try r.frame();
    const float_item = centerOf(r, r.ui.menu.?.entries[0].row);
    r.ui.pointerMove(float_item[0], float_item[1]);
    r.ui.pointerButtonEx(float_item[0], float_item[1], 1, true, 1);
    r.ui.pointerButtonEx(float_item[0], float_item[1], 1, false, 1);
    try r.settle();
    try testing.expect(b.state == .floating);
    d.destroyPanel(b);
    try r.settle();
    try testing.expectEqual(@as(usize, 0), d.floats.items.len);
    try testing.expectEqual(@as(usize, 1), d.panels.items.len);
}

test "requestClose asks the hook; setTitle renames the tab; dockTab falls back to the last group" {
    var ui = try Ui.init(testing.allocator);
    defer ui.deinit();
    const d = try ui.add(Dock, ui.tree.root, .{});
    const a = try d.addPanel("A");
    const b = try d.addPanel("B");
    try d.dockTab(a, null);
    try d.dockTab(b, a);
    const Ctx = struct {
        seen: ?*Panel = null,
        take: bool = true,
        fn hook(self: *@This(), p: *Panel) bool {
            self.seen = p;
            return self.take;
        }
    };
    var ctx: Ctx = .{};
    d.close_hook = .bind(&ctx, Ctx.hook);
    d.requestClose(b);
    try testing.expect(ctx.seen == b);
    try testing.expectEqual(State.docked, b.state);
    ctx.take = false;
    d.requestClose(b);
    try testing.expectEqual(State.hidden, b.state);
    try d.setTitle(a, "A *");
    try testing.expectEqualStrings("A *", a.group.?.tabs.?.title(0));
    // `a` is closed too; docking `b` near the hidden `a` goes to a's last group (or a fresh one).
    d.closePanel(a);
    try d.dockTab(b, a);
    try testing.expectEqual(State.docked, b.state);
}
