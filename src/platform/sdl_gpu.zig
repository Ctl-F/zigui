//! SDL3 GPU renderer backend (design doc section 22): the `Backend` interface
//! implemented on Vulkan, Metal, or Direct3D 12 through SDL's GPU API.
//!
//! Every frame is drawn into a persistent offscreen target (so partial redraws
//! keep what is already there) and, if a window is attached, blitted to the
//! swapchain at `endFrame`. Without a window the backend is headless: draw, then
//! `readback`. Glyphs live in R8 atlas textures uploaded from the engine's atlas
//! pages (`caps.atlas_upload`), images and canvas surfaces in RGBA8/R8 textures.
//!
//! One pipeline and one shader pair draw everything. A draw list is turned into
//! a flat vertex stream (six vertices per quad), batched by texture and scissor,
//! uploaded once, and drawn in a single render pass. Shapes are signed distance
//! fields evaluated per pixel in the fragment shader, the same math as the
//! software rasterizer, so the two backends agree to within rounding.
//!
//! Shaders are SPIR-V (GLSL in `shaders/`, compiled with `zig build shaders` and
//! committed), so the Vulkan driver works out of the box. Metal and D3D12 need
//! the same shaders converted (SDL_shadercross); see the README.
//!
//! Needs SDL3 with GPU support. Headless use (tests, servers) works with
//! `SDL_VIDEO_DRIVER=offscreen`.

const std = @import("std");
const c = @import("sdl_c");
const zigui = @import("zigui");
const rb = zigui.render_backend;
const draw_list = zigui.draw_list;
const geometry = zigui.geometry;
const Rect = geometry.Rect;
const Color = geometry.Color;

const vert_spv = @embedFile("shaders/ui.vert.spv");
const frag_spv = @embedFile("shaders/ui.frag.spv");

pub const Error = rb.Error || error{ GpuUnavailable, GpuFailed };

const atlas_pages = 4;
const atlas_size: u32 = 1024;
const floats_per_vertex = 24;
const bytes_per_vertex = floats_per_vertex * 4;
const max_clip_depth = 32;
const max_opacity_depth = 16;

const Kind = enum(u8) { rect = 0, round_box = 1, ring = 2, segment = 3, glyph = 4, image = 5, image_mask = 6 };
const Vertex = [floats_per_vertex]f32;

const IRect = struct {
    x0: i32,
    y0: i32,
    x1: i32,
    y1: i32,

    fn intersect(a: IRect, b: IRect) IRect {
        return .{ .x0 = @max(a.x0, b.x0), .y0 = @max(a.y0, b.y0), .x1 = @min(a.x1, b.x1), .y1 = @min(a.y1, b.y1) };
    }

    fn isEmpty(self: IRect) bool {
        return self.x1 <= self.x0 or self.y1 <= self.y0;
    }

    fn covering(r: Rect, pad: f32) IRect {
        return .{
            .x0 = @intFromFloat(@floor(r.x - pad)),
            .y0 = @intFromFloat(@floor(r.y - pad)),
            .x1 = @intFromFloat(@ceil(r.right() + pad)),
            .y1 = @intFromFloat(@ceil(r.bottom() + pad)),
        };
    }
};

/// What a batch samples.
const Binding = struct {
    /// null: the 1x1 white texture (shapes).
    texture: ?*c.SDL_GPUTexture,
    linear: bool,

    fn eql(a: Binding, b: Binding) bool {
        return a.texture == b.texture and a.linear == b.linear;
    }
};

const Batch = struct {
    first: u32,
    count: u32,
    binding: Binding,
    scissor: IRect,
};

const UserTexture = struct {
    texture: *c.SDL_GPUTexture,
    desc: rb.TextureDesc,
};

pub const Options = struct {
    /// Show frames in this window (claimed for the device). Null for headless.
    window: ?*c.SDL_Window = null,
    /// Ask SDL for validation layers.
    debug: bool = false,
};

