//! FindBar: find and replace for a `CodeEditor`. Put it where you like (usually
//! just above the editor) and `attach` it: Ctrl+F in the editor then opens it,
//! Ctrl+H opens it with the replace row, matches are highlighted in the editor
//! (decoration owner `find_owner`), Enter / Shift+Enter step through them, and
//! Escape closes it and gives the editor focus back.
//!
//!     const find = try ui.add(FindBar, column, .{});
//!     find.attach(editor);
//!
//! Matching is literal, with case and whole-word toggles (see `editor/search`).
//! Replace All is one undo step. The bar follows edits: matches are recomputed
//! when the text changes.

const std = @import("std");
const Handle = @import("../core/handle.zig").Handle;
const shadow = @import("../core/shadow.zig");
const Ui = @import("../core/ui.zig").Ui;
const event = @import("../core/event.zig");
const paint_ctx = @import("../core/paint_ctx.zig");
const PaintCtx = paint_ctx.PaintCtx;
const Style = @import("../core/style.zig").Style;
const Edges = @import("../core/style.zig").Edges;
const Length = @import("../core/length.zig").Length;
const Node = @import("../core/tree.zig").Node;
const search = @import("../editor/search.zig");
const editor_mod = @import("../editor/editor.zig");
const Label = @import("label.zig").Label;
const Button = @import("button.zig").Button;
const TextField = @import("text_field.zig").TextField;
const code_editor = @import("code_editor.zig");
const CodeEditor = code_editor.CodeEditor;

/// The decoration owner the bar uses on the editor.
pub const find_owner: u8 = 0;
const max_matches = 10_000;

