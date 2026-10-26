//! SDL3 platform shim: windows, events, and presenting a software framebuffer.
//!
//! This is the thin interface of our own from design doc section 22. Nothing
//! outside this file sees SDL types, so a native backend can replace it per
//! platform later. Events carry the id of the window they belong to, so
//! multi-window support does not need an API change.

const std = @import("std");
const c = @import("sdl_c");

pub const Error = error{
    InitFailed,
    WindowFailed,
    RendererFailed,
    TextureFailed,
    PresentFailed,
};

pub const MouseButton = enum(u8) { left = 1, middle = 2, right = 3, x1 = 4, x2 = 5, _ };

pub const Event = struct {
    /// Id of the window the event belongs to (0 for global events).
    window: u32 = 0,
    data: Data,

    pub const Data = union(enum) {
        /// The app should quit (last window closed or OS request).
        quit,
        /// The window's close button was pressed.
        close_requested,
        /// The drawable size in device pixels changed.
        resized: struct { w: u32, h: u32 },
        /// The window needs repainting.
        expose,
        mouse_move: struct { x: f32, y: f32 },
        mouse_button: struct { x: f32, y: f32, button: MouseButton, down: bool },
        mouse_wheel: struct { x: f32, y: f32 },
        key: struct { scancode: u32, keycode: u32, down: bool, repeat: bool },
    };
};

pub fn init() Error!void {
    if (!c.SDL_Init(c.SDL_INIT_VIDEO)) return error.InitFailed;
}

pub fn quit() void {
    c.SDL_Quit();
}

/// Last SDL error message, for logging.
pub fn lastError() []const u8 {
    return std.mem.span(c.SDL_GetError());
}

pub const Window = struct {
    handle: *c.SDL_Window,
    renderer: *c.SDL_Renderer,
    texture: ?*c.SDL_Texture = null,
    tex_w: u32 = 0,
    tex_h: u32 = 0,

    pub fn create(title: [:0]const u8, logical_w: u32, logical_h: u32) Error!Window {
        const flags = c.SDL_WINDOW_RESIZABLE | c.SDL_WINDOW_HIGH_PIXEL_DENSITY;
        const handle = c.SDL_CreateWindow(title.ptr, @intCast(logical_w), @intCast(logical_h), flags) orelse
            return error.WindowFailed;
        errdefer c.SDL_DestroyWindow(handle);
        const renderer = c.SDL_CreateRenderer(handle, null) orelse return error.RendererFailed;
        return .{ .handle = handle, .renderer = renderer };
    }

    pub fn destroy(self: *Window) void {
        if (self.texture) |t| c.SDL_DestroyTexture(t);
        c.SDL_DestroyRenderer(self.renderer);
        c.SDL_DestroyWindow(self.handle);
        self.* = undefined;
    }

    pub fn id(self: *const Window) u32 {
        return c.SDL_GetWindowID(self.handle);
    }

    /// Drawable size in device pixels.
    pub fn pixelSize(self: *const Window) struct { w: u32, h: u32 } {
        var w: c_int = 0;
        var h: c_int = 0;
        _ = c.SDL_GetWindowSizeInPixels(self.handle, &w, &h);
        return .{ .w = @intCast(@max(w, 1)), .h = @intCast(@max(h, 1)) };
    }

    /// Device pixels per logical pixel.
    pub fn scale(self: *const Window) f32 {
        var lw: c_int = 0;
        var lh: c_int = 0;
        _ = c.SDL_GetWindowSize(self.handle, &lw, &lh);
        if (lw <= 0) return 1;
        const px = self.pixelSize();
        return @as(f32, @floatFromInt(px.w)) / @as(f32, @floatFromInt(lw));
    }

    pub fn setTitle(self: *Window, title: [:0]const u8) void {
        _ = c.SDL_SetWindowTitle(self.handle, title.ptr);
    }

    /// Upload tightly packed RGBA8 pixels (`w` by `h`) and show them.
    pub fn present(self: *Window, rgba: []const u8, w: u32, h: u32) Error!void {
        if (self.texture == null or self.tex_w != w or self.tex_h != h) {
            if (self.texture) |t| c.SDL_DestroyTexture(t);
            self.texture = c.SDL_CreateTexture(
                self.renderer,
                c.SDL_PIXELFORMAT_RGBA32,
                c.SDL_TEXTUREACCESS_STREAMING,
                @intCast(w),
                @intCast(h),
            ) orelse return error.TextureFailed;
            self.tex_w = w;
            self.tex_h = h;
        }
        const tex = self.texture.?;
        if (!c.SDL_UpdateTexture(tex, null, rgba.ptr, @intCast(w * 4))) return error.PresentFailed;
        _ = c.SDL_RenderClear(self.renderer);
        if (!c.SDL_RenderTexture(self.renderer, tex, null, null)) return error.PresentFailed;
        if (!c.SDL_RenderPresent(self.renderer)) return error.PresentFailed;
    }
};

fn translate(ev: *const c.SDL_Event) ?Event {
    switch (ev.type) {
        c.SDL_EVENT_QUIT => return .{ .data = .quit },
        c.SDL_EVENT_WINDOW_CLOSE_REQUESTED => return .{ .window = ev.window.windowID, .data = .close_requested },
        c.SDL_EVENT_WINDOW_PIXEL_SIZE_CHANGED => return .{
            .window = ev.window.windowID,
            .data = .{ .resized = .{ .w = @intCast(@max(ev.window.data1, 1)), .h = @intCast(@max(ev.window.data2, 1)) } },
        },
        c.SDL_EVENT_WINDOW_EXPOSED => return .{ .window = ev.window.windowID, .data = .expose },
        c.SDL_EVENT_MOUSE_MOTION => return .{
            .window = ev.motion.windowID,
            .data = .{ .mouse_move = .{ .x = ev.motion.x, .y = ev.motion.y } },
        },
        c.SDL_EVENT_MOUSE_BUTTON_DOWN, c.SDL_EVENT_MOUSE_BUTTON_UP => return .{
            .window = ev.button.windowID,
            .data = .{ .mouse_button = .{
                .x = ev.button.x,
                .y = ev.button.y,
                .button = @enumFromInt(ev.button.button),
                .down = ev.type == c.SDL_EVENT_MOUSE_BUTTON_DOWN,
            } },
        },
        c.SDL_EVENT_MOUSE_WHEEL => return .{
            .window = ev.wheel.windowID,
            .data = .{ .mouse_wheel = .{ .x = ev.wheel.x, .y = ev.wheel.y } },
        },
        c.SDL_EVENT_KEY_DOWN, c.SDL_EVENT_KEY_UP => return .{
            .window = ev.key.windowID,
            .data = .{ .key = .{
                .scancode = @intCast(ev.key.scancode),
                .keycode = @intCast(ev.key.key),
                .down = ev.type == c.SDL_EVENT_KEY_DOWN,
                .repeat = ev.key.repeat,
            } },
        },
        else => return null,
    }
}

/// Next pending event, or null if the queue is empty. Events the toolkit
/// does not use are skipped.
pub fn pollEvent() ?Event {
    var ev: c.SDL_Event = undefined;
    while (c.SDL_PollEvent(&ev)) {
        if (translate(&ev)) |e| return e;
    }
    return null;
}

/// Block until an event arrives or `timeout_ms` passes (negative waits forever).
pub fn waitEvent(timeout_ms: i32) ?Event {
    var ev: c.SDL_Event = undefined;
    if (!c.SDL_WaitEventTimeout(&ev, timeout_ms)) return null;
    if (translate(&ev)) |e| return e;
    return pollEvent();
}
