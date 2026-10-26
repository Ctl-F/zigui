//! Software rasterizer: executes a `DrawList` into an RGBA8 pixel buffer.
//!
//! The guaranteed fallback renderer (see design doc section 22) and the easy
//! one to debug. Every shape is evaluated as a signed distance field per pixel
//! so edges and rounded corners are anti-aliased with a single code path; plain
//! rectangles take a cheaper exact-coverage path.
//!
//! Supported: fill_rect, stroke_rect (with radius), fill_rounded_rect (per-corner
//! radii), line, push/pop clip (rectangular, pixel-snapped outward), push/pop
//! opacity, solid / linear / radial paints, and glyph runs (through a
//! `GlyphProvider`; without one, runs are skipped). Not yet: image patterns.
//! Unsupported commands are skipped.
//!
//! Text blends coverage straight over the destination in sRGB space (no gamma
//! correction or contrast tuning yet).
//!
//! Coordinates are logical pixels; `Options.scale` converts to device pixels.
//! Pixels are straight (non-premultiplied) RGBA, matching `geometry.Color`.

const std = @import("std");
const geometry = @import("../core/geometry.zig");
const draw_list = @import("../core/draw_list.zig");
const Rect = geometry.Rect;
const Vec2 = geometry.Vec2;
const Color = geometry.Color;
const Paint = draw_list.Paint;
const DrawList = draw_list.DrawList;
const Command = draw_list.Command;
const GlyphProvider = @import("../text/system.zig").GlyphProvider;

pub const Framebuffer = struct {
    pixels: []Color,
    width: u32,
    height: u32,

    pub fn init(allocator: std.mem.Allocator, width: u32, height: u32) !Framebuffer {
        const pixels = try allocator.alloc(Color, @as(usize, width) * height);
        @memset(pixels, Color.transparent);
        return .{ .pixels = pixels, .width = width, .height = height };
    }

    pub fn deinit(self: *Framebuffer, allocator: std.mem.Allocator) void {
        allocator.free(self.pixels);
        self.* = undefined;
    }

    /// Reallocate to a new size (contents are cleared).
    pub fn resize(self: *Framebuffer, allocator: std.mem.Allocator, width: u32, height: u32) !void {
        if (width == self.width and height == self.height) return;
        const pixels = try allocator.alloc(Color, @as(usize, width) * height);
        @memset(pixels, Color.transparent);
        allocator.free(self.pixels);
        self.* = .{ .pixels = pixels, .width = width, .height = height };
    }

    pub fn at(self: *const Framebuffer, x: u32, y: u32) Color {
        return self.pixels[@as(usize, y) * self.width + x];
    }

    pub fn bytes(self: *const Framebuffer) []const u8 {
        return std.mem.sliceAsBytes(self.pixels);
    }

    pub fn stride(self: *const Framebuffer) usize {
        return @as(usize, self.width) * @sizeOf(Color);
    }
};

pub const Options = struct {
    /// Device pixels per logical pixel.
    scale: f32 = 1,
    /// If set, the (damaged) area is cleared to this color first.
    clear: ?Color = null,
    /// Logical-pixel region to redraw. Everything outside is left untouched.
    damage: ?Rect = null,
    /// Source of glyph bitmaps for `glyph_run` commands.
    glyphs: ?GlyphProvider = null,
};

/// Half-open integer pixel rectangle.
const IRect = struct {
    x0: i32,
    y0: i32,
    x1: i32,
    y1: i32,

    fn intersect(a: IRect, b: IRect) IRect {
        return .{
            .x0 = @max(a.x0, b.x0),
            .y0 = @max(a.y0, b.y0),
            .x1 = @min(a.x1, b.x1),
            .y1 = @min(a.y1, b.y1),
        };
    }

    fn isEmpty(self: IRect) bool {
        return self.x1 <= self.x0 or self.y1 <= self.y0;
    }

    /// Smallest pixel rect covering `r`, grown by `pad` pixels on each side.
    fn covering(r: Rect, pad: f32) IRect {
        return .{
            .x0 = floorI(r.x - pad),
            .y0 = floorI(r.y - pad),
            .x1 = ceilI(r.right() + pad),
            .y1 = ceilI(r.bottom() + pad),
        };
    }
};

