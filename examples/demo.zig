//! Demo: an IDE-style layout with working buttons. Layout pass, hit-testing,
//! events, widget state blocks, software renderer, and SDL3 shim together.
//!
//! Run:  zig build demo
//!
//!   Header buttons: "+ Card" adds a card, "- Card" removes one, "Sidebar"
//!   toggles the sidebar. Sidebar rows are flat buttons; click one to select it.
//!   Text uses system fonts (stb_truetype); override with ZIGUI_FONT / ZIGUI_MONO_FONT.
//!
//! Env (for headless checks, with SDL_VIDEODRIVER=dummy):
//!   ZIGUI_SCRIPT="move 100 20;click 60 20"   feed pointer input after the first frame
//!   ZIGUI_SCREENSHOT=out.png                 write a PNG of the final frame and exit

const std = @import("std");
const zigui = @import("zigui");
const sdl = @import("zigui_sdl");
const stb = @import("zigui_stb");

const Color = zigui.Color;
const Length = zigui.Length;
const Edges = zigui.style.Edges;
const Handle = zigui.Handle;
const Ui = zigui.Ui;
const Button = zigui.Button;

fn rgb(hex: u24) Color {
    return Color.rgb(@truncate(hex >> 16), @truncate(hex >> 8), @truncate(hex));
}

const background = rgb(0x1e1f22);
const card_palette = [_]u24{ 0x2f6f4f, 0x7a4b2a, 0x5a3f8a, 0x2a5f7a, 0x8a3f5a, 0x6a7a2a };
const max_cards = 8;

const SidebarItem = struct { app: *App, index: usize };

const App = struct {
    ui: *Ui,
    body: Handle = Handle.invalid,
    sidebar: Handle = Handle.invalid,
    cards: Handle = Handle.invalid,
    card_count: usize = 0,
    sidebar_visible: bool = true,
    selected: usize = 2,
    items: [9]*Button = undefined,
    item_ctx: [9]SidebarItem = undefined,
    clicks: u32 = 0,
    status: ?*zigui.Label = null,
    card_serial: usize = 0,

    fn addNode(self: *App, parent: Handle, style: zigui.Style, visual: zigui.tree.Visual) !Handle {
        const h = try self.ui.tree.create(.{ .style = style, .visual = visual });
        try self.ui.tree.appendChild(parent, h);
        return h;
    }
};

fn app(user: ?*anyopaque) *App {
    return @ptrCast(@alignCast(user.?));
}

fn addCard(a: *App) !void {
    const col = card_palette[a.card_serial % card_palette.len];
    const card = try a.addNode(a.cards, .{ .grow = 1, .padding = Edges.all(14) }, .{ .background = rgb(col), .radius = 12 });
    a.card_serial += 1;
    a.card_count += 1;
    var buf: [32]u8 = undefined;
    const name = std.fmt.bufPrint(&buf, "Card {d}", .{a.card_serial}) catch "Card";
    const l = try a.ui.createLabel(card, .{}, name);
    l.props.size = 18;
    l.props.color = Color.white;
}

fn onAddCard(_: *zigui.Event, user: ?*anyopaque) callconv(.c) void {
    const a = app(user);
    a.clicks += 1;
    if (a.card_count >= max_cards) return;
    addCard(a) catch {};
}

fn onRemoveCard(_: *zigui.Event, user: ?*anyopaque) callconv(.c) void {
    const a = app(user);
    a.clicks += 1;
    if (a.card_count == 0) return;
    const last = a.ui.tree.get(a.cards).?.last_child;
    _ = a.ui.tree.destroySubtree(last); // deferred until this click finishes dispatching
    a.card_count -= 1;
}

fn onToggleSidebar(_: *zigui.Event, user: ?*anyopaque) callconv(.c) void {
    const a = app(user);
    a.clicks += 1;
    a.sidebar_visible = !a.sidebar_visible;
    a.ui.setHidden(a.sidebar, !a.sidebar_visible);
}

fn onSelectItem(_: *zigui.Event, user: ?*anyopaque) callconv(.c) void {
    const ctx: *SidebarItem = @ptrCast(@alignCast(user.?));
    const a = ctx.app;
    a.clicks += 1;
    a.ui.setButtonVariant(a.items[a.selected], .flat);
    a.selected = ctx.index;
    a.ui.setButtonVariant(a.items[a.selected], .primary);
}

