//! stb_truetype font backend (design doc section 15: "stb_truetype first").
//!
//! SECURITY: stb_truetype does no range checking on font data. Only load font
//! files you trust (system fonts, fonts you ship).
//!
//! Limits: TrueType outlines only through stb's cmap/glyf/kern support. No
//! GPOS kerning, no OpenType layout features, variable fonts render their
//! default instance. Those arrive with a HarfBuzz/FreeType backend behind the
//! same `font.Backend` interface.

const std = @import("std");
const zigui = @import("zigui");
const c = @import("stb_c");
const font = zigui.font;

pub const Error = error{InvalidFont};

pub const StbFont = struct {
    info: c.stbtt_fontinfo,
    /// Font file bytes. Must outlive the font and must not move.
    data: []const u8,

    /// Initialize in place (`stbtt_fontinfo` points into `data`, so the
    /// StbFont must not be moved afterwards). `index` picks a face in a collection.
    pub fn init(self: *StbFont, data: []const u8, index: i32) Error!void {
        self.data = data;
        const offset = c.stbtt_GetFontOffsetForIndex(data.ptr, index);
        if (offset < 0) return error.InvalidFont;
        if (c.stbtt_InitFont(&self.info, data.ptr, offset) == 0) return error.InvalidFont;
    }

    pub fn backend(self: *StbFont) font.Backend {
        return .{ .ctx = self, .vtable = &vtable };
    }

    const vtable: font.VTable = .{
        .metrics = metricsFn,
        .glyphIndex = glyphIndexFn,
        .advance = advanceFn,
        .kerning = kerningFn,
        .glyphBox = glyphBoxFn,
        .rasterize = rasterizeFn,
    };

    fn self_(ctx: *anyopaque) *StbFont {
        return @ptrCast(@alignCast(ctx));
    }

    fn scale(self: *StbFont, size: f32) f32 {
        return c.stbtt_ScaleForMappingEmToPixels(&self.info, size);
    }

    fn metricsFn(ctx: *anyopaque, size: f32) font.Metrics {
        const self = self_(ctx);
        var asc: c_int = 0;
        var desc: c_int = 0;
        var gap: c_int = 0;
        c.stbtt_GetFontVMetrics(&self.info, &asc, &desc, &gap);
        const s = self.scale(size);
        return .{
            .ascent = @as(f32, @floatFromInt(asc)) * s,
            .descent = -@as(f32, @floatFromInt(desc)) * s,
            .line_gap = @as(f32, @floatFromInt(gap)) * s,
        };
    }

    fn glyphIndexFn(ctx: *anyopaque, cp: u21) u32 {
        const g = c.stbtt_FindGlyphIndex(&self_(ctx).info, @intCast(cp));
        return @intCast(@max(g, 0));
    }

    fn advanceFn(ctx: *anyopaque, glyph: u32, size: f32) f32 {
        const self = self_(ctx);
        var adv: c_int = 0;
        var lsb: c_int = 0;
        c.stbtt_GetGlyphHMetrics(&self.info, @intCast(glyph), &adv, &lsb);
        return @as(f32, @floatFromInt(adv)) * self.scale(size);
    }

    fn kerningFn(ctx: *anyopaque, left: u32, right: u32, size: f32) f32 {
        const self = self_(ctx);
        const k = c.stbtt_GetGlyphKernAdvance(&self.info, @intCast(left), @intCast(right));
        return @as(f32, @floatFromInt(k)) * self.scale(size);
    }

    fn glyphBoxFn(ctx: *anyopaque, glyph: u32, size: f32, subpixel_x: f32) font.GlyphBox {
        const self = self_(ctx);
        const s = self.scale(size);
        var x0: c_int = 0;
        var y0: c_int = 0;
        var x1: c_int = 0;
        var y1: c_int = 0;
        c.stbtt_GetGlyphBitmapBoxSubpixel(&self.info, @intCast(glyph), s, s, subpixel_x, 0, &x0, &y0, &x1, &y1);
        return .{
            .w = @intCast(@max(x1 - x0, 0)),
            .h = @intCast(@max(y1 - y0, 0)),
            .left = x0,
            .top = -y0, // stb's y grows downward from the baseline
        };
    }

    fn rasterizeFn(ctx: *anyopaque, glyph: u32, size: f32, subpixel_x: f32, dst: []u8, stride: usize) void {
        const self = self_(ctx);
        const box = glyphBoxFn(ctx, glyph, size, subpixel_x);
        if (box.w == 0 or box.h == 0) return;
        std.debug.assert(dst.len >= (box.h - 1) * stride + box.w);
        const s = self.scale(size);
        c.stbtt_MakeGlyphBitmapSubpixel(&self.info, dst.ptr, @intCast(box.w), @intCast(box.h), @intCast(stride), s, s, subpixel_x, 0, @intCast(glyph));
    }
};