fn floorI(v: f32) i32 {
    return @intFromFloat(std.math.clamp(@floor(v), -1e9, 1e9));
}

fn ceilI(v: f32) i32 {
    return @intFromFloat(std.math.clamp(@ceil(v), -1e9, 1e9));
}

const max_clip_depth = 32;
const max_opacity_depth = 16;

/// Anti-aliased coverage of one shape, evaluated at pixel centers.
const Shape = union(enum) {
    /// Axis-aligned rectangle with square corners: exact area coverage.
    rect: Rect,
    round_box: struct { cx: f32, cy: f32, hw: f32, hh: f32, radii: [4]f32 },
    /// Border drawn inward from a rounded box edge.
    ring: struct { cx: f32, cy: f32, hw: f32, hh: f32, radius: f32, width: f32 },
    segment: struct { a: Vec2, b: Vec2, half_width: f32 },

    fn coverage(self: Shape, px: f32, py: f32) f32 {
        switch (self) {
            .rect => |r| {
                const cx = std.math.clamp(@min(px + 0.5, r.right()) - @max(px - 0.5, r.x), 0, 1);
                const cy = std.math.clamp(@min(py + 0.5, r.bottom()) - @max(py - 0.5, r.y), 0, 1);
                return cx * cy;
            },
            .round_box => |s| return edgeCoverage(sdRoundBox(px, py, s.cx, s.cy, s.hw, s.hh, s.radii)),
            .ring => |s| {
                const d = sdRoundBox(px, py, s.cx, s.cy, s.hw, s.hh, .{ s.radius, s.radius, s.radius, s.radius });
                return @max(edgeCoverage(d) - edgeCoverage(d + s.width), 0);
            },
            .segment => |s| {
                const abx = s.b.x - s.a.x;
                const aby = s.b.y - s.a.y;
                const apx = px - s.a.x;
                const apy = py - s.a.y;
                const len2 = abx * abx + aby * aby;
                const t = if (len2 > 0) std.math.clamp((apx * abx + apy * aby) / len2, 0, 1) else 0;
                const dx = apx - abx * t;
                const dy = apy - aby * t;
                return edgeCoverage(@sqrt(dx * dx + dy * dy) - s.half_width);
            },
        }
    }
};

/// Coverage for a pixel center at signed distance `d` from an edge (negative inside).
fn edgeCoverage(d: f32) f32 {
    return std.math.clamp(0.5 - d, 0, 1);
}

fn sdRoundBox(px: f32, py: f32, cx: f32, cy: f32, hw: f32, hh: f32, radii: [4]f32) f32 {
    const qx = px - cx;
    const qy = py - cy;
    // radii order: top-left, top-right, bottom-right, bottom-left.
    const r0 = if (qx < 0) (if (qy < 0) radii[0] else radii[3]) else (if (qy < 0) radii[1] else radii[2]);
    const r = @min(@max(r0, 0), @min(hw, hh));
    const dx = @abs(qx) - hw + r;
    const dy = @abs(qy) - hh + r;
    const ox = @max(dx, 0);
    const oy = @max(dy, 0);
    return @sqrt(ox * ox + oy * oy) + @min(@max(dx, dy), 0) - r;
}

fn lerpU8(a: u8, b: u8, t: f32) u8 {
    const v = @as(f32, @floatFromInt(a)) * (1 - t) + @as(f32, @floatFromInt(b)) * t;
    return @intFromFloat(std.math.clamp(@round(v), 0, 255));
}

fn lerpColor(a: Color, b: Color, t: f32) Color {
    return .{ .r = lerpU8(a.r, b.r, t), .g = lerpU8(a.g, b.g, t), .b = lerpU8(a.b, b.b, t), .a = lerpU8(a.a, b.a, t) };
}

