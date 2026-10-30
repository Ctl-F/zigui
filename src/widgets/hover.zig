//! Hover and signature help for a `CodeEditor`: the two small overlays that
//! explain the code under the pointer or around the caret.
//!
//! **Hover**: rest the pointer on an identifier for a moment and a tooltip
//! shows what providers know about it (a declaration, its doc comment).
//!
//! **Signature help**: while the caret is inside the parentheses of a call
//! (`@Vector(4, `), a tip above the line shows the callee's parameter list with
//! the parameter being typed emphasized. It opens when you type `(` or `,`,
//! follows the caret, and closes when the caret leaves the call (Escape closes it too).
//!
//!     const hover = try Hover.create(&ui);
//!     try hover.addProvider(.bind(&index, Index.hover));
//!     try hover.attach(editor);
//!     const sig = try SignatureHelp.create(&ui);
//!     try sig.addProvider(.bind(&index, Index.signature));
//!     try sig.attach(editor);
//!
//! Providers answer from what they already know (an index, a language server's
//! cached reply): they run on the UI thread. Both overlays use `Ui.tip`, which
//! is separate from the completion list, so the two can show at once. Detach
//! an editor (or destroy the controller) before destroying the editor.

const std = @import("std");
const Ui = @import("../core/ui.zig").Ui;
const TimerId = @import("../core/ui.zig").TimerId;
const event = @import("../core/event.zig");
const CodeEditor = @import("code_editor.zig").CodeEditor;

const max_providers = 8;
const wrap_cols = 88;

/// Where a hover provider writes lines of text. Lines longer than 88 columns
/// are wrapped at spaces; strings are copied.
pub const Lines = struct {
    arena: std.mem.Allocator,
    list: *std.ArrayListUnmanaged([]const u8),

    pub fn add(self: *Lines, text: []const u8) void {
        var rest = text;
        while (rest.len > wrap_cols) {
            const cut = std.mem.lastIndexOfScalar(u8, rest[0..wrap_cols], ' ') orelse wrap_cols;
            self.push(rest[0..cut]);
            rest = std.mem.trimStart(u8, rest[cut..], " ");
        }
        self.push(rest);
    }

    fn push(self: *Lines, text: []const u8) void {
        const copy = self.arena.dupe(u8, text) catch return;
        self.list.append(self.arena, copy) catch {};
    }
};

pub const HoverRequest = struct {
    editor: *CodeEditor,
    /// The identifier under the pointer (with a leading `@` if it has one).
    word: []const u8,
    /// Byte offset of its start.
    word_start: usize,
    /// The line's text before the word (to see `std.mem.` in `std.mem.eql`).
    line_before: []const u8,
};

pub const HoverProvider = struct {
    ctx: ?*anyopaque = null,
    hover: *const fn (ctx: ?*anyopaque, req: *const HoverRequest, out: *Lines) void,

    pub fn bind(ctx: anytype, comptime f: anytype) HoverProvider {
        const Ptr = @TypeOf(ctx);
        return .{
            .ctx = @ptrCast(ctx),
            .hover = &struct {
                fn thunk(c: ?*anyopaque, req: *const HoverRequest, out: *Lines) void {
                    f(@as(Ptr, @ptrCast(@alignCast(c.?))), req, out);
                }
            }.thunk,
        };
    }
};

fn editorOf(list: []const *CodeEditor, ev: *event.Event) ?*CodeEditor {
    for (list) |ed| {
        if (ed.node.eql(ev.current) or ed.node.eql(ev.target)) return ed;
    }
    return null;
}