pub const GpuBackend = struct {
    gpa: std.mem.Allocator,
    device: *c.SDL_GPUDevice,
    window: ?*c.SDL_Window,
    vertex_shader: *c.SDL_GPUShader,
    fragment_shader: *c.SDL_GPUShader,
    pipeline: *c.SDL_GPUGraphicsPipeline,
    nearest: *c.SDL_GPUSampler,
    bilinear: *c.SDL_GPUSampler,
    white: *c.SDL_GPUTexture,

    target: ?*c.SDL_GPUTexture = null,
    target_w: u32 = 0,
    target_h: u32 = 0,
    /// The target was just (re)created: its contents are undefined until drawn.
    target_fresh: bool = true,
    scale: f32 = 1,
    in_frame: bool = false,
    submitted_this_frame: bool = false,
    frames: u64 = 0,

    atlas: [atlas_pages]?*c.SDL_GPUTexture = @splat(null),
    atlas_ptr: [atlas_pages]?[*]const u8 = @splat(null),
    textures: zigui.Pool(UserTexture, 32),

    verts: std.ArrayListUnmanaged(Vertex) = .empty,
    batches: std.ArrayListUnmanaged(Batch) = .empty,
    vertex_buffer: ?*c.SDL_GPUBuffer = null,
    vertex_capacity: u32 = 0,
    upload_buffer: ?*c.SDL_GPUTransferBuffer = null,
    upload_capacity: u32 = 0,

    /// Draw calls and vertices of the last `submit` (stats and tests).
    last_batches: u32 = 0,
    last_vertices: u32 = 0,

    var sdl_initialized = false;

    /// Create the backend (heap allocated: the `Backend` handle points into it).
    pub fn create(gpa: std.mem.Allocator, opts: Options) Error!*GpuBackend {
        if (!sdl_initialized) {
            if (!c.SDL_Init(c.SDL_INIT_VIDEO)) return error.GpuUnavailable;
            sdl_initialized = true;
        }
        const device = c.SDL_CreateGPUDevice(c.SDL_GPU_SHADERFORMAT_SPIRV, opts.debug, null) orelse return error.GpuUnavailable;
        errdefer c.SDL_DestroyGPUDevice(device);
        // A window that cannot be claimed (the offscreen video driver, for
        // example) leaves the backend headless: it still renders and reads back.
        var window = opts.window;
        if (window) |w| {
            if (!c.SDL_ClaimWindowForGPUDevice(device, w)) {
                std.log.warn("sdl gpu: cannot present to the window ({s}); rendering offscreen only", .{std.mem.span(c.SDL_GetError())});
                window = null;
            }
        }
        errdefer if (window) |w| c.SDL_ReleaseWindowFromGPUDevice(device, w);

        const self = gpa.create(GpuBackend) catch return error.OutOfMemory;
        errdefer gpa.destroy(self);

        const vs = makeShader(device, vert_spv, c.SDL_GPU_SHADERSTAGE_VERTEX, 0, 1) orelse return error.GpuFailed;
        errdefer c.SDL_ReleaseGPUShader(device, vs);
        const fs = makeShader(device, frag_spv, c.SDL_GPU_SHADERSTAGE_FRAGMENT, 1, 0) orelse return error.GpuFailed;
        errdefer c.SDL_ReleaseGPUShader(device, fs);
        const pipeline = makePipeline(device, vs, fs) orelse return error.GpuFailed;
        errdefer c.SDL_ReleaseGPUGraphicsPipeline(device, pipeline);
        const nearest = makeSampler(device, c.SDL_GPU_FILTER_NEAREST) orelse return error.GpuFailed;
        errdefer c.SDL_ReleaseGPUSampler(device, nearest);
        const bilinear = makeSampler(device, c.SDL_GPU_FILTER_LINEAR) orelse return error.GpuFailed;
        errdefer c.SDL_ReleaseGPUSampler(device, bilinear);
        const white = makeTexture(device, c.SDL_GPU_TEXTUREFORMAT_R8G8B8A8_UNORM, 1, 1, c.SDL_GPU_TEXTUREUSAGE_SAMPLER) orelse return error.GpuFailed;
        errdefer c.SDL_ReleaseGPUTexture(device, white);

        self.* = .{
            .gpa = gpa,
            .device = device,
            .window = window,
            .vertex_shader = vs,
            .fragment_shader = fs,
            .pipeline = pipeline,
            .nearest = nearest,
            .bilinear = bilinear,
            .white = white,
            .textures = zigui.Pool(UserTexture, 32).init(gpa),
        };
        // The white texel the shape kinds bind.
        uploadTexel(self, white, &.{ 255, 255, 255, 255 }, 1, 1, 4) catch return error.GpuFailed;
        return self;
    }

    pub fn destroy(self: *GpuBackend) void {
        _ = c.SDL_WaitForGPUIdle(self.device);
        var it = self.textures.iterator();
        while (it.next()) |e| c.SDL_ReleaseGPUTexture(self.device, e.ptr.texture);
        self.textures.deinit();
        for (self.atlas) |t| if (t) |tex| c.SDL_ReleaseGPUTexture(self.device, tex);
        if (self.target) |t| c.SDL_ReleaseGPUTexture(self.device, t);
        if (self.vertex_buffer) |b| c.SDL_ReleaseGPUBuffer(self.device, b);
        if (self.upload_buffer) |b| c.SDL_ReleaseGPUTransferBuffer(self.device, b);
        c.SDL_ReleaseGPUTexture(self.device, self.white);
        c.SDL_ReleaseGPUSampler(self.device, self.nearest);
        c.SDL_ReleaseGPUSampler(self.device, self.bilinear);
        c.SDL_ReleaseGPUGraphicsPipeline(self.device, self.pipeline);
        c.SDL_ReleaseGPUShader(self.device, self.vertex_shader);
        c.SDL_ReleaseGPUShader(self.device, self.fragment_shader);
        if (self.window) |w| c.SDL_ReleaseWindowFromGPUDevice(self.device, w);
        c.SDL_DestroyGPUDevice(self.device);
        self.verts.deinit(self.gpa);
        self.batches.deinit(self.gpa);
        self.gpa.destroy(self);
    }

    /// The name of the driver SDL picked ("vulkan", "metal", "direct3d12").
    pub fn driver(self: *const GpuBackend) []const u8 {
        return std.mem.span(c.SDL_GetGPUDeviceDriver(self.device));
    }

    pub fn backend(self: *GpuBackend) rb.Backend {
        return .{ .ctx = self, .vtable = &vtable };
    }

    const vtable: rb.VTable = .{
        .caps = .{
            .name = "sdl-gpu",
            .textures = true,
            .readback = true,
            .atlas_upload = true,
            .partial_redraw = true,
            .max_texture_size = 8192,
        },
        .begin_frame = beginFrame,
        .submit = submit,
        .end_frame = endFrame,
        .create_texture = createTexture,
        .update_texture = updateTexture,
        .destroy_texture = destroyTexture,
        .upload_atlas_page = uploadAtlasPage,
        .readback = readback,
    };

    fn me(ctx: *anyopaque) *GpuBackend {
        return @ptrCast(@alignCast(ctx));
    }

    // ---- device objects ----

    fn makeShader(device: *c.SDL_GPUDevice, code: []const u8, stage: c.SDL_GPUShaderStage, samplers: u32, uniforms: u32) ?*c.SDL_GPUShader {
        var info = std.mem.zeroes(c.SDL_GPUShaderCreateInfo);
        info.code_size = code.len;
        info.code = code.ptr;
        info.entrypoint = "main";
        info.format = c.SDL_GPU_SHADERFORMAT_SPIRV;
        info.stage = stage;
        info.num_samplers = samplers;
        info.num_uniform_buffers = uniforms;
        return c.SDL_CreateGPUShader(device, &info);
    }

    fn makePipeline(device: *c.SDL_GPUDevice, vs: *c.SDL_GPUShader, fs: *c.SDL_GPUShader) ?*c.SDL_GPUGraphicsPipeline {
        var buffers = [_]c.SDL_GPUVertexBufferDescription{.{
            .slot = 0,
            .pitch = bytes_per_vertex,
            .input_rate = c.SDL_GPU_VERTEXINPUTRATE_VERTEX,
            .instance_step_rate = 0,
        }};
        var attrs: [6]c.SDL_GPUVertexAttribute = undefined;
        for (&attrs, 0..) |*a, i| a.* = .{
            .location = @intCast(i),
            .buffer_slot = 0,
            .format = c.SDL_GPU_VERTEXELEMENTFORMAT_FLOAT4,
            .offset = @intCast(i * 16),
        };
        var color_target = std.mem.zeroes(c.SDL_GPUColorTargetDescription);
        color_target.format = c.SDL_GPU_TEXTUREFORMAT_R8G8B8A8_UNORM;
        color_target.blend_state = .{
            .src_color_blendfactor = c.SDL_GPU_BLENDFACTOR_SRC_ALPHA,
            .dst_color_blendfactor = c.SDL_GPU_BLENDFACTOR_ONE_MINUS_SRC_ALPHA,
            .color_blend_op = c.SDL_GPU_BLENDOP_ADD,
            .src_alpha_blendfactor = c.SDL_GPU_BLENDFACTOR_ONE,
            .dst_alpha_blendfactor = c.SDL_GPU_BLENDFACTOR_ONE_MINUS_SRC_ALPHA,
            .alpha_blend_op = c.SDL_GPU_BLENDOP_ADD,
            .color_write_mask = 0,
            .enable_blend = true,
            .enable_color_write_mask = false,
            .padding1 = 0,
            .padding2 = 0,
        };
        var info = std.mem.zeroes(c.SDL_GPUGraphicsPipelineCreateInfo);
        info.vertex_shader = vs;
        info.fragment_shader = fs;
        info.vertex_input_state = .{
            .vertex_buffer_descriptions = &buffers,
            .num_vertex_buffers = 1,
            .vertex_attributes = &attrs,
            .num_vertex_attributes = attrs.len,
        };
        info.primitive_type = c.SDL_GPU_PRIMITIVETYPE_TRIANGLELIST;
        info.rasterizer_state.fill_mode = c.SDL_GPU_FILLMODE_FILL;
        info.rasterizer_state.cull_mode = c.SDL_GPU_CULLMODE_NONE;
        info.rasterizer_state.front_face = c.SDL_GPU_FRONTFACE_COUNTER_CLOCKWISE;
        info.multisample_state.sample_count = c.SDL_GPU_SAMPLECOUNT_1;
        info.target_info.color_target_descriptions = &color_target;
        info.target_info.num_color_targets = 1;
        return c.SDL_CreateGPUGraphicsPipeline(device, &info);
    }

    fn makeSampler(device: *c.SDL_GPUDevice, filter: c.SDL_GPUFilter) ?*c.SDL_GPUSampler {
        var info = std.mem.zeroes(c.SDL_GPUSamplerCreateInfo);
        info.min_filter = filter;
        info.mag_filter = filter;
        info.mipmap_mode = c.SDL_GPU_SAMPLERMIPMAPMODE_NEAREST;
        info.address_mode_u = c.SDL_GPU_SAMPLERADDRESSMODE_CLAMP_TO_EDGE;
        info.address_mode_v = c.SDL_GPU_SAMPLERADDRESSMODE_CLAMP_TO_EDGE;
        info.address_mode_w = c.SDL_GPU_SAMPLERADDRESSMODE_CLAMP_TO_EDGE;
        return c.SDL_CreateGPUSampler(device, &info);
    }

    fn makeTexture(device: *c.SDL_GPUDevice, format: c.SDL_GPUTextureFormat, w: u32, h: u32, usage: c.SDL_GPUTextureUsageFlags) ?*c.SDL_GPUTexture {
        var info = std.mem.zeroes(c.SDL_GPUTextureCreateInfo);
        info.type = c.SDL_GPU_TEXTURETYPE_2D;
        info.format = format;
        info.usage = usage;
        info.width = w;
        info.height = h;
        info.layer_count_or_depth = 1;
        info.num_levels = 1;
        info.sample_count = c.SDL_GPU_SAMPLECOUNT_1;
        return c.SDL_CreateGPUTexture(device, &info);
    }

    /// Copy `w` by `h` texels (rows `stride` bytes apart, `bpp` bytes each) into
    /// the region at (x, y) of `tex`, on a command buffer of its own.
    fn uploadRegion(self: *GpuBackend, tex: *c.SDL_GPUTexture, x: u32, y: u32, w: u32, h: u32, pixels: []const u8, stride: usize, bpp: u32) !void {
        const row = w * bpp;
        var tinfo = std.mem.zeroes(c.SDL_GPUTransferBufferCreateInfo);
        tinfo.usage = c.SDL_GPU_TRANSFERBUFFERUSAGE_UPLOAD;
        tinfo.size = row * h;
        const tb = c.SDL_CreateGPUTransferBuffer(self.device, &tinfo) orelse return error.GpuFailed;
        defer c.SDL_ReleaseGPUTransferBuffer(self.device, tb);
        const mapped: [*]u8 = @ptrCast(c.SDL_MapGPUTransferBuffer(self.device, tb, false) orelse return error.GpuFailed);
        for (0..h) |r| @memcpy(mapped[r * row ..][0..row], pixels[r * stride ..][0..row]);
        c.SDL_UnmapGPUTransferBuffer(self.device, tb);

        const cmd = c.SDL_AcquireGPUCommandBuffer(self.device) orelse return error.GpuFailed;
        const pass = c.SDL_BeginGPUCopyPass(cmd) orelse {
            _ = c.SDL_CancelGPUCommandBuffer(cmd);
            return error.GpuFailed;
        };
        var src = std.mem.zeroes(c.SDL_GPUTextureTransferInfo);
        src.transfer_buffer = tb;
        src.pixels_per_row = w;
        src.rows_per_layer = h;
        var dst = std.mem.zeroes(c.SDL_GPUTextureRegion);
        dst.texture = tex;
        dst.x = x;
        dst.y = y;
        dst.w = w;
        dst.h = h;
        dst.d = 1;
        c.SDL_UploadToGPUTexture(pass, &src, &dst, false);
        c.SDL_EndGPUCopyPass(pass);
        if (!c.SDL_SubmitGPUCommandBuffer(cmd)) return error.GpuFailed;
    }

    fn uploadTexel(self: *GpuBackend, tex: *c.SDL_GPUTexture, pixels: []const u8, w: u32, h: u32, bpp: u32) !void {
        try self.uploadRegion(tex, 0, 0, w, h, pixels, w * bpp, bpp);
    }

    // ---- frame ----

    fn ensureTarget(self: *GpuBackend, w: u32, h: u32) rb.Error!void {
        if (self.target != null and self.target_w == w and self.target_h == h) return;
        _ = c.SDL_WaitForGPUIdle(self.device);
        if (self.target) |t| c.SDL_ReleaseGPUTexture(self.device, t);
        self.target = makeTexture(
            self.device,
            c.SDL_GPU_TEXTUREFORMAT_R8G8B8A8_UNORM,
            w,
            h,
            c.SDL_GPU_TEXTUREUSAGE_COLOR_TARGET | c.SDL_GPU_TEXTUREUSAGE_SAMPLER,
        ) orelse return error.DeviceLost;
        self.target_w = w;
        self.target_h = h;
        self.target_fresh = true;
    }

    fn beginFrame(ctx: *anyopaque, info: rb.FrameInfo) rb.Error!void {
        const self = me(ctx);
        if (self.in_frame) return error.BadFrameState;
        try self.ensureTarget(@max(info.pixel_w, 1), @max(info.pixel_h, 1));
        self.scale = info.scale;
        self.in_frame = true;
        self.submitted_this_frame = false;
    }

    fn endFrame(ctx: *anyopaque) rb.Error!void {
        const self = me(ctx);
        if (!self.in_frame) return error.BadFrameState;
        self.in_frame = false;
        self.frames += 1;
        const window = self.window orelse return;
        const cmd = c.SDL_AcquireGPUCommandBuffer(self.device) orelse return error.DeviceLost;
        var swap: ?*c.SDL_GPUTexture = null;
        var sw: u32 = 0;
        var sh: u32 = 0;
        if (!c.SDL_WaitAndAcquireGPUSwapchainTexture(cmd, window, &swap, &sw, &sh)) {
            _ = c.SDL_CancelGPUCommandBuffer(cmd);
            return error.PresentFailed;
        }
        if (swap) |dst| {
            var blit = std.mem.zeroes(c.SDL_GPUBlitInfo);
            blit.source = .{ .texture = self.target, .mip_level = 0, .layer_or_depth_plane = 0, .x = 0, .y = 0, .w = self.target_w, .h = self.target_h };
            blit.destination = .{ .texture = dst, .mip_level = 0, .layer_or_depth_plane = 0, .x = 0, .y = 0, .w = sw, .h = sh };
            blit.load_op = c.SDL_GPU_LOADOP_DONT_CARE;
            blit.filter = c.SDL_GPU_FILTER_NEAREST;
            c.SDL_BlitGPUTexture(cmd, &blit);
        }
        if (!c.SDL_SubmitGPUCommandBuffer(cmd)) return error.PresentFailed;
    }

    // ---- building vertices ----

    const Builder = struct {
        be: *GpuBackend,
        scale: f32,
        glyph_items: []const draw_list.Glyph,
        provider: ?zigui.text.GlyphProvider,
        base: IRect,
        clip: IRect,
        clips: [max_clip_depth]IRect = undefined,
        clip_n: usize = 0,
        clip_overflow: u32 = 0,
        opacity: f32 = 1,
        opacities: [max_opacity_depth]f32 = undefined,
        opacity_n: usize = 0,
        opacity_overflow: u32 = 0,
        current: ?Batch = null,
        oom: bool = false,

        fn flush(self: *Builder) void {
            if (self.current) |b| {
                if (b.count > 0) self.be.batches.append(self.be.gpa, b) catch {
                    self.oom = true;
                };
            }
            self.current = null;
        }

        /// Start (or continue) a batch for `binding` under the current clip.
        fn use(self: *Builder, binding: Binding) void {
            if (self.current) |*b| {
                if (b.binding.eql(binding) and std.meta.eql(b.scissor, self.clip)) return;
            }
            self.flush();
            self.current = .{ .first = @intCast(self.be.verts.items.len), .count = 0, .binding = binding, .scissor = self.clip };
        }

        fn quad(self: *Builder, x0: f32, y0: f32, x1: f32, y1: f32, uv: [4]f32, v: Vertex) void {
            // Two triangles; position and local/uv per corner, the rest shared.
            const corners = [6][2]u8{ .{ 0, 0 }, .{ 1, 0 }, .{ 0, 1 }, .{ 1, 0 }, .{ 1, 1 }, .{ 0, 1 } };
            for (corners) |cn| {
                var vv = v;
                vv[0] = if (cn[0] == 0) x0 else x1;
                vv[1] = if (cn[1] == 0) y0 else y1;
                if (uv[2] != 0 or uv[3] != 0) {
                    vv[2] = if (cn[0] == 0) uv[0] else uv[2];
                    vv[3] = if (cn[1] == 0) uv[1] else uv[3];
                }
                self.be.verts.append(self.be.gpa, vv) catch {
                    self.oom = true;
                    return;
                };
            }
            if (self.current) |*b| b.count += 6;
        }

        fn shapeVertex(kind: Kind, paint: draw_list.Paint, scale: f32, opacity: f32, center: [2]f32, half: [2]f32, params: [4]f32) Vertex {
            var v: Vertex = @splat(0);
            v[2] = center[0];
            v[3] = center[1];
            v[4] = @floatFromInt(@intFromEnum(kind));
            v[6] = half[0];
            v[7] = half[1];
            v[8] = params[0];
            v[9] = params[1];
            v[10] = params[2];
            v[11] = params[3];
            switch (paint) {
                .color => |col| setColor(&v, 12, col, opacity),
                .linear_gradient, .radial_gradient => |g| {
                    v[5] = if (paint == .linear_gradient) 1 else 2;
                    setColor(&v, 12, g.color, opacity);
                    setColor(&v, 16, g.color2, opacity);
                    v[20] = g.from.x * scale;
                    v[21] = g.from.y * scale;
                    v[22] = g.to.x * scale;
                    v[23] = g.to.y * scale;
                },
                .image_pattern => setColor(&v, 12, Color.transparent, opacity),
            }
            return v;
        }

        fn setColor(v: *Vertex, at: usize, col: Color, opacity: f32) void {
            v[at] = @as(f32, @floatFromInt(col.r)) / 255.0;
            v[at + 1] = @as(f32, @floatFromInt(col.g)) / 255.0;
            v[at + 2] = @as(f32, @floatFromInt(col.b)) / 255.0;
            v[at + 3] = @as(f32, @floatFromInt(col.a)) / 255.0 * opacity;
        }

        fn scaled(self: *const Builder, r: Rect) Rect {
            return .{ .x = r.x * self.scale, .y = r.y * self.scale, .w = r.w * self.scale, .h = r.h * self.scale };
        }

        fn shape(self: *Builder, kind: Kind, bounds: Rect, paint: draw_list.Paint, center: [2]f32, half: [2]f32, params: [4]f32) void {
            if (IRect.covering(bounds, 0).intersect(self.clip).isEmpty()) return;
            self.use(.{ .texture = null, .linear = false });
            const v = shapeVertex(kind, paint, self.scale, self.opacity, center, half, params);
            self.quad(bounds.x, bounds.y, bounds.right(), bounds.bottom(), .{ 0, 0, 0, 0 }, v);
        }

        fn fillBox(self: *Builder, r: Rect, radii: [4]f32, paint: draw_list.Paint) void {
            const d = self.scaled(r);
            if (d.w <= 0 or d.h <= 0) return;
            const pad: Rect = .{ .x = d.x - 1, .y = d.y - 1, .w = d.w + 2, .h = d.h + 2 };
            const center = [2]f32{ d.x + d.w / 2, d.y + d.h / 2 };
            const half = [2]f32{ d.w / 2, d.h / 2 };
            const sr = [4]f32{ radii[0] * self.scale, radii[1] * self.scale, radii[2] * self.scale, radii[3] * self.scale };
            if (sr[0] <= 0 and sr[1] <= 0 and sr[2] <= 0 and sr[3] <= 0) {
                self.shape(.rect, pad, paint, center, half, .{ 0, 0, 0, 0 });
            } else {
                self.shape(.round_box, pad, paint, center, half, sr);
            }
        }

        fn execute(self: *Builder, cmd: draw_list.Command) void {
            switch (cmd) {
                .fill_rect => |f| self.fillBox(f.rect, .{ 0, 0, 0, 0 }, f.paint),
                .fill_rounded_rect => |f| self.fillBox(f.rect, f.radii, f.paint),
                .stroke_rect => |s| {
                    const d = self.scaled(s.rect);
                    if (d.w <= 0 or d.h <= 0 or s.width <= 0) return;
                    const pad: Rect = .{ .x = d.x - 1, .y = d.y - 1, .w = d.w + 2, .h = d.h + 2 };
                    self.shape(.ring, pad, s.paint, .{ d.x + d.w / 2, d.y + d.h / 2 }, .{ d.w / 2, d.h / 2 }, .{ s.radius * self.scale, s.width * self.scale, 0, 0 });
                },
                .line => |l| {
                    const a = [2]f32{ l.from.x * self.scale, l.from.y * self.scale };
                    const b = [2]f32{ l.to.x * self.scale, l.to.y * self.scale };
                    const hw = @max(l.width * self.scale / 2, 0);
                    const pad = hw + 1;
                    const bounds: Rect = .{ .x = @min(a[0], b[0]) - pad, .y = @min(a[1], b[1]) - pad, .w = @abs(b[0] - a[0]) + 2 * pad, .h = @abs(b[1] - a[1]) + 2 * pad };
                    self.shape(.segment, bounds, l.paint, .{ 0, 0 }, .{ hw, 0 }, .{ a[0], a[1], b[0], b[1] });
                },
                .push_clip => |r| {
                    if (self.clip_n == max_clip_depth) {
                        self.clip_overflow += 1;
                        return;
                    }
                    self.clips[self.clip_n] = self.clip;
                    self.clip_n += 1;
                    self.clip = self.clip.intersect(IRect.covering(self.scaled(r), 0));
                },
                .pop_clip => {
                    if (self.clip_overflow > 0) {
                        self.clip_overflow -= 1;
                    } else if (self.clip_n > 0) {
                        self.clip_n -= 1;
                        self.clip = self.clips[self.clip_n];
                    }
                },
                .push_opacity => |o| {
                    if (self.opacity_n == max_opacity_depth) {
                        self.opacity_overflow += 1;
                        return;
                    }
                    self.opacities[self.opacity_n] = self.opacity;
                    self.opacity_n += 1;
                    self.opacity *= std.math.clamp(o, 0, 1);
                },
                .pop_opacity => {
                    if (self.opacity_overflow > 0) {
                        self.opacity_overflow -= 1;
                    } else if (self.opacity_n > 0) {
                        self.opacity_n -= 1;
                        self.opacity = self.opacities[self.opacity_n];
                    }
                },
                .glyph_run => |run| self.glyphRun(run),
                .image => |im| self.image(im),
            }
        }

        fn pageOf(self: *const Builder, pixels: []const u8) ?usize {
            for (self.be.atlas_ptr, 0..) |p, i| {
                if (p != null and p.? == pixels.ptr) return i;
            }
            return null;
        }

        fn glyphRun(self: *Builder, run: draw_list.GlyphRun) void {
            const provider = self.provider orelse return;
            const end = @as(usize, run.offset) + run.count;
            if (end > self.glyph_items.len) return;
            const size_px = run.size * self.scale;
            for (self.glyph_items[run.offset..end]) |g| {
                const dx = g.x * self.scale;
                var ix: i32 = undefined;
                var sub: u8 = 0;
                if (run.subpixel) {
                    const fl = @floor(dx);
                    ix = @intFromFloat(fl);
                    sub = @intFromFloat(std.math.clamp(@floor((dx - fl) * 4), 0, 3));
                } else {
                    ix = @intFromFloat(@round(dx));
                }
                const iy: i32 = @intFromFloat(@round(g.y * self.scale));
                const img = provider.lookup(run.font, g.id, size_px, sub) orelse continue;
                if (img.w == 0 or img.h == 0) continue;
                const page = self.pageOf(img.pixels) orelse continue;
                const tex = self.be.atlas[page] orelse continue;
                const gx0: f32 = @floatFromInt(ix + img.left);
                const gy0: f32 = @floatFromInt(iy - img.top);
                const gx1 = gx0 + @as(f32, @floatFromInt(img.w));
                const gy1 = gy0 + @as(f32, @floatFromInt(img.h));
                const area = IRect.covering(.{ .x = gx0, .y = gy0, .w = gx1 - gx0, .h = gy1 - gy0 }, 0).intersect(self.clip);
                if (area.isEmpty()) continue;
                self.use(.{ .texture = tex, .linear = false });
                var v: Vertex = @splat(0);
                v[4] = @floatFromInt(@intFromEnum(Kind.glyph));
                setColor(&v, 12, run.color, self.opacity);
                const inv = 1.0 / @as(f32, @floatFromInt(atlas_size));
                self.quad(gx0, gy0, gx1, gy1, .{
                    @as(f32, @floatFromInt(img.x)) * inv,
                    @as(f32, @floatFromInt(img.y)) * inv,
                    @as(f32, @floatFromInt(img.x + img.w)) * inv,
                    @as(f32, @floatFromInt(img.y + img.h)) * inv,
                }, v);
            }
        }

        fn image(self: *Builder, im: draw_list.Image) void {
            const t = self.be.textures.get(im.texture) orelse return;
            const d = self.scaled(im.rect);
            if (d.w <= 0 or d.h <= 0) return;
            if (IRect.covering(d, 0).intersect(self.clip).isEmpty()) return;
            const tw: f32 = @floatFromInt(t.desc.width);
            const th: f32 = @floatFromInt(t.desc.height);
            const s = if (im.src.w > 0 and im.src.h > 0) im.src else Rect{ .x = 0, .y = 0, .w = tw, .h = th };
            self.use(.{ .texture = t.texture, .linear = im.filter == .linear });
            var v: Vertex = @splat(0);
            v[4] = @floatFromInt(@intFromEnum(if (t.desc.format == .alpha8) Kind.image_mask else Kind.image));
            setColor(&v, 12, im.tint, self.opacity);
            self.quad(d.x, d.y, d.right(), d.bottom(), .{ s.x / tw, s.y / th, s.right() / tw, s.bottom() / th }, v);
        }
    };

    // ---- submit ----

    fn ensureVertexStorage(self: *GpuBackend, bytes: u32) !void {
        if (self.vertex_capacity < bytes) {
            if (self.vertex_buffer) |b| c.SDL_ReleaseGPUBuffer(self.device, b);
            if (self.upload_buffer) |b| c.SDL_ReleaseGPUTransferBuffer(self.device, b);
            const cap = @max(bytes, self.vertex_capacity * 2, 64 * 1024);
            var binfo = std.mem.zeroes(c.SDL_GPUBufferCreateInfo);
            binfo.usage = c.SDL_GPU_BUFFERUSAGE_VERTEX;
            binfo.size = cap;
            self.vertex_buffer = c.SDL_CreateGPUBuffer(self.device, &binfo) orelse {
                self.vertex_capacity = 0;
                return error.GpuFailed;
            };
            var tinfo = std.mem.zeroes(c.SDL_GPUTransferBufferCreateInfo);
            tinfo.usage = c.SDL_GPU_TRANSFERBUFFERUSAGE_UPLOAD;
            tinfo.size = cap;
            self.upload_buffer = c.SDL_CreateGPUTransferBuffer(self.device, &tinfo) orelse {
                self.vertex_capacity = 0;
                return error.GpuFailed;
            };
            self.vertex_capacity = cap;
        }
    }

    fn submit(ctx: *anyopaque, s: rb.Submit) rb.Error!void {
        const self = me(ctx);
        if (!self.in_frame) return error.BadFrameState;
        const target = self.target.?;
        const tw: i32 = @intCast(self.target_w);
        const th: i32 = @intCast(self.target_h);

        var bounds: IRect = .{ .x0 = 0, .y0 = 0, .x1 = tw, .y1 = th };
        if (s.damage) |dmg| {
            const d: Rect = .{ .x = dmg.x * self.scale, .y = dmg.y * self.scale, .w = dmg.w * self.scale, .h = dmg.h * self.scale };
            bounds = bounds.intersect(IRect.covering(d, 0));
        }
        const full = bounds.x0 == 0 and bounds.y0 == 0 and bounds.x1 == tw and bounds.y1 == th;

        self.verts.clearRetainingCapacity();
        self.batches.clearRetainingCapacity();
        var b: Builder = .{
            .be = self,
            .scale = self.scale,
            .glyph_items = s.list.glyphItems(),
            .provider = s.glyphs,
            .base = bounds,
            .clip = bounds,
        };
        // A partial clear is a rect over the damaged area (a full one is the load op).
        const clear_with_load_op = s.clear != null and full;
        if (s.clear) |col| {
            if (!full) {
                const area = Rect{ .x = @floatFromInt(bounds.x0), .y = @floatFromInt(bounds.y0), .w = @floatFromInt(bounds.x1 - bounds.x0), .h = @floatFromInt(bounds.y1 - bounds.y0) };
                b.shape(.rect, area, .{ .color = Color.rgba(col.r, col.g, col.b, 255) }, .{ area.x + area.w / 2, area.y + area.h / 2 }, .{ area.w / 2, area.h / 2 }, .{ 0, 0, 0, 0 });
            }
        }
        for (s.list.items()) |cmd| b.execute(cmd);
        b.flush();
        if (b.oom) return error.OutOfMemory;

        const bytes: u32 = @intCast(self.verts.items.len * bytes_per_vertex);
        self.last_batches = @intCast(self.batches.items.len);
        self.last_vertices = @intCast(self.verts.items.len);
        if (bytes > 0) self.ensureVertexStorage(bytes) catch return error.DeviceLost;

        const cmd = c.SDL_AcquireGPUCommandBuffer(self.device) orelse return error.DeviceLost;
        if (bytes > 0) {
            const mapped: [*]u8 = @ptrCast(c.SDL_MapGPUTransferBuffer(self.device, self.upload_buffer, true) orelse {
                _ = c.SDL_CancelGPUCommandBuffer(cmd);
                return error.DeviceLost;
            });
            @memcpy(mapped[0..bytes], std.mem.sliceAsBytes(self.verts.items));
            c.SDL_UnmapGPUTransferBuffer(self.device, self.upload_buffer);
            const copy = c.SDL_BeginGPUCopyPass(cmd) orelse {
                _ = c.SDL_CancelGPUCommandBuffer(cmd);
                return error.DeviceLost;
            };
            const src: c.SDL_GPUTransferBufferLocation = .{ .transfer_buffer = self.upload_buffer, .offset = 0 };
            const dst: c.SDL_GPUBufferRegion = .{ .buffer = self.vertex_buffer, .offset = 0, .size = bytes };
            c.SDL_UploadToGPUBuffer(copy, &src, &dst, true);
            c.SDL_EndGPUCopyPass(copy);
        }

        var color_info = std.mem.zeroes(c.SDL_GPUColorTargetInfo);
        color_info.texture = target;
        color_info.store_op = c.SDL_GPU_STOREOP_STORE;
        if (clear_with_load_op) {
            color_info.load_op = c.SDL_GPU_LOADOP_CLEAR;
            color_info.clear_color = .{
                .r = @as(f32, @floatFromInt(s.clear.?.r)) / 255.0,
                .g = @as(f32, @floatFromInt(s.clear.?.g)) / 255.0,
                .b = @as(f32, @floatFromInt(s.clear.?.b)) / 255.0,
                .a = 1,
            };
        } else if (self.target_fresh and !self.submitted_this_frame) {
            color_info.load_op = c.SDL_GPU_LOADOP_CLEAR; // undefined contents: start transparent
        } else {
            color_info.load_op = c.SDL_GPU_LOADOP_LOAD;
        }
        self.target_fresh = false;
        self.submitted_this_frame = true;

        const pass = c.SDL_BeginGPURenderPass(cmd, &color_info, 1, null) orelse {
            _ = c.SDL_CancelGPUCommandBuffer(cmd);
            return error.DeviceLost;
        };
        if (self.batches.items.len > 0) {
            c.SDL_BindGPUGraphicsPipeline(pass, self.pipeline);
            const vb: c.SDL_GPUBufferBinding = .{ .buffer = self.vertex_buffer, .offset = 0 };
            c.SDL_BindGPUVertexBuffers(pass, 0, &vb, 1);
            const viewport = [2]f32{ @floatFromInt(self.target_w), @floatFromInt(self.target_h) };
            c.SDL_PushGPUVertexUniformData(cmd, 0, &viewport, @sizeOf(@TypeOf(viewport)));
            for (self.batches.items) |batch| {
                const sc = batch.scissor.intersect(bounds);
                if (sc.isEmpty()) continue;
                const rect: c.SDL_Rect = .{ .x = sc.x0, .y = sc.y0, .w = sc.x1 - sc.x0, .h = sc.y1 - sc.y0 };
                c.SDL_SetGPUScissor(pass, &rect);
                const binding: c.SDL_GPUTextureSamplerBinding = .{
                    .texture = batch.binding.texture orelse self.white,
                    .sampler = if (batch.binding.linear) self.bilinear else self.nearest,
                };
                c.SDL_BindGPUFragmentSamplers(pass, 0, &binding, 1);
                c.SDL_DrawGPUPrimitives(pass, batch.count, 1, batch.first, 0);
            }
        }
        c.SDL_EndGPURenderPass(pass);
        if (!c.SDL_SubmitGPUCommandBuffer(cmd)) return error.DeviceLost;
    }

    // ---- textures ----

    fn formatOf(f: rb.TextureFormat) c.SDL_GPUTextureFormat {
        return switch (f) {
            .rgba8 => c.SDL_GPU_TEXTUREFORMAT_R8G8B8A8_UNORM,
            .alpha8 => c.SDL_GPU_TEXTUREFORMAT_R8_UNORM,
        };
    }

    fn createTexture(ctx: *anyopaque, desc: rb.TextureDesc) rb.Error!rb.TextureId {
        const self = me(ctx);
        if (desc.width == 0 or desc.height == 0 or desc.width > 8192 or desc.height > 8192) return error.TextureTooLarge;
        const tex = makeTexture(self.device, formatOf(desc.format), desc.width, desc.height, c.SDL_GPU_TEXTUREUSAGE_SAMPLER) orelse return error.DeviceLost;
        errdefer c.SDL_ReleaseGPUTexture(self.device, tex);
        // Start transparent rather than undefined.
        const zeros = self.gpa.alloc(u8, @as(usize, desc.width) * desc.height * desc.format.bytesPerPixel()) catch return error.OutOfMemory;
        defer self.gpa.free(zeros);
        @memset(zeros, 0);
        self.uploadTexel(tex, zeros, desc.width, desc.height, desc.format.bytesPerPixel()) catch return error.DeviceLost;
        return self.textures.create(.{ .texture = tex, .desc = desc }) catch error.OutOfMemory;
    }

    fn updateTexture(ctx: *anyopaque, id: rb.TextureId, rect: rb.URect, pixels: []const u8, stride: usize) rb.Error!void {
        const self = me(ctx);
        const t = self.textures.get(id) orelse return error.BadTexture;
        if (rect.x + rect.w > t.desc.width or rect.y + rect.h > t.desc.height) return error.BadTexture;
        const bpp = t.desc.format.bytesPerPixel();
        if (rect.h > 0 and pixels.len < (rect.h - 1) * stride + rect.w * bpp) return error.BadTexture;
        if (rect.w == 0 or rect.h == 0) return;
        self.uploadRegion(t.texture, rect.x, rect.y, rect.w, rect.h, pixels, stride, bpp) catch return error.DeviceLost;
    }

    fn destroyTexture(ctx: *anyopaque, id: rb.TextureId) void {
        const self = me(ctx);
        if (self.textures.get(id)) |t| {
            _ = c.SDL_WaitForGPUIdle(self.device);
            c.SDL_ReleaseGPUTexture(self.device, t.texture);
            _ = self.textures.destroy(id);
        }
    }

    fn uploadAtlasPage(ctx: *anyopaque, page: u8, pixels: []const u8, size: u32) rb.Error!void {
        const self = me(ctx);
        if (page >= atlas_pages or size != atlas_size) return error.Unsupported;
        if (self.atlas[page] == null) {
            self.atlas[page] = makeTexture(self.device, c.SDL_GPU_TEXTUREFORMAT_R8_UNORM, size, size, c.SDL_GPU_TEXTUREUSAGE_SAMPLER) orelse return error.DeviceLost;
        }
        self.atlas_ptr[page] = pixels.ptr;
        self.uploadTexel(self.atlas[page].?, pixels, size, size, 1) catch return error.DeviceLost;
    }

    // ---- readback ----

    fn readback(ctx: *anyopaque, gpa: std.mem.Allocator) rb.Error!rb.Image {
        const self = me(ctx);
        const target = self.target orelse return error.BadFrameState;
        const w = self.target_w;
        const h = self.target_h;
        _ = c.SDL_WaitForGPUIdle(self.device);
        var tinfo = std.mem.zeroes(c.SDL_GPUTransferBufferCreateInfo);
        tinfo.usage = c.SDL_GPU_TRANSFERBUFFERUSAGE_DOWNLOAD;
        tinfo.size = w * h * 4;
        const tb = c.SDL_CreateGPUTransferBuffer(self.device, &tinfo) orelse return error.DeviceLost;
        defer c.SDL_ReleaseGPUTransferBuffer(self.device, tb);

        const cmd = c.SDL_AcquireGPUCommandBuffer(self.device) orelse return error.DeviceLost;
        const pass = c.SDL_BeginGPUCopyPass(cmd) orelse {
            _ = c.SDL_CancelGPUCommandBuffer(cmd);
            return error.DeviceLost;
        };
        var src = std.mem.zeroes(c.SDL_GPUTextureRegion);
        src.texture = target;
        src.w = w;
        src.h = h;
        src.d = 1;
        var dst = std.mem.zeroes(c.SDL_GPUTextureTransferInfo);
        dst.transfer_buffer = tb;
        dst.pixels_per_row = w;
        dst.rows_per_layer = h;
        c.SDL_DownloadFromGPUTexture(pass, &src, &dst);
        c.SDL_EndGPUCopyPass(pass);
        const fence = c.SDL_SubmitGPUCommandBufferAndAcquireFence(cmd) orelse return error.DeviceLost;
        defer c.SDL_ReleaseGPUFence(self.device, fence);
        var fences = [_]?*c.SDL_GPUFence{fence};
        if (!c.SDL_WaitForGPUFences(self.device, true, &fences, 1)) return error.DeviceLost;

        const mapped: [*]const u8 = @ptrCast(c.SDL_MapGPUTransferBuffer(self.device, tb, false) orelse return error.DeviceLost);
        defer c.SDL_UnmapGPUTransferBuffer(self.device, tb);
        const out = gpa.alloc(u8, @as(usize, w) * h * 4) catch return error.OutOfMemory;
        @memcpy(out, mapped[0..out.len]);
        return .{ .width = w, .height = h, .rgba = out };
    }
};

