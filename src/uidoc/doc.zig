//! UI document model (design doc section 13).
//!
//! A document is a tree of nodes, each a widget type name (or `"box"` for a plain
//! container) with a sparse `style`, sparse `props`, event bindings (`on`), an
//! optional `id`, and children. Style and props are ZON records holding only what
//! differs from the defaults, so files stay small and diff well.
//!
//!     .{
//!         .version = 1,
//!         .root = .{
//!             .type = "box",
//!             .style = .{ .direction = .column, .gap = 8, .padding = .{ .left = 12, .top = 12 } },
//!             .children = .{
//!                 .{ .type = "label", .props = .{ .text = "Hello" } },
//!                 .{ .type = "button", .id = "ok", .props = .{ .text = "OK" }, .on = .{ .click = "confirm" } },
//!             },
//!         },
//!     }
//!
//! The same model is what the builder edits. All memory lives in the document's
//! arena and is released together; nodes removed by an edit stay allocated until
//! then, so undo can bring them back without copying.

const std = @import("std");
const Allocator = std.mem.Allocator;
const zon = @import("zon.zig");

pub const box_type = "box";
pub const format_version: i64 = 1;

pub const EventBinding = struct { event: []const u8, action: []const u8 };

pub const Node = struct {
    /// Stable identity within the document (never reused), for selection and history.
    uid: u32,
    /// A registered widget name, or `"box"`.
    type_name: []const u8,
    /// Optional name the app can look the instance up by.
    id: []const u8 = "",
    style: zon.Value = .{ .record = &.{} },
    props: zon.Value = .{ .record = &.{} },
    on: []const EventBinding = &.{},
    children: std.ArrayListUnmanaged(*Node) = .empty,
    parent: ?*Node = null,

    pub fn indexInParent(self: *const Node) ?usize {
        const p = self.parent orelse return null;
        for (p.children.items, 0..) |c, i| if (c == self) return i;
        return null;
    }

    pub fn isAncestorOf(self: *const Node, other: *const Node) bool {
        var n: ?*const Node = other.parent;
        while (n) |x| : (n = x.parent) if (x == self) return true;
        return false;
    }
};

/// What is wrong with a document being read.
pub const Problem = struct {
    /// Static text.
    message: []const u8,
    /// The offending key or value, borrowed from the parsed tree ("" if none).
    detail: []const u8 = "",
};

