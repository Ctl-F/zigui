//! Event dispatch: capture, target, bubble.
//!
//! Dispatch is immediate. While it runs, `Tree.destroySubtree` is deferred
//! until the outermost dispatch ends, so handlers can safely remove nodes
//! (including the one being dispatched to). Adding nodes and reparenting take
//! effect immediately; every step re-validates handles, so a node that
//! disappears mid-dispatch simply stops receiving the event.

const std = @import("std");
const Handle = @import("handle.zig").Handle;
const Tree = @import("tree.zig").Tree;
const event = @import("event.zig");
const Event = event.Event;
const Phase = event.Phase;

/// Ancestors deeper than this (counting from the target) are not visited.
pub const max_path = 256;

pub fn dispatch(tree: *Tree, ev: *Event) void {
    tree.beginDispatch();
    defer tree.endDispatch();

    var path: [max_path]Handle = undefined;
    var n: usize = 0;
    var cur = ev.target;
    while (n < max_path) {
        const node = tree.get(cur) orelse break;
        path[n] = cur;
        n += 1;
        cur = node.parent;
    }
    if (n == 0) return;

    const bubbles = ev.kind.bubbles();
    if (bubbles) {
        var i = n - 1;
        while (i >= 1) : (i -= 1) {
            fire(tree, ev, path[i], .capture);
            if (ev.stopped) return;
        }
    }
    fire(tree, ev, path[0], .target);
    if (bubbles) {
        for (path[1..n]) |h| {
            if (ev.stopped) return;
            fire(tree, ev, h, .bubble);
        }
    }
}

fn fire(tree: *Tree, ev: *Event, h: Handle, phase: Phase) void {
    ev.phase = phase;
    ev.current = h;
    if (tree.absoluteRect(h)) |r| {
        ev.local_x = ev.x - r.x;
        ev.local_y = ev.y - r.y;
    }
    // Handlers may add listeners (growing the list), so re-fetch by index.
    var i: usize = 0;
    while (true) : (i += 1) {
        const node = tree.get(h) orelse return;
        const list = node.listeners orelse return;
        if (i >= list.items.len) return;
        const l = list.items[i];
        if (l.kind != ev.kind) continue;
        if (phase != .target and l.capture != (phase == .capture)) continue;
        l.callback(ev, l.user_data);
    }
}

// ---- tests -----------------------------------------------------------------

const Log = struct {
    buf: [32]u8 = undefined,
    len: usize = 0,

    fn add(self: *Log, c: u8) void {
        self.buf[self.len] = c;
        self.len += 1;
    }

    fn str(self: *const Log) []const u8 {
        return self.buf[0..self.len];
    }
};

const Probe = struct { log: *Log, tag: u8, stop: bool = false };

fn probeHandler(ev: *Event, user: ?*anyopaque) callconv(.c) void {
    const p: *Probe = @ptrCast(@alignCast(user.?));
    p.log.add(p.tag);
    if (p.stop) ev.stopPropagation();
}

test "capture runs root-down, then target, then bubble up" {
    var tree = try Tree.init(std.testing.allocator);
    defer tree.deinit();
    const a = try tree.create(.{});
    const b = try tree.create(.{});
    try tree.appendChild(tree.root, a);
    try tree.appendChild(a, b);

    var log: Log = .{};
    var cap_root: Probe = .{ .log = &log, .tag = 'R' };
    var cap_a: Probe = .{ .log = &log, .tag = 'A' };
    var tgt: Probe = .{ .log = &log, .tag = 'T' };
    var bub_a: Probe = .{ .log = &log, .tag = 'a' };
    var bub_root: Probe = .{ .log = &log, .tag = 'r' };
    try tree.addListener(tree.root, .{ .kind = .click, .capture = true, .callback = probeHandler, .user_data = &cap_root });
    try tree.addListener(a, .{ .kind = .click, .capture = true, .callback = probeHandler, .user_data = &cap_a });
    try tree.addListener(b, .{ .kind = .click, .callback = probeHandler, .user_data = &tgt });
    try tree.addListener(a, .{ .kind = .click, .callback = probeHandler, .user_data = &bub_a });
    try tree.addListener(tree.root, .{ .kind = .click, .callback = probeHandler, .user_data = &bub_root });

    var ev: Event = .{ .kind = .click, .target = b };
    dispatch(&tree, &ev);
    try std.testing.expectEqualStrings("RATar", log.str());
}

test "stopPropagation finishes the current node then stops" {
    var tree = try Tree.init(std.testing.allocator);
    defer tree.deinit();
    const a = try tree.create(.{});
    const b = try tree.create(.{});
    try tree.appendChild(tree.root, a);
    try tree.appendChild(a, b);

    var log: Log = .{};
    var t1: Probe = .{ .log = &log, .tag = '1', .stop = true };
    var t2: Probe = .{ .log = &log, .tag = '2' };
    var up: Probe = .{ .log = &log, .tag = 'u' };
    try tree.addListener(b, .{ .kind = .click, .callback = probeHandler, .user_data = &t1 });
    try tree.addListener(b, .{ .kind = .click, .callback = probeHandler, .user_data = &t2 });
    try tree.addListener(a, .{ .kind = .click, .callback = probeHandler, .user_data = &up });

    var ev: Event = .{ .kind = .click, .target = b };
    dispatch(&tree, &ev);
    try std.testing.expectEqualStrings("12", log.str());
}

