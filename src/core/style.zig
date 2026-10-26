//! Layout style carried by every node. Plain Zig (engine-side); the app edits
//! it through setters that mark the node layout-dirty.

const Length = @import("length.zig").Length;

pub const Direction = enum { row, column };

/// Alignment on either axis. `stretch` on the main axis behaves like `start`.
pub const Align = enum { start, center, end, stretch };

/// Four sides, each a `Length` (px, or percent of the parent's content width).
pub const Edges = extern struct {
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

/// Width, height, min, and max describe the border box (padding included).
pub const Style = struct {
    width: Length = Length.auto,
    height: Length = Length.auto,
    min_width: Length = Length.auto,
    max_width: Length = Length.auto,
    min_height: Length = Length.auto,
    max_height: Length = Length.auto,
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
};
