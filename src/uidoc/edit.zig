//! Editing a document with undo and redo (design doc section 13: "all editing a
//! document model through undo/redo commands").
//!
//! Every change is a `Command` that knows how to apply and revert itself, kept on
//! two stacks. Consecutive edits to the same record (a style or props record of one
//! node) coalesce into a single undo step, so typing a number is one step, not one
//! per keystroke; `breakCoalescing` ends the run (call it when selection changes).
//!
//! Nodes removed by an edit stay in the document's arena, so undoing a removal
//! brings back the very same node (and its uid) with its subtree intact.

const std = @import("std");
const Allocator = std.mem.Allocator;
const doc_mod = @import("doc.zig");
const zon = @import("zon.zig");
const Doc = doc_mod.Doc;
const Node = doc_mod.Node;

pub const Which = enum { style, props };

pub const Error = error{ NoSuchNode, InvalidMove, CannotEditRoot } || Allocator.Error;


const Command = union(enum) {
    set_record: struct { uid: u32, which: Which, old: zon.Value, new: zon.Value },
    set_id: struct { uid: u32, old: []const u8, new: []const u8 },
    set_on: struct { uid: u32, old: []const doc_mod.EventBinding, new: []const doc_mod.EventBinding },
    insert: struct { parent: u32, index: usize, node: *Node },
    remove: struct { node: *Node, parent: u32, index: usize },
    move: struct { node: *Node, from_parent: u32, from_index: usize, to_parent: u32, to_index: usize },
    /// Several commands that undo and redo as one step.
    batch: []const Command,
};