fn buildUi(a: *App) !void {
    const ui = a.ui;
    const tree = &ui.tree;
    tree.get(tree.root).?.style = .{ .direction = .column };
    tree.get(tree.root).?.visual = .{ .background = background };

    // Header.
    const header = try a.addNode(tree.root, .{
        .direction = .row,
        .height = Length.px(44),
        .padding = Edges.xy(12, 8),
        .gap = Length.px(8),
        .shrink = 0,
    }, .{ .background = rgb(0x2b2d30) });
    const specs = [_]struct { text: []const u8, variant: zigui.button.Variant, cb: zigui.event.Handler }{
        .{ .text = "+ Card", .variant = .primary, .cb = onAddCard },
        .{ .text = "- Card", .variant = .normal, .cb = onRemoveCard },
        .{ .text = "Toggle sidebar", .variant = .normal, .cb = onToggleSidebar },
    };
    for (specs) |spec| {
        const b = try ui.createButton(header, .{ .padding = Edges.xy(14, 0), .shrink = 0 });
        try ui.setButtonText(b, spec.text);
        ui.setButtonVariant(b, spec.variant);
        b.props.on_click = spec.cb;
        b.props.on_click_user = a;
    }
    _ = try a.addNode(header, .{ .grow = 1 }, .{});
    const disabled = try ui.createButton(header, .{ .padding = Edges.xy(14, 0), .shrink = 0 });
    try ui.setButtonText(disabled, "Disabled");
    ui.setButtonEnabled(disabled, false);

    // Body.
    a.body = try a.addNode(tree.root, .{
        .direction = .row,
        .grow = 1,
        .padding = Edges.all(8),
        .gap = Length.px(8),
    }, .{});
    a.sidebar = try a.addNode(a.body, .{
        .direction = .column,
        .width = Length.pct(20),
        .min_width = Length.px(150),
        .max_width = Length.px(360),
        .shrink = 0,
        .padding = Edges.all(8),
        .gap = Length.px(4),
    }, .{ .background = rgb(0x2b2d30), .radius = 8 });
    const names = [_][]const u8{ "root.zig", "layout.zig", "paint.zig", "event.zig", "input.zig", "ui.zig", "button.zig", "theme.zig", "software.zig" };
    for (0..a.items.len) |i| {
        const indent: f32 = @floatFromInt((i % 3) * 10);
        const b = try ui.createButton(a.sidebar, .{
            .height = Length.px(28),
            .shrink = 0,
            .padding = Edges.xy(10, 0),
            .margin = .{ .left = Length.px(indent) },
        });
        try ui.setButtonText(b, names[i]);
        b.props.text_align = .start;
        ui.setButtonVariant(b, if (i == a.selected) .primary else .flat);
        a.items[i] = b;
        a.item_ctx[i] = .{ .app = a, .index = i };
        b.props.on_click = onSelectItem;
        b.props.on_click_user = &a.item_ctx[i];
    }

    const content = try a.addNode(a.body, .{ .direction = .column, .grow = 1, .gap = Length.px(8) }, .{});
    a.cards = try a.addNode(content, .{ .direction = .row, .height = Length.px(120), .gap = Length.px(8), .shrink = 0 }, .{});
    for (0..4) |_| try addCard(a);
    const editor = try a.addNode(content, .{ .grow = 1, .padding = Edges.all(12), .direction = .column, .gap = Length.px(6) }, .{
        .background = rgb(0x26282c),
        .border_color = rgb(0x3d3f45),
        .border_width = 1,
        .radius = 8,
    });
    tree.get(editor).?.flags.clip_children = true;
    const code = [_]struct { text: []const u8, color: u24 }{
        .{ .text = "// zigui: retained-mode UI for Zig", .color = 0x6a9955 },
        .{ .text = "const std = @import(\"std\");", .color = 0xd4d4d4 },
        .{ .text = "const zigui = @import(\"zigui\");", .color = 0xd4d4d4 },
        .{ .text = "", .color = 0xd4d4d4 },
        .{ .text = "pub fn main(init: std.process.Init) !void {", .color = 0x569cd6 },
        .{ .text = "    var ui = try zigui.Ui.init(init.gpa);", .color = 0xd4d4d4 },
        .{ .text = "    defer ui.deinit();", .color = 0xd4d4d4 },
        .{ .text = "", .color = 0xd4d4d4 },
        .{ .text = "    const btn = try ui.createButton(root, .{});", .color = 0xd4d4d4 },
        .{ .text = "    try ui.setButtonText(btn, \"Hello, text!\");", .color = 0xce9178 },
        .{ .text = "    btn.props.on_click = onClick;", .color = 0xd4d4d4 },
        .{ .text = "}", .color = 0x569cd6 },
    };
    for (code) |line| {
        const l = try ui.createLabel(editor, .{ .height = Length.px(18), .shrink = 0 }, line.text);
        l.props.font = .mono;
        l.props.size = 13;
        l.props.color = rgb(line.color);
    }

    // Status bar.
    const status_bar = try a.addNode(tree.root, .{ .height = Length.px(24), .shrink = 0, .padding = Edges.xy(10, 0) }, .{ .background = rgb(0x3574f0) });
    const status = try ui.createLabel(status_bar, .{ .grow = 1 }, "Ready");
    status.props.size = 12;
    status.props.color = Color.white;
    a.status = status;
}