/// Composite `src` over `dst` with extra `alpha` (coverage times opacity, 0..1).
fn blend(dst: *Color, src: Color, alpha: f32) void {
    const a = (@as(f32, @floatFromInt(src.a)) / 255.0) * alpha;
    if (a <= 0) return;
    if (a >= 0.999) {
        dst.* = .{ .r = src.r, .g = src.g, .b = src.b, .a = 255 };
        return;
    }
    const da = @as(f32, @floatFromInt(dst.a)) / 255.0;
    const out_a = a + da * (1 - a);
    const wd = da * (1 - a);
    const sr: f32 = @floatFromInt(src.r);
    const sg: f32 = @floatFromInt(src.g);
    const sb: f32 = @floatFromInt(src.b);
    const dr: f32 = @floatFromInt(dst.r);
    const dg: f32 = @floatFromInt(dst.g);
    const db: f32 = @floatFromInt(dst.b);
    dst.* = .{
        .r = toU8((sr * a + dr * wd) / out_a),
        .g = toU8((sg * a + dg * wd) / out_a),
        .b = toU8((sb * a + db * wd) / out_a),
        .a = toU8(out_a * 255.0),
    };
}

fn toU8(v: f32) u8 {
    return @intFromFloat(std.math.clamp(@round(v), 0, 255));
}

