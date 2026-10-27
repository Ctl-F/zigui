//! Demo: an IDE-style layout with working buttons. Layout pass, hit-testing,
//! events, widget state blocks, software renderer, and SDL3 shim together.
//!
//! Run:  zig build demo
//!
//!   Header buttons: "+ Card" adds a card, "- Card" removes one, "Sidebar"
//!   toggles the sidebar. Sidebar rows are flat buttons; click one to select it.
//!   The filter field narrows the sidebar as you type (Enter selects the first
//!   match). Tab / Shift+Tab move focus; Enter or Space activate a focused button.
//!
//!   Commands and shortcuts (the header buttons show theirs):
//!     Ctrl+N add card, Ctrl+D remove card, Ctrl+K Ctrl+X remove all cards,
//!     Ctrl+B toggle sidebar, Ctrl+F focus the filter, Ctrl+T switch theme
//!     (an alternative theme with its own button painter and colors),
//!     Up / Down move through the files while focus is in the sidebar (panel
//!     scope), Esc clears the filter while it has focus (widget scope).
//!   Text uses system fonts (stb_truetype); override with ZIGUI_FONT / ZIGUI_MONO_FONT.
//!
//! Env (for headless checks, with SDL_VIDEODRIVER=dummy):
//!   ZIGUI_SCRIPT="move 100 20;click 60 20"   feed input after the first frame:
//!       move X Y | click X Y | press X Y | type TEXT | key [ctrl+][shift+]NAME
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
    selected: usize = 0,
    items: [9]*Button = undefined,
    item_ctx: [9]SidebarItem = undefined,
    clicks: u32 = 0,
    status: ?*zigui.Label = null,
    filter: ?*zigui.TextField = null,
    buttons: [3]*Button = undefined,
    names: [9][]const u8 = undefined,
    paths: [9][]const u8 = undefined,
    editor: ?*zigui.CodeEditor = null,
    language: *const zigui.syntax.Language = &zigui.syntax.plain,
    io: std.Io = undefined,
    gpa: std.mem.Allocator = undefined,
    last_status: [160]u8 = undefined,
    last_status_len: usize = 0,
    base_theme: zigui.Theme = .{},
    alt_theme: zigui.Theme = .{},
    alt_active: bool = false,
    card_serial: usize = 0,

    fn addNode(self: *App, parent: Handle, style: zigui.Style, visual: zigui.tree.Visual) !Handle {
        const h = try self.ui.tree.create(.{ .style = style, .visual = visual });
        try self.ui.tree.appendChild(parent, h);
        return h;
    }
};

fn addCard(a: *App) !void {
    const col = card_palette[a.card_serial % card_palette.len];
    const card = try a.addNode(a.cards, .{ .grow = 1, .padding = Edges.all(14) }, .{ .background = rgb(col), .radius = 12 });
    a.card_serial += 1;
    a.card_count += 1;
    var buf: [32]u8 = undefined;
    const name = std.fmt.bufPrint(&buf, "Card {d}", .{a.card_serial}) catch "Card";
    _ = try a.ui.add(zigui.Label, card, .{ .text = name, .size = 18, .color = Color.white });
}

/// Load the file behind sidebar row `index` into the editor.
fn openFile(a: *App, index: usize) void {
    const ed = a.editor orelse return;
    const bytes = std.Io.Dir.cwd().readFileAlloc(a.io, a.paths[index], a.gpa, .limited(32 * 1024 * 1024)) catch |err| {
        std.log.warn("could not open {s}: {s}", .{ a.paths[index], @errorName(err) });
        return;
    };
    ed.loadText(bytes, true) catch {
        a.gpa.free(bytes);
        return;
    };
    a.language = zigui.syntax.languageForPath(a.paths[index]);
    ed.setLanguage(a.language) catch {};
}

fn onSelectItem(ctx: *SidebarItem, _: *zigui.Event) void {
    const a = ctx.app;
    a.clicks += 1;
    a.items[a.selected].setVariant(.flat);
    a.selected = ctx.index;
    a.items[a.selected].setVariant(.primary);
    openFile(a, a.selected);
}

// ---- commands (shared by shortcuts and buttons) ----

