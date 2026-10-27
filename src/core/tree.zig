//! The node tree: nodes live in a stable-address pool and link to each other
//! through generational handles (parent, first/last child, prev/next sibling).
//!
//! Internal engine type. Widgets are separate structs that hold a node `Handle`.

const std = @import("std");
const Handle = @import("handle.zig").Handle;
const Pool = @import("pool.zig").Pool;
const DirtyFlags = @import("dirty.zig").DirtyFlags;
const Rect = @import("geometry.zig").Rect;
const Size = @import("geometry.zig").Size;
const event = @import("event.zig");
const TextBlock = @import("../text/block.zig").TextBlock;

/// Accessibility role. Reserved on every node from v0.1; platform bridges come later.
pub const Role = enum(u16) {
    none = 0,
    generic,
    window,
    panel,
    button,
    label,
    link,
    text_field,
    checkbox,
    list,
    list_item,
    tree_item,
    menu,
    menu_item,
    image,
    canvas,
    _,
};

/// Mouse cursor shape to show while the pointer is over a node (nearest
/// ancestor that sets one wins).
pub const Cursor = enum(u8) { default = 0, text, pointer };

pub const NodeFlags = packed struct(u16) {
    focusable: bool = false,
    /// Takes part in hit-testing (set when a pointer listener is attached).
    interactive: bool = false,
    /// Own size cannot be changed by descendants; layout dirtiness stops here.
    relayout_boundary: bool = false,
    /// Subtree geometry is cached; repaints do not invalidate neighbors.
    repaint_boundary: bool = false,
    hidden: bool = false,
    /// Children are clipped to this node's rect when painting.
    clip_children: bool = false,
    /// Typing goes into this node (text fields): unmodified printable-key
    /// shortcuts do not fire while it has focus.
    accepts_text: bool = false,
    /// A focused node with this set gets every key first and nothing falls
    /// through to shortcuts or Tab navigation (canvases); only Escape escapes.
    raw_keys: bool = false,
    _reserved: u8 = 0,
};

pub const Style = @import("style.zig").Style;
pub const Visual = @import("style.zig").Visual;

pub const Node = struct {
    parent: Handle = Handle.invalid,
    first_child: Handle = Handle.invalid,
    last_child: Handle = Handle.invalid,
    prev: Handle = Handle.invalid,
    next: Handle = Handle.invalid,

    dirty: DirtyFlags = .{},
    flags: NodeFlags = .{},
    role: Role = .none,
    cursor: Cursor = .default,
    /// Accessibility label. Not owned: must outlive the node or be interned.
    label: []const u8 = "",
    style: Style = .{},
    visual: Visual = .{},
    /// Layout result in the parent's coordinate space (logical pixels).
    rect: Rect = .{},
    /// Content size of a leaf (for example measured text), set by its widget.
    /// Ignored for nodes that have children.
    intrinsic: Size = .{},
    /// Natural border-box size computed by the layout pass (content plus padding).
    measured: Size = .{},
    /// Transient: set by the layout pass while it decides which children to descend into.
    place_pending: bool = false,
    user_data: ?*anyopaque = null,
    /// The widget living on this node and its type tag (set by `Ui.add`); the
    /// widget registry maps these back to a descriptor.
    widget: ?*anyopaque = null,
    widget_type: ?*const anyopaque = null,
    /// Lazily allocated listener table; null for nodes without listeners.
    listeners: ?*ListenerList = null,
    /// Shaped text drawn inside this node's content box; owned by the node.
    text: ?*TextBlock = null,
    paint_hook: ?PaintHook = null,

    /// Intrusive link for the tree's dirty-boundary stack (engine-internal).
    layout_queue_next: Handle = Handle.invalid,
    /// True while this node is on the dirty-boundary stack.
    layout_queued: bool = false,
};

pub const ListenerList = std.ArrayListUnmanaged(event.Listener);

pub const PaintCtx = @import("paint_ctx.zig").PaintCtx;

