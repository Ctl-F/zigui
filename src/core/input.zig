//! Pointer input state machine: hover tracking, press capture, click synthesis.
//!
//! Feed it window-space pointer positions and buttons; it hit-tests the tree
//! and dispatches events:
//!
//! - `pointer_enter` / `pointer_leave` for each node whose subtree the pointer
//!   enters or leaves (outermost first on enter, deepest first on leave).
//! - A press captures the pointer: `pointer_move` and `pointer_up` go to the
//!   pressed node even if the pointer has left it.
//! - `click` fires on the pressed node if the release is still inside its
//!   subtree, after `pointer_up`.

const std = @import("std");
const Handle = @import("handle.zig").Handle;
const Tree = @import("tree.zig").Tree;
const event = @import("event.zig");
const dispatch = @import("dispatch.zig");
const Event = event.Event;

pub const primary_button: u32 = 1;

pub const Input = struct {
    hover: Handle = Handle.invalid,
    pressed: Handle = Handle.invalid,
    pressed_button: u32 = 0,

    /// True if `a` is `n` or one of its ancestors.
    fn selfOrAncestor(tree: *Tree, a: Handle, n: Handle) bool {
        return Handle.eql(a, n) or tree.isAncestor(a, n);
    }

    fn send(tree: *Tree, kind: event.EventKind, target: Handle, x: f32, y: f32) Event {
        var ev: Event = .{ .kind = kind, .target = target, .x = x, .y = y };
        dispatch.dispatch(tree, &ev);
        return ev;
    }

    fn setHover(self: *Input, tree: *Tree, new_hit: ?Handle, x: f32, y: f32) void {
        const new = new_hit orelse Handle.invalid;
        const old = if (tree.isValid(self.hover)) self.hover else Handle.invalid;
        if (Handle.eql(old, new)) return;

        // Leave: from the old node up, until reaching a node that still contains the pointer.
        var cur = old;
        while (tree.get(cur)) |n| {
            if (selfOrAncestor(tree, cur, new)) break;
            const parent = n.parent;
            _ = send(tree, .pointer_leave, cur, x, y);
            cur = parent;
        }

        // Enter: outermost new node first.
        var chain: [dispatch.max_path]Handle = undefined;
        var count: usize = 0;
        cur = new;
        while (count < chain.len) {
            const n = tree.get(cur) orelse break;
            if (selfOrAncestor(tree, cur, old)) break;
            chain[count] = cur;
            count += 1;
            cur = n.parent;
        }
        while (count > 0) {
            count -= 1;
            _ = send(tree, .pointer_enter, chain[count], x, y);
        }
        self.hover = new;
    }

    pub fn pointerMove(self: *Input, tree: *Tree, x: f32, y: f32) void {
        const hit = tree.hitTest(x, y);
        self.setHover(tree, hit, x, y);
        const target = if (tree.isValid(self.pressed)) self.pressed else (hit orelse return);
        _ = send(tree, .pointer_move, target, x, y);
    }

    pub fn pointerButton(self: *Input, tree: *Tree, x: f32, y: f32, button: u32, down: bool) void {
        const hit = tree.hitTest(x, y);
        self.setHover(tree, hit, x, y);

        if (down) {
            if (hit) |h| {
                if (!tree.isValid(self.pressed)) {
                    self.pressed = h;
                    self.pressed_button = button;
                }
                var ev: Event = .{ .kind = .pointer_down, .target = h, .x = x, .y = y, .button = button };
                dispatch.dispatch(tree, &ev);
            }
            return;
        }

        const captured = tree.isValid(self.pressed);
        const target = if (captured) self.pressed else (hit orelse return);
        var up: Event = .{ .kind = .pointer_up, .target = target, .x = x, .y = y, .button = button };
        dispatch.dispatch(tree, &up);

        if (captured and button == self.pressed_button) {
            const pressed = self.pressed;
            self.pressed = Handle.invalid;
            self.pressed_button = 0;
            if (hit) |h| {
                if (selfOrAncestor(tree, pressed, h)) {
                    var click: Event = .{ .kind = .click, .target = pressed, .x = x, .y = y, .button = button };
                    dispatch.dispatch(tree, &click);
                }
            }
        }
        // The pointer may now be over something else (or the pressed node was removed).
        self.setHover(tree, tree.hitTest(x, y), x, y);
    }

    pub fn wheel(self: *Input, tree: *Tree, x: f32, y: f32, dx: f32, dy: f32) void {
        _ = self;
        const hit = tree.hitTest(x, y) orelse return;
        var ev: Event = .{ .kind = .wheel, .target = hit, .x = x, .y = y, .dx = dx, .dy = dy };
        dispatch.dispatch(tree, &ev);
    }
};

// ---- tests -----------------------------------------------------------------

const Log = struct {
    buf: [64]u8 = undefined,
    len: usize = 0,

    fn add(self: *Log, c: u8) void {
        if (self.len < self.buf.len) {
            self.buf[self.len] = c;
            self.len += 1;
        }
    }

    fn str(self: *const Log) []const u8 {
        return self.buf[0..self.len];
    }
};