pub const Hover = struct {
    gpa: std.mem.Allocator,
    ui: *Ui,
    providers: [max_providers]HoverProvider = undefined,
    provider_n: usize = 0,
    /// How long the pointer rests on a word before the tooltip shows.
    delay_ms: u64 = 450,
    attached: std.ArrayListUnmanaged(*CodeEditor) = .empty,
    /// The word the pointer rests on (document offsets) in `editor`.
    editor: ?*CodeEditor = null,
    word: ?CodeEditor.WordRange = null,
    timer: ?TimerId = null,
    showing: bool = false,
    arena: std.heap.ArenaAllocator,

    pub fn create(ui: *Ui) !*Hover {
        const self = try ui.gpa.create(Hover);
        self.* = .{ .gpa = ui.gpa, .ui = ui, .arena = std.heap.ArenaAllocator.init(ui.gpa) };
        return self;
    }

    pub fn destroy(self: *Hover) void {
        self.hide();
        for (self.attached.items) |ed| ed.removeHooks(self);
        self.attached.deinit(self.gpa);
        self.arena.deinit();
        self.gpa.destroy(self);
    }

    pub fn addProvider(self: *Hover, p: HoverProvider) !void {
        if (self.provider_n == max_providers) return error.TooManyProviders;
        self.providers[self.provider_n] = p;
        self.provider_n += 1;
    }

    pub fn attach(self: *Hover, ed: *CodeEditor) !void {
        try self.attached.append(self.gpa, ed);
        const tree = &ed.ui.tree;
        try tree.addListener(ed.node, .{ .kind = .pointer_move, .callback = event.Callback.bind(self, onMove) });
        inline for (.{ .pointer_leave, .pointer_down, .wheel, .focus_out, .key_down }) |k| {
            try tree.addListener(ed.node, .{ .kind = k, .callback = event.Callback.bind(self, onHide) });
        }
    }

    pub fn detach(self: *Hover, ed: *CodeEditor) void {
        if (self.editor == ed) self.hide();
        if (std.mem.indexOfScalar(*CodeEditor, self.attached.items, ed)) |i| _ = self.attached.swapRemove(i);
        ed.removeHooks(self);
    }

    /// Cancel a pending tooltip and close a shown one.
    pub fn hide(self: *Hover) void {
        if (self.timer) |t| self.ui.cancelTimer(t);
        self.timer = null;
        if (self.showing) self.ui.hideTip();
        self.showing = false;
        self.word = null;
        self.editor = null;
    }

    fn onHide(self: *Hover, _: *event.Event) void {
        self.hide();
    }

    fn onMove(self: *Hover, ev: *event.Event) void {
        const ed = editorOf(self.attached.items, ev) orelse return;
        const w = ed.wordAtPoint(ev.local_x, ev.local_y) orelse return self.hide();
        if (self.editor == ed) {
            if (self.word) |cur| if (cur.start == w.start and cur.end == w.end) return; // still on it
        }
        self.hide();
        self.editor = ed;
        self.word = w;
        self.timer = self.ui.setTimer(self.delay_ms, event.Callback.bind(self, onTimer)) catch null;
    }

    fn onTimer(self: *Hover, _: *event.Event) void {
        self.timer = null;
        const ed = self.editor orelse return;
        const w = self.word orelse return;
        // A list or hint that is already showing has priority.
        if (self.ui.popupOpen() or self.ui.tipOpen()) return;
        const doc = &ed.core().doc;
        if (w.end > doc.len()) return;
        _ = self.arena.reset(.retain_capacity);
        const a = self.arena.allocator();
        const word = a.dupe(u8, doc.range(w.start, w.end) catch return) catch return;
        const ls = doc.lineStart(doc.lineOfOffset(w.start));
        const before = a.dupe(u8, doc.range(ls, w.start) catch return) catch return;
        const req: HoverRequest = .{ .editor = ed, .word = word, .word_start = w.start, .line_before = before };
        var lines: std.ArrayListUnmanaged([]const u8) = .empty;
        var sink: Lines = .{ .arena = a, .list = &lines };
        for (self.providers[0..self.provider_n]) |p| p.hover(p.ctx, &req, &sink);
        if (lines.items.len == 0) return;
        self.show(ed, w, lines.items);
    }

    fn show(self: *Hover, ed: *CodeEditor, w: CodeEditor.WordRange, lines: []const []const u8) void {
        const a = self.arena.allocator();
        const text = std.mem.join(a, "\n", lines) catch return;
        var anchor = ed.rectOfOffset(w.start) orelse return;
        if (ed.rectOfOffset(w.end)) |e| anchor.w = @max(e.x - anchor.x, 1);
        self.ui.showTip(text, anchor) catch return;
        self.showing = true;
    }

    /// A late answer (from a language server) for the word that starts at
    /// `word_start` in `ed`: shown if the pointer still rests on that word and
    /// nothing else is showing. `text` is split into lines and wrapped.
    pub fn offer(self: *Hover, ed: *CodeEditor, word_start: usize, text: []const u8) void {
        const w = self.word orelse return;
        if (self.editor != ed or w.start != word_start or self.showing or self.timer != null) return;
        if (self.ui.popupOpen() or self.ui.tipOpen()) return;
        _ = self.arena.reset(.retain_capacity);
        const a = self.arena.allocator();
        var lines: std.ArrayListUnmanaged([]const u8) = .empty;
        var sink: Lines = .{ .arena = a, .list = &lines };
        var it = std.mem.splitScalar(u8, text, '\n');
        while (it.next()) |l| sink.add(l);
        if (lines.items.len == 0) return;
        self.show(ed, w, lines.items);
    }
};

