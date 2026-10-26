//! Text system: font registry, shaping, and the glyph atlas behind one object.
//!
//! Shaping here is "simple": UTF-8 decode, cmap lookup, advances, and pair
//! kerning from the backend. No ligatures, bidirectional text, or complex
//! scripts: those need a real shaper (HarfBuzz) behind the same interface.
//! Lines only: control characters (including newline) are skipped.
//!
//! Monospace fast path: for a monospace font, ASCII text skips per-glyph
//! backend calls. Glyph ids come from a table built when the font is added and
//! every glyph advances by one precomputed cell width.

const std = @import("std");
const font = @import("font.zig");
const atlas_mod = @import("atlas.zig");
const draw_list = @import("../core/draw_list.zig");

pub const Glyph = draw_list.Glyph;
pub const FontId = u32;

/// A glyph bitmap inside an atlas page, as the renderer needs it.
pub const GlyphImage = struct {
    /// The whole page (`stride` bytes per row).
    pixels: []const u8,
    stride: u32,
    x: u32,
    y: u32,
    w: u32,
    h: u32,
    /// Pixels from the pen position to the bitmap's left edge.
    left: i32,
    /// Pixels from the baseline up to the bitmap's top edge.
    top: i32,
};

/// What the software renderer uses to draw glyph runs.
pub const GlyphProvider = struct {
    ctx: *anyopaque,
    lookupFn: *const fn (ctx: *anyopaque, font: FontId, glyph: u32, size_px: f32, subpixel: u8) ?GlyphImage,

    pub fn lookup(self: GlyphProvider, f: FontId, glyph: u32, size_px: f32, subpixel: u8) ?GlyphImage {
        return self.lookupFn(self.ctx, f, glyph, size_px, subpixel);
    }
};

const FontEntry = struct {
    backend: font.Backend,
    monospace: bool,
    /// Glyph id for each ASCII code point (0 = missing).
    ascii: [128]u32,
    /// Monospace cell width as a fraction of the em size.
    cell_per_em: f32,
};

pub const ShapeResult = struct {
    width: f32,
    glyph_count: usize,
};