fn cmdAddCard(a: *App, _: *zigui.Event) void {
    a.clicks += 1;
    if (a.card_count < max_cards) addCard(a) catch {};
}

fn cmdRemoveCard(a: *App, _: *zigui.Event) void {
    a.clicks += 1;
    if (a.card_count == 0) return;
    _ = a.ui.tree.destroySubtree(a.ui.tree.get(a.cards).?.last_child);
    a.card_count -= 1;
}

fn cmdClearCards(a: *App, _: *zigui.Event) void {
    a.clicks += 1;
    while (a.card_count > 0) {
        _ = a.ui.tree.destroySubtree(a.ui.tree.get(a.cards).?.last_child);
        a.card_count -= 1;
    }
}

fn cmdToggleSidebar(a: *App, _: *zigui.Event) void {
    a.clicks += 1;
    a.sidebar_visible = !a.sidebar_visible;
    a.ui.setHidden(a.sidebar, !a.sidebar_visible);
}

/// An alternative button look: flat, square, with an accent bar along the bottom.
fn flatButtonPainter(pc: *zigui.PaintCtx, b: *const Button) zigui.paint_ctx.Error!void {
    const c = b.colors();
    const bg = if (!b.props.enabled) c.disabled else if (b.out.pressed) c.pressed else if (b.out.hovered) c.hover else c.normal;
    try pc.list.fillRect(pc.rect, zigui.draw_list.Paint.solid(bg));
    const bar: zigui.geometry.Rect = .{ .x = pc.rect.x, .y = pc.rect.bottom() - 3, .w = pc.rect.w, .h = 3 };
    try pc.list.fillRect(bar, zigui.draw_list.Paint.solid(if (b.out.focus_visible) b.ui.theme.focus_ring else rgb(0xf0a030)));
    pc.text_color = if (b.props.enabled) c.text else c.text_disabled;
}

fn cmdSwitchTheme(a: *App, _: *zigui.Event) void {
    a.alt_active = !a.alt_active;
    a.ui.setTheme(if (a.alt_active) a.alt_theme else a.base_theme);
}

fn cmdFocusFilter(a: *App, _: *zigui.Event) void {
    if (a.filter) |f| a.ui.setFocus(f.node);
}

/// Esc in the filter: clear it, or leave it if it is already empty.
fn cmdClearFilter(a: *App, _: *zigui.Event) void {
    const f = a.filter orelse return;
    if (f.text().len == 0) {
        a.ui.setFocus(null);
        return;
    }
    f.setText("") catch return;
    applyFilter(a);
}

fn moveSelection(a: *App, step: isize) void {
    var i: isize = @intCast(a.selected);
    const n: isize = @intCast(a.items.len);
    while (true) {
        i += step;
        if (i < 0 or i >= n) return;
        if (!a.ui.tree.get(a.items[@intCast(i)].node).?.flags.hidden) break;
    }
    a.items[a.selected].setVariant(.flat);
    a.selected = @intCast(i);
    a.items[a.selected].setVariant(.primary);
    a.ui.setFocus(a.items[a.selected].node);
    a.clicks += 1;
    openFile(a, a.selected);
}

fn cmdNextFile(a: *App, _: *zigui.Event) void {
    moveSelection(a, 1);
}

fn cmdPrevFile(a: *App, _: *zigui.Event) void {
    moveSelection(a, -1);
}