// ---- signature help --------------------------------------------------------

/// What a signature provider is asked.
pub const SigRequest = struct {
    editor: *CodeEditor,
    /// The called expression: `@Vector`, `std.mem.eql`, `foo`.
    callee: []const u8,
    /// Index of the argument the caret is in (0-based).
    active: usize,
};

/// Where a signature provider puts its answer.
pub const SigSink = struct {
    arena: std.mem.Allocator,
    text: []const u8 = "",
    params: []const [2]usize = &.{},
    set_flag: bool = false,
    /// The provider will answer later through `SignatureHelp.offer`.
    later: bool = false,

    /// Say the answer will come later (`SignatureHelp.offer`); a hint already showing stays until then.
    pub fn deferToOffer(self: *SigSink) void {
        self.later = true;
    }

    /// `text` is the whole signature (`@Vector(len: comptime_int, Element: type) type`);
    /// `params` are the byte ranges of each parameter within it.
    pub fn set(self: *SigSink, text: []const u8, params: []const [2]usize) void {
        self.text = self.arena.dupe(u8, text) catch return;
        self.params = self.arena.dupe([2]usize, params) catch &.{};
        self.set_flag = true;
    }
};

pub const SigProvider = struct {
    ctx: ?*anyopaque = null,
    signature: *const fn (ctx: ?*anyopaque, req: *const SigRequest, out: *SigSink) void,

    pub fn bind(ctx: anytype, comptime f: anytype) SigProvider {
        const Ptr = @TypeOf(ctx);
        return .{
            .ctx = @ptrCast(ctx),
            .signature = &struct {
                fn thunk(c: ?*anyopaque, req: *const SigRequest, out: *SigSink) void {
                    f(@as(Ptr, @ptrCast(@alignCast(c.?))), req, out);
                }
            }.thunk,
        };
    }
};

pub const Call = struct { callee: []const u8, active: usize };

/// The call whose parentheses surround the end of `before` (the text up to the
/// caret): its callee and the index of the argument being typed. Parentheses
/// of `if (`, `while (`, grouping and `fn name(` declarations do not count.
pub fn enclosingCall(before: []const u8) ?Call {
    const limit = 4000;
    const text = if (before.len > limit) before[before.len - limit ..] else before;
    var depth: usize = 0;
    var commas: usize = 0;
    var i = text.len;
    while (i > 0) {
        i -= 1;
        switch (text[i]) {
            ')', ']', '}' => depth += 1,
            '[', '{' => if (depth == 0) {
                commas = 0; // inside an array or block literal: those commas are not ours
            } else {
                depth -= 1;
            },
            ',' => if (depth == 0) {
                commas += 1;
            },
            '(' => {
                if (depth > 0) {
                    depth -= 1;
                    continue;
                }
                var s = i;
                while (s > 0 and (std.ascii.isAlphanumeric(text[s - 1]) or text[s - 1] == '_' or text[s - 1] == '.' or text[s - 1] == '@')) s -= 1;
                const callee = text[s..i];
                const keyword = callee.len == 0 or isKeyword(callee) or std.mem.endsWith(u8, std.mem.trimEnd(u8, text[0..s], " "), "fn");
                if (!keyword) return .{ .callee = callee, .active = commas };
                commas = 0; // not a call: keep looking outward
            },
            '\n' => {},
            else => {},
        }
    }
    return null;
}