/// A node that logs "<tag><kind letter>" for the kinds it hears.
const Spy = struct {
    log: *Log,
    tag: u8,

    fn handler(ev: *Event, user: ?*anyopaque) callconv(.c) void {
        const s: *Spy = @ptrCast(@alignCast(user.?));
        const k: u8 = switch (ev.kind) {
            .pointer_enter => 'e',
            .pointer_leave => 'l',
            .pointer_down => 'd',
            .pointer_up => 'u',
            .click => 'c',
            .pointer_move => 'm',
            else => '?',
        };
        s.log.add(s.tag);
        s.log.add(k);
    }

    fn attach(self: *Spy, tree: *Tree, h: Handle, comptime kinds: []const event.EventKind) !void {
        inline for (kinds) |k| try tree.addListener(h, .{ .kind = k, .callback = handler, .user_data = self });
    }
};

const all_kinds = [_]event.EventKind{ .pointer_enter, .pointer_leave, .pointer_down, .pointer_up, .click };

fn twoBoxes(tree: *Tree) !struct { a: Handle, b: Handle } {
    tree.get(tree.root).?.rect = .{ .w = 300, .h = 100 };
    const a = try tree.create(.{});
    const b = try tree.create(.{});
    try tree.appendChild(tree.root, a);
    try tree.appendChild(tree.root, b);
    tree.get(a).?.rect = .{ .x = 0, .y = 0, .w = 100, .h = 100 };
    tree.get(b).?.rect = .{ .x = 150, .y = 0, .w = 100, .h = 100 };
    return .{ .a = a, .b = b };
}

test "hover enters and leaves as the pointer moves" {
    var tree = try Tree.init(std.testing.allocator);
    defer tree.deinit();
    const n = try twoBoxes(&tree);
    var log: Log = .{};
    var sa: Spy = .{ .log = &log, .tag = 'A' };
    var sb: Spy = .{ .log = &log, .tag = 'B' };
    try sa.attach(&tree, n.a, &all_kinds);
    try sb.attach(&tree, n.b, &all_kinds);

    var input: Input = .{};
    input.pointerMove(&tree, 10, 10);
    input.pointerMove(&tree, 20, 20); // still inside A: nothing new
    input.pointerMove(&tree, 125, 50); // gap: leaves A
    input.pointerMove(&tree, 160, 50); // enters B
    try std.testing.expectEqualStrings("AeAlBe", log.str());
}

test "press captures the pointer and click fires on release inside" {
    var tree = try Tree.init(std.testing.allocator);
    defer tree.deinit();
    const n = try twoBoxes(&tree);
    var log: Log = .{};
    var sa: Spy = .{ .log = &log, .tag = 'A' };
    try sa.attach(&tree, n.a, &all_kinds);

    var input: Input = .{};
    input.pointerButton(&tree, 10, 10, 1, true);
    input.pointerButton(&tree, 10, 10, 1, false);
    try std.testing.expectEqualStrings("AeAdAuAc", log.str());
}

test "releasing outside after a press delivers up but no click" {
    var tree = try Tree.init(std.testing.allocator);
    defer tree.deinit();
    const n = try twoBoxes(&tree);
    var log: Log = .{};
    var sa: Spy = .{ .log = &log, .tag = 'A' };
    var sb: Spy = .{ .log = &log, .tag = 'B' };
    try sa.attach(&tree, n.a, &all_kinds);
    try sb.attach(&tree, n.b, &all_kinds);

    var input: Input = .{};
    input.pointerButton(&tree, 10, 10, 1, true);
    input.pointerButton(&tree, 160, 10, 1, false); // released over B
    // Hover moves to B first, then A (captured) gets the up and no click.
    // B only ever sees hover.
    try std.testing.expectEqualStrings("AeAdAlBeAu", log.str());
}

test "nested hover: parent stays hovered while moving between children" {
    var tree = try Tree.init(std.testing.allocator);
    defer tree.deinit();
    tree.get(tree.root).?.rect = .{ .w = 300, .h = 100 };
    const p = try tree.create(.{});
    const c1 = try tree.create(.{});
    const c2 = try tree.create(.{});
    try tree.appendChild(tree.root, p);
    try tree.appendChild(p, c1);
    try tree.appendChild(p, c2);
    tree.get(p).?.rect = .{ .x = 0, .y = 0, .w = 200, .h = 100 };
    tree.get(c1).?.rect = .{ .x = 0, .y = 0, .w = 100, .h = 100 };
    tree.get(c2).?.rect = .{ .x = 100, .y = 0, .w = 100, .h = 100 };
    var log: Log = .{};
    var sp: Spy = .{ .log = &log, .tag = 'P' };
    var s1: Spy = .{ .log = &log, .tag = '1' };
    var s2: Spy = .{ .log = &log, .tag = '2' };
    try sp.attach(&tree, p, &all_kinds);
    try s1.attach(&tree, c1, &all_kinds);
    try s2.attach(&tree, c2, &all_kinds);

    var input: Input = .{};
    input.pointerMove(&tree, 10, 10); // enter P, then 1
    input.pointerMove(&tree, 150, 10); // leave 1, enter 2; P keeps hover
    input.pointerMove(&tree, 250, 10); // leave 2 then P
    try std.testing.expectEqualStrings("Pe1e1l2e2lPl", log.str());
}