pub const FindBar = struct {
    props: Props = .{},
    out: Out = .{},
    node: Handle,
    ui: *Ui,
    checker: shadow.Checker(Props),
    editor: ?*CodeEditor = null,
    find_field: *TextField = undefined,
    replace_field: *TextField = undefined,
    replace_row: Handle = Handle.invalid,
    count: *Label = undefined,
    case_btn: *Button = undefined,
    word_btn: *Button = undefined,
    matches: []search.Match = &.{},
    /// Index into `matches` of the current one, if any.
    current: ?usize = null,
    /// The document version and query the matches were computed for.
    seen_version: u64 = 0,
    seen_query: []u8 = &.{},
    open: bool = false,

    pub const Props = struct {
        case_sensitive: bool = false,
        whole_word: bool = false,
        /// The replace row is showing.
        show_replace: bool = false,

        pub const dirty_map = .{
            .case_sensitive = shadow.Category.paint,
            .whole_word = shadow.Category.paint,
            .show_replace = shadow.Category.layout,
        };
    };

    pub const Out = struct {
        match_count: u32 = 0,
        /// 1-based index of the current match, 0 for none.
        current: u32 = 0,
        open: bool = false,
    };

    pub const Options = struct {
        style: Style = .{},
    };

    pub const listened_kinds = [_]event.EventKind{.key_down};

    pub fn nodeTemplate(style: Style) Node {
        var s = style;
        s.direction = .column;
        s.gap = Length.px(4);
        if (std.meta.eql(s.padding, .{})) s.padding = Edges.all(6);
        return .{
            .role = .panel,
            .style = s,
            .visual = .{ .background = Color.rgb(0x2b, 0x2d, 0x31), .border_color = Color.rgb(0x4a, 0x4d, 0x52), .border_width = 1, .radius = 4 },
            .flags = .{ .hidden = true },
        };
    }

    const Color = @import("../core/geometry.zig").Color;

    pub fn init(ui: *Ui, node: Handle) FindBar {
        const props: Props = .{};
        return .{ .node = node, .ui = ui, .checker = shadow.Checker(Props).init(&props) };
    }

    pub fn deinit(self: *FindBar) void {
        self.ui.gpa.free(self.matches);
        self.ui.gpa.free(self.seen_query);
    }

    pub fn apply(self: *FindBar, o: Options) !void {
        _ = o;
        const ui = self.ui;
        const tree = &ui.tree;
        try tree.setLabel(self.node, "Find");
        const row1 = try tree.create(.{ .style = .{ .direction = .row, .gap = Length.px(4), .align_items = .center } });
        try tree.appendChild(self.node, row1);
        self.find_field = try ui.add(TextField, row1, .{
            .placeholder = "Find",
            .label = "Find",
            .style = .{ .grow = 1, .min_width = Length.px(120) },
            .on_change = event.Callback.bind(self, onQueryChange),
            .on_submit = event.Callback.bind(self, onFindSubmit),
        });
        self.case_btn = try ui.add(Button, row1, .{ .text = "Aa", .variant = .flat, .style = .{ .padding = Edges.xy(8, 4) }, .on_click = event.Callback.bind(self, onToggle) });
        self.word_btn = try ui.add(Button, row1, .{ .text = "W", .variant = .flat, .style = .{ .padding = Edges.xy(8, 4) }, .on_click = event.Callback.bind(self, onToggle) });
        self.count = try ui.add(Label, row1, .{ .text = "", .style = .{ .width = Length.px(70), .shrink = 0 } });
        _ = try ui.add(Button, row1, .{ .text = "Prev", .variant = .flat, .style = .{ .padding = Edges.xy(8, 4) }, .on_click = event.Callback.bind(self, onPrev) });
        _ = try ui.add(Button, row1, .{ .text = "Next", .variant = .flat, .style = .{ .padding = Edges.xy(8, 4) }, .on_click = event.Callback.bind(self, onNext) });
        _ = try ui.add(Button, row1, .{ .text = "x", .variant = .flat, .style = .{ .padding = Edges.xy(8, 4) }, .on_click = event.Callback.bind(self, onClose) });

        self.replace_row = try tree.create(.{ .style = .{ .direction = .row, .gap = Length.px(4), .align_items = .center }, .flags = .{ .hidden = true } });
        try tree.appendChild(self.node, self.replace_row);
        self.replace_field = try ui.add(TextField, self.replace_row, .{
            .placeholder = "Replace",
            .label = "Replace",
            .style = .{ .grow = 1, .min_width = Length.px(120) },
            .on_submit = event.Callback.bind(self, onReplaceOne),
        });
        _ = try ui.add(Button, self.replace_row, .{ .text = "Replace", .variant = .flat, .style = .{ .padding = Edges.xy(8, 4) }, .on_click = event.Callback.bind(self, onReplaceOne) });
        _ = try ui.add(Button, self.replace_row, .{ .text = "Replace all", .variant = .flat, .style = .{ .padding = Edges.xy(8, 4) }, .on_click = event.Callback.bind(self, onReplaceAll) });
        self.checker.sync(&self.props);
    }

    /// Connect to `ed`: Ctrl+F / Ctrl+H in it open this bar.
    pub fn attach(self: *FindBar, ed: *CodeEditor) void {
        self.editor = ed;
        ed.props.on_find = event.Callback.bind(self, onEditorFind);
    }

    // ---- showing and hiding ----

    /// Show the bar (with the replace row if `replace`), seed the query from a
    /// one-line selection, and focus the query.
    pub fn show(self: *FindBar, replace: bool) void {
        const ed = self.editor orelse return;
        self.open = true;
        self.out.open = true;
        self.props.show_replace = replace;
        self.ui.setHidden(self.node, false);
        self.ui.setHidden(self.replace_row, !replace);
        const core = ed.core();
        if (core.hasSelectedText()) {
            if (core.selectedText(self.ui.gpa)) |t| {
                defer self.ui.gpa.free(t);
                if (t.len > 0 and std.mem.indexOfScalar(u8, t, '\n') == null) self.find_field.setText(t) catch {};
            } else |_| {}
        }
        self.ui.setFocus(self.find_field.node);
        self.find_field.editor.selectAll();
        self.refresh(true);
    }

    pub fn hide(self: *FindBar) void {
        if (!self.open) return;
        self.open = false;
        self.out.open = false;
        self.ui.setHidden(self.node, true);
        if (self.editor) |ed| {
            ed.clearDecorations(find_owner);
            self.ui.setFocus(ed.node);
        }
        self.setMatches(&.{});
    }

    fn onEditorFind(self: *FindBar, ev: *event.Event) void {
        self.show(ev.key == .h);
    }

    fn onClose(self: *FindBar, _: *event.Event) void {
        self.hide();
    }

    pub fn handleEvent(self: *FindBar, ev: *event.Event) void {
        if (ev.kind == .key_down and ev.key == .escape) {
            ev.markHandled();
            self.hide();
        }
    }

    // ---- matching ----

    fn options(self: *const FindBar) search.Options {
        return .{ .case_sensitive = self.props.case_sensitive, .whole_word = self.props.whole_word };
    }

    fn setMatches(self: *FindBar, list: []const search.Match) void {
        self.ui.gpa.free(self.matches);
        self.matches = self.ui.gpa.dupe(search.Match, list) catch &.{};
        self.out.match_count = @intCast(self.matches.len);
    }

    /// Recompute the matches for the current query and options; with `select`,
    /// jump to the first one at or after the caret.
    pub fn refresh(self: *FindBar, select: bool) void {
        const ed = self.editor orelse return;
        const q = self.find_field.text();
        const core = ed.core();
        const found = search.findAll(&core.doc, self.ui.gpa, q, self.options(), max_matches) catch &.{};
        defer if (found.len > 0) self.ui.gpa.free(found);
        self.setMatches(found);
        self.seen_version = core.doc.version;
        self.ui.gpa.free(self.seen_query);
        self.seen_query = self.ui.gpa.dupe(u8, q) catch &.{};
        const caret = core.sel.items.items[0].start();
        self.current = search.nextIndex(self.matches, caret);
        if (select) self.jump() else self.paintMatches();
        self.updateCount();
    }

    fn jump(self: *FindBar) void {
        const ed = self.editor orelse return;
        if (self.current) |i| {
            const m = self.matches[i];
            ed.selectRange(m.start, m.end);
        }
        self.paintMatches();
    }

    fn paintMatches(self: *FindBar) void {
        const ed = self.editor orelse return;
        var list: std.ArrayListUnmanaged(code_editor.Decoration) = .empty;
        defer list.deinit(self.ui.gpa);
        for (self.matches, 0..) |m, i| {
            const kind: code_editor.DecorationKind = if (self.current != null and self.current.? == i) .current else .highlight;
            list.append(self.ui.gpa, .{ .start = m.start, .end = m.end, .kind = kind }) catch break;
        }
        ed.setDecorations(find_owner, list.items) catch {};
    }

    fn updateCount(self: *FindBar) void {
        var buf: [32]u8 = undefined;
        const text = if (self.find_field.text().len == 0)
            ""
        else if (self.matches.len == 0)
            "No results"
        else
            std.fmt.bufPrint(&buf, "{d} of {d}", .{ (self.current orelse 0) + 1, self.matches.len }) catch "";
        self.out.current = if (self.current != null and self.matches.len > 0) @intCast(self.current.? + 1) else 0;
        if (!std.mem.eql(u8, self.count.props.text.bytes, text)) self.count.setText(text) catch {};
    }

    pub fn findNext(self: *FindBar) void {
        if (self.matches.len == 0) return;
        const cur = self.current orelse 0;
        self.current = (cur + 1) % self.matches.len;
        self.jump();
        self.updateCount();
    }

    pub fn findPrev(self: *FindBar) void {
        if (self.matches.len == 0) return;
        const cur = self.current orelse 0;
        self.current = (cur + self.matches.len - 1) % self.matches.len;
        self.jump();
        self.updateCount();
    }

    // ---- replacing ----

    /// Replace the current match and move to the next.
    pub fn replaceCurrent(self: *FindBar) void {
        const ed = self.editor orelse return;
        const i = self.current orelse return;
        if (i >= self.matches.len) return;
        const m = self.matches[i];
        _ = ed.core().replaceRanges(self.ui.now_ms, &.{.{ .start = m.start, .end = m.end, .text = self.replace_field.text() }}) catch return;
        ed.repaint = true;
        self.refresh(false);
        // `current` is the match that now follows the caret; select it.
        self.jump();
        self.updateCount();
    }

    /// Replace every match (one undo step); returns how many.
    pub fn replaceAll(self: *FindBar) usize {
        const ed = self.editor orelse return 0;
        if (self.matches.len == 0) return 0;
        const gpa = self.ui.gpa;
        const edits = gpa.alloc(editor_mod.Edit, self.matches.len) catch return 0;
        defer gpa.free(edits);
        const with = self.replace_field.text();
        for (self.matches, edits) |m, *e| e.* = .{ .start = m.start, .end = m.end, .text = with };
        const n = self.matches.len;
        _ = ed.core().replaceRanges(self.ui.now_ms, edits) catch return 0;
        ed.repaint = true;
        self.refresh(false);
        return n;
    }

    // ---- control callbacks ----

    fn onQueryChange(self: *FindBar, _: *event.Event) void {
        self.refresh(true);
    }

    fn onFindSubmit(self: *FindBar, ev: *event.Event) void {
        if (ev.mods.shift) self.findPrev() else self.findNext();
    }

    fn onNext(self: *FindBar, _: *event.Event) void {
        self.findNext();
    }

    fn onPrev(self: *FindBar, _: *event.Event) void {
        self.findPrev();
    }

    fn onToggle(self: *FindBar, ev: *event.Event) void {
        if (ev.current.eql(self.case_btn.node)) self.props.case_sensitive = !self.props.case_sensitive else self.props.whole_word = !self.props.whole_word;
        self.case_btn.setVariant(if (self.props.case_sensitive) .primary else .flat);
        self.word_btn.setVariant(if (self.props.whole_word) .primary else .flat);
        self.refresh(true);
    }

    fn onReplaceOne(self: *FindBar, _: *event.Event) void {
        self.replaceCurrent();
    }

    fn onReplaceAll(self: *FindBar, _: *event.Event) void {
        _ = self.replaceAll();
    }

    // ---- widget plumbing ----

    pub fn paintHook(self: *FindBar, pc: *PaintCtx) paint_ctx.Error!void {
        _ = self;
        _ = pc;
    }

    pub fn prepare(self: *FindBar) void {
        _ = self;
    }

    /// Follow edits made to the text while the bar is open.
    pub fn update(self: *FindBar) void {
        self.ui.verifyProps(self.node, &self.checker, &self.props, "find_bar");
        if (!self.open) return;
        const ed = self.editor orelse return;
        if (ed.core().doc.version != self.seen_version) {
            self.refresh(false);
        }
    }

    pub fn endFrame(self: *FindBar) void {
        _ = self;
    }
};

