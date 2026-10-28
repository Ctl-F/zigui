//! A randomized stress test of the event system: pointer, keyboard, focus
//! scopes, and listeners that fight back (stop propagation, destroy nodes,
//! reparent, hide, change focusability) while events are being delivered.
//!
//! After every operation the tree must still be a consistent tree, no dispatch
//! may be left open, deferred destroys must have run, and the input state must
//! only refer to live nodes or to none. Run under the leak-checking allocator.

const std = @import("std");
const Handle = @import("handle.zig").Handle;
const Tree = @import("tree.zig").Tree;
const Input = @import("input.zig").Input;
const event = @import("event.zig");
const keys = @import("keys.zig");
const Rect = @import("geometry.zig").Rect;

const max_nodes = 48;

const Fuzz = struct {
    tree: Tree,
    input: Input = .{},
    rng: std.Random.DefaultPrng,
    nodes: [max_nodes]Handle = undefined,
    n: usize = 0,
    events: u64 = 0,

    fn random(self: *Fuzz) std.Random {
        return self.rng.random();
    }

    fn pick(self: *Fuzz) ?Handle {
        if (self.n == 0) return null;
        const h = self.nodes[self.random().uintLessThan(usize, self.n)];
        return if (self.tree.isValid(h)) h else null;
    }

    fn onEvent(ctx: ?*anyopaque, ev: *event.Event) void {
        const self: *Fuzz = @ptrCast(@alignCast(ctx.?));
        self.events += 1;
        const r = self.random();
        switch (r.uintLessThan(u32, 100)) {
            0...4 => ev.stopPropagation(),
            5...14 => ev.handled = true,
            15...17 => if (self.pick()) |h| {
                if (!Handle.eql(h, self.tree.root)) _ = self.tree.destroySubtree(h);
            },
            18...20 => if (self.pick()) |a| if (self.pick()) |b| {
                if (!Handle.eql(a, self.tree.root)) self.tree.appendChild(b, a) catch {};
            },
            21...22 => if (self.pick()) |h| {
                if (self.tree.get(h)) |nd| nd.flags.hidden = !nd.flags.hidden;
            },
            23...25 => if (self.pick()) |h| {
                if (self.tree.get(h)) |nd| nd.flags.focusable = !nd.flags.focusable;
            },
            26...27 => if (self.pick()) |h| self.input.setFocus(&self.tree, h),
            else => {},
        }
    }

    fn build(self: *Fuzz) !void {
        const r = self.random();
        self.nodes[0] = self.tree.root;
        self.n = 1;
        self.tree.get(self.tree.root).?.rect = .{ .x = 0, .y = 0, .w = 400, .h = 400 };
        while (self.n < max_nodes) {
            const parent = self.nodes[r.uintLessThan(usize, self.n)];
            const pr = self.tree.get(parent).?.rect;
            const w = r.float(f32) * pr.w * 0.8 + 10;
            const h = r.float(f32) * pr.h * 0.8 + 10;
            const node = try self.tree.create(.{
                .rect = .{ .x = r.float(f32) * (pr.w - w), .y = r.float(f32) * (pr.h - h), .w = w, .h = h },
                .flags = .{
                    .focusable = r.boolean(),
                    .clip_children = r.uintLessThan(u8, 4) == 0,
                },
            });
            try self.tree.appendChild(parent, node);
            const kinds = [_]event.EventKind{ .pointer_down, .pointer_up, .pointer_move, .pointer_enter, .pointer_leave, .click, .key_down, .wheel, .focus_in, .focus_out, .text_input };
            for (kinds) |k| {
                if (r.uintLessThan(u8, 3) == 0) {
                    try self.tree.addListener(node, .{ .kind = k, .capture = r.boolean(), .callback = .{ .ctx = self, .call = onEvent } });
                }
            }
            self.nodes[self.n] = node;
            self.n += 1;
        }
    }

    /// Everything reachable from the root links back correctly, and counts agree.
    fn checkTree(self: *Fuzz) !void {
        var visited: usize = 0;
        var cur: ?Handle = self.tree.root;
        while (cur) |h| : (cur = self.tree.nextPreorder(self.tree.root, h)) {
            visited += 1;
            const node = self.tree.get(h) orelse return error.DanglingNode;
            var child = node.first_child;
            var prev = Handle.invalid;
            while (self.tree.get(child)) |c| : (child = c.next) {
                if (!Handle.eql(c.parent, h)) return error.WrongParent;
                if (!Handle.eql(c.prev, prev)) return error.WrongPrev;
                prev = child;
            }
            if (!Handle.eql(node.last_child, prev)) return error.WrongLastChild;
            if (visited > 10_000) return error.Cycle;
        }
        // Detached (but alive) subtrees are not reachable; the pool may hold more.
        try std.testing.expect(visited <= self.tree.count());
    }

    fn checkInput(self: *Fuzz) !void {
        try std.testing.expectEqual(@as(u32, 0), self.tree.dispatch_depth);
        try std.testing.expectEqual(@as(usize, 0), self.tree.deferred.items.len);
        // Settle focus the way a frame would, then it must be usable.
        self.input.syncFocus(&self.tree);
        if (self.tree.isValid(self.tree.focused)) {
            try std.testing.expect(self.tree.isFocusable(self.tree.focused));
        }
        // Scopes never keep dead roots on top.
        if (self.input.activeScope(&self.tree)) |sc| try std.testing.expect(self.tree.isValid(sc.root));
    }

    fn step(self: *Fuzz) !void {
        const r = self.random();
        const x = r.float(f32) * 420 - 10;
        const y = r.float(f32) * 420 - 10;
        switch (r.uintLessThan(u32, 100)) {
            0...34 => self.input.pointerMove(&self.tree, x, y),
            35...49 => self.input.pointerButtonEx(&self.tree, x, y, 1, true, 1),
            50...64 => self.input.pointerButtonEx(&self.tree, x, y, 1, false, 1),
            65...67 => self.input.pointerButtonEx(&self.tree, x, y, 3, r.boolean(), 1),
            68...72 => self.input.wheel(&self.tree, x, y, 0, 1),
            73...80 => {
                const k = [_]keys.Key{ .tab, .a, .enter, .escape, .left };
                _ = self.input.keyEx(&self.tree, k[r.uintLessThan(usize, k.len)], .{ .shift = r.boolean() }, r.boolean(), false, 0, 0, null);
            },
            81...83 => self.input.textInput(&self.tree, "x"),
            84...87 => if (self.pick()) |h| self.input.setFocus(&self.tree, h),
            88...89 => if (self.pick()) |h| {
                _ = self.input.pushScope(&self.tree, h, r.boolean());
            },
            90...91 => self.input.popScope(&self.tree),
            92...93 => self.input.cancelPress(&self.tree, x, y),
            94 => self.input.pointerLeft(&self.tree),
            95...97 => if (self.pick()) |h| {
                if (!Handle.eql(h, self.tree.root)) _ = self.tree.destroySubtree(h);
            },
            else => if (self.pick()) |h| {
                if (self.tree.get(h)) |nd| nd.flags.hidden = !nd.flags.hidden;
            },
        }
        try self.checkTree();
        try self.checkInput();
    }
};

