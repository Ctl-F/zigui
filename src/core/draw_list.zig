//! The draw list: a flat, append-only buffer of fixed-size command records.
//!
//! - Every record is the same size, so the list is cheap to build, cache per
//!   repaint boundary, replay into a damage rect, and hand across the C ABI.
//! - Variable-size data (glyphs) lives in a side array that commands refer to
//!   by offset and count.
//! - Capacity is fixed at startup. Appending never allocates, which keeps the
//!   frame path free of dynamic allocation. When full, `push` returns an error
//!   instead of growing.
//!
//! Coordinates are floats in logical pixels. Fills take a `Paint`, so every
//! shape gets solid colors and gradients without duplicate commands.
//!
//! TODO: monospace run record (start, cell width, glyph ids only) for the
//! editor fast path; nine-slice and image commands; path commands.

const std = @import("std");
const geometry = @import("geometry.zig");
const Rect = geometry.Rect;
const Vec2 = geometry.Vec2;
const Color = geometry.Color;

pub const CommandKind = enum(u32) {
    fill_rect = 0,
    stroke_rect,
    fill_rounded_rect,
    line,
    push_clip,
    pop_clip,
    push_opacity,
    pop_opacity,
    glyph_run,
    _,
};

pub const PaintKind = enum(u32) {
    solid = 0,
    linear_gradient,
    radial_gradient,
    image_pattern,
    _,
};

/// What a shape is filled with. For gradients, `color`/`color2` are the end
/// colors and `p0`/`p1` the gradient line (or center and radius vector).
/// For image patterns, `aux` is an opaque texture handle from the backend.
pub const Paint = extern struct {
    kind: PaintKind = .solid,
    color: Color = Color.black,
    color2: Color = Color.transparent,
    p0: Vec2 = .{},
    p1: Vec2 = .{},
    aux: u32 = 0,

    pub fn solid(c: Color) Paint {
        return .{ .kind = .solid, .color = c };
    }

    pub fn linear(from: Vec2, to: Vec2, c0: Color, c1: Color) Paint {
        return .{ .kind = .linear_gradient, .color = c0, .color2 = c1, .p0 = from, .p1 = to };
    }
};

/// One positioned glyph in the side array.
pub const Glyph = extern struct {
    id: u32,
    x: f32,
    y: f32,
};

/// Fixed-size command record.
///
/// Field use by kind:
///   fill_rect:         rect, paint
///   stroke_rect:       rect, paint, params[0] = stroke width (drawn inside the rect),
///                      params[1] = uniform corner radius
///   fill_rounded_rect: rect, paint, params = corner radii (tl, tr, br, bl)
///   line:              rect.x/y = start, rect.w/h = end point, params[0] = width
///   push_clip:         rect
///   push_opacity:      params[0] = opacity 0..1
///   glyph_run:         a = glyph offset, b = glyph count, rect = bounds,
///                      paint = text color, aux via params[0] = font id,
///                      params[1] = font size
pub const Command = extern struct {
    kind: CommandKind,
    a: u32 = 0,
    b: u32 = 0,
    rect: Rect = .{},
    paint: Paint = .{},
    params: [4]f32 = .{ 0, 0, 0, 0 },
};

comptime {
    // The record size is part of the ABI. Change deliberately.
    std.debug.assert(@sizeOf(Command) == 76);
    std.debug.assert(@sizeOf(Glyph) == 12);
    std.debug.assert(@sizeOf(Paint) == 32);
}

pub const Error = error{
    DrawListFull,
    GlyphBufferFull,
};

