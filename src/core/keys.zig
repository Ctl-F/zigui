//! Platform-independent key identifiers and modifier bits.
//!
//! `Key` names the physical/logical keys the toolkit reacts to (navigation,
//! editing, letters for shortcuts). Platform shims translate their native
//! codes into it; anything unmapped is `.unknown`, and the raw platform codes
//! still travel in the event.

pub const Key = enum(u32) {
    unknown = 0,
    a, b, c, d, e, f, g, h, i, j, k, l, m,
    n, o, p, q, r, s, t, u, v, w, x, y, z,
    enter,
    escape,
    backspace,
    tab,
    space,
    delete,
    insert,
    left,
    right,
    up,
    down,
    home,
    end,
    page_up,
    page_down,
    f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12,
    _,
};

/// Modifier bits for `Event.mods`.
pub const mod_shift: u32 = 1 << 0;
pub const mod_ctrl: u32 = 1 << 1;
pub const mod_alt: u32 = 1 << 2;
/// Windows/Command/Super key.
pub const mod_gui: u32 = 1 << 3;