fn isKeyword(w: []const u8) bool {
    const kws = [_][]const u8{ "if", "while", "for", "switch", "catch", "orelse", "and", "or", "return", "try", "defer", "errdefer", "comptime" };
    for (kws) |k| if (std.mem.eql(u8, k, w)) return true;
    return false;
}

pub const SignatureHelp = struct {
    gpa: std.mem.Allocator,
    ui: *Ui,
    providers: [max_providers]SigProvider = undefined,
    provider_n: usize = 0,
    attached: std.ArrayListUnmanaged(*CodeEditor) = .empty,
    /// The editor whose hint is showing.
    editor: ?*CodeEditor = null,
    showing: bool = false,
    /// Editor to refresh after a navigation key has moved the caret.
    pending: ?*CodeEditor = null,
    arena: std.heap.ArenaAllocator,

    pub fn create(ui: *Ui) !*SignatureHelp {
        const self = try ui.gpa.create(SignatureHelp);
        self.* = .{ .gpa = ui.gpa, .ui = ui, .arena = std.heap.ArenaAllocator.init(ui.gpa) };
        return self;
    }

    pub fn destroy(self: *SignatureHelp) void {
        self.hide();
        for (self.attached.items) |ed| ed.removeHooks(self);
        self.attached.deinit(self.gpa);
        self.arena.deinit();
        self.gpa.destroy(self);
    }

    pub fn addProvider(self: *SignatureHelp, p: SigProvider) !void {
        if (self.provider_n == max_providers) return error.TooManyProviders;
        self.providers[self.provider_n] = p;
        self.provider_n += 1;
    }

    pub fn attach(self: *SignatureHelp, ed: *CodeEditor) !void {
        try self.attached.append(self.gpa, ed);
        try ed.addKeyHook(event.Callback.bind(self, onKey));
        try ed.addEditHook(event.Callback.bind(self, onEdit));
        try ed.ui.tree.addListener(ed.node, .{ .kind = .focus_out, .callback = event.Callback.bind(self, onBlur) });
    }

    pub fn detach(self: *SignatureHelp, ed: *CodeEditor) void {
        if (self.editor == ed) self.hide();
        if (self.pending == ed) self.pending = null;
        if (std.mem.indexOfScalar(*CodeEditor, self.attached.items, ed)) |i| _ = self.attached.swapRemove(i);
        ed.removeHooks(self);
    }

    pub fn hide(self: *SignatureHelp) void {
        if (self.showing) self.ui.hideTip();
        self.showing = false;
        self.editor = null;
    }

    fn onBlur(self: *SignatureHelp, _: *event.Event) void {
        self.hide();
    }

    fn onKey(self: *SignatureHelp, ev: *event.Event) void {
        const ed = editorOf(self.attached.items, ev) orelse return;
        if (!self.showing) return;
        switch (ev.key) {
            .escape => self.hide(),
            // The caret moves after this hook runs: look again a moment later.
            .left, .right, .up, .down, .home, .end, .page_up, .page_down, .backspace, .delete => {
                self.pending = ed;
                _ = self.ui.setTimer(1, event.Callback.bind(self, onLater)) catch {};
            },
            else => {},
        }
    }

    fn onLater(self: *SignatureHelp, _: *event.Event) void {
        const ed = self.pending orelse return;
        self.pending = null;
        self.refresh(ed);
    }

    fn onEdit(self: *SignatureHelp, ev: *event.Event) void {
        const ed = editorOf(self.attached.items, ev) orelse return;
        // Typed (or pasted) text may open or move the hint; other edits only update a shown one.
        if (ev.kind == .text_input or self.showing) self.refresh(ed);
    }

    /// Recompute the hint for `ed`'s caret.
    pub fn refresh(self: *SignatureHelp, ed: *CodeEditor) void {
        const core = ed.core();
        const doc = &core.doc;
        const head = core.primaryHead();
        const from = head -| 4000;
        const before = doc.range(from, head) catch return self.hide();
        const call = enclosingCall(before) orelse return self.hide();
        _ = self.arena.reset(.retain_capacity);
        const a = self.arena.allocator();
        const req: SigRequest = .{ .editor = ed, .callee = a.dupe(u8, call.callee) catch return, .active = call.active };
        var sink: SigSink = .{ .arena = a };
        for (self.providers[0..self.provider_n]) |p| {
            p.signature(p.ctx, &req, &sink);
            if (sink.set_flag) break;
        }
        if (!sink.set_flag) {
            // A provider may answer later through `offer`: leave a shown hint alone.
            if (!sink.later) self.hide();
            return;
        }
        self.show(ed, head, sink.text, sink.params, call.active);
    }

    /// A late answer (from a language server) for a call to `callee` that the
    /// caret is still inside: shown as if a provider had answered at once.
    pub fn offer(self: *SignatureHelp, ed: *CodeEditor, callee: []const u8, text: []const u8, params: []const [2]usize, active: usize) void {
        const core = ed.core();
        const doc = &core.doc;
        const head = core.primaryHead();
        const before = doc.range(head -| 4000, head) catch return;
        const call = enclosingCall(before) orelse return;
        if (!std.mem.eql(u8, call.callee, callee)) return;
        _ = self.arena.reset(.retain_capacity);
        const a = self.arena.allocator();
        self.show(ed, head, a.dupe(u8, text) catch return, a.dupe([2]usize, params) catch return, active);
    }

    fn show(self: *SignatureHelp, ed: *CodeEditor, head: usize, text: []const u8, params: []const [2]usize, active: usize) void {
        const doc = &ed.core().doc;
        var ms: usize = 0;
        var me: usize = 0;
        if (params.len > 0) {
            const p = params[@min(active, params.len - 1)];
            ms = p[0];
            me = p[1];
        }
        const caret = ed.caretRect() orelse return self.hide();
        const line_start = doc.lineStart(doc.lineOfOffset(head));
        const left = ed.rectOfOffset(line_start) orelse caret;
        const anchor: @TypeOf(caret) = .{ .x = left.x, .y = caret.y, .w = 1, .h = caret.h };
        self.ui.showTipOpts(text, anchor, .{ .above = true, .mark_start = ms, .mark_end = me }) catch return self.hide();
        self.showing = true;
        self.editor = ed;
    }
};

