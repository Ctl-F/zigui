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
//!
//! Keyboard focus: one focused node per tree (`Tree.focused`). A press that is
//! not handled focuses the nearest focusable ancestor-or-self of the node hit
//! (or clears focus when nothing focusable was hit). Key events go to the
//! focused node (or the root if none) and travel capture, target, bubble; an
//! unhandled Tab moves focus in tree order. `text_input` goes to the focused
//! node only. `focus_in`/`focus_out` fire when focus changes, however it changed.
//!
//! `keyboard` records the last input modality so painters can show focus rings
//! after keyboard use but not after a mouse click.

const std = @import("std");
const Handle = @import("handle.zig").Handle;
const Tree = @import("tree.zig").Tree;
const event = @import("event.zig");
const dispatch = @import("dispatch.zig");
const keys = @import("keys.zig");
const Event = event.Event;

pub const primary_button: u32 = 1;

pub const Input = struct {
    hover: Handle = Handle.invalid,
    pressed: Handle = Handle.invalid,
    pressed_button: u32 = 0,
    /// The node last notified with focus_in.
    focus_seen: Handle = Handle.invalid,
    /// True if the most recent input was from the keyboard.
    keyboard: bool = false,

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
        self.pointerButtonEx(tree, x, y, button, down, 1);
    }

    /// Like `pointerButton`, with the platform's consecutive-press count.
    pub fn pointerButtonEx(self: *Input, tree: *Tree, x: f32, y: f32, button: u32, down: bool, clicks: u32) void {
        const hit = tree.hitTest(x, y);
        self.setHover(tree, hit, x, y);

        if (down) {
            self.keyboard = false;
            var handled = false;
            if (hit) |h| {
                if (!tree.isValid(self.pressed)) {
                    self.pressed = h;
                    self.pressed_button = button;
                }
                var ev: Event = .{ .kind = .pointer_down, .target = h, .x = x, .y = y, .button = button, .clicks = clicks };
                dispatch.dispatch(tree, &ev);
                handled = ev.handled;
            }
            if (!handled) self.setFocus(tree, if (hit) |h| tree.focusableAtOrAbove(h) else null);
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

    // ---- keyboard focus ---------------------------------------------------

    /// Move focus to `h` (null clears it). Ignored if `h` is not focusable.
    pub fn setFocus(self: *Input, tree: *Tree, h: ?Handle) void {
        if (h) |n| {
            if (!tree.isFocusable(n)) return;
            tree.focused = n;
        } else {
            tree.focused = Handle.invalid;
        }
        self.syncFocus(tree);
    }

    /// Fire focus_out / focus_in if `tree.focused` differs from what nodes were
    /// last told (it also changes when a focused node is destroyed or hidden).
    pub fn syncFocus(self: *Input, tree: *Tree) void {
        // A focused node that became unfocusable (hidden, or lost its flag) loses focus.
        if (tree.isValid(tree.focused) and !tree.isFocusable(tree.focused)) {
            tree.focused = tree.focusableAtOrAbove(tree.get(tree.focused).?.parent) orelse Handle.invalid;
        }
        const new = if (tree.isValid(tree.focused)) tree.focused else Handle.invalid;
        const old = if (tree.isValid(self.focus_seen)) self.focus_seen else Handle.invalid;
        tree.focused = new;
        if (Handle.eql(old, new)) {
            self.focus_seen = new;
            return;
        }
        self.focus_seen = new;
        if (!old.isNull()) _ = send(tree, .focus_out, old, 0, 0);
        if (!new.isNull()) _ = send(tree, .focus_in, new, 0, 0);
    }

    /// Route a key press or release. Unhandled Tab / Shift+Tab move focus.
    pub fn key(self: *Input, tree: *Tree, k: keys.Key, mods: u32, down: bool, repeat: bool, scancode: u32, keycode: u32) void {
        self.syncFocus(tree);
        if (down) self.keyboard = true;
        const target = if (tree.isValid(tree.focused)) tree.focused else tree.root;
        var ev: Event = .{
            .kind = if (down) .key_down else .key_up,
            .target = target,
            .key = k,
            .mods = mods,
            .repeat = repeat,
            .scancode = scancode,
            .keycode = keycode,
        };
        dispatch.dispatch(tree, &ev);
        if (down and !ev.handled and k == .tab and mods & (keys.mod_ctrl | keys.mod_alt | keys.mod_gui) == 0) {
            const forward = mods & keys.mod_shift == 0;
            if (tree.nextFocusable(tree.focused, forward)) |n| self.setFocus(tree, n);
        }
    }

    /// Deliver committed text to the focused node (dropped if nothing is focused).
    pub fn textInput(self: *Input, tree: *Tree, text: []const u8) void {
        self.syncFocus(tree);
        if (!tree.isValid(tree.focused) or text.len == 0) return;
        self.keyboard = true;
        var ev: Event = .{ .kind = .text_input, .target = tree.focused, .text = text.ptr, .text_len = text.len };
        dispatch.dispatch(tree, &ev);
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

// ---- focus and keyboard tests ------------------------------------------------

fn focusBoxes(tree: *Tree, comptime n: usize) ![n]Handle {
    tree.get(tree.root).?.rect = .{ .w = 400, .h = 100 };
    var out: [n]Handle = undefined;
    for (&out, 0..) |*h, i| {
        h.* = try tree.create(.{ .flags = .{ .focusable = true } });
        try tree.appendChild(tree.root, h.*);
        tree.get(h.*).?.rect = .{ .x = @as(f32, @floatFromInt(i)) * 100, .y = 0, .w = 90, .h = 90 };
    }
    return out;
}

const FocusLog = struct {
    fn handler(ev: *Event, user: ?*anyopaque) callconv(.c) void {
        const s: *Spy = @ptrCast(@alignCast(user.?));
        s.log.add(s.tag);
        s.log.add(switch (ev.kind) {
            .focus_in => 'i',
            .focus_out => 'o',
            .key_down => 'k',
            .text_input => 't',
            else => '?',
        });
    }
};

fn spyFocus(tree: *Tree, h: Handle, spy: *Spy) !void {
    inline for (.{ event.EventKind.focus_in, .focus_out, .key_down, .text_input }) |k| {
        try tree.addListener(h, .{ .kind = k, .callback = FocusLog.handler, .user_data = spy });
    }
}

test "clicking a focusable node focuses it and blurs the previous one" {
    var tree = try Tree.init(std.testing.allocator);
    defer tree.deinit();
    const n = try focusBoxes(&tree, 2);
    var log: Log = .{};
    var s0: Spy = .{ .log = &log, .tag = 'A' };
    var s1: Spy = .{ .log = &log, .tag = 'B' };
    try spyFocus(&tree, n[0], &s0);
    try spyFocus(&tree, n[1], &s1);
    // Pointer listeners make the nodes hit-testable.
    const H = struct {
        fn h(_: *Event, _: ?*anyopaque) callconv(.c) void {}
    };
    try tree.addListener(n[0], .{ .kind = .click, .callback = H.h });
    try tree.addListener(n[1], .{ .kind = .click, .callback = H.h });

    var input: Input = .{};
    input.pointerButton(&tree, 10, 10, 1, true);
    try std.testing.expect(Handle.eql(tree.focused, n[0]));
    input.pointerButton(&tree, 110, 10, 1, true);
    try std.testing.expect(Handle.eql(tree.focused, n[1]));
    input.pointerButton(&tree, 300, 10, 1, true); // empty space blurs
    try std.testing.expect(tree.focused.isNull());
    try std.testing.expectEqualStrings("AiAoBiBo", log.str());
    try std.testing.expect(!input.keyboard);
}

test "keys go to the focused node, and unhandled Tab moves focus" {
    var tree = try Tree.init(std.testing.allocator);
    defer tree.deinit();
    const n = try focusBoxes(&tree, 3);
    var log: Log = .{};
    var s: [3]Spy = undefined;
    for (&s, 0..) |*sp, i| {
        sp.* = .{ .log = &log, .tag = 'A' + @as(u8, @intCast(i)) };
        try spyFocus(&tree, n[i], sp);
    }

    var input: Input = .{};
    input.key(&tree, .a, 0, true, false, 0, 0); // nothing focused: goes to the root, no listeners
    try std.testing.expectEqualStrings("", log.str());

    input.key(&tree, .tab, 0, true, false, 0, 0); // none -> first
    try std.testing.expect(Handle.eql(tree.focused, n[0]));
    input.key(&tree, .tab, 0, true, false, 0, 0);
    input.key(&tree, .tab, 0, true, false, 0, 0);
    try std.testing.expect(Handle.eql(tree.focused, n[2]));
    input.key(&tree, .tab, 0, true, false, 0, 0); // wraps
    try std.testing.expect(Handle.eql(tree.focused, n[0]));
    input.key(&tree, .tab, keys.mod_shift, true, false, 0, 0); // backwards wraps to the last
    try std.testing.expect(Handle.eql(tree.focused, n[2]));
    try std.testing.expect(input.keyboard);

    log.len = 0;
    input.key(&tree, .a, 0, true, false, 0, 0);
    try std.testing.expectEqualStrings("Ck", log.str()); // the focused node only (plus tab keys earlier)
}

test "a handler that handles Tab keeps focus where it is" {
    var tree = try Tree.init(std.testing.allocator);
    defer tree.deinit();
    const n = try focusBoxes(&tree, 2);
    const Eat = struct {
        fn h(ev: *Event, _: ?*anyopaque) callconv(.c) void {
            ev.markHandled();
        }
    };
    try tree.addListener(n[0], .{ .kind = .key_down, .callback = Eat.h });
    var input: Input = .{};
    input.setFocus(&tree, n[0]);
    input.key(&tree, .tab, 0, true, false, 0, 0);
    try std.testing.expect(Handle.eql(tree.focused, n[0]));
}

test "text input reaches only the focused node" {
    var tree = try Tree.init(std.testing.allocator);
    defer tree.deinit();
    const n = try focusBoxes(&tree, 2);
    var log: Log = .{};
    var s0: Spy = .{ .log = &log, .tag = 'A' };
    var s1: Spy = .{ .log = &log, .tag = 'B' };
    try spyFocus(&tree, n[0], &s0);
    try spyFocus(&tree, n[1], &s1);

    var input: Input = .{};
    input.textInput(&tree, "x"); // no focus: dropped
    input.setFocus(&tree, n[1]);
    input.textInput(&tree, "hi");
    try std.testing.expectEqualStrings("BiBt", log.str());
}

test "destroying or hiding the focused node moves focus to a focusable ancestor" {
    var tree = try Tree.init(std.testing.allocator);
    defer tree.deinit();
    const n = try focusBoxes(&tree, 1);
    const kid = try tree.create(.{ .flags = .{ .focusable = true } });
    try tree.appendChild(n[0], kid);

    var log: Log = .{};
    var s0: Spy = .{ .log = &log, .tag = 'A' };
    var sk: Spy = .{ .log = &log, .tag = 'K' };
    try spyFocus(&tree, n[0], &s0);
    try spyFocus(&tree, kid, &sk);

    var input: Input = .{};
    input.setFocus(&tree, kid);
    _ = tree.destroySubtree(kid);
    input.syncFocus(&tree);
    try std.testing.expect(Handle.eql(tree.focused, n[0]));
    try std.testing.expectEqualStrings("KiAi", log.str()); // K died: no focus_out for it

    tree.get(n[0]).?.flags.hidden = true;
    input.syncFocus(&tree);
    try std.testing.expect(tree.focused.isNull());
    try std.testing.expectEqualStrings("KiAiAo", log.str());
}

test "hidden and non-focusable nodes are skipped by Tab" {
    var tree = try Tree.init(std.testing.allocator);
    defer tree.deinit();
    const n = try focusBoxes(&tree, 3);
    tree.get(n[1]).?.flags.hidden = true;
    try std.testing.expect(Handle.eql(tree.nextFocusable(n[0], true).?, n[2]));
    try std.testing.expect(Handle.eql(tree.nextFocusable(n[2], false).?, n[0]));
    tree.get(n[0]).?.flags.focusable = false;
    tree.get(n[2]).?.flags.focusable = false;
    try std.testing.expect(tree.nextFocusable(Handle.invalid, true) == null);
}

test "a lone focusable node stays focused through Tab" {
    var tree = try Tree.init(std.testing.allocator);
    defer tree.deinit();
    const n = try focusBoxes(&tree, 1);
    try std.testing.expect(Handle.eql(tree.nextFocusable(n[0], true).?, n[0]));
    try std.testing.expect(Handle.eql(tree.nextFocusable(n[0], false).?, n[0]));
}
