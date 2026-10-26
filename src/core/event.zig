//! Event records and listeners. Everything here is `extern`: it crosses the
//! app boundary (handlers receive an `*Event`, and may be plain C functions).
//!
//! Flow follows the DOM model: capture (root toward target), target, then
//! bubble (target toward root). A handler may call `stopPropagation` (finish
//! the current node, then stop) or `markHandled`.

const Handle = @import("handle.zig").Handle;
const keys = @import("keys.zig");

pub const EventKind = enum(u32) {
    pointer_down = 0,
    pointer_up,
    pointer_move,
    /// Pointer entered the node or one of its descendants. Does not bubble.
    pointer_enter,
    /// Pointer left the node and all its descendants. Does not bubble.
    pointer_leave,
    /// Press and release on the same node (or within its subtree).
    click,
    wheel,
    key_down,
    key_up,
    focus_in,
    focus_out,
    /// Committed text (typing, paste, IME). Separate from key events. `text`
    /// and `text_len` hold UTF-8 valid only during dispatch.
    text_input,
    _,

    pub fn bubbles(self: EventKind) bool {
        return switch (self) {
            .pointer_enter, .pointer_leave, .focus_in, .focus_out => false,
            else => true,
        };
    }

    /// Kinds that make a node take part in hit-testing when a listener is attached.
    pub fn isPointer(self: EventKind) bool {
        return switch (self) {
            .pointer_down, .pointer_up, .pointer_move, .pointer_enter, .pointer_leave, .click, .wheel => true,
            else => false,
        };
    }
};

pub const Phase = enum(u32) { capture = 0, target, bubble };

pub const Event = extern struct {
    kind: EventKind,
    phase: Phase = .target,
    /// Node the event was aimed at.
    target: Handle = Handle.invalid,
    /// Node whose listener is running right now.
    current: Handle = Handle.invalid,
    /// Pointer position in window (logical) coordinates.
    x: f32 = 0,
    y: f32 = 0,
    /// Pointer position relative to `current`'s top-left corner.
    local_x: f32 = 0,
    local_y: f32 = 0,
    /// Wheel delta.
    dx: f32 = 0,
    dy: f32 = 0,
    /// Pointer button (1 = left) for pointer events.
    button: u32 = 0,
    scancode: u32 = 0,
    keycode: u32 = 0,
    /// Toolkit key for key events (`.unknown` if unmapped).
    key: keys.Key = .unknown,
    /// `keys.mod_*` bits held during the event.
    mods: u32 = 0,
    /// Consecutive press count for pointer_down (2 = double click).
    clicks: u32 = 0,
    text: ?[*]const u8 = null,
    text_len: usize = 0,
    repeat: bool = false,
    handled: bool = false,
    stopped: bool = false,

    pub fn hasMod(self: *const Event, mod: u32) bool {
        return self.mods & mod != 0;
    }

    pub fn textSlice(self: *const Event) []const u8 {
        const p = self.text orelse return "";
        return p[0..self.text_len];
    }

    pub fn stopPropagation(self: *Event) void {
        self.stopped = true;
    }

    pub fn markHandled(self: *Event) void {
        self.handled = true;
    }
};

pub const Handler = *const fn (ev: *Event, user_data: ?*anyopaque) callconv(.c) void;

pub const Listener = extern struct {
    kind: EventKind,
    /// Fire during the capture phase instead of the bubble phase. Listeners on
    /// the target itself fire regardless.
    capture: bool = false,
    callback: Handler,
    user_data: ?*anyopaque = null,
};