const Renderer = struct {
    fb: *Framebuffer,
    scale: f32,
    glyphs: ?GlyphProvider = null,
    glyph_items: []const draw_list.Glyph = &.{},

    clip: IRect,
    clips: [max_clip_depth]IRect = undefined,
    clip_n: usize = 0,
    clip_overflow: u32 = 0,

    opacity: f32 = 1,
    opacities: [max_opacity_depth]f32 = undefined,
    opacity_n: usize = 0,
    opacity_overflow: u32 = 0,

    fn scaled(self: *const Renderer, r: Rect) Rect {
        return .{ .x = r.x * self.scale, .y = r.y * self.scale, .w = r.w * self.scale, .h = r.h * self.scale };
    }

    fn paintAt(paint: Paint, scale: f32, px: f32, py: f32) Color {
        switch (paint.kind) {
            .solid => return paint.color,
            .linear_gradient => {
                const ax = paint.p0.x * scale;
                const ay = paint.p0.y * scale;
                const dx = paint.p1.x * scale - ax;
                const dy = paint.p1.y * scale - ay;
                const len2 = dx * dx + dy * dy;
                const t = if (len2 > 0) std.math.clamp(((px - ax) * dx + (py - ay) * dy) / len2, 0, 1) else 0;
                return lerpColor(paint.color, paint.color2, t);
            },
            .radial_gradient => {
                const ax = paint.p0.x * scale;
                const ay = paint.p0.y * scale;
                const rx = paint.p1.x * scale - ax;
                const ry = paint.p1.y * scale - ay;
                const radius = @sqrt(rx * rx + ry * ry);
                const dist = @sqrt((px - ax) * (px - ax) + (py - ay) * (py - ay));
                const t = if (radius > 0) std.math.clamp(dist / radius, 0, 1) else 0;
                return lerpColor(paint.color, paint.color2, t);
            },
            else => return Color.transparent,
        }
    }

    /// Rasterize `shape` over `bounds` (device pixels, already padded for AA).
    fn draw(self: *Renderer, bounds: IRect, shape: Shape, paint: Paint) void {
        const b = bounds.intersect(self.clip);
        if (b.isEmpty()) return;
        const solid_opaque = paint.kind == .solid and paint.color.a == 255 and self.opacity >= 0.999;
        const w: usize = self.fb.width;

        var y = b.y0;
        while (y < b.y1) : (y += 1) {
            const py = @as(f32, @floatFromInt(y)) + 0.5;
            const row = self.fb.pixels[@as(usize, @intCast(y)) * w ..][0..w];
            var x = b.x0;
            while (x < b.x1) : (x += 1) {
                const px = @as(f32, @floatFromInt(x)) + 0.5;
                const cov = shape.coverage(px, py);
                if (cov <= 0) continue;
                const dst = &row[@intCast(x)];
                if (solid_opaque and cov >= 0.999) {
                    dst.* = paint.color;
                } else {
                    blend(dst, paintAt(paint, self.scale, px, py), cov * self.opacity);
                }
            }
        }
    }

    fn fillRoundBox(self: *Renderer, r: Rect, radii: [4]f32, paint: Paint) void {
        const d = self.scaled(r);
        if (d.w <= 0 or d.h <= 0) return;
        const bounds = IRect.covering(d, 1);
        const sr = [4]f32{ radii[0] * self.scale, radii[1] * self.scale, radii[2] * self.scale, radii[3] * self.scale };
        if (sr[0] <= 0 and sr[1] <= 0 and sr[2] <= 0 and sr[3] <= 0) {
            self.draw(bounds, .{ .rect = d }, paint);
        } else {
            self.draw(bounds, .{ .round_box = .{
                .cx = d.x + d.w / 2,
                .cy = d.y + d.h / 2,
                .hw = d.w / 2,
                .hh = d.h / 2,
                .radii = sr,
            } }, paint);
        }
    }

    fn drawGlyphRun(self: *Renderer, cmd: Command) void {
        const provider = self.glyphs orelse return;
        const end = @as(usize, cmd.a) + cmd.b;
        if (end > self.glyph_items.len) return;
        const font_id: u32 = @intFromFloat(@max(cmd.params[0], 0));
        const size_px = cmd.params[1] * self.scale;
        const subpixel = cmd.params[2] != 0;
        const color = cmd.paint.color;
        const w: usize = self.fb.width;

        for (self.glyph_items[cmd.a..end]) |g| {
            const dx = g.x * self.scale;
            var ix: i32 = undefined;
            var sub: u8 = 0;
            if (subpixel) {
                const fl = @floor(dx);
                ix = floorI(fl);
                sub = @intFromFloat(std.math.clamp(@floor((dx - fl) * 4), 0, 3));
            } else {
                ix = floorI(@round(dx));
            }
            const iy = floorI(@round(g.y * self.scale));
            const img = provider.lookup(font_id, g.id, size_px, sub) orelse continue;
            if (img.w == 0 or img.h == 0) continue;

            const gx0 = ix + img.left;
            const gy0 = iy - img.top;
            const area = (IRect{ .x0 = gx0, .y0 = gy0, .x1 = gx0 + @as(i32, @intCast(img.w)), .y1 = gy0 + @as(i32, @intCast(img.h)) }).intersect(self.clip);
            if (area.isEmpty()) continue;

            var y = area.y0;
            while (y < area.y1) : (y += 1) {
                const src_row = img.pixels[(img.y + @as(u32, @intCast(y - gy0))) * img.stride + img.x ..];
                const row = self.fb.pixels[@as(usize, @intCast(y)) * w ..][0..w];
                var x = area.x0;
                while (x < area.x1) : (x += 1) {
                    const cov = src_row[@intCast(x - gx0)];
                    if (cov == 0) continue;
                    blend(&row[@intCast(x)], color, @as(f32, @floatFromInt(cov)) / 255.0 * self.opacity);
                }
            }
        }
    }

    fn execute(self: *Renderer, cmd: Command) void {
        switch (cmd.kind) {
            .fill_rect => self.fillRoundBox(cmd.rect, .{ 0, 0, 0, 0 }, cmd.paint),
            .fill_rounded_rect => self.fillRoundBox(cmd.rect, cmd.params, cmd.paint),
            .stroke_rect => {
                const d = self.scaled(cmd.rect);
                const width = cmd.params[0] * self.scale;
                if (d.w <= 0 or d.h <= 0 or width <= 0) return;
                self.draw(IRect.covering(d, 1), .{ .ring = .{
                    .cx = d.x + d.w / 2,
                    .cy = d.y + d.h / 2,
                    .hw = d.w / 2,
                    .hh = d.h / 2,
                    .radius = cmd.params[1] * self.scale,
                    .width = width,
                } }, cmd.paint);
            },
            .line => {
                const hw = @max(cmd.params[0] * self.scale, 0) / 2;
                const a: Vec2 = .{ .x = cmd.rect.x * self.scale, .y = cmd.rect.y * self.scale };
                const b: Vec2 = .{ .x = cmd.rect.w * self.scale, .y = cmd.rect.h * self.scale };
                const box: Rect = .{
                    .x = @min(a.x, b.x),
                    .y = @min(a.y, b.y),
                    .w = @abs(b.x - a.x),
                    .h = @abs(b.y - a.y),
                };
                self.draw(IRect.covering(box, hw + 1), .{ .segment = .{ .a = a, .b = b, .half_width = hw } }, cmd.paint);
            },
            .push_clip => {
                if (self.clip_n == max_clip_depth) {
                    self.clip_overflow += 1;
                    return;
                }
                self.clips[self.clip_n] = self.clip;
                self.clip_n += 1;
                self.clip = self.clip.intersect(IRect.covering(self.scaled(cmd.rect), 0));
            },
            .pop_clip => {
                if (self.clip_overflow > 0) {
                    self.clip_overflow -= 1;
                } else if (self.clip_n > 0) {
                    self.clip_n -= 1;
                    self.clip = self.clips[self.clip_n];
                }
            },
            .push_opacity => {
                if (self.opacity_n == max_opacity_depth) {
                    self.opacity_overflow += 1;
                    return;
                }
                self.opacities[self.opacity_n] = self.opacity;
                self.opacity_n += 1;
                self.opacity *= std.math.clamp(cmd.params[0], 0, 1);
            },
            .pop_opacity => {
                if (self.opacity_overflow > 0) {
                    self.opacity_overflow -= 1;
                } else if (self.opacity_n > 0) {
                    self.opacity_n -= 1;
                    self.opacity = self.opacities[self.opacity_n];
                }
            },
            .glyph_run => self.drawGlyphRun(cmd),
            // Image paints and unknown kinds are skipped.
            _ => {},
        }
    }
};