fn setupCommands(a: *App) !void {
    const ui = a.ui;
    _ = try ui.registerCommand("cards.add", .{ .title = "+ Card", .run = .bind(a, cmdAddCard) });
    _ = try ui.registerCommand("cards.remove", .{ .title = "- Card", .run = .bind(a, cmdRemoveCard) });
    _ = try ui.registerCommand("cards.clear", .{ .title = "Clear cards", .run = .bind(a, cmdClearCards) });
    _ = try ui.registerCommand("view.sidebar", .{ .title = "Sidebar", .run = .bind(a, cmdToggleSidebar) });
    _ = try ui.registerCommand("view.theme", .{ .title = "Switch theme", .run = .bind(a, cmdSwitchTheme) });
    _ = try ui.registerCommand("filter.focus", .{ .title = "Filter", .run = .bind(a, cmdFocusFilter) });
    _ = try ui.registerCommand("filter.clear", .{ .title = "Clear filter", .run = .bind(a, cmdClearFilter) });
    _ = try ui.registerCommand("file.next", .{ .title = "Next file", .run = .bind(a, cmdNextFile), .repeat = true });
    _ = try ui.registerCommand("file.prev", .{ .title = "Previous file", .run = .bind(a, cmdPrevFile), .repeat = true });

    // App-wide bindings come from keymap text, like a user's keymap file.
    const report = ui.loadKeymap(
        \\ctrl+n = cards.add
        \\ctrl+d = cards.remove
        \\ctrl+k ctrl+x = cards.clear   # a two-key chord
        \\ctrl+b = view.sidebar
        \\ctrl+f = filter.focus
        \\ctrl+t = view.theme
        \\
    );
    if (report.errors > 0) std.log.warn("keymap: {d} bad line(s), first at line {d}", .{ report.errors, report.first_error_line });

    // Scoped bindings need node handles, so they are made in code.
    try ui.bindShortcut("down", "file.next", .panel, a.sidebar);
    try ui.bindShortcut("up", "file.prev", .panel, a.sidebar);
    try ui.bindShortcut("escape", "filter.clear", .widget, a.filter.?.node);

    // Header buttons run the same commands, so they stay in sync with shortcuts.
    const linked = [_][]const u8{ "cards.add", "cards.remove", "view.sidebar" };
    for (a.buttons, linked) |b, name| {
        try b.setCommand(name);
        var buf: [48]u8 = undefined;
        const title = ui.commands.get(ui.commands.find(name).?).?.title;
        var label_buf: [96]u8 = undefined;
        const text = if (ui.shortcutText(name, &buf)) |sc|
            std.fmt.bufPrint(&label_buf, "{s}   {s}", .{ title, sc }) catch title
        else
            title;
        try b.setText(text);
    }
}

fn containsIgnoreCase(hay: []const u8, needle: []const u8) bool {
    return std.ascii.findIgnoreCase(hay, needle) != null;
}

fn applyFilter(a: *App) void {
    const f = a.filter orelse return;
    const needle = f.text();
    for (a.items, a.names) |b, name| a.ui.setHidden(b.node, !containsIgnoreCase(name, needle));
}

fn onFilterChanged(a: *App, _: *zigui.Event) void {
    applyFilter(a);
}