/// A node's painter: called by the paint pass after the node's `Visual`, inside
/// its clip, before its text and children. It emits the node's own draw
/// commands (and may set text color overrides on the context). It must keep
/// push/pop balanced. Widgets install one that runs the theme's painter.
pub const PaintHook = struct {
    ctx: *anyopaque,
    run: *const fn (ctx: *anyopaque, pc: *PaintCtx) @import("paint_ctx.zig").Error!void,

    /// `PaintHook.bind(widget, Widget.paintHook)` where the function is
    /// `fn (*Widget, *PaintCtx) Error!void`.
    pub fn bind(ctx: anytype, comptime f: anytype) PaintHook {
        const Ptr = @TypeOf(ctx);
        return .{
            .ctx = @ptrCast(ctx),
            .run = &struct {
                fn thunk(c: *anyopaque, pc: *PaintCtx) @import("paint_ctx.zig").Error!void {
                    return f(@as(Ptr, @ptrCast(@alignCast(c))), pc);
                }
            }.thunk,
        };
    }
};

pub const TreeError = error{
    InvalidHandle,
    WouldCycle,
    NotAChild,
    OutOfMemory,
};

pub const Tree = struct {
    allocator: std.mem.Allocator,
    pool: Pool(Node, 256),
    root: Handle,
    /// Nonzero while an event is being dispatched. Destroys requested then are
    /// queued in `deferred` and run when the outermost dispatch ends.
    dispatch_depth: u32 = 0,
    deferred: std.ArrayListUnmanaged(Handle) = .empty,
    /// The window's focused node (invalid if none). `Input` notifies nodes of
    /// changes with focus_in/focus_out. If the focused node is destroyed, focus
    /// falls back to the nearest focusable ancestor.
    focused: Handle = Handle.invalid,
    /// Top of the stack of relayout boundaries that need a layout pass. It is
    /// intrusive (links live in `Node`), so marking dirty never allocates or fails.
    layout_queue_head: Handle = Handle.invalid,

    /// Create a tree with a root node. The root's size comes from its window,
    /// so it is both a relayout and a repaint boundary.
    pub fn init(allocator: std.mem.Allocator) !Tree {
        var pool = Pool(Node, 256).init(allocator);
        errdefer pool.deinit();
        const root = try pool.create(.{
            .role = .generic,
            .flags = .{ .relayout_boundary = true, .repaint_boundary = true },
        });
        return .{ .allocator = allocator, .pool = pool, .root = root };
    }

    pub fn deinit(self: *Tree) void {
        var it = self.pool.iterator();
        while (it.next()) |entry| {
            self.freeListeners(entry.ptr);
            self.freeText(entry.ptr);
        }
        self.deferred.deinit(self.allocator);
        self.pool.deinit();
        self.* = undefined;
    }

    pub fn count(self: *const Tree) u32 {
        return self.pool.count();
    }

    pub fn create(self: *Tree, node: Node) !Handle {
        var n = node;
        // A fresh node starts detached and fully dirty so its first frame lays out and paints.
        n.parent = Handle.invalid;
        n.first_child = Handle.invalid;
        n.last_child = Handle.invalid;
        n.prev = Handle.invalid;
        n.next = Handle.invalid;
        n.dirty = n.dirty.merge(DirtyFlags.layout_and_paint);
        return self.pool.create(n);
    }

    pub fn get(self: *Tree, h: Handle) ?*Node {
        return self.pool.get(h);
    }

    pub fn isValid(self: *const Tree, h: Handle) bool {
        return self.pool.isValid(h);
    }

    /// True if `ancestor` is a strict ancestor of `node`.
    pub fn isAncestor(self: *Tree, ancestor: Handle, node: Handle) bool {
        var cur = if (self.get(node)) |n| n.parent else return false;
        while (!cur.isNull()) {
            if (Handle.eql(cur, ancestor)) return true;
            cur = if (self.get(cur)) |n| n.parent else return false;
        }
        return false;
    }

    pub fn childCount(self: *Tree, h: Handle) u32 {
        var n: u32 = 0;
        var it = self.children(h);
        while (it.next()) |_| n += 1;
        return n;
    }

    pub const ChildIterator = struct {
        tree: *Tree,
        cur: Handle,

        pub fn next(self: *ChildIterator) ?Handle {
            if (self.cur.isNull()) return null;
            const out = self.cur;
            const node = self.tree.get(out) orelse return null;
            self.cur = node.next;
            return out;
        }
    };

    pub fn children(self: *Tree, h: Handle) ChildIterator {
        const first = if (self.get(h)) |n| n.first_child else Handle.invalid;
        return .{ .tree = self, .cur = first };
    }

    /// Remove `child` from its parent (if any) without destroying it.
    pub fn detach(self: *Tree, child: Handle) void {
        const node = self.get(child) orelse return;
        const parent_h = node.parent;
        if (parent_h.isNull()) return;

        if (self.get(node.prev)) |p| {
            p.next = node.next;
        } else if (self.get(parent_h)) |parent| {
            parent.first_child = node.next;
        }
        if (self.get(node.next)) |nx| {
            nx.prev = node.prev;
        } else if (self.get(parent_h)) |parent| {
            parent.last_child = node.prev;
        }

        node.parent = Handle.invalid;
        node.prev = Handle.invalid;
        node.next = Handle.invalid;
        self.markDirty(parent_h, .{ .children = true });
    }

    pub fn appendChild(self: *Tree, parent: Handle, child: Handle) TreeError!void {
        return self.insertBefore(parent, child, Handle.invalid);
    }

    /// Insert `child` under `parent` before `before`. A null `before` appends.
    /// The child is detached from its old parent first.
    pub fn insertBefore(self: *Tree, parent: Handle, child: Handle, before: Handle) TreeError!void {
        const parent_node = self.get(parent) orelse return error.InvalidHandle;
        const child_node = self.get(child) orelse return error.InvalidHandle;
        if (Handle.eql(parent, child) or self.isAncestor(child, parent)) return error.WouldCycle;

        if (!before.isNull()) {
            const before_node = self.get(before) orelse return error.InvalidHandle;
            if (!Handle.eql(before_node.parent, parent)) return error.NotAChild;
            if (Handle.eql(before, child)) return; // already in place relative to itself
        }

        self.detach(child);

        if (before.isNull()) {
            child_node.prev = parent_node.last_child;
            child_node.next = Handle.invalid;
            if (self.get(parent_node.last_child)) |last| {
                last.next = child;
            } else {
                parent_node.first_child = child;
            }
            parent_node.last_child = child;
        } else {
            const before_node = self.get(before).?;
            child_node.next = before;
            child_node.prev = before_node.prev;
            if (self.get(before_node.prev)) |p| {
                p.next = child;
            } else {
                parent_node.first_child = child;
            }
            before_node.prev = child;
        }
        child_node.parent = parent;
        self.markDirty(parent, .{ .children = true });
        self.markDirty(child, DirtyFlags.layout_and_paint);
    }

    /// Destroy `h` and all its descendants. Returns the number of nodes destroyed.
    /// Iterative, so deep trees cannot overflow the stack.
    /// During event dispatch the destroy is deferred (returns 0) and runs when
    /// the outermost dispatch ends, so handlers never pull nodes out from under it.
    pub fn destroySubtree(self: *Tree, h: Handle) u32 {
        if (!self.isValid(h)) return 0;
        if (self.dispatch_depth > 0) {
            self.deferred.append(self.allocator, h) catch {
                // Cannot queue: hide the subtree so it at least disappears.
                if (self.get(h)) |n| n.flags.hidden = true;
            };
            return 0;
        }
        if (Handle.eql(self.focused, h) or self.isAncestor(h, self.focused)) {
            const parent = if (self.get(h)) |n| n.parent else Handle.invalid;
            self.focused = self.focusableAtOrAbove(parent) orelse Handle.invalid;
        }
        self.detach(h);

        var destroyed: u32 = 0;
        var cur = h;
        while (true) {
            const node = self.get(cur).?;
            if (!node.first_child.isNull()) {
                cur = node.first_child; // descend to a leaf
                continue;
            }
            // `cur` is a leaf. Below `h` it is always its parent's first child
            // (earlier siblings were already destroyed), so unlink by advancing it.
            const parent_h = node.parent;
            const next_h = node.next;
            const is_top = Handle.eql(cur, h);
            if (!is_top) {
                if (self.get(parent_h)) |p| {
                    p.first_child = next_h;
                    if (next_h.isNull()) p.last_child = Handle.invalid;
                }
                if (self.get(next_h)) |nx| nx.prev = Handle.invalid;
            }
            if (node.layout_queued) self.unqueueBoundary(cur);
            self.freeListeners(node);
            self.freeText(node);
            _ = self.pool.destroy(cur);
            destroyed += 1;
            if (is_top) break;
            cur = if (next_h.isNull()) parent_h else next_h;
        }
        return destroyed;
    }

    /// True if neither `h` nor any ancestor is hidden.
    pub fn isVisible(self: *Tree, h: Handle) bool {
        var cur = h;
        while (self.get(cur)) |n| : (cur = n.parent) {
            if (n.flags.hidden) return false;
        }
        return true;
    }

    pub fn isFocusable(self: *Tree, h: Handle) bool {
        const n = self.get(h) orelse return false;
        return n.flags.focusable and self.isVisible(h);
    }

    /// `h` if it is focusable, else the nearest focusable ancestor.
    pub fn focusableAtOrAbove(self: *Tree, h: Handle) ?Handle {
        var cur = h;
        while (self.get(cur)) |n| : (cur = n.parent) {
            if (n.flags.focusable and self.isVisible(cur)) return cur;
        }
        return null;
    }

    /// Next focusable node after `from` in tree order (previous if `!forward`),
    /// wrapping around; `from` itself is returned if it is the only candidate.
    /// With an invalid `from`, the first (or last) focusable. Null if nothing
    /// is focusable.
    pub fn nextFocusable(self: *Tree, from: Handle, forward: bool) ?Handle {
        const have_from = self.isValid(from);
        if (forward) {
            var cur: ?Handle = if (have_from) self.nextPreorder(self.root, from) else self.root;
            while (cur) |c| : (cur = self.nextPreorder(self.root, c)) {
                if (self.isFocusable(c)) return c;
            }
            if (!have_from) return null;
            // Wrap: from the start up to and including `from`.
            cur = self.root;
            while (cur) |c| : (cur = self.nextPreorder(self.root, c)) {
                if (self.isFocusable(c)) return c;
                if (Handle.eql(c, from)) break;
            }
            return null;
        }
        // Backward: the last focusable before `from`, else the last overall.
        var before: ?Handle = null;
        var overall: ?Handle = null;
        var seen_from = !have_from;
        var cur: ?Handle = self.root;
        while (cur) |c| : (cur = self.nextPreorder(self.root, c)) {
            if (have_from and Handle.eql(c, from)) seen_from = true;
            if (!self.isFocusable(c)) continue;
            overall = c;
            if (!seen_from) before = c;
        }
        return before orelse overall;
    }

    pub fn beginDispatch(self: *Tree) void {
        self.dispatch_depth += 1;
    }

    pub fn endDispatch(self: *Tree) void {
        std.debug.assert(self.dispatch_depth > 0);
        self.dispatch_depth -= 1;
        if (self.dispatch_depth > 0) return;
        while (self.deferred.pop()) |h| _ = self.destroySubtree(h);
    }

    fn freeText(self: *Tree, node: *Node) void {
        if (node.text) |t| {
            self.allocator.free(t.glyphs);
            self.allocator.destroy(t);
            node.text = null;
        }
    }

    /// Attach (or replace) the node's text. `block.glyphs` must have been
    /// allocated with the tree's allocator; the node takes ownership.
    pub fn setText(self: *Tree, h: Handle, block: TextBlock) TreeError!void {
        const node = self.get(h) orelse {
            self.allocator.free(block.glyphs);
            return error.InvalidHandle;
        };
        const copy = self.allocator.create(TextBlock) catch |e| {
            self.allocator.free(block.glyphs);
            return e;
        };
        copy.* = block;
        self.freeText(node);
        node.text = copy;
    }

    pub fn clearText(self: *Tree, h: Handle) void {
        if (self.get(h)) |node| self.freeText(node);
    }

    fn freeListeners(self: *Tree, node: *Node) void {
        if (node.listeners) |list| {
            list.deinit(self.allocator);
            self.allocator.destroy(list);
            node.listeners = null;
        }
    }

    /// Attach a listener. A pointer-kind listener makes the node interactive
    /// (it takes part in hit-testing).
    pub fn addListener(self: *Tree, h: Handle, listener: event.Listener) TreeError!void {
        const node = self.get(h) orelse return error.InvalidHandle;
        if (node.listeners == null) {
            const list = try self.allocator.create(ListenerList);
            list.* = .empty;
            node.listeners = list;
        }
        try node.listeners.?.append(self.allocator, listener);
        if (listener.kind.isPointer()) node.flags.interactive = true;
    }

    /// Remove every listener matching `kind` and `callback` (function and context).
    /// Removing the last pointer listener clears the interactive bit.
    pub fn removeListener(self: *Tree, h: Handle, kind: event.EventKind, callback: event.Callback) void {
        const node = self.get(h) orelse return;
        const list = node.listeners orelse return;
        var i: usize = 0;
        while (i < list.items.len) {
            const l = list.items[i];
            if (l.kind == kind and l.callback.eql(callback)) {
                _ = list.orderedRemove(i);
            } else i += 1;
        }
        var any_pointer = false;
        for (list.items) |l| any_pointer = any_pointer or l.kind.isPointer();
        node.flags.interactive = any_pointer;
        if (list.items.len == 0) self.freeListeners(node);
    }

    /// Position and size of `h` in window coordinates.
    pub fn absoluteRect(self: *Tree, h: Handle) ?Rect {
        const node = self.get(h) orelse return null;
        var r = node.rect;
        var cur = node.parent;
        while (self.get(cur)) |p| : (cur = p.parent) {
            r.x += p.rect.x;
            r.y += p.rect.y;
        }
        return r;
    }

    /// Topmost interactive node under the window-space point, or null.
    /// Later siblings paint on top, so they are tested first. A node with
    /// `clip_children` only hits inside its own rect.
    pub fn hitTest(self: *Tree, x: f32, y: f32) ?Handle {
        return self.hitNode(self.root, x, y);
    }

    fn hitNode(self: *Tree, h: Handle, px: f32, py: f32) ?Handle {
        const node = self.get(h) orelse return null;
        if (node.flags.hidden) return null;
        const lx = px - node.rect.x;
        const ly = py - node.rect.y;
        const inside = lx >= 0 and ly >= 0 and lx < node.rect.w and ly < node.rect.h;
        if (node.flags.clip_children and !inside) return null;

        var c = node.last_child;
        while (self.get(c)) |cn| : (c = cn.prev) {
            if (self.hitNode(c, lx, ly)) |hit| return hit;
        }
        if (inside and node.flags.interactive) return h;
        return null;
    }

    /// Next node in pre-order within the subtree rooted at `root`, or null at the end.
    pub fn nextPreorder(self: *Tree, root: Handle, cur: Handle) ?Handle {
        const node = self.get(cur) orelse return null;
        if (!node.first_child.isNull()) return node.first_child;
        var c = cur;
        while (true) {
            if (Handle.eql(c, root)) return null;
            const cn = self.get(c) orelse return null;
            if (!cn.next.isNull()) return cn.next;
            c = cn.parent;
            if (c.isNull()) return null;
        }
    }

    /// Mark a node dirty and propagate "a descendant is dirty" markers upward.
    /// Layout markers stop at the first relayout boundary; paint markers stop
    /// at the first ancestor that already carries one.
    pub fn markDirty(self: *Tree, h: Handle, flags: DirtyFlags) void {
        const node = self.get(h) orelse return;
        node.dirty = node.dirty.merge(flags);

        if (flags.needsLayout()) {
            if (node.flags.relayout_boundary) {
                self.queueBoundary(h, node);
            } else {
                self.propagate(node.parent, .layout);
            }
        }
        if (flags.needsPaint()) {
            self.propagate(node.parent, .paint);
        }
    }

    const PropagateKind = enum { layout, paint };

    fn propagate(self: *Tree, start: Handle, kind: PropagateKind) void {
        var cur = start;
        while (!cur.isNull()) {
            const n = self.get(cur) orelse return;
            switch (kind) {
                .layout => {
                    if (n.dirty.child_layout) return; // ancestors already marked
                    n.dirty.child_layout = true;
                    if (n.flags.relayout_boundary) {
                        self.queueBoundary(cur, n);
                        return;
                    }
                },
                .paint => {
                    if (n.dirty.child_paint) return;
                    n.dirty.child_paint = true;
                },
            }
            cur = n.parent;
        }
    }

    fn queueBoundary(self: *Tree, h: Handle, node: *Node) void {
        if (node.layout_queued) return;
        node.layout_queued = true;
        node.layout_queue_next = self.layout_queue_head;
        self.layout_queue_head = h;
    }

    /// Remove `h` from the dirty-boundary stack (used when it is destroyed).
    fn unqueueBoundary(self: *Tree, h: Handle) void {
        const node = self.get(h) orelse return;
        if (Handle.eql(self.layout_queue_head, h)) {
            self.layout_queue_head = node.layout_queue_next;
        } else {
            var cur = self.layout_queue_head;
            while (self.get(cur)) |c| : (cur = c.layout_queue_next) {
                if (Handle.eql(c.layout_queue_next, h)) {
                    c.layout_queue_next = node.layout_queue_next;
                    break;
                }
            }
        }
        node.layout_queued = false;
        node.layout_queue_next = Handle.invalid;
    }

    /// Seed for the layout pass: pop the next relayout boundary that still
    /// needs layout, or null when none remain. Layout starts at the returned
    /// node (its own rect is taken as given) and covers its dirty descendants.
    /// A boundary whose dirty bits were cleared since it was queued is skipped,
    /// so a pass that clears bits as it goes never lays out a subtree twice.
    pub fn popLayoutRoot(self: *Tree) ?Handle {
        while (self.get(self.layout_queue_head)) |node| {
            const h = self.layout_queue_head;
            self.layout_queue_head = node.layout_queue_next;
            node.layout_queue_next = Handle.invalid;
            node.layout_queued = false;
            if (node.dirty.needsLayout() or node.dirty.child_layout) return h;
        }
        return null;
    }

    /// Clear dirty flags for the whole subtree (call after a frame is built).
    pub fn clearDirty(self: *Tree, root: Handle) void {
        var cur: ?Handle = root;
        while (cur) |h| {
            if (self.get(h)) |n| n.dirty.clear();
            cur = self.nextPreorder(root, h);
        }
    }
};

