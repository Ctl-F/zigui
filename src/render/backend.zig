//! The renderer backend interface (design doc sections 19 and 22).
//!
//! A backend turns a `DrawList` into pixels on some target. The engine never
//! touches a backend's resources: textures are opaque generational handles the
//! backend issues and owns, and glyph bitmaps reach it through atlas page
//! uploads. Software rendering is the first implementation
//! (`software_backend.zig`); a GPU backend implements the same table.
//!
//! One frame is:
//!
//!     beginFrame(info)        target size and scale
//!     submit(...)             one or more draw lists (usually one)
//!     endFrame()              present
//!
//! Atlas pages: a backend that keeps glyphs in its own memory (`caps.atlas_upload`)
//! needs pages uploaded before it draws. The engine calls `prepareGlyphs` to make
//! sure every glyph in the list is in the atlas, then `uploadAtlasPage` for each
//! changed page, then `submit`. A backend that can read the atlas directly (the
//! software renderer) leaves `atlas_upload` false and skips that work.
//!
//! Coordinates in a draw list are logical pixels; `FrameInfo.scale` converts to
//! device pixels. `damage`, if given, is a logical-pixel region to redraw; the
//! rest of the target keeps its previous contents.

const std = @import("std");
const geometry = @import("../core/geometry.zig");
const draw_list = @import("../core/draw_list.zig");
const Handle = @import("../core/handle.zig").Handle;
const GlyphProvider = @import("../text/system.zig").GlyphProvider;

pub const Rect = geometry.Rect;
pub const Color = geometry.Color;
pub const DrawList = draw_list.DrawList;

pub const Error = error{
    OutOfMemory,
    /// The device or target went away; recreate the backend.
    DeviceLost,
    PresentFailed,
    /// The backend does not implement this operation (see `Caps`).
    Unsupported,
    /// A texture handle is stale or was never issued.
    BadTexture,
    /// `submit` or `endFrame` outside a frame, or `beginFrame` inside one.
    BadFrameState,
    TextureTooLarge,
};

pub const TextureFormat = enum {
    /// 8-bit straight RGBA.
    rgba8,
    /// 8-bit coverage (glyph-like masks).
    alpha8,

    pub fn bytesPerPixel(self: TextureFormat) u32 {
        return switch (self) {
            .rgba8 => 4,
            .alpha8 => 1,
        };
    }
};

pub const TextureDesc = struct {
    width: u32,
    height: u32,
    format: TextureFormat = .rgba8,
};

/// Opaque handle to a backend-owned texture. Generational, like every handle.
pub const TextureId = Handle;

pub const Caps = struct {
    name: []const u8,
    /// `createTexture` and friends work.
    textures: bool = false,
    /// `readback` works (screenshots, tests).
    readback: bool = false,
    /// The backend keeps glyphs in its own memory: upload atlas pages.
    atlas_upload: bool = false,
    max_texture_size: u32 = 0,
};

pub const FrameInfo = struct {
    /// Target size in device pixels.
    pixel_w: u32,
    pixel_h: u32,
    /// Device pixels per logical pixel.
    scale: f32 = 1,
};

pub const Submit = struct {
    list: *const DrawList,
    /// Fill the (damaged) target with this color first.
    clear: ?Color = null,
    /// Logical-pixel region to redraw; null means everything.
    damage: ?Rect = null,
    /// Where glyph bitmaps come from (backends without `atlas_upload` read it
    /// directly while drawing).
    glyphs: ?GlyphProvider = null,
};

pub const VTable = struct {
    caps: Caps,
    begin_frame: *const fn (ctx: *anyopaque, info: FrameInfo) Error!void,
    submit: *const fn (ctx: *anyopaque, s: Submit) Error!void,
    end_frame: *const fn (ctx: *anyopaque) Error!void,
    create_texture: *const fn (ctx: *anyopaque, desc: TextureDesc) Error!TextureId,
    /// Replace `rect` (pixels) of the texture from `pixels` (rows `stride` bytes apart).
    update_texture: *const fn (ctx: *anyopaque, id: TextureId, rect: URect, pixels: []const u8, stride: usize) Error!void,
    destroy_texture: *const fn (ctx: *anyopaque, id: TextureId) void,
    upload_atlas_page: *const fn (ctx: *anyopaque, page: u8, pixels: []const u8, size: u32) Error!void,
    /// RGBA8 copy of the last completed frame, owned by the caller.
    readback: *const fn (ctx: *anyopaque, gpa: std.mem.Allocator) Error!Image,
};

/// Integer pixel rectangle.
pub const URect = struct { x: u32, y: u32, w: u32, h: u32 };

pub const Image = struct {
    width: u32,
    height: u32,
    /// Tightly packed RGBA8, `width * height * 4` bytes.
    rgba: []u8,

    pub fn deinit(self: Image, gpa: std.mem.Allocator) void {
        gpa.free(self.rgba);
    }
};

pub const Backend = struct {
    ctx: *anyopaque,
    vtable: *const VTable,

    pub fn caps(self: Backend) Caps {
        return self.vtable.caps;
    }

    pub fn beginFrame(self: Backend, info: FrameInfo) Error!void {
        return self.vtable.begin_frame(self.ctx, info);
    }

    pub fn submit(self: Backend, s: Submit) Error!void {
        return self.vtable.submit(self.ctx, s);
    }

    pub fn endFrame(self: Backend) Error!void {
        return self.vtable.end_frame(self.ctx);
    }

    pub fn createTexture(self: Backend, desc: TextureDesc) Error!TextureId {
        return self.vtable.create_texture(self.ctx, desc);
    }

    pub fn updateTexture(self: Backend, id: TextureId, rect: URect, pixels: []const u8, stride: usize) Error!void {
        return self.vtable.update_texture(self.ctx, id, rect, pixels, stride);
    }

    pub fn destroyTexture(self: Backend, id: TextureId) void {
        self.vtable.destroy_texture(self.ctx, id);
    }

    pub fn uploadAtlasPage(self: Backend, page: u8, pixels: []const u8, size: u32) Error!void {
        return self.vtable.upload_atlas_page(self.ctx, page, pixels, size);
    }

    pub fn readback(self: Backend, gpa: std.mem.Allocator) Error!Image {
        return self.vtable.readback(self.ctx, gpa);
    }
};

/// Make sure every glyph `list` draws is in the atlas (so a backend with
/// `atlas_upload` can upload before it draws). Mirrors how the software
/// renderer picks glyph size and subpixel bucket.
pub fn prepareGlyphs(list: *const DrawList, scale: f32, provider: GlyphProvider) void {
    const items = list.glyphItems();
    for (list.items()) |cmd| switch (cmd) {
        .glyph_run => |run| {
            const end = @as(usize, run.offset) + run.count;
            if (end > items.len) continue;
            const size_px = run.size * scale;
            for (items[run.offset..end]) |g| {
                var sub: u8 = 0;
                if (run.subpixel) {
                    const dx = g.x * scale;
                    sub = @intFromFloat(std.math.clamp(@floor((dx - @floor(dx)) * 4), 0, 3));
                }
                _ = provider.lookup(run.font, g.id, size_px, sub);
            }
        },
        else => {},
    };
}