// ---- tests -----------------------------------------------------------------

const testing = std.testing;
const Rig = @import("../core/test_rig.zig").Rig;

test "enclosingCall finds the callee and the argument index" {
    const a = enclosingCall("const v = @Vector(4, ").?;
    try testing.expectEqualStrings("@Vector", a.callee);
    try testing.expectEqual(@as(usize, 1), a.active);
    const b = enclosingCall("std.mem.eql(u8, foo(1, 2), ").?;
    try testing.expectEqualStrings("std.mem.eql", b.callee);
    try testing.expectEqual(@as(usize, 2), b.active);
    const c = enclosingCall("f(a, g(").?;
    try testing.expectEqualStrings("g", c.callee);
    try testing.expectEqual(@as(usize, 0), c.active);
    // Keywords, grouping and declarations are skipped in favor of the real call.
    const d = enclosingCall("outer(1, if (x").?;
    try testing.expectEqualStrings("outer", d.callee);
    try testing.expectEqual(@as(usize, 1), d.active);
    const e = enclosingCall("call(a, (b + ").?;
    try testing.expectEqualStrings("call", e.callee);
    try testing.expect(enclosingCall("pub fn name(a: u8, ") == null);
    // Commas inside an array literal belong to the literal.
    const f = enclosingCall("call(x, .{ 1, 2, ").?;
    try testing.expectEqual(@as(usize, 1), f.active);
    try testing.expect(enclosingCall("no call here") == null);
    try testing.expect(enclosingCall("done(1, 2) + ") == null);
    // Across lines.
    const g = enclosingCall("foo(\n    a,\n    ").?;
    try testing.expectEqualStrings("foo", g.callee);
    try testing.expectEqual(@as(usize, 1), g.active);
}

