//! Layout style carried by every node. Plain Zig (engine-side); the app edits
//! it through setters that mark the node layout-dirty.

const Length = @import("length.zig").Length;
const Color = @import("geometry.zig").Color;

pub const Direction = enum { row, column };

/// Alignment on either axis. `stretch` on the main axis behaves like `start`.
pub const Align = enum { start, center, end, stretch };

/// Four sides, each a `Length` (px, or percent of the parent's content width).
pub const Edges = struct {
    left: Length = Length.px(0),
    top: Length = Length.px(0),
    right: Length = Length.px(0),
    bottom: Length = Length.px(0),

    pub fn all(v: f32) Edges {
        const l = Length.px(v);
        return .{ .left = l, .top = l, .right = l, .bottom = l };
    }

    pub fn xy(x: f32, y: f32) Edges {
        return .{ .left = Length.px(x), .right = Length.px(x), .top = Length.px(y), .bottom = Length.px(y) };
    }
};

/// How a node takes part in its parent's layout.
pub const Position = enum {
    /// Laid out by the parent's flex rules, in order.
    flow,
    /// Taken out of the flow: placed against the parent's box by `inset`, not
    /// counted in the parent's size, drawn above earlier siblings.
    absolute,
};

/// Distances from the edges of the parent's box (padding included) for an
/// `absolute` node. `auto` leaves that side free: with both sides of an axis
/// set and the size `auto`, the node stretches between them.
pub const Insets = struct {
    left: Length = .auto,
    top: Length = .auto,
    right: Length = .auto,
    bottom: Length = .auto,
};

/// Width, height, min, and max describe the border box (padding included).
pub const Style = struct {
    width: Length = .auto,
    height: Length = .auto,
    min_width: Length = .auto,
    max_width: Length = .auto,
    min_height: Length = .auto,
    max_height: Length = .auto,
    grow: f32 = 0,
    shrink: f32 = 1,

    /// Main axis of this node's flex container behavior.
    direction: Direction = .row,
    gap: Length = Length.px(0),
    padding: Edges = .{},
    margin: Edges = .{},
    /// Cross-axis alignment of children.
    align_items: Align = .stretch,
    /// Main-axis placement of children when nothing grows.
    justify: Align = .start,
    /// Overrides the parent's `align_items` for this node.
    align_self: ?Align = null,
    /// Let children that do not fit along the main axis continue on a new line
    /// (needs a definite main-axis size; the container's own size is not
    /// grown to hold the extra lines).
    wrap: bool = false,
    position: Position = .flow,
    inset: Insets = .{},
    /// Make this node a grid: its flow children fill rows of this many
    /// equal-width columns, left to right, then top to bottom. 0 means a flex
    /// container (`direction`, `wrap`, ...). `gap` is used between rows and
    /// between columns; `align_items`/`align_self` align a child inside its
    /// cell (`.stretch` fills it).
    grid_columns: u16 = 0,
    /// For a child of a grid: how many columns it spans (at least 1).
    grid_span: u16 = 1,
    /// For a child of a grid: how many rows it spans (at least 1). Cells below
    /// a tall child are skipped when later children are placed.
    grid_row_span: u16 = 1,
};

/// Stopgap built-in look until painters and themes exist: a filled, optionally
/// rounded, optionally bordered box.
pub const Visual = struct {
    background: Color = Color.transparent,
    border_color: Color = Color.black,
    border_width: f32 = 0,
    /// Uniform corner radius in logical pixels.
    radius: f32 = 0,
};
