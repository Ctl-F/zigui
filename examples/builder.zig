//! The UI builder: edit a ZON UI document visually.
//!
//! Run:  zig build builder            (edits ./ui.zon)
//!       zig-out/bin/builder path/to/ui.zon
//!
//! The file is created if it does not exist. Ctrl+S (or the Save button) writes it.
//! Ctrl+Z / Ctrl+Y undo and redo. Add widgets from the palette, select them in the
//! outline, and edit props, style, and events in the inspector. Load the saved file
//! in your own program with `zigui.uidoc.parseDoc` and `zigui.uiload.instantiate`.
//!
//! Env (for headless checks, with SDL_VIDEODRIVER=dummy):
//!   ZIGUI_SCRIPT="add button;tab style;click X Y;type TEXT;key ctrl+z"
//!       add NAME | tab NAME | select UID | click X Y | type TEXT | key [mods+]NAME
//!   ZIGUI_SCREENSHOT=out.png   write a PNG of the final frame and exit

const std = @import("std");
const zigui = @import("zigui");
const sdl = @import("zigui_sdl");
const stb = @import("zigui_stb");

const Ui = zigui.Ui;
const Builder = zigui.builder.Builder;

const Save = struct {
    io: std.Io,
    path: []const u8,

    fn write(ctx: ?*anyopaque, text: []const u8) void {
        const self: *Save = @ptrCast(@alignCast(ctx.?));
        std.Io.Dir.cwd().writeFile(self.io, .{ .sub_path = self.path, .data = text }) catch |err| {
            std.log.err("could not save {s}: {s}", .{ self.path, @errorName(err) });
            return;
        };
        std.log.info("saved {s}", .{self.path});
    }
};

/// Run one scripted command. The main loop draws a frame between commands so
/// clicks see the layout that earlier commands produced.
fn runCommand(b: *Builder, ui: *Ui, cmd: []const u8) void {
    {
        const sp = std.mem.indexOfScalar(u8, cmd, ' ') orelse return;
        const verb = cmd[0..sp];
        const rest = cmd[sp + 1 ..];
        if (std.mem.eql(u8, verb, "add")) {
            b.addWidget(rest);
        } else if (std.mem.eql(u8, verb, "tab")) {
            if (std.meta.stringToEnum(zigui.builder.Tab, rest)) |t| b.setTab(t);
        } else if (std.mem.eql(u8, verb, "select")) {
            b.select(std.fmt.parseInt(u32, rest, 10) catch return);
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
        } else if (std.mem.eql(u8, verb, "move")) {
            var nums = std.mem.tokenizeScalar(u8, rest, ' ');
            const x = std.fmt.parseFloat(f32, nums.next() orelse return) catch return;
            const y = std.fmt.parseFloat(f32, nums.next() orelse return) catch return;
            ui.pointerMove(x, y);
        } else if (std.mem.eql(u8, verb, "click")) {
            var nums = std.mem.tokenizeScalar(u8, rest, ' ');
            const x = std.fmt.parseFloat(f32, nums.next() orelse return) catch return;
            const y = std.fmt.parseFloat(f32, nums.next() orelse return) catch return;
            ui.pointerMove(x, y);
            ui.pointerButtonEx(x, y, 1, true, 1);
            ui.pointerButtonEx(x, y, 1, false, 1);
        }
    }
}