// ---- tests -----------------------------------------------------------------
//
// These need a GPU device (a real one, or a software Vulkan such as lavapipe)
// and run headless with SDL's offscreen video driver. They skip when there is
// none.

const testing = std.testing;
const software = zigui.software;

fn testBackend(window: ?*c.SDL_Window) !*GpuBackend {
    _ = c.SDL_SetHint(c.SDL_HINT_VIDEO_DRIVER, "offscreen");
    return GpuBackend.create(testing.allocator, .{ .window = window }) catch |err| switch (err) {
        error.GpuUnavailable => return error.SkipZigTest,
        else => return err,
    };
}

const Px = [4]u8;

fn pixel(img: rb.Image, x: u32, y: u32) Px {
    return img.rgba[(y * img.width + x) * 4 ..][0..4].*;
}

fn expectNear(want: Px, got: Px, tol: u8) !void {
    for (want, got) |w, g| {
        const d = if (w > g) w - g else g - w;
        if (d > tol) {
            std.debug.print("want {any} got {any}\n", .{ want, got });
            return error.PixelMismatch;
        }
    }
}

test "the GPU backend draws a rect where the draw list says (top-left origin) and clears" {
    const gpu = try testBackend(null);
    defer gpu.destroy();
    const be = gpu.backend();
    try testing.expect(be.caps().atlas_upload and be.caps().partial_redraw);

    var cmds: [8]draw_list.Command = undefined;
    var gl: [1]draw_list.Glyph = undefined;
    var list = draw_list.DrawList.init(&cmds, &gl);
    try list.fillRect(.{ .x = 2, .y = 3, .w = 4, .h = 2 }, .{ .color = Color.rgb(255, 0, 0) });
    try be.beginFrame(.{ .pixel_w = 16, .pixel_h = 12 });
    try be.submit(.{ .list = &list, .clear = Color.rgb(0, 0, 255) });
    try be.endFrame();
    const img = try be.readback(testing.allocator);
    defer img.deinit(testing.allocator);
    try testing.expectEqual(@as(u32, 16), img.width);
    try expectNear(.{ 255, 0, 0, 255 }, pixel(img, 3, 3), 1);
    try expectNear(.{ 255, 0, 0, 255 }, pixel(img, 5, 4), 1);
    try expectNear(.{ 0, 0, 255, 255 }, pixel(img, 1, 3), 1); // left of the rect
    try expectNear(.{ 0, 0, 255, 255 }, pixel(img, 3, 6), 1); // below it: y grows down
    try expectNear(.{ 0, 0, 255, 255 }, pixel(img, 15, 11), 1);
}

