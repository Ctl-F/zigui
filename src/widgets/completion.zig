//! Completion: a suggestion list that follows typing in a `CodeEditor`.
//!
//! A `Completion` watches the editors attached to it. When you type an
//! identifier (two letters by default), type `.`, or press Ctrl+Space, it asks
//! its providers for candidates, ranks them against the word before the caret,
//! and shows them in a focus-less popup (`Ui.showPopup`). Up/Down/PageUp/PageDown
//! move, Enter or Tab inserts, Escape closes; typing on narrows the list and
//! moving the caret away, clicking, or leaving the editor closes it.
//!
//!     const comp = try Completion.create(&ui);
//!     defer comp.destroy();
//!     try comp.addProvider(.bind(&index, Index.complete));   // yours; optional
//!     comp.attach(editor);                                    // per editor
//!
//! Providers fill a `Sink` synchronously; the list is rebuilt on every
//! keystroke, so they must be quick (index lookups, not file scans). A provider
//! that works in the background (a language server) can call `offer` later with
//! the items it has; they show if the caret is still in the same word. The
//! built-in `words` provider offers identifiers already in the buffer, which
//! works for any language with nothing configured. Ranking: exact prefix, then
//! prefix ignoring case, then letters in order (`gtl` finds `getTotalLength`).
//!
//! Detach an editor (or destroy the `Completion`) before destroying the editor.

const std = @import("std");
const Ui = @import("../core/ui.zig").Ui;
const event = @import("../core/event.zig");
const geometry = @import("../core/geometry.zig");
const code_editor = @import("code_editor.zig");
const CodeEditor = code_editor.CodeEditor;
const popup = @import("popup.zig");
const PickHook = @import("menu.zig").PickHook;

pub const Item = struct {
    /// Shown in the list, and what is matched.
    label: []const u8,
    /// Text to insert instead of `label` (empty: the label).
    insert: []const u8 = "",
    /// Dimmed text after the label (a signature, a type).
    detail: []const u8 = "",
    /// Short tag before the label: `fn`, `var`, `type`, `const`, `field`...
    tag: []const u8 = "",
};

/// What a provider is asked.
pub const Request = struct {
    editor: *CodeEditor,
    /// The identifier before the caret (may be empty).
    prefix: []const u8,
    /// Byte offset where that identifier starts.
    word_start: usize,
    /// The line's text before the identifier (to see `foo.` or `@import(`).
    line_before: []const u8,
    /// Asked for by the user (Ctrl+Space), so offer even for an empty prefix.
    explicit: bool,

    /// True when the identifier follows a dot: `value.` then the prefix.
    pub fn afterDot(self: *const Request) bool {
        return self.line_before.len > 0 and self.line_before[self.line_before.len - 1] == '.';
    }
};

/// Where a provider puts candidates. Strings are copied.
pub const Sink = struct {
    arena: std.mem.Allocator,
    items: *std.ArrayListUnmanaged(Item),

    pub fn add(self: *Sink, item: Item) void {
        const copy: Item = .{
            .label = self.arena.dupe(u8, item.label) catch return,
            .insert = self.arena.dupe(u8, item.insert) catch return,
            .detail = self.arena.dupe(u8, item.detail) catch return,
            .tag = self.arena.dupe(u8, item.tag) catch return,
        };
        self.items.append(self.arena, copy) catch {};
    }
};

pub const Provider = struct {
    ctx: ?*anyopaque = null,
    complete: *const fn (ctx: ?*anyopaque, req: *const Request, sink: *Sink) void,

    /// `Provider.bind(&x, X.complete)` with `fn (*X, *const Request, *Sink) void`.
    pub fn bind(ctx: anytype, comptime f: anytype) Provider {
        const Ptr = @TypeOf(ctx);
        return .{
            .ctx = @ptrCast(ctx),
            .complete = &struct {
                fn thunk(c: ?*anyopaque, req: *const Request, sink: *Sink) void {
                    f(@as(Ptr, @ptrCast(@alignCast(c.?))), req, sink);
                }
            }.thunk,
        };
    }
};

pub const max_items = 200;
const max_providers = 8;
const words_limit = 1 << 20;

fn isWordChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c >= 0x80;
}

