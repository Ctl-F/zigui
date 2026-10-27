//! A tiny paint program: a canvas with an offscreen surface (design doc section 9).
//!
//! Run:  zig build paint
//!
//! Drag to draw. Keys 1-6 pick a color, [ and ] change the brush size, C clears,
//! E toggles the eraser. The canvas is in raw-key mode, so every key reaches it.
//! Only the pixels a stroke touched are uploaded.
//!
//! Env (for headless checks, with SDL_VIDEODRIVER=dummy):
//!   ZIGUI_SCRIPT="drag 100 100 300 200;key d3;drag 100 300 400 300"
//!   ZIGUI_SCREENSHOT=out.png

const std = @import("std");
const zigui = @import("zigui");
const sdl = @import("zigui_sdl");
const stb = @import("zigui_stb");

const Ui = zigui.Ui;
const Color = zigui.Color;

const surface_w = 800;
const surface_h = 560;

const palette = [_]Color{
    Color.rgb(20, 20, 24),   Color.rgb(224, 64, 64),  Color.rgb(240, 170, 40),
    Color.rgb(80, 190, 90),  Color.rgb(64, 140, 230), Color.rgb(170, 90, 220),
};

const Point = struct { x: f32, y: f32 };

const Paint = struct {
    ui: *Ui,
    canvas: *zigui.Canvas = undefined,
    pixels: []u8,
    color: Color = palette[0],
    radius: f32 = 6,
    eraser: bool = false,
    last: ?Point = null,

    fn stamp(self: *Paint, cx: f32, cy: f32) ?zigui.render_backend.URect {
        const r = self.radius;
        const x0: i32 = @max(@as(i32, @intFromFloat(@floor(cx - r))), 0);
        const y0: i32 = @max(@as(i32, @intFromFloat(@floor(cy - r))), 0);
        const x1: i32 = @min(@as(i32, @intFromFloat(@ceil(cx + r))) + 1, surface_w);
        const y1: i32 = @min(@as(i32, @intFromFloat(@ceil(cy + r))) + 1, surface_h);
        if (x1 <= x0 or y1 <= y0) return null;
        const paper = Color.rgb(250, 248, 242);
        const c = if (self.eraser) paper else self.color;
        var y = y0;
        while (y < y1) : (y += 1) {
            var x = x0;
            while (x < x1) : (x += 1) {
                const dx = @as(f32, @floatFromInt(x)) + 0.5 - cx;
                const dy = @as(f32, @floatFromInt(y)) + 0.5 - cy;
                if (dx * dx + dy * dy <= r * r) {
                    const i = (@as(usize, @intCast(y)) * surface_w + @as(usize, @intCast(x))) * 4;
                    self.pixels[i..][0..4].* = .{ c.r, c.g, c.b, 255 };
                }
            }
        }
        return .{ .x = @intCast(x0), .y = @intCast(y0), .w = @intCast(x1 - x0), .h = @intCast(y1 - y0) };
    }

    /// Stamp along the segment so fast strokes stay connected, then upload
    /// only the touched rectangle.
    fn stroke(self: *Paint, x: f32, y: f32) void {
        const from: Point = self.last orelse .{ .x = x, .y = y };
        const dist = std.math.hypot(x - from.x, y - from.y);
        const steps: usize = @max(@as(usize, @intFromFloat(dist / (self.radius * 0.5))), 1);
        var dirty: ?zigui.render_backend.URect = null;
        for (0..steps + 1) |i| {
            const t = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(steps));
            if (self.stamp(from.x + (x - from.x) * t, from.y + (y - from.y) * t)) |r| {
                dirty = if (dirty) |d| unite(d, r) else r;
            }
        }
        self.last = .{ .x = x, .y = y };
        if (dirty) |d| {
            const offset = (@as(usize, d.y) * surface_w + d.x) * 4;
            self.canvas.updateSurface(d, self.pixels[offset..], surface_w * 4) catch {};
        }
    }

    fn unite(a: zigui.render_backend.URect, b: zigui.render_backend.URect) zigui.render_backend.URect {
        const x0 = @min(a.x, b.x);
        const y0 = @min(a.y, b.y);
        return .{ .x = x0, .y = y0, .w = @max(a.x + a.w, b.x + b.w) - x0, .h = @max(a.y + a.h, b.y + b.h) - y0 };
    }

    fn clear(self: *Paint) void {
        var i: usize = 0;
        while (i < self.pixels.len) : (i += 4) self.pixels[i..][0..4].* = .{ 250, 248, 242, 255 };
        self.canvas.updateSurface(.{ .x = 0, .y = 0, .w = surface_w, .h = surface_h }, self.pixels, surface_w * 4) catch {};
    }

    fn onPointer(self: *Paint, ev: *zigui.event.Event) void {
        switch (ev.kind) {
            .pointer_down, .pointer_move => {
                if (ev.kind == .pointer_move and !self.canvas.out.pressed) {
                    self.last = null;
                    return;
                }
                if (self.canvas.toSurface(ev.local_x, ev.local_y)) |p| self.stroke(p.x, p.y);
            },
            .pointer_up => self.last = null,
            else => {},
        }
    }

    fn onKey(self: *Paint, ev: *zigui.event.Event) void {
        if (ev.kind != .key_down) return;
        switch (ev.key) {
            .d1, .d2, .d3, .d4, .d5, .d6 => {
                self.color = palette[@intFromEnum(ev.key) - @intFromEnum(zigui.keys.Key.d1)];
                self.eraser = false;
            },
            .c => self.clear(),
            .e => self.eraser = !self.eraser,
            .left_bracket => self.radius = @max(self.radius - 2, 1),
            .right_bracket => self.radius = @min(self.radius + 2, 60),
            else => {},
        }
    }

    fn pick(self: *Paint, ev: *zigui.event.Event) void {
        const n = self.ui.tree.get(ev.current) orelse return;
        self.color = palette[@intFromPtr(n.user_data) - 1];
        self.eraser = false;
    }
};

