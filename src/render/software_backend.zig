//! The software renderer as a `Backend` (see `backend.zig`).
//!
//! Owns an RGBA8 framebuffer sized by `beginFrame`, draws with
//! `software.render`, and hands the finished frame to an optional `Presenter`
//! (the platform shim uploads it to the window). Textures live in a pool of CPU
//! buffers; no draw command samples them yet, but the contract is complete so
//! image and canvas commands can arrive without changing backends. Atlas pages
//! are read directly through the glyph provider, so `uploadAtlasPage` only
//! counts.

const std = @import("std");
const backend_mod = @import("backend.zig");
const software = @import("software.zig");
const Pool = @import("../core/pool.zig").Pool;
const Handle = @import("../core/handle.zig").Handle;

const Backend = backend_mod.Backend;
const Error = backend_mod.Error;

/// Shows a finished frame (RGBA8, tightly packed) somewhere.
pub const Presenter = struct {
    ctx: ?*anyopaque = null,
    present: *const fn (ctx: ?*anyopaque, rgba: []const u8, w: u32, h: u32) Error!void,
};

const Texture = struct {
    desc: backend_mod.TextureDesc,
    pixels: []u8,
};

pub const max_texture_size: u32 = 16384;

pub const SoftwareBackend = struct {
    gpa: std.mem.Allocator,
    fb: software.Framebuffer,
    presenter: ?Presenter,
    scale: f32 = 1,
    in_frame: bool = false,
    textures: Pool(Texture, 32),
    /// Frames presented and atlas uploads seen (useful in tests and stats).
    frames: u64 = 0,
    atlas_uploads: u64 = 0,

    pub fn init(gpa: std.mem.Allocator, presenter: ?Presenter) !SoftwareBackend {
        return .{
            .gpa = gpa,
            .fb = try software.Framebuffer.init(gpa, 1, 1),
            .presenter = presenter,
            .textures = Pool(Texture, 32).init(gpa),
        };
    }

    pub fn deinit(self: *SoftwareBackend) void {
        var it = self.textures.iterator();
        while (it.next()) |e| self.gpa.free(e.ptr.pixels);
        self.textures.deinit();
        self.fb.deinit(self.gpa);
    }

    pub fn backend(self: *SoftwareBackend) Backend {
        return .{ .ctx = self, .vtable = &vtable };
    }

    const vtable: backend_mod.VTable = .{
        .caps = .{ .name = "software", .textures = true, .readback = true, .atlas_upload = false, .max_texture_size = max_texture_size },
        .begin_frame = beginFrame,
        .submit = submit,
        .end_frame = endFrame,
        .create_texture = createTexture,
        .update_texture = updateTexture,
        .destroy_texture = destroyTexture,
        .upload_atlas_page = uploadAtlasPage,
        .readback = readback,
    };

    fn self_(ctx: *anyopaque) *SoftwareBackend {
        return @ptrCast(@alignCast(ctx));
    }

    fn beginFrame(ctx: *anyopaque, info: backend_mod.FrameInfo) Error!void {
        const self = self_(ctx);
        if (self.in_frame) return error.BadFrameState;
        self.fb.resize(self.gpa, @max(info.pixel_w, 1), @max(info.pixel_h, 1)) catch return error.OutOfMemory;
        self.scale = info.scale;
        self.in_frame = true;
    }

    fn submit(ctx: *anyopaque, s: backend_mod.Submit) Error!void {
        const self = self_(ctx);
        if (!self.in_frame) return error.BadFrameState;
        software.render(&self.fb, s.list, .{ .scale = self.scale, .clear = s.clear, .damage = s.damage, .glyphs = s.glyphs });
    }

    fn endFrame(ctx: *anyopaque) Error!void {
        const self = self_(ctx);
        if (!self.in_frame) return error.BadFrameState;
        self.in_frame = false;
        self.frames += 1;
        if (self.presenter) |p| try p.present(p.ctx, self.fb.bytes(), self.fb.width, self.fb.height);
    }

    fn createTexture(ctx: *anyopaque, desc: backend_mod.TextureDesc) Error!backend_mod.TextureId {
        const self = self_(ctx);
        if (desc.width == 0 or desc.height == 0 or desc.width > max_texture_size or desc.height > max_texture_size) return error.TextureTooLarge;
        const len = @as(usize, desc.width) * desc.height * desc.format.bytesPerPixel();
        const pixels = self.gpa.alloc(u8, len) catch return error.OutOfMemory;
        errdefer self.gpa.free(pixels);
        @memset(pixels, 0);
        return self.textures.create(.{ .desc = desc, .pixels = pixels }) catch error.OutOfMemory;
    }

    fn updateTexture(ctx: *anyopaque, id: backend_mod.TextureId, rect: backend_mod.URect, pixels: []const u8, stride: usize) Error!void {
        const self = self_(ctx);
        const t = self.textures.get(id) orelse return error.BadTexture;
        if (rect.x + rect.w > t.desc.width or rect.y + rect.h > t.desc.height) return error.BadTexture;
        const bpp = t.desc.format.bytesPerPixel();
        const row_bytes = @as(usize, rect.w) * bpp;
        if (rect.h > 0 and pixels.len < (rect.h - 1) * stride + row_bytes) return error.BadTexture;
        for (0..rect.h) |row| {
            const dst = ((@as(usize, rect.y) + row) * t.desc.width + rect.x) * bpp;
            @memcpy(t.pixels[dst..][0..row_bytes], pixels[row * stride ..][0..row_bytes]);
        }
    }

    fn destroyTexture(ctx: *anyopaque, id: backend_mod.TextureId) void {
        const self = self_(ctx);
        if (self.textures.get(id)) |t| {
            self.gpa.free(t.pixels);
            _ = self.textures.destroy(id);
        }
    }

    fn uploadAtlasPage(ctx: *anyopaque, _: u8, _: []const u8, _: u32) Error!void {
        self_(ctx).atlas_uploads += 1;
    }

    fn readback(ctx: *anyopaque, gpa: std.mem.Allocator) Error!backend_mod.Image {
        const self = self_(ctx);
        const rgba = gpa.dupe(u8, self.fb.bytes()) catch return error.OutOfMemory;
        return .{ .width = self.fb.width, .height = self.fb.height, .rgba = rgba };
    }
};

