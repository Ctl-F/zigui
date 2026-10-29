//! Docking demo: a code editor, a file tree, an output pane and a properties
//! pane in a dock. Drag a tab onto another group's middle to tab it in, onto an
//! edge to split, hold Shift (or drop outside the window area) to float it,
//! drag a floating window's title strip back onto a group to dock it again.
//! Right-click a tab for Float / Close; the View menu brings closed panels back.
//!
//! Env (headless checks, with SDL_VIDEODRIVER=dummy):
//!   ZIGUI_SCRIPT="drag X Y X2 Y2;float Output;close Files;show Files;click X Y"
//!   ZIGUI_SCREENSHOT=out.png

const std = @import("std");
const zigui = @import("zigui");
const sdl = @import("zigui_sdl");
const stb = @import("zigui_stb");

const Ui = zigui.Ui;
const Dock = zigui.Dock;

const App = struct {
    ui: *Ui,
    dock: *Dock,
    view_panels: [4]*zigui.dock.Panel = undefined,

    fn onViewPick(self: *App, index: usize) void {
        const p = self.view_panels[index];
        if (p.state == .hidden) self.dock.showPanel(p) catch {} else self.dock.closePanel(p);
    }
};

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

fn num(it: *std.mem.TokenIterator(u8, .scalar)) f32 {
    return std.fmt.parseFloat(f32, it.next() orelse "0") catch 0;
}

fn runCommand(app: *App, ui: *Ui, cmd: []const u8) void {
    var words = std.mem.tokenizeScalar(u8, cmd, ' ');
    const verb = words.next() orelse return;
    if (std.mem.eql(u8, verb, "drag")) {
        const x = num(&words);
        const y = num(&words);
        const x2 = num(&words);
        const y2 = num(&words);
        ui.pointerMove(x, y);
        ui.pointerButtonEx(x, y, 1, true, 1);
        for (1..9) |i| {
            const f = @as(f32, @floatFromInt(i)) / 8;
            ui.pointerMove(x + (x2 - x) * f, y + (y2 - y) * f);
            ui.update();
        }
        ui.pointerButtonEx(x2, y2, 1, false, 1);
    } else if (std.mem.eql(u8, verb, "click")) {
        const x = num(&words);
        const y = num(&words);
        ui.pointerMove(x, y);
        ui.pointerButtonEx(x, y, 1, true, 1);
        ui.pointerButtonEx(x, y, 1, false, 1);
    } else if (words.next()) |name| {
        // verbs with a panel name: float NAME, close NAME, show NAME
        const rest = cmd[verb.len + 1 ..];
        _ = name;
        const p = app.dock.panelNamed(rest) orelse return;
        if (std.mem.eql(u8, verb, "float")) app.dock.floatPanel(p, .{ .x = 120, .y = 90, .w = 360, .h = 240 }) catch {};
        if (std.mem.eql(u8, verb, "close")) app.dock.closePanel(p);
        if (std.mem.eql(u8, verb, "show")) app.dock.showPanel(p) catch {};
    }
}

fn clipGet(_: ?*anyopaque, gpa: std.mem.Allocator) ?[]u8 {
    return sdl.clipboardGet(gpa);
}