/// How well `label` matches `prefix`: lower is better, null if it does not match.
pub fn matchScore(prefix: []const u8, label: []const u8) ?u32 {
    if (prefix.len == 0) return 0;
    if (std.mem.startsWith(u8, label, prefix)) return 0;
    if (label.len >= prefix.len and std.ascii.eqlIgnoreCase(label[0..prefix.len], prefix)) return 1;
    // Letters in order; the score grows with the gaps and a late first letter.
    var li: usize = 0;
    var gaps: u32 = 0;
    for (prefix) |pc| {
        const at = while (li < label.len) : (li += 1) {
            if (std.ascii.toLower(label[li]) == std.ascii.toLower(pc)) break li;
        } else return null;
        if (at > 0 and at != li) gaps += 1;
        li = at + 1;
    }
    return 2 + gaps + @as(u32, @intCast(@min(std.mem.indexOfScalar(u8, label, prefix[0]) orelse 0, 20)));
}

const Ranked = struct { item: Item, score: u32 };

fn rankLess(_: void, a: Ranked, b: Ranked) bool {
    if (a.score != b.score) return a.score < b.score;
    if (a.item.label.len != b.item.label.len) return a.item.label.len < b.item.label.len;
    return std.mem.lessThan(u8, a.item.label, b.item.label);
}

