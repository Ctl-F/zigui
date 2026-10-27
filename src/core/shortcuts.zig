//! Shortcut system: key chords bound to named commands, with scopes and
//! multi-key sequences (design doc sections 16 and 23).
//!
//! Scopes, least to most specific:
//!   app     active everywhere
//!   window  active in this window's tree (same as app until multi-window)
//!   panel   active while focus is inside a given node's subtree
//!   widget  active only while a given node itself has focus
//! When several bindings match, the most specific scope wins; between panels,
//! the deeper node wins; remaining ties go to the most recently added. A
//! binding whose command is disabled is skipped, so a less specific binding
//! can take over.
//!
//! Sequences: "ctrl+k ctrl+c" waits for the second chord (up to
//! `chord_timeout_ms`, cancelled by a focus change or `clearPending`). A second
//! key that completes nothing is swallowed, so a dead chord never types. A
//! sequence may not be a prefix of another binding in the same scope: `bind`
//! reports `Conflict` instead of making one unreachable. (Across scopes the
//! more specific one wins.)
//!
//! Bindings are data: built from text with `parseSequence`, loaded from a
//! keymap text, and removable, so users can remap them.

const std = @import("std");
const Handle = @import("handle.zig").Handle;
const Tree = @import("tree.zig").Tree;
const commands_mod = @import("commands.zig");
const Commands = commands_mod.Commands;
const keys = @import("keys.zig");
const Chord = keys.Chord;

pub const Scope = enum(u8) { app = 0, window, panel, widget };

pub const chord_timeout_ms: u64 = 1500;

pub const BindError = error{ InvalidSequence, UnknownCommand, Conflict, InvalidScope, OutOfMemory };

pub const Binding = struct {
    seq: [keys.max_sequence]Chord,
    len: u8,
    command: Handle,
    scope: Scope,
    /// The panel or widget node for those scopes; invalid otherwise.
    node: Handle,
    order: u32,

    fn sequence(self: *const Binding) []const Chord {
        return self.seq[0..self.len];
    }
};

/// What a key press did.
pub const Result = struct {
    /// The key was used: it ran a command, started a chord, or was swallowed
    /// by a dead chord. The caller should not process it further.
    consumed: bool = false,
    ran: bool = false,
};

pub const LoadReport = struct {
    bound: u32 = 0,
    unbound: u32 = 0,
    errors: u32 = 0,
    /// 1-based line of the first problem, or 0 if none.
    first_error_line: u32 = 0,
};

const Specificity = struct {
    rank: u8,
    depth: u32,

    fn gt(a: Specificity, b: Specificity) bool {
        return a.rank > b.rank or (a.rank == b.rank and a.depth > b.depth);
    }
};

fn seqEql(a: []const Chord, b: []const Chord) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (!x.eql(y)) return false;
    return true;
}

fn startsWith(seq: []const Chord, prefix: []const Chord) bool {
    if (prefix.len > seq.len) return false;
    return seqEql(seq[0..prefix.len], prefix);
}

