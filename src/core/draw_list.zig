//! The draw list: a flat, append-only buffer of fixed-size command records.
//!
//! - Every record is the same size, so the list is cheap to build, cache per
//!   repaint boundary, replay into a damage rect, and hand to a renderer backend.
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

/// Colors and the line (or center and radius vector) of a gradient.
pub const Gradient = struct {
    from: Vec2,
    to: Vec2,
    color: Color,
    color2: Color,
};

/// What a shape is filled with. For a linear gradient, `from`/`to` is the
/// gradient line; for a radial one, `from` is the center and `to` a point at
/// the radius. An image pattern holds an opaque texture handle from the backend.
pub const Paint = union(enum) {
    color: Color,
    linear_gradient: Gradient,
    radial_gradient: Gradient,
    image_pattern: u32,

    pub fn solid(c: Color) Paint {
        return .{ .color = c };
    }

    pub fn linear(from: Vec2, to: Vec2, c0: Color, c1: Color) Paint {
        return .{ .linear_gradient = .{ .from = from, .to = to, .color = c0, .color2 = c1 } };
    }

    pub fn radial(center: Vec2, edge: Vec2, c0: Color, c1: Color) Paint {
        return .{ .radial_gradient = .{ .from = center, .to = edge, .color = c0, .color2 = c1 } };
    }
};

/// One positioned glyph in the side array. `x`/`y` are the baseline pen
/// position in logical pixels (relative to a run origin until it is drawn).
pub const Glyph = struct {
    id: u32,
    x: f32,
    y: f32,
};

pub const Fill = struct { rect: Rect, paint: Paint };

/// A border drawn inside `rect`.
pub const Stroke = struct { rect: Rect, paint: Paint, width: f32, radius: f32 = 0 };

/// `radii` is top-left, top-right, bottom-right, bottom-left.
pub const RoundedFill = struct { rect: Rect, paint: Paint, radii: [4]f32 };

pub const Line = struct { from: Vec2, to: Vec2, paint: Paint, width: f32 };

pub const ImageFilter = enum { nearest, linear };

/// A textured quad: `src` (texels; zero width or height means the whole
/// texture) stretched over `rect`, multiplied by `tint`. The texture is an
/// opaque handle issued by the renderer backend.
pub const Image = struct {
    rect: Rect,
    texture: @import("handle.zig").Handle,
    src: Rect = .{},
    tint: Color = Color.white,
    filter: ImageFilter = .linear,
};

/// A run of pre-shaped glyphs, referenced by offset and count into the side
/// array. Glyph positions are baseline pen positions in logical pixels.
pub const GlyphRun = struct {
    offset: u32,
    count: u32,
    bounds: Rect,
    color: Color,
    font: u32,
    /// Font size in logical pixels.
    size: f32,
    /// Subpixel glyph positioning (proportional text); otherwise positions
    /// snap to whole device pixels.
    subpixel: bool,
};

/// One draw command. Records stay fixed-size, so the list is cheap to build,
/// cache, and replay.
pub const Command = union(enum) {
    fill_rect: Fill,
    stroke_rect: Stroke,
    fill_rounded_rect: RoundedFill,
    line: Line,
    push_clip: Rect,
    pop_clip,
    push_opacity: f32,
    pop_opacity,
    glyph_run: GlyphRun,
    image: Image,
};

