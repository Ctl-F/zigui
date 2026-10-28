//! SDL3 platform shim: windows, events, and presenting a software framebuffer.
//!
//! This is the thin interface of our own from design doc section 22. Nothing
//! outside this file sees SDL types, so a native backend can replace it per
//! platform later. Events carry the id of the window they belong to, so
//! multi-window support does not need an API change.

const std = @import("std");
const c = @import("sdl_c");
const zigui = @import("zigui");
const Key = zigui.keys.Key;

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
        mouse_button: struct { x: f32, y: f32, button: MouseButton, down: bool, clicks: u32 },
        /// `x`/`y` are the scroll amounts (positive y is up); `px`/`py` where the
        /// pointer was when the wheel turned (window coordinates).
        mouse_wheel: struct { x: f32, y: f32, px: f32, py: f32 },
        /// The pointer left the window: hover should clear.
        pointer_left,
        /// The window lost keyboard focus: a held button's release may never arrive.
        focus_lost,
        key: struct { key: Key, mods: zigui.keys.Mods, scancode: u32, keycode: u32, down: bool, repeat: bool },
        /// Committed text. Copied out of SDL's buffer, truncated to 63 bytes
        /// at a code point boundary.
        text_input: struct { bytes: [64]u8, len: u8 },
        /// IME composition (uncommitted text), same truncation as `text_input`.
        /// `cursor` is the IME caret as a byte offset into the text.
        text_editing: struct { bytes: [64]u8, len: u8, cursor: u8 },
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

/// Map the window and wait for the compositor to finish configuring it before
/// a renderer attaches a buffer. Wayland compositors may otherwise not route
/// pointer input to a window until its first resize.
fn showAndSync(handle: *c.SDL_Window) void {
    _ = c.SDL_ShowWindow(handle);
    _ = c.SDL_SyncWindow(handle);
}

