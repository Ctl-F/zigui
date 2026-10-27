//! Label: a line of text. State block with props the app writes and an `out`
//! block reporting the measured size.

const Handle = @import("../core/handle.zig").Handle;
const shadow = @import("../core/shadow.zig");
const Color = @import("../core/geometry.zig").Color;
const block = @import("../text/block.zig");

pub const Text = @import("common.zig").Text;
pub const Align = block.Align;

pub const Font = enum(u32) {
    /// The theme's UI font.
    ui = 0,
    /// The theme's monospace font.
    mono,
};

pub const Label = struct {
    props: Props = .{},
    out: Out = .{},
    node: Handle = Handle.invalid,

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
};
