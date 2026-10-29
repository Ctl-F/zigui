//! TextArea: a multi-line text field with a border. Typing, selection, the
//! clipboard, undo, and scrolling are the `CodeEditor`'s (this is one, with no
//! gutter or highlighting and the UI font), so it works like a field but holds
//! several lines. Use it for notes, descriptions, and lists; use `TextField`
//! for a single line and `CodeEditor` for code.
//!
//!     const notes = try ui.add(TextArea, parent, .{ .style = .{ .height = .px(90) }, .text = "a\nb" });
//!     const text = try notes.textAlloc(gpa);       // the content; you free it
//!
//! In a UI document the content is `.props.text` (like a text field's). Forms
//! use a text area for any string whose `ui` metadata says `.multiline = true`.

const std = @import("std");
const Handle = @import("../core/handle.zig").Handle;
const shadow = @import("../core/shadow.zig");
const geometry = @import("../core/geometry.zig");
const Ui = @import("../core/ui.zig").Ui;
const event = @import("../core/event.zig");
const paint_ctx = @import("../core/paint_ctx.zig");
const PaintCtx = paint_ctx.PaintCtx;
const Style = @import("../core/style.zig").Style;
const Edges = @import("../core/style.zig").Edges;
const Length = @import("../core/length.zig").Length;
const Node = @import("../core/tree.zig").Node;
const syntax = @import("../editor/syntax.zig");
const CodeEditor = @import("code_editor.zig").CodeEditor;

pub const TextArea = struct {
    props: Props = .{},
    out: Out = .{},
    node: Handle,
    ui: *Ui,
    checker: shadow.Checker(Props),
    /// The editing widget inside the border.
    editor: *CodeEditor = undefined,

    pub const Props = struct {
        enabled: bool = true,
        read_only: bool = false,
        /// The user edited the text.
        on_change: ?event.Callback = null,

        pub const dirty_map = .{
            .enabled = shadow.Category.paint,
            .read_only = shadow.Category.none,
        };
    };

    pub const Out = struct {
        /// The user edited the text this frame.
        changed: bool = false,
        change_count: u32 = 0,
        focused: bool = false,
        line_count: u32 = 1,
    };

    pub const Options = struct {
        style: Style = .{},
        /// Initial content (copied).
        text: []const u8 = "",
        /// Accessible name.
        label: []const u8 = "Text area",
        enabled: bool = true,
        read_only: bool = false,
        /// Em size; 0 uses the theme's.
        size: f32 = 0,
        on_change: ?event.Callback = null,
    };

    pub const listened_kinds = [_]event.EventKind{};

    pub fn nodeTemplate(style: Style) Node {
        var s = style;
        s.direction = .column;
        if (s.height == .auto) s.height = Length.px(80);
        return .{ .role = .text_field, .style = s, .flags = .{ .clip_children = true } };
    }

    pub fn init(ui: *Ui, node: Handle) TextArea {
        const props: Props = .{};
        return .{ .node = node, .ui = ui, .checker = shadow.Checker(Props).init(&props) };
    }

    pub fn deinit(self: *TextArea) void {
        _ = self;
    }

    pub fn apply(self: *TextArea, o: Options) !void {
        self.props.enabled = o.enabled;
        self.props.read_only = o.read_only;
        self.props.on_change = o.on_change;
        const c = self.ui.theme.field;
        self.ui.tree.get(self.node).?.visual = .{ .background = c.background, .border_color = c.border, .border_width = 1, .radius = self.ui.theme.corner_radius };
        self.editor = try self.ui.add(CodeEditor, self.node, .{
            .style = .{ .grow = 1, .padding = Edges.xy(2, 2) },
            .label = o.label,
            .language = &syntax.plain,
            .font = .ui,
            .size = o.size,
            .line_numbers = false,
            .auto_indent = false,
            .enabled = o.enabled,
            .read_only = o.read_only,
            .on_change = event.Callback.bind(self, onInner),
        });
        if (o.text.len > 0) {
            const copy = try self.ui.gpa.dupe(u8, o.text);
            errdefer self.ui.gpa.free(copy);
            try self.editor.loadText(copy, true);
        }
        self.checker.sync(&self.props);
    }

    fn onInner(self: *TextArea, ev: *event.Event) void {
        self.out.changed = true;
        self.out.change_count +%= 1;
        if (self.props.on_change) |cb| cb.invoke(ev);
    }

    // ---- content ----

    /// Replace the content with `bytes` (`owned`: an allocation from the Ui's
    /// allocator, handed over). Does not call `on_change`.
    pub fn loadText(self: *TextArea, bytes: []const u8, owned: bool) !void {
        try self.editor.loadText(bytes, owned);
    }

    pub fn setText(self: *TextArea, text: []const u8) !void {
        const copy = try self.ui.gpa.dupe(u8, text);
        errdefer self.ui.gpa.free(copy);
        try self.editor.loadText(copy, true);
    }

    /// A copy of the content, allocated with `gpa` (you free it).
    pub fn textAlloc(self: *TextArea, gpa: std.mem.Allocator) ![]u8 {
        return self.editor.textAlloc(gpa);
    }

    // ---- widget plumbing ----

    pub fn handleEvent(self: *TextArea, ev: *event.Event) void {
        _ = self;
        _ = ev;
    }

    pub fn paintHook(self: *TextArea, pc: *PaintCtx) paint_ctx.Error!void {
        _ = self;
        _ = pc;
    }

    pub fn prepare(self: *TextArea) void {
        _ = self;
    }

    pub fn update(self: *TextArea) void {
        self.ui.verifyProps(self.node, &self.checker, &self.props, "text_area");
        if (self.editor.props.read_only != self.props.read_only) self.editor.props.read_only = self.props.read_only;
        if (self.editor.props.enabled != self.props.enabled) self.editor.props.enabled = self.props.enabled;
        self.out.focused = self.editor.out.focused;
        self.out.line_count = self.editor.out.line_count;
    }

    pub fn endFrame(self: *TextArea) void {
        self.out.changed = false;
    }
};