pub const Shortcuts = struct {
    gpa: std.mem.Allocator,
    bindings: std.ArrayListUnmanaged(Binding) = .empty,
    next_order: u32 = 0,
    pending: [keys.max_sequence]Chord = undefined,
    pending_len: u8 = 0,
    pending_at: u64 = 0,
    pending_focus: Handle = Handle.invalid,

    pub fn init(gpa: std.mem.Allocator) Shortcuts {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Shortcuts) void {
        self.bindings.deinit(self.gpa);
        self.* = undefined;
    }

    pub fn count(self: *const Shortcuts) usize {
        return self.bindings.items.len;
    }

    pub fn hasPending(self: *const Shortcuts) bool {
        return self.pending_len > 0;
    }

    pub fn clearPending(self: *Shortcuts) void {
        self.pending_len = 0;
    }

    // ---- binding ------------------------------------------------------------

    /// Bind `seq` to `command`. Panel and widget scopes need `node`.
    pub fn bind(self: *Shortcuts, seq: []const Chord, command: Handle, scope: Scope, node: Handle) BindError!void {
        if (seq.len == 0 or seq.len > keys.max_sequence) return error.InvalidSequence;
        if ((scope == .panel or scope == .widget) and node.isNull()) return error.InvalidScope;
        const n = if (scope == .panel or scope == .widget) node else Handle.invalid;
        for (self.bindings.items) |b| {
            if (b.scope != scope or !Handle.eql(b.node, n)) continue;
            if (startsWith(b.sequence(), seq) or startsWith(seq, b.sequence())) return error.Conflict;
        }
        var entry: Binding = .{ .seq = undefined, .len = @intCast(seq.len), .command = command, .scope = scope, .node = n, .order = self.next_order };
        @memcpy(entry.seq[0..seq.len], seq);
        self.next_order += 1;
        try self.bindings.append(self.gpa, entry);
    }

    /// Like `bind`, but replaces an existing binding of exactly the same
    /// sequence in the same scope (the remapping case).
    pub fn rebind(self: *Shortcuts, seq: []const Chord, command: Handle, scope: Scope, node: Handle) BindError!void {
        _ = self.unbind(seq, scope, node);
        try self.bind(seq, command, scope, node);
    }

    /// Remove the binding with exactly this sequence in this scope.
    pub fn unbind(self: *Shortcuts, seq: []const Chord, scope: Scope, node: Handle) bool {
        const n = if (scope == .panel or scope == .widget) node else Handle.invalid;
        for (self.bindings.items, 0..) |b, i| {
            if (b.scope == scope and Handle.eql(b.node, n) and seqEql(b.sequence(), seq)) {
                _ = self.bindings.orderedRemove(i);
                return true;
            }
        }
        return false;
    }

    /// Remove every binding of `command`. Returns how many.
    pub fn unbindCommand(self: *Shortcuts, command: Handle) usize {
        var removed: usize = 0;
        var i: usize = 0;
        while (i < self.bindings.items.len) {
            if (Handle.eql(self.bindings.items[i].command, command)) {
                _ = self.bindings.orderedRemove(i);
                removed += 1;
            } else i += 1;
        }
        return removed;
    }

    /// Drop bindings whose command or scope node no longer exists.
    pub fn prune(self: *Shortcuts, tree: *Tree, cmds: *Commands) void {
        var i: usize = 0;
        while (i < self.bindings.items.len) {
            const b = self.bindings.items[i];
            const node_gone = (b.scope == .panel or b.scope == .widget) and !tree.isValid(b.node);
            if (node_gone or cmds.get(b.command) == null) {
                _ = self.bindings.orderedRemove(i);
            } else i += 1;
        }
    }

    // ---- display ------------------------------------------------------------

    /// The first shortcut bound to `command`, formatted ("Ctrl+K Ctrl+C").
    pub fn shortcutText(self: *const Shortcuts, command: Handle, buf: []u8) ?[]const u8 {
        for (self.bindings.items) |b| {
            if (!Handle.eql(b.command, command)) continue;
            var w: usize = 0;
            for (b.sequence(), 0..) |c, i| {
                if (i > 0 and w < buf.len) {
                    buf[w] = ' ';
                    w += 1;
                }
                const s = keys.formatChord(c, buf[w..]);
                w += s.len;
            }
            return buf[0..w];
        }
        return null;
    }

    // ---- matching -----------------------------------------------------------

    fn depthOf(tree: *Tree, h: Handle) u32 {
        var d: u32 = 0;
        var cur = h;
        while (tree.get(cur)) |n| : (cur = n.parent) d += 1;
        return d;
    }

    fn specificity(tree: *Tree, b: *const Binding, focus: Handle) ?Specificity {
        switch (b.scope) {
            .app => return .{ .rank = 0, .depth = 0 },
            .window => return .{ .rank = 1, .depth = 0 },
            .panel => {
                if (!tree.isValid(b.node)) return null;
                if (!(Handle.eql(b.node, focus) or tree.isAncestor(b.node, focus))) return null;
                return .{ .rank = 2, .depth = depthOf(tree, b.node) };
            },
            .widget => {
                if (!tree.isValid(b.node) or !Handle.eql(b.node, focus)) return null;
                return .{ .rank = 3, .depth = 0 };
            },
        }
    }

    /// Process a key press. `now_ms` drives the chord timeout. The focused node
    /// (or the root if nothing has focus) defines which scopes are active and is
    /// the target of the command event.
    pub fn handleKey(self: *Shortcuts, tree: *Tree, cmds: *Commands, now_ms: u64, chord: Chord, repeat: bool) Result {
        const focus = if (tree.isValid(tree.focused)) tree.focused else tree.root;

        if (self.pending_len > 0 and
            (now_ms -% self.pending_at > chord_timeout_ms or !Handle.eql(self.pending_focus, focus)))
        {
            self.pending_len = 0;
        }
        if (repeat and self.pending_len > 0) return .{ .consumed = true };

        var cand: [keys.max_sequence]Chord = undefined;
        @memcpy(cand[0..self.pending_len], self.pending[0..self.pending_len]);
        cand[self.pending_len] = chord;
        const cand_len: usize = self.pending_len + 1;
        const cand_seq = cand[0..cand_len];

        var exact: ?struct { spec: Specificity, order: u32, command: Handle } = null;
        var prefix_spec: ?Specificity = null;

        for (self.bindings.items) |*b| {
            if (b.len < cand_len or !startsWith(b.sequence(), cand_seq)) continue;
            const cmd = cmds.get(b.command) orelse continue;
            const spec = specificity(tree, b, focus) orelse continue;
            if (b.len == cand_len) {
                if (!cmd.enabled or (repeat and !cmd.repeat)) continue;
                const better = if (exact) |e| spec.gt(e.spec) or (!e.spec.gt(spec) and b.order > e.order) else true;
                if (better) exact = .{ .spec = spec, .order = b.order, .command = b.command };
            } else if (!repeat) {
                if (prefix_spec == null or spec.gt(prefix_spec.?)) prefix_spec = spec;
            }
        }

        const wait = if (prefix_spec) |ps| (exact == null or ps.gt(exact.?.spec)) else false;
        if (wait) {
            @memcpy(self.pending[0..cand_len], cand_seq);
            self.pending_len = @intCast(cand_len);
            self.pending_at = now_ms;
            self.pending_focus = focus;
            return .{ .consumed = true };
        }
        if (exact) |e| {
            self.pending_len = 0;
            const ran = cmds.invoke(e.command, focus);
            return .{ .consumed = ran, .ran = ran };
        }
        if (self.pending_len > 0) {
            // The sequence went nowhere: swallow this key so it cannot type.
            self.pending_len = 0;
            return .{ .consumed = true };
        }
        return .{};
    }

    // ---- keymap text --------------------------------------------------------

    /// Bind from text: `seq_text` like "ctrl+k ctrl+c", `command_name` looked up
    /// in `cmds`. `replace` overrides an existing binding of the same sequence.
    pub fn bindText(
        self: *Shortcuts,
        cmds: *Commands,
        seq_text: []const u8,
        command_name: []const u8,
        scope: Scope,
        node: Handle,
        replace: bool,
    ) BindError!void {
        var seq: [keys.max_sequence]Chord = undefined;
        const n = keys.parseSequence(seq_text, &seq) orelse return error.InvalidSequence;
        const cmd = cmds.find(command_name) orelse return error.UnknownCommand;
        if (replace) return self.rebind(seq[0..n], cmd, scope, node);
        return self.bind(seq[0..n], cmd, scope, node);
    }

    /// Load a keymap. One binding per line, `#` starts a comment:
    ///
    ///     ctrl+s = file.save
    ///     window: ctrl+k ctrl+c = edit.comment
    ///     ctrl+q = none            # unbind
    ///
    /// Lines override earlier bindings of the same sequence. Only app and
    /// window scopes can be written in text (panel and widget bindings need
    /// node handles). Bad lines are skipped and counted.
    pub fn loadKeymap(self: *Shortcuts, cmds: *Commands, text: []const u8) LoadReport {
        var report: LoadReport = .{};
        var line_no: u32 = 0;
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |raw| {
            line_no += 1;
            var line = raw;
            if (std.mem.indexOfScalar(u8, line, '#')) |i| line = line[0..i];
            line = std.mem.trim(u8, line, " \t\r");
            if (line.len == 0) continue;

            var scope: Scope = .app;
            if (std.ascii.startsWithIgnoreCase(line, "app:")) {
                line = std.mem.trim(u8, line[4..], " \t");
            } else if (std.ascii.startsWithIgnoreCase(line, "window:")) {
                scope = .window;
                line = std.mem.trim(u8, line[7..], " \t");
            }

            const eq = std.mem.indexOf(u8, line, " = ") orelse {
                report.errors += 1;
                if (report.first_error_line == 0) report.first_error_line = line_no;
                continue;
            };
            const seq_text = std.mem.trim(u8, line[0..eq], " \t");
            const target = std.mem.trim(u8, line[eq + 3 ..], " \t");

            var ok = true;
            if (std.mem.eql(u8, target, "none") or std.mem.eql(u8, target, "-")) {
                var seq: [keys.max_sequence]Chord = undefined;
                if (keys.parseSequence(seq_text, &seq)) |n| {
                    if (self.unbind(seq[0..n], scope, Handle.invalid)) report.unbound += 1;
                } else ok = false;
            } else if (self.bindText(cmds, seq_text, target, scope, Handle.invalid, true)) {
                report.bound += 1;
            } else |_| ok = false;

            if (!ok) {
                report.errors += 1;
                if (report.first_error_line == 0) report.first_error_line = line_no;
            }
        }
        return report;
    }
};