test "partial redraw keeps what is outside the damage" {
    const gpu = try testBackend(null);
    defer gpu.destroy();
    const be = gpu.backend();
    var cmds: [8]draw_list.Command = undefined;
    var gl: [1]draw_list.Glyph = undefined;
    var list = draw_list.DrawList.init(&cmds, &gl);
    try be.beginFrame(.{ .pixel_w = 16, .pixel_h = 16 });
    try be.submit(.{ .list = &list, .clear = Color.rgb(10, 20, 30) });
    try be.endFrame();

    try list.fillRect(.{ .x = 0, .y = 0, .w = 16, .h = 16 }, .{ .color = Color.rgb(200, 0, 0) });
    try be.beginFrame(.{ .pixel_w = 16, .pixel_h = 16 });
    try be.submit(.{ .list = &list, .clear = Color.rgb(1, 2, 3), .damage = .{ .x = 4, .y = 4, .w = 4, .h = 4 } });
    try be.endFrame();
    const img = try be.readback(testing.allocator);
    defer img.deinit(testing.allocator);
    try expectNear(.{ 200, 0, 0, 255 }, pixel(img, 5, 5), 1); // redrawn inside the damage
    try expectNear(.{ 10, 20, 30, 255 }, pixel(img, 1, 1), 1); // untouched outside it
    try expectNear(.{ 10, 20, 30, 255 }, pixel(img, 12, 12), 1);
}