pub const Doc = struct {
    arena: std.heap.ArenaAllocator,
    root: *Node,
    next_uid: u32 = 1,

    pub fn init(gpa: Allocator) !Doc {
        var self: Doc = .{ .arena = std.heap.ArenaAllocator.init(gpa), .root = undefined };
        errdefer self.arena.deinit();
        self.root = try self.newNode(box_type);
        return self;
    }

    pub fn deinit(self: *Doc) void {
        self.arena.deinit();
    }

    pub fn alloc(self: *Doc) Allocator {
        return self.arena.allocator();
    }

    /// A detached node. Attach it with `insert`.
    pub fn newNode(self: *Doc, type_name: []const u8) !*Node {
        const n = try self.alloc().create(Node);
        n.* = .{ .uid = self.next_uid, .type_name = try self.alloc().dupe(u8, type_name) };
        self.next_uid += 1;
        return n;
    }

    pub fn find(self: *Doc, uid: u32) ?*Node {
        return findIn(self.root, uid);
    }

    fn findIn(n: *Node, uid: u32) ?*Node {
        if (n.uid == uid) return n;
        for (n.children.items) |c| if (findIn(c, uid)) |hit| return hit;
        return null;
    }

    /// Attach a detached `child` under `parent` at `index` (clamped).
    pub fn insert(self: *Doc, parent: *Node, index: usize, child: *Node) !void {
        std.debug.assert(child.parent == null);
        std.debug.assert(child != self.root and child != parent and !child.isAncestorOf(parent));
        const at = @min(index, parent.children.items.len);
        try parent.children.insert(self.alloc(), at, child);
        child.parent = parent;
    }

    /// Detach `node` from its parent; its subtree stays intact. Returns the
    /// index it had.
    pub fn detach(self: *Doc, node: *Node) usize {
        _ = self;
        const p = node.parent.?;
        const i = node.indexInParent().?;
        _ = p.children.orderedRemove(i);
        node.parent = null;
        return i;
    }

    pub fn setId(self: *Doc, node: *Node, id: []const u8) !void {
        node.id = try self.alloc().dupe(u8, id);
    }

    pub fn setEvent(self: *Doc, node: *Node, event: []const u8, action: []const u8) !void {
        var list: std.ArrayListUnmanaged(EventBinding) = .empty;
        var replaced = false;
        for (node.on) |b| {
            if (std.mem.eql(u8, b.event, event)) {
                replaced = true;
                if (action.len > 0) try list.append(self.alloc(), .{ .event = b.event, .action = try self.alloc().dupe(u8, action) });
            } else try list.append(self.alloc(), b);
        }
        if (!replaced and action.len > 0) {
            try list.append(self.alloc(), .{ .event = try self.alloc().dupe(u8, event), .action = try self.alloc().dupe(u8, action) });
        }
        node.on = list.items;
    }

    // ---- reading ----

    /// Build a document from parsed ZON. Structure is checked here (known keys,
    /// types); that props and styles name real fields and fit their types is
    /// checked when the document is instantiated.
    pub fn fromValue(gpa: Allocator, v: zon.Value, problem: ?*Problem) !Doc {
        var self = try Doc.init(gpa);
        errdefer self.deinit();
        if (v.fields() == null) return fail(problem, "a document is a record", "");
        for (v.fields().?) |f| {
            if (std.mem.eql(u8, f.name, "version")) {
                if (f.value != .int or f.value.int != format_version) return fail(problem, "unsupported version", f.name);
            } else if (!std.mem.eql(u8, f.name, "root")) return fail(problem, "unknown key at the top level", f.name);
        }
        const root_v = v.field("root") orelse return fail(problem, "missing .root", "");
        const root = try self.readNode(root_v, problem);
        self.root = root;
        return self;
    }

    fn fail(problem: ?*Problem, message: []const u8, detail: []const u8) error{InvalidDocument} {
        if (problem) |p| p.* = .{ .message = message, .detail = detail };
        return error.InvalidDocument;
    }

    /// A detached node (with its subtree) built from a ZON node record (what
    /// `nodeToValue` writes). Attach it with `insert`.
    pub fn parseNode(self: *Doc, v: zon.Value, problem: ?*Problem) !*Node {
        return self.readNode(v, problem);
    }

    fn readNode(self: *Doc, v: zon.Value, problem: ?*Problem) !*Node {
        const fs = v.fields() orelse return fail(problem, "a node is a record", "");
        const type_v = v.field("type") orelse return fail(problem, "node is missing .type", "");
        if (type_v != .string) return fail(problem, ".type must be a string", "");
        const node = try self.newNode(type_v.string);
        for (fs) |f| {
            const name = f.name;
            if (std.mem.eql(u8, name, "type")) continue;
            if (std.mem.eql(u8, name, "id")) {
                if (f.value != .string) return fail(problem, ".id must be a string", name);
                try self.setId(node, f.value.string);
            } else if (std.mem.eql(u8, name, "style") or std.mem.eql(u8, name, "props")) {
                if (f.value.fields() == null) return fail(problem, "must be a record", name);
                const copy = try self.copyValue(f.value);
                if (name[0] == 's') node.style = copy else node.props = copy;
            } else if (std.mem.eql(u8, name, "on")) {
                const evs = f.value.fields() orelse return fail(problem, ".on must be a record of event = \"action\"", name);
                for (evs) |e| {
                    if (e.value != .string) return fail(problem, "an action name must be a string", e.name);
                    try self.setEvent(node, e.name, e.value.string);
                }
            } else if (std.mem.eql(u8, name, "children")) {
                const items = f.value.items() orelse return fail(problem, ".children must be a list of nodes", name);
                for (items) |c| {
                    const child = try self.readNode(c, problem);
                    try self.insert(node, node.children.items.len, child);
                }
            } else return fail(problem, "unknown node key", name);
        }
        return node;
    }

    /// Deep copy of `v` into the document's arena.
    pub fn copyValue(self: *Doc, v: zon.Value) Allocator.Error!zon.Value {
        const a = self.alloc();
        return switch (v) {
            .none, .bool, .int, .float => v,
            .string => |s| .{ .string = try a.dupe(u8, s) },
            .tag => |s| .{ .tag = try a.dupe(u8, s) },
            .record => |fs| blk: {
                const out = try a.alloc(zon.Field, fs.len);
                for (fs, 0..) |f, i| out[i] = .{ .name = try a.dupe(u8, f.name), .value = try self.copyValue(f.value) };
                break :blk .{ .record = out };
            },
            .list => |items| blk: {
                const out = try a.alloc(zon.Value, items.len);
                for (items, 0..) |x, i| out[i] = try self.copyValue(x);
                break :blk .{ .list = out };
            },
        };
    }

    // ---- writing ----

    fn isEmpty(v: zon.Value) bool {
        const fs = v.fields() orelse return true;
        return fs.len == 0;
    }

    /// The ZON record for `n` and its subtree.
    pub fn nodeToValue(self: *Doc, n: *const Node) Allocator.Error!zon.Value {
        return self.nodeValue(n);
    }

    /// A detached copy of `n` and its subtree with fresh uids. Ids are dropped
    /// (they are meant to be unique).
    pub fn cloneNode(self: *Doc, n: *const Node) Allocator.Error!*Node {
        const c = try self.newNode(n.type_name);
        c.style = n.style;
        c.props = n.props;
        c.on = n.on;
        for (n.children.items) |child| {
            const cc = try self.cloneNode(child);
            cc.parent = c;
            try c.children.append(self.alloc(), cc);
        }
        return c;
    }

    fn nodeValue(self: *Doc, n: *const Node) Allocator.Error!zon.Value {
        const a = self.alloc();
        var fs: std.ArrayListUnmanaged(zon.Field) = .empty;
        try fs.append(a, .{ .name = "type", .value = .{ .string = n.type_name } });
        if (n.id.len > 0) try fs.append(a, .{ .name = "id", .value = .{ .string = n.id } });
        if (!isEmpty(n.style)) try fs.append(a, .{ .name = "style", .value = n.style });
        if (!isEmpty(n.props)) try fs.append(a, .{ .name = "props", .value = n.props });
        if (n.on.len > 0) {
            const evs = try a.alloc(zon.Field, n.on.len);
            for (n.on, 0..) |b, i| evs[i] = .{ .name = b.event, .value = .{ .string = b.action } };
            try fs.append(a, .{ .name = "on", .value = .{ .record = evs } });
        }
        if (n.children.items.len > 0) {
            const kids = try a.alloc(zon.Value, n.children.items.len);
            for (n.children.items, 0..) |c, i| kids[i] = try self.nodeValue(c);
            try fs.append(a, .{ .name = "children", .value = .{ .list = kids } });
        }
        return .{ .record = fs.items };
    }

    pub fn toValue(self: *Doc) Allocator.Error!zon.Value {
        const a = self.alloc();
        const fs = try a.alloc(zon.Field, 2);
        fs[0] = .{ .name = "version", .value = .{ .int = format_version } };
        fs[1] = .{ .name = "root", .value = try self.nodeValue(self.root) };
        return .{ .record = fs };
    }

    /// The document as ZON text, owned by the caller.
    pub fn toZon(self: *Doc, gpa: Allocator) ![]u8 {
        const text = try zon.render(gpa, try self.toValue());
        return text;
    }
};