pub const DrawList = struct {
    commands: []Command,
    glyphs: []Glyph,
    len: usize = 0,
    glyph_len: usize = 0,
    clip_depth: u32 = 0,
    opacity_depth: u32 = 0,

    /// Wrap caller-provided storage. No allocation happens here or later.
    pub fn init(commands: []Command, glyphs: []Glyph) DrawList {
        return .{ .commands = commands, .glyphs = glyphs };
    }

    /// Start a new frame. Keeps all capacity.
    pub fn reset(self: *DrawList) void {
        self.len = 0;
        self.glyph_len = 0;
        self.clip_depth = 0;
        self.opacity_depth = 0;
    }

    pub fn items(self: *const DrawList) []const Command {
        return self.commands[0..self.len];
    }

    pub fn glyphItems(self: *const DrawList) []const Glyph {
        return self.glyphs[0..self.glyph_len];
    }

    /// True when every push has a matching pop.
    pub fn isBalanced(self: *const DrawList) bool {
        return self.clip_depth == 0 and self.opacity_depth == 0;
    }

    pub fn push(self: *DrawList, cmd: Command) Error!void {
        if (self.len == self.commands.len) return error.DrawListFull;
        self.commands[self.len] = cmd;
        self.len += 1;
    }

    pub fn fillRect(self: *DrawList, rect: Rect, paint: Paint) Error!void {
        try self.push(.{ .kind = .fill_rect, .rect = rect, .paint = paint });
    }

    pub fn strokeRect(self: *DrawList, rect: Rect, width: f32, paint: Paint) Error!void {
        try self.strokeRoundedRect(rect, width, 0, paint);
    }

    pub fn strokeRoundedRect(self: *DrawList, rect: Rect, width: f32, radius: f32, paint: Paint) Error!void {
        try self.push(.{ .kind = .stroke_rect, .rect = rect, .paint = paint, .params = .{ width, radius, 0, 0 } });
    }

    /// `radii` is top-left, top-right, bottom-right, bottom-left.
    pub fn fillRoundedRect(self: *DrawList, rect: Rect, radii: [4]f32, paint: Paint) Error!void {
        try self.push(.{ .kind = .fill_rounded_rect, .rect = rect, .paint = paint, .params = radii });
    }

    pub fn line(self: *DrawList, from: Vec2, to: Vec2, width: f32, paint: Paint) Error!void {
        try self.push(.{
            .kind = .line,
            .rect = .{ .x = from.x, .y = from.y, .w = to.x, .h = to.y },
            .paint = paint,
            .params = .{ width, 0, 0, 0 },
        });
    }

    pub fn pushClip(self: *DrawList, rect: Rect) Error!void {
        try self.push(.{ .kind = .push_clip, .rect = rect });
        self.clip_depth += 1;
    }

    /// Returns false (and records nothing) if there is no clip to pop.
    pub fn popClip(self: *DrawList) Error!bool {
        if (self.clip_depth == 0) return false;
        try self.push(.{ .kind = .pop_clip });
        self.clip_depth -= 1;
        return true;
    }

    pub fn pushOpacity(self: *DrawList, opacity: f32) Error!void {
        try self.push(.{ .kind = .push_opacity, .params = .{ opacity, 0, 0, 0 } });
        self.opacity_depth += 1;
    }

    pub fn popOpacity(self: *DrawList) Error!bool {
        if (self.opacity_depth == 0) return false;
        try self.push(.{ .kind = .pop_opacity });
        self.opacity_depth -= 1;
        return true;
    }

    /// Append a run of pre-shaped glyphs. The glyphs are copied into the side
    /// array, so the caller's slice can be reused immediately.
    pub fn glyphRun(
        self: *DrawList,
        bounds: Rect,
        run: []const Glyph,
        color: Color,
        font_id: u32,
        font_size: f32,
    ) Error!void {
        if (self.glyph_len + run.len > self.glyphs.len) return error.GlyphBufferFull;
        if (self.len == self.commands.len) return error.DrawListFull;

        const offset = self.glyph_len;
        @memcpy(self.glyphs[offset .. offset + run.len], run);
        self.glyph_len += run.len;

        try self.push(.{
            .kind = .glyph_run,
            .a = @intCast(offset),
            .b = @intCast(run.len),
            .rect = bounds,
            .paint = Paint.solid(color),
            .params = .{ @floatFromInt(font_id), font_size, 0, 0 },
        });
    }
};

/// Owns the backing buffers. Allocate once at startup; `list()` hands out a
/// DrawList that never allocates.
pub const Storage = struct {
    allocator: std.mem.Allocator,
    commands: []Command,
    glyphs: []Glyph,

    pub fn init(allocator: std.mem.Allocator, command_capacity: usize, glyph_capacity: usize) !Storage {
        const commands = try allocator.alloc(Command, command_capacity);
        errdefer allocator.free(commands);
        const glyphs = try allocator.alloc(Glyph, glyph_capacity);
        return .{ .allocator = allocator, .commands = commands, .glyphs = glyphs };
    }

    pub fn deinit(self: *Storage) void {
        self.allocator.free(self.commands);
        self.allocator.free(self.glyphs);
        self.* = undefined;
    }

    pub fn list(self: *Storage) DrawList {
        return DrawList.init(self.commands, self.glyphs);
    }
};