fn sceneList(list: *draw_list.DrawList) !void {
    const P = draw_list.Paint;
    try list.fillRect(.{ .x = 0, .y = 0, .w = 96, .h = 64 }, P.solid(Color.rgb(30, 32, 40)));
    try list.fillRect(.{ .x = 3.5, .y = 4.25, .w = 20.5, .h = 11.5 }, P.solid(Color.rgb(220, 80, 60)));
    try list.fillRoundedRect(.{ .x = 30, .y = 4, .w = 40, .h = 24 }, .{ 8, 2, 12, 0 }, P.solid(Color.rgb(60, 160, 220)));
    try list.strokeRoundedRect(.{ .x = 30, .y = 4, .w = 40, .h = 24 }, 2, 6, P.solid(Color.white));
    try list.line(.{ .x = 4, .y = 30 }, .{ .x = 60, .y = 50 }, 3, P.solid(Color.rgb(250, 220, 40)));
    try list.fillRect(.{ .x = 4, .y = 40, .w = 50, .h = 16 }, P.linear(.{ .x = 4, .y = 0 }, .{ .x = 54, .y = 0 }, Color.rgb(255, 0, 0), Color.rgb(0, 0, 255)));
    try list.fillRoundedRect(.{ .x = 60, .y = 34, .w = 30, .h = 26 }, .{ 10, 10, 10, 10 }, P.radial(.{ .x = 75, .y = 47 }, .{ .x = 90, .y = 47 }, Color.rgb(255, 255, 255), Color.rgb(0, 120, 0)));
    try list.pushClip(.{ .x = 10, .y = 20, .w = 30, .h = 10 });
    try list.pushOpacity(0.5);
    try list.fillRect(.{ .x = 0, .y = 0, .w = 96, .h = 64 }, P.solid(Color.rgb(255, 255, 255)));
    _ = try list.popOpacity();
    _ = try list.popClip();
}