// ---- tests -----------------------------------------------------------------

const testing = std.testing;
const event = @import("event.zig");

const Log = struct {
    var buf: [64]u8 = undefined;
    var len: usize = 0;

    fn reset() void {
        len = 0;
    }

    fn str() []const u8 {
        return buf[0..len];
    }

    /// Handler that appends the first letter after the last dot of the command
    /// name (so "x.a" logs 'a'), making the order of runs easy to assert.
    fn handler(_: ?*anyopaque, ev: *event.Event) void {
        const name = ev.textSlice();
        if (len < buf.len) {
            buf[len] = name[name.len - 1];
            len += 1;
        }
    }
};

const Fixture = struct {
    tree: Tree,
    cmds: Commands,
    sc: Shortcuts,

    fn init() !Fixture {
        Log.reset();
        return .{
            .tree = try Tree.init(testing.allocator),
            .cmds = Commands.init(testing.allocator),
            .sc = Shortcuts.init(testing.allocator),
        };
    }

    fn deinit(self: *Fixture) void {
        self.sc.deinit();
        self.cmds.deinit();
        self.tree.deinit();
    }

    fn cmd(self: *Fixture, name: []const u8) !Handle {
        return self.cmds.register(name, name, .{ .call = Log.handler });
    }

    fn node(self: *Fixture, parent: Handle) !Handle {
        const h = try self.tree.create(.{ .flags = .{ .focusable = true } });
        try self.tree.appendChild(parent, h);
        return h;
    }

    fn key(self: *Fixture, text: []const u8) Result {
        return self.keyAt(text, 0);
    }

    fn keyAt(self: *Fixture, text: []const u8, now: u64) Result {
        return self.sc.handleKey(&self.tree, &self.cmds, now, keys.parseChord(text).?, false);
    }

    /// Parse a sequence into rotating static storage, so a few can be live at once.
    fn seq(text: []const u8) []const Chord {
        const S = struct {
            var ring: [8][keys.max_sequence]Chord = undefined;
            var next: usize = 0;
        };
        const slot = &S.ring[S.next % S.ring.len];
        S.next += 1;
        const n = keys.parseSequence(text, slot).?;
        return slot[0..n];
    }

    fn bind(self: *Fixture, text: []const u8, command: Handle, scope: Scope, node_: Handle) !void {
        var s: [keys.max_sequence]Chord = undefined;
        const n = keys.parseSequence(text, &s).?;
        try self.sc.bind(s[0..n], command, scope, node_);
    }
};