// ---- tests -----------------------------------------------------------------

const testing = std.testing;
const draw_list = @import("../core/draw_list.zig");

const Rig = struct {
    ui: Ui,
    cmds: [4096]draw_list.Command = undefined,
    glyphs: [4096]draw_list.Glyph = undefined,
    list: draw_list.DrawList = undefined,
    prop: @import("../text/font.zig").TestFont = .{},
    mono: @import("../text/font.zig").TestFont = .{ .monospace = true },

    fn init() !*Rig {
        const r = try testing.allocator.create(Rig);
        r.* = .{ .ui = try Ui.init(testing.allocator) };
        _ = try r.ui.addFont(r.prop.backend());
        r.ui.theme.mono_font = try r.ui.addFont(r.mono.backend());
        r.list = draw_list.DrawList.init(&r.cmds, &r.glyphs);
        r.ui.tree.get(r.ui.tree.root).?.style = .{ .direction = .column, .align_items = .stretch };
        return r;
    }

    fn deinit(self: *Rig) void {
        self.ui.deinit();
        testing.allocator.destroy(self);
    }

    fn frame(self: *Rig) !void {
        self.ui.update();
        try self.ui.layoutAndPaint(.{ .w = 500, .h = 300 }, &self.list);
        self.ui.endFrame();
    }
};

