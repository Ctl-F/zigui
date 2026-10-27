//! Label: a line of text. Props the app writes, an `out` block reporting the
//! measured size, and a `ui` back-pointer (the `Ui` must not move).

const Handle = @import("../core/handle.zig").Handle;
const shadow = @import("../core/shadow.zig");
const DirtyFlags = @import("../core/dirty.zig").DirtyFlags;
const Color = @import("../core/geometry.zig").Color;
const block = @import("../text/block.zig");
const Ui = @import("../core/ui.zig").Ui;
const paint_ctx = @import("../core/paint_ctx.zig");
const PaintCtx = paint_ctx.PaintCtx;
const Style = @import("../core/style.zig").Style;
const Node = @import("../core/tree.zig").Node;

pub const Text = @import("common.zig").Text;
pub const Align = block.Align;

/// Draws a label (it has no box; the default just picks the text color).
pub const Painter = *const fn (ctx: *PaintCtx, l: *const Label) paint_ctx.Error!void;

pub const Font = enum {
    /// The theme's UI font.
    ui,
    /// The theme's monospace font.
    mono,
};

pub const Label = struct {
    props: Props = .{},
    out: Out = .{},
    node: Handle,
    ui: *Ui,
    /// Internal: verifies raw `props` writes (empty unless `ui_checks` is on).
    checker: shadow.Checker(Props),

    pub const Props = struct {
        text: Text = .{},
        font: Font = .ui,
        /// Em size in logical pixels; 0 uses the theme's size.
        size: f32 = 0,
        /// Fully transparent (alpha 0) uses the theme's text color.
        color: Color = Color.transparent,
        text_align: Align = .start,
        /// Overrides the theme's label painter for this label (use `setPainter`).
        painter: ?Painter = null,

        pub const dirty_map = .{
            .text = shadow.Category.layout,
            .font = shadow.Category.layout,
            .size = shadow.Category.layout,
            .color = shadow.Category.paint,
            .text_align = shadow.Category.paint,
        };
    };

    pub const Out = struct {
        /// Measured size of the text line in logical pixels.
        text_width: f32 = 0,
        text_height: f32 = 0,
    };

    pub const Options = struct {
        style: Style = .{},
        text: []const u8 = "",
        font: Font = .ui,
        size: f32 = 0,
        color: Color = Color.transparent,
        text_align: Align = .start,
        painter: ?Painter = null,
    };

    pub const listened_kinds = [_]@import("../core/event.zig").EventKind{};

    pub fn nodeTemplate(style: Style) Node {
        return .{ .role = .label, .style = style };
    }

    pub fn apply(self: *Label, o: Options) !void {
        self.props.font = o.font;
        self.props.size = o.size;
        self.props.color = o.color;
        self.props.text_align = o.text_align;
        self.props.painter = o.painter;
        if (o.text.len > 0) try self.setText(o.text);
        self.checker.sync(&self.props);
    }

    /// Labels have no events.
    pub fn handleEvent(self: *Label, ev: *@import("../core/event.zig").Event) void {
        _ = self;
        _ = ev;
    }

    pub fn init(ui: *Ui, node: Handle) Label {
        const props: Props = .{};
        return .{ .node = node, .ui = ui, .checker = shadow.Checker(Props).init(&props) };
    }

    pub fn deinit(self: *Label) void {
        self.ui.freeText(&self.props.text);
    }

    /// Copy `text` into toolkit-owned storage; the caller may free its own copy.
    pub fn setText(self: *Label, text: []const u8) !void {
        try self.ui.replaceText(&self.props.text, text);
        self.ui.tree.markDirty(self.node, DirtyFlags.layout_and_paint);
    }

    /// The node's painter hook: runs this label's painter, else the theme's.
    pub fn paintHook(self: *Label, pc: *PaintCtx) paint_ctx.Error!void {
        const p = self.props.painter orelse self.ui.theme.label_painter;
        try p(pc, self);
    }

    pub fn setPainter(self: *Label, p: ?Painter) void {
        self.props.painter = p;
        self.ui.tree.markDirty(self.node, DirtyFlags.paint_only);
    }

    pub fn prepare(self: *Label) void {
        _ = self;
    }

    pub fn update(self: *Label) void {
        const ui = self.ui;
        ui.verifyProps(self.node, &self.checker, &self.props, "label");
        const f = switch (self.props.font) {
            .ui => ui.theme.ui_font,
            .mono => ui.theme.mono_font,
        };
        const size = if (self.props.size > 0) self.props.size else ui.theme.font_size;
        const color = if (self.props.color.a != 0) self.props.color else ui.theme.text_color;
        ui.syncText(self.node, self.props.text, f, size, color, self.props.text_align);
        if (ui.tree.get(self.node).?.text) |t| {
            self.out.text_width = t.width;
            self.out.text_height = t.line_height;
        }
    }

    pub fn endFrame(self: *Label) void {
        _ = self;
    }
};

/// The default look: no box; text in `props.color`, or the theme's text color.
pub fn defaultPainter(pc: *PaintCtx, l: *const Label) paint_ctx.Error!void {
    pc.text_color = if (l.props.color.a != 0) l.props.color else l.ui.theme.text_color;
}