test "a bound chord runs its command; unbound keys are not consumed" {
    var f = try Fixture.init();
    defer f.deinit();
    const save = try f.cmd("file.s");
    try f.bind("ctrl+s", save, .app, Handle.invalid);

    const r = f.key("ctrl+s");
    try testing.expect(r.consumed and r.ran);
    try testing.expectEqualStrings("s", Log.str());
    try testing.expect(!f.key("ctrl+x").consumed);
    try testing.expect(!f.key("s").consumed); // modifiers must match exactly
    try testing.expect(!f.key("ctrl+shift+s").consumed);
}

test "the most specific scope wins: widget over panel over window over app" {
    var f = try Fixture.init();
    defer f.deinit();
    const panel = try f.node(f.tree.root);
    const widget = try f.node(panel);
    const a = try f.cmd("x.a");
    const w = try f.cmd("x.w");
    const p = try f.cmd("x.p");
    const wi = try f.cmd("x.i");
    try f.bind("f1", a, .app, Handle.invalid);
    try f.bind("f1", w, .window, Handle.invalid);
    try f.bind("f1", p, .panel, panel);
    try f.bind("f1", wi, .widget, widget);

    f.tree.focused = widget;
    _ = f.key("f1");
    f.tree.focused = panel; // the widget binding no longer applies
    _ = f.key("f1");
    f.tree.focused = f.tree.root; // outside the panel
    _ = f.key("f1");
    try testing.expectEqualStrings("ipw", Log.str());

    // Without window scope the app binding takes over.
    _ = f.sc.unbind(Fixture.seq("f1"), .window, Handle.invalid);
    Log.reset();
    _ = f.key("f1");
    try testing.expectEqualStrings("a", Log.str());
}

