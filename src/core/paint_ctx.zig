//! The context a painter draws into.
//!
//! A painter is a function that takes a widget's state and a `PaintCtx` and
//! emits draw commands for the widget's box (and, if it wants, more). The
//! engine then draws the node's text on top, using any color overrides the
//! painter set. So a theme can restyle a widget completely, or just recolor it,
//! without touching the widget's behavior.

const draw_list = @import("draw_list.zig");
const geometry = @import("geometry.zig");
const Visual = @import("style.zig").Visual;
const Rect = geometry.Rect;
const Color = geometry.Color;

pub const Error = draw_list.Error;

pub const PaintCtx = struct {
    list: *draw_list.DrawList,
    /// The node's rect in window coordinates.
    rect: Rect,
    /// If set, the node's text is drawn in this color instead of the color it
    /// was shaped with. Painters use it to react to state (disabled, hovered).
    text_color: ?Color = null,
    /// Colors for a text field's selection highlight and caret. Transparent
    /// (the default) draws nothing.
    selection_color: Color = Color.transparent,
    caret_color: Color = Color.transparent,

    /// Draw a filled, optionally rounded, optionally bordered box over `rect`.
    pub fn box(self: *PaintCtx, v: Visual) Error!void {
        const paint = draw_list.Paint.solid(v.background);
        if (v.background.a != 0) {
            if (v.radius > 0) {
                try self.list.fillRoundedRect(self.rect, .{ v.radius, v.radius, v.radius, v.radius }, paint);
            } else {
                try self.list.fillRect(self.rect, paint);
            }
        }
        if (v.border_width > 0 and v.border_color.a != 0) {
            try self.list.strokeRoundedRect(self.rect, v.border_width, v.radius, draw_list.Paint.solid(v.border_color));
        }
    }
};
