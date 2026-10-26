//! Demo: a small IDE-style layout driven by the layout pass, painted by the
//! software renderer, shown through the SDL3 shim.
//!
//! Run:  zig build demo
//! Env:  ZIGUI_SCREENSHOT=out.png  render one frame, write a PNG, and exit
//!                                 (use SDL_VIDEODRIVER=dummy for headless runs)

const std = @import("std");
const zigui = @import("zigui");
const sdl = @import("zigui_sdl");

const Color = zigui.Color;
const Length = zigui.Length;
const Edges = zigui.style.Edges;
const Tree = zigui.Tree;
const Handle = zigui.Handle;

fn rgb(hex: u24) Color {
    return Color.rgb(@truncate(hex >> 16), @truncate(hex >> 8), @truncate(hex));
}

fn add(tree: *Tree, parent: Handle, style: zigui.Style, visual: zigui.tree.Visual) !Handle {
    const h = try tree.create(.{ .style = style, .visual = visual });
    try tree.appendChild(parent, h);
    return h;
}

fn buildUi(tree: *Tree) !void {
    tree.get(tree.root).?.style = .{ .direction = .column };
    tree.get(tree.root).?.visual = .{ .background = rgb(0x1e1f22) };

    // Header with a few button-like boxes.
    const header = try add(tree, tree.root, .{
        .direction = .row,
        .height = Length.px(44),
        .padding = Edges.xy(12, 8),
        .gap = Length.px(8),
        .shrink = 0,
    }, .{ .background = rgb(0x2b2d30) });
    const accents = [_]u24{ 0x3574f0, 0x4a4d52, 0x4a4d52 };
    const widths = [_]f32{ 90, 70, 70 };
    for (accents, widths) |a, w| {
        _ = try add(tree, header, .{ .width = Length.px(w), .shrink = 0 }, .{ .background = rgb(a), .radius = 6 });
    }
    _ = try add(tree, header, .{ .grow = 1 }, .{});
    _ = try add(tree, header, .{ .width = Length.px(160), .shrink = 0 }, .{
        .background = rgb(0x1e1f22),
        .border_color = rgb(0x4a4d52),
        .border_width = 1,
        .radius = 6,
    });

    // Body: sidebar (20%, clamped 150..360) and main area.
    const body = try add(tree, tree.root, .{
        .direction = .row,
        .grow = 1,
        .padding = Edges.all(8),
        .gap = Length.px(8),
    }, .{});
    const sidebar = try add(tree, body, .{
        .direction = .column,
        .width = Length.pct(20),
        .min_width = Length.px(150),
        .max_width = Length.px(360),
        .shrink = 0,
        .padding = Edges.all(8),
        .gap = Length.px(4),
    }, .{ .background = rgb(0x2b2d30), .radius = 8 });
    for (0..9) |i| {
        const shade: u24 = if (i == 2) 0x3574f0 else 0x393b40;
        _ = try add(tree, sidebar, .{ .height = Length.px(28), .shrink = 0, .margin = .{ .left = Length.px(@floatFromInt((i % 3) * 10)) } }, .{
            .background = rgb(shade),
            .radius = 4,
        });
    }

    const content = try add(tree, body, .{ .direction = .column, .grow = 1, .gap = Length.px(8) }, .{});
    const cards = try add(tree, content, .{ .direction = .row, .height = Length.px(120), .gap = Length.px(8), .shrink = 0 }, .{});
    const card_colors = [_]u24{ 0x2f6f4f, 0x7a4b2a, 0x5a3f8a, 0x2a5f7a };
    for (card_colors) |col| {
        _ = try add(tree, cards, .{ .grow = 1 }, .{ .background = rgb(col), .radius = 12 });
    }
    const editor = try add(tree, content, .{ .grow = 1, .padding = Edges.all(12), .direction = .column, .gap = Length.px(6) }, .{
        .background = rgb(0x26282c),
        .border_color = rgb(0x3d3f45),
        .border_width = 1,
        .radius = 8,
    });
    tree.get(editor).?.flags.clip_children = true;
    for (0..14) |i| {
        const w: f32 = 120 + @as(f32, @floatFromInt((i * 53) % 260));
        _ = try add(tree, editor, .{ .height = Length.px(10), .width = Length.px(w), .shrink = 0 }, .{
            .background = rgb(if (i % 4 == 0) 0x6f737a else 0x4e5157),
            .radius = 3,
        });
    }

    // Status bar.
    _ = try add(tree, tree.root, .{ .height = Length.px(24), .shrink = 0 }, .{ .background = rgb(0x3574f0) });
}

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

    var tree = try Tree.init(gpa);
    defer tree.deinit();
    try buildUi(&tree);

    var layout = zigui.Layout.init(gpa);
    defer layout.deinit();

    const commands = try gpa.alloc(zigui.draw_list.Command, 4096);
    defer gpa.free(commands);
    var list = zigui.DrawList.init(commands, &.{});

    var fb = try zigui.software.Framebuffer.init(gpa, 1, 1);
    defer fb.deinit(gpa);

    const screenshot = init.environ_map.get("ZIGUI_SCREENSHOT");
    var needs_frame = true;
    var running = true;

    while (running) {
        if (needs_frame) {
            needs_frame = false;
            const px = window.pixelSize();
            const scale = window.scale();
            try fb.resize(gpa, px.w, px.h);

            const logical: zigui.geometry.Size = .{
                .w = @as(f32, @floatFromInt(px.w)) / scale,
                .h = @as(f32, @floatFromInt(px.h)) / scale,
            };
            try layout.run(&tree, logical);
            try zigui.paint.build(&tree, &list);
            zigui.software.render(&fb, &list, .{ .scale = scale, .clear = rgb(0x1e1f22) });
            tree.clearDirty(tree.root);
            try window.present(fb.bytes(), fb.width, fb.height);

            if (screenshot) |path| {
                const png = try zigui.png.encodeRgba(gpa, fb.bytes(), fb.width, fb.height);
                defer gpa.free(png);
                try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = png });
                std.log.info("wrote {s} ({d}x{d}, scale {d:.2}, {d} commands)", .{ path, fb.width, fb.height, scale, list.items().len });
                return;
            }
        }

        var ev = sdl.waitEvent(-1);
        while (ev) |e| : (ev = sdl.pollEvent()) {
            switch (e.data) {
                .quit, .close_requested => running = false,
                .resized, .expose => needs_frame = true,
                .key => |k| if (k.down and k.keycode == 27) { // escape
                    running = false;
                },
                else => {},
            }
        }
    }
}
