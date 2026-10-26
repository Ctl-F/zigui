//! Font backend interface: the swappable layer under the text system.
//!
//! A backend turns a font file into metrics, glyph ids, advances, kerning and
//! rasterized coverage bitmaps. The text system (shaping, atlas) only sees
//! this interface, so stb_truetype can be replaced by FreeType/HarfBuzz later.
//!
//! All sizes are the font's em height in pixels (like CSS `font-size`). Advances
//! and metrics are unhinted and scale linearly with size, so layout is the same
//! at every display scale.

const std = @import("std");

pub const Metrics = struct {
    /// Distance from baseline up to the top of the tallest glyphs (positive).
    ascent: f32,
    /// Distance from baseline down to the lowest descenders (positive).
    descent: f32,
    /// Extra spacing between lines.
    line_gap: f32,

    pub fn lineHeight(self: Metrics) f32 {
        return self.ascent + self.descent + self.line_gap;
    }
};

/// Placement of a rasterized glyph relative to its pen position on the baseline.
pub const GlyphBox = struct {
    /// Bitmap size in pixels. Zero for glyphs with no ink (space).
    w: u32,
    h: u32,
    /// Pixels from the pen position to the bitmap's left edge (may be negative).
    left: i32,
    /// Pixels from the baseline up to the bitmap's top edge (positive = above).
    top: i32,
};

pub const VTable = struct {
    metrics: *const fn (ctx: *anyopaque, size: f32) Metrics,
    /// Glyph id for a code point; 0 means the font has no glyph for it.
    glyphIndex: *const fn (ctx: *anyopaque, codepoint: u21) u32,
    advance: *const fn (ctx: *anyopaque, glyph: u32, size: f32) f32,
    kerning: *const fn (ctx: *anyopaque, left: u32, right: u32, size: f32) f32,
    /// Size of the bitmap `rasterize` will produce. `subpixel_x` is the
    /// horizontal pen offset in [0, 1) pixels.
    glyphBox: *const fn (ctx: *anyopaque, glyph: u32, size: f32, subpixel_x: f32) GlyphBox,
    /// Write 8-bit coverage into `dst` (`stride` bytes per row). `dst` must
    /// hold at least `box.h * stride` bytes, `stride >= box.w`.
    rasterize: *const fn (ctx: *anyopaque, glyph: u32, size: f32, subpixel_x: f32, dst: []u8, stride: usize) void,
};

pub const Backend = struct {
    ctx: *anyopaque,
    vtable: *const VTable,

    pub fn metrics(self: Backend, size: f32) Metrics {
        return self.vtable.metrics(self.ctx, size);
    }

    pub fn glyphIndex(self: Backend, cp: u21) u32 {
        return self.vtable.glyphIndex(self.ctx, cp);
    }

    pub fn advance(self: Backend, glyph: u32, size: f32) f32 {
        return self.vtable.advance(self.ctx, glyph, size);
    }

    pub fn kerning(self: Backend, left: u32, right: u32, size: f32) f32 {
        return self.vtable.kerning(self.ctx, left, right, size);
    }

    pub fn glyphBox(self: Backend, glyph: u32, size: f32, subpixel_x: f32) GlyphBox {
        return self.vtable.glyphBox(self.ctx, glyph, size, subpixel_x);
    }

    pub fn rasterize(self: Backend, glyph: u32, size: f32, subpixel_x: f32, dst: []u8, stride: usize) void {
        self.vtable.rasterize(self.ctx, glyph, size, subpixel_x, dst, stride);
    }
};

/// Synthetic font for tests and headless runs: every printable glyph is a solid
/// box. No file needed. `monospace` makes all advances equal; otherwise 'i',
/// 'l' and '.' are narrow and 'M' and 'W' are wide, and "AV" kerns.
pub const TestFont = struct {
    monospace: bool = false,

    pub fn backend(self: *TestFont) Backend {
        return .{ .ctx = self, .vtable = &vtable };
    }

    const vtable: VTable = .{
        .metrics = metricsFn,
        .glyphIndex = glyphIndexFn,
        .advance = advanceFn,
        .kerning = kerningFn,
        .glyphBox = glyphBoxFn,
        .rasterize = rasterizeFn,
    };

    fn self_(ctx: *anyopaque) *TestFont {
        return @ptrCast(@alignCast(ctx));
    }

    fn metricsFn(_: *anyopaque, size: f32) Metrics {
        return .{ .ascent = size * 0.8, .descent = size * 0.2, .line_gap = size * 0.1 };
    }

    fn glyphIndexFn(_: *anyopaque, cp: u21) u32 {
        if (cp < 0x21 or cp > 0x7e) return if (cp == ' ') 1 else 0;
        return cp; // glyph id == code point for printable ASCII
    }

    fn advanceFn(ctx: *anyopaque, glyph: u32, size: f32) f32 {
        if (self_(ctx).monospace) return size * 0.6;
        if (glyph == 1) return size * 0.3; // space
        return switch (glyph) {
            'i', 'l', '.', ',', '!' => size * 0.25,
            'M', 'W' => size * 0.9,
            else => size * 0.55,
        };
    }

    fn kerningFn(ctx: *anyopaque, left: u32, right: u32, size: f32) f32 {
        if (self_(ctx).monospace) return 0;
        return if (left == 'A' and right == 'V') -size * 0.1 else 0;
    }

    fn glyphBoxFn(ctx: *anyopaque, glyph: u32, size: f32, _: f32) GlyphBox {
        if (glyph <= 1) return .{ .w = 0, .h = 0, .left = 0, .top = 0 };
        const adv = advanceFn(ctx, glyph, size);
        const w: u32 = @intFromFloat(@max(@floor(adv - 1), 1));
        const h: u32 = @intFromFloat(@max(@floor(size * 0.7), 1));
        return .{ .w = w, .h = h, .left = 0, .top = @intCast(h) };
    }

    fn rasterizeFn(ctx: *anyopaque, glyph: u32, size: f32, subpixel_x: f32, dst: []u8, stride: usize) void {
        const b = glyphBoxFn(ctx, glyph, size, subpixel_x);
        for (0..b.h) |y| @memset(dst[y * stride ..][0..b.w], 255);
    }
};

test "test font reports sensible metrics and boxes" {
    var f: TestFont = .{};
    const b = f.backend();
    try std.testing.expectEqual(@as(u32, 0), b.glyphIndex(0x4e2d));
    try std.testing.expect(b.glyphIndex('a') != 0);
    try std.testing.expect(b.advance('M', 10) > b.advance('i', 10));
    try std.testing.expectEqual(@as(u32, 0), b.glyphBox(b.glyphIndex(' '), 10, 0).w);
    try std.testing.expectApproxEqAbs(@as(f32, 13), b.metrics(10).lineHeight() + 2, 0.01);
}