test "shapes, gradients, clips, and opacity match the software rasterizer" {
    const gpu = try testBackend(null);
    defer gpu.destroy();
    const be = gpu.backend();
    var cmds: [64]draw_list.Command = undefined;
    var gl: [1]draw_list.Glyph = undefined;
    var list = draw_list.DrawList.init(&cmds, &gl);
    try sceneList(&list);

    for ([_]f32{ 1, 2 }) |scale| {
        const w: u32 = @intFromFloat(96 * scale);
        const h: u32 = @intFromFloat(64 * scale);
        try be.beginFrame(.{ .pixel_w = w, .pixel_h = h, .scale = scale });
        try be.submit(.{ .list = &list, .clear = Color.black });
        try be.endFrame();
        const got = try be.readback(testing.allocator);
        defer got.deinit(testing.allocator);

        var fb = try software.Framebuffer.init(testing.allocator, w, h);
        defer fb.deinit(testing.allocator);
        software.render(&fb, &list, .{ .scale = scale, .clear = Color.black });

        var worst: u8 = 0;
        var off: usize = 0;
        var i: usize = 0;
        while (i < got.rgba.len) : (i += 1) {
            const a = got.rgba[i];
            const b = fb.bytes()[i];
            const d = if (a > b) a - b else b - a;
            worst = @max(worst, d);
            if (d > 6) off += 1;
        }
        if (off > 0) std.debug.print("scale {d}: {d} channel values differ by more than 6 (worst {d})\n", .{ scale, off, worst });
        try testing.expect(worst <= 24);
        try testing.expect(off <= got.rgba.len / 400); // a few edge pixels at most
    }
}