fn typeQuery(r: *Rig, f: *TextField, text: []const u8) void {
    r.ui.setFocus(f.node);
    r.ui.key(.a, .{ .ctrl = true }, true, false);
    r.ui.textInput(text);
}

fn selectedOf(ed: *CodeEditor) ![]u8 {
    return ed.core().selectedText(testing.allocator);
}

test "Ctrl+F opens the bar; typing highlights and selects matches; Enter steps; Escape closes" {
    const r = try Rig.init();
    defer r.deinit();
    const ed = try r.ui.add(CodeEditor, r.ui.tree.root, .{ .style = .{ .grow = 1 }, .language = null });
    try ed.loadText("cat dog cat\nbird cat\n", false);
    const bar = try r.ui.add(FindBar, r.ui.tree.root, .{});
    bar.attach(ed);
    try r.frame();
    try testing.expect(!bar.open);

    r.ui.setFocus(ed.node);
    r.ui.key(.f, .{ .ctrl = true }, true, false);
    try r.frame();
    try testing.expect(bar.open);
    try testing.expect(r.ui.tree.focused.eql(bar.find_field.node));

    typeQuery(r, bar.find_field, "cat");
    try r.frame();
    try testing.expectEqual(@as(u32, 3), bar.out.match_count);
    try testing.expectEqual(@as(u32, 1), bar.out.current);
    const s1 = try selectedOf(ed);
    defer testing.allocator.free(s1);
    try testing.expectEqualStrings("cat", s1);
    try testing.expectEqual(@as(usize, 3), ed.decos[find_owner].items.len);
    try testing.expectEqual(code_editor.DecorationKind.current, ed.decos[find_owner].items[0].kind);

    // Enter goes to the next match, Shift+Enter back.
    r.ui.key(.enter, .{}, true, false);
    try testing.expectEqual(@as(u32, 2), bar.out.current);
    try testing.expectEqual(@as(usize, 8), ed.core().sel.items.items[0].start());
    r.ui.key(.enter, .{ .shift = true }, true, false);
    try testing.expectEqual(@as(u32, 1), bar.out.current);
    r.ui.key(.enter, .{ .shift = true }, true, false); // wraps to the last
    try testing.expectEqual(@as(u32, 3), bar.out.current);

    r.ui.key(.escape, .{}, true, false);
    try r.frame();
    try testing.expect(!bar.open);
    try testing.expectEqual(@as(usize, 0), ed.decos[find_owner].items.len);
    try testing.expect(r.ui.tree.focused.eql(ed.node));
}