const Script = struct {
    /// Apply "move X Y;click X Y;..." to the UI.
    fn run(ui: *Ui, text: []const u8) void {
        var cmds = std.mem.tokenizeScalar(u8, text, ';');
        while (cmds.next()) |cmd| {
            var parts = std.mem.tokenizeScalar(u8, cmd, ' ');
            const verb = parts.next() orelse continue;
            const x = std.fmt.parseFloat(f32, parts.next() orelse continue) catch continue;
            const y = std.fmt.parseFloat(f32, parts.next() orelse continue) catch continue;
            if (std.mem.eql(u8, verb, "move")) {
                ui.pointerMove(x, y);
            } else if (std.mem.eql(u8, verb, "click")) {
                ui.pointerMove(x, y);
                ui.pointerButton(x, y, 1, true);
                ui.pointerButton(x, y, 1, false);
            } else if (std.mem.eql(u8, verb, "press")) {
                ui.pointerMove(x, y);
                ui.pointerButton(x, y, 1, true);
            }
        }
    }
};

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    try sdl.init();
    defer sdl.quit();

    var window = sdl.Window.create("zigui demo", 960, 600) catch |err| {
        std.log.err("could not create window: {s} ({s})", .{ @errorName(err), sdl.lastError() });
        return err;
    };
    defer window.destroy();

    var ui = try Ui.init(gpa);
    defer ui.deinit();

    // Fonts: the file bytes and StbFont structs must outlive the Ui.
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
    var state: App = .{ .ui = &ui };
    try buildUi(&state);

    const commands = try gpa.alloc(zigui.draw_list.Command, 4096);
    defer gpa.free(commands);
    const glyphs = try gpa.alloc(zigui.draw_list.Glyph, 16384);
    defer gpa.free(glyphs);
    var list = zigui.DrawList.init(commands, glyphs);
    var prewarmed_scale: f32 = 0;

    var fb = try zigui.software.Framebuffer.init(gpa, 1, 1);
    defer fb.deinit(gpa);

    var last_clicks: u32 = std.math.maxInt(u32);
    var force = true; // first frame, resize, or expose: redraw even if the tree is clean

    const screenshot = init.environ_map.get("ZIGUI_SCREENSHOT");
    var script: ?[]const u8 = init.environ_map.get("ZIGUI_SCRIPT");
    var frames_drawn: u32 = 0;

    var running = true;
    while (running) {
        if (state.clicks != last_clicks) {
            last_clicks = state.clicks;
            var buf: [64]u8 = undefined;
            const title = std.mem.printSentinel(&buf, "zigui demo - {d} clicks, {d} cards", .{ state.clicks, state.card_count }, 0) catch "zigui demo";
            window.setTitle(title);
            if (state.status) |st| {
                var sbuf: [96]u8 = undefined;
                const msg = std.fmt.bufPrint(&sbuf, "{d} clicks  |  {d} cards  |  selected: sidebar row {d}", .{ state.clicks, state.card_count, state.selected + 1 }) catch "";
                try ui.setLabelText(st, msg);
            }
        }

        ui.update();
        if (force or ui.isDirty()) {
            const px = window.pixelSize();
            const scale = window.scale();
            try fb.resize(gpa, px.w, px.h);
            const logical: zigui.geometry.Size = .{
                .w = @as(f32, @floatFromInt(px.w)) / scale,
                .h = @as(f32, @floatFromInt(px.h)) / scale,
            };
            if (scale != prewarmed_scale) {
                // Rasterize common glyphs up front so first draw does not stall.
                prewarmed_scale = scale;
                for (0..ui.text.fonts.items.len) |f| {
                    ui.text.prewarmAscii(@intCast(f), ui.theme.font_size * scale);
                    ui.text.prewarmAscii(@intCast(f), 13 * scale);
                }
            }
            try ui.layoutAndPaint(logical, &list);
            zigui.software.render(&fb, &list, .{ .scale = scale, .clear = background, .glyphs = ui.glyphProvider() });
            try window.present(fb.bytes(), fb.width, fb.height);
            force = false;
            frames_drawn += 1;
        }
        ui.endFrame();

        // Headless mode: after the first frame has laid things out, feed the
        // scripted input, then let the loop redraw once more and finish.
        if (screenshot != null) {
            if (script) |s| {
                Script.run(&ui, s);
                script = null;
                continue;
            }
            const path = screenshot.?;
            const png = try zigui.png.encodeRgba(gpa, fb.bytes(), fb.width, fb.height);
            defer gpa.free(png);
            try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = png });
            std.log.info("wrote {s}: {d}x{d}, {d} frames drawn, {d} clicks, {d} cards", .{
                path, fb.width, fb.height, frames_drawn, state.clicks, state.card_count,
            });
            return;
        }

        var ev = sdl.waitEvent(-1);
        while (ev) |e| : (ev = sdl.pollEvent()) {
            switch (e.data) {
                .quit, .close_requested => running = false,
                .resized, .expose => force = true,
                .mouse_move => |m| ui.pointerMove(m.x, m.y),
                .mouse_button => |m| ui.pointerButton(m.x, m.y, @intFromEnum(m.button), m.down),
                .mouse_wheel => |m| ui.wheel(0, 0, m.x, m.y),
                .key => |k| if (k.down and k.keycode == 27) { // escape
                    running = false;
                },
            }
        }
    }
}