comptime {
    // Records are copied around constantly: keep them small. Raise deliberately.
    std.debug.assert(@sizeOf(Command) <= 96);
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

    /// Slots kept free for pop commands in lists large enough to spare them, so
    /// a frame that fills up can still close the clips and opacities it opened.
    pub const pop_reserve = 16;

    pub fn push(self: *DrawList, cmd: Command) Error!void {
        const is_pop = cmd == .pop_clip or cmd == .pop_opacity;
        const reserve: usize = if (is_pop or self.commands.len <= 64) 0 else pop_reserve;
        if (self.len + reserve >= self.commands.len) return error.DrawListFull;
        self.commands[self.len] = cmd;
        self.len += 1;
    }

    pub fn fillRect(self: *DrawList, rect: Rect, paint: Paint) Error!void {
        try self.push(.{ .fill_rect = .{ .rect = rect, .paint = paint } });
    }

    pub fn strokeRect(self: *DrawList, rect: Rect, width: f32, paint: Paint) Error!void {
        try self.strokeRoundedRect(rect, width, 0, paint);
    }

    pub fn strokeRoundedRect(self: *DrawList, rect: Rect, width: f32, radius: f32, paint: Paint) Error!void {
        try self.push(.{ .stroke_rect = .{ .rect = rect, .paint = paint, .width = width, .radius = radius } });
    }

    /// `radii` is top-left, top-right, bottom-right, bottom-left.
    pub fn fillRoundedRect(self: *DrawList, rect: Rect, radii: [4]f32, paint: Paint) Error!void {
        try self.push(.{ .fill_rounded_rect = .{ .rect = rect, .paint = paint, .radii = radii } });
    }

    pub fn line(self: *DrawList, from: Vec2, to: Vec2, width: f32, paint: Paint) Error!void {
        try self.push(.{ .line = .{ .from = from, .to = to, .paint = paint, .width = width } });
    }

    pub fn image(self: *DrawList, img: Image) Error!void {
        try self.push(.{ .image = img });
    }

    pub fn pushClip(self: *DrawList, rect: Rect) Error!void {
        try self.push(.{ .push_clip = rect });
        self.clip_depth += 1;
    }

    /// Returns false (and records nothing) if there is no clip to pop.
    pub fn popClip(self: *DrawList) Error!bool {
        if (self.clip_depth == 0) return false;
        try self.push(.pop_clip);
        self.clip_depth -= 1;
        return true;
    }

    pub fn pushOpacity(self: *DrawList, opacity: f32) Error!void {
        try self.push(.{ .push_opacity = opacity });
        self.opacity_depth += 1;
    }

    pub fn popOpacity(self: *DrawList) Error!bool {
        if (self.opacity_depth == 0) return false;
        try self.push(.pop_opacity);
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
        return self.glyphRunEx(bounds, run, color, font_id, font_size, false);
    }

    /// Like `glyphRun`, with control over subpixel positioning (proportional
    /// UI text) versus whole-pixel snapping (monospace editor text).
    pub fn glyphRunEx(
        self: *DrawList,
        bounds: Rect,
        run: []const Glyph,
        color: Color,
        font_id: u32,
        font_size: f32,
        subpixel: bool,
    ) Error!void {
        return self.glyphRunAt(bounds, run, .{}, color, font_id, font_size, subpixel);
    }

    /// Like `glyphRunEx`, adding `origin` to every glyph position as it is copied.
    pub fn glyphRunAt(
        self: *DrawList,
        bounds: Rect,
        run: []const Glyph,
        origin: Vec2,
        color: Color,
        font_id: u32,
        font_size: f32,
        subpixel: bool,
    ) Error!void {
        if (self.glyph_len + run.len > self.glyphs.len) return error.GlyphBufferFull;
        if (self.len == self.commands.len) return error.DrawListFull;

        const offset = self.glyph_len;
        for (run, self.glyphs[offset .. offset + run.len]) |src, *dst| {
            dst.* = .{ .id = src.id, .x = src.x + origin.x, .y = src.y + origin.y };
        }
        self.glyph_len += run.len;

        try self.push(.{ .glyph_run = .{
            .offset = @intCast(offset),
            .count = @intCast(run.len),
            .bounds = bounds,
            .color = color,
            .font = font_id,
            .size = font_size,
            .subpixel = subpixel,
        } });
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
    try std.testing.expect(cmds[0] == .fill_rect);
    try std.testing.expect(cmds[1] == .stroke_rect);
    try std.testing.expectEqual(@as(f32, 2), cmds[1].stroke_rect.width);
    try std.testing.expectEqual(@as(f32, 4), cmds[2].fill_rounded_rect.radii[0]);
}

test "full list returns an error instead of allocating" {
    var storage = try Storage.init(std.testing.allocator, 2, 0);
    defer storage.deinit();
    var dl = storage.list();

    const r: Rect = .{ .w = 1, .h = 1 };
    try dl.fillRect(r, Paint.solid(Color.black));
    try dl.fillRect(r, Paint.solid(Color.black));
    try std.testing.expectError(error.DrawListFull, dl.fillRect(r, Paint.solid(Color.black)));
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
    try std.testing.expectEqual(@as(u32, 0), cmds[0].glyph_run.offset);
    try std.testing.expectEqual(@as(u32, 2), cmds[0].glyph_run.count);
    try std.testing.expectEqual(@as(u32, 2), cmds[1].glyph_run.offset);
    try std.testing.expectEqual(@as(u32, 1), cmds[1].glyph_run.count);
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

test "a full list still accepts the pops that close what it opened" {
    var cmds: [128]Command = undefined;
    var glyphs: [8]Glyph = undefined;
    var dl = DrawList.init(&cmds, &glyphs);
    try dl.pushClip(.{ .w = 10, .h = 10 });
    try dl.pushClip(.{ .w = 5, .h = 5 });
    var filled: usize = 0;
    while (true) : (filled += 1) {
        dl.fillRect(.{ .w = 1, .h = 1 }, Paint.solid(Color.black)) catch break;
    }
    try std.testing.expectEqual(@as(usize, 128 - DrawList.pop_reserve - 2), filled);
    try std.testing.expectError(error.DrawListFull, dl.pushClip(.{ .w = 1, .h = 1 })); // pushes stop at the reserve
    try std.testing.expect(try dl.popClip());
    try std.testing.expect(try dl.popClip());
    try std.testing.expect(dl.isBalanced());
}