fn makeChild(tree: *Tree, parent: Handle) !Handle {
    const h = try tree.create(.{ .role = .generic });
    try tree.appendChild(parent, h);
    return h;
}

test "root exists and is a boundary" {
    var tree = try Tree.init(std.testing.allocator);
    defer tree.deinit();
    const root = tree.get(tree.root).?;
    try std.testing.expect(root.flags.relayout_boundary);
    try std.testing.expectEqual(@as(u32, 1), tree.count());
}

test "append keeps order and sibling links" {
    var tree = try Tree.init(std.testing.allocator);
    defer tree.deinit();

    const a = try makeChild(&tree, tree.root);
    const b = try makeChild(&tree, tree.root);
    const c = try makeChild(&tree, tree.root);

    try std.testing.expectEqual(@as(u32, 3), tree.childCount(tree.root));
    var it = tree.children(tree.root);
    try std.testing.expect(Handle.eql(it.next().?, a));
    try std.testing.expect(Handle.eql(it.next().?, b));
    try std.testing.expect(Handle.eql(it.next().?, c));
    try std.testing.expect(it.next() == null);

    try std.testing.expect(Handle.eql(tree.get(b).?.prev, a));
    try std.testing.expect(Handle.eql(tree.get(b).?.next, c));
    try std.testing.expect(Handle.eql(tree.get(tree.root).?.last_child, c));
}

