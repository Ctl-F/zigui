//! TextField: single-line editable text. State block plus editing behavior.
//!
//! The content lives in toolkit-owned storage; read it with `Ui.textFieldText`
//! and set it with `Ui.setTextFieldText`. `out.changed` / `out.submitted` are
//! frame-scoped, the counters only grow, and the callbacks come from the same
//! events, so polling and callbacks never disagree. Programmatic changes via
//! `setTextFieldText` do not count as edits.
//!
//! Editing: typing, Backspace/Delete, arrows, Home/End, Ctrl/Alt+arrows and
//! Ctrl/Alt+Backspace/Delete by word, Shift to select, Ctrl+A/C/X/V (Cmd on
//! macOS too), mouse click/drag, double-click for a word, triple-click for all,
//! Enter to submit. Not yet: undo/redo, IME composition display, password mode,
//! max length.

const Handle = @import("../core/handle.zig").Handle;
const shadow = @import("../core/shadow.zig");
const event = @import("../core/event.zig");
const label = @import("label.zig");

pub const Text = @import("common.zig").Text;
pub const Font = label.Font;

pub const TextField = struct {
    props: Props = .{},
    out: Out = .{},
    node: Handle = Handle.invalid,

    pub const Props = struct {
        /// Shown, dimmed, while the field is empty.
        placeholder: Text = .{},
        enabled: bool = true,
        read_only: bool = false,
        font: Font = .ui,
        /// Em size in logical pixels; 0 uses the theme's size.
        size: f32 = 0,
        on_change: ?event.Callback = null,
        on_submit: ?event.Callback = null,

        pub const dirty_map = .{
            .placeholder = shadow.Category.layout,
            .enabled = shadow.Category.paint,
            .read_only = shadow.Category.paint,
            .font = shadow.Category.layout,
            .size = shadow.Category.layout,
        };
    };

    pub const Out = struct {
        /// The user edited the text this frame.
        changed: bool = false,
        /// Enter was pressed this frame.
        submitted: bool = false,
        focused: bool = false,
        hovered: bool = false,
        change_count: u32 = 0,
        submit_count: u32 = 0,
        /// Caret and selection as byte offsets into the text.
        caret: u32 = 0,
        sel_start: u32 = 0,
        sel_end: u32 = 0,
    };
};
