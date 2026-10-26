//! zigui: a lightweight, retained-mode, cross-platform UI toolkit for Zig.
//!
//! Boundary rule: anything the app sees or touches is `extern` (handles,
//! geometry, lengths, draw records). Anything only the engine touches (the
//! node tree, pool internals) is plain Zig.

pub const handle = @import("core/handle.zig");
pub const pool = @import("core/pool.zig");
pub const geometry = @import("core/geometry.zig");
pub const length = @import("core/length.zig");
pub const flex = @import("core/flex.zig");
pub const dirty = @import("core/dirty.zig");
pub const tree = @import("core/tree.zig");
pub const style = @import("core/style.zig");
pub const layout = @import("core/layout.zig");
pub const paint = @import("core/paint.zig");
pub const software = @import("render/software.zig");
pub const png = @import("render/png.zig");
pub const shadow = @import("core/shadow.zig");
pub const draw_list = @import("core/draw_list.zig");

pub const Handle = handle.Handle;
pub const Pool = pool.Pool;
pub const Rect = geometry.Rect;
pub const Vec2 = geometry.Vec2;
pub const Color = geometry.Color;
pub const Length = length.Length;
pub const DirtyFlags = dirty.DirtyFlags;
pub const Tree = tree.Tree;
pub const Style = style.Style;
pub const Layout = layout.Layout;
pub const DrawList = draw_list.DrawList;

test {
    // Pull in the tests of every module.
    @import("std").testing.refAllDecls(@This());
}