pub const TextSystem = struct {
    gpa: std.mem.Allocator,
    fonts: std.ArrayListUnmanaged(FontEntry) = .empty,
    atlas: atlas_mod.Atlas,

    pub fn init(gpa: std.mem.Allocator) TextSystem {
        return .{ .gpa = gpa, .atlas = atlas_mod.Atlas.init(gpa) };
    }

    pub fn deinit(self: *TextSystem) void {
        self.fonts.deinit(self.gpa);
        self.atlas.deinit();
        self.* = undefined;
    }

    pub fn addFont(self: *TextSystem, backend: font.Backend) !FontId {
        var entry: FontEntry = .{ .backend = backend, .monospace = false, .ascii = undefined, .cell_per_em = 0 };
        for (&entry.ascii, 0..) |*g, cp| g.* = backend.glyphIndex(@intCast(cp));

        // Monospace if all common glyphs share one advance.
        const ref = entry.ascii['M'];
        if (ref != 0) {
            const ref_adv = backend.advance(ref, 1000);
            var mono = true;
            for ("iIlW.m 0") |c| {
                const g = entry.ascii[c];
                if (g != 0 and @abs(backend.advance(g, 1000) - ref_adv) > 0.5) mono = false;
            }
            entry.monospace = mono;
            entry.cell_per_em = ref_adv / 1000;
        }
        try self.fonts.append(self.gpa, entry);
        return @intCast(self.fonts.items.len - 1);
    }

    pub fn isMonospace(self: *const TextSystem, f: FontId) bool {
        return self.fonts.items[f].monospace;
    }

    pub fn metrics(self: *const TextSystem, f: FontId, size: f32) font.Metrics {
        return self.fonts.items[f].backend.metrics(size);
    }

    /// Shape `text` at `size` (logical px). Glyphs are appended to `out` with
    /// positions relative to the line origin. Pass null to only measure.
    pub fn shape(
        self: *const TextSystem,
        f: FontId,
        size: f32,
        text: []const u8,
        out: ?*std.ArrayListUnmanaged(Glyph),
        gpa: std.mem.Allocator,
    ) !ShapeResult {
        const fe = &self.fonts.items[f];
        const start_len = if (out) |o| o.items.len else 0;
        var x: f32 = 0;

        if (fe.monospace and isAscii(text)) {
            const cell = fe.cell_per_em * size;
            for (text) |c| {
                if (c < 0x20 or c == 0x7f) continue;
                if (c != ' ') if (out) |o| {
                    try o.append(gpa, .{ .id = fe.ascii[c], .x = x, .y = 0 });
                };
                x += cell;
            }
        } else {
            var prev: u32 = 0;
            var it = std.unicode.Utf8View.initUnchecked(text).iterator();
            while (it.nextCodepoint()) |cp| {
                if (cp < 0x20 or cp == 0x7f or (cp >= 0x80 and cp < 0xa0)) continue;
                var g = if (cp < 128) fe.ascii[cp] else fe.backend.glyphIndex(cp);
                if (g == 0) g = fe.ascii['?']; // fallback for missing glyphs
                if (prev != 0 and g != 0) x += fe.backend.kerning(prev, g, size);
                if (cp != ' ' and cp != 0xa0) if (out) |o| {
                    try o.append(gpa, .{ .id = g, .x = x, .y = 0 });
                };
                x += fe.backend.advance(g, size);
                prev = g;
            }
        }
        const count = if (out) |o| o.items.len - start_len else 0;
        return .{ .width = x, .glyph_count = count };
    }

    pub fn measure(self: *const TextSystem, f: FontId, size: f32, text: []const u8) f32 {
        const r = self.shape(f, size, text, null, self.gpa) catch unreachable; // no allocation when `out` is null
        return r.width;
    }

    /// Rasterize printable ASCII at a device pixel size ahead of time so first
    /// use does not stall on rasterization.
    pub fn prewarmAscii(self: *TextSystem, f: FontId, size_px: f32) void {
        const fe = &self.fonts.items[f];
        for (0x21..0x7f) |cp| {
            const g = fe.ascii[cp];
            if (g == 0) continue;
            _ = self.atlas.getOrAdd(.{ .font = f, .glyph = g, .size_q = atlas_mod.quantizeSize(size_px), .subpixel = 0 }, fe.backend, size_px);
        }
    }

    pub fn provider(self: *TextSystem) GlyphProvider {
        return .{ .ctx = self, .lookupFn = lookupThunk };
    }

    fn lookupThunk(ctx: *anyopaque, f: FontId, glyph: u32, size_px: f32, subpixel: u8) ?GlyphImage {
        const self: *TextSystem = @ptrCast(@alignCast(ctx));
        if (f >= self.fonts.items.len) return null;
        const key: atlas_mod.Key = .{ .font = f, .glyph = glyph, .size_q = atlas_mod.quantizeSize(size_px), .subpixel = subpixel };
        const e = self.atlas.getOrAdd(key, self.fonts.items[f].backend, size_px) orelse return null;
        return .{
            .pixels = if (e.w == 0) &.{} else self.atlas.pagePixels(e.page),
            .stride = atlas_mod.page_size,
            .x = e.x,
            .y = e.y,
            .w = e.w,
            .h = e.h,
            .left = e.left,
            .top = e.top,
        };
    }
};

fn isAscii(s: []const u8) bool {
    for (s) |c| if (c >= 0x80) return false;
    return true;
}

// ---- tests -----------------------------------------------------------------

const testing = std.testing;

fn runShape(ts: *TextSystem, f: FontId, size: f32, text: []const u8, list: *std.ArrayListUnmanaged(Glyph)) !ShapeResult {
    return ts.shape(f, size, text, list, testing.allocator);
}