test "nested panels: the deeper one wins; panel scope covers the whole subtree" {
    var f = try Fixture.init();
    defer f.deinit();
    const outer = try f.node(f.tree.root);
    const inner = try f.node(outer);
    const leaf = try f.node(inner);
    const o = try f.cmd("x.o");
    const i = try f.cmd("x.i");
    try f.bind("f2", o, .panel, outer);
    try f.bind("f2", i, .panel, inner);

    f.tree.focused = leaf;
    _ = f.key("f2");
    f.tree.focused = outer;
    _ = f.key("f2");
    try testing.expectEqualStrings("io", Log.str());
}

test "no focus means only root-level scopes are active" {
    var f = try Fixture.init();
    defer f.deinit();
    const panel = try f.node(f.tree.root);
    const a = try f.cmd("x.a");
    const p = try f.cmd("x.p");
    try f.bind("f3", a, .app, Handle.invalid);
    try f.bind("f3", p, .panel, panel);
    _ = f.key("f3"); // nothing focused: the panel is not active
    try testing.expectEqualStrings("a", Log.str());
}

test "a disabled command is skipped so a less specific binding can take over" {
    var f = try Fixture.init();
    defer f.deinit();
    const panel = try f.node(f.tree.root);
    const a = try f.cmd("x.a");
    const p = try f.cmd("x.p");
    try f.bind("f4", a, .app, Handle.invalid);
    try f.bind("f4", p, .panel, panel);
    f.tree.focused = panel;
    f.cmds.setEnabled(p, false);
    _ = f.key("f4");
    try testing.expectEqualStrings("a", Log.str());
    f.cmds.setEnabled(a, false);
    try testing.expect(!f.key("f4").consumed); // nothing enabled: the key passes through
}

test "later bindings win ties across different nodes" {
    var f = try Fixture.init();
    defer f.deinit();
    const a = try f.cmd("x.a");
    const b = try f.cmd("x.b");
    try f.bind("f5", a, .app, Handle.invalid);
    try testing.expectError(error.Conflict, f.sc.bind(Fixture.seq("f5"), b, .app, Handle.invalid));
    try f.sc.rebind(Fixture.seq("f5"), b, .app, Handle.invalid); // remap
    _ = f.key("f5");
    try testing.expectEqualStrings("b", Log.str());
    try testing.expectEqual(@as(usize, 1), f.sc.count());
}

