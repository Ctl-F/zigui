//! Clipboard access supplied by the platform layer.

const std = @import("std");

pub const Clipboard = struct {
    ctx: ?*anyopaque = null,
    /// Returns the clipboard text allocated with `gpa`, or null if empty/unavailable.
    get: *const fn (ctx: ?*anyopaque, gpa: std.mem.Allocator) ?[]u8,
    set: *const fn (ctx: ?*anyopaque, text: []const u8) void,
};
