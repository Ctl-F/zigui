//! Label: a line of text. Props the app writes, an `out` block reporting the
//! measured size, and a `ui` back-pointer (the `Ui` must not move).

const Handle = @import("../core/handle.zig").Handle;
const shadow = @import("../core/shadow.zig");
const DirtyFlags = @import("../core/dirty.zig").DirtyFlags;
const Color = @import("../core/geometry.zig").Color;
const block = @import("../text/block.zig");
const Ui = @import("../core/ui.zig").Ui;

pub const Text = @import("common.zig").Text;
pub const Align = block.Align;

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

    pub const listened_kinds = [_]@import("../core/event.zig").EventKind{};

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