/// Read a document from ZON text.
pub fn parseDoc(gpa: Allocator, source: []const u8, diag: ?*zon.Diag, problem: ?*Problem) !Doc {
    var scratch = std.heap.ArenaAllocator.init(gpa);
    defer scratch.deinit();
    const v = try zon.parse(scratch.allocator(), source, diag);
    return Doc.fromValue(gpa, v, problem);
}

// ---- tests -----------------------------------------------------------------

const testing = std.testing;

const sample =
    \\.{
    \\    .version = 1,
    \\    .root = .{
    \\        .type = "box",
    \\        .style = .{ .direction = .column, .gap = 8 },
    \\        .children = .{
    \\            .{ .type = "label", .props = .{ .text = "Hello" } },
    \\            .{
    \\                .type = "button",
    \\                .id = "ok",
    \\                .props = .{ .text = "OK", .variant = .primary },
    \\                .on = .{ .click = "confirm" },
    \\            },
    \\        },
    \\    },
    \\}
;

test "a document reads its tree, ids, props, and bindings" {
    var doc = try parseDoc(testing.allocator, sample, null, null);
    defer doc.deinit();
    try testing.expectEqualStrings("box", doc.root.type_name);
    try testing.expectEqual(@as(usize, 2), doc.root.children.items.len);
    const btn = doc.root.children.items[1];
    try testing.expectEqualStrings("ok", btn.id);
    try testing.expectEqualStrings("primary", btn.props.field("variant").?.tag);
    try testing.expectEqualStrings("confirm", btn.on[0].action);
    try testing.expect(btn.parent == doc.root);
    try testing.expectEqual(@as(?usize, 1), btn.indexInParent());
    try testing.expectEqual(@as(i64, 8), doc.root.style.field("gap").?.int);
}