pub const Editor = struct {
    gpa: Allocator,
    doc: Doc,
    undo_stack: std.ArrayListUnmanaged(Command) = .empty,
    redo_stack: std.ArrayListUnmanaged(Command) = .empty,
    /// Bumped by every change, undo, and redo.
    version: u32 = 0,
    /// The last command was a record edit that the next one may merge into.
    coalescing: bool = false,
    /// The single top-level field that edit changed (edits to other fields do
    /// not merge into it), or null if it changed several.
    coalesce_key: ?[]const u8 = null,
    batch_depth: u32 = 0,
    batch_cmds: std.ArrayListUnmanaged(Command) = .empty,

    pub fn init(gpa: Allocator, doc: Doc) Editor {
        return .{ .gpa = gpa, .doc = doc };
    }

    pub fn deinit(self: *Editor) void {
        self.batch_cmds.deinit(self.gpa);
        self.undo_stack.deinit(self.gpa);
        self.redo_stack.deinit(self.gpa);
        self.doc.deinit();
    }

    pub fn canUndo(self: *const Editor) bool {
        return self.undo_stack.items.len > 0;
    }

    pub fn canRedo(self: *const Editor) bool {
        return self.redo_stack.items.len > 0;
    }

    pub fn breakCoalescing(self: *Editor) void {
        self.coalescing = false;
    }

    fn node(self: *Editor, uid: u32) Error!*Node {
        return self.doc.find(uid) orelse error.NoSuchNode;
    }

    fn parentUid(n: *const Node) u32 {
        return n.parent.?.uid;
    }

    fn apply(self: *Editor, cmd: Command) Error!void {
        switch (cmd) {
            .set_record => |c| {
                const n = try self.node(c.uid);
                switch (c.which) {
                    .style => n.style = c.new,
                    .props => n.props = c.new,
                }
            },
            .set_id => |c| (try self.node(c.uid)).id = c.new,
            .set_on => |c| (try self.node(c.uid)).on = c.new,
            .insert => |c| try self.doc.insert(try self.node(c.parent), c.index, c.node),
            .remove => |c| _ = self.doc.detach(c.node),
            .move => |c| {
                _ = self.doc.detach(c.node);
                try self.doc.insert(try self.node(c.to_parent), c.to_index, c.node);
            },
            .batch => |cmds| for (cmds) |sub| try self.apply(sub),
        }
    }

    fn revert(self: *Editor, cmd: Command) Error!void {
        switch (cmd) {
            .set_record => |c| {
                const n = try self.node(c.uid);
                switch (c.which) {
                    .style => n.style = c.old,
                    .props => n.props = c.old,
                }
            },
            .set_id => |c| (try self.node(c.uid)).id = c.old,
            .set_on => |c| (try self.node(c.uid)).on = c.old,
            .insert => |c| _ = self.doc.detach(c.node),
            .remove => |c| try self.doc.insert(try self.node(c.parent), c.index, c.node),
            .move => |c| {
                _ = self.doc.detach(c.node);
                try self.doc.insert(try self.node(c.from_parent), c.from_index, c.node);
            },
            .batch => |cmds| {
                var i = cmds.len;
                while (i > 0) {
                    i -= 1;
                    try self.revert(cmds[i]);
                }
            },
        }
    }

    fn exec(self: *Editor, cmd: Command) Error!void {
        if (self.batch_depth > 0) {
            try self.batch_cmds.ensureUnusedCapacity(self.gpa, 1);
            try self.apply(cmd);
            self.batch_cmds.appendAssumeCapacity(cmd);
            self.redo_stack.clearRetainingCapacity();
            self.version +%= 1;
            self.coalescing = false;
            return;
        }
        // Make room first so a failure leaves nothing half-done.
        try self.undo_stack.ensureUnusedCapacity(self.gpa, 1);
        try self.apply(cmd);
        self.undo_stack.appendAssumeCapacity(cmd);
        self.redo_stack.clearRetainingCapacity();
        self.version +%= 1;
        self.coalescing = false;
    }

    pub fn undo(self: *Editor) Error!bool {
        const cmd = self.undo_stack.pop() orelse return false;
        try self.redo_stack.ensureUnusedCapacity(self.gpa, 1);
        try self.revert(cmd);
        self.redo_stack.appendAssumeCapacity(cmd);
        self.version +%= 1;
        self.coalescing = false;
        return true;
    }

    pub fn redo(self: *Editor) Error!bool {
        const cmd = self.redo_stack.pop() orelse return false;
        try self.undo_stack.ensureUnusedCapacity(self.gpa, 1);
        try self.apply(cmd);
        self.undo_stack.appendAssumeCapacity(cmd);
        self.version +%= 1;
        self.coalescing = false;
        return true;
    }

    // ---- batches ----

    /// Start grouping edits: everything done until the matching `endBatch`
    /// undoes and redoes as one step. Batches nest (only the outermost counts).
    pub fn beginBatch(self: *Editor) void {
        self.batch_depth += 1;
    }

    /// Finish a batch. If one of its edits failed, call `abortBatch` instead.
    pub fn endBatch(self: *Editor) Error!void {
        std.debug.assert(self.batch_depth > 0);
        self.batch_depth -= 1;
        if (self.batch_depth > 0 or self.batch_cmds.items.len == 0) return;
        const cmds = try self.doc.alloc().dupe(Command, self.batch_cmds.items);
        self.batch_cmds.clearRetainingCapacity();
        try self.undo_stack.append(self.gpa, .{ .batch = cmds });
    }

    /// Undo whatever the open batch did so far and close it.
    pub fn abortBatch(self: *Editor) void {
        std.debug.assert(self.batch_depth > 0);
        self.batch_depth -= 1;
        var i = self.batch_cmds.items.len;
        while (i > 0) {
            i -= 1;
            self.revert(self.batch_cmds.items[i]) catch {};
        }
        self.batch_cmds.clearRetainingCapacity();
        if (self.batch_depth == 0) self.version +%= 1;
    }

    // ---- the editing operations ----

    /// Add a new node of `type_name` under `parent` at `index`.
    pub fn addNode(self: *Editor, parent: u32, index: usize, type_name: []const u8) Error!*Node {
        const p = try self.node(parent);
        const n = try self.doc.newNode(type_name);
        const at = @min(index, p.children.items.len);
        try self.exec(.{ .insert = .{ .parent = parent, .index = at, .node = n } });
        return n;
    }

    /// Insert an already-built detached node (paste, templates).
    pub fn insertNode(self: *Editor, parent: u32, index: usize, n: *Node) Error!void {
        const p = try self.node(parent);
        try self.exec(.{ .insert = .{ .parent = parent, .index = @min(index, p.children.items.len), .node = n } });
    }

    pub fn removeNode(self: *Editor, uid: u32) Error!void {
        const n = try self.node(uid);
        if (n == self.doc.root) return error.CannotEditRoot;
        try self.exec(.{ .remove = .{ .node = n, .parent = parentUid(n), .index = n.indexInParent().? } });
    }

    /// Move `uid` under `to_parent`; `to_index` counts siblings after `uid` has
    /// been taken out of its old place.
    pub fn moveNode(self: *Editor, uid: u32, to_parent: u32, to_index: usize) Error!void {
        const n = try self.node(uid);
        if (n == self.doc.root) return error.CannotEditRoot;
        const dest = try self.node(to_parent);
        if (dest == n or n.isAncestorOf(dest)) return error.InvalidMove;
        const from_index = n.indexInParent().?;
        const same = dest == n.parent.?;
        const count = dest.children.items.len - @as(usize, if (same) 1 else 0);
        const at = @min(to_index, count);
        if (same and at == from_index) return;
        try self.exec(.{ .move = .{ .node = n, .from_parent = parentUid(n), .from_index = from_index, .to_parent = to_parent, .to_index = at } });
    }

    /// Copy `uid` and its subtree and put the copy right after it; returns the copy.
    pub fn duplicateNode(self: *Editor, uid: u32) Error!*Node {
        const n = try self.node(uid);
        if (n == self.doc.root) return error.CannotEditRoot;
        const copy = try self.doc.cloneNode(n);
        try self.insertNode(parentUid(n), n.indexInParent().? + 1, copy);
        return copy;
    }

    /// Put `uid` inside a new node of `type_name` (a box) where it was; returns
    /// the wrapper. One undo step.
    pub fn wrapNode(self: *Editor, uid: u32, type_name: []const u8) Error!*Node {
        const n = try self.node(uid);
        if (n == self.doc.root) return error.CannotEditRoot;
        const parent = parentUid(n);
        const index = n.indexInParent().?;
        self.beginBatch();
        errdefer self.abortBatch();
        const w = try self.addNode(parent, index, type_name);
        try self.moveNode(uid, w.uid, 0);
        try self.endBatch();
        return w;
    }

    /// Replace `uid` by its children, in place. One undo step.
    pub fn unwrapNode(self: *Editor, uid: u32) Error!void {
        const n = try self.node(uid);
        if (n == self.doc.root) return error.CannotEditRoot;
        const parent = parentUid(n);
        const at = n.indexInParent().?;
        self.beginBatch();
        errdefer self.abortBatch();
        var moved: usize = 0;
        while (n.children.items.len > 0) {
            // The first child goes right where the wrapper is, pushing it along.
            try self.moveNode(n.children.items[0].uid, parent, at + moved);
            moved += 1;
        }
        try self.removeNode(uid);
        try self.endBatch();
    }

    /// Move `uid` into the end of the sibling before it, if that is a box.
    pub fn indentNode(self: *Editor, uid: u32) Error!void {
        const n = try self.node(uid);
        if (n == self.doc.root) return error.CannotEditRoot;
        const i = n.indexInParent().?;
        if (i == 0) return error.InvalidMove;
        const prev = n.parent.?.children.items[i - 1];
        if (!std.mem.eql(u8, prev.type_name, doc_mod.box_type)) return error.InvalidMove;
        try self.moveNode(uid, prev.uid, prev.children.items.len);
    }

    /// Move `uid` out of its parent, to just after it.
    pub fn outdentNode(self: *Editor, uid: u32) Error!void {
        const n = try self.node(uid);
        if (n == self.doc.root) return error.CannotEditRoot;
        const p = n.parent.?;
        const gp = p.parent orelse return error.InvalidMove;
        try self.moveNode(uid, gp.uid, p.indexInParent().? + 1);
    }

    /// Insert a node built from a ZON record (a pasted subtree) under `parent`.
    pub fn pasteValue(self: *Editor, parent: u32, index: usize, value: zon.Value) Error!*Node {
        const n = self.doc.parseNode(value, null) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.InvalidMove,
        };
        try self.insertNode(parent, index, n);
        return n;
    }

    /// Replace a node's style or props record. Consecutive calls for the same
    /// record merge into one undo step.
    pub fn setRecord(self: *Editor, uid: u32, which: Which, value: zon.Value) Error!void {
        const n = try self.node(uid);
        const old = switch (which) {
            .style => n.style,
            .props => n.props,
        };
        if (old.eql(value)) return;
        const copy = try self.doc.copyValue(value);
        const key = changedKey(old, copy);
        if (self.coalescing and key != null and self.coalesce_key != null and std.mem.eql(u8, key.?, self.coalesce_key.?) and self.undo_stack.items.len > 0) {
            switch (self.undo_stack.items[self.undo_stack.items.len - 1]) {
                .set_record => |*last| if (last.uid == uid and last.which == which) {
                    last.new = copy;
                    try self.apply(.{ .set_record = last.* });
                    self.redo_stack.clearRetainingCapacity();
                    self.version +%= 1;
                    return;
                },
                else => {},
            }
        }
        try self.exec(.{ .set_record = .{ .uid = uid, .which = which, .old = old, .new = copy } });
        self.coalescing = true;
        self.coalesce_key = key;
    }

    /// The one top-level field in which two records differ, if exactly one does.
    fn changedKey(old: zon.Value, new: zon.Value) ?[]const u8 {
        var found: ?[]const u8 = null;
        const of: []const zon.Field = old.fields() orelse &.{};
        const nf: []const zon.Field = new.fields() orelse &.{};
        for (nf) |f| {
            const same = if (old.field(f.name)) |o| o.eql(f.value) else false;
            if (same) continue;
            if (found != null) return null;
            found = f.name;
        }
        for (of) |f| {
            if (new.field(f.name) != null) continue;
            if (found != null) return null;
            found = f.name;
        }
        return found;
    }

    pub fn setId(self: *Editor, uid: u32, id: []const u8) Error!void {
        const n = try self.node(uid);
        if (std.mem.eql(u8, n.id, id)) return;
        try self.exec(.{ .set_id = .{ .uid = uid, .old = n.id, .new = try self.doc.alloc().dupe(u8, id) } });
    }

    /// Bind `event` to `action` (an empty action clears the binding).
    pub fn setEvent(self: *Editor, uid: u32, event: []const u8, action: []const u8) Error!void {
        const n = try self.node(uid);
        const old = n.on;
        try self.doc.setEvent(n, event, action); // builds the new slice in the arena
        const new = n.on;
        n.on = old;
        if (sameBindings(old, new)) return;
        try self.exec(.{ .set_on = .{ .uid = uid, .old = old, .new = new } });
    }

    fn sameBindings(a: []const doc_mod.EventBinding, b: []const doc_mod.EventBinding) bool {
        if (a.len != b.len) return false;
        for (a, b) |x, y| {
            if (!std.mem.eql(u8, x.event, y.event) or !std.mem.eql(u8, x.action, y.action)) return false;
        }
        return true;
    }
};