fn runSeed(seed: u64, steps: usize) !void {
    var f: Fuzz = .{ .tree = try Tree.init(std.testing.allocator), .rng = std.Random.DefaultPrng.init(seed) };
    defer f.tree.deinit();
    try f.build();
    var i: usize = 0;
    while (i < steps) : (i += 1) f.step() catch |err| {
        std.debug.print("event fuzz: seed {d} step {d}: {s}\n", .{ seed, i, @errorName(err) });
        return err;
    };
    try std.testing.expect(f.events > 0);
}

test "random input against hostile listeners never corrupts the tree or the input state" {
    var seed: u64 = 1;
    while (seed <= 40) : (seed += 1) try runSeed(seed, 1500);
}

test "a press whose release was lost does not misroute the next click" {
    var tree = try Tree.init(std.testing.allocator);
    defer tree.deinit();
    var input: Input = .{};
    const Log = struct {
        var downs: u32 = 0;
        var ups: u32 = 0;
        var clicks: u32 = 0;
        fn on(ctx: ?*anyopaque, ev: *event.Event) void {
            const tag: *u8 = @ptrCast(@alignCast(ctx.?));
            switch (ev.kind) {
                .pointer_down => downs += 1,
                .pointer_up => ups += 1,
                .click => clicks += tag.*,
                else => {},
            }
        }
    };
    Log.downs = 0;
    Log.ups = 0;
    Log.clicks = 0;
    var tag_a: u8 = 1;
    var tag_b: u8 = 10;
    const a = try tree.create(.{ .rect = .{ .x = 0, .y = 0, .w = 50, .h = 50 } });
    const b = try tree.create(.{ .rect = .{ .x = 100, .y = 0, .w = 50, .h = 50 } });
    try tree.appendChild(tree.root, a);
    try tree.appendChild(tree.root, b);
    tree.get(tree.root).?.rect = .{ .x = 0, .y = 0, .w = 200, .h = 100 };
    for ([_]struct { Handle, *u8 }{ .{ a, &tag_a }, .{ b, &tag_b } }) |p| {
        for ([_]event.EventKind{ .pointer_down, .pointer_up, .click }) |k| {
            try tree.addListener(p[0], .{ .kind = k, .callback = .{ .ctx = p[1], .call = Log.on } });
        }
    }
    // Press on A; the release happens outside the window and never arrives.
    input.pointerButtonEx(&tree, 10, 10, 1, true, 1);
    try std.testing.expect(Handle.eql(input.pressed, a));
    // The next press, on B, ends A's press (it gets its pointer_up, no click)...
    input.pointerButtonEx(&tree, 110, 10, 1, true, 1);
    try std.testing.expectEqual(@as(u32, 1), Log.ups);
    try std.testing.expect(Handle.eql(input.pressed, b));
    // ...and its own release clicks B, not A.
    input.pointerButtonEx(&tree, 110, 10, 1, false, 1);
    try std.testing.expectEqual(@as(u32, 10), Log.clicks);
    try std.testing.expect(!tree.isValid(input.pressed));
}