/// Execute `list` into `fb`.
pub fn render(fb: *Framebuffer, list: *const DrawList, opts: Options) void {
    var bounds: IRect = .{ .x0 = 0, .y0 = 0, .x1 = @intCast(fb.width), .y1 = @intCast(fb.height) };
    if (opts.damage) |dmg| {
        const d: Rect = .{ .x = dmg.x * opts.scale, .y = dmg.y * opts.scale, .w = dmg.w * opts.scale, .h = dmg.h * opts.scale };
        bounds = bounds.intersect(IRect.covering(d, 0));
    }
    var r: Renderer = .{ .fb = fb, .scale = opts.scale, .clip = bounds, .glyphs = opts.glyphs, .glyph_items = list.glyphItems() };

    if (opts.clear) |c| {
        var y = bounds.y0;
        while (y < bounds.y1) : (y += 1) {
            const start = @as(usize, @intCast(y)) * fb.width + @as(usize, @intCast(bounds.x0));
            const n: usize = @intCast(@max(bounds.x1 - bounds.x0, 0));
            @memset(fb.pixels[start..][0..n], c);
        }
    }
    for (list.items()) |cmd| r.execute(cmd);
}

// ---- tests -----------------------------------------------------------------

fn testList(storage: []Command) DrawList {
    return DrawList.init(storage, &.{});
}

test "solid rect fills exactly the pixels it covers" {
    var fb = try Framebuffer.init(std.testing.allocator, 10, 10);
    defer fb.deinit(std.testing.allocator);
    var cmds: [8]Command = undefined;
    var dl = testList(&cmds);
    try dl.fillRect(.{ .x = 2, .y = 3, .w = 4, .h = 2 }, Paint.solid(Color.rgb(255, 0, 0)));
    render(&fb, &dl, .{ .clear = Color.white });

    try std.testing.expectEqual(Color.rgb(255, 0, 0), fb.at(2, 3));
    try std.testing.expectEqual(Color.rgb(255, 0, 0), fb.at(5, 4));
    try std.testing.expectEqual(Color.white, fb.at(1, 3));
    try std.testing.expectEqual(Color.white, fb.at(6, 3));
    try std.testing.expectEqual(Color.white, fb.at(2, 5));
}