// ---- tests -----------------------------------------------------------------

const testing = std.testing;
const geometry = @import("../core/geometry.zig");
const draw_list = @import("../core/draw_list.zig");
const Color = geometry.Color;

fn tinyList(storage: *[8]draw_list.Command, glyphs: *[4]draw_list.Glyph) draw_list.DrawList {
    var l = draw_list.DrawList.init(storage, glyphs);
    l.fillRect(.{ .x = 1, .y = 1, .w = 2, .h = 2 }, .{ .color = Color.rgb(255, 0, 0) }) catch unreachable;
    return l;
}

test "a frame draws, presents once, and reads back" {
    const Sink = struct {
        var calls: u32 = 0;
        var w: u32 = 0;
        fn present(_: ?*anyopaque, rgba: []const u8, pw: u32, ph: u32) Error!void {
            calls += 1;
            w = pw;
            if (rgba.len != @as(usize, pw) * ph * 4) return error.PresentFailed;
        }
    };
    Sink.calls = 0;
    var sb = try SoftwareBackend.init(testing.allocator, .{ .present = Sink.present });
    defer sb.deinit();
    const be = sb.backend();
    try testing.expectEqualStrings("software", be.caps().name);

    var cmds: [8]draw_list.Command = undefined;
    var gl: [4]draw_list.Glyph = undefined;
    const list = tinyList(&cmds, &gl);
    try be.beginFrame(.{ .pixel_w = 8, .pixel_h = 6, .scale = 1 });
    try be.submit(.{ .list = &list, .clear = Color.rgb(0, 0, 255) });
    try be.endFrame();
    try testing.expectEqual(@as(u32, 1), Sink.calls);
    try testing.expectEqual(@as(u32, 8), Sink.w);

    const img = try be.readback(testing.allocator);
    defer img.deinit(testing.allocator);
    try testing.expectEqual(@as(u32, 8), img.width);
    try testing.expectEqualSlices(u8, &.{ 255, 0, 0, 255 }, img.rgba[(1 * 8 + 1) * 4 ..][0..4]); // drawn
    try testing.expectEqualSlices(u8, &.{ 0, 0, 255, 255 }, img.rgba[0..4]); // cleared
}