// ---- tests -----------------------------------------------------------------

const testing = std.testing;

fn newEditor() !Editor {
    return Editor.init(testing.allocator, try Doc.init(testing.allocator));
}

fn snapshot(e: *Editor) ![]u8 {
    return e.doc.toZon(testing.allocator);
}

fn rec(e: *Editor, src: []const u8) !zon.Value {
    return zon.parse(e.doc.alloc(), src, null);
}

test "add and remove nodes, undo and redo restore the exact tree" {
    var e = try newEditor();
    defer e.deinit();
    const empty = try snapshot(&e);
    defer testing.allocator.free(empty);

    const a = try e.addNode(e.doc.root.uid, 0, "label");
    const b = try e.addNode(e.doc.root.uid, 1, "box");
    _ = try e.addNode(b.uid, 0, "button");
    const full = try snapshot(&e);
    defer testing.allocator.free(full);

    try e.removeNode(b.uid);
    try testing.expectEqual(@as(usize, 1), e.doc.root.children.items.len);
    try testing.expect(e.doc.find(b.uid) == null);

    try testing.expect(try e.undo());
    const back = try snapshot(&e);
    defer testing.allocator.free(back);
    try testing.expectEqualStrings(full, back);
    try testing.expect(e.doc.find(b.uid) == b); // the same node, with its child
    try testing.expectEqual(@as(usize, 1), b.children.items.len);

    try testing.expect(try e.redo());
    try testing.expect(e.doc.find(b.uid) == null);
    try testing.expect(try e.undo());
    try testing.expect(try e.undo());
    try testing.expect(try e.undo());
    try testing.expect(try e.undo());
    const none = try snapshot(&e);
    defer testing.allocator.free(none);
    try testing.expectEqualStrings(empty, none);
    try testing.expect(!try e.undo());
    _ = a;
}