test "insertBefore places a node and reparenting detaches from the old parent" {
    var tree = try Tree.init(std.testing.allocator);
    defer tree.deinit();

    const a = try makeChild(&tree, tree.root);
    const c = try makeChild(&tree, tree.root);
    const b = try tree.create(.{});
    try tree.insertBefore(tree.root, b, c);

    var it = tree.children(tree.root);
    try std.testing.expect(Handle.eql(it.next().?, a));
    try std.testing.expect(Handle.eql(it.next().?, b));
    try std.testing.expect(Handle.eql(it.next().?, c));

    // Move b under a.
    try tree.appendChild(a, b);
    try std.testing.expectEqual(@as(u32, 2), tree.childCount(tree.root));
    try std.testing.expectEqual(@as(u32, 1), tree.childCount(a));
    try std.testing.expect(Handle.eql(tree.get(b).?.parent, a));
}

test "cycles and bad handles are rejected" {
    var tree = try Tree.init(std.testing.allocator);
    defer tree.deinit();

    const a = try makeChild(&tree, tree.root);
    const b = try makeChild(&tree, a);

    try std.testing.expectError(error.WouldCycle, tree.appendChild(b, a));
    try std.testing.expectError(error.WouldCycle, tree.appendChild(a, a));
    try std.testing.expectError(error.InvalidHandle, tree.appendChild(tree.root, Handle.invalid));

    const stranger = try tree.create(.{});
    try std.testing.expectError(error.NotAChild, tree.insertBefore(a, stranger, tree.root));
}