pub const Completion = struct {
    gpa: std.mem.Allocator,
    ui: *Ui,
    providers: [max_providers]Provider = undefined,
    provider_n: usize = 0,
    /// Offer identifiers already in the buffer.
    words: bool = true,
    /// Letters typed before the list opens by itself.
    min_prefix: usize = 2,
    /// The editor the open list belongs to.
    editor: ?*CodeEditor = null,
    word_start: usize = 0,
    /// Candidates of the current request (the list and its strings live in `arena`).
    arena: std.heap.ArenaAllocator,
    shown: std.ArrayListUnmanaged(Item) = .empty,
    /// Where the popup list starts in `shown` indexes (the rows are the ranked
    /// subset; `row_items` maps a row to its item).
    row_items: std.ArrayListUnmanaged(u32) = .empty,
    attached: std.ArrayListUnmanaged(*CodeEditor) = .empty,

    pub fn create(ui: *Ui) !*Completion {
        const self = try ui.gpa.create(Completion);
        self.* = .{ .gpa = ui.gpa, .ui = ui, .arena = std.heap.ArenaAllocator.init(ui.gpa) };
        return self;
    }

    pub fn destroy(self: *Completion) void {
        self.hide();
        for (self.attached.items) |ed| self.unbind(ed);
        self.attached.deinit(self.gpa);
        self.row_items.deinit(self.gpa);
        self.arena.deinit();
        self.gpa.destroy(self);
    }

    pub fn addProvider(self: *Completion, p: Provider) !void {
        if (self.provider_n == max_providers) return error.TooManyProviders;
        self.providers[self.provider_n] = p;
        self.provider_n += 1;
    }

    /// Watch `ed`: typing there opens the list.
    pub fn attach(self: *Completion, ed: *CodeEditor) !void {
        try self.attached.append(self.gpa, ed);
        try ed.addKeyHook(event.Callback.bind(self, onKey));
        try ed.addEditHook(event.Callback.bind(self, onEdit));
        ed.ui.tree.addListener(ed.node, .{ .kind = .pointer_down, .callback = event.Callback.bind(self, onDismiss) }) catch {};
        ed.ui.tree.addListener(ed.node, .{ .kind = .focus_out, .callback = event.Callback.bind(self, onDismiss) }) catch {};
    }

    fn unbind(self: *Completion, ed: *CodeEditor) void {
        ed.removeHooks(self);
    }

    /// Stop watching `ed` (do this before destroying it).
    pub fn detach(self: *Completion, ed: *CodeEditor) void {
        if (self.editor == ed) self.hide();
        if (std.mem.indexOfScalar(*CodeEditor, self.attached.items, ed)) |i| {
            _ = self.attached.swapRemove(i);
            self.unbind(ed);
        }
    }

    pub fn isOpen(self: *const Completion) bool {
        return self.editor != null and self.ui.popupOpen();
    }

    pub fn hide(self: *Completion) void {
        if (self.editor != null) self.ui.hidePopup();
        self.editor = null;
    }

    /// Open the list now for `ed`'s caret (Ctrl+Space).
    pub fn trigger(self: *Completion, ed: *CodeEditor) void {
        self.query(ed, true);
    }

    /// Late results from a background provider for the word that started at
    /// `word_start` in `ed`: ignored if the caret has moved on.
    pub fn offer(self: *Completion, ed: *CodeEditor, word_start: usize, items: []const Item) void {
        var w = self.wordAtCaret(ed) orelse return;
        if (w.start != word_start) return;
        _ = &w;
        var list: std.ArrayListUnmanaged(Item) = .empty;
        var sink: Sink = .{ .arena = self.arena.allocator(), .items = &list };
        if (self.editor == ed) {
            list = self.shown;
            self.shown = .empty;
        }
        for (items) |it| sink.add(it);
        self.shown = list;
        self.editor = ed;
        self.present(ed, w.prefix, w.start);
    }

    const Word = struct { start: usize, prefix: []const u8, line_before: []const u8 };

    /// The identifier before `ed`'s caret; strings are valid until the next document read.
    fn wordAtCaret(self: *Completion, ed: *CodeEditor) ?Word {
        _ = self;
        const core = ed.core();
        const head = core.primaryHead();
        const doc = &core.doc;
        const ls = doc.lineStart(doc.lineOfOffset(head));
        const before = doc.range(ls, head) catch return null;
        var i = before.len;
        while (i > 0 and isWordChar(before[i - 1])) i -= 1;
        if (i > 0 and before[i - 1] == '@') i -= 1;
        return .{ .start = ls + i, .prefix = before[i..], .line_before = before[0..i] };
    }

    fn query(self: *Completion, ed: *CodeEditor, explicit: bool) void {
        const w = self.wordAtCaret(ed) orelse return self.hide();
        // `shown` and its strings live in the arena; reset frees them together.
        self.shown = .empty;
        _ = self.arena.reset(.retain_capacity);
        const req: Request = .{ .editor = ed, .prefix = w.prefix, .word_start = w.start, .line_before = w.line_before, .explicit = explicit };
        var sink: Sink = .{ .arena = self.arena.allocator(), .items = &self.shown };
        for (self.providers[0..self.provider_n]) |p| p.complete(p.ctx, &req, &sink);
        if (self.words) self.addWords(ed, &req, &sink);
        self.present(ed, w.prefix, w.start);
    }

    /// Identifiers already in the buffer.
    fn addWords(self: *Completion, ed: *CodeEditor, req: *const Request, sink: *Sink) void {
        if (req.prefix.len == 0) return;
        const doc = &ed.core().doc;
        if (doc.len() > words_limit) return;
        const text = doc.textAlloc(self.gpa, 0, doc.len()) catch return;
        defer self.gpa.free(text);
        var seen: std.StringHashMapUnmanaged(void) = .empty;
        defer seen.deinit(self.gpa);
        var i: usize = 0;
        while (i < text.len) {
            if (!isWordChar(text[i])) {
                i += 1;
                continue;
            }
            const s = i;
            while (i < text.len and isWordChar(text[i])) i += 1;
            const word = text[s..i];
            // The word being typed does not suggest itself.
            if (word.len < 3 or (s <= req.word_start + req.prefix.len and i >= req.word_start)) continue;
            if (std.ascii.isDigit(word[0])) continue;
            const gop = seen.getOrPut(self.gpa, word) catch return;
            if (gop.found_existing) continue;
            sink.add(.{ .label = word, .tag = "" });
        }
    }

    /// Rank `shown` against `prefix` and (re)open the popup.
    fn present(self: *Completion, ed: *CodeEditor, prefix: []const u8, word_start: usize) void {
        var ranked: std.ArrayListUnmanaged(Ranked) = .empty;
        defer ranked.deinit(self.gpa);
        var seen: std.StringHashMapUnmanaged(void) = .empty;
        defer seen.deinit(self.gpa);
        for (self.shown.items, 0..) |it, idx| {
            _ = idx;
            const score = matchScore(prefix, it.label) orelse continue;
            // A candidate that is exactly what is typed adds nothing.
            if (std.mem.eql(u8, it.label, prefix)) continue;
            const gop = seen.getOrPut(self.gpa, it.label) catch continue;
            if (gop.found_existing) continue;
            ranked.append(self.gpa, .{ .item = it, .score = score }) catch continue;
        }
        if (ranked.items.len == 0) return self.hide();
        std.mem.sort(Ranked, ranked.items, {}, rankLess);
        const n = @min(ranked.items.len, max_items);
        var rows = self.gpa.alloc(popup.Row, n) catch return;
        defer self.gpa.free(rows);
        // Rows refer to items by position in the ranked order; keep the
        // order so `onPick` can find the text.
        self.row_items.clearRetainingCapacity();
        var reordered: std.ArrayListUnmanaged(Item) = .empty;
        reordered.ensureTotalCapacity(self.arena.allocator(), n) catch return;
        for (ranked.items[0..n], 0..) |r, i| {
            rows[i] = .{ .label = r.item.label, .detail = r.item.detail, .tag = r.item.tag, .user = i };
            reordered.appendAssumeCapacity(r.item);
        }
        self.shown = reordered;
        const caret = ed.caretRect() orelse return self.hide();
        const font_w = ed.ui.theme.font_size * 0.6;
        const anchor: geometry.Rect = .{ .x = caret.x - font_w * @as(f32, @floatFromInt(prefix.len)), .y = caret.y, .w = caret.w, .h = caret.h };
        self.ui.showPopup(rows, .{ .anchor = anchor, .on_pick = PickHook.bind(self, onPick), .max_rows = 10, .min_width = 220 }) catch return self.hide();
        self.editor = ed;
        self.word_start = word_start;
    }

    fn onPick(self: *Completion, index: usize) void {
        const ed = self.editor orelse return;
        self.editor = null;
        if (index >= self.shown.items.len) return;
        const it = self.shown.items[index];
        const text = if (it.insert.len > 0) it.insert else it.label;
        const head = ed.core().primaryHead();
        if (head < self.word_start) return;
        ed.replaceRange(self.word_start, head, text);
    }

    fn onKey(self: *Completion, ev: *event.Event) void {
        const ed = self.editorOf(ev) orelse return;
        const m = ev.mods;
        if (m.ctrl and !m.alt and !m.shift and ev.key == .space) {
            ev.markHandled();
            self.trigger(ed);
            return;
        }
        if (!self.isOpen() or self.editor != ed) return;
        if (m.ctrl or m.alt or m.gui) return;
        switch (ev.key) {
            .down => {
                ev.markHandled();
                self.ui.popupMove(1);
            },
            .up => {
                ev.markHandled();
                self.ui.popupMove(-1);
            },
            .page_down => {
                ev.markHandled();
                self.ui.popupMove(8);
            },
            .page_up => {
                ev.markHandled();
                self.ui.popupMove(-8);
            },
            .enter, .tab => if (!m.shift) {
                ev.markHandled();
                _ = self.ui.popupPick();
            },
            .escape => {
                ev.markHandled();
                self.hide();
            },
            .left, .right, .home, .end => self.hide(),
            else => {},
        }
    }

    fn editorOf(self: *Completion, ev: *event.Event) ?*CodeEditor {
        for (self.attached.items) |ed| {
            if (ed.node.eql(ev.current) or ed.node.eql(ev.target)) return ed;
        }
        return null;
    }

    fn onEdit(self: *Completion, ev: *event.Event) void {
        const ed = self.editorOf(ev) orelse return;
        const typed = ev.kind == .text_input and ev.text.len > 0;
        if (self.isOpen() and self.editor == ed) {
            // Keep narrowing while the caret stays in the same word.
            const w = self.wordAtCaret(ed) orelse return self.hide();
            if (w.start != self.word_start) return self.hide();
            return self.query(ed, false);
        }
        if (!typed) return;
        const w = self.wordAtCaret(ed) orelse return;
        const last = ev.text[ev.text.len - 1];
        if (last == '.' or (isWordChar(last) and w.prefix.len >= self.min_prefix) or (last == '@' and self.min_prefix <= 1)) {
            self.query(ed, last == '.');
        }
    }

    fn onDismiss(self: *Completion, _: *event.Event) void {
        self.hide();
    }
};