const FakeHover = struct {
    seen: usize = 0,
    fn hover(self: *FakeHover, req: *const HoverRequest, out: *Lines) void {
        self.seen += 1;
        if (!std.mem.eql(u8, req.word, "target")) return;
        out.add("fn target(a: u8) void");
        out.add("Does the thing.");
    }
};

test "resting on a word shows a tooltip; moving away hides it" {
    const r = try Rig.init();
    defer r.deinit();
    const ed = try r.ui.add(CodeEditor, r.ui.tree.root, .{ .style = .{ .grow = 1 }, .label = "t" });
    try ed.loadText(try r.ui.gpa.dupe(u8, "call(target, other)\n"), true);
    try r.frame();
    const hv = try Hover.create(&r.ui);
    defer hv.destroy();
    var fake: FakeHover = .{};
    try hv.addProvider(.bind(&fake, FakeHover.hover));
    try hv.attach(ed);
    defer hv.detach(ed);

    const rect = ed.rectOfOffset(7).?; // inside "target"
    _ = r.ui.tick(1000);
    r.ui.pointerMove(rect.x + 2, rect.y + 5);
    try testing.expect(!r.ui.tipOpen()); // not yet
    _ = r.ui.tick(1200);
    try testing.expect(!r.ui.tipOpen());
    _ = r.ui.tick(1500);
    try r.frame();
    try testing.expect(r.ui.tipOpen());
    try testing.expectEqual(@as(usize, 2), r.ui.tip.?.count());
    try testing.expectEqualStrings("fn target(a: u8) void", r.ui.tip.?.entries[0].row.label);

    // Move onto another word: the tip closes, and a new wait starts (nothing to show there).
    const other = ed.rectOfOffset(15).?;
    r.ui.pointerMove(other.x + 2, other.y + 5);
    try testing.expect(!r.ui.tipOpen());
    _ = r.ui.tick(2200);
    try testing.expect(!r.ui.tipOpen());
    // Past the end of the line: no word.
    r.ui.pointerMove(700, other.y + 5);
    _ = r.ui.tick(3000);
    try testing.expect(!r.ui.tipOpen());
}

const FakeSig = struct {
    fn sig(_: *FakeSig, req: *const SigRequest, out: *SigSink) void {
        if (!std.mem.eql(u8, req.callee, "@Vector")) return;
        const text = "@Vector(len: comptime_int, Element: type) type";
        out.set(text, &.{ .{ 8, 25 }, .{ 27, 39 } });
    }
};

test "signature help follows the caret through a call" {
    const r = try Rig.init();
    defer r.deinit();
    const ed = try r.ui.add(CodeEditor, r.ui.tree.root, .{ .style = .{ .grow = 1 }, .label = "t" });
    try ed.loadText(try r.ui.gpa.dupe(u8, ""), true);
    r.ui.setFocus(ed.node);
    try r.frame();
    const sh = try SignatureHelp.create(&r.ui);
    defer sh.destroy();
    var fake: FakeSig = .{};
    try sh.addProvider(.bind(&fake, FakeSig.sig));
    try sh.attach(ed);
    defer sh.detach(ed);

    r.ui.textInput("const V = @Vector(");
    try r.frame();
    try testing.expect(r.ui.tipOpen());
    try testing.expectEqualStrings("@Vector(len: comptime_int, Element: type) type", r.ui.tip.?.entries[0].row.label);
    r.ui.textInput("4, ");
    try r.frame();
    try testing.expect(r.ui.tipOpen());
    r.ui.textInput("f32)");
    try r.frame();
    try testing.expect(!r.ui.tipOpen()); // the call is closed
    // Escape closes it too.
    r.ui.textInput("\nconst W = @Vector(");
    try r.frame();
    try testing.expect(r.ui.tipOpen());
    r.ui.key(.escape, .{}, true, false);
    try testing.expect(!r.ui.tipOpen());
    // Unknown callees show nothing.
    r.ui.textInput("1, 2)\nunknown(");
    try r.frame();
    try testing.expect(!r.ui.tipOpen());
}