test "textures: updates land in the right place; images scale, tint, and respect nearest filtering" {
    const gpu = try testBackend(null);
    defer gpu.destroy();
    const be = gpu.backend();
    const tex = try be.createTexture(.{ .width = 2, .height = 1 });
    try be.updateTexture(tex, .{ .x = 0, .y = 0, .w = 2, .h = 1 }, &.{ 255, 0, 0, 255, 0, 255, 0, 255 }, 8);
    try testing.expectError(error.BadTexture, be.updateTexture(tex, .{ .x = 1, .y = 0, .w = 2, .h = 1 }, &.{ 0, 0, 0, 0, 0, 0, 0, 0 }, 8));

    var cmds: [8]draw_list.Command = undefined;
    var gl: [1]draw_list.Glyph = undefined;
    var list = draw_list.DrawList.init(&cmds, &gl);
    try list.image(.{ .rect = .{ .x = 0, .y = 0, .w = 8, .h = 2 }, .texture = tex, .filter = .nearest });
    try list.image(.{ .rect = .{ .x = 0, .y = 4, .w = 8, .h = 2 }, .texture = tex, .filter = .nearest, .tint = Color.rgb(128, 128, 128) });
    try be.beginFrame(.{ .pixel_w = 8, .pixel_h = 6 });
    try be.submit(.{ .list = &list, .clear = Color.black });
    try be.endFrame();
    const img = try be.readback(testing.allocator);
    defer img.deinit(testing.allocator);
    try expectNear(.{ 255, 0, 0, 255 }, pixel(img, 1, 0), 2);
    try expectNear(.{ 0, 255, 0, 255 }, pixel(img, 6, 1), 2);
    try expectNear(.{ 128, 0, 0, 255 }, pixel(img, 1, 4), 3);
    try expectNear(.{ 0, 0, 0, 255 }, pixel(img, 1, 3), 1);

    be.destroyTexture(tex);
    try testing.expectError(error.BadTexture, be.updateTexture(tex, .{ .x = 0, .y = 0, .w = 1, .h = 1 }, &.{ 0, 0, 0, 0 }, 4));
    const leftover = try be.createTexture(.{ .width = 4, .height = 4, .format = .alpha8 }); // freed by destroy()
    _ = leftover;
}