// ---- tests -----------------------------------------------------------------

const testing = std.testing;
const Rig = @import("../core/test_rig.zig").Rig;

test "matching: prefix, case-insensitive prefix, then letters in order" {
    try testing.expectEqual(@as(?u32, 0), matchScore("get", "getTotal"));
    try testing.expectEqual(@as(?u32, 1), matchScore("get", "GetTotal"));
    try testing.expect(matchScore("gtl", "getTotalLength").? >= 2);
    try testing.expect(matchScore("xyz", "getTotal") == null);
    try testing.expect(matchScore("get", "xget").? >= 2);
    try testing.expectEqual(@as(?u32, 0), matchScore("", "anything"));
    try testing.expect(matchScore("gtl", "getTotalLength").? < matchScore("gtl", "xxxxxxxxxxgxxtxxl").?);
}

const Fixed = struct {
    asked: usize = 0,
    dot: bool = false,
    fn complete(self: *Fixed, req: *const Request, sink: *Sink) void {
        self.asked += 1;
        self.dot = req.afterDot();
        sink.add(.{ .label = "print", .detail = "(fmt, args) void", .tag = "fn" });
        sink.add(.{ .label = "printErr", .insert = "printErr()", .tag = "fn" });
    }
};

fn setup(r: *Rig, text: []const u8) !*CodeEditor {
    const ed = try r.ui.add(CodeEditor, r.ui.tree.root, .{ .style = .{ .grow = 1 }, .label = "t" });
    try ed.loadText(try r.ui.gpa.dupe(u8, text), true);
    r.ui.setFocus(ed.node);
    try r.frame();
    return ed;
}