test "two-key chords wait, complete, and are cancelled by timeout or focus change" {
    var f = try Fixture.init();
    defer f.deinit();
    const c = try f.cmd("edit.c");
    const u = try f.cmd("edit.u");
    try f.bind("ctrl+k ctrl+c", c, .app, Handle.invalid);
    try f.bind("ctrl+k ctrl+u", u, .app, Handle.invalid);

    var r = f.keyAt("ctrl+k", 100);
    try testing.expect(r.consumed and !r.ran);
    try testing.expect(f.sc.hasPending());
    r = f.keyAt("ctrl+c", 200);
    try testing.expect(r.ran);
    try testing.expect(!f.sc.hasPending());
    r = f.keyAt("ctrl+k", 300);
    r = f.keyAt("ctrl+u", 400);
    try testing.expectEqualStrings("cu", Log.str());

    // Timeout: the second chord arrives too late and starts over (and matches nothing alone).
    Log.reset();
    _ = f.keyAt("ctrl+k", 1000);
    r = f.keyAt("ctrl+c", 1000 + chord_timeout_ms + 1);
    try testing.expect(!r.consumed);
    try testing.expectEqualStrings("", Log.str());

    // A focus change cancels a pending chord.
    const other = try f.node(f.tree.root);
    _ = f.keyAt("ctrl+k", 5000);
    f.tree.focused = other;
    r = f.keyAt("ctrl+c", 5001);
    try testing.expect(!r.consumed);
    try testing.expectEqualStrings("", Log.str());
}

test "a dead chord swallows the second key" {
    var f = try Fixture.init();
    defer f.deinit();
    const c = try f.cmd("edit.c");
    const plain = try f.cmd("edit.p");
    try f.bind("ctrl+k ctrl+c", c, .app, Handle.invalid);
    try f.bind("x", plain, .app, Handle.invalid);

    _ = f.key("ctrl+k");
    const r = f.key("x"); // not a continuation: swallowed, and does not run "x"
    try testing.expect(r.consumed and !r.ran);
    try testing.expectEqualStrings("", Log.str());
    try testing.expect(f.key("x").ran); // pending is cleared: normal again
    try testing.expectEqualStrings("p", Log.str());
}

test "prefix conflicts are rejected within a scope but allowed across scopes" {
    var f = try Fixture.init();
    defer f.deinit();
    const panel = try f.node(f.tree.root);
    const a = try f.cmd("x.a");
    const b = try f.cmd("x.b");
    const c = try f.cmd("x.c");
    try f.bind("ctrl+k", a, .app, Handle.invalid);
    try testing.expectError(error.Conflict, f.sc.bind(Fixture.seq("ctrl+k ctrl+c"), b, .app, Handle.invalid));
    // In a more specific scope the longer chord is allowed and wins when focus is in the panel.
    try f.sc.bind(Fixture.seq("ctrl+k ctrl+c"), c, .panel, panel);

    _ = f.key("ctrl+k"); // focus at root: app binding runs right away
    try testing.expectEqualStrings("a", Log.str());
    f.tree.focused = panel;
    _ = f.key("ctrl+k"); // in the panel the chord is the more specific, so it waits
    try testing.expect(f.sc.hasPending());
    _ = f.key("ctrl+c");
    try testing.expectEqualStrings("ac", Log.str());
}

test "auto-repeat only re-runs commands marked repeatable" {
    var f = try Fixture.init();
    defer f.deinit();
    const nav = try f.cmd("nav.n");
    const save = try f.cmd("file.s");
    f.cmds.get(nav).?.repeat = true;
    try f.bind("down", nav, .app, Handle.invalid);
    try f.bind("ctrl+s", save, .app, Handle.invalid);

    const down = keys.parseChord("down").?;
    const ctrl_s = keys.parseChord("ctrl+s").?;
    _ = f.sc.handleKey(&f.tree, &f.cmds, 0, down, false);
    _ = f.sc.handleKey(&f.tree, &f.cmds, 0, down, true);
    _ = f.sc.handleKey(&f.tree, &f.cmds, 0, ctrl_s, false);
    const r = f.sc.handleKey(&f.tree, &f.cmds, 0, ctrl_s, true);
    try testing.expect(!r.consumed);
    try testing.expectEqualStrings("nns", Log.str());
}

