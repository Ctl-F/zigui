//! The IDE: a project's files, find in project, tabbed source editors, and the
//! Output panel, all in one dock. This is the workbench's sibling that edits a
//! folder of code instead of one UI document.
//!
//! Run:  zig build ide                     (opens the current folder)
//!       zig-out/bin/ide path/to/project
//!
//! Double-click a file in Files to open it; Ctrl+S saves; Ctrl+F finds in the
//! file, Ctrl+Shift+F finds in the project; F5 runs `zig build run`, Ctrl+B `zig build`, Ctrl+` opens the terminal, and Ctrl+Shift+T
//! `zig build test` (double-click an error in Output to jump to it).
//!
//! Env (headless checks, with SDL_VIDEODRIVER=dummy):
//!   ZIGUI_SCRIPT="open src/main.zig;search needle;sleep 300"   open PATH[:LINE] |
//!       search TEXT | sleep MS | wheel X Y DY | click X Y | type TEXT | key [mods+]NAME
//!   ZIGUI_SCREENSHOT=out.png

const std = @import("std");
const zigui = @import("zigui");
const sdl = @import("zigui_sdl");
const stb = @import("zigui_stb");

const Ui = zigui.Ui;
const ide = zigui.ide; // hello

const App = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    ui: *Ui,
    project: *ide.Project,
    dock: *zigui.Dock,
    docs: *ide.Documents = undefined,
    files: *ide.FilesPanel = undefined,
    search: *ide.SearchPanel = undefined,
    output: *ide.OutputPanel = undefined,
    status: *zigui.Label = undefined,
    lsp: *ide.lsp_assist.Assist = undefined,
    terminal: *ide.TerminalPanel = undefined,
    terminal_panel: *zigui.dock.Panel = undefined,
    files_panel: *zigui.dock.Panel = undefined,
    search_panel: *zigui.dock.Panel = undefined,

    fn openFile(self: *App, path: []const u8) void {
        self.openAt(path, 0, 0);
    }

    fn openAt(self: *App, path: []const u8, line: u32, col: u32) void {
        // Compiler output carries paths relative to where the build ran (the
        // project root) or absolute ones.
        
        std.debug.print("Path Requested: {s}@{},{}\n", .{ path, line, col });
        
        const rel = self.project.relPath(path) orelse path;
        _ = self.docs.open(rel, line, col) catch |err| {
            var buf: [200]u8 = undefined;
            self.status.setText(std.fmt.bufPrint(&buf, "could not open {s}: {s}", .{ rel, @errorName(err) }) catch "could not open file") catch {};
        };
    }

    fn runBuild(self: *App, step: []const u8) void {
        if (self.dock.panelNamed("Output")) |p| {
            if (p.state == .hidden) self.dock.showPanel(p) catch {};
        }
        _ = self.docs.saveAll();
        const argv: []const []const u8 = if (step.len == 0) &.{ "zig", "build" } else &.{ "zig", "build", step };
        self.output.run(self.io, argv, self.project.root, sdl.wake) catch |err| {
            std.log.err("could not start zig build: {s}", .{@errorName(err)});
        };
    }

    fn onCommand(self: *App, ev: *zigui.Event) void {
        const name = ev.text;
        if (std.mem.eql(u8, name, "ide.build")) self.runBuild("") else if (std.mem.eql(u8, name, "ide.run")) self.runBuild("run") else if (std.mem.eql(u8, name, "ide.test")) self.runBuild("test") else if (std.mem.eql(u8, name, "file.save")) {
            _ = self.docs.saveActive();
        } else if (std.mem.eql(u8, name, "view.terminal")) {
            self.dock.showPanel(self.terminal_panel) catch {};
            self.dock.activatePanel(self.terminal_panel);
            self.terminal.focus();
        } else if (std.mem.eql(u8, name, "editor.definition")) {
            if (self.docs.active()) |d| self.lsp.gotoDefinition(d.editor);
        } else if (std.mem.eql(u8, name, "project.search")) {
            self.dock.showPanel(self.search_panel) catch {};
            self.dock.activatePanel(self.search_panel);
            self.ui.setFocus(self.search.field.node);
        }
    }

    fn poll(self: *App) void {
        self.output.poll();
        self.search.poll();
        self.docs.poll();
        self.lsp.poll();
        self.terminal.poll();
        const doc_msg = self.docs.statusText();
        const msg = if (doc_msg.len > 0) doc_msg else self.lsp.statusText();
        if (!std.mem.eql(u8, msg, self.status.props.text.bytes)) self.status.setText(msg) catch {};
    }
};