// ---- tests -----------------------------------------------------------------

const testing = std.testing;
const draw_list = @import("../core/draw_list.zig");

const Rig = struct {
    ui: Ui,
    cmds: [2048]draw_list.Command = undefined,
    glyphs: [2048]draw_list.Glyph = undefined,
    list: draw_list.DrawList = undefined,
    prop: @import("../text/font.zig").TestFont = .{},
    changes: u32 = 0,

    fn init() !*Rig {
        const r = try testing.allocator.create(Rig);
        r.* = .{ .ui = try Ui.init(testing.allocator) };
        _ = try r.ui.addFont(r.prop.backend());
        r.list = draw_list.DrawList.init(&r.cmds, &r.glyphs);
        r.ui.tree.get(r.ui.tree.root).?.style = .{ .align_items = .start, .direction = .column };
        return r;
    }

    fn deinit(self: *Rig) void {
        self.ui.deinit();
        testing.allocator.destroy(self);
    }

    fn frame(self: *Rig) !void {
        self.ui.update();
        try self.ui.layoutAndPaint(.{ .w = 400, .h = 300 }, &self.list);
        self.ui.endFrame();
    }

    fn onChange(self: *Rig, _: *event.Event) void {
        self.changes += 1;
    }
};

test "a text area holds several lines, reports edits, and round-trips its text" {
    const r = try Rig.init();
    defer r.deinit();
    const a = try r.ui.add(TextArea, r.ui.tree.root, .{
        .style = .{ .width = Length.px(200), .height = Length.px(90) },
        .text = "one\ntwo",
        .on_change = .bind(r, Rig.onChange),
    });
    try r.frame();
    try testing.expectEqual(@as(u32, 2), a.out.line_count);
    const t = try a.textAlloc(testing.allocator);
    defer testing.allocator.free(t);
    try testing.expectEqualStrings("one\ntwo", t);

    r.ui.setFocus(a.editor.node);
    try r.frame();
    r.ui.key(.end, .{ .ctrl = true }, true, false);
    r.ui.key(.enter, .{}, true, false);
    r.ui.textInput("three");
    try r.frame();
    try testing.expect(r.changes > 0);
    try testing.expect(a.out.change_count > 0);
    const t2 = try a.textAlloc(testing.allocator);
    defer testing.allocator.free(t2);
    try testing.expectEqualStrings("one\ntwo\nthree", t2);

    try a.setText("fresh");
    const t3 = try a.textAlloc(testing.allocator);
    defer testing.allocator.free(t3);
    try testing.expectEqualStrings("fresh", t3);
    // read_only is honored.
    a.props.read_only = true;
    try r.frame();
    const before = r.changes;
    r.ui.textInput("x");
    try r.frame();
    try testing.expectEqual(before, r.changes);
}