/// Well-known system font locations, tried in order. Linux paths for now.
pub const ui_font_candidates = [_][]const u8{
    "/usr/share/fonts/liberation-sans-fonts/LiberationSans-Regular.ttf",
    "/usr/share/fonts/liberation/LiberationSans-Regular.ttf",
    "/usr/share/fonts/truetype/liberation/LiberationSans-Regular.ttf",
    "/usr/share/fonts/dejavu-sans-fonts/DejaVuSans.ttf",
    "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
    "/usr/share/fonts/TTF/DejaVuSans.ttf",
    "/usr/share/fonts/google-noto-vf/NotoSans[wght].ttf",
};

pub const mono_font_candidates = [_][]const u8{
    "/usr/share/fonts/adwaita-mono-fonts/AdwaitaMono-Regular.ttf",
    "/usr/share/fonts/liberation-mono-fonts/LiberationMono-Regular.ttf",
    "/usr/share/fonts/liberation/LiberationMono-Regular.ttf",
    "/usr/share/fonts/truetype/liberation/LiberationMono-Regular.ttf",
    "/usr/share/fonts/dejavu-sans-mono-fonts/DejaVuSansMono.ttf",
    "/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf",
    "/usr/share/fonts/TTF/DejaVuSansMono.ttf",
    "/usr/share/fonts/google-noto-vf/NotoSansMono[wght].ttf",
};

/// Read the first readable file from `candidates` (or `override`). Caller frees the bytes.
pub fn loadFirst(io: std.Io, gpa: std.mem.Allocator, override: ?[]const u8, candidates: []const []const u8) ?[]u8 {
    if (override) |path| {
        if (std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(64 * 1024 * 1024))) |bytes| return bytes else |_| {}
    }
    for (candidates) |path| {
        if (std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(64 * 1024 * 1024))) |bytes| return bytes else |_| {}
    }
    return null;
}

// ---- tests -----------------------------------------------------------------

fn loadTestFont(candidates: []const []const u8) ?[]u8 {
    return loadFirst(std.testing.io, std.testing.allocator, null, candidates);
}

test "a real font shapes, measures, and rasterizes" {
    const bytes = loadTestFont(&ui_font_candidates) orelse return error.SkipZigTest;
    defer std.testing.allocator.free(bytes);
    var f: StbFont = undefined;
    try f.init(bytes, 0);
    const b = f.backend();

    const m = b.metrics(20);
    try std.testing.expect(m.ascent > 10 and m.ascent < 25);
    try std.testing.expect(m.descent > 0);

    const gi = b.glyphIndex('i');
    const gm = b.glyphIndex('M');
    try std.testing.expect(gi != 0 and gm != 0);
    try std.testing.expect(b.advance(gm, 20) > b.advance(gi, 20)); // proportional
    try std.testing.expectEqual(@as(u32, 0), b.glyphIndex(0x10FFFF)); // missing

    const box = b.glyphBox(gm, 20, 0);
    try std.testing.expect(box.w > 5 and box.h > 8);
    try std.testing.expect(box.top > 0); // capital M sits above the baseline

    var pixels: [64 * 64]u8 = @splat(0);
    b.rasterize(gm, 20, 0, &pixels, 64);
    var ink: u32 = 0;
    for (pixels) |p| ink += p;
    try std.testing.expect(ink > 1000);
}

test "a real monospace font is detected and goes through the text system" {
    const bytes = loadTestFont(&mono_font_candidates) orelse return error.SkipZigTest;
    defer std.testing.allocator.free(bytes);
    var f: StbFont = undefined;
    try f.init(bytes, 0);

    var ts = zigui.text.TextSystem.init(std.testing.allocator);
    defer ts.deinit();
    const id = try ts.addFont(f.backend());
    try std.testing.expect(ts.isMonospace(id));

    var list: std.ArrayListUnmanaged(zigui.text.Glyph) = .empty;
    defer list.deinit(std.testing.allocator);
    const r = try ts.shape(id, 16, "hello world", &list, std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 10), r.glyph_count); // the space has no glyph
    try std.testing.expect(r.width > 16 * 5);
    // Cells are uniform.
    const cell = list.items[1].x - list.items[0].x;
    try std.testing.expectApproxEqAbs(cell * 11, r.width, 0.01);

    ts.prewarmAscii(id, 16);
    try std.testing.expect(ts.atlas.count() > 80);
}

test "garbage is rejected as a font" {
    var junk: [256]u8 = @splat(0x41);
    var f: StbFont = undefined;
    try std.testing.expectError(error.InvalidFont, f.init(&junk, 0));
}
