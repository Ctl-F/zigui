//! Demo: an IDE-style layout with working buttons. Layout pass, hit-testing,
//! events, widget state blocks, software renderer, and SDL3 shim together.
//!
//! Run:  zig build demo
//!
//!   Header buttons: "+ Card" adds a card, "- Card" removes one, "Sidebar"
//!   toggles the sidebar. Sidebar rows are flat buttons; click one to select it.
//!   The window title counts clicks. Text is not drawn yet (no text renderer).
//!
//! Env (for headless checks, with SDL_VIDEODRIVER=dummy):
//!   ZIGUI_SCRIPT="move 100 20;click 60 20"   feed pointer input after the first frame
//!   ZIGUI_SCREENSHOT=out.png                 write a PNG of the final frame and exit

const std = @import("std");
const zigui = @import("zigui");
const sdl = @import("zigui_sdl");

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

    fn addNode(self: *App, parent: Handle, style: zigui.Style, visual: zigui.tree.Visual) !Handle {
        const h = try self.ui.tree.create(.{ .style = style, .visual = visual });
        try self.ui.tree.appendChild(parent, h);
        return h;
    }
};

fn app(user: ?*anyopaque) *App {
    return @ptrCast(@alignCast(user.?));
}

fn onAddCard(_: *zigui.Event, user: ?*anyopaque) callconv(.c) void {
    const a = app(user);
    a.clicks += 1;
    if (a.card_count >= max_cards) return;
    const col = card_palette[a.card_count % card_palette.len];
    _ = a.addNode(a.cards, .{ .grow = 1 }, .{ .background = rgb(col), .radius = 12 }) catch return;
    a.card_count += 1;
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
    const specs = [_]struct { w: f32, variant: zigui.button.Variant, cb: zigui.event.Handler }{
        .{ .w = 90, .variant = .primary, .cb = onAddCard },
        .{ .w = 90, .variant = .normal, .cb = onRemoveCard },
        .{ .w = 90, .variant = .normal, .cb = onToggleSidebar },
    };
    for (specs) |spec| {
        const b = try ui.createButton(header, .{ .width = Length.px(spec.w), .shrink = 0 });
        ui.setButtonVariant(b, spec.variant);
        b.props.on_click = spec.cb;
        b.props.on_click_user = a;
    }
    _ = try a.addNode(header, .{ .grow = 1 }, .{});
    const disabled = try ui.createButton(header, .{ .width = Length.px(120), .shrink = 0 });
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
    for (0..a.items.len) |i| {
        const indent: f32 = @floatFromInt((i % 3) * 10);
        const b = try ui.createButton(a.sidebar, .{ .height = Length.px(28), .shrink = 0, .margin = .{ .left = Length.px(indent) } });
        ui.setButtonVariant(b, if (i == a.selected) .primary else .flat);
        a.items[i] = b;
        a.item_ctx[i] = .{ .app = a, .index = i };
        b.props.on_click = onSelectItem;
        b.props.on_click_user = &a.item_ctx[i];
    }

    const content = try a.addNode(a.body, .{ .direction = .column, .grow = 1, .gap = Length.px(8) }, .{});
    a.cards = try a.addNode(content, .{ .direction = .row, .height = Length.px(120), .gap = Length.px(8), .shrink = 0 }, .{});
    for (0..4) |_| {
        const col = card_palette[a.card_count % card_palette.len];
        _ = try a.addNode(a.cards, .{ .grow = 1 }, .{ .background = rgb(col), .radius = 12 });
        a.card_count += 1;
    }
    const editor = try a.addNode(content, .{ .grow = 1, .padding = Edges.all(12), .direction = .column, .gap = Length.px(6) }, .{
        .background = rgb(0x26282c),
        .border_color = rgb(0x3d3f45),
        .border_width = 1,
        .radius = 8,
    });
    tree.get(editor).?.flags.clip_children = true;
    for (0..14) |i| {
        const w: f32 = 120 + @as(f32, @floatFromInt((i * 53) % 260));
        _ = try a.addNode(editor, .{ .height = Length.px(10), .width = Length.px(w), .shrink = 0 }, .{
            .background = rgb(if (i % 4 == 0) 0x6f737a else 0x4e5157),
            .radius = 3,
        });
    }

    // Status bar.
    _ = try a.addNode(tree.root, .{ .height = Length.px(24), .shrink = 0 }, .{ .background = rgb(0x3574f0) });
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
    var state: App = .{ .ui = &ui };
    try buildUi(&state);

    const commands = try gpa.alloc(zigui.draw_list.Command, 4096);
    defer gpa.free(commands);
    var list = zigui.DrawList.init(commands, &.{});

    var fb = try zigui.software.Framebuffer.init(gpa, 1, 1);
    defer fb.deinit(gpa);

    var last_clicks: u32 = std.math.maxInt(u32);
    var force = true; // first frame, resize, or expose: redraw even if the tree is clean

    const screenshot = init.environ_map.get("ZIGUI_SCREENSHOT");
    var script: ?[]const u8 = init.environ_map.get("ZIGUI_SCRIPT");
    var frames_drawn: u32 = 0;

    var running = true;
    while (running) {
        ui.update();
        if (force or ui.isDirty()) {
            const px = window.pixelSize();
            const scale = window.scale();
            try fb.resize(gpa, px.w, px.h);
            const logical: zigui.geometry.Size = .{
                .w = @as(f32, @floatFromInt(px.w)) / scale,
                .h = @as(f32, @floatFromInt(px.h)) / scale,
            };
            try ui.layoutAndPaint(logical, &list);
            zigui.software.render(&fb, &list, .{ .scale = scale, .clear = background });
            try window.present(fb.bytes(), fb.width, fb.height);
            force = false;
            frames_drawn += 1;
        }
        ui.endFrame();

        if (state.clicks != last_clicks) {
            last_clicks = state.clicks;
            var buf: [64]u8 = undefined;
            const title = std.mem.printSentinel(&buf, "zigui demo - {d} clicks, {d} cards", .{ state.clicks, state.card_count }, 0) catch "zigui demo";
            window.setTitle(title);
        }

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
