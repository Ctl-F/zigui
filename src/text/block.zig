//! A shaped line of text attached to a node. Owned by the node (freed with it).

const draw_list = @import("../core/draw_list.zig");
const Color = @import("../core/geometry.zig").Color;

pub const Align = enum(u32) { start = 0, center, end };

/// Extras drawn with a text block: used by editable text. All x values are
/// relative to the text origin (before scrolling), in logical pixels.
pub const Decor = struct {
    /// How far the text is scrolled left inside its box.
    scroll_x: f32 = 0,
    sel_on: bool = false,
    sel_x0: f32 = 0,
    sel_x1: f32 = 0,
    caret_on: bool = false,
    caret_x: f32 = 0,

    pub fn active(self: Decor) bool {
        return self.sel_on or self.caret_on or self.scroll_x != 0;
    }
};

pub const TextBlock = struct {
    /// Glyph ids with pen positions relative to the line origin: x from the
    /// left edge, y = 0 on the baseline (logical pixels). Spaces are not emitted.
    glyphs: []draw_list.Glyph,
    width: f32,
    ascent: f32,
    descent: f32,
    line_height: f32,
    font: u32,
    size: f32,
    color: Color,
    align_x: Align = .start,
    /// Subpixel glyph positioning (proportional UI text) vs pixel snapping (monospace).
    subpixel: bool = true,
    decor: Decor = .{},
    /// Identity of the source string, so callers can tell when it changed.
    src_ptr: usize,
    src_len: usize,
};