test "fractional rect edges are anti-aliased" {
    var fb = try Framebuffer.init(std.testing.allocator, 4, 1);
    defer fb.deinit(std.testing.allocator);
    var cmds: [4]Command = undefined;
    var dl = testList(&cmds);
    try dl.fillRect(.{ .x = 0.5, .y = 0, .w = 2, .h = 1 }, Paint.solid(Color.black));
    render(&fb, &dl, .{ .clear = Color.white });
    try std.testing.expectEqual(@as(u8, 128), fb.at(0, 0).r); // half covered
    try std.testing.expectEqual(@as(u8, 0), fb.at(1, 0).r);
    try std.testing.expectEqual(@as(u8, 128), fb.at(2, 0).r);
    try std.testing.expectEqual(@as(u8, 255), fb.at(3, 0).r);
}

test "clip restricts drawing and pop restores it" {
    var fb = try Framebuffer.init(std.testing.allocator, 10, 10);
    defer fb.deinit(std.testing.allocator);
    var cmds: [8]Command = undefined;
    var dl = testList(&cmds);
    const red = Paint.solid(Color.rgb(255, 0, 0));
    try dl.pushClip(.{ .x = 0, .y = 0, .w = 5, .h = 10 });
    try dl.fillRect(.{ .x = 0, .y = 0, .w = 10, .h = 1 }, red);
    _ = try dl.popClip();
    try dl.fillRect(.{ .x = 0, .y = 1, .w = 10, .h = 1 }, red);
    render(&fb, &dl, .{ .clear = Color.white });

    try std.testing.expectEqual(Color.rgb(255, 0, 0), fb.at(4, 0));
    try std.testing.expectEqual(Color.white, fb.at(5, 0));
    try std.testing.expectEqual(Color.rgb(255, 0, 0), fb.at(9, 1));
}

test "opacity blends over the background" {
    var fb = try Framebuffer.init(std.testing.allocator, 2, 1);
    defer fb.deinit(std.testing.allocator);
    var cmds: [8]Command = undefined;
    var dl = testList(&cmds);
    try dl.pushOpacity(0.5);
    try dl.fillRect(.{ .x = 0, .y = 0, .w = 1, .h = 1 }, Paint.solid(Color.black));
    _ = try dl.popOpacity();
    try dl.fillRect(.{ .x = 1, .y = 0, .w = 1, .h = 1 }, Paint.solid(Color.black));
    render(&fb, &dl, .{ .clear = Color.white });
    try std.testing.expectEqual(@as(u8, 128), fb.at(0, 0).r);
    try std.testing.expectEqual(@as(u8, 0), fb.at(1, 0).r);
}

test "rounded rect leaves its corner pixel untouched" {
    var fb = try Framebuffer.init(std.testing.allocator, 20, 20);
    defer fb.deinit(std.testing.allocator);
    var cmds: [4]Command = undefined;
    var dl = testList(&cmds);
    try dl.fillRoundedRect(.{ .x = 0, .y = 0, .w = 20, .h = 20 }, .{ 8, 8, 8, 8 }, Paint.solid(Color.black));
    render(&fb, &dl, .{ .clear = Color.white });
    try std.testing.expectEqual(Color.white, fb.at(0, 0));
    try std.testing.expectEqual(Color.black, fb.at(10, 10));
    try std.testing.expectEqual(Color.black, fb.at(10, 0)); // straight edge is solid
}