test "pointerLeft clears hover unless a button is held; cancelPress ends a press without a click" {
    var tree = try Tree.init(std.testing.allocator);
    defer tree.deinit();
    var input: Input = .{};
    const Log = struct {
        var leaves: u32 = 0;
        var ups: u32 = 0;
        var clicks: u32 = 0;
        fn on(_: ?*anyopaque, ev: *event.Event) void {
            switch (ev.kind) {
                .pointer_leave => leaves += 1,
                .pointer_up => ups += 1,
                .click => clicks += 1,
                else => {},
            }
        }
    };
    Log.leaves = 0;
    Log.ups = 0;
    Log.clicks = 0;
    const a = try tree.create(.{ .rect = .{ .x = 0, .y = 0, .w = 50, .h = 50 } });
    try tree.appendChild(tree.root, a);
    tree.get(tree.root).?.rect = .{ .x = 0, .y = 0, .w = 100, .h = 100 };
    for ([_]event.EventKind{ .pointer_leave, .pointer_up, .click }) |k| {
        try tree.addListener(a, .{ .kind = k, .callback = .{ .call = Log.on } });
    }
    input.pointerMove(&tree, 10, 10);
    try std.testing.expect(Handle.eql(input.hover, a));
    input.pointerLeft(&tree);
    try std.testing.expectEqual(@as(u32, 1), Log.leaves);
    try std.testing.expect(!tree.isValid(input.hover));

    input.pointerMove(&tree, 10, 10);
    input.pointerButtonEx(&tree, 10, 10, 1, true, 1);
    input.pointerLeft(&tree); // held: the capture keeps the hover
    try std.testing.expectEqual(@as(u32, 1), Log.leaves);
    input.cancelPress(&tree, 10, 10);
    try std.testing.expectEqual(@as(u32, 1), Log.ups);
    try std.testing.expectEqual(@as(u32, 0), Log.clicks);
    try std.testing.expect(!tree.isValid(input.pressed));
    input.cancelPress(&tree, 10, 10); // nothing pressed: harmless
    try std.testing.expectEqual(@as(u32, 1), Log.ups);
}