test "a new edit clears the redo stack; version tracks every change" {
    var e = try newEditor();
    defer e.deinit();
    const v0 = e.version;
    _ = try e.addNode(e.doc.root.uid, 0, "label");
    _ = try e.undo();
    try testing.expect(e.canRedo());
    _ = try e.addNode(e.doc.root.uid, 0, "button");
    try testing.expect(!e.canRedo());
    try testing.expect(e.version != v0);
    try testing.expect(e.canUndo());
}

test "record edits coalesce until the run is broken" {
    var e = try newEditor();
    defer e.deinit();
    const n = try e.addNode(e.doc.root.uid, 0, "label");
    try e.setRecord(n.uid, .props, try rec(&e, ".{ .text = \"a\" }"));
    try e.setRecord(n.uid, .props, try rec(&e, ".{ .text = \"ab\" }"));
    try e.setRecord(n.uid, .props, try rec(&e, ".{ .text = \"abc\" }"));
    try testing.expectEqualStrings("abc", n.props.field("text").?.string);
    _ = try e.undo(); // one step undoes all three
    try testing.expect(n.props.fields().?.len == 0);
    _ = try e.redo();
    try testing.expectEqualStrings("abc", n.props.field("text").?.string);

    e.breakCoalescing();
    try e.setRecord(n.uid, .props, try rec(&e, ".{ .text = \"abcd\" }"));
    _ = try e.undo();
    try testing.expectEqualStrings("abc", n.props.field("text").?.string);

    // A different field, a different record, or another command in between
    // starts a new step.
    try e.setRecord(n.uid, .props, try rec(&e, ".{ .text = \"abc\", .size = 3 }"));
    try e.setRecord(n.uid, .props, try rec(&e, ".{ .text = \"abc\", .size = 30 }"));
    _ = try e.undo();
    try testing.expect(n.props.field("size") == null);
    try testing.expectEqualStrings("abc", n.props.field("text").?.string);

    try e.setRecord(n.uid, .style, try rec(&e, ".{ .grow = 1 }"));
    try e.setRecord(n.uid, .props, try rec(&e, ".{ .text = \"z\" }"));
    _ = try e.undo();
    try testing.expectEqualStrings("abc", n.props.field("text").?.string);
    try testing.expect(n.style.field("grow") != null);
}

