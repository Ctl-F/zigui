//! Flex layout pass over the node tree.
//!
//! Two phases per relayout boundary popped from `Tree.popLayoutRoot()`:
//!
//! 1. `measure` (bottom-up): computes each dirty node's natural border-box size
//!    (`Node.measured`) from its children, or from `Node.intrinsic` for leaves.
//!    Clean subtrees keep their cached value.
//! 2. `place` (top-down): resolves each child's main-axis basis, runs the flex
//!    solver, resolves the cross axis and alignment, and writes `Node.rect`.
//!    A child is descended into only if its size changed or it is dirty.
//!
//! Boxes are border boxes: width/height/min/max include padding. Margins sit
//! outside the box and take part in the main-axis solve (as extra basis/min/max).
//! Percent lengths are relative to the parent's content box; if the parent is
//! `fit_content` on that axis the percent falls back to auto and is counted in
//! `circular_percent`.
//!
//! A relayout boundary must have a size that does not depend on its contents,
//! or ancestors keep a stale `measured` value for it.
//!
//! The pass recurses once per tree level, so depth is bounded by the stack.
//! Scratch buffers grow to the largest child count seen and are then reused,
//! so a steady-state frame does not allocate.

const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");

const flex = @import("flex.zig");
const length = @import("length.zig");
const Handle = @import("handle.zig").Handle;
const Size = @import("geometry.zig").Size;
const Length = length.Length;
const Edges = @import("style.zig").Edges;
const Tree = @import("tree.zig").Tree;
const Node = @import("tree.zig").Node;

pub const Pad = struct { l: f32, t: f32, r: f32, b: f32 };

fn edge(len: Length, base: ?f32) f32 {
    return length.resolve(len, .{ .parent = base, .content = 0 }).value;
}

pub fn resolveEdges(e: Edges, base: ?f32) Pad {
    return .{ .l = edge(e.left, base), .t = edge(e.top, base), .r = edge(e.right, base), .b = edge(e.bottom, base) };
}

/// `a` if `horizontal`, else `b`. Lets one code path serve both directions.
fn pick(horizontal: bool, a: anytype, b: @TypeOf(a)) @TypeOf(a) {
    return if (horizontal) a else b;
}

fn minOf(len: Length, ctx: length.ResolveCtx) f32 {
    return if (len == .auto) 0 else length.resolve(len, ctx).value;
}

fn maxOf(len: Length, ctx: length.ResolveCtx) f32 {
    return if (len == .auto) std.math.inf(f32) else length.resolve(len, ctx).value;
}