/// Enter in the filter selects the first row that is still visible.
fn onFilterSubmit(a: *App, _: *zigui.Event) void {
    a.clicks += 1;
    for (a.items, 0..) |b, i| {
        if (a.ui.tree.get(b.node).?.flags.hidden) continue;
        a.items[a.selected].setVariant(.flat);
        a.selected = i;
        b.setVariant(.primary);
        openFile(a, i);
        return;
    }
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
    const variants = [_]zigui.button.Variant{ .primary, .normal, .normal };
    for (&a.buttons, variants) |*slot, variant| {
        slot.* = try ui.add(zigui.Button, header, .{
            .style = .{ .padding = Edges.xy(14, 0), .shrink = 0 },
            .variant = variant,
        });
    }
    _ = try a.addNode(header, .{ .grow = 1 }, .{});
    a.filter = try ui.add(zigui.TextField, header, .{
        .style = .{ .width = .px(220), .padding = Edges.xy(8, 0), .shrink = 0 },
        .placeholder = "Filter files...",
        .on_change = .bind(a, onFilterChanged),
        .on_submit = .bind(a, onFilterSubmit),
    });
    _ = try ui.add(zigui.Button, header, .{
        .style = .{ .padding = Edges.xy(14, 0), .shrink = 0 },
        .text = "Disabled",
        .enabled = false,
    });

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
    const names = [9][]const u8{ "editor.zig", "piece_table.zig", "document.zig", "code_editor.zig", "layout.zig", "ui.zig", "shortcuts.zig", "demo.zig", "README.md" };
    const paths = [9][]const u8{ "src/editor/editor.zig", "src/editor/piece_table.zig", "src/editor/document.zig", "src/widgets/code_editor.zig", "src/core/layout.zig", "src/core/ui.zig", "src/core/shortcuts.zig", "examples/demo.zig", "README.md" };
    for (0..a.items.len) |i| {
        const indent: f32 = @floatFromInt((i % 3) * 10);
        a.names[i] = names[i];
        a.paths[i] = paths[i];
        a.item_ctx[i] = .{ .app = a, .index = i };
        a.items[i] = try ui.add(zigui.Button, a.sidebar, .{
            .style = .{
                .height = .px(28),
                .shrink = 0,
                .padding = Edges.xy(10, 0),
                .margin = .{ .left = .px(indent) },
            },
            .text = names[i],
            .text_align = .start,
            .variant = if (i == a.selected) .primary else .flat,
            .on_click = .bind(&a.item_ctx[i], onSelectItem),
        });
    }

    const content = try a.addNode(a.body, .{ .direction = .column, .grow = 1, .gap = Length.px(8) }, .{});
    a.cards = try a.addNode(content, .{ .direction = .row, .height = Length.px(120), .gap = Length.px(8), .shrink = 0 }, .{});
    for (0..4) |_| try addCard(a);
    a.editor = try ui.add(zigui.CodeEditor, content, .{ .style = .{ .grow = 1 }, .size = 13 });
    openFile(a, a.selected);

    // Status bar.
    const status_bar = try a.addNode(tree.root, .{ .height = Length.px(24), .shrink = 0, .padding = Edges.xy(10, 0) }, .{ .background = rgb(0x3574f0) });
    a.status = try ui.add(zigui.Label, status_bar, .{
        .style = .{ .grow = 1 },
        .text = "Ready",
        .size = 12,
        .color = Color.white,
    });
}

const Script = struct {
    fn keyByName(name: []const u8) zigui.keys.Key {
        return zigui.keys.parseKey(name) orelse .unknown;
    }

    /// Apply ";"-separated commands to the UI.
    fn run(ui: *Ui, text: []const u8) void {
        var cmds = std.mem.tokenizeScalar(u8, text, ';');
        while (cmds.next()) |cmd| {
            const sp = std.mem.indexOfScalar(u8, cmd, ' ') orelse continue;
            const verb = cmd[0..sp];
            const rest = cmd[sp + 1 ..];
            if (std.mem.eql(u8, verb, "type")) {
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
                    } else if (std.mem.eql(u8, p, "alt")) {
                        mods.alt = true;
                    } else {
                        last = p;
                    }
                }
                const k = keyByName(last);
                ui.key(k, mods, true, false);
                ui.key(k, mods, false, false);
            } else {
                var nums = std.mem.tokenizeScalar(u8, rest, ' ');
                const x = std.fmt.parseFloat(f32, nums.next() orelse continue) catch continue;
                const y = std.fmt.parseFloat(f32, nums.next() orelse continue) catch continue;
                if (std.mem.eql(u8, verb, "move")) {
                    ui.pointerMove(x, y);
                } else if (std.mem.eql(u8, verb, "click")) {
                    ui.pointerMove(x, y);
                    ui.pointerButtonEx(x, y, 1, true, 1);
                    ui.pointerButtonEx(x, y, 1, false, 1);
                } else if (std.mem.eql(u8, verb, "press")) {
                    ui.pointerMove(x, y);
                    ui.pointerButtonEx(x, y, 1, true, 1);
                }
            }
        }
    }
};

fn clipGet(_: ?*anyopaque, gpa: std.mem.Allocator) ?[]u8 {
    return sdl.clipboardGet(gpa);
}

fn clipSet(_: ?*anyopaque, text: []const u8) void {
    sdl.clipboardSet(text);
}