test "records are appended in order" {
    var storage = try Storage.init(std.testing.allocator, 16, 16);
    defer storage.deinit();
    var dl = storage.list();

    const r: Rect = .{ .x = 1, .y = 2, .w = 3, .h = 4 };
    try dl.fillRect(r, Paint.solid(Color.white));
    try dl.strokeRect(r, 2, Paint.solid(Color.black));
    try dl.fillRoundedRect(r, .{ 4, 4, 0, 0 }, Paint.solid(Color.black));

    const cmds = dl.items();
    try std.testing.expectEqual(@as(usize, 3), cmds.len);
    try std.testing.expectEqual(CommandKind.fill_rect, cmds[0].kind);
    try std.testing.expectEqual(CommandKind.stroke_rect, cmds[1].kind);
    try std.testing.expectEqual(@as(f32, 2), cmds[1].params[0]);
    try std.testing.expectEqual(@as(f32, 4), cmds[2].params[0]);
}

test "full list returns an error instead of allocating" {
    var storage = try Storage.init(std.testing.allocator, 2, 0);
    defer storage.deinit();
    var dl = storage.list();

    const r: Rect = .{ .w = 1, .h = 1 };
    try dl.fillRect(r, .{});
    try dl.fillRect(r, .{});
    try std.testing.expectError(error.DrawListFull, dl.fillRect(r, .{}));
    try std.testing.expectEqual(@as(usize, 2), dl.items().len);
}

test "reset keeps capacity and clears state" {
    var storage = try Storage.init(std.testing.allocator, 4, 4);
    defer storage.deinit();
    var dl = storage.list();

    try dl.pushClip(.{ .w = 10, .h = 10 });
    try std.testing.expect(!dl.isBalanced());
    dl.reset();
    try std.testing.expectEqual(@as(usize, 0), dl.items().len);
    try std.testing.expect(dl.isBalanced());
    try std.testing.expectEqual(@as(usize, 4), dl.commands.len);
}

test "clip and opacity pushes and pops balance" {
    var storage = try Storage.init(std.testing.allocator, 8, 0);
    defer storage.deinit();
    var dl = storage.list();

    try dl.pushClip(.{ .w = 5, .h = 5 });
    try dl.pushOpacity(0.5);
    try std.testing.expect(!dl.isBalanced());
    try std.testing.expect(try dl.popOpacity());
    try std.testing.expect(try dl.popClip());
    try std.testing.expect(dl.isBalanced());

    // Unbalanced pops are refused and record nothing.
    const before = dl.items().len;
    try std.testing.expect(!(try dl.popClip()));
    try std.testing.expectEqual(before, dl.items().len);
}

test "glyph runs copy into the side array and reference it by offset" {
    var storage = try Storage.init(std.testing.allocator, 8, 8);
    defer storage.deinit();
    var dl = storage.list();

    const run1 = [_]Glyph{ .{ .id = 1, .x = 0, .y = 0 }, .{ .id = 2, .x = 8, .y = 0 } };
    const run2 = [_]Glyph{.{ .id = 3, .x = 0, .y = 20 }};
    try dl.glyphRun(.{ .w = 16, .h = 16 }, &run1, Color.black, 0, 14);
    try dl.glyphRun(.{ .y = 20, .w = 8, .h = 16 }, &run2, Color.black, 0, 14);

    const cmds = dl.items();
    try std.testing.expectEqual(@as(u32, 0), cmds[0].a);
    try std.testing.expectEqual(@as(u32, 2), cmds[0].b);
    try std.testing.expectEqual(@as(u32, 2), cmds[1].a);
    try std.testing.expectEqual(@as(u32, 1), cmds[1].b);
    try std.testing.expectEqual(@as(u32, 3), dl.glyphItems()[2].id);
}

test "glyph buffer overflow is reported and leaves the list untouched" {
    var storage = try Storage.init(std.testing.allocator, 8, 1);
    defer storage.deinit();
    var dl = storage.list();

    const run = [_]Glyph{ .{ .id = 1, .x = 0, .y = 0 }, .{ .id = 2, .x = 8, .y = 0 } };
    try std.testing.expectError(error.GlyphBufferFull, dl.glyphRun(.{}, &run, Color.black, 0, 14));
    try std.testing.expectEqual(@as(usize, 0), dl.items().len);
    try std.testing.expectEqual(@as(usize, 0), dl.glyphItems().len);
}