pub const Window = struct {
    handle: *c.SDL_Window,
    /// Null for a window made with `createGpu` (a GPU device owns its drawing).
    renderer: ?*c.SDL_Renderer,
    texture: ?*c.SDL_Texture = null,
    tex_w: u32 = 0,
    tex_h: u32 = 0,

    pub fn create(title: [:0]const u8, logical_w: u32, logical_h: u32) Error!Window {
        const flags = c.SDL_WINDOW_RESIZABLE | c.SDL_WINDOW_HIGH_PIXEL_DENSITY;
        const handle = c.SDL_CreateWindow(title.ptr, @intCast(logical_w), @intCast(logical_h), flags) orelse
            return error.WindowFailed;
        errdefer c.SDL_DestroyWindow(handle);
        showAndSync(handle);
        const renderer = c.SDL_CreateRenderer(handle, null) orelse return error.RendererFailed;
        std.log.info("sdl: video driver {s}, renderer {s}", .{ std.mem.span(@as([*:0]const u8, c.SDL_GetCurrentVideoDriver() orelse @ptrCast("?"))), std.mem.span(@as([*:0]const u8, c.SDL_GetRendererName(renderer) orelse @ptrCast("?"))) });
        // Pace presents to the display so continuous canvases do not spin.
        _ = c.SDL_SetRenderVSync(renderer, 1);
        return .{ .handle = handle, .renderer = renderer };
    }

    /// A window for the SDL GPU backend (`zigui_gpu`): no software renderer is
    /// attached, so the GPU device can claim it. `present` is not available.
    pub fn createGpu(title: [:0]const u8, logical_w: u32, logical_h: u32) Error!Window {
        const flags = c.SDL_WINDOW_RESIZABLE | c.SDL_WINDOW_HIGH_PIXEL_DENSITY;
        const handle = c.SDL_CreateWindow(title.ptr, @intCast(logical_w), @intCast(logical_h), flags) orelse
            return error.WindowFailed;
        showAndSync(handle);
        return .{ .handle = handle, .renderer = null };
    }

    pub fn destroy(self: *Window) void {
        if (self.texture) |t| c.SDL_DestroyTexture(t);
        if (self.renderer) |r| c.SDL_DestroyRenderer(r);
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
        const renderer = self.renderer orelse return error.RendererFailed;
        if (self.texture == null or self.tex_w != w or self.tex_h != h) {
            if (self.texture) |t| c.SDL_DestroyTexture(t);
            self.texture = c.SDL_CreateTexture(
                renderer,
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
        _ = c.SDL_RenderClear(renderer);
        if (!c.SDL_RenderTexture(renderer, tex, null, null)) return error.PresentFailed;
        if (!c.SDL_RenderPresent(renderer)) return error.PresentFailed;
    }
};

fn sc(comptime v: anytype) u32 {
    return @intCast(v);
}

fn mapKey(scancode: u32) Key {
    const a = sc(c.SDL_SCANCODE_A);
    if (scancode >= a and scancode <= a + 25) return @enumFromInt(@intFromEnum(Key.a) + (scancode - a));
    const f1 = sc(c.SDL_SCANCODE_F1);
    if (scancode >= f1 and scancode <= f1 + 11) return @enumFromInt(@intFromEnum(Key.f1) + (scancode - f1));
    const n1 = sc(c.SDL_SCANCODE_1);
    if (scancode >= n1 and scancode <= n1 + 8) return @enumFromInt(@intFromEnum(Key.d1) + (scancode - n1));
    return switch (scancode) {
        sc(c.SDL_SCANCODE_0) => .d0,
        sc(c.SDL_SCANCODE_MINUS) => .minus,
        sc(c.SDL_SCANCODE_EQUALS) => .equals,
        sc(c.SDL_SCANCODE_LEFTBRACKET) => .left_bracket,
        sc(c.SDL_SCANCODE_RIGHTBRACKET) => .right_bracket,
        sc(c.SDL_SCANCODE_BACKSLASH) => .backslash,
        sc(c.SDL_SCANCODE_SEMICOLON) => .semicolon,
        sc(c.SDL_SCANCODE_APOSTROPHE) => .quote,
        sc(c.SDL_SCANCODE_GRAVE) => .grave,
        sc(c.SDL_SCANCODE_COMMA) => .comma,
        sc(c.SDL_SCANCODE_PERIOD) => .period,
        sc(c.SDL_SCANCODE_SLASH) => .slash,
        sc(c.SDL_SCANCODE_RETURN), sc(c.SDL_SCANCODE_KP_ENTER) => .enter,
        sc(c.SDL_SCANCODE_ESCAPE) => .escape,
        sc(c.SDL_SCANCODE_BACKSPACE) => .backspace,
        sc(c.SDL_SCANCODE_TAB) => .tab,
        sc(c.SDL_SCANCODE_SPACE) => .space,
        sc(c.SDL_SCANCODE_DELETE) => .delete,
        sc(c.SDL_SCANCODE_INSERT) => .insert,
        sc(c.SDL_SCANCODE_LEFT) => .left,
        sc(c.SDL_SCANCODE_RIGHT) => .right,
        sc(c.SDL_SCANCODE_UP) => .up,
        sc(c.SDL_SCANCODE_DOWN) => .down,
        sc(c.SDL_SCANCODE_HOME) => .home,
        sc(c.SDL_SCANCODE_END) => .end,
        sc(c.SDL_SCANCODE_PAGEUP) => .page_up,
        sc(c.SDL_SCANCODE_PAGEDOWN) => .page_down,
        else => .unknown,
    };
}

fn mapMods(mod: u32) zigui.keys.Mods {
    return .{
        .shift = mod & sc(c.SDL_KMOD_SHIFT) != 0,
        .ctrl = mod & sc(c.SDL_KMOD_CTRL) != 0,
        .alt = mod & sc(c.SDL_KMOD_ALT) != 0,
        .gui = mod & sc(c.SDL_KMOD_GUI) != 0,
    };
}

fn translate(ev: *const c.SDL_Event) ?Event {
    switch (ev.type) {
        c.SDL_EVENT_QUIT => return .{ .data = .quit },
        c.SDL_EVENT_WINDOW_CLOSE_REQUESTED => return .{ .window = ev.window.windowID, .data = .close_requested },
        c.SDL_EVENT_WINDOW_PIXEL_SIZE_CHANGED => return .{
            .window = ev.window.windowID,
            .data = .{ .resized = .{ .w = @intCast(@max(ev.window.data1, 1)), .h = @intCast(@max(ev.window.data2, 1)) } },
        },
        // Anything that can change what is on screen or how it maps (the
        // compositor may configure the surface after the first frame): redraw.
        c.SDL_EVENT_WINDOW_EXPOSED,
        c.SDL_EVENT_WINDOW_SHOWN,
        c.SDL_EVENT_WINDOW_RESIZED,
        c.SDL_EVENT_WINDOW_DISPLAY_SCALE_CHANGED,
        c.SDL_EVENT_WINDOW_FOCUS_GAINED,
        c.SDL_EVENT_WINDOW_MOUSE_ENTER,
        => return .{ .window = ev.window.windowID, .data = .expose },
        c.SDL_EVENT_MOUSE_MOTION => return .{
            .window = ev.motion.windowID,
            .data = .{ .mouse_move = .{ .x = ev.motion.x, .y = ev.motion.y } },
        },
        c.SDL_EVENT_MOUSE_BUTTON_DOWN, c.SDL_EVENT_MOUSE_BUTTON_UP => {
            // While a button is held keep receiving the pointer outside the
            // window, so the release is never lost.
            _ = c.SDL_CaptureMouse(ev.type == c.SDL_EVENT_MOUSE_BUTTON_DOWN);
            return .{
            .window = ev.button.windowID,
            .data = .{ .mouse_button = .{
                .x = ev.button.x,
                .y = ev.button.y,
                .button = @enumFromInt(ev.button.button),
                .down = ev.type == c.SDL_EVENT_MOUSE_BUTTON_DOWN,
                .clicks = ev.button.clicks,
            } },
            };
        },
        c.SDL_EVENT_MOUSE_WHEEL => return .{
            .window = ev.wheel.windowID,
            .data = .{ .mouse_wheel = .{ .x = ev.wheel.x, .y = ev.wheel.y, .px = ev.wheel.mouse_x, .py = ev.wheel.mouse_y } },
        },
        c.SDL_EVENT_WINDOW_MOUSE_LEAVE => return .{ .window = ev.window.windowID, .data = .pointer_left },
        c.SDL_EVENT_WINDOW_FOCUS_LOST => return .{ .window = ev.window.windowID, .data = .focus_lost },
        c.SDL_EVENT_KEY_DOWN, c.SDL_EVENT_KEY_UP => return .{
            .window = ev.key.windowID,
            .data = .{ .key = .{
                .key = mapKey(@intCast(ev.key.scancode)),
                .mods = mapMods(@intCast(ev.key.mod)),
                .scancode = @intCast(ev.key.scancode),
                .keycode = @intCast(ev.key.key),
                .down = ev.type == c.SDL_EVENT_KEY_DOWN,
                .repeat = ev.key.repeat,
            } },
        },
        c.SDL_EVENT_TEXT_INPUT => {
            const src = std.mem.span(ev.text.text);
            var n = @min(src.len, 63);
            // Do not cut a multi-byte character in half.
            while (n > 0 and n < src.len and (src[n] & 0xC0) == 0x80) n -= 1;
            var out: Event.Data = .{ .text_input = .{ .bytes = undefined, .len = @intCast(n) } };
            @memcpy(out.text_input.bytes[0..n], src[0..n]);
            return .{ .window = ev.text.windowID, .data = out };
        },
        c.SDL_EVENT_TEXT_EDITING => {
            const src = std.mem.span(ev.edit.text);
            var n = @min(src.len, 63);
            while (n > 0 and n < src.len and (src[n] & 0xC0) == 0x80) n -= 1;
            // SDL reports the caret in characters; convert to a byte offset.
            var cursor_bytes: usize = n;
            if (ev.edit.start >= 0) {
                var chars: i32 = 0;
                var i: usize = 0;
                while (i < n and chars < ev.edit.start) : (chars += 1) {
                    i += std.unicode.utf8ByteSequenceLength(src[i]) catch 1;
                }
                cursor_bytes = @min(i, n);
            }
            var out: Event.Data = .{ .text_editing = .{ .bytes = undefined, .len = @intCast(n), .cursor = @intCast(cursor_bytes) } };
            @memcpy(out.text_editing.bytes[0..n], src[0..n]);
            return .{ .window = ev.edit.windowID, .data = out };
        },
        else => return null,
    }
}

// ---- text input, clipboard, cursor, time -----------------------------------

/// Enable text input events (and the on-screen keyboard / IME where present).
pub fn startTextInput(window: *const Window) void {
    _ = c.SDL_StartTextInput(window.handle);
}

pub fn stopTextInput(window: *const Window) void {
    _ = c.SDL_StopTextInput(window.handle);
}

/// Tell the IME where the caret is (window coordinates, logical pixels).
pub fn setTextInputArea(window: *const Window, x: f32, y: f32, w: f32, h: f32) void {
    const rect: c.SDL_Rect = .{ .x = @intFromFloat(x), .y = @intFromFloat(y), .w = @intFromFloat(@max(w, 1)), .h = @intFromFloat(@max(h, 1)) };
    _ = c.SDL_SetTextInputArea(window.handle, &rect, 0);
}

/// Clipboard text copied into memory from `gpa`, or null if empty.
pub fn clipboardGet(gpa: std.mem.Allocator) ?[]u8 {
    const raw = c.SDL_GetClipboardText() orelse return null;
    defer c.SDL_free(raw);
    const s = std.mem.span(raw);
    if (s.len == 0) return null;
    return gpa.dupe(u8, s) catch null;
}

pub fn clipboardSet(text: []const u8) void {
    var buf: [4096]u8 = undefined;
    const n = @min(text.len, buf.len - 1);
    @memcpy(buf[0..n], text[0..n]);
    buf[n] = 0;
    _ = c.SDL_SetClipboardText(&buf);
}

/// Milliseconds since SDL started.
pub fn ticks() u64 {
    return c.SDL_GetTicks();
}

/// Wake a blocked `waitEvent` from any thread (the event is dropped by the shim;
/// the loop just runs another iteration).
pub fn wake() void {
    var ev: c.SDL_Event = std.mem.zeroes(c.SDL_Event);
    ev.type = c.SDL_EVENT_USER;
    _ = c.SDL_PushEvent(&ev);
}

/// Nanoseconds from a monotonic clock, for `Ui.clock`.
pub fn ticksNs() u64 {
    return c.SDL_GetTicksNS();
}

pub const Cursor = enum { default, text, pointer, resize_horizontal, resize_vertical };

var cursors: [5]?*c.SDL_Cursor = .{ null, null, null, null, null };
var current_cursor: ?Cursor = null;

pub fn setCursor(kind: Cursor) void {
    if (current_cursor == kind) return;
    const idx = @intFromEnum(kind);
    if (cursors[idx] == null) {
        const sys: c_uint = switch (kind) {
            .default => c.SDL_SYSTEM_CURSOR_DEFAULT,
            .text => c.SDL_SYSTEM_CURSOR_TEXT,
            .pointer => c.SDL_SYSTEM_CURSOR_POINTER,
            .resize_horizontal => c.SDL_SYSTEM_CURSOR_EW_RESIZE,
            .resize_vertical => c.SDL_SYSTEM_CURSOR_NS_RESIZE,
        };
        cursors[idx] = c.SDL_CreateSystemCursor(sys);
    }
    if (cursors[idx]) |cur| {
        _ = c.SDL_SetCursor(cur);
        current_cursor = kind;
    }
}

/// Next pending event, or null if the queue is empty. Events the toolkit
/// does not use are skipped.
/// An event read ahead while merging mouse motion; returned by the next call.
var lookahead: ?c.SDL_Event = null;

fn nextRaw(wait_ms: ?i32) ?c.SDL_Event {
    if (lookahead) |e| {
        lookahead = null;
        return e;
    }
    var ev: c.SDL_Event = undefined;
    if (wait_ms) |ms| {
        if (!c.SDL_WaitEventTimeout(&ev, ms)) return null;
        return ev;
    }
    if (!c.SDL_PollEvent(&ev)) return null;
    return ev;
}

/// Translate the next queued event. Runs of mouse motion are merged into the
/// last one: handling every motion of a fast mouse costs hit tests and hover
/// work for positions that are never drawn.
fn nextEvent(wait_ms: ?i32) ?Event {
    var first = true;
    while (nextRaw(if (first) wait_ms else null)) |ev| {
        first = false;
        var cur = ev;
        if (cur.type == c.SDL_EVENT_MOUSE_MOTION) {
            while (nextRaw(null)) |more| {
                if (more.type == c.SDL_EVENT_MOUSE_MOTION and more.motion.windowID == cur.motion.windowID) {
                    cur = more;
                } else {
                    lookahead = more;
                    break;
                }
            }
        }
        if (translate(&cur)) |e| return e;
    }
    return null;
}

pub fn pollEvent() ?Event {
    return nextEvent(null);
}

/// Block until an event arrives or `timeout_ms` passes (negative waits forever).
pub fn waitEvent(timeout_ms: i32) ?Event {
    return nextEvent(timeout_ms);
}

/// Show the cursor shape the UI asks for (`Ui.cursor()`).
pub fn setUiCursor(shape: zigui.tree.Cursor) void {
    setCursor(switch (shape) {
        .default => .default,
        .text => .text,
        .pointer => .pointer,
        .resize_horizontal => .resize_horizontal,
        .resize_vertical => .resize_vertical,
    });
}