pub const Layout = struct {
    allocator: std.mem.Allocator,
    items: std.ArrayListUnmanaged(flex.Item) = .empty,
    sizes: std.ArrayListUnmanaged(f32) = .empty,
    frozen: std.ArrayListUnmanaged(bool) = .empty,
    /// Count of percent lengths that fell back to auto since the last reset.
    circular_percent: u32 = 0,

    pub fn init(allocator: std.mem.Allocator) Layout {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Layout) void {
        self.items.deinit(self.allocator);
        self.sizes.deinit(self.allocator);
        self.frozen.deinit(self.allocator);
        self.* = undefined;
    }

    /// Run layout for every pending boundary. `root_size` is the window size;
    /// if it differs from the root's current size the whole tree is relaid out.
    pub fn run(self: *Layout, tree: *Tree, root_size: Size) error{OutOfMemory}!void {
        if (tree.get(tree.root)) |root| {
            if (root.rect.w != root_size.w or root.rect.h != root_size.h) {
                root.rect.w = root_size.w;
                root.rect.h = root_size.h;
                tree.damage.markAll();
                tree.markDirty(tree.root, .{ .layout = true, .paint = true });
            }
        }
        while (tree.popLayoutRoot()) |h| {
            self.measure(tree, h);
            try self.place(tree, h, parentContentWidth(tree, h));
        }
    }

    fn parentContentWidth(tree: *Tree, h: Handle) ?f32 {
        const node = tree.get(h) orelse return null;
        const p = tree.get(node.parent) orelse return null;
        const pad = resolveEdges(p.style.padding, null);
        return @max(p.rect.w - pad.l - pad.r, 0);
    }

    fn ensure(self: *Layout, n: usize) error{OutOfMemory}!void {
        if (self.items.items.len >= n) return;
        try self.items.resize(self.allocator, n);
        try self.sizes.resize(self.allocator, n);
        try self.frozen.resize(self.allocator, n);
    }

    fn noteCircular(self: *Layout, r: length.Resolved) void {
        if (!r.circular_percent) return;
        self.circular_percent += 1;
        if (build_options.ui_checks and !builtin.is_test) {
            std.log.warn("ui_check: percent length against a fit-content parent; treated as auto", .{});
        }
    }

    // ---- phase 1: measure -------------------------------------------------

    fn measure(self: *Layout, tree: *Tree, h: Handle) void {
        const node = tree.get(h) orelse return;
        if (!(node.dirty.needsLayout() or node.dirty.child_layout)) return;

        var it = tree.children(h);
        while (it.next()) |c| self.measure(tree, c);

        const st = node.style;
        const row = st.direction == .row;
        const pad = resolveEdges(st.padding, null);
        const gap = edge(st.gap, null);

        var main_sum: f32 = 0;
        var cross_max: f32 = 0;
        var n: u32 = 0;
        it = tree.children(h);
        while (it.next()) |c| {
            const cn = tree.get(c).?;
            if (cn.flags.hidden) continue;
            const o = preferredOuter(cn);
            main_sum += pick(row, o.w, o.h);
            cross_max = @max(cross_max, pick(row, o.h, o.w));
            n += 1;
        }

        var w: f32 = undefined;
        var ht: f32 = undefined;
        if (n == 0) {
            w = node.intrinsic.w;
            ht = node.intrinsic.h;
        } else {
            const main_total = main_sum + gap * @as(f32, @floatFromInt(n - 1));
            w = pick(row, main_total, cross_max);
            ht = pick(row, cross_max, main_total);
        }
        node.measured = .{ .w = w + pad.l + pad.r, .h = ht + pad.t + pad.b };
    }

    /// A child's preferred outer size (border box plus margins) with no
    /// parent constraints, used to size content-driven parents.
    fn preferredOuter(cn: *const Node) Size {
        const s = cn.style;
        const m = resolveEdges(s.margin, null);
        const cw = length.resolveClamped(s.width, s.min_width, s.max_width, .{ .parent = null, .content = cn.measured.w });
        const ch = length.resolveClamped(s.height, s.min_height, s.max_height, .{ .parent = null, .content = cn.measured.h });
        return .{ .w = cw.value + m.l + m.r, .h = ch.value + m.t + m.b };
    }

    // ---- phase 2: place ---------------------------------------------------

    /// Lay out the children of `h` inside its current rect. `pct_base` is the
    /// parent's content width, the base for this node's percent padding.
    fn place(self: *Layout, tree: *Tree, h: Handle, pct_base: ?f32) error{OutOfMemory}!void {
        const node = tree.get(h) orelse return;
        const st = node.style;
        const row = st.direction == .row;
        const pad = resolveEdges(st.padding, pct_base);
        const cw = @max(node.rect.w - pad.l - pad.r, 0);
        const ch = @max(node.rect.h - pad.t - pad.b, 0);
        const main_avail = pick(row, cw, ch);
        const cross_avail = pick(row, ch, cw);
        const main_definite = pick(row, st.width, st.height) != .fit;
        const cross_definite = pick(row, st.height, st.width) != .fit;
        const gap = length.resolve(st.gap, .{ .parent = if (main_definite) main_avail else null, .content = 0 }).value;

        // Scratch is free again once the rects are written, so the recursion
        // at the bottom can reuse it.
        var n: usize = 0;
        {
            var it = tree.children(h);
            while (it.next()) |c| {
                if (!tree.get(c).?.flags.hidden) n += 1;
            }
        }
        node.dirty.layout = false;
        node.dirty.children = false;
        node.dirty.style = false;
        node.dirty.child_layout = false;
        if (n == 0) return;
        try self.ensure(n);

        const items = self.items.items[0..n];
        const sizes = self.sizes.items[0..n];

        // Main axis: one flex item per visible child.
        var i: usize = 0;
        var it = tree.children(h);
        while (it.next()) |c| {
            const cn = tree.get(c).?;
            if (cn.flags.hidden) continue;
            const cs = cn.style;
            const m = resolveEdges(cs.margin, cw);
            const mm = pick(row, m.l + m.r, m.t + m.b);
            const len = pick(row, cs.width, cs.height);
            const ctx: length.ResolveCtx = .{
                .parent = if (main_definite) main_avail else null,
                .content = pick(row, cn.measured.w, cn.measured.h),
            };
            const basis = length.resolve(len, ctx);
            self.noteCircular(basis);
            items[i] = .{
                .basis = basis.value + mm,
                .min = minOf(pick(row, cs.min_width, cs.min_height), ctx) + mm,
                .max = maxOf(pick(row, cs.max_width, cs.max_height), ctx) + mm,
                .grow = if (len == .fill) @max(cs.grow, 1) else cs.grow,
                .shrink = cs.shrink,
            };
            i += 1;
        }
        flex.solve(items, main_avail, gap, sizes, self.frozen.items[0..n]);

        var used: f32 = gap * @as(f32, @floatFromInt(n - 1));
        for (sizes) |s| used += s;
        const leftover = @max(main_avail - used, 0);
        var pos = pick(row, pad.l, pad.t) + switch (st.justify) {
            .start, .stretch => 0,
            .center => leftover / 2,
            .end => leftover,
        };
        const cross_pad = pick(row, pad.t, pad.l);

        // Cross axis, alignment, and writing rects.
        i = 0;
        it = tree.children(h);
        while (it.next()) |c| {
            const cn = tree.get(c).?;
            if (cn.flags.hidden) continue;
            const cs = cn.style;
            const m = resolveEdges(cs.margin, cw);
            const mm = pick(row, m.l + m.r, m.t + m.b);
            const cross_margin = pick(row, m.t + m.b, m.l + m.r);
            const al = cs.align_self orelse st.align_items;

            const clen = pick(row, cs.height, cs.width);
            const cctx: length.ResolveCtx = .{
                .parent = if (cross_definite) cross_avail else null,
                .content = pick(row, cn.measured.h, cn.measured.w),
            };
            const lo = minOf(pick(row, cs.min_height, cs.min_width), cctx);
            const hi = maxOf(pick(row, cs.max_height, cs.max_width), cctx);
            var cross_size: f32 = undefined;
            if (clen == .fill or (clen == .auto and al == .stretch)) {
                cross_size = length.clampSize(@max(cross_avail - cross_margin, 0), lo, hi);
            } else {
                const r = length.resolve(clen, cctx);
                self.noteCircular(r);
                cross_size = length.clampSize(r.value, lo, hi);
            }
            const free = cross_avail - cross_size - cross_margin;
            const cross_off = switch (al) {
                .start, .stretch => 0,
                .center => free / 2,
                .end => free,
            };
            const cross_pos = cross_pad + pick(row, m.t, m.l) + cross_off;

            const main_size = @max(sizes[i] - mm, 0);
            const main_pos = pos + pick(row, m.l, m.t);
            pos += sizes[i] + gap;

            const old = cn.rect;
            const new: @TypeOf(old) = if (row)
                .{ .x = main_pos, .y = cross_pos, .w = main_size, .h = cross_size }
            else
                .{ .x = cross_pos, .y = main_pos, .w = cross_size, .h = main_size };
            cn.rect = new;
            const size_changed = new.w != old.w or new.h != old.h;
            if (size_changed or new.x != old.x or new.y != old.y) {
                // The area it used to cover needs redrawing too (`markDirty`
                // adds the new area).
                if (tree.absoluteRect(h)) |pa| {
                    tree.damage.add(Tree.withTextOverhang(cn, .{ .x = pa.x + old.x, .y = pa.y + old.y, .w = old.w, .h = old.h }));
                }
                if (size_changed) tree.markDirty(c, .{ .paint = true }) else tree.markMoved(c);
            }
            cn.place_pending = size_changed or cn.dirty.needsLayout() or cn.dirty.child_layout;
            i += 1;
        }

        // Descend only where something changed. The decision lives on the
        // node because the recursive calls reuse the scratch buffers above.
        it = tree.children(h);
        while (it.next()) |c| {
            const cn = tree.get(c).?;
            if (!cn.place_pending) continue;
            cn.place_pending = false;
            try self.place(tree, c, cw);
        }
    }
};