const WindowPresenter = struct {
    window: *sdl.Window,

    fn present(ctx: ?*anyopaque, rgba: []const u8, w: u32, h: u32) zigui.render_backend.Error!void {
        const self: *WindowPresenter = @ptrCast(@alignCast(ctx.?));
        self.window.present(rgba, w, h) catch return error.PresentFailed;
    }
};

fn runCommand(p: *Paint, ui: *Ui, cmd: []const u8) void {
    const sp = std.mem.indexOfScalar(u8, cmd, ' ') orelse return;
    const verb = cmd[0..sp];
    const rest = cmd[sp + 1 ..];
    if (std.mem.eql(u8, verb, "key")) {
        const k = zigui.keys.parseKey(rest) orelse return;
        ui.key(k, .{}, true, false);
        ui.key(k, .{}, false, false);
    } else if (std.mem.eql(u8, verb, "drag")) {
        var nums = std.mem.tokenizeScalar(u8, rest, ' ');
        var v: [4]f32 = undefined;
        for (&v) |*x| x.* = std.fmt.parseFloat(f32, nums.next() orelse return) catch return;
        ui.pointerMove(v[0], v[1]);
        ui.pointerButtonEx(v[0], v[1], 1, true, 1);
        const steps = 12;
        for (1..steps + 1) |i| {
            const t = @as(f32, @floatFromInt(i)) / steps;
            ui.pointerMove(v[0] + (v[2] - v[0]) * t, v[1] + (v[3] - v[1]) * t);
        }
        ui.pointerButtonEx(v[2], v[3], 1, false, 1);
    }
    _ = p;
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    try sdl.init();
    defer sdl.quit();
    var window = sdl.Window.create("zigui paint", 1000, 700) catch |err| {
        std.log.err("could not create window: {s} ({s})", .{ @errorName(err), sdl.lastError() });
        return err;
    };
    defer window.destroy();

    var ui = try Ui.init(gpa);
    ui.clock = sdl.ticksNs;
    defer ui.deinit();
    const ui_bytes = stb.loadFirst(io, gpa, init.environ_map.get("ZIGUI_FONT"), &stb.ui_font_candidates);
    defer if (ui_bytes) |b| gpa.free(b);
    var ui_font: stb.StbFont = undefined;
    if (ui_bytes) |bytes| {
        try ui_font.init(bytes, 0);
        _ = try ui.addFont(ui_font.backend());
    }

    var wp: WindowPresenter = .{ .window = &window };
    var renderer = try zigui.software_backend.SoftwareBackend.init(gpa, .{ .ctx = &wp, .present = WindowPresenter.present });
    defer renderer.deinit();
    const backend = renderer.backend();
    ui.setBackend(backend);

    const pixels = try gpa.alloc(u8, surface_w * surface_h * 4);
    defer gpa.free(pixels);
    var app: Paint = .{ .ui = &ui, .pixels = pixels };

    const root = ui.tree.root;
    ui.tree.get(root).?.style = .{ .direction = .column, .gap = zigui.Length.px(8), .padding = zigui.style.Edges.all(8) };
    ui.tree.get(root).?.visual = .{ .background = Color.rgb(36, 38, 43) };
    const bar = try ui.tree.create(.{ .style = .{ .direction = .row, .gap = zigui.Length.px(6), .align_items = .center } });
    try ui.tree.appendChild(root, bar);
    _ = try ui.add(zigui.Label, bar, .{ .text = "Colors:" });
    for (palette, 0..) |col, i| {
        const b = try ui.add(zigui.Button, bar, .{ .text = "   ", .style = .{ .width = zigui.Length.px(34) } });
        b.props.on_click = zigui.event.Callback.bind(&app, Paint.pick);
        b.props.colors = .{ .normal = col, .hover = col, .pressed = col, .disabled = col, .border = Color.white, .border_width = 1 };
        ui.tree.get(b.node).?.user_data = @ptrFromInt(i + 1);
    }
    _ = try ui.add(zigui.Label, bar, .{ .text = "  1-6 color   [ ] size   E eraser   C clear" });
    app.canvas = try ui.add(zigui.Canvas, root, .{
        .style = .{ .grow = 1 },
        .raw_keys = true,
        .filter = .linear,
        .on_pointer = zigui.event.Callback.bind(&app, Paint.onPointer),
        .on_key = zigui.event.Callback.bind(&app, Paint.onKey),
    });
    ui.tree.get(app.canvas.node).?.cursor = .pointer;

    const commands = try gpa.alloc(zigui.draw_list.Command, 4096);
    defer gpa.free(commands);
    const glyphs = try gpa.alloc(zigui.draw_list.Glyph, 4096);
    defer gpa.free(glyphs);
    var list = zigui.DrawList.init(commands, glyphs);

    // The surface needs the backend, which is ready now.
    try app.canvas.createSurface(surface_w, surface_h);
    app.clear();
    ui.setFocus(app.canvas.node);

    var force = true;
    const screenshot = init.environ_map.get("ZIGUI_SCREENSHOT");
    var script = std.mem.tokenizeScalar(u8, init.environ_map.get("ZIGUI_SCRIPT") orelse "", ';');
    var running = true;
    while (running) {
        _ = ui.tick(sdl.ticks());
        ui.update();
        if (force or ui.isDirty()) {
            const px = window.pixelSize();
            try ui.renderFrame(backend, &list, .{ .pixel_w = px.w, .pixel_h = px.h, .scale = window.scale(), .clear = Color.black });
            force = false;
        }
        ui.endFrame();
        if (screenshot != null) {
            if (script.next()) |cmd| {
                runCommand(&app, &ui, cmd);
                continue;
            }
            const img = try backend.readback(gpa);
            defer img.deinit(gpa);
            const png = try zigui.png.encodeRgba(gpa, img.rgba, img.width, img.height);
            defer gpa.free(png);
            try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = screenshot.?, .data = png });
            std.log.info("wrote {s}: {d}x{d}", .{ screenshot.?, img.width, img.height });
            app.canvas.releaseSurface();
            return;
        }
        const timeout: i32 = if (ui.nextWakeMs()) |ms| @intCast(ms) else -1;
        var ev = sdl.waitEvent(timeout);
        _ = ui.tick(sdl.ticks());
        while (ev) |e| : (ev = sdl.pollEvent()) {
            switch (e.data) {
                .quit, .close_requested => running = false,
                .resized, .expose => force = true,
                .mouse_move => |m| ui.pointerMove(m.x, m.y),
                .mouse_button => |m| ui.pointerButtonEx(m.x, m.y, @backingInt(m.button), m.down, m.clicks),
                .mouse_wheel => |m| ui.wheel(0, 0, m.x, m.y),
                .text_input => |t| ui.textInput(t.bytes[0..t.len]),
                .key => |k| {
                    const used = ui.keyHandled(k.key, k.mods, k.down, k.repeat);
                    if (k.down and k.key == .escape and !used) {
                        if (ui.focused() != null) ui.setFocus(null) else running = false;
                    }
                },
            }
        }
    }
    app.canvas.releaseSurface();
}
