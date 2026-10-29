//! The workbench: a code editor on a UI document's ZON text beside the visual
//! builder, kept in step both ways. This is the shape of the IDE the builder is
//! meant to live in.
//!
//! Run:  zig build workbench            (edits ./ui.zon)
//!       zig-out/bin/workbench path/to/ui.zon
//!
//! Edit the text and the builder follows (when it parses; otherwise the status
//! line shows the error and the last good document stays); edit visually and the
//! text updates. Ctrl+S saves. The builder's own undo history is replaced when
//! the text is edited, since a text edit is a different kind of change.
//!
//! Env (headless checks, with SDL_VIDEODRIVER=dummy):
//!   ZIGUI_SCRIPT="add button;select 3;type x"   add NAME | select UID | tab NAME |
//!       click X Y | type TEXT | key [mods+]NAME
//!   ZIGUI_SCREENSHOT=out.png

const std = @import("std");
const zigui = @import("zigui");
const sdl = @import("zigui_sdl");
const stb = @import("zigui_stb");

const Ui = zigui.Ui;
const Builder = zigui.builder.Builder;

const App = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    ui: *Ui,
    builder: *Builder,
    output: *zigui.ide.OutputPanel = undefined,
    editor: *zigui.CodeEditor,
    status: *zigui.Label,
    dock: *zigui.Dock = undefined,
    /// Set while one side is writing the other, so the echo is ignored.
    syncing: bool = false,
    dirty: bool = false,

    /// Run `zig build` (or another step) and show its output in the Output panel.
    fn runBuild(self: *App, step: []const u8) void {
        if (self.dock.panelNamed("Output")) |p| {
            if (p.state == .hidden) self.dock.showPanel(p) catch {};
        }
        const argv: []const []const u8 = if (step.len == 0) &.{ "zig", "build" } else &.{ "zig", "build", step };
        self.output.run(self.io, argv, null, sdl.wake) catch |err| {
            std.log.err("could not start zig build: {s}", .{@errorName(err)});
        };
    }

    fn onBuildCommand(self: *App, ev: *zigui.Event) void {
        if (std.mem.eql(u8, ev.text, "ide.build")) self.runBuild("") else if (std.mem.eql(u8, ev.text, "ide.test")) self.runBuild("test");
    }

    /// A double-clicked diagnostic: show the file in the document editor.
    fn openAt(self: *App, path: []const u8, line: u32, col: u32) void {
        _ = col;
        std.log.info("open {s}:{d}", .{ path, line });
        self.status.setText(path) catch {};
    }

    /// The builder changed the document: show its ZON in the editor.
    fn onBuilderChange(self: *App, _: *zigui.Event) void {
        if (self.syncing) return;
        const text = self.builder.toZon(self.gpa) catch return;
        self.syncing = true;
        defer self.syncing = false;
        self.editor.loadText(text, true) catch {
            self.gpa.free(text);
            return;
        };
        self.dirty = true;
        self.setStatus("");
    }

    /// The text changed: if it parses, the builder takes it.
    fn onTextChange(self: *App, _: *zigui.Event) void {
        if (self.syncing) return;
        const text = self.editor.textAlloc(self.gpa) catch return;
        defer self.gpa.free(text);
        var diag: zigui.zon.Diag = .{};
        var problem: zigui.uidoc.Problem = .{ .message = "" };
        const doc = zigui.uidoc.parseDoc(self.gpa, text, &diag, &problem) catch |err| {
            var buf: [200]u8 = undefined;
            const msg = if (err == error.Syntax)
                std.fmt.bufPrint(&buf, "line {d}:{d}: {s}", .{ diag.line, diag.col, diag.message }) catch "syntax error"
            else
                std.fmt.bufPrint(&buf, "{s} {s}", .{ problem.message, problem.detail }) catch "invalid document";
            self.setStatus(msg);
            return;
        };
        self.syncing = true;
        defer self.syncing = false;
        self.builder.loadDocument(doc) catch return;
        self.dirty = true;
        self.setStatus("");
    }

    fn setStatus(self: *App, msg: []const u8) void {
        self.status.props.color = if (msg.len > 0) zigui.Color.rgb(224, 96, 96) else zigui.Color.transparent;
        self.status.setText(msg) catch {};
    }

    fn save(ctx: ?*anyopaque, text: []const u8) void {
        const self: *App = @ptrCast(@alignCast(ctx.?));
        std.Io.Dir.cwd().writeFile(self.io, .{ .sub_path = self.path, .data = text }) catch |err| {
            std.log.err("could not save {s}: {s}", .{ self.path, @errorName(err) });
            return;
        };
        self.dirty = false;
        std.log.info("saved {s}", .{self.path});
    }
};

