//! Event records and listeners (`Callback`).
//!
//! Flow follows the DOM model: capture (root toward target), target, then
//! bubble (target toward root). A handler may call `stopPropagation` (finish
//! the current node, then stop) or `markHandled`.

const Handle = @import("handle.zig").Handle;
const keys = @import("keys.zig");

pub const EventKind = enum {
    pointer_down,
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
    /// holds UTF-8 valid only during dispatch.
    text_input,
    /// IME composition in progress: `text` is the uncommitted string (empty when
    /// composition ends or is cancelled) and `preedit_cursor` the byte offset of
    /// the IME's caret inside it. The final text arrives as `text_input`.
    text_editing,
    /// A named command is being run (from a shortcut, a button, a menu, or code).
    /// `text` holds the command name. Delivered straight to the command's
    /// handler, not through the tree.
    command,

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

pub const Phase = enum { capture, target, bubble };

pub const Event = struct {
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
    /// Modifier keys held during the event.
    mods: keys.Mods = .{},
    /// Consecutive press count for pointer_down (2 = double click).
    clicks: u32 = 0,
    /// UTF-8 for `text_input` events (and the name for `command` events); only
    /// valid while the event is being dispatched.
    text: []const u8 = "",
    /// For `text_editing`: byte offset of the IME caret within `text`.
    preedit_cursor: u32 = 0,
    repeat: bool = false,
    handled: bool = false,
    stopped: bool = false,

    pub fn stopPropagation(self: *Event) void {
        self.stopped = true;
    }

    pub fn markHandled(self: *Event) void {
        self.handled = true;
    }
};

/// A callback: a function plus the context it receives first. Build one with
/// `bind` (typed context) or `fromFn` (no context). Shadow checking skips any
/// struct that declares `is_callback`, since changing a handler needs no layout
/// or paint.
pub const Callback = struct {
    ctx: ?*anyopaque = null,
    call: *const fn (ctx: ?*anyopaque, ev: *Event) void,

    pub const is_callback = true;

    /// `Callback.bind(&app, App.onSave)` where `onSave` is `fn (*App, *Event) void`.
    pub fn bind(ctx: anytype, comptime f: anytype) Callback {
        const Ptr = @TypeOf(ctx);
        return .{
            .ctx = @ptrCast(ctx),
            .call = &struct {
                fn thunk(c: ?*anyopaque, ev: *Event) void {
                    f(@as(Ptr, @ptrCast(@alignCast(c.?))), ev);
                }
            }.thunk,
        };
    }

    /// For callbacks that need no context: `fn (*Event) void`.
    pub fn fromFn(comptime f: fn (*Event) void) Callback {
        return .{ .call = &struct {
            fn thunk(_: ?*anyopaque, ev: *Event) void {
                f(ev);
            }
        }.thunk };
    }

    pub fn eql(a: Callback, b: Callback) bool {
        return a.ctx == b.ctx and a.call == b.call;
    }

    pub fn invoke(self: Callback, ev: *Event) void {
        self.call(self.ctx, ev);
    }
};

pub const Listener = struct {
    kind: EventKind,
    /// Fire during the capture phase instead of the bubble phase. Listeners on
    /// the target itself fire regardless.
    capture: bool = false,
    callback: Callback,
};