test "detach unlinks the first, middle, and last child correctly" {
    var tree = try Tree.init(std.testing.allocator);
    defer tree.deinit();

    const a = try makeChild(&tree, tree.root);
    const b = try makeChild(&tree, tree.root);
    const c = try makeChild(&tree, tree.root);

    tree.detach(b);
    try std.testing.expect(Handle.eql(tree.get(a).?.next, c));
    try std.testing.expect(Handle.eql(tree.get(c).?.prev, a));

    tree.detach(a);
    try std.testing.expect(Handle.eql(tree.get(tree.root).?.first_child, c));
    tree.detach(c);
    try std.testing.expect(tree.get(tree.root).?.first_child.isNull());
    try std.testing.expect(tree.get(tree.root).?.last_child.isNull());
    try std.testing.expectEqual(@as(u32, 0), tree.childCount(tree.root));
}

test "destroySubtree removes all descendants and invalidates handles" {
    var tree = try Tree.init(std.testing.allocator);
    defer tree.deinit();

    const keep = try makeChild(&tree, tree.root);
    const branch = try makeChild(&tree, tree.root);
    const b1 = try makeChild(&tree, branch);
    const b2 = try makeChild(&tree, branch);
    const b11 = try makeChild(&tree, b1);
    _ = try makeChild(&tree, b2);
    try std.testing.expectEqual(@as(u32, 7), tree.count());

    const gone = tree.destroySubtree(branch);
    try std.testing.expectEqual(@as(u32, 5), gone);
    try std.testing.expectEqual(@as(u32, 2), tree.count()); // root + keep
    try std.testing.expect(!tree.isValid(branch));
    try std.testing.expect(!tree.isValid(b11));
    try std.testing.expect(tree.isValid(keep));
    try std.testing.expectEqual(@as(u32, 1), tree.childCount(tree.root));
}