fn runCommand(app: *App, ui: *Ui, cmd: []const u8) void {
    if (std.mem.startsWith(u8, cmd, "sleep ")) {
        const ms = std.fmt.parseInt(u64, cmd["sleep ".len..], 10) catch 0;
        var ts: std.os.linux.timespec = .{ .sec = @intCast(ms / 1000), .nsec = @intCast((ms % 1000) * 1_000_000) };
        _ = std.os.linux.nanosleep(&ts, null);
        return;
    }
    const b = app.builder;
    const sp = std.mem.indexOfScalar(u8, cmd, ' ') orelse return;
    const verb = cmd[0..sp];
    const rest = cmd[sp + 1 ..];
    if (std.mem.eql(u8, verb, "add")) {
        b.addWidget(rest);
    } else if (std.mem.eql(u8, verb, "tab")) {
        if (std.meta.stringToEnum(zigui.builder.Tab, rest)) |t| b.setTab(t);
    } else if (std.mem.eql(u8, verb, "select")) {
        b.select(std.fmt.parseInt(u32, rest, 10) catch return);
    } else if (std.mem.eql(u8, verb, "focus")) {
        ui.setFocus(app.editor.node);
    } else if (std.mem.eql(u8, verb, "type")) {
        ui.textInput(rest);
    } else if (std.mem.eql(u8, verb, "key")) {
        var mods: zigui.keys.Mods = .{};
        var parts = std.mem.splitScalar(u8, rest, '+');
        var last: []const u8 = "";
        while (parts.next()) |p| {
            if (std.mem.eql(u8, p, "ctrl")) {
                mods.ctrl = true;
            } else if (std.mem.eql(u8, p, "shift")) {
                mods.shift = true;
            } else last = p;
        }
        const k = zigui.keys.parseKey(last) orelse .unknown;
        ui.key(k, mods, true, false);
        ui.key(k, mods, false, false);
    } else if (std.mem.eql(u8, verb, "click") or std.mem.eql(u8, verb, "move")) {
        var nums = std.mem.tokenizeScalar(u8, rest, ' ');
        const x = std.fmt.parseFloat(f32, nums.next() orelse return) catch return;
        const y = std.fmt.parseFloat(f32, nums.next() orelse return) catch return;
        ui.pointerMove(x, y);
        if (verb[0] == 'c') {
            ui.pointerButtonEx(x, y, 1, true, 1);
            ui.pointerButtonEx(x, y, 1, false, 1);
        }
    }
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
    const path: []const u8 = if (args.len > 1) args[1] else "ui.zon";

    try sdl.init();
    defer sdl.quit();
    var window = sdl.Window.create("zigui workbench", 1500, 860) catch |err| {
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

    // The document: from the file if it exists, otherwise empty.
    const source: ?[]u8 = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(4 * 1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    defer if (source) |s| gpa.free(s);
    var doc: zigui.uidoc.Doc = if (source) |s| blk: {
        var diag: zigui.zon.Diag = .{};
        var problem: zigui.uidoc.Problem = .{ .message = "" };
        break :blk zigui.uidoc.parseDoc(gpa, s, &diag, &problem) catch |err| {
            if (err == error.Syntax) {
                std.log.err("{s}:{d}:{d}: {s}", .{ path, diag.line, diag.col, diag.message });
            } else std.log.err("{s}: {s} {s}", .{ path, problem.message, problem.detail });
            return err;
        };
    } else try zigui.uidoc.Doc.init(gpa);

    var app: App = .{ .gpa = gpa, .io = io, .path = path, .ui = &ui, .builder = undefined, .editor = undefined, .status = undefined };

    // Layout: one dock holds every region (the document text and the builder's
    // Toolbox, Outline, Preview and Inspector), so any of them can be dragged
    // into another group, split off, floated, or closed (View menu to bring back).
    ui.tree.get(ui.tree.root).?.style = .{ .direction = .column };
    ui.tree.get(ui.tree.root).?.visual = .{ .background = zigui.Color.rgb(24, 25, 29) };
    const dock = try zigui.Dock.create(&ui, ui.tree.root, .{ .style = .{ .grow = 1 } });
    const text_panel = try dock.addPanel("Document");
    const left = text_panel.content;
    ui.tree.get(left).?.style = .{ .direction = .column, .grow = 1, .padding = zigui.style.Edges.all(8), .gap = zigui.Length.px(6) };
    _ = try ui.add(zigui.Label, left, .{ .text = path, .size = 15 });
    app.editor = try ui.add(zigui.CodeEditor, left, .{ .style = .{ .grow = 1 }, .label = "UI document text", .size = 13 });
    try app.editor.setLanguage(&zigui.syntax.zig);
    app.status = try ui.add(zigui.Label, left, .{});

    const initial_text = try doc.toZon(gpa);
    try app.editor.loadText(initial_text, true);
    app.editor.props.on_change = zigui.event.Callback.bind(&app, App.onTextChange);

    app.builder = Builder.create(&ui, ui.tree.root, doc, .{
        .save = .{ .ctx = &app, .call = App.save },
        .on_change = zigui.event.Callback.bind(&app, App.onBuilderChange),
        .dock = dock,
    }) catch |err| {
        doc.deinit();
        return err;
    };
    defer app.builder.destroy();
    try app.builder.arrange();
    try dock.dockRoot(text_panel, .left, 460);

    // The Output panel and the Build menu.
    app.dock = dock;
    const output_panel = try dock.addPanel("Output");
    app.output = try zigui.ide.OutputPanel.create(&ui, output_panel.content, .{ .style = .{ .grow = 1 }, .on_open = zigui.ide.output_panel.OpenHook.bind(&app, App.openAt) });
    defer app.output.destroy();
    try dock.dockRoot(output_panel, .bottom, 200);
    _ = try ui.registerCommand("ide.build", .{ .title = "Build", .run = zigui.event.Callback.bind(&app, App.onBuildCommand) });
    _ = try ui.registerCommand("ide.test", .{ .title = "Run tests", .run = zigui.event.Callback.bind(&app, App.onBuildCommand) });
    try ui.bindShortcut("f5", "ide.build", .app, null);
    try ui.bindShortcut("mod+shift+t", "ide.test", .app, null);
    if (app.builder.menu_bar) |mb| try mb.addMenu("Build", &.{
        .{ .label = "Build", .command = "ide.build" },
        .{ .label = "Run tests", .command = "ide.test" },
    }, null);

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
        app.output.poll();
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