// ---- tests -----------------------------------------------------------------

const Style = @import("style.zig").Style;

const Harness = struct {
    tree: Tree,
    layout: Layout,

    fn init(root_style: Style) !Harness {
        var tree = try Tree.init(std.testing.allocator);
        tree.get(tree.root).?.style = root_style;
        return .{ .tree = tree, .layout = Layout.init(std.testing.allocator) };
    }

    fn deinit(self: *Harness) void {
        self.layout.deinit();
        self.tree.deinit();
    }

    fn add(self: *Harness, parent: Handle, node: Node) !Handle {
        const h = try self.tree.create(node);
        try self.tree.appendChild(parent, h);
        return h;
    }

    fn box(self: *Harness, parent: Handle, w: f32, h: f32) !Handle {
        return self.add(parent, .{ .style = .{ .width = Length.px(w), .height = Length.px(h) } });
    }

    fn run(self: *Harness, w: f32, h: f32) !void {
        try self.layout.run(&self.tree, .{ .w = w, .h = h });
    }

    fn rect(self: *Harness, h: Handle) @import("geometry.zig").Rect {
        return self.tree.get(h).?.rect;
    }
};

fn expectRect(r: @import("geometry.zig").Rect, x: f32, y: f32, w: f32, h: f32) !void {
    try std.testing.expectApproxEqAbs(x, r.x, 0.01);
    try std.testing.expectApproxEqAbs(y, r.y, 0.01);
    try std.testing.expectApproxEqAbs(w, r.w, 0.01);
    try std.testing.expectApproxEqAbs(h, r.h, 0.01);
}