test "destroySubtree on a deep chain does not recurse" {
    var tree = try Tree.init(std.testing.allocator);
    defer tree.deinit();

    var parent = tree.root;
    var i: u32 = 0;
    while (i < 5000) : (i += 1) parent = try makeChild(&tree, parent);

    const first = tree.get(tree.root).?.first_child;
    try std.testing.expectEqual(@as(u32, 5000), tree.destroySubtree(first));
    try std.testing.expectEqual(@as(u32, 1), tree.count());
}

test "preorder traversal visits every node once" {
    var tree = try Tree.init(std.testing.allocator);
    defer tree.deinit();

    const a = try makeChild(&tree, tree.root);
    _ = try makeChild(&tree, a);
    _ = try makeChild(&tree, a);
    _ = try makeChild(&tree, tree.root);

    var visited: u32 = 0;
    var cur: ?Handle = tree.root;
    while (cur) |h| : (cur = tree.nextPreorder(tree.root, h)) visited += 1;
    try std.testing.expectEqual(@as(u32, 5), visited);
}

test "layout dirtiness stops at a relayout boundary" {
    var tree = try Tree.init(std.testing.allocator);
    defer tree.deinit();

    const panel = try makeChild(&tree, tree.root);
    const inner = try makeChild(&tree, panel);
    const leaf = try makeChild(&tree, inner);
    tree.get(inner).?.flags.relayout_boundary = true; // fixed-size node

    tree.clearDirty(tree.root);
    tree.markDirty(leaf, DirtyFlags.layout_only);

    try std.testing.expect(tree.get(leaf).?.dirty.layout);
    try std.testing.expect(tree.get(inner).?.dirty.child_layout); // reaches the boundary
    try std.testing.expect(!tree.get(panel).?.dirty.child_layout); // stops there
    try std.testing.expect(!tree.get(tree.root).?.dirty.child_layout);
    // Paint still propagates to the root so the frame knows to redraw.
    try std.testing.expect(tree.get(tree.root).?.dirty.child_paint);
}