test "setting a record to its current value is not an undo step" {
    var e = try newEditor();
    defer e.deinit();
    const n = try e.addNode(e.doc.root.uid, 0, "label");
    const before = e.undo_stack.items.len;
    try e.setRecord(n.uid, .props, try rec(&e, ".{}"));
    try e.setId(n.uid, "");
    try e.setEvent(n.uid, "click", "");
    try testing.expectEqual(before, e.undo_stack.items.len);
}

test "ids and event bindings undo" {
    var e = try newEditor();
    defer e.deinit();
    const n = try e.addNode(e.doc.root.uid, 0, "button");
    try e.setId(n.uid, "ok");
    try e.setEvent(n.uid, "click", "go");
    try e.setEvent(n.uid, "click", "stop");
    try testing.expectEqualStrings("ok", n.id);
    try testing.expectEqualStrings("stop", n.on[0].action);
    _ = try e.undo();
    try testing.expectEqualStrings("go", n.on[0].action);
    _ = try e.undo();
    try testing.expectEqual(@as(usize, 0), n.on.len);
    _ = try e.undo();
    try testing.expectEqualStrings("", n.id);
    _ = try e.redo();
    _ = try e.redo();
    try testing.expectEqualStrings("ok", n.id);
    try testing.expectEqualStrings("go", n.on[0].action);
}