fn sdlCursor(c: zigui.tree.Cursor) sdl.Cursor {
    return switch (c) {
        .default => .default,
        .text => .text,
        .pointer => .pointer,
    };
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
    ui.clipboard = .{ .get = clipGet, .set = clipSet };
    var state: App = .{ .ui = &ui, .io = io, .gpa = gpa };
    state.base_theme = ui.theme;
    state.alt_theme = ui.theme;
    state.alt_theme.button_painter = flatButtonPainter;
    state.alt_theme.corner_radius = 0;
    state.alt_theme.font_size = 15;
    state.alt_theme.button_colors[0].normal = rgb(0x5a4a38);
    state.alt_theme.button_colors[0].hover = rgb(0x6e5a44);
    state.alt_theme.button_colors[1].normal = rgb(0xb8541f);
    state.alt_theme.button_colors[1].hover = rgb(0xd06428);
    state.alt_theme.field.border_focus = rgb(0xf0a030);
    state.alt_theme.editor.background = rgb(0x1a1612);
    state.alt_theme.editor.current_line = rgb(0x26201a);
    state.alt_theme.editor.syntax[@intFromEnum(zigui.syntax.TokenKind.keyword)] = rgb(0xf0a030);
    try buildUi(&state);
    try setupCommands(&state);

    // Highlighted code emits one glyph run per token color change, so the
    // list needs room: a full screen of code is a few thousand commands.
    const commands = try gpa.alloc(zigui.draw_list.Command, 32768);
    defer gpa.free(commands);
    const glyphs = try gpa.alloc(zigui.draw_list.Glyph, 65536);
    defer gpa.free(glyphs);
    var list = zigui.DrawList.init(commands, glyphs);
    var prewarmed_scale: f32 = 0;

    var fb = try zigui.software.Framebuffer.init(gpa, 1, 1);
    defer fb.deinit(gpa);

    var force = true; // first frame, resize, or expose: redraw even if the tree is clean

    const screenshot = init.environ_map.get("ZIGUI_SCREENSHOT");
    var script: ?[]const u8 = init.environ_map.get("ZIGUI_SCRIPT");
    var frames_drawn: u32 = 0;

    var text_input_on = false;
    var running = true;
    while (running) {
        _ = ui.tick(sdl.ticks());
        // Settle widget state from last iteration's input, then refresh the
        // status text from it (so it never lags a keystroke behind).
        ui.update();
        if (state.status) |st| {
            const ed = state.editor.?;
            var sbuf: [160]u8 = undefined;
            const msg = std.fmt.bufPrint(&sbuf, "{s} ({s})   Ln {d}, Col {d}{s}   |   {d} lines   |   {d} cursor(s)   |   {d} cards   |   {d} clicks", .{
                state.names[state.selected],
                state.language.name,
                ed.out.caret_line + 1,
                ed.out.caret_column + 1,
                if (ed.out.modified) "   (modified)" else "",
                ed.out.line_count,
                ed.out.selection_count,
                state.card_count,
                state.clicks,
            }) catch "";
            if (!std.mem.eql(u8, msg, state.last_status[0..state.last_status_len])) {
                @memcpy(state.last_status[0..msg.len], msg);
                state.last_status_len = msg.len;
                try st.setText(msg);
                var tbuf: [96]u8 = undefined;
                const title = std.mem.printSentinel(&tbuf, "zigui demo - {s}{s}", .{ state.names[state.selected], if (ed.out.modified) " *" else "" }, 0) catch "zigui demo";
                window.setTitle(title);
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

        // Platform sync: IME/text input follows the focused text field, and the
        // mouse cursor follows what is under the pointer.
        if (ui.textInputRect()) |r| {
            if (!text_input_on) sdl.startTextInput(&window);
            text_input_on = true;
            sdl.setTextInputArea(&window, r.x, r.y, r.w, r.h);
        } else if (text_input_on) {
            sdl.stopTextInput(&window);
            text_input_on = false;
        }
        sdl.setCursor(sdlCursor(ui.cursor()));

        // Sleep until input, or until the caret next needs to blink.
        const timeout: i32 = if (ui.nextWakeMs()) |ms| @intCast(ms) else -1;
        var ev = sdl.waitEvent(timeout);
        _ = ui.tick(sdl.ticks()); // time as of this input, for chord timeouts and blinking
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
                    // Escape that nothing used: leave a focused widget, else quit.
                    if (k.down and k.key == .escape and !used) {
                        if (ui.focused() != null) ui.setFocus(null) else running = false;
                    }
                },
            }
        }
    }
}