fn runCommand(app: *App, ui: *Ui, cmd: []const u8) void {
    if (std.mem.startsWith(u8, cmd, "sleep ")) {
        const ms = std.fmt.parseInt(u64, cmd["sleep ".len..], 10) catch 0;
        var ts: std.os.linux.timespec = .{ .sec = @intCast(ms / 1000), .nsec = @intCast((ms % 1000) * 1_000_000) };
        _ = std.os.linux.nanosleep(&ts, null);
        app.poll();
        return;
    }
    const sp = std.mem.indexOfScalar(u8, cmd, ' ') orelse return;
    const verb = cmd[0..sp];
    const rest = cmd[sp + 1 ..];
    if (std.mem.eql(u8, verb, "open")) {
        var path = rest;
        var line: u32 = 0;
        if (std.mem.lastIndexOfScalar(u8, rest, ':')) |c| {
            if (std.fmt.parseInt(u32, rest[c + 1 ..], 10)) |l| {
                path = rest[0..c];
                line = l;
            } else |_| {}
        }
        app.openAt(path, line, 1);
    } else if (std.mem.eql(u8, verb, "search")) {
        app.dock.activatePanel(app.search_panel);
        app.search.setQuery(rest);
        app.search.start();
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
    } else if (std.mem.eql(u8, verb, "wheel")) {
        var nums = std.mem.tokenizeScalar(u8, rest, ' ');
        const x = std.fmt.parseFloat(f32, nums.next() orelse return) catch return;
        const y = std.fmt.parseFloat(f32, nums.next() orelse return) catch return;
        const dy = std.fmt.parseFloat(f32, nums.next() orelse return) catch return;
        ui.pointerMove(x, y);
        ui.wheel(x, y, 0, dy);
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
    const dir_arg: []const u8 = if (args.len > 1) args[1] else ".";

    var project = ide.Project.open(gpa, io, dir_arg) catch |err| {
        std.log.err("could not open project folder {s}: {s}", .{ dir_arg, @errorName(err) });
        return err;
    };
    defer project.close();

    try sdl.init();
    defer sdl.quit();
    var title_buf: [256]u8 = undefined;
    const title: [:0]const u8 = std.fmt.bufPrintSentinel(&title_buf, "zigui ide - {s}", .{project.name}, 0) catch "zigui ide";
    var window = sdl.Window.create(title, 1500, 860) catch |err| {
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

    var app: App = .{ .gpa = gpa, .io = io, .ui = &ui, .project = &project, .dock = undefined };

    ui.tree.get(ui.tree.root).?.style = .{ .direction = .column };
    ui.tree.get(ui.tree.root).?.visual = .{ .background = zigui.Color.rgb(24, 25, 29) };
    const dock = try zigui.Dock.create(&ui, ui.tree.root, .{ .style = .{ .grow = 1 } });
    app.dock = dock;
    app.status = try ui.add(zigui.Label, ui.tree.root, .{ .style = .{ .padding = zigui.style.Edges.xy(8, 3), .shrink = 0 } });

    // Center: a welcome tab that documents open beside.
    const welcome = try dock.addPanel("Welcome");
    ui.tree.get(welcome.content).?.style = .{ .direction = .column, .grow = 1, .padding = zigui.style.Edges.all(16), .gap = zigui.Length.px(8) };
    _ = try ui.add(zigui.Label, welcome.content, .{ .text = project.name, .size = 20 });
    _ = try ui.add(zigui.Label, welcome.content, .{ .text = "Double-click a file to open it. Ctrl+S saves, Ctrl+Shift+F searches the project, F5 runs, Ctrl+B builds." });
    try dock.dockTab(welcome, null);

    // Suggestions that work with no language server: words in the file, plus
    // Zig names and the standard library read from source (std.zig.Ast).
    const std_dir = ide.zig_complete.locateStdDir(gpa, io);
    defer if (std_dir) |d| gpa.free(d);
    if (std_dir == null) std.log.warn("could not run `zig env`; standard library completion is off", .{});
    const zig_completer = try ide.zig_complete.ZigCompleter.create(gpa, io, std_dir);
    defer zig_completer.destroy();
    const completion = try zigui.completion.Completion.create(&ui);
    defer completion.destroy();
    try completion.addProvider(zig_completer.provider());
    const hover = try zigui.hover.Hover.create(&ui);
    defer hover.destroy();
    try hover.addProvider(zig_completer.hoverProvider());
    const signature = try zigui.hover.SignatureHelp.create(&ui);
    defer signature.destroy();
    try signature.addProvider(zig_completer.signatureProvider());
    // A language server, if one is installed (ZIGUI_ZLS=/path/to/zls, else `zls` on PATH).
    // It adds diagnostics, completions, hover, parameter hints and go to definition
    // to the offline ones; without it everything above still works.
    const lsp = try ide.lsp_assist.Assist.create(&ui, io, project.root);
    defer lsp.destroy();
    app.lsp = lsp;
    lsp.wake = sdl.wake;
    lsp.completion = completion;
    lsp.hover = hover;
    lsp.signature = signature;
    lsp.on_open = ide.output_panel.OpenHook.bind(&app, App.openAt);
    try lsp.addServer(&zigui.syntax.zig, "zig", &.{init.environ_map.get("ZIGUI_ZLS") orelse "zls"});
    try completion.addProvider(lsp.completionProvider());
    try hover.addProvider(lsp.hoverProvider());
    try signature.addProvider(lsp.signatureProvider());
    app.docs = try ide.Documents.create(&ui, dock, &project, io, .{ .anchor = welcome });
    defer app.docs.destroy();
    app.docs.enableCompletion(completion, zig_completer);
    app.docs.enableHints(hover, signature);

    app.docs.enableLsp(lsp);

    const files_panel = try dock.addPanel("Files");
    app.files_panel = files_panel;
    app.files = try ide.FilesPanel.create(&ui, files_panel.content, &project, .{ .on_open = ide.files_panel.OpenFileHook.bind(&app, App.openFile) });
    defer app.files.destroy();
    try dock.dockRoot(files_panel, .left, 280);

    const search_panel = try dock.addPanel("Search");
    app.search_panel = search_panel;
    app.search = try ide.SearchPanel.create(&ui, search_panel.content, &project, .{ .on_open = ide.output_panel.OpenHook.bind(&app, App.openAt), .wake = sdl.wake });
    defer app.search.destroy();
    try dock.dockTab(search_panel, files_panel);
    dock.activatePanel(files_panel);

    const output_panel = try dock.addPanel("Output");
    app.output = try ide.OutputPanel.create(&ui, output_panel.content, .{ .style = .{ .grow = 1 }, .on_open = ide.output_panel.OpenHook.bind(&app, App.openAt) });
    defer app.output.destroy();
    try dock.dockRoot(output_panel, .bottom, 220);

    // The terminal shares the bottom group with Output.
    const terminal_panel = try dock.addPanel("Terminal");
    app.terminal_panel = terminal_panel;
    app.terminal = try ide.TerminalPanel.create(&ui, terminal_panel.content, .{ .cwd = project.root, .environ = init.environ_map, .wake = sdl.wake });
    defer app.terminal.destroy();
    try dock.dockTab(terminal_panel, output_panel);
    dock.activatePanel(output_panel);

    inline for (.{
        .{ "ide.build", "Build" },
        .{ "ide.run", "Run" },
        .{ "ide.test", "Run tests" },
        .{ "file.save", "Save" },
        .{ "project.search", "Find in project" },
        .{ "editor.definition", "Go to definition" },
        .{ "view.terminal", "Terminal" },
    }) |c| _ = try ui.registerCommand(c[0], .{ .title = c[1], .run = zigui.event.Callback.bind(&app, App.onCommand) });
    try ui.bindShortcut("f5", "ide.run", .app, null);
    try ui.bindShortcut("mod+b", "ide.build", .app, null);
    try ui.bindShortcut("mod+shift+t", "ide.test", .app, null);
    try ui.bindShortcut("mod+s", "file.save", .app, null);
    try ui.bindShortcut("mod+shift+f", "project.search", .app, null);
    try ui.bindShortcut("f12", "editor.definition", .app, null);
    try ui.bindShortcut("mod+`", "view.terminal", .app, null);

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
    var last_frame_ms: u64 = 0;
    const screenshot = init.environ_map.get("ZIGUI_SCREENSHOT");
    var script = std.mem.tokenizeScalar(u8, init.environ_map.get("ZIGUI_SCRIPT") orelse "", ';');
    var text_input_on = false;
    var running = true;
    while (running) {
        _ = ui.tick(sdl.ticks());
        app.poll();
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