fn clipSet(_: ?*anyopaque, text: []const u8) void {
    sdl.clipboardSet(text);
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    _ = args;

    try sdl.init();
    defer sdl.quit();
    var window = sdl.Window.create("zigui docking", 1280, 800) catch |err| {
        std.log.err("could not create window: {s} ({s})", .{ @errorName(err), sdl.lastError() });
        return err;
    };
    defer window.destroy();

    var ui = try Ui.init(gpa);
    ui.clock = sdl.ticksNs;
    ui.wake = sdl.wake;
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
        std.log.warn("no UI font found (set ZIGUI_FONT=/path/to/font.ttf); text will not be drawn", .{});
    }
    ui.clipboard = .{ .get = clipGet, .set = clipSet };

    ui.tree.get(ui.tree.root).?.style = .{ .direction = .column, .padding = zigui.style.Edges.all(8), .gap = zigui.Length.px(6) };
    ui.tree.get(ui.tree.root).?.visual = .{ .background = zigui.Color.rgb(24, 25, 29) };
    var app: App = .{ .ui = &ui, .dock = undefined };

    const bar = try zigui.MenuBar.create(&ui, ui.tree.root, .{});
    defer bar.destroy();
    app.dock = try Dock.create(&ui, ui.tree.root, .{ .style = .{ .width = .fill, .height = .fill } });
    defer app.dock.destroy();
    const dock = app.dock;

    const files = try dock.addPanel("Files");
    const editor = try dock.addPanel("Editor");
    const output = try dock.addPanel("Output");
    const props = try dock.addPanel("Properties");
    app.view_panels = .{ files, editor, output, props };

    const tree = try ui.add(zigui.TreeView, files.content, .{ .style = .{ .grow = 1 } });
    const src = try tree.addItem(zigui.tree_view.no_item, "src");
    for ([_][]const u8{ "main.zig", "ui.zig", "layout.zig" }) |n| _ = try tree.addItem(src, n);
    const docs = try tree.addItem(zigui.tree_view.no_item, "docs");
    _ = try tree.addItem(docs, "index.html");
    tree.setExpanded(src, true);

    const code = try ui.add(zigui.CodeEditor, editor.content, .{ .style = .{ .grow = 1 }, .size = 13, .label = "Source" });
    try code.setLanguage(&zigui.syntax.zig);
    try code.loadText("const std = @import(\"std\");\n\npub fn main() void {\n    std.debug.print(\"hello\\n\", .{});\n}\n", false);

    const log = try ui.add(zigui.ScrollView, output.content, .{ .style = .{ .grow = 1 } });
    for ([_][]const u8{ "zig build", "compiled 12 files", "0 errors" }) |l| _ = try ui.add(zigui.Label, log.contentNode(), .{ .text = l });

    const form = try ui.tree.create(.{ .style = .{ .direction = .column, .gap = zigui.Length.px(6), .padding = zigui.style.Edges.all(8), .grow = 1 } });
    try ui.tree.appendChild(props.content, form);
    _ = try ui.add(zigui.Label, form, .{ .text = "Width" });
    _ = try ui.add(zigui.TextField, form, .{ .text = "120" });
    _ = try ui.add(zigui.Select, form, .{ .items = &.{ "start", "center", "end" } });

    try dock.dockTab(editor, null);
    try dock.dockTab(output, editor);
    try dock.dockSplit(files, editor, .left, 220);
    try dock.dockSplit(props, editor, .right, 260);

    try bar.addMenu("View", &.{
        .{ .label = "Files" },
        .{ .label = "Editor" },
        .{ .label = "Output" },
        .{ .label = "Properties" },
    }, zigui.menu.PickHook.bind(&app, App.onViewPick));

    const commands = try gpa.alloc(zigui.draw_list.Command, 32768);
    defer gpa.free(commands);
    const glyphs = try gpa.alloc(zigui.draw_list.Glyph, 65536);
    defer gpa.free(glyphs);
    var list = zigui.DrawList.init(commands, glyphs);
    var prewarmed_scale: f32 = 0;
    var presenter: WindowPresenter = .{ .window = &window };
    var renderer = try zigui.software_backend.SoftwareBackend.init(gpa, presenter.presenter());
    defer renderer.deinit();
    const backend = renderer.backend();

    var force = true;
    var last_frame_ms: u64 = 0; // expose events that follow our own present would loop forever (Wayland)
    const screenshot = init.environ_map.get("ZIGUI_SCREENSHOT");
    var script = std.mem.tokenizeScalar(u8, init.environ_map.get("ZIGUI_SCRIPT") orelse "", ';');
    var text_input_on = false;
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
                    ui.text.prewarmAscii(@intCast(f), 15 * scale);
                }
            }
            try ui.renderFrame(backend, &list, .{ .pixel_w = px.w, .pixel_h = px.h, .scale = scale, .clear = zigui.Color.black });
            force = false;
            last_frame_ms = sdl.ticks();
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
            return;
        }

        if (ui.textInputRect()) |r| {
            if (!text_input_on) sdl.startTextInput(&window);
            text_input_on = true;
            sdl.setTextInputArea(&window, r.x, r.y, r.w, r.h);
        } else if (text_input_on) {
            sdl.stopTextInput(&window);
            text_input_on = false;
        }

        sdl.setUiCursor(ui.cursor());
        const timeout: i32 = if (ui.nextWakeMs()) |ms| @intCast(ms) else -1;
        var ev = sdl.waitEvent(timeout);
        _ = ui.tick(sdl.ticks());
        while (ev) |e| : (ev = sdl.pollEvent()) {
            switch (e.data) {
                .quit, .close_requested => running = false,
                .resized => force = true,
                .expose => if (sdl.ticks() -% last_frame_ms > 100) {
                    force = true;
                },
                .mouse_move => |m| ui.pointerMove(m.x, m.y),
                .mouse_button => |m| ui.pointerButtonEx(m.x, m.y, @backingInt(m.button), m.down, m.clicks),
                .mouse_wheel => |m| ui.wheel(m.px, m.py, m.x, m.y),
                .pointer_left => ui.pointerLeft(),
                .focus_lost => ui.pointerCancel(),
                .text_input => |t| ui.textInput(t.bytes[0..t.len]),
                .text_editing => |t| ui.textEditing(t.bytes[0..t.len], t.cursor),
                .key => |k| {
                    const used = ui.keyHandled(k.key, k.mods, k.down, k.repeat);
                    if (k.down and k.key == .escape and !used) {
                        if (ui.focused() != null) ui.setFocus(null) else running = false;
                    }
                },
            }
        }
    }
}