test "moving nodes: reorder, reparent, and the guarded cases" {
    var e = try newEditor();
    defer e.deinit();
    const root = e.doc.root.uid;
    const a = try e.addNode(root, 0, "label");
    const b = try e.addNode(root, 1, "box");
    const c = try e.addNode(root, 2, "button");
    // Reorder: put c first.
    try e.moveNode(c.uid, root, 0);
    try testing.expect(e.doc.root.children.items[0] == c and e.doc.root.children.items[2] == b);
    // Into a box.
    try e.moveNode(a.uid, b.uid, 0);
    try testing.expect(a.parent == b);
    try testing.expectEqual(@as(usize, 2), e.doc.root.children.items.len);
    // Not into itself or a descendant; not the root.
    try testing.expectError(error.InvalidMove, e.moveNode(b.uid, b.uid, 0));
    try testing.expectError(error.InvalidMove, e.moveNode(b.uid, a.uid, 0));
    try testing.expectError(error.CannotEditRoot, e.moveNode(root, b.uid, 0));
    try testing.expectError(error.CannotEditRoot, e.removeNode(root));
    try testing.expectError(error.NoSuchNode, e.removeNode(9999));
    // Moving to where it already is is a no-op.
    const steps = e.undo_stack.items.len;
    try e.moveNode(c.uid, root, 0);
    try testing.expectEqual(steps, e.undo_stack.items.len);

    try testing.expect(try e.undo()); // a back to the root
    try testing.expect(a.parent == e.doc.root and a.indexInParent().? == 1);
    try testing.expect(try e.undo()); // c back to the end
    try testing.expect(e.doc.root.children.items[2] == c);
    try testing.expect(e.doc.root.children.items[0] == a);
}

test "an edit that fails to allocate leaves the document unchanged" {
    var i: usize = 0;
    while (i < 12) : (i += 1) {
        var fa = std.testing.FailingAllocator.init(testing.allocator, .{ .fail_index = i });
        var doc = Doc.init(testing.allocator) catch continue;
        var e = Editor.init(fa.allocator(), doc);
        defer e.deinit();
        _ = &doc;
        const before = e.undo_stack.items.len;
        _ = e.addNode(e.doc.root.uid, 0, "label") catch {
            try testing.expectEqual(before, e.undo_stack.items.len);
            try testing.expectEqual(@as(usize, 0), e.doc.root.children.items.len);
        };
    }
}

fn shape(e: *Editor, n: *Node, out: *std.ArrayListUnmanaged(u8)) !void {
    try out.print(testing.allocator, "{s}", .{n.type_name});
    if (n.children.items.len > 0) {
        try out.append(testing.allocator, '(');
        for (n.children.items, 0..) |c, i| {
            if (i > 0) try out.append(testing.allocator, ',');
            try shape(e, c, out);
        }
        try out.append(testing.allocator, ')');
    }
}

/// The tree as "box(label,box(button))".
fn treeShape(e: *Editor) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(testing.allocator);
    try shape(e, e.doc.root, &out);
    return out.toOwnedSlice(testing.allocator);
}

fn expectShape(e: *Editor, want: []const u8) !void {
    const got = try treeShape(e);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(want, got);
}

test "a batch undoes and redoes as one step, and aborting rolls back" {
    var e = try newEditor();
    defer e.deinit();
    const root = e.doc.root.uid;
    e.beginBatch();
    _ = try e.addNode(root, 0, "label");
    _ = try e.addNode(root, 1, "button");
    try e.endBatch();
    try expectShape(&e, "box(label,button)");
    try testing.expectEqual(@as(usize, 1), e.undo_stack.items.len);
    _ = try e.undo();
    try expectShape(&e, "box");
    _ = try e.redo();
    try expectShape(&e, "box(label,button)");

    e.beginBatch();
    _ = try e.addNode(root, 2, "box");
    try e.removeNode(e.doc.root.children.items[0].uid);
    try expectShape(&e, "box(button,box)");
    e.abortBatch();
    try expectShape(&e, "box(label,button)");
    try testing.expectEqual(@as(usize, 1), e.undo_stack.items.len);

    // Nested batches join the outer one; an empty batch records nothing.
    e.beginBatch();
    e.beginBatch();
    _ = try e.addNode(root, 0, "label");
    try e.endBatch();
    try e.endBatch();
    e.beginBatch();
    try e.endBatch();
    try testing.expectEqual(@as(usize, 2), e.undo_stack.items.len);
}