test "typing opens the list; keys move, pick and close it" {
    const r = try Rig.init();
    defer r.deinit();
    const ed = try setup(r, "alpha_beta alphabet\n");
    const comp = try Completion.create(&r.ui);
    defer comp.destroy();
    try comp.attach(ed);
    ed.core().setCaret(ed.core().doc.len() - 1, false); // end of the first line
    r.ui.textInput("\nalp");
    try r.frame();
    try testing.expect(comp.isOpen());
    const p = r.ui.popup.?;
    try testing.expectEqual(@as(usize, 2), p.count());
    // Shorter first: "alphabet" (8) before "alpha_beta" (10).
    try testing.expectEqualStrings("alphabet", p.entries[0].row.label);
    r.ui.key(.down, .{}, true, false);
    r.ui.key(.down, .{}, true, false); // wraps back
    try r.frame();
    try testing.expectEqual(@as(?usize, 0), r.ui.popup.?.selectedIndex());
    r.ui.key(.tab, .{}, true, false);
    try r.frame();
    try testing.expect(!comp.isOpen());
    const text = try ed.textAlloc(testing.allocator);
    defer testing.allocator.free(text);
    try testing.expectEqualStrings("alpha_beta alphabet\nalphabet\n"[0..28], text[0..28]);
    // Escape closes without inserting.
    r.ui.textInput("\nalp");
    try r.frame();
    try testing.expect(comp.isOpen());
    r.ui.key(.escape, .{}, true, false);
    try testing.expect(!comp.isOpen());
    try testing.expect(r.ui.tree.focused.eql(ed.node));
}

test "providers, Ctrl+Space, dot triggers, narrowing and insert text" {
    const r = try Rig.init();
    defer r.deinit();
    const ed = try setup(r, "");
    const comp = try Completion.create(&r.ui);
    defer comp.destroy();
    var prov: Fixed = .{};
    try comp.addProvider(.bind(&prov, Fixed.complete));
    try comp.attach(ed);
    r.ui.textInput("std.");
    try r.frame();
    try testing.expect(comp.isOpen());
    try testing.expect(prov.dot);
    try testing.expectEqual(@as(usize, 2), r.ui.popup.?.count());
    r.ui.textInput("printE"); // narrows to printErr
    try r.frame();
    try testing.expectEqual(@as(usize, 1), r.ui.popup.?.count());
    r.ui.key(.enter, .{}, true, false);
    try r.frame();
    const text = try ed.textAlloc(testing.allocator);
    defer testing.allocator.free(text);
    try testing.expectEqualStrings("std.printErr()", text);
    try testing.expect(!comp.isOpen());

    // Ctrl+Space opens it for an empty prefix; moving the caret away closes it.
    r.ui.textInput("\n");
    r.ui.key(.space, .{ .ctrl = true }, true, false);
    try r.frame();
    try testing.expect(comp.isOpen());
    r.ui.key(.left, .{}, true, false);
    try testing.expect(!comp.isOpen());

    // Detached editors no longer trigger.
    comp.detach(ed);
    prov.asked = 0;
    r.ui.textInput("zzz");
    try testing.expectEqual(@as(usize, 0), prov.asked);
}