/// Shows software frames in the SDL window.
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
    var window = sdl.Window.create("zigui builder", 1280, 760) catch |err| {
        std.log.err("could not create window: {s} ({s})", .{ @errorName(err), sdl.lastError() });
        return err;
    };
    defer window.destroy();

    var ui = try Ui.init(gpa);
    ui.clock = sdl.ticksNs;
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

    // Load the document if the file exists, otherwise start empty.
    var doc: zigui.uidoc.Doc = blk: {
        const source = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(4 * 1024 * 1024)) catch |err| switch (err) {
            error.FileNotFound => break :blk try zigui.uidoc.Doc.init(gpa),
            else => return err,
        };
        defer gpa.free(source);
        var diag: zigui.zon.Diag = .{};
        var problem: zigui.uidoc.Problem = .{ .message = "" };
        break :blk zigui.uidoc.parseDoc(gpa, source, &diag, &problem) catch |err| {
            if (err == error.Syntax) {
                std.log.err("{s}:{d}:{d}: {s}", .{ path, diag.line, diag.col, diag.message });
            } else std.log.err("{s}: {s} {s}", .{ path, problem.message, problem.detail });
            return err;
        };
    };
    var saver: Save = .{ .io = io, .path = path };
    const builder = Builder.create(&ui, ui.tree.root, doc, .{ .save = .{ .ctx = &saver, .call = Save.write } }) catch |err| {
        doc.deinit();
        return err;
    };
    defer builder.destroy();
    ui.tree.get(ui.tree.root).?.style = .{ .direction = .column };
    ui.tree.get(ui.tree.root).?.visual = .{ .background = zigui.Color.rgb(24, 25, 29) };

    const commands = try gpa.alloc(zigui.draw_list.Command, 32768);
    defer gpa.free(commands);
    const glyphs = try gpa.alloc(zigui.draw_list.Glyph, 65536);
    defer gpa.free(glyphs);
    var list = zigui.DrawList.init(commands, glyphs);
    var prewarmed_scale: f32 = 0;
    var presenter: WindowPresenter = .{ .window = &window };
    const no_present = init.environ_map.get("ZIGUI_NOPRESENT") != null; // measure rendering without the window's vsync wait
    var renderer = try zigui.software_backend.SoftwareBackend.init(gpa, if (no_present) null else presenter.presenter());
    defer renderer.deinit();
    const backend = renderer.backend();

    var force = true;
    var last_frame_ms: u64 = 0; // expose events that follow our own present would loop forever (Wayland)
    const screenshot = init.environ_map.get("ZIGUI_SCREENSHOT");
    var script = std.mem.tokenizeScalar(u8, init.environ_map.get("ZIGUI_SCRIPT") orelse "", ';');
    var text_input_on = false;
    var running = true;
    const trace_events = init.environ_map.get("ZIGUI_TRACE") != null;
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
            defer if (init.environ_map.get("ZIGUI_TRACE") != null) {
                std.log.info("frame px {d}x{d} scale {d:.3}", .{ px.w, px.h, scale });
                if (ui.last_damage) |d| std.log.info("damage {d:.0}x{d:.0} at {d:.0},{d:.0}; cmds {d}", .{ d.w, d.h, d.x, d.y, list.items().len }) else std.log.info("damage full; cmds {d}", .{list.items().len});
            };
            try ui.renderFrame(backend, &list, .{ .pixel_w = px.w, .pixel_h = px.h, .scale = scale, .clear = zigui.Color.black });
            force = false;
            last_frame_ms = sdl.ticks();
        }
        ui.endFrame();

        if (screenshot != null) {
            if (script.next()) |cmd| {
                runCommand(builder, &ui, cmd);
                continue;
            }
            const img = try backend.readback(gpa);
            defer img.deinit(gpa);
            const png = try zigui.png.encodeRgba(gpa, img.rgba, img.width, img.height);
            defer gpa.free(png);
            try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = screenshot.?, .data = png });
            {
                var u: u64 = 0;
                var l: u64 = 0;
                var bl: u64 = 0;
                var sb: u64 = 0;
                var h: u64 = 0;
                var worst: u64 = 0;
                const n = ui.stats.len();
                for (0..n) |i| {
                    const f = ui.stats.recent(i).?;
                    u += f.update_ns;
                    l += f.layout_ns;
                    bl += f.build_ns;
                    sb += f.submit_ns;
                    h += f.handler_ns;
                    worst = @max(worst, f.total_ns);
                }
                const d = @as(f64, @floatFromInt(@max(n, 1))) * 1e6;
                std.log.info("per frame (ms): update {d:.3} layout {d:.3} build {d:.3} submit {d:.3} handlers {d:.3}; worst total {d:.2}", .{ @as(f64, @floatFromInt(u)) / d, @as(f64, @floatFromInt(l)) / d, @as(f64, @floatFromInt(bl)) / d, @as(f64, @floatFromInt(sb)) / d, @as(f64, @floatFromInt(h)) / d, @as(f64, @floatFromInt(worst)) / 1e6 });
            }
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
            if (trace_events) std.log.info("event {s} {any}", .{ @tagName(e.data), e.data });
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