test "duplicate copies a subtree with fresh uids and no ids" {
    var e = try newEditor();
    defer e.deinit();
    const root = e.doc.root.uid;
    const box = try e.addNode(root, 0, "box");
    const label = try e.addNode(box.uid, 0, "label");
    try e.setId(box.uid, "panel");
    try e.setRecord(label.uid, .props, try rec(&e, ".{ .text = \"hi\" }"));
    const copy = try e.duplicateNode(box.uid);
    try expectShape(&e, "box(box(label),box(label))");
    try testing.expect(copy != box and copy.uid != box.uid);
    try testing.expectEqual(@as(usize, 1), copy.indexInParent().? - box.indexInParent().?);
    try testing.expectEqualStrings("", copy.id);
    try testing.expectEqualStrings("hi", copy.children.items[0].props.field("text").?.string);
    try testing.expect(copy.children.items[0].uid != label.uid);
    // Editing the copy leaves the original alone.
    try e.setRecord(copy.children.items[0].uid, .props, try rec(&e, ".{ .text = \"changed\" }"));
    try testing.expectEqualStrings("hi", label.props.field("text").?.string);
    _ = try e.undo();
    _ = try e.undo();
    try expectShape(&e, "box(box(label))");
    try testing.expectError(error.CannotEditRoot, e.duplicateNode(root));
}

test "wrap puts a node in a new box in place; unwrap puts the children back" {
    var e = try newEditor();
    defer e.deinit();
    const root = e.doc.root.uid;
    const a = try e.addNode(root, 0, "label");
    const b = try e.addNode(root, 1, "button");
    const c = try e.addNode(root, 2, "label");
    const w = try e.wrapNode(b.uid, "box");
    try expectShape(&e, "box(label,box(button),label)");
    try testing.expect(b.parent == w and w.indexInParent().? == 1);
    _ = try e.undo();
    try expectShape(&e, "box(label,button,label)");
    _ = try e.redo();

    // Unwrapping restores the order, even for a wrapper with several children.
    const d = try e.addNode(w.uid, 1, "label");
    try e.unwrapNode(w.uid);
    try expectShape(&e, "box(label,button,label,label)");
    try testing.expect(e.doc.root.children.items[1] == b and e.doc.root.children.items[2] == d and e.doc.root.children.items[3] == c);
    _ = try e.undo();
    try expectShape(&e, "box(label,box(button,label),label)");
    try testing.expect(w.parent == e.doc.root and b.parent == w);
    _ = a;
    try testing.expectError(error.CannotEditRoot, e.wrapNode(root, "box"));
    try testing.expectError(error.CannotEditRoot, e.unwrapNode(root));
}

test "indent and outdent change nesting without changing order" {
    var e = try newEditor();
    defer e.deinit();
    const root = e.doc.root.uid;
    _ = try e.addNode(root, 0, "label");
    const box = try e.addNode(root, 1, "box");
    const x = try e.addNode(root, 2, "button");
    try e.indentNode(x.uid);
    try expectShape(&e, "box(label,box(button))");
    try testing.expect(x.parent == box);
    try e.outdentNode(x.uid);
    try expectShape(&e, "box(label,box,button)");
    try testing.expectError(error.InvalidMove, e.outdentNode(box.uid)); // its parent is the root
    try testing.expectError(error.InvalidMove, e.indentNode(e.doc.root.children.items[0].uid)); // nothing before it
    try testing.expectError(error.InvalidMove, e.indentNode(box.uid)); // the previous sibling is a label
    _ = try e.undo();
    try expectShape(&e, "box(label,box(button))");
}

test "pasting a ZON record inserts a subtree with fresh uids" {
    var e = try newEditor();
    defer e.deinit();
    const root = e.doc.root.uid;
    const pasted = try e.pasteValue(root, 0, try rec(&e, ".{ .type = \"box\", .children = .{ .{ .type = \"label\", .props = .{ .text = \"p\" } } } }"));
    try expectShape(&e, "box(box(label))");
    try testing.expectEqualStrings("p", pasted.children.items[0].props.field("text").?.string);
    try testing.expectError(error.InvalidMove, e.pasteValue(root, 0, try rec(&e, ".{ .nonsense = 1 }")));
    _ = try e.undo();
    try expectShape(&e, "box");
}