test "case and whole-word toggles change the matches" {
    const r = try Rig.init();
    defer r.deinit();
    const ed = try r.ui.add(CodeEditor, r.ui.tree.root, .{ .style = .{ .grow = 1 } });
    try ed.loadText("Cat category cat", false);
    const bar = try r.ui.add(FindBar, r.ui.tree.root, .{});
    bar.attach(ed);
    bar.show(false);
    typeQuery(r, bar.find_field, "cat");
    try r.frame();
    try testing.expectEqual(@as(u32, 3), bar.out.match_count);
    var e1: event.Event = .{ .kind = .click, .current = bar.case_btn.node };
    bar.case_btn.props.on_click.?.invoke(&e1);
    try testing.expectEqual(@as(u32, 2), bar.out.match_count); // not "Cat"
    var e2: event.Event = .{ .kind = .click, .current = bar.word_btn.node };
    bar.word_btn.props.on_click.?.invoke(&e2);
    try testing.expectEqual(@as(u32, 1), bar.out.match_count); // not "category"
}

test "replace one, replace all (one undo step), and the bar follows edits" {
    const r = try Rig.init();
    defer r.deinit();
    const ed = try r.ui.add(CodeEditor, r.ui.tree.root, .{ .style = .{ .grow = 1 } });
    try ed.loadText("a b a b a", false);
    const bar = try r.ui.add(FindBar, r.ui.tree.root, .{});
    bar.attach(ed);
    bar.show(true);
    typeQuery(r, bar.find_field, "a");
    try r.frame();
    try testing.expectEqual(@as(u32, 3), bar.out.match_count);
    typeQuery(r, bar.replace_field, "XY");
    bar.replaceCurrent();
    try r.frame();
    {
        const t = try ed.textAlloc(testing.allocator);
        defer testing.allocator.free(t);
        try testing.expectEqualStrings("XY b a b a", t);
    }
    try testing.expectEqual(@as(u32, 2), bar.out.match_count);

    try testing.expectEqual(@as(usize, 2), bar.replaceAll());
    try r.frame();
    {
        const t = try ed.textAlloc(testing.allocator);
        defer testing.allocator.free(t);
        try testing.expectEqualStrings("XY b XY b XY", t);
    }
    try testing.expectEqual(@as(u32, 0), bar.out.match_count);
    // Undo restores both replacements at once.
    _ = try ed.core().undo();
    {
        const t = try ed.textAlloc(testing.allocator);
        defer testing.allocator.free(t);
        try testing.expectEqualStrings("XY b a b a", t);
    }

    // Typing in the editor re-runs the search.
    typeQuery(r, bar.find_field, "b");
    try r.frame();
    try testing.expectEqual(@as(u32, 2), bar.out.match_count);
    ed.core().setCaret(0, false);
    r.ui.setFocus(ed.node);
    r.ui.textInput("b ");
    try r.frame();
    try r.frame();
    try testing.expectEqual(@as(u32, 3), bar.out.match_count);
}