test "proportional shaping advances per glyph and skips spaces" {
    var tf: font.TestFont = .{};
    var ts = TextSystem.init(testing.allocator);
    defer ts.deinit();
    const f = try ts.addFont(tf.backend());
    try testing.expect(!ts.isMonospace(f));

    var list: std.ArrayListUnmanaged(Glyph) = .empty;
    defer list.deinit(testing.allocator);
    const r = try runShape(&ts, f, 20, "Mi x", &list);
    // M = 0.9em, i = 0.25em, space = 0.3em, x = 0.55em
    try testing.expectApproxEqAbs(@as(f32, 20 * (0.9 + 0.25 + 0.3 + 0.55)), r.width, 0.01);
    try testing.expectEqual(@as(usize, 3), r.glyph_count); // no glyph for the space
    try testing.expectApproxEqAbs(@as(f32, 0), list.items[0].x, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 18), list.items[1].x, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 20 * 1.45), list.items[2].x, 0.01);
}

test "kerning pairs tighten the advance" {
    var tf: font.TestFont = .{};
    var ts = TextSystem.init(testing.allocator);
    defer ts.deinit();
    const f = try ts.addFont(tf.backend());
    const kerned = ts.measure(f, 10, "AV");
    const plain = ts.measure(f, 10, "AB");
    try testing.expectApproxEqAbs(plain - 1.0, kerned, 0.01);
}

test "monospace fast path gives uniform cells" {
    var tf: font.TestFont = .{ .monospace = true };
    var ts = TextSystem.init(testing.allocator);
    defer ts.deinit();
    const f = try ts.addFont(tf.backend());
    try testing.expect(ts.isMonospace(f));

    var list: std.ArrayListUnmanaged(Glyph) = .empty;
    defer list.deinit(testing.allocator);
    const r = try runShape(&ts, f, 10, "a b!i", &list);
    try testing.expectApproxEqAbs(@as(f32, 5 * 6), r.width, 0.01);
    try testing.expectEqual(@as(usize, 4), list.items.len);
    try testing.expectApproxEqAbs(@as(f32, 12), list.items[1].x, 0.01); // 'b' is the third cell
    try testing.expectEqual(@as(u32, 'a'), list.items[0].id);
}

test "non-ASCII text on a monospace font falls back to the full path" {
    var tf: font.TestFont = .{ .monospace = true };
    var ts = TextSystem.init(testing.allocator);
    defer ts.deinit();
    const f = try ts.addFont(tf.backend());
    var list: std.ArrayListUnmanaged(Glyph) = .empty;
    defer list.deinit(testing.allocator);
    // U+00E9 is missing from the test font: it falls back to '?', still one cell.
    const r = try runShape(&ts, f, 10, "a\u{e9}b", &list);
    try testing.expectEqual(@as(usize, 3), r.glyph_count);
    try testing.expectEqual(@as(u32, '?'), list.items[1].id);
    try testing.expectApproxEqAbs(@as(f32, 18), r.width, 0.01);
}

test "control characters are skipped and measure matches shape" {
    var tf: font.TestFont = .{};
    var ts = TextSystem.init(testing.allocator);
    defer ts.deinit();
    const f = try ts.addFont(tf.backend());
    var list: std.ArrayListUnmanaged(Glyph) = .empty;
    defer list.deinit(testing.allocator);
    const r = try runShape(&ts, f, 12, "ab\ncd\t", &list);
    try testing.expectEqual(@as(usize, 4), r.glyph_count);
    try testing.expectEqual(r.width, ts.measure(f, 12, "ab\ncd\t"));
}

test "empty text has zero width and no glyphs" {
    var tf: font.TestFont = .{};
    var ts = TextSystem.init(testing.allocator);
    defer ts.deinit();
    const f = try ts.addFont(tf.backend());
    try testing.expectEqual(@as(f32, 0), ts.measure(f, 12, ""));
}

test "provider hands out atlas bitmaps and prewarm fills the atlas" {
    var tf: font.TestFont = .{};
    var ts = TextSystem.init(testing.allocator);
    defer ts.deinit();
    const f = try ts.addFont(tf.backend());
    ts.prewarmAscii(f, 14);
    try testing.expect(ts.atlas.count() > 80);

    const img = ts.provider().lookup(f, 'A', 14, 0).?;
    try testing.expect(img.w > 0);
    try testing.expectEqual(@as(u8, 255), img.pixels[@as(usize, img.y) * img.stride + img.x]);
    try testing.expect(ts.provider().lookup(99, 'A', 14, 0) == null); // unknown font
}