test "paint-only change does not mark layout on ancestors" {
    var tree = try Tree.init(std.testing.allocator);
    defer tree.deinit();

    const a = try makeChild(&tree, tree.root);
    tree.clearDirty(tree.root);
    tree.markDirty(a, DirtyFlags.paint_only);

    try std.testing.expect(tree.get(a).?.dirty.paint);
    try std.testing.expect(!tree.get(tree.root).?.dirty.child_layout);
    try std.testing.expect(tree.get(tree.root).?.dirty.child_paint);
}

test "clearDirty resets the whole subtree" {
    var tree = try Tree.init(std.testing.allocator);
    defer tree.deinit();

    const a = try makeChild(&tree, tree.root);
    const b = try makeChild(&tree, a);
    tree.clearDirty(tree.root);
    try std.testing.expect(tree.get(a).?.dirty.isClean());
    try std.testing.expect(tree.get(b).?.dirty.isClean());
    try std.testing.expect(tree.get(tree.root).?.dirty.isClean());
}

test "layout seeding queues the nearest boundary, not the root" {
    var tree = try Tree.init(std.testing.allocator);
    defer tree.deinit();

    const panel = try makeChild(&tree, tree.root);
    const inner = try makeChild(&tree, panel);
    const leaf = try makeChild(&tree, inner);
    tree.get(inner).?.flags.relayout_boundary = true;

    // Drain the initial dirtiness from building the tree.
    while (tree.popLayoutRoot()) |_| {}
    tree.clearDirty(tree.root);

    tree.markDirty(leaf, DirtyFlags.layout_only);
    try std.testing.expect(Handle.eql(tree.popLayoutRoot().?, inner));
    try std.testing.expect(tree.popLayoutRoot() == null);
}

