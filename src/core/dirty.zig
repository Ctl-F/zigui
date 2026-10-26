//! Categorical dirty flags: one small bitset per widget, not one flag per
//! property. Setters mark the right category automatically; apps that write
//! fields directly can call `mark` once at the end of their updates.

const std = @import("std");

pub const DirtyFlags = packed struct(u8) {
    /// Resolved style or theme lookup changed.
    style: bool = false,
    /// Size or position inputs changed: needs measure and layout.
    layout: bool = false,
    /// Only appearance changed: needs repaint.
    paint: bool = false,
    /// Hit-test geometry or interactivity changed.
    hit_test: bool = false,
    /// Children were added, removed, or reordered.
    children: bool = false,
    /// A descendant needs layout (set on ancestors up to a relayout boundary).
    child_layout: bool = false,
    /// A descendant needs repaint.
    child_paint: bool = false,
    _reserved: bool = false,

    pub const none: DirtyFlags = .{};
    /// The safe default when the app does not say what it changed.
    pub const layout_and_paint: DirtyFlags = .{ .layout = true, .paint = true };
    pub const paint_only: DirtyFlags = .{ .paint = true };
    pub const layout_only: DirtyFlags = .{ .layout = true };

    pub fn bits(self: DirtyFlags) u8 {
        return @bitCast(self);
    }

    pub fn fromBits(b: u8) DirtyFlags {
        return @bitCast(b);
    }

    pub fn isClean(self: DirtyFlags) bool {
        return self.bits() == 0;
    }

    pub fn merge(a: DirtyFlags, b: DirtyFlags) DirtyFlags {
        return fromBits(a.bits() | b.bits());
    }

    /// True if every flag in `needed` is also set in `self`.
    pub fn covers(self: DirtyFlags, needed: DirtyFlags) bool {
        return (self.bits() & needed.bits()) == needed.bits();
    }

    /// Flags in `needed` that `self` is missing.
    pub fn missing(self: DirtyFlags, needed: DirtyFlags) DirtyFlags {
        return fromBits(needed.bits() & ~self.bits());
    }

    pub fn clear(self: *DirtyFlags) void {
        self.* = .{};
    }

    /// True if the node itself must be laid out (as opposed to a descendant).
    pub fn needsLayout(self: DirtyFlags) bool {
        return self.layout or self.children or self.style;
    }

    pub fn needsPaint(self: DirtyFlags) bool {
        return self.paint or self.layout or self.style or self.children;
    }
};

test "default is clean" {
    try std.testing.expect(DirtyFlags.none.isClean());
}

test "merge and covers" {
    const a = DirtyFlags.paint_only;
    const b = DirtyFlags.layout_only;
    const both = a.merge(b);
    try std.testing.expect(both.paint and both.layout);
    try std.testing.expect(both.covers(DirtyFlags.layout_and_paint));
    try std.testing.expect(!a.covers(DirtyFlags.layout_and_paint));
}

test "missing reports what is absent" {
    const have = DirtyFlags.paint_only;
    const miss = have.missing(DirtyFlags.layout_and_paint);
    try std.testing.expect(miss.layout);
    try std.testing.expect(!miss.paint);
}

test "layout change implies repaint" {
    try std.testing.expect(DirtyFlags.layout_only.needsPaint());
    try std.testing.expect(!DirtyFlags.paint_only.needsLayout());
}

test "flags fit in one byte" {
    try std.testing.expectEqual(@as(usize, 1), @sizeOf(DirtyFlags));
}