test "writing then reading gives the same document text" {
    var doc = try parseDoc(testing.allocator, sample, null, null);
    defer doc.deinit();
    const a = try doc.toZon(testing.allocator);
    defer testing.allocator.free(a);
    var again = try parseDoc(testing.allocator, a, null, null);
    defer again.deinit();
    const b = try again.toZon(testing.allocator);
    defer testing.allocator.free(b);
    try testing.expectEqualStrings(a, b);
}

fn problemOf(src: []const u8) !Problem {
    var p: Problem = .{ .message = "" };
    try testing.expectError(error.InvalidDocument, parseDoc(testing.allocator, src, null, &p));
    return p;
}

test "structure errors name what is wrong" {
    try testing.expectEqualStrings("missing .root", (try problemOf(".{ .version = 1 }")).message);
    try testing.expectEqualStrings("unsupported version", (try problemOf(".{ .version = 2, .root = .{ .type = \"box\" } }")).message);
    const p = try problemOf(".{ .root = .{ .type = \"box\", .colour = 1 } }");
    try testing.expectEqualStrings("unknown node key", p.message);
    try testing.expectEqualStrings("colour", p.detail);
    try testing.expectEqualStrings("node is missing .type", (try problemOf(".{ .root = .{ } }")).message);
    try testing.expectEqualStrings("unknown key at the top level", (try problemOf(".{ .root = .{ .type = \"box\" }, .extra = 1 }")).message);
    try testing.expectEqualStrings("an action name must be a string", (try problemOf(".{ .root = .{ .type = \"box\", .on = .{ .click = 1 } } }")).message);
    try testing.expectEqualStrings(".children must be a list of nodes", (try problemOf(".{ .root = .{ .type = \"box\", .children = 5 } }")).message);
    var d: zon.Diag = .{};
    try testing.expectError(error.Syntax, parseDoc(testing.allocator, ".{ .root = ", &d, null));
    try testing.expect(d.line == 1);
}

test "edits: insert, detach, reorder keep parents and indices right" {
    var doc = try Doc.init(testing.allocator);
    defer doc.deinit();
    const a = try doc.newNode("label");
    const b = try doc.newNode("button");
    const c = try doc.newNode("box");
    try doc.insert(doc.root, 0, a);
    try doc.insert(doc.root, 5, b); // clamped to the end
    try doc.insert(doc.root, 1, c);
    try testing.expectEqual(@as(?usize, 1), c.indexInParent());
    try testing.expectEqual(@as(?usize, 2), b.indexInParent());
    try doc.insert(c, 0, try doc.newNode("label"));
    try testing.expect(doc.root.isAncestorOf(c.children.items[0]));
    try testing.expect(!a.isAncestorOf(b));

    const old = doc.detach(c);
    try testing.expectEqual(@as(usize, 1), old);
    try testing.expect(c.parent == null);
    try testing.expectEqual(@as(usize, 2), doc.root.children.items.len);
    try testing.expectEqual(@as(usize, 1), c.children.items.len); // subtree intact
    try doc.insert(doc.root, old, c);
    try testing.expect(doc.find(c.children.items[0].uid) != null);
    try testing.expect(doc.find(9999) == null);
}

test "setEvent adds, replaces, and clears a binding" {
    var doc = try Doc.init(testing.allocator);
    defer doc.deinit();
    const n = try doc.newNode("button");
    try doc.setEvent(n, "click", "one");
    try doc.setEvent(n, "click", "two");
    try testing.expectEqual(@as(usize, 1), n.on.len);
    try testing.expectEqualStrings("two", n.on[0].action);
    try doc.setEvent(n, "click", "");
    try testing.expectEqual(@as(usize, 0), n.on.len);
}

test "empty style, props, and bindings are left out of the file" {
    var doc = try Doc.init(testing.allocator);
    defer doc.deinit();
    const text = try doc.toZon(testing.allocator);
    defer testing.allocator.free(text);
    try testing.expect(std.mem.indexOf(u8, text, "style") == null);
    try testing.expect(std.mem.indexOf(u8, text, "children") == null);
}