test "scale and damage reach the rasterizer" {
    var sb = try SoftwareBackend.init(testing.allocator, null);
    defer sb.deinit();
    const be = sb.backend();
    var cmds: [8]draw_list.Command = undefined;
    var gl: [4]draw_list.Glyph = undefined;
    const list = tinyList(&cmds, &gl);

    try be.beginFrame(.{ .pixel_w = 8, .pixel_h = 8, .scale = 2 });
    try be.submit(.{ .list = &list, .clear = Color.rgb(9, 9, 9) });
    try be.endFrame();
    var img = try be.readback(testing.allocator);
    // The 2x2 logical square at (1,1) covers device pixels 2..6.
    try testing.expectEqualSlices(u8, &.{ 255, 0, 0, 255 }, img.rgba[(5 * 8 + 5) * 4 ..][0..4]);
    try testing.expectEqualSlices(u8, &.{ 9, 9, 9, 255 }, img.rgba[(6 * 8 + 6) * 4 ..][0..4]);
    img.deinit(testing.allocator);

    // Damaged redraw clears only the damage rect.
    try be.beginFrame(.{ .pixel_w = 8, .pixel_h = 8, .scale = 2 });
    try be.submit(.{ .list = &list, .clear = Color.rgb(1, 2, 3), .damage = .{ .x = 3, .y = 3, .w = 1, .h = 1 } });
    try be.endFrame();
    img = try be.readback(testing.allocator);
    defer img.deinit(testing.allocator);
    try testing.expectEqualSlices(u8, &.{ 1, 2, 3, 255 }, img.rgba[(6 * 8 + 6) * 4 ..][0..4]);
    try testing.expectEqualSlices(u8, &.{ 9, 9, 9, 255 }, img.rgba[(0 * 8 + 0) * 4 ..][0..4]); // outside damage: kept
}

test "frame state is enforced" {
    var sb = try SoftwareBackend.init(testing.allocator, null);
    defer sb.deinit();
    const be = sb.backend();
    var cmds: [8]draw_list.Command = undefined;
    var gl: [4]draw_list.Glyph = undefined;
    const list = tinyList(&cmds, &gl);
    try testing.expectError(error.BadFrameState, be.submit(.{ .list = &list }));
    try testing.expectError(error.BadFrameState, be.endFrame());
    try be.beginFrame(.{ .pixel_w = 2, .pixel_h = 2 });
    try testing.expectError(error.BadFrameState, be.beginFrame(.{ .pixel_w = 2, .pixel_h = 2 }));
    try be.endFrame();
}

test "textures: create, update a sub-rectangle, destroy, and stale handles fail" {
    var sb = try SoftwareBackend.init(testing.allocator, null);
    defer sb.deinit();
    const be = sb.backend();
    const t = try be.createTexture(.{ .width = 4, .height = 4, .format = .alpha8 });
    const src = [_]u8{ 1, 2, 3, 4, 5, 6, 7, 8 };
    try be.updateTexture(t, .{ .x = 1, .y = 1, .w = 2, .h = 2 }, &src, 4);
    const px = sb.textures.get(t).?.pixels;
    try testing.expectEqual(@as(u8, 1), px[1 * 4 + 1]);
    try testing.expectEqual(@as(u8, 2), px[1 * 4 + 2]);
    try testing.expectEqual(@as(u8, 5), px[2 * 4 + 1]);
    try testing.expectEqual(@as(u8, 0), px[0]);
    try testing.expectError(error.BadTexture, be.updateTexture(t, .{ .x = 3, .y = 3, .w = 2, .h = 1 }, &src, 4));
    try testing.expectError(error.BadTexture, be.updateTexture(t, .{ .x = 0, .y = 0, .w = 2, .h = 2 }, src[0..3], 4));
    try testing.expectError(error.TextureTooLarge, be.createTexture(.{ .width = 0, .height = 4 }));
    be.destroyTexture(t);
    try testing.expectError(error.BadTexture, be.updateTexture(t, .{ .x = 0, .y = 0, .w = 1, .h = 1 }, &src, 4));
    be.destroyTexture(t); // destroying twice is harmless
}

test "destroying the backend frees leftover textures" {
    var sb = try SoftwareBackend.init(testing.allocator, null);
    const be = sb.backend();
    _ = try be.createTexture(.{ .width = 8, .height = 8 });
    _ = try be.createTexture(.{ .width = 2, .height = 2, .format = .alpha8 });
    sb.deinit();
}
