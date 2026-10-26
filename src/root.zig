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
pub const event = @import("core/event.zig");
pub const dispatch = @import("core/dispatch.zig");
pub const keys = @import("core/keys.zig");
pub const commands = @import("core/commands.zig");
pub const shortcuts = @import("core/shortcuts.zig");
pub const input = @import("core/input.zig");
pub const ui = @import("core/ui.zig");
pub const button = @import("widgets/button.zig");
pub const theme = @import("widgets/theme.zig");
pub const font = @import("text/font.zig");
pub const atlas = @import("text/atlas.zig");
pub const text = @import("text/system.zig");
pub const label = @import("widgets/label.zig");
pub const text_field = @import("widgets/text_field.zig");
pub const common = @import("widgets/common.zig");
pub const gap_buffer = @import("text/gap_buffer.zig");
pub const line_editor = @import("text/line_editor.zig");
pub const text_block = @import("text/block.zig");
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
pub const Ui = ui.Ui;
pub const Button = button.Button;
pub const Label = label.Label;
pub const TextField = text_field.TextField;
pub const Theme = theme.Theme;
pub const Event = event.Event;
pub const EventKind = event.EventKind;
pub const Layout = layout.Layout;
pub const DrawList = draw_list.DrawList;

test {
    // Pull in the tests of every module.
    @import("std").testing.refAllDecls(@This());
}