test "row places fixed children with a gap" {
    var t = try Harness.init(.{ .gap = Length.px(10) });
    defer t.deinit();
    const a = try t.box(t.tree.root, 50, 20);
    const b = try t.box(t.tree.root, 50, 20);
    const c = try t.box(t.tree.root, 50, 20);
    try t.run(300, 100);
    try expectRect(t.rect(a), 0, 0, 50, 20);
    try expectRect(t.rect(b), 60, 0, 50, 20);
    try expectRect(t.rect(c), 120, 0, 50, 20);
}

test "grow shares leftover space and stretch fills the cross axis" {
    var t = try Harness.init(.{});
    defer t.deinit();
    const a = try t.add(t.tree.root, .{ .style = .{ .grow = 1 } });
    const b = try t.add(t.tree.root, .{ .style = .{ .grow = 2 } });
    try t.run(300, 100);
    try expectRect(t.rect(a), 0, 0, 100, 100);
    try expectRect(t.rect(b), 100, 0, 200, 100);
}

test "column with padding and gap" {
    var t = try Harness.init(.{ .direction = .column, .padding = Edges.all(10), .gap = Length.px(5) });
    defer t.deinit();
    const a = try t.add(t.tree.root, .{ .style = .{ .height = Length.px(30) } });
    const b = try t.add(t.tree.root, .{ .style = .{ .height = Length.px(30) } });
    try t.run(200, 200);
    try expectRect(t.rect(a), 10, 10, 180, 30);
    try expectRect(t.rect(b), 10, 45, 180, 30);
}

test "cross-axis alignment and align_self" {
    var t = try Harness.init(.{ .align_items = .center });
    defer t.deinit();
    const a = try t.box(t.tree.root, 50, 20);
    const b = try t.add(t.tree.root, .{ .style = .{ .width = Length.px(50), .height = Length.px(20), .align_self = .end } });
    const c = try t.add(t.tree.root, .{ .style = .{ .width = Length.px(50), .height = Length.px(20), .align_self = .start } });
    try t.run(300, 100);
    try expectRect(t.rect(a), 0, 40, 50, 20);
    try expectRect(t.rect(b), 50, 80, 50, 20);
    try expectRect(t.rect(c), 100, 0, 50, 20);
}

