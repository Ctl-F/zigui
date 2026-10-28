//! Direct-manipulation geometry for the builder: what is under the pointer, where
//! a dragged node would land, and the resize handles of the selection.
//!
//! Everything here reads the live preview (the tree and the instance made from
//! the document) and the document, and returns plain values; the builder decides
//! what to do with them. All rectangles are window coordinates.

const std = @import("std");
const Rect = @import("../core/geometry.zig").Rect;
const Handle = @import("../core/handle.zig").Handle;
const Ui = @import("../core/ui.zig").Ui;
const registry = @import("../widgets/registry.zig");
const doc_mod = @import("../uidoc/doc.zig");
const load = @import("../uidoc/load.zig");

/// A place a node can be dropped: inside `parent` at `index` (counting the
/// parent's children without the dragged node, the numbering `Editor.moveNode`
/// uses), and the rectangle to draw as the insertion marker.
pub const Drop = struct {
    parent: u32,
    index: usize,
    indicator: Rect,
};

/// Types whose children are laid out as a list the user can arrange.
pub fn isContainer(type_name: []const u8) bool {
    return std.mem.eql(u8, type_name, doc_mod.box_type) or std.mem.eql(u8, type_name, "scroll_view");
}

/// The document node whose preview node is, or contains, `h`, found by walking
/// up from `h` to `frame`. Null if `h` is not inside the frame.
pub fn docNodeAt(ui: *Ui, doc: *doc_mod.Doc, frame: Handle, h: Handle) ?*doc_mod.Node {
    var cur = h;
    while (ui.tree.get(cur)) |n| : (cur = n.parent) {
        if (Handle.eql(cur, frame)) return null;
        const uid: u32 = @intCast(@intFromPtr(n.user_data));
        if (uid != 0) {
            if (doc.find(uid)) |d| return d;
        }
    }
    return null;
}

/// The preview node whose children are `dn`'s children (a scroll view keeps them
/// in an inner node).
pub fn childrenHost(ui: *Ui, inst: *const load.Instance, dn: *const doc_mod.Node) ?Handle {
    const h = inst.handleOf(dn.uid) orelse return null;
    if (registry.infoOf(ui, h)) |info| {
        if (info.content_at != null) return null; // panes are the children, not a list
        if (info.content) |content| {
            const n = ui.tree.get(h) orelse return null;
            return content(n.widget.?);
        }
    }
    return h;
}

fn inSubtree(dragged: ?*const doc_mod.Node, n: *const doc_mod.Node) bool {
    const d = dragged orelse return false;
    return d == n or d.isAncestorOf(n);
}

fn isRow(ui: *Ui, host: Handle) bool {
    const n = ui.tree.get(host) orelse return false;
    return n.style.direction == .row;
}

const Gap = struct { index: usize, indicator: Rect };

/// The slot among `container`'s children (minus `dragged`) nearest the pointer
/// along the container's main axis, and a marker for it.
fn slotIn(ui: *Ui, inst: *const load.Instance, container: *const doc_mod.Node, dragged: ?*const doc_mod.Node, x: f32, y: f32) ?Gap {
    const host = childrenHost(ui, inst, container) orelse return null;
    const host_rect = ui.tree.absoluteRect(host) orelse return null;
    const row = isRow(ui, host);
    const p = if (row) x else y;
    var index: usize = 0;
    var last_rect: ?Rect = null;
    var next_rect: ?Rect = null;
    for (container.children.items) |c| {
        if (c == dragged) continue;
        const h = inst.handleOf(c.uid) orelse continue;
        const r = ui.tree.absoluteRect(h) orelse continue;
        const mid = if (row) r.x + r.w / 2 else r.y + r.h / 2;
        if (mid <= p) {
            index += 1;
            last_rect = r;
        } else if (next_rect == null) {
            next_rect = r;
        }
    }
    const thick: f32 = 3;
    const ind: Rect = blk: {
        if (next_rect) |r| {
            break :blk if (row)
                .{ .x = r.x - thick, .y = r.y, .w = thick, .h = r.h }
            else
                .{ .x = r.x, .y = r.y - thick, .w = r.w, .h = thick };
        }
        if (last_rect) |r| {
            break :blk if (row)
                .{ .x = r.right(), .y = r.y, .w = thick, .h = r.h }
            else
                .{ .x = r.x, .y = r.bottom(), .w = r.w, .h = thick };
        }
        // Empty container: a marker across its middle.
        break :blk if (row)
            .{ .x = host_rect.x + host_rect.w / 2 - 1, .y = host_rect.y, .w = thick, .h = host_rect.h }
        else
            .{ .x = host_rect.x, .y = host_rect.y + host_rect.h / 2 - 1, .w = host_rect.w, .h = thick };
    };
    return .{ .index = index, .indicator = ind };
}

