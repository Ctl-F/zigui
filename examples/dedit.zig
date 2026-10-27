const std = @import("std");
const sdl = @import("zigui_sdl");
const stb = @import("zigui_stb");
const zigui = @import("zigui");

const Ui = zigui.Ui;
const Handle = zigui.Handle;

const App = struct {
    ui: *Ui,
    io: std.Io,
    gpa: std.mem.Allocator,

    fn addNode(self: *App, parent: Handle, style: zigui.Style, visual: zigui.tree.Visual) !Handle {
        const h = try self.ui.tree.create(.{ .style = style, .visual = visual });
        try self.ui.tree.appendChild(parent, h);
        return h;
    }
};

fn app(user: ?*anyopaque) *App {
    return @ptrCast(@alignCast(user.?));
}

fn buildUi(a: *App) !void {
    const ui = a.ui;
    const tree = &ui.tree;

    tree.get(tree.root).?.style = .{ .direction = .column };
    tree.get(tree.root).?.visual = .{ .background = zigui.Color.rgb(32, 40, 60) };

    const header = try a.addNode(tree.root, .{
        .direction = .row,
        .height = zigui.Length.px(44),
        .padding = zigui.style.Edges.xy(12, 8),
        .gap = zigui.Length.px(8),
        .shrink = 0,
    }, .{ .background = zigui.Color.rgb(80, 80, 80) });
    _ = try ui.add(zigui.Label, header, .{
        .style = .{ .grow = 1 },
        .text = "Hello World",
        .size = 12,
        .color = zigui.Color.white,
    });
}

const WindowPresenter = struct {
    window: *sdl.Window,

    fn present(ctx: ?*anyopaque, rgba: []const u8, w: u32, h: u32) zigui.render_backend.Error!void {
        const self: *WindowPresenter = @ptrCast(@alignCast(ctx.?));
        self.window.present(rgba, w, h) catch return error.PresentFailed;
    }

    fn presenter(self: *WindowPresenter) zigui.software_backend.Presenter {
        return .{ .ctx = self, .present = present };
    }
};

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    try sdl.init();
    defer sdl.quit();

    var window = sdl.Window.create("demo editor", 960, 600) catch |err| {
        std.log.err("could not create window: {s} ({s})", .{ @errorName(err), sdl.lastError() });
        return err;
    };
    defer window.destroy();

    var ui = try Ui.init(gpa);
    defer ui.deinit();

    const ui_bytes = stb.loadFirst(io, gpa, init.environ_map.get("ZIGUI_FONT"), &stb.ui_font_candidates);
    defer if (ui_bytes) |b| gpa.free(b);

    const mono_bytes = stb.loadFirst(io, gpa, init.environ_map.get("ZIGUI_MONO_FONT"), &stb.mono_font_candidates);
    defer if (mono_bytes) |b| gpa.free(b);

    var ui_font: stb.StbFont = undefined;
    var mono_font: stb.StbFont = undefined;

    if (ui_bytes) |bytes| {
        try ui_font.init(bytes, 0);
        _ = try ui.addFont(ui_font.backend());
        if (mono_bytes) |mb| {
            try mono_font.init(mb, 0);
            ui.theme.mono_font = try ui.addFont(mono_font.backend());
        }
    } else {
        std.log.warn("no UI font found", .{});
    }

    var state: App = .{ .ui = &ui, .io = io, .gpa = gpa };
    try buildUi(&state);

    const commands = try gpa.alloc(zigui.draw_list.Command, 32768);
    defer gpa.free(commands);
    const glyphs = try gpa.alloc(zigui.draw_list.Glyph, 65536);
    defer gpa.free(glyphs);
    var list = zigui.DrawList.init(commands, glyphs);
    var prewarmed_scale: f32 = 0;

    var presenter = WindowPresenter{ .window = &window };
    var renderer = try zigui.software_backend.SoftwareBackend.init(gpa, presenter.presenter());
    defer renderer.deinit();
    const backend = renderer.backend();

    // var fb = try zigui.software.Framebuffer.init(gpa, 1, 1);
    // defer fb.deinit(gpa);

    var force = true;
    var frames_drawn: u64 = 0;

    var running = true;
    while (running) {
        _ = ui.tick(sdl.ticks());

        ui.update();
        if (force or ui.isDirty()) {
            const px = window.pixelSize();
            const scale = window.scale();

            if (scale != prewarmed_scale) {
                prewarmed_scale = scale;
                for (0..ui.text.fonts.items.len) |f| {
                    ui.text.prewarmAscii(@intCast(f), ui.theme.font_size * scale);
                    ui.text.prewarmAscii(@intCast(f), 13 * scale);
                }
            }

            try ui.renderFrame(backend, &list, .{ .pixel_w = px.w, .pixel_h = px.h, .scale = scale, .clear = zigui.Color.black });

            force = false;
            frames_drawn += 1;
        }

        ui.endFrame();

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
                .text_editing => |t| ui.textEditing(t.bytes[0..t.len], t.cursor),
                .key => |k| {
                    const used = ui.keyHandled(k.key, k.mods, k.down, k.repeat);
                    // Escape that nothing used: leave a focused widget, else quit.
                    if (k.down and k.key == .escape and !used) {
                        if (ui.focused() != null) ui.setFocus(null) else running = false;
                    }
                },
            }
        }
    }
}