test "non-bubbling kinds only reach the target" {
    var tree = try Tree.init(std.testing.allocator);
    defer tree.deinit();
    const a = try tree.create(.{});
    try tree.appendChild(tree.root, a);

    var log: Log = .{};
    var on_root: Probe = .{ .log = &log, .tag = 'r' };
    var on_a: Probe = .{ .log = &log, .tag = 'a' };
    try tree.addListener(tree.root, .{ .kind = .pointer_enter, .callback = probeHandler, .user_data = &on_root });
    try tree.addListener(a, .{ .kind = .pointer_enter, .callback = probeHandler, .user_data = &on_a });
    var ev: Event = .{ .kind = .pointer_enter, .target = a };
    dispatch(&tree, &ev);
    try std.testing.expectEqualStrings("a", log.str());
}

test "listeners only see their own kind, and local coordinates are relative" {
    var tree = try Tree.init(std.testing.allocator);
    defer tree.deinit();
    const a = try tree.create(.{});
    try tree.appendChild(tree.root, a);
    tree.get(a).?.rect = .{ .x = 10, .y = 20, .w = 50, .h = 50 };

    const Seen = struct {
        var lx: f32 = -1;
        var ly: f32 = -1;
        fn h(ev: *Event, _: ?*anyopaque) callconv(.c) void {
            lx = ev.local_x;
            ly = ev.local_y;
        }
    };
    try tree.addListener(a, .{ .kind = .pointer_down, .callback = Seen.h });
    var other: Event = .{ .kind = .pointer_up, .target = a, .x = 15, .y = 25 };
    dispatch(&tree, &other);
    try std.testing.expectEqual(@as(f32, -1), Seen.lx);

    var ev: Event = .{ .kind = .pointer_down, .target = a, .x = 15, .y = 25 };
    dispatch(&tree, &ev);
    try std.testing.expectEqual(@as(f32, 5), Seen.lx);
    try std.testing.expectEqual(@as(f32, 5), Seen.ly);
}

test "destroying the target inside a handler is deferred until dispatch ends" {
    var tree = try Tree.init(std.testing.allocator);
    defer tree.deinit();
    const a = try tree.create(.{});
    try tree.appendChild(tree.root, a);

    const Ctx = struct {
        tree: *Tree,
        target: Handle,
        alive_after_destroy: bool = false,
    };
    const H = struct {
        fn h(ev: *Event, user: ?*anyopaque) callconv(.c) void {
            const ctx: *Ctx = @ptrCast(@alignCast(user.?));
            _ = ctx.tree.destroySubtree(ev.target);
            ctx.alive_after_destroy = ctx.tree.isValid(ev.target); // still alive mid-dispatch
        }
    };
    var ctx: Ctx = .{ .tree = &tree, .target = a };
    try tree.addListener(a, .{ .kind = .click, .callback = H.h, .user_data = &ctx });

    var ev: Event = .{ .kind = .click, .target = a };
    dispatch(&tree, &ev);
    try std.testing.expect(ctx.alive_after_destroy);
    try std.testing.expect(!tree.isValid(a));
    try std.testing.expectEqual(@as(u32, 1), tree.count());
}

test "removing the last pointer listener clears the interactive bit" {
    var tree = try Tree.init(std.testing.allocator);
    defer tree.deinit();
    const a = try tree.create(.{});
    try tree.appendChild(tree.root, a);
    const H = struct {
        fn h(_: *Event, _: ?*anyopaque) callconv(.c) void {}
    };
    try tree.addListener(a, .{ .kind = .click, .callback = H.h });
    try std.testing.expect(tree.get(a).?.flags.interactive);
    tree.removeListener(a, .click, H.h, null);
    try std.testing.expect(!tree.get(a).?.flags.interactive);
    try std.testing.expect(tree.get(a).?.listeners == null);
}

test "hit test picks the topmost interactive node and respects clipping" {
    var tree = try Tree.init(std.testing.allocator);
    defer tree.deinit();
    tree.get(tree.root).?.rect = .{ .w = 200, .h = 200 };

    const H = struct {
        fn h(_: *Event, _: ?*anyopaque) callconv(.c) void {}
    };
    const under = try tree.create(.{});
    const over = try tree.create(.{});
    const plain = try tree.create(.{});
    try tree.appendChild(tree.root, under);
    try tree.appendChild(tree.root, over);
    try tree.appendChild(tree.root, plain);
    tree.get(under).?.rect = .{ .x = 0, .y = 0, .w = 100, .h = 100 };
    tree.get(over).?.rect = .{ .x = 50, .y = 50, .w = 100, .h = 100 };
    tree.get(plain).?.rect = .{ .x = 0, .y = 150, .w = 200, .h = 50 }; // not interactive
    try tree.addListener(under, .{ .kind = .click, .callback = H.h });
    try tree.addListener(over, .{ .kind = .click, .callback = H.h });

    try std.testing.expect(Handle.eql(tree.hitTest(10, 10).?, under));
    try std.testing.expect(Handle.eql(tree.hitTest(60, 60).?, over)); // overlap: later sibling wins
    try std.testing.expect(tree.hitTest(10, 160) == null);
    try std.testing.expect(tree.hitTest(190, 10) == null);

    // A clipping parent hides children that overflow it.
    const clip = try tree.create(.{});
    try tree.appendChild(tree.root, clip);
    tree.get(clip).?.rect = .{ .x = 0, .y = 0, .w = 20, .h = 20 };
    tree.get(clip).?.flags.clip_children = true;
    const kid = try tree.create(.{});
    try tree.appendChild(clip, kid);
    tree.get(kid).?.rect = .{ .x = 0, .y = 0, .w = 100, .h = 100 };
    try tree.addListener(kid, .{ .kind = .click, .callback = H.h });
    try std.testing.expect(Handle.eql(tree.hitTest(10, 10).?, kid));
    try std.testing.expect(!Handle.eql(tree.hitTest(60, 10) orelse Handle.invalid, kid));

    tree.get(over).?.flags.hidden = true;
    try std.testing.expect(Handle.eql(tree.hitTest(60, 60).?, under));
}