/// Where a node dropped at window point (x, y) over the preview `frame` would
/// go. `dragged` (the node being moved, or null for a new one) is excluded, and
/// so is anything inside it. Over a container (away from its edges) the node goes
/// inside; over a widget, or the edge of a container, beside it.
pub fn previewDrop(ui: *Ui, inst: *const load.Instance, doc: *doc_mod.Doc, frame: Handle, dragged: ?*const doc_mod.Node, x: f32, y: f32) ?Drop {
    const hit = ui.tree.nodeAt(frame, x, y) orelse return null;
    const dn = docNodeAt(ui, doc, frame, hit) orelse return null;
    if (inSubtree(dragged, dn)) return null;

    var target = dn;
    var beside: enum { no, before, after } = .no;
    if (dn.parent) |parent| {
        const live = inst.handleOf(dn.uid) orelse return null;
        const r = ui.tree.absoluteRect(live) orelse return null;
        const phost = childrenHost(ui, inst, parent) orelse return null;
        const row = isRow(ui, phost);
        const size = if (row) r.w else r.h;
        const pos = (if (row) x - r.x else y - r.y);
        if (!isContainer(dn.type_name)) {
            target = parent;
            beside = if (pos < size / 2) .before else .after;
        } else {
            const edge = @min(8, size / 4);
            if (pos < edge) {
                target = parent;
                beside = .before;
            } else if (pos > size - edge) {
                target = parent;
                beside = .after;
            }
        }
    } else if (!isContainer(dn.type_name)) return null;

    if (beside == .no) {
        if (inSubtree(dragged, target)) return null;
        const g = slotIn(ui, inst, target, dragged, x, y) orelse return null;
        return .{ .parent = target.uid, .index = g.index, .indicator = g.indicator };
    }
    // Beside `dn`: its slot among its siblings (minus the dragged one).
    if (inSubtree(dragged, target)) return null;
    var at: usize = 0;
    for (target.children.items) |c| {
        if (c == dn) break;
        if (c != dragged) at += 1;
    }
    if (beside == .after) at += @intFromBool(dn != dragged);
    const host = childrenHost(ui, inst, target) orelse return null;
    const row = isRow(ui, host);
    const live = inst.handleOf(dn.uid) orelse return null;
    const r = ui.tree.absoluteRect(live) orelse return null;
    const thick: f32 = 3;
    const ind: Rect = switch (beside) {
        .before => if (row) .{ .x = r.x - thick, .y = r.y, .w = thick, .h = r.h } else .{ .x = r.x, .y = r.y - thick, .w = r.w, .h = thick },
        else => if (row) .{ .x = r.right(), .y = r.y, .w = thick, .h = r.h } else .{ .x = r.x, .y = r.bottom(), .w = r.w, .h = thick },
    };
    return .{ .parent = target.uid, .index = at, .indicator = ind };
}

/// One visible row of the outline.
pub const Row = struct { uid: u32, rect: Rect };