test "a dirty boundary queues itself, once" {
    var tree = try Tree.init(std.testing.allocator);
    defer tree.deinit();

    while (tree.popLayoutRoot()) |_| {}
    tree.clearDirty(tree.root);

    tree.markDirty(tree.root, DirtyFlags.layout_only);
    tree.markDirty(tree.root, DirtyFlags.layout_only);
    try std.testing.expect(Handle.eql(tree.popLayoutRoot().?, tree.root));
    try std.testing.expect(tree.popLayoutRoot() == null);
}

test "building a tree seeds layout at the root" {
    var tree = try Tree.init(std.testing.allocator);
    defer tree.deinit();

    _ = try makeChild(&tree, tree.root);
    try std.testing.expect(Handle.eql(tree.popLayoutRoot().?, tree.root));
    try std.testing.expect(tree.popLayoutRoot() == null);
}

test "paint-only changes seed no layout" {
    var tree = try Tree.init(std.testing.allocator);
    defer tree.deinit();

    const a = try makeChild(&tree, tree.root);
    while (tree.popLayoutRoot()) |_| {}
    tree.clearDirty(tree.root);

    tree.markDirty(a, DirtyFlags.paint_only);
    try std.testing.expect(tree.popLayoutRoot() == null);
}

test "boundaries cleaned since queueing are skipped and re-queue works" {
    var tree = try Tree.init(std.testing.allocator);
    defer tree.deinit();

    const a = try makeChild(&tree, tree.root);
    tree.clearDirty(tree.root); // layout pass "ran" without draining the queue
    try std.testing.expect(tree.popLayoutRoot() == null);

    tree.markDirty(a, DirtyFlags.layout_only);
    try std.testing.expect(Handle.eql(tree.popLayoutRoot().?, tree.root));
}

test "destroying a queued boundary unlinks it from the queue" {
    var tree = try Tree.init(std.testing.allocator);
    defer tree.deinit();

    const b1 = try makeChild(&tree, tree.root);
    const b2 = try makeChild(&tree, tree.root);
    const l1 = try makeChild(&tree, b1);
    const l2 = try makeChild(&tree, b2);
    tree.get(b1).?.flags.relayout_boundary = true;
    tree.get(b2).?.flags.relayout_boundary = true;
    while (tree.popLayoutRoot()) |_| {}
    tree.clearDirty(tree.root);

    tree.markDirty(l1, DirtyFlags.layout_only);
    tree.markDirty(l2, DirtyFlags.layout_only);
    _ = tree.destroySubtree(b2); // top of the stack; also dirties the root's children
    try std.testing.expect(Handle.eql(tree.popLayoutRoot().?, tree.root));
    try std.testing.expect(Handle.eql(tree.popLayoutRoot().?, b1));
    try std.testing.expect(tree.popLayoutRoot() == null);
}
