//! Theme: colors and metrics plus the painter that turns widget state into a
//! look. Swapping a painter changes appearance with identical behavior.

const geometry = @import("../core/geometry.zig");
const Color = geometry.Color;
const Visual = @import("../core/style.zig").Visual;
const button = @import("button.zig");
const syntax = @import("../editor/syntax.zig");

pub const ButtonColors = struct {
    normal: Color,
    hover: Color,
    pressed: Color,
    disabled: Color,
    border: Color = Color.transparent,
    border_width: f32 = 0,
    text: Color = Color.rgb(0xdf, 0xe1, 0xe5),
    text_disabled: Color = Color.rgb(0x7a, 0x7d, 0x83),
};

/// Turns a button's state into a `Visual`. Replace to restyle all buttons.
pub const ButtonPainter = *const fn (b: *const button.Button, theme: *const Theme) Visual;

pub const FieldColors = struct {
    background: Color = Color.rgb(0x1e, 0x1f, 0x22),
    background_disabled: Color = Color.rgb(0x28, 0x2a, 0x2d),
    border: Color = Color.rgb(0x4a, 0x4d, 0x52),
    border_focus: Color = Color.rgb(0x35, 0x74, 0xf0),
    text: Color = Color.rgb(0xdf, 0xe1, 0xe5),
    text_disabled: Color = Color.rgb(0x7a, 0x7d, 0x83),
    placeholder: Color = Color.rgb(0x7a, 0x7d, 0x83),
    selection: Color = Color.rgba(0x35, 0x74, 0xf0, 0x90),
    caret: Color = Color.rgb(0xdf, 0xe1, 0xe5),
};

/// Default token colors, indexed by `syntax.TokenKind`.
fn defaultSyntaxColors() [syntax.token_kind_count]Color {
    var c: [syntax.token_kind_count]Color = undefined;
    c[@intFromEnum(syntax.TokenKind.plain)] = Color.rgb(0xd4, 0xd4, 0xd4);
    c[@intFromEnum(syntax.TokenKind.keyword)] = Color.rgb(0x56, 0x9c, 0xd6);
    c[@intFromEnum(syntax.TokenKind.type)] = Color.rgb(0x4e, 0xc9, 0xb0);
    c[@intFromEnum(syntax.TokenKind.function)] = Color.rgb(0xdc, 0xdc, 0xaa);
    c[@intFromEnum(syntax.TokenKind.builtin)] = Color.rgb(0xc5, 0x86, 0xc0);
    c[@intFromEnum(syntax.TokenKind.constant)] = Color.rgb(0x4f, 0xc1, 0xff);
    c[@intFromEnum(syntax.TokenKind.string)] = Color.rgb(0xce, 0x91, 0x78);
    c[@intFromEnum(syntax.TokenKind.number)] = Color.rgb(0xb5, 0xce, 0xa8);
    c[@intFromEnum(syntax.TokenKind.comment)] = Color.rgb(0x6a, 0x99, 0x55);
    c[@intFromEnum(syntax.TokenKind.doc_comment)] = Color.rgb(0x7f, 0xb8, 0x6a);
    c[@intFromEnum(syntax.TokenKind.operator)] = Color.rgb(0xc8, 0xc8, 0xc8);
    c[@intFromEnum(syntax.TokenKind.punctuation)] = Color.rgb(0xa8, 0xaa, 0xb0);
    c[@intFromEnum(syntax.TokenKind.preprocessor)] = Color.rgb(0xc5, 0x86, 0xc0);
    c[@intFromEnum(syntax.TokenKind.heading)] = Color.rgb(0x56, 0x9c, 0xd6);
    c[@intFromEnum(syntax.TokenKind.emphasis)] = Color.rgb(0xdc, 0xdc, 0xaa);
    return c;
}

pub const EditorColors = struct {
    /// Colors for syntax tokens, indexed by `syntax.TokenKind`. `plain` is the
    /// text color used when there is no highlighting.
    syntax: [syntax.token_kind_count]Color = defaultSyntaxColors(),

    background: Color = Color.rgb(0x1e, 0x1f, 0x22),
    gutter_background: Color = Color.rgb(0x1e, 0x1f, 0x22),
    gutter_text: Color = Color.rgb(0x6b, 0x6f, 0x76),
    gutter_text_active: Color = Color.rgb(0xc4, 0xc7, 0xcc),
    text: Color = Color.rgb(0xd4, 0xd4, 0xd4),
    current_line: Color = Color.rgb(0x26, 0x28, 0x2c),
    selection: Color = Color.rgba(0x35, 0x74, 0xf0, 0x80),
    selection_unfocused: Color = Color.rgba(0x6b, 0x6f, 0x76, 0x60),
    caret: Color = Color.rgb(0xe8, 0xea, 0xed),
    scrollbar: Color = Color.rgba(0xff, 0xff, 0xff, 0x28),

    pub fn tokenColor(self: *const EditorColors, kind: syntax.TokenKind) Color {
        return self.syntax[@intFromEnum(kind)];
    }
};

pub const Theme = struct {
    field: FieldColors = .{},
    editor: EditorColors = .{},
    /// Indexed by `button.Variant`.
    button_colors: [4]ButtonColors = .{
        // normal
        .{
            .normal = Color.rgb(0x4a, 0x4d, 0x52),
            .hover = Color.rgb(0x5a, 0x5d, 0x63),
            .pressed = Color.rgb(0x3a, 0x3c, 0x40),
            .disabled = Color.rgb(0x33, 0x35, 0x38),
        },
        // primary
        .{
            .normal = Color.rgb(0x35, 0x74, 0xf0),
            .hover = Color.rgb(0x4a, 0x85, 0xf5),
            .pressed = Color.rgb(0x2a, 0x5c, 0xc4),
            .disabled = Color.rgb(0x2b, 0x3f, 0x6b),
        },
        // danger
        .{
            .normal = Color.rgb(0xc0, 0x39, 0x2b),
            .hover = Color.rgb(0xd8, 0x4a, 0x3b),
            .pressed = Color.rgb(0x9a, 0x2c, 0x21),
            .disabled = Color.rgb(0x5a, 0x2b, 0x27),
        },
        // flat: a faint tint until hovered
        .{
            .normal = Color.rgb(0x31, 0x33, 0x37),
            .hover = Color.rgb(0x39, 0x3b, 0x40),
            .pressed = Color.rgb(0x2f, 0x31, 0x35),
            .disabled = Color.transparent,
        },
    },
    corner_radius: f32 = 6,
    focus_ring: Color = Color.rgb(0x9d, 0xc4, 0xff),
    focus_ring_width: f32 = 2,
    /// Font ids from `Ui.addFont`. Both default to font 0 until a mono font is added.
    ui_font: u32 = 0,
    mono_font: u32 = 0,
    /// Default em size for UI text, logical pixels.
    font_size: f32 = 14,
    text_color: Color = Color.rgb(0xdf, 0xe1, 0xe5),
    button_painter: ButtonPainter = button.defaultPainter,
};