/// Where a node dropped at window height `y` over the outline `rows` would go:
/// the top quarter of a row puts it before that node, the bottom quarter after,
/// the middle inside it if it is a container.
pub fn outlineDrop(doc: *doc_mod.Doc, rows: []const Row, dragged: ?*const doc_mod.Node, y: f32) ?Drop {
    for (rows) |row| {
        if (y < row.rect.y or y >= row.rect.bottom()) continue;
        const dn = doc.find(row.uid) orelse return null;
        if (inSubtree(dragged, dn)) return null;
        const t = (y - row.rect.y) / row.rect.h;
        const parent = dn.parent;
        var zone: enum { before, after, inside } = if (t < 0.25) .before else if (t > 0.75) .after else .inside;
        if (zone == .inside and !isContainer(dn.type_name)) zone = if (t < 0.5) .before else .after;
        if (parent == null) zone = .inside; // nothing is beside the root
        if (zone == .inside) {
            if (!isContainer(dn.type_name)) return null;
            var n: usize = 0;
            for (dn.children.items) |c| n += @intFromBool(c != dragged);
            return .{ .parent = dn.uid, .index = n, .indicator = .{ .x = row.rect.x, .y = row.rect.y, .w = row.rect.w, .h = row.rect.h } };
        }
        const p = parent.?;
        if (inSubtree(dragged, p)) return null;
        var at: usize = 0;
        for (p.children.items) |c| {
            if (c == dn) break;
            if (c != dragged) at += 1;
        }
        if (zone == .after) at += @intFromBool(dn != dragged);
        const line_y = if (zone == .before) row.rect.y else row.rect.bottom();
        return .{ .parent = p.uid, .index = at, .indicator = .{ .x = row.rect.x, .y = line_y - 1, .w = row.rect.w, .h = 3 } };
    }
    return null;
}

// ---- resize handles ---------------------------------------------------------

pub const ResizeHandle = enum { right, bottom, corner };

pub const handle_size: f32 = 9;

/// The square drawn for `h` on a selection rectangle `r`.
pub fn handleRect(r: Rect, h: ResizeHandle) Rect {
    const s = handle_size;
    return switch (h) {
        .right => .{ .x = r.right() - s / 2, .y = r.y + r.h / 2 - s / 2, .w = s, .h = s },
        .bottom => .{ .x = r.x + r.w / 2 - s / 2, .y = r.bottom() - s / 2, .w = s, .h = s },
        .corner => .{ .x = r.right() - s / 2, .y = r.bottom() - s / 2, .w = s, .h = s },
    };
}

/// The handle under (x, y) on selection rect `r`, if any (a little slop makes
/// them easier to grab).
pub fn handleAt(r: Rect, x: f32, y: f32) ?ResizeHandle {
    inline for (.{ ResizeHandle.corner, ResizeHandle.right, ResizeHandle.bottom }) |h| {
        const hr = handleRect(r, h);
        if (x >= hr.x - 3 and x < hr.right() + 3 and y >= hr.y - 3 and y < hr.bottom() + 3) return h;
    }
    return null;
}

// ---- tests -----------------------------------------------------------------

const testing = std.testing;
const Length = @import("../core/length.zig").Length;

const Scene = struct {
    ui: Ui,
    doc: doc_mod.Doc,
    inst: load.Instance,
    cmds: [256]@import("../core/draw_list.zig").Command = undefined,
    glyphs: [64]@import("../core/draw_list.zig").Glyph = undefined,
    list: @import("../core/draw_list.zig").DrawList = undefined,

    fn init(src: []const u8) !*Scene {
        const s = try testing.allocator.create(Scene);
        s.ui = try Ui.init(testing.allocator);
        s.list = @import("../core/draw_list.zig").DrawList.init(&s.cmds, &s.glyphs);
        s.doc = try doc_mod.parseDoc(testing.allocator, src, null, null);
        s.inst = try load.instantiate(&s.ui, s.ui.tree.root, &s.doc, .{ .strict = false });
        var it = s.inst.by_uid.iterator();
        while (it.next()) |e| s.ui.tree.get(e.value_ptr.*).?.user_data = @ptrFromInt(e.key_ptr.*);
        s.ui.update();
        try s.ui.layoutAndPaint(.{ .w = 400, .h = 400 }, &s.list);
        return s;
    }

    fn deinit(self: *Scene) void {
        self.inst.destroy();
        self.doc.deinit();
        self.ui.deinit();
        testing.allocator.destroy(self);
    }

    fn node(self: *Scene, id: []const u8) *doc_mod.Node {
        return findById(self.doc.root, id).?;
    }
};

fn findById(n: *doc_mod.Node, id: []const u8) ?*doc_mod.Node {
    if (std.mem.eql(u8, n.id, id)) return n;
    for (n.children.items) |c| if (findById(c, id)) |hit| return hit;
    return null;
}