test "unbind, unbindCommand, and prune" {
    var f = try Fixture.init();
    defer f.deinit();
    const panel = try f.node(f.tree.root);
    const a = try f.cmd("x.a");
    const b = try f.cmd("x.b");
    try f.bind("f6", a, .app, Handle.invalid);
    try f.bind("f7", a, .app, Handle.invalid);
    try f.bind("f8", b, .panel, panel);
    try testing.expect(f.sc.unbind(Fixture.seq("f6"), .app, Handle.invalid));
    try testing.expect(!f.sc.unbind(Fixture.seq("f6"), .app, Handle.invalid));
    try testing.expectEqual(@as(usize, 1), f.sc.unbindCommand(a));
    try testing.expectEqual(@as(usize, 1), f.sc.count());

    _ = f.tree.destroySubtree(panel); // its panel binding is now dead weight
    f.sc.prune(&f.tree, &f.cmds);
    try testing.expectEqual(@as(usize, 0), f.sc.count());

    try f.bind("f9", b, .app, Handle.invalid);
    _ = f.cmds.unregister(b);
    f.sc.prune(&f.tree, &f.cmds);
    try testing.expectEqual(@as(usize, 0), f.sc.count());
}

test "bindings to an unregistered command are inert" {
    var f = try Fixture.init();
    defer f.deinit();
    const a = try f.cmd("x.a");
    try f.bind("f10", a, .app, Handle.invalid);
    _ = f.cmds.unregister(a);
    try testing.expect(!f.key("f10").consumed);
}

test "scope errors: panel and widget need a node" {
    var f = try Fixture.init();
    defer f.deinit();
    const a = try f.cmd("x.a");
    try testing.expectError(error.InvalidScope, f.sc.bind(Fixture.seq("f1"), a, .panel, Handle.invalid));
    try testing.expectError(error.InvalidScope, f.sc.bind(Fixture.seq("f1"), a, .widget, Handle.invalid));
    try testing.expectError(error.InvalidSequence, f.sc.bind(&.{}, a, .app, Handle.invalid));
}

test "shortcut text for display" {
    var f = try Fixture.init();
    defer f.deinit();
    const a = try f.cmd("x.a");
    const b = try f.cmd("x.b");
    try f.bind("ctrl+shift+p", a, .app, Handle.invalid);
    var buf: [48]u8 = undefined;
    try testing.expectEqualStrings("Ctrl+Shift+P", f.sc.shortcutText(a, &buf).?);
    try testing.expect(f.sc.shortcutText(b, &buf) == null);
    try f.bind("ctrl+k ctrl+c", b, .app, Handle.invalid);
    try testing.expectEqualStrings("Ctrl+K Ctrl+C", f.sc.shortcutText(b, &buf).?);
}

test "keymap text: bind, override, unbind, comments, scopes, and error reporting" {
    var f = try Fixture.init();
    defer f.deinit();
    const a = try f.cmd("x.a");
    const b = try f.cmd("x.b");
    _ = b;
    try f.bind("ctrl+q", a, .app, Handle.invalid);

    const report = f.sc.loadKeymap(&f.cmds,
        \\# defaults
        \\ctrl+s = x.a            # trailing comment
        \\window: ctrl+k ctrl+c = x.b
        \\ctrl+q = none
        \\ctrl+= = x.b
        \\
        \\ctrl+z = x.missing
        \\bogus+key = x.a
        \\just text
        \\
    );
    try testing.expectEqual(@as(u32, 3), report.bound); // ctrl+s, ctrl+k ctrl+c, ctrl+=
    try testing.expectEqual(@as(u32, 1), report.unbound);
    try testing.expectEqual(@as(u32, 3), report.errors);
    try testing.expectEqual(@as(u32, 7), report.first_error_line);

    try testing.expect(f.key("ctrl+s").ran);
    try testing.expect(!f.key("ctrl+q").consumed);
    try testing.expect(f.key("ctrl+=").ran);
    _ = f.key("ctrl+k");
    try testing.expect(f.key("ctrl+c").ran);
    try testing.expectEqualStrings("abb", Log.str());

    // Later lines override earlier bindings of the same sequence.
    const again = f.sc.loadKeymap(&f.cmds, "ctrl+s = x.b\n");
    try testing.expectEqual(@as(u32, 1), again.bound);
    Log.reset();
    _ = f.key("ctrl+s");
    try testing.expectEqualStrings("b", Log.str());
}
