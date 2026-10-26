//! Theme: colors and metrics plus the painter that turns widget state into a
//! look. Swapping a painter changes appearance with identical behavior.

const geometry = @import("../core/geometry.zig");
const Color = geometry.Color;
const Visual = @import("../core/style.zig").Visual;
const button = @import("button.zig");

pub const ButtonColors = struct {
    normal: Color,
    hover: Color,
    pressed: Color,
    disabled: Color,
    border: Color = Color.transparent,
    border_width: f32 = 0,
};

/// Turns a button's state into a `Visual`. Replace to restyle all buttons.
pub const ButtonPainter = *const fn (b: *const button.Button, theme: *const Theme) Visual;

pub const Theme = struct {
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
    button_painter: ButtonPainter = button.defaultPainter,
};
