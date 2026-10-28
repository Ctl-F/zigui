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
    kids: std.ArrayListUnmanaged(Handle) = .empty,
    /// Count of percent lengths that fell back to auto since the last reset.
    circular_percent: u32 = 0,

    pub fn init(allocator: std.mem.Allocator) Layout {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Layout) void {
        self.items.deinit(self.allocator);
        self.sizes.deinit(self.allocator);
        self.frozen.deinit(self.allocator);
        self.kids.deinit(self.allocator);
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
        try self.kids.resize(self.allocator, n);
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

        if (st.grid_columns > 0) {
            self.measureGrid(tree, h, node, pad, gap);
            return;
        }

        var main_sum: f32 = 0;
        var cross_max: f32 = 0;
        var n: u32 = 0;
        it = tree.children(h);
        while (it.next()) |c| {
            const cn = tree.get(c).?;
            if (cn.flags.hidden or cn.style.position == .absolute) continue;
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

    /// A grid's preferred size: columns as wide as the widest cell (per column
    /// spanned), rows as tall as their tallest cell.
    fn measureGrid(self: *Layout, tree: *Tree, h: Handle, node: *Node, pad: Pad, gap: f32) void {
        _ = self;
        const cols: u16 = node.style.grid_columns;
        var col_w: f32 = 0;
        var total_h: f32 = 0;
        var rows: u32 = 0;
        var any = false;
        var it = tree.children(h);
        while (true) {
            var row_h: f32 = 0;
            var used: u16 = 0;
            var peek = it;
            while (nextFlow(tree, &peek)) |c| {
                const cn = tree.get(c).?;
                const span = cellSpan(cn, cols);
                if (used > 0 and used + span > cols) break;
                used += span;
                it = peek;
                const o = preferredOuter(cn);
                col_w = @max(col_w, (o.w - gap * @as(f32, @floatFromInt(span - 1))) / @as(f32, @floatFromInt(span)));
                row_h = @max(row_h, o.h);
                any = true;
            }
            if (used == 0) break;
            total_h += row_h;
            rows += 1;
        }
        if (!any) {
            node.measured = .{ .w = node.intrinsic.w + pad.l + pad.r, .h = node.intrinsic.h + pad.t + pad.b };
            return;
        }
        const w = col_w * @as(f32, @floatFromInt(cols)) + gap * @as(f32, @floatFromInt(cols - 1));
        const ht = total_h + gap * @as(f32, @floatFromInt(rows - 1));
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
        const pad = resolveEdges(st.padding, pct_base);
        const cw = @max(node.rect.w - pad.l - pad.r, 0);

        // Flow children only: hidden and absolute ones take no part in the flex solve.
        var n: usize = 0;
        {
            var it = tree.children(h);
            while (it.next()) |c| {
                if (isFlow(tree.get(c).?)) n += 1;
            }
        }
        node.dirty.layout = false;
        node.dirty.children = false;
        node.dirty.style = false;
        node.dirty.child_layout = false;
        if (n > 0) {
            if (st.grid_columns > 0) self.placeGrid(tree, h, node, pad, cw) else try self.placeFlow(tree, h, node, n, pad, cw);
        }
        self.placeAbsolute(tree, h, node, pad);

        // Descend only where something changed. The decision lives on the
        // node because the recursive calls reuse the scratch buffers.
        var it = tree.children(h);
        while (it.next()) |c| {
            const cn = tree.get(c).?;
            if (!cn.place_pending) continue;
            cn.place_pending = false;
            try self.place(tree, c, cw);
        }
    }

    /// The next flow child after `it`'s position, advancing it.
    fn nextFlow(tree: *Tree, it: *Tree.ChildIterator) ?Handle {
        while (it.next()) |c| {
            if (isFlow(tree.get(c).?)) return c;
        }
        return null;
    }

    fn cellSpan(cn: *const Node, cols: u16) u16 {
        return @min(@max(cn.style.grid_span, 1), cols);
    }

    /// Grid placement: equal-width columns, rows as tall as their tallest cell.
    fn placeGrid(self: *Layout, tree: *Tree, h: Handle, node: *Node, pad: Pad, cw: f32) void {
        _ = self;
        const st = node.style;
        const cols: u16 = st.grid_columns;
        const gap = edge(st.gap, cw);
        const colf: f32 = @floatFromInt(cols);
        const col_w = @max((cw - gap * (colf - 1)) / colf, 0);
        var y: f32 = pad.t;
        var it = tree.children(h);
        while (true) {
            // Find the row: children until the next one would overflow the columns.
            var used: u16 = 0;
            var count: u32 = 0;
            var row_h: f32 = 0;
            var scan = it;
            while (true) {
                var peek = scan;
                const c = nextFlow(tree, &peek) orelse break;
                const cn = tree.get(c).?;
                const span = cellSpan(cn, cols);
                if (used > 0 and used + span > cols) break;
                used += span;
                count += 1;
                scan = peek;
                const m = resolveEdges(cn.style.margin, col_w);
                const nat = if (cn.style.height == .fill) cn.measured.h else length.resolveClamped(cn.style.height, cn.style.min_height, cn.style.max_height, .{ .parent = null, .content = cn.measured.h }).value;
                row_h = @max(row_h, nat + m.t + m.b);
            }
            if (count == 0) break;

            var col: u16 = 0;
            for (0..count) |_| {
                const c = nextFlow(tree, &it).?;
                const cn = tree.get(c).?;
                const cs = cn.style;
                const span = cellSpan(cn, cols);
                const spanf: f32 = @floatFromInt(span);
                const cell_w = spanf * col_w + (spanf - 1) * gap;
                const cell_x = pad.l + @as(f32, @floatFromInt(col)) * (col_w + gap);
                col += span;
                const m = resolveEdges(cs.margin, col_w);
                const inner_w = @max(cell_w - m.l - m.r, 0);
                const inner_h = @max(row_h - m.t - m.b, 0);
                const al = cs.align_self orelse st.align_items;

                const wctx: length.ResolveCtx = .{ .parent = inner_w, .content = cn.measured.w };
                const w = if (cs.width == .fill or (cs.width == .auto and al == .stretch))
                    length.clampSize(inner_w, minOf(cs.min_width, wctx), maxOf(cs.max_width, wctx))
                else
                    length.resolveClamped(cs.width, cs.min_width, cs.max_width, wctx).value;
                const hctx: length.ResolveCtx = .{ .parent = null, .content = cn.measured.h };
                const ht = if (cs.height == .fill or (cs.height == .auto and al == .stretch))
                    length.clampSize(inner_h, minOf(cs.min_height, hctx), maxOf(cs.max_height, hctx))
                else
                    length.resolveClamped(cs.height, cs.min_height, cs.max_height, hctx).value;
                const free = @max(inner_w - w, 0);
                const dx: f32 = switch (al) {
                    .start, .stretch => 0,
                    .center => free / 2,
                    .end => free,
                };
                setRect(tree, h, c, cn, .{ .x = cell_x + m.l + dx, .y = y + m.t, .w = w, .h = ht });
            }
            y += row_h + gap;
        }
    }

    fn isFlow(n: *const Node) bool {
        return !n.flags.hidden and n.style.position == .flow;
    }

    /// Write `new` as `cn`'s rect (a child of `h`), damaging old and new areas.
    fn setRect(tree: *Tree, h: Handle, c: Handle, cn: *Node, new: @TypeOf(cn.rect)) void {
        const old = cn.rect;
        cn.rect = new;
        const size_changed = new.w != old.w or new.h != old.h;
        if (size_changed or new.x != old.x or new.y != old.y) {
            // The area it used to cover needs redrawing too (`markDirty` adds
            // the new area).
            if (tree.absoluteRect(h)) |pa| {
                const hn = tree.get(h).?;
                tree.damage.add(Tree.withTextOverhang(cn, .{ .x = pa.x - hn.scroll_x + old.x, .y = pa.y - hn.scroll_y + old.y, .w = old.w, .h = old.h }));
            }
            if (size_changed) tree.markDirty(c, .{ .paint = true }) else tree.markMoved(c);
        }
        cn.place_pending = size_changed or cn.dirty.needsLayout() or cn.dirty.child_layout;
    }

    /// The flex solve for `h`'s `n` flow children, in one line or (with `wrap`)
    /// several, writing their rects.
    fn placeFlow(self: *Layout, tree: *Tree, h: Handle, node: *Node, n: usize, pad: Pad, cw: f32) error{OutOfMemory}!void {
        const st = node.style;
        const row = st.direction == .row;
        const ch = @max(node.rect.h - pad.t - pad.b, 0);
        const main_avail = pick(row, cw, ch);
        const cross_avail = pick(row, ch, cw);
        const main_definite = pick(row, st.width, st.height) != .fit;
        const cross_definite = pick(row, st.height, st.width) != .fit;
        const gap = length.resolve(st.gap, .{ .parent = if (main_definite) main_avail else null, .content = 0 }).value;
        try self.ensure(n);

        const items = self.items.items[0..n];
        const sizes = self.sizes.items[0..n];
        const kids = self.kids.items[0..n];

        // Main axis: one flex item per flow child.
        var i: usize = 0;
        var it = tree.children(h);
        while (it.next()) |c| {
            const cn = tree.get(c).?;
            if (!isFlow(cn)) continue;
            kids[i] = c;
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

        const cross_pad = pick(row, pad.t, pad.l);
        const can_wrap = st.wrap and main_definite;
        var cross_cursor: f32 = 0;
        var start: usize = 0;
        while (start < n) {
            // This line: everything up to the first child that would overflow.
            var end = start + 1;
            if (can_wrap) {
                var sum = items[start].basis;
                while (end < n and sum + gap + items[end].basis <= main_avail) : (end += 1) sum += gap + items[end].basis;
            } else end = n;
            const count = end - start;

            flex.solve(items[start..end], main_avail, gap, sizes[start..end], self.frozen.items[start..end]);
            var used: f32 = gap * @as(f32, @floatFromInt(count - 1));
            for (sizes[start..end]) |sz| used += sz;
            const leftover = @max(main_avail - used, 0);
            var pos = pick(row, pad.l, pad.t) + switch (st.justify) {
                .start, .stretch => 0,
                .center => leftover / 2,
                .end => leftover,
            };

            // A wrapped line is as tall as its tallest child; a single line is
            // the whole container's cross size.
            var line_cross = cross_avail;
            if (can_wrap) {
                line_cross = 0;
                for (kids[start..end]) |c| {
                    const cn = tree.get(c).?;
                    const cs = cn.style;
                    const m = resolveEdges(cs.margin, cw);
                    const cm = pick(row, m.t + m.b, m.l + m.r);
                    const clen = pick(row, cs.height, cs.width);
                    const cctx: length.ResolveCtx = .{ .parent = if (cross_definite) cross_avail else null, .content = pick(row, cn.measured.h, cn.measured.w) };
                    const natural = length.resolveClamped(clen, pick(row, cs.min_height, cs.min_width), pick(row, cs.max_height, cs.max_width), cctx).value;
                    line_cross = @max(line_cross, natural + cm);
                }
            }

            // Cross axis, alignment, and writing rects.
            for (kids[start..end], start..) |c, k| {
                const cn = tree.get(c).?;
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
                    cross_size = length.clampSize(@max(line_cross - cross_margin, 0), lo, hi);
                } else {
                    const r = length.resolve(clen, cctx);
                    self.noteCircular(r);
                    cross_size = length.clampSize(r.value, lo, hi);
                }
                const free = line_cross - cross_size - cross_margin;
                const cross_off = switch (al) {
                    .start, .stretch => 0,
                    .center => free / 2,
                    .end => free,
                };
                const cross_pos = cross_pad + cross_cursor + pick(row, m.t, m.l) + cross_off;

                const main_size = @max(sizes[k] - mm, 0);
                const main_pos = pos + pick(row, m.l, m.t);
                pos += sizes[k] + gap;

                const new: @TypeOf(cn.rect) = if (row)
                    .{ .x = main_pos, .y = cross_pos, .w = main_size, .h = cross_size }
                else
                    .{ .x = cross_pos, .y = main_pos, .w = cross_size, .h = main_size };
                setRect(tree, h, c, cn, new);
            }
            cross_cursor += line_cross + gap;
            start = end;
        }
    }

    /// Place `h`'s absolutely positioned children against its box (padding
    /// included): `inset` pins sides, an axis with both sides pinned and an auto
    /// size stretches, and an unpinned axis starts at the content edge.
    fn placeAbsolute(self: *Layout, tree: *Tree, h: Handle, node: *Node, pad: Pad) void {
        _ = self;
        var it = tree.children(h);
        while (it.next()) |c| {
            const cn = tree.get(c).?;
            if (cn.flags.hidden or cn.style.position != .absolute) continue;
            const cs = cn.style;
            const pw = node.rect.w;
            const ph = node.rect.h;
            const l = insetPx(cs.inset.left, pw);
            const r = insetPx(cs.inset.right, pw);
            const t = insetPx(cs.inset.top, ph);
            const b = insetPx(cs.inset.bottom, ph);
            const w = absoluteSize(cs.width, cs.min_width, cs.max_width, pw, cn.measured.w, l, r);
            const ht = absoluteSize(cs.height, cs.min_height, cs.max_height, ph, cn.measured.h, t, b);
            const x = if (l) |v| v else if (r) |v| pw - v - w else pad.l;
            const y = if (t) |v| v else if (b) |v| ph - v - ht else pad.t;
            setRect(tree, h, c, cn, .{ .x = x, .y = y, .w = w, .h = ht });
        }
    }

    fn insetPx(len: Length, base: f32) ?f32 {
        if (len == .auto) return null;
        return length.resolve(len, .{ .parent = base, .content = 0 }).value;
    }

    /// An absolute child's size on one axis within a parent `parent` long, with
    /// its near and far insets (null when free).
    fn absoluteSize(len: Length, min: Length, max: Length, parent: f32, content: f32, near: ?f32, far: ?f32) f32 {
        const ctx: length.ResolveCtx = .{ .parent = parent, .content = content };
        const lo = minOf(min, ctx);
        const hi = maxOf(max, ctx);
        if (len == .fill or (len == .auto and near != null and far != null)) {
            return length.clampSize(@max(parent - (near orelse 0) - (far orelse 0), 0), lo, hi);
        }
        return length.clampSize(length.resolve(len, ctx).value, lo, hi);
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

test "absolute children are pinned by insets and leave the flow alone" {
    var t = try Harness.init(.{ .direction = .column });
    defer t.deinit();
    const parent = try t.add(t.tree.root, .{ .style = .{ .width = Length.px(200), .height = Length.px(120), .padding = Edges.all(8), .direction = .column, .gap = Length.px(4) } });
    const a = try t.box(parent, 50, 20);
    const pinned = try t.add(parent, .{ .style = .{ .position = .absolute, .width = Length.px(30), .height = Length.px(30), .inset = .{ .right = Length.px(10), .bottom = Length.px(6) } } });
    const b = try t.box(parent, 50, 20);
    try t.run(400, 300);
    // The flow ignores the pinned node: b follows a directly (gap 4).
    try expectRect(t.rect(a), 8, 8, 50, 20);
    try expectRect(t.rect(b), 8, 32, 50, 20);
    // Pinned against the 200x120 box, not the content box.
    try expectRect(t.rect(pinned), 200 - 10 - 30, 120 - 6 - 30, 30, 30);
}

test "an absolute child with both sides pinned and no size stretches between them" {
    var t = try Harness.init(.{});
    defer t.deinit();
    const parent = try t.add(t.tree.root, .{ .style = .{ .width = Length.px(200), .height = Length.px(100) } });
    const s = try t.add(parent, .{ .style = .{ .position = .absolute, .inset = .{ .left = Length.px(10), .right = Length.px(20), .top = Length.px(5), .bottom = Length.px(15) } } });
    const pct = try t.add(parent, .{ .style = .{ .position = .absolute, .width = Length.pct(50), .height = Length.px(10), .inset = .{ .left = Length.pct(25), .top = Length.px(0) } } });
    const free = try t.add(parent, .{ .style = .{ .position = .absolute, .width = Length.px(40), .height = Length.px(40) } });
    try t.run(400, 300);
    try expectRect(t.rect(s), 10, 5, 170, 80);
    try expectRect(t.rect(pct), 50, 0, 100, 10); // percent of the parent's width
    try expectRect(t.rect(free), 0, 0, 40, 40); // no insets: the content corner
}

test "absolute children do not grow a fit parent and hidden ones are skipped" {
    var t = try Harness.init(.{ .align_items = .start });
    defer t.deinit();
    const parent = try t.add(t.tree.root, .{ .style = .{ .width = .fit, .height = .fit, .direction = .column } });
    _ = try t.box(parent, 60, 30);
    const big = try t.add(parent, .{ .style = .{ .position = .absolute, .width = Length.px(500), .height = Length.px(500) } });
    const hidden = try t.add(parent, .{ .style = .{ .position = .absolute, .width = Length.px(10), .height = Length.px(10) }, .flags = .{ .hidden = true } });
    try t.run(800, 600);
    try expectRect(t.rect(parent), 0, 0, 60, 30);
    try expectRect(t.rect(big), 0, 0, 500, 500);
    try expectRect(t.rect(hidden), 0, 0, 0, 0); // never placed
}

test "absolute children lay out their own children and move with the parent" {
    var t = try Harness.init(.{ .direction = .column, .padding = Edges.all(0) });
    defer t.deinit();
    const parent = try t.add(t.tree.root, .{ .style = .{ .width = Length.px(200), .height = Length.px(200) } });
    const panel = try t.add(parent, .{ .style = .{ .position = .absolute, .width = Length.px(100), .height = Length.px(80), .padding = Edges.all(10), .direction = .column, .inset = .{ .left = Length.px(30), .top = Length.px(40) } } });
    const inner = try t.box(panel, 20, 20);
    try t.run(400, 400);
    try expectRect(t.rect(inner), 10, 10, 20, 20);
    // Changing an inset relays out just that node.
    t.tree.get(panel).?.style.inset.left = Length.px(60);
    t.tree.markDirty(panel, .{ .layout = true, .paint = true });
    try t.run(400, 400);
    try expectRect(t.rect(panel), 60, 40, 100, 80);
    try expectRect(t.rect(inner), 10, 10, 20, 20);
}

test "wrap starts a new line when a child does not fit" {
    var t = try Harness.init(.{ .direction = .column, .align_items = .start });
    defer t.deinit();
    const row = try t.add(t.tree.root, .{ .style = .{ .direction = .row, .wrap = true, .width = Length.px(100), .height = Length.px(200), .gap = Length.px(10) } });
    const a = try t.box(row, 40, 20);
    const b = try t.box(row, 40, 30);
    const c = try t.box(row, 40, 20);
    const d = try t.box(row, 40, 25);
    try t.run(400, 400);
    // 40 + 10 + 40 = 90 fits; the third would need 140.
    try expectRect(t.rect(a), 0, 0, 40, 20);
    try expectRect(t.rect(b), 50, 0, 40, 30);
    // The second line starts below the first line's tallest child (30) plus the gap.
    try expectRect(t.rect(c), 0, 40, 40, 20);
    try expectRect(t.rect(d), 50, 40, 40, 25);
}

test "wrapped lines justify and align within themselves; column wrap goes sideways" {
    var t = try Harness.init(.{ .direction = .column, .align_items = .start });
    defer t.deinit();
    const row = try t.add(t.tree.root, .{ .style = .{ .direction = .row, .wrap = true, .justify = .center, .align_items = .center, .width = Length.px(100), .height = Length.px(200) } });
    const a = try t.box(row, 60, 20);
    const b = try t.box(row, 30, 40);
    const c = try t.box(row, 30, 10);
    try t.run(400, 400);
    // Line one: a alone (60 + 30 does not fit... 90 <= 100 fits, so a and b share it).
    try expectRect(t.rect(a), 5, 10, 60, 20); // centered in a 40-high line, 5px of slack either side
    try expectRect(t.rect(b), 65, 0, 30, 40);
    try expectRect(t.rect(c), 35, 40, 30, 10); // alone on line two: centered in x, the line is as tall as it is

    var u = try Harness.init(.{ .direction = .row, .align_items = .start });
    defer u.deinit();
    const col = try u.add(u.tree.root, .{ .style = .{ .direction = .column, .wrap = true, .width = Length.px(200), .height = Length.px(70) } });
    const e = try u.box(col, 30, 30);
    const f = try u.box(col, 20, 30);
    const g = try u.box(col, 25, 30);
    try u.run(400, 400);
    try expectRect(u.rect(e), 0, 0, 30, 30);
    try expectRect(u.rect(f), 0, 30, 20, 30);
    // The third does not fit in 70: next column, after the widest (30) of the first.
    try expectRect(u.rect(g), 30, 0, 25, 30);
}

test "wrap needs a definite main size; fit containers stay on one line" {
    var t = try Harness.init(.{ .direction = .column, .align_items = .start });
    defer t.deinit();
    const row = try t.add(t.tree.root, .{ .style = .{ .direction = .row, .wrap = true, .width = .fit } });
    const a = try t.box(row, 60, 20);
    const b = try t.box(row, 60, 20);
    try t.run(400, 400);
    try expectRect(t.rect(a), 0, 0, 60, 20);
    try expectRect(t.rect(b), 60, 0, 60, 20);
}

test "without wrap nothing changes: a single line shrinks as before" {
    var t = try Harness.init(.{ .direction = .column, .align_items = .start });
    defer t.deinit();
    const row = try t.add(t.tree.root, .{ .style = .{ .direction = .row, .width = Length.px(100), .height = Length.px(50) } });
    const a = try t.add(row, .{ .style = .{ .width = Length.px(80), .height = Length.px(20) } });
    const b = try t.add(row, .{ .style = .{ .width = Length.px(80), .height = Length.px(20) } });
    try t.run(400, 400);
    try expectRect(t.rect(a), 0, 0, 50, 20);
    try expectRect(t.rect(b), 50, 0, 50, 20);
}

test "grid: equal columns, rows as tall as their tallest cell, gap between" {
    var t = try Harness.init(.{});
    defer t.deinit();
    const g = try t.add(t.tree.root, .{ .style = .{ .grid_columns = 2, .width = Length.px(210), .height = Length.px(200), .gap = Length.px(10), .padding = Edges.all(5) } });
    const a = try t.add(g, .{ .style = .{ .height = Length.px(20) } }); // stretches to the column
    const b = try t.add(g, .{ .style = .{ .height = Length.px(30) } });
    const c = try t.add(g, .{ .style = .{ .width = Length.px(40), .height = Length.px(10) } });
    try t.run(400, 300);
    // Content 200 wide: columns (200 - 10) / 2 = 95.
    try expectRect(t.rect(a), 5, 5, 95, 20);
    try expectRect(t.rect(b), 110, 5, 95, 30);
    // Row 2 starts after the 30px tall first row plus the gap.
    try expectRect(t.rect(c), 5, 45, 40, 10);
}

test "grid: spans, alignment, and hidden children" {
    var t = try Harness.init(.{});
    defer t.deinit();
    const g = try t.add(t.tree.root, .{ .style = .{ .grid_columns = 3, .width = Length.px(300), .height = Length.px(200), .align_items = .center } });
    const wide = try t.add(g, .{ .style = .{ .grid_span = 2, .width = Length.px(100), .height = Length.px(20) } });
    const one = try t.add(g, .{ .style = .{ .width = Length.px(40), .height = Length.px(20) } });
    const hidden = try t.add(g, .{ .style = .{ .height = Length.px(99) }, .flags = .{ .hidden = true } });
    const next = try t.add(g, .{ .style = .{ .grid_span = 3, .width = Length.px(60), .height = Length.px(10) } });
    _ = hidden;
    try t.run(400, 300);
    // Columns are 100 wide: a span of 2 is 200 and centers its 100px child.
    try expectRect(t.rect(wide), 50, 0, 100, 20);
    try expectRect(t.rect(one), 230, 0, 40, 20);
    // The three-column span starts a new row and centers in 300.
    try expectRect(t.rect(next), 120, 20, 60, 10);
}

test "a fit-width grid sizes columns to the widest cell" {
    var t = try Harness.init(.{ .align_items = .start });
    defer t.deinit();
    const g = try t.add(t.tree.root, .{ .style = .{ .grid_columns = 2, .width = .fit, .height = .fit, .gap = Length.px(4) } });
    _ = try t.box(g, 30, 10);
    _ = try t.box(g, 50, 20);
    _ = try t.box(g, 20, 10);
    try t.run(400, 300);
    try expectRect(t.rect(g), 0, 0, 50 + 4 + 50, 20 + 4 + 10);
}