test "margins offset boxes and take part in the main axis" {
    var t = try Harness.init(.{ .align_items = .start });
    defer t.deinit();
    const m = Edges.all(5);
    const a = try t.add(t.tree.root, .{ .style = .{ .width = Length.px(50), .height = Length.px(20), .margin = m } });
    const b = try t.add(t.tree.root, .{ .style = .{ .width = Length.px(50), .height = Length.px(20), .margin = m } });
    try t.run(300, 100);
    try expectRect(t.rect(a), 5, 5, 50, 20);
    try expectRect(t.rect(b), 65, 5, 50, 20);
}

test "justify centers and ends when nothing grows" {
    var t = try Harness.init(.{ .justify = .center });
    defer t.deinit();
    const a = try t.box(t.tree.root, 100, 20);
    try t.run(300, 100);
    try expectRect(t.rect(a), 100, 0, 100, 20);

    t.tree.get(t.tree.root).?.style.justify = .end;
    t.tree.markDirty(t.tree.root, .{ .layout = true });
    try t.run(300, 100);
    try expectRect(t.rect(a), 200, 0, 100, 20);
}

test "shrink takes back overflow" {
    var t = try Harness.init(.{});
    defer t.deinit();
    const a = try t.box(t.tree.root, 80, 20);
    const b = try t.box(t.tree.root, 80, 20);
    try t.run(100, 50);
    try expectRect(t.rect(a), 0, 0, 50, 20);
    try expectRect(t.rect(b), 50, 0, 50, 20);
}

test "column fill takes the remaining height" {
    var t = try Harness.init(.{ .direction = .column });
    defer t.deinit();
    const a = try t.add(t.tree.root, .{ .style = .{ .height = Length.px(50) } });
    const b = try t.add(t.tree.root, .{ .style = .{ .height = .fill } });
    try t.run(100, 300);
    try expectRect(t.rect(a), 0, 0, 100, 50);
    try expectRect(t.rect(b), 0, 50, 100, 250);
}

test "percent width with min and max (sidebar)" {
    var t = try Harness.init(.{});
    defer t.deinit();
    const side = try t.add(t.tree.root, .{ .style = .{
        .width = Length.pct(20),
        .min_width = Length.px(150),
        .max_width = Length.px(360),
        .shrink = 0,
    } });
    try t.run(500, 100);
    try std.testing.expectApproxEqAbs(@as(f32, 150), t.rect(side).w, 0.01);
    try t.run(1500, 100);
    try std.testing.expectApproxEqAbs(@as(f32, 300), t.rect(side).w, 0.01);
    try t.run(3840, 100);
    try std.testing.expectApproxEqAbs(@as(f32, 360), t.rect(side).w, 0.01);
}

test "auto container sizes to its content" {
    var t = try Harness.init(.{ .align_items = .start });
    defer t.deinit();
    const box = try t.add(t.tree.root, .{ .style = .{ .gap = Length.px(10) } });
    const a = try t.add(box, .{ .intrinsic = .{ .w = 40, .h = 20 } });
    const b = try t.add(box, .{ .intrinsic = .{ .w = 40, .h = 20 } });
    try t.run(400, 400);
    try expectRect(t.rect(box), 0, 0, 90, 20);
    try expectRect(t.rect(a), 0, 0, 40, 20);
    try expectRect(t.rect(b), 50, 0, 40, 20);
}

test "container padding adds to its natural size" {
    var t = try Harness.init(.{ .align_items = .start });
    defer t.deinit();
    const box = try t.add(t.tree.root, .{ .style = .{ .padding = Edges.xy(8, 4) } });
    const a = try t.add(box, .{ .intrinsic = .{ .w = 40, .h = 20 } });
    try t.run(400, 400);
    try expectRect(t.rect(box), 0, 0, 56, 28);
    try expectRect(t.rect(a), 8, 4, 40, 20);
}

test "percent inside a fit-content parent falls back to auto and is counted" {
    var t = try Harness.init(.{ .align_items = .start });
    defer t.deinit();
    const box = try t.add(t.tree.root, .{ .style = .{ .width = .fit } });
    const a = try t.add(box, .{ .style = .{ .width = Length.pct(50) }, .intrinsic = .{ .w = 10, .h = 10 } });
    try t.run(400, 400);
    try expectRect(t.rect(box), 0, 0, 10, 10);
    try expectRect(t.rect(a), 0, 0, 10, 10);
    try std.testing.expect(t.layout.circular_percent > 0);
}