test "stroke draws a border and leaves the interior" {
    var fb = try Framebuffer.init(std.testing.allocator, 10, 10);
    defer fb.deinit(std.testing.allocator);
    var cmds: [4]Command = undefined;
    var dl = testList(&cmds);
    try dl.strokeRect(.{ .x = 0, .y = 0, .w = 10, .h = 10 }, 2, Paint.solid(Color.black));
    render(&fb, &dl, .{ .clear = Color.white });
    try std.testing.expectEqual(Color.black, fb.at(0, 5));
    try std.testing.expectEqual(Color.black, fb.at(1, 5));
    try std.testing.expectEqual(Color.white, fb.at(2, 5));
    try std.testing.expectEqual(Color.white, fb.at(5, 5));
    try std.testing.expectEqual(Color.black, fb.at(5, 9));
}

test "linear gradient interpolates across the rect" {
    var fb = try Framebuffer.init(std.testing.allocator, 100, 1);
    defer fb.deinit(std.testing.allocator);
    var cmds: [4]Command = undefined;
    var dl = testList(&cmds);
    const p = Paint.linear(.{ .x = 0, .y = 0 }, .{ .x = 100, .y = 0 }, Color.black, Color.white);
    try dl.fillRect(.{ .x = 0, .y = 0, .w = 100, .h = 1 }, p);
    render(&fb, &dl, .{});
    try std.testing.expect(fb.at(0, 0).r < 5);
    try std.testing.expect(fb.at(99, 0).r > 250);
    try std.testing.expect(@abs(@as(i32, fb.at(50, 0).r) - 128) < 4);
}

test "scale multiplies logical coordinates" {
    var fb = try Framebuffer.init(std.testing.allocator, 20, 20);
    defer fb.deinit(std.testing.allocator);
    var cmds: [4]Command = undefined;
    var dl = testList(&cmds);
    try dl.fillRect(.{ .x = 1, .y = 1, .w = 2, .h = 2 }, Paint.solid(Color.black));
    render(&fb, &dl, .{ .clear = Color.white, .scale = 2 });
    try std.testing.expectEqual(Color.black, fb.at(2, 2));
    try std.testing.expectEqual(Color.black, fb.at(5, 5));
    try std.testing.expectEqual(Color.white, fb.at(6, 6));
    try std.testing.expectEqual(Color.white, fb.at(1, 1));
}

test "damage rect limits what is redrawn" {
    var fb = try Framebuffer.init(std.testing.allocator, 10, 1);
    defer fb.deinit(std.testing.allocator);
    var cmds: [4]Command = undefined;
    var dl = testList(&cmds);
    try dl.fillRect(.{ .x = 0, .y = 0, .w = 10, .h = 1 }, Paint.solid(Color.black));
    render(&fb, &dl, .{ .clear = Color.white });
    // Redraw only x in [0, 5) with a new background and no content.
    dl.reset();
    render(&fb, &dl, .{ .clear = Color.rgb(9, 9, 9), .damage = .{ .x = 0, .y = 0, .w = 5, .h = 1 } });
    try std.testing.expectEqual(Color.rgb(9, 9, 9), fb.at(4, 0));
    try std.testing.expectEqual(Color.black, fb.at(5, 0));
}

test "line covers its path" {
    var fb = try Framebuffer.init(std.testing.allocator, 10, 10);
    defer fb.deinit(std.testing.allocator);
    var cmds: [4]Command = undefined;
    var dl = testList(&cmds);
    try dl.line(.{ .x = 0, .y = 5 }, .{ .x = 10, .y = 5 }, 2, Paint.solid(Color.black));
    render(&fb, &dl, .{ .clear = Color.white });
    try std.testing.expectEqual(Color.black, fb.at(5, 4));
    try std.testing.expectEqual(Color.black, fb.at(5, 5));
    try std.testing.expectEqual(Color.white, fb.at(5, 2));
}