// A column of three 100x40 boxes with 10px gaps, at the origin: a at y 0..40, b 50..90, c 100..140.
const column_src =
    \\.{ .root = .{ .type = "box", .id = "root", .style = .{ .direction = .column, .gap = 10, .width = 200, .height = 300, .align_items = .start }, .children = .{
    \\    .{ .type = "box", .id = "a", .style = .{ .width = 100, .height = 40 } },
    \\    .{ .type = "box", .id = "b", .style = .{ .width = 100, .height = 40 } },
    \\    .{ .type = "box", .id = "c", .style = .{ .width = 100, .height = 40 } },
    \\} } }
;

test "docNodeAt finds the document node under a preview node" {
    const s = try Scene.init(column_src);
    defer s.deinit();
    const hit = s.ui.tree.nodeAt(s.ui.tree.root, 50, 70).?;
    try testing.expectEqual(s.node("b"), docNodeAt(&s.ui, &s.doc, s.ui.tree.root, hit).?);
    // Outside the boxes but inside the root box.
    const empty = s.ui.tree.nodeAt(s.ui.tree.root, 150, 250).?;
    try testing.expectEqual(s.node("root"), docNodeAt(&s.ui, &s.doc, s.ui.tree.root, empty).?);
}

test "dropping over the middle of a box puts the node inside it, at the nearest slot" {
    const s = try Scene.init(column_src);
    defer s.deinit();
    const root = s.ui.tree.root;
    // Over the empty part of the root box, below c: inside root, after all three.
    const d = previewDrop(&s.ui, &s.inst, &s.doc, root, null, 150, 250).?;
    try testing.expectEqual(s.node("root").uid, d.parent);
    try testing.expectEqual(@as(usize, 3), d.index);
    // The marker is a thin horizontal bar just under c.
    try testing.expect(d.indicator.h == 3 and @abs(d.indicator.y - 140) < 1);
}

test "over a widget-sized box's edge or a leaf, the node goes beside it" {
    const s = try Scene.init(column_src);
    defer s.deinit();
    const root = s.ui.tree.root;
    // The top edge of b (y 50..90, edge zone = 8px... min(8, 40/4=10) = 8): before b.
    const before = previewDrop(&s.ui, &s.inst, &s.doc, root, null, 50, 52).?;
    try testing.expectEqual(s.node("root").uid, before.parent);
    try testing.expectEqual(@as(usize, 1), before.index);
    // The bottom edge of b: after b.
    const after = previewDrop(&s.ui, &s.inst, &s.doc, root, null, 50, 88).?;
    try testing.expectEqual(@as(usize, 2), after.index);
    // The middle of b (a box): inside it, which is empty.
    const inside = previewDrop(&s.ui, &s.inst, &s.doc, root, null, 50, 70).?;
    try testing.expectEqual(s.node("b").uid, inside.parent);
    try testing.expectEqual(@as(usize, 0), inside.index);
}

test "the dragged node is excluded from slots and cannot drop into itself" {
    const s = try Scene.init(column_src);
    defer s.deinit();
    const root = s.ui.tree.root;
    const a = s.node("a");
    // Dragging a over the bottom edge of c: index counts siblings without a, so 2 (after c).
    const d = previewDrop(&s.ui, &s.inst, &s.doc, root, a, 50, 138).?;
    try testing.expectEqual(s.node("root").uid, d.parent);
    try testing.expectEqual(@as(usize, 2), d.index);
    // Over itself: nothing.
    try testing.expect(previewDrop(&s.ui, &s.inst, &s.doc, root, a, 50, 20) == null);
    // Over the root's empty area, after everything else (a is not counted).
    const tail = previewDrop(&s.ui, &s.inst, &s.doc, root, a, 150, 250).?;
    try testing.expectEqual(@as(usize, 2), tail.index);
}

test "a box cannot be dropped inside its own descendant" {
    const s = try Scene.init(
        \\.{ .root = .{ .type = "box", .id = "root", .style = .{ .width = 200, .height = 200, .direction = .column }, .children = .{
        \\    .{ .type = "box", .id = "outer", .style = .{ .width = 120, .height = 120, .padding = 10 }, .children = .{
        \\        .{ .type = "box", .id = "inner", .style = .{ .width = 60, .height = 60 } },
        \\    } },
        \\} } }
    );
    defer s.deinit();
    const root = s.ui.tree.root;
    const outer = s.node("outer");
    try testing.expect(previewDrop(&s.ui, &s.inst, &s.doc, root, outer, 30, 30) == null); // over inner (inside outer)
    // Dropping inner onto outer's padding is fine (it moves up one level... into outer, index 0).
    const d = previewDrop(&s.ui, &s.inst, &s.doc, root, s.node("inner"), 15, 100).?;
    try testing.expectEqual(outer.uid, d.parent);
}