test "Ui.renderFrame draws text through the GPU atlas and matches the software renderer" {
    const gpu = try testBackend(null);
    defer gpu.destroy();
    var ui = try zigui.Ui.init(testing.allocator);
    defer ui.deinit();
    var prop: zigui.font.TestFont = .{};
    var mono: zigui.font.TestFont = .{ .monospace = true };
    _ = try ui.addFont(prop.backend());
    ui.theme.mono_font = try ui.addFont(mono.backend());
    ui.theme.font_size = 16;
    const root = ui.tree.root;
    ui.tree.get(root).?.style = .{ .direction = .column, .gap = zigui.Length.px(4), .padding = zigui.style.Edges.all(6) };
    ui.tree.get(root).?.visual = .{ .background = Color.rgb(24, 26, 32) };
    _ = try ui.add(zigui.Label, root, .{ .text = "Hello GPU text", .color = Color.white });
    _ = try ui.add(zigui.Button, root, .{ .text = "Button", .style = .{ .width = zigui.Length.px(100), .height = zigui.Length.px(28), .shrink = 0 } });
    const field = try ui.add(zigui.TextField, root, .{ .text = "field text", .style = .{ .width = zigui.Length.px(160), .height = zigui.Length.px(26), .shrink = 0 } });
    _ = field;
    const ed = try ui.add(zigui.CodeEditor, root, .{ .style = .{ .width = zigui.Length.px(200), .height = zigui.Length.px(80), .shrink = 0 } });
    try ed.loadText("fn main() void {\n    return;\n}\n", false);

    var cmds: [1024]draw_list.Command = undefined;
    var glyphs: [2048]draw_list.Glyph = undefined;
    var list = draw_list.DrawList.init(&cmds, &glyphs);
    ui.update();
    try ui.renderFrame(gpu.backend(), &list, .{ .pixel_w = 240, .pixel_h = 220, .clear = Color.black });
    try testing.expect(gpu.last_batches > 1); // shapes, plus at least one glyph page
    try testing.expect(gpu.atlas[0] != null);
    const got = try gpu.backend().readback(testing.allocator);
    defer got.deinit(testing.allocator);

    var fb = try software.Framebuffer.init(testing.allocator, 240, 220);
    defer fb.deinit(testing.allocator);
    software.render(&fb, &list, .{ .clear = Color.black, .glyphs = ui.glyphProvider() });
    var off: usize = 0;
    for (got.rgba, fb.bytes()) |a, b| {
        const d = if (a > b) a - b else b - a;
        if (d > 8) off += 1;
    }
    if (off > 0) std.debug.print("{d} channel values differ by more than 8\n", .{off});
    try testing.expect(off <= got.rgba.len / 500);
    // And there really is text: some bright pixel on the dark background.
    var bright = false;
    var i: usize = 0;
    while (i < got.rgba.len) : (i += 4) {
        if (got.rgba[i] > 200 and got.rgba[i + 1] > 200 and got.rgba[i + 2] > 200) bright = true;
    }
    try testing.expect(bright);
}

test "frame state is enforced and stats count draw calls" {
    const gpu = try testBackend(null);
    defer gpu.destroy();
    const be = gpu.backend();
    var cmds: [8]draw_list.Command = undefined;
    var gl: [1]draw_list.Glyph = undefined;
    var list = draw_list.DrawList.init(&cmds, &gl);
    try testing.expectError(error.BadFrameState, be.submit(.{ .list = &list }));
    try testing.expectError(error.BadFrameState, be.endFrame());
    try be.beginFrame(.{ .pixel_w = 8, .pixel_h = 8 });
    try testing.expectError(error.BadFrameState, be.beginFrame(.{ .pixel_w = 8, .pixel_h = 8 }));
    try list.fillRect(.{ .x = 0, .y = 0, .w = 4, .h = 4 }, .{ .color = Color.white });
    try list.fillRect(.{ .x = 4, .y = 4, .w = 4, .h = 4 }, .{ .color = Color.white });
    try be.submit(.{ .list = &list });
    try be.endFrame();
    try testing.expectEqual(@as(u32, 1), gpu.last_batches); // same texture and clip: one draw call
    try testing.expectEqual(@as(u32, 12), gpu.last_vertices);
}