test "hidden children take no space" {
    var t = try Harness.init(.{});
    defer t.deinit();
    const a = try t.box(t.tree.root, 50, 20);
    const b = try t.box(t.tree.root, 50, 20);
    const c = try t.box(t.tree.root, 50, 20);
    t.tree.get(b).?.flags.hidden = true;
    try t.run(300, 100);
    try expectRect(t.rect(a), 0, 0, 50, 20);
    try expectRect(t.rect(c), 50, 0, 50, 20);
}

test "a pass clears layout dirtiness and leaves no seeds" {
    var t = try Harness.init(.{});
    defer t.deinit();
    const a = try t.box(t.tree.root, 50, 20);
    try t.run(300, 100);
    try std.testing.expect(t.tree.popLayoutRoot() == null);
    const root = t.tree.get(t.tree.root).?;
    try std.testing.expect(!root.dirty.layout and !root.dirty.children and !root.dirty.child_layout);
    try std.testing.expect(!t.tree.get(a).?.dirty.layout);
}

test "nested layout works for column inside row" {
    var t = try Harness.init(.{ .align_items = .start });
    defer t.deinit();
    const side = try t.add(t.tree.root, .{ .style = .{ .width = Length.px(100), .direction = .column, .height = Length.pct(100) } });
    const s1 = try t.add(side, .{ .style = .{ .height = Length.px(30) } });
    const s2 = try t.add(side, .{ .style = .{ .height = .fill } });
    const main = try t.add(t.tree.root, .{ .style = .{ .grow = 1, .height = Length.pct(100) } });
    try t.run(400, 200);
    try expectRect(t.rect(side), 0, 0, 100, 200);
    try expectRect(t.rect(s1), 0, 0, 100, 30);
    try expectRect(t.rect(s2), 0, 30, 100, 170);
    try expectRect(t.rect(main), 100, 0, 300, 200);
}

test "incremental: only the dirty boundary subtree is relaid out" {
    var t = try Harness.init(.{});
    defer t.deinit();
    const panel = try t.add(t.tree.root, .{
        .style = .{ .width = Length.px(200), .height = Length.px(100), .shrink = 0 },
        .flags = .{ .relayout_boundary = true },
    });
    const leaf = try t.box(panel, 50, 20);
    const other = try t.add(t.tree.root, .{ .style = .{ .width = Length.px(100), .shrink = 0 } });
    try t.run(400, 100);
    try expectRect(t.rect(leaf), 0, 0, 50, 20);

    // Poison a clean sibling: a re-placement of the root would overwrite it.
    t.tree.get(other).?.rect.x = 999;
    t.tree.get(leaf).?.style.width = Length.px(77);
    t.tree.markDirty(leaf, .{ .layout = true });
    try t.run(400, 100);

    try std.testing.expectApproxEqAbs(@as(f32, 77), t.rect(leaf).w, 0.01);
    try std.testing.expectEqual(@as(f32, 999), t.rect(other).x);
    try std.testing.expect(t.tree.popLayoutRoot() == null);
}

test "resizing the window relays out the tree" {
    var t = try Harness.init(.{});
    defer t.deinit();
    const a = try t.add(t.tree.root, .{ .style = .{ .grow = 1 } });
    try t.run(300, 100);
    try expectRect(t.rect(a), 0, 0, 300, 100);
    try t.run(500, 80);
    try expectRect(t.rect(a), 0, 0, 500, 80);
}

test "moved or resized nodes are marked paint-dirty" {
    var t = try Harness.init(.{});
    defer t.deinit();
    const a = try t.box(t.tree.root, 50, 20);
    try t.run(300, 100);
    t.tree.clearDirty(t.tree.root);

    t.tree.get(a).?.style.width = Length.px(60);
    t.tree.markDirty(a, .{ .layout = true });
    try t.run(300, 100);
    try std.testing.expect(t.tree.get(a).?.dirty.paint);
}
