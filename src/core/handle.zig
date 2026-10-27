//! Generational handles. A handle is an index plus a generation counter, so a
//! stale handle (one whose slot was freed and reused) is detected instead of
//! silently aliasing a different object.
//!
//! An extern struct of two u32s, so a C facade can pass it by value.

const std = @import("std");

pub const Handle = extern struct {
    index: u32,
    generation: u32,

    /// Never refers to a live object. Generation 0 is never issued by a pool.
    pub const invalid: Handle = .{ .index = std.math.maxInt(u32), .generation = 0 };

    pub fn isNull(self: Handle) bool {
        return self.generation == 0;
    }

    pub fn eql(a: Handle, b: Handle) bool {
        return a.index == b.index and a.generation == b.generation;
    }
};

test "invalid handle is null and not equal to a real handle" {
    const real: Handle = .{ .index = 0, .generation = 1 };
    try std.testing.expect(Handle.invalid.isNull());
    try std.testing.expect(!real.isNull());
    try std.testing.expect(!Handle.eql(Handle.invalid, real));
    try std.testing.expect(Handle.eql(real, real));
}

test "handle has C-compatible size" {
    try std.testing.expectEqual(@as(usize, 8), @sizeOf(Handle));
}