test "row containers place by x" {
    const s = try Scene.init(
        \\.{ .root = .{ .type = "box", .id = "root", .style = .{ .direction = .row, .gap = 10, .width = 300, .height = 100, .align_items = .start }, .children = .{
        \\    .{ .type = "box", .id = "a", .style = .{ .width = 50, .height = 50 } },
        \\    .{ .type = "box", .id = "b", .style = .{ .width = 50, .height = 50 } },
        \\} } }
    );
    defer s.deinit();
    const root = s.ui.tree.root;
    const d = previewDrop(&s.ui, &s.inst, &s.doc, root, null, 200, 80).?; // right of b, in the root
    try testing.expectEqual(@as(usize, 2), d.index);
    try testing.expect(d.indicator.w == 3 and @abs(d.indicator.x - 110) < 1.5);
    const first = previewDrop(&s.ui, &s.inst, &s.doc, root, null, 5, 80).?; // left half of the root's start, below a
    try testing.expectEqual(@as(usize, 0), first.index);
}

test "outline drops: before, after, and inside by row zone" {
    var doc = try doc_mod.parseDoc(testing.allocator, column_src, null, null);
    defer doc.deinit();
    const root = doc.root;
    const a = root.children.items[0];
    const b = root.children.items[1];
    const c = root.children.items[2];
    // Rows: root 0..20, a 20..40, b 40..60, c 60..80.
    const rows = [_]Row{
        .{ .uid = root.uid, .rect = .{ .x = 0, .y = 0, .w = 100, .h = 20 } },
        .{ .uid = a.uid, .rect = .{ .x = 0, .y = 20, .w = 100, .h = 20 } },
        .{ .uid = b.uid, .rect = .{ .x = 0, .y = 40, .w = 100, .h = 20 } },
        .{ .uid = c.uid, .rect = .{ .x = 0, .y = 60, .w = 100, .h = 20 } },
    };
    const top_of_b = outlineDrop(&doc, &rows, null, 41).?;
    try testing.expectEqual(root.uid, top_of_b.parent);
    try testing.expectEqual(@as(usize, 1), top_of_b.index);
    const bottom_of_b = outlineDrop(&doc, &rows, null, 59).?;
    try testing.expectEqual(@as(usize, 2), bottom_of_b.index);
    const into_b = outlineDrop(&doc, &rows, null, 50).?; // b is a box
    try testing.expectEqual(b.uid, into_b.parent);
    try testing.expectEqual(@as(usize, 0), into_b.index);
    // Over the root row: always inside.
    const into_root = outlineDrop(&doc, &rows, null, 2).?;
    try testing.expectEqual(root.uid, into_root.parent);
    try testing.expectEqual(@as(usize, 3), into_root.index);
    // Dragging a: dropping after c counts without a; dropping onto itself is refused.
    const after_c = outlineDrop(&doc, &rows, a, 79).?;
    try testing.expectEqual(@as(usize, 2), after_c.index);
    try testing.expect(outlineDrop(&doc, &rows, a, 30) == null);
    try testing.expect(outlineDrop(&doc, &rows, null, 500) == null);
}

test "resize handles sit on the selection edges and are hit with a little slop" {
    const r: Rect = .{ .x = 10, .y = 20, .w = 100, .h = 60 };
    const right = handleRect(r, .right);
    try testing.expectEqual(@as(f32, 110 - handle_size / 2), right.x);
    try testing.expectEqual(@as(f32, 20 + 30 - handle_size / 2), right.y);
    try testing.expectEqual(ResizeHandle.corner, handleAt(r, 110, 80).?);
    try testing.expectEqual(ResizeHandle.right, handleAt(r, 112, 50).?);
    try testing.expectEqual(ResizeHandle.bottom, handleAt(r, 60, 82).?);
    try testing.expect(handleAt(r, 40, 40) == null);
}
