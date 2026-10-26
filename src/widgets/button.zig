//! Button: a state block with a stable address plus its event handling.
//!
//! The app reads and writes `props`; the toolkit writes `out`. `out.clicked`
//! is frame-scoped (cleared by `Ui.endFrame`) and `out.click_count` only ever
//! grows, so apps that poll less often than they render do not miss clicks.
//! Callbacks and flags come from the same click event and cannot disagree.
//!
//! Text is stored but not drawn yet: there is no text renderer.

const std = @import("std");
const Handle = @import("../core/handle.zig").Handle;
const event = @import("../core/event.zig");
const shadow = @import("../core/shadow.zig");
const Visual = @import("../core/style.zig").Visual;
const Theme = @import("theme.zig").Theme;

pub const Variant = enum(u32) { normal = 0, primary, danger, flat };

/// Toolkit-owned string: set it through `Ui.setButtonText`, which copies.
pub const Text = extern struct {
    ptr: ?[*]const u8 = null,
    len: usize = 0,

    pub fn slice(self: Text) []const u8 {
        const p = self.ptr orelse return "";
        return p[0..self.len];
    }
};

pub const Button = extern struct {
    props: Props = .{},
    out: Out = .{},
    node: Handle = Handle.invalid,

    pub const Props = extern struct {
        text: Text = .{},
        enabled: bool = true,
        variant: Variant = .normal,
        on_click: ?event.Handler = null,
        on_click_user: ?*anyopaque = null,

        pub const dirty_map = .{
            .text = shadow.Category.layout,
            .enabled = shadow.Category.paint,
            .variant = shadow.Category.paint,
        };
    };

    pub const Out = extern struct {
        /// A click happened this frame.
        clicked: bool = false,
        hovered: bool = false,
        pressed: bool = false,
        /// Total clicks since creation.
        click_count: u32 = 0,
    };
};

/// Shared listener for every button event kind; `user_data` is the `*Button`.
pub fn handleEvent(ev: *event.Event, user: ?*anyopaque) callconv(.c) void {
    const b: *Button = @ptrCast(@alignCast(user.?));
    switch (ev.kind) {
        .pointer_enter => b.out.hovered = true,
        .pointer_leave => b.out.hovered = false,
        .pointer_down => if (b.props.enabled) {
            b.out.pressed = true;
        },
        .pointer_up => b.out.pressed = false,
        .click => if (b.props.enabled) {
            b.out.clicked = true;
            b.out.click_count +%= 1;
            if (b.props.on_click) |cb| cb(ev, b.props.on_click_user);
        },
        else => {},
    }
}

pub const listened_kinds = [_]event.EventKind{ .pointer_enter, .pointer_leave, .pointer_down, .pointer_up, .click };

pub fn defaultPainter(b: *const Button, theme: *const Theme) Visual {
    const idx: usize = @intFromEnum(b.props.variant);
    const c = theme.button_colors[@min(idx, theme.button_colors.len - 1)];
    const bg = if (!b.props.enabled)
        c.disabled
    else if (b.out.pressed)
        c.pressed
    else if (b.out.hovered)
        c.hover
    else
        c.normal;
    return .{
        .background = bg,
        .border_color = c.border,
        .border_width = c.border_width,
        .radius = theme.corner_radius,
    };
}