test "glyph runs blit atlas coverage at the pen position" {
    const font = @import("../text/font.zig");
    const system = @import("../text/system.zig");
    var tf: font.TestFont = .{};
    var ts = system.TextSystem.init(std.testing.allocator);
    defer ts.deinit();
    const f = try ts.addFont(tf.backend());

    var fb = try Framebuffer.init(std.testing.allocator, 40, 30);
    defer fb.deinit(std.testing.allocator);
    var cmds: [4]Command = undefined;
    var glyphs: [4]draw_list.Glyph = undefined;
    var dl = DrawList.init(&cmds, &glyphs);
    // Test-font 'x' at size 10: box is (5 wide, 7 tall) sitting on the baseline.
    const run = [_]draw_list.Glyph{.{ .id = 'x', .x = 10, .y = 20 }};
    try dl.glyphRun(.{ .x = 10, .y = 13, .w = 6, .h = 7 }, &run, Color.black, f, 10);
    render(&fb, &dl, .{ .clear = Color.white, .glyphs = ts.provider() });

    try std.testing.expectEqual(Color.black, fb.at(10, 19)); // just above the baseline
    try std.testing.expectEqual(Color.black, fb.at(10, 13)); // top row of the box
    try std.testing.expectEqual(Color.white, fb.at(10, 20)); // below the baseline
    try std.testing.expectEqual(Color.white, fb.at(9, 15)); // left of the pen
    try std.testing.expectEqual(Color.white, fb.at(10, 12)); // above the box
}

test "glyph runs respect clip and opacity, and are skipped without a provider" {
    const font = @import("../text/font.zig");
    const system = @import("../text/system.zig");
    var tf: font.TestFont = .{};
    var ts = system.TextSystem.init(std.testing.allocator);
    defer ts.deinit();
    const f = try ts.addFont(tf.backend());

    var fb = try Framebuffer.init(std.testing.allocator, 40, 30);
    defer fb.deinit(std.testing.allocator);
    var cmds: [8]Command = undefined;
    var glyphs: [4]draw_list.Glyph = undefined;
    var dl = DrawList.init(&cmds, &glyphs);
    const run = [_]draw_list.Glyph{.{ .id = 'x', .x = 10, .y = 20 }};
    try dl.pushClip(.{ .x = 0, .y = 0, .w = 12, .h = 30 });
    try dl.pushOpacity(0.5);
    try dl.glyphRun(.{}, &run, Color.black, f, 10);
    _ = try dl.popOpacity();
    _ = try dl.popClip();

    render(&fb, &dl, .{ .clear = Color.white, .glyphs = ts.provider() });
    try std.testing.expectEqual(@as(u8, 128), fb.at(11, 15).r); // half opacity, inside clip
    try std.testing.expectEqual(Color.white, fb.at(12, 15)); // clipped

    render(&fb, &dl, .{ .clear = Color.white }); // no provider
    try std.testing.expectEqual(Color.white, fb.at(11, 15));
}

test "glyph runs rasterize at the device size when scaled" {
    const font = @import("../text/font.zig");
    const system = @import("../text/system.zig");
    var tf: font.TestFont = .{};
    var ts = system.TextSystem.init(std.testing.allocator);
    defer ts.deinit();
    const f = try ts.addFont(tf.backend());

    var fb = try Framebuffer.init(std.testing.allocator, 60, 60);
    defer fb.deinit(std.testing.allocator);
    var cmds: [4]Command = undefined;
    var glyphs: [4]draw_list.Glyph = undefined;
    var dl = DrawList.init(&cmds, &glyphs);
    const run = [_]draw_list.Glyph{.{ .id = 'x', .x = 10, .y = 20 }};
    try dl.glyphRun(.{}, &run, Color.black, f, 10);
    render(&fb, &dl, .{ .clear = Color.white, .glyphs = ts.provider(), .scale = 2 });

    // At 2x the pen is at (20, 40) and the glyph is rasterized at size 20: 10 wide, 14 tall.
    try std.testing.expectEqual(Color.black, fb.at(20, 26));
    try std.testing.expectEqual(Color.black, fb.at(29, 39));
    try std.testing.expectEqual(Color.white, fb.at(30, 30));
    try std.testing.expectEqual(Color.white, fb.at(20, 40));
    try std.testing.expectEqual(Color.white, fb.at(20, 25));
}
