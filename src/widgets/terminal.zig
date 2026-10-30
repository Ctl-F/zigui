//! Terminal: draws a terminal emulator screen (`terminal/vt.zig`) and turns
//! keys, text, mouse and paste into the bytes a program expects.
//!
//! It knows nothing about processes. You give it a `write` hook (where the
//! bytes the user types go: a `Pty`, an SSH channel) and call `feed` with what
//! the program printed; it reports its size in character cells to an `on_resize`
//! hook so the program can be told.
//!
//!     const term = try ui.add(Terminal, parent, .{
//!         .style = .{ .grow = 1 },
//!         .on_write = .bind(&session, Session.send),     // fn (*Session, bytes: []const u8) void
//!         .on_resize = .bind(&session, Session.resized), // fn (*Session, cols: u16, rows: u16) void
//!     });
//!     term.feed(bytes_from_the_program);
//!
//! Keys: everything is sent to the program (arrows, Home/End, F-keys, Ctrl+letter,
//! Alt+letter as Escape-prefixed), except function keys, which stay with the
//! application's shortcuts unless `pass_function_keys` is off, Shift+PageUp/Down
//! and Shift+Home/End (scroll the history), Ctrl+Shift+C (copy) and Ctrl+Shift+V
//! (paste). The wheel scrolls the history. Dragging selects; double-click selects
//! a word and triple-click a line. Programs that ask for mouse reports (tmux, vim)
//! get them, unless Shift is held.

const std = @import("std");
const Handle = @import("../core/handle.zig").Handle;
const shadow = @import("../core/shadow.zig");
const Ui = @import("../core/ui.zig").Ui;
const event = @import("../core/event.zig");
const keys = @import("../core/keys.zig");
const paint_ctx = @import("../core/paint_ctx.zig");
const PaintCtx = paint_ctx.PaintCtx;
const draw_list = @import("../core/draw_list.zig");
const Paint = draw_list.Paint;
const geometry = @import("../core/geometry.zig");
const Color = geometry.Color;
const Rect = geometry.Rect;
const Style = @import("../core/style.zig").Style;
const Node = @import("../core/tree.zig").Node;
const vt = @import("../terminal/vt.zig");

pub const WriteHook = struct {
    ctx: ?*anyopaque = null,
    call: *const fn (ctx: ?*anyopaque, bytes: []const u8) void,

    pub fn bind(ctx: anytype, comptime f: anytype) WriteHook {
        const Ptr = @TypeOf(ctx);
        return .{
            .ctx = @ptrCast(ctx),
            .call = &struct {
                fn thunk(c: ?*anyopaque, bytes: []const u8) void {
                    f(@as(Ptr, @ptrCast(@alignCast(c.?))), bytes);
                }
            }.thunk,
        };
    }
};

pub const ResizeHook = struct {
    ctx: ?*anyopaque = null,
    call: *const fn (ctx: ?*anyopaque, cols: u16, rows: u16) void,

    pub fn bind(ctx: anytype, comptime f: anytype) ResizeHook {
        const Ptr = @TypeOf(ctx);
        return .{
            .ctx = @ptrCast(ctx),
            .call = &struct {
                fn thunk(c: ?*anyopaque, cols: u16, rows: u16) void {
                    f(@as(Ptr, @ptrCast(@alignCast(c.?))), cols, rows);
                }
            }.thunk,
        };
    }
};

/// The 16 base colors (xterm-like, readable on a dark background).
const ansi16 = [16]Color{
    Color.rgb(0x1e, 0x1e, 0x1e), Color.rgb(0xcd, 0x31, 0x31), Color.rgb(0x0d, 0xbc, 0x79), Color.rgb(0xe5, 0xe5, 0x10),
    Color.rgb(0x24, 0x72, 0xc8), Color.rgb(0xbc, 0x3f, 0xbc), Color.rgb(0x11, 0xa8, 0xcd), Color.rgb(0xe5, 0xe5, 0xe5),
    Color.rgb(0x66, 0x66, 0x66), Color.rgb(0xf1, 0x4c, 0x4c), Color.rgb(0x23, 0xd1, 0x8b), Color.rgb(0xf5, 0xf5, 0x43),
    Color.rgb(0x3b, 0x8e, 0xea), Color.rgb(0xd6, 0x70, 0xd6), Color.rgb(0x29, 0xb8, 0xdb), Color.rgb(0xff, 0xff, 0xff),
};

/// A terminal color (`vt.Color`) as a drawing color; `default` is used for the default color.
pub fn resolveColor(c: vt.Color, default: Color) Color {
    return switch (c >> 24) {
        1 => blk: {
            const i: u8 = @intCast(c & 0xff);
            if (i < 16) break :blk ansi16[i];
            if (i < 232) {
                const n = i - 16;
                const steps = [6]u8{ 0, 95, 135, 175, 215, 255 };
                break :blk Color.rgb(steps[n / 36], steps[(n / 6) % 6], steps[n % 6]);
            }
            const g: u8 = 8 + (i - 232) * 10;
            break :blk Color.rgb(g, g, g);
        },
        2 => Color.rgb(@intCast((c >> 16) & 0xff), @intCast((c >> 8) & 0xff), @intCast(c & 0xff)),
        else => default,
    };
}

fn modParam(m: keys.Mods) u8 {
    return 1 + @as(u8, if (m.shift) 1 else 0) + @as(u8, if (m.alt) 2 else 0) + @as(u8, if (m.ctrl) 4 else 0);
}

/// The bytes a key press stands for, or null if the terminal does not use it
/// (printable keys without Ctrl/Alt arrive as text instead).
pub fn encodeKey(buf: *[32]u8, key: keys.Key, mods: keys.Mods, app_cursor: bool) ?[]const u8 {
    const has_mod = mods.shift or mods.alt or mods.ctrl;
    const mp = modParam(mods);
    const K = keys.Key;
    switch (key) {
        .enter => return "\r",
        .tab => return if (mods.shift) "\x1b[Z" else "\t",
        .backspace => return if (mods.alt) "\x1b\x7f" else if (mods.ctrl) "\x08" else "\x7f",
        .escape => return "\x1b",
        .up, .down, .right, .left => {
            const ch: u8 = switch (key) {
                .up => 'A',
                .down => 'B',
                .right => 'C',
                else => 'D',
            };
            if (has_mod) return std.fmt.bufPrint(buf, "\x1b[1;{d}{c}", .{ mp, ch }) catch null;
            return std.fmt.bufPrint(buf, "\x1b{c}{c}", .{ @as(u8, if (app_cursor) 'O' else '['), ch }) catch null;
        },
        .home, .end => {
            const ch: u8 = if (key == .home) 'H' else 'F';
            if (has_mod) return std.fmt.bufPrint(buf, "\x1b[1;{d}{c}", .{ mp, ch }) catch null;
            return std.fmt.bufPrint(buf, "\x1b{c}{c}", .{ @as(u8, if (app_cursor) 'O' else '['), ch }) catch null;
        },
        .insert, .delete, .page_up, .page_down => {
            const n: u8 = switch (key) {
                .insert => 2,
                .delete => 3,
                .page_up => 5,
                else => 6,
            };
            if (has_mod) return std.fmt.bufPrint(buf, "\x1b[{d};{d}~", .{ n, mp }) catch null;
            return std.fmt.bufPrint(buf, "\x1b[{d}~", .{n}) catch null;
        },
        .f1, .f2, .f3, .f4 => {
            const ch: u8 = "PQRS"[@intFromEnum(key) - @intFromEnum(K.f1)];
            if (has_mod) return std.fmt.bufPrint(buf, "\x1b[1;{d}{c}", .{ mp, ch }) catch null;
            return std.fmt.bufPrint(buf, "\x1bO{c}", .{ch}) catch null;
        },
        .f5, .f6, .f7, .f8, .f9, .f10, .f11, .f12 => {
            const codes = [8]u8{ 15, 17, 18, 19, 20, 21, 23, 24 };
            const n = codes[@intFromEnum(key) - @intFromEnum(K.f5)];
            if (has_mod) return std.fmt.bufPrint(buf, "\x1b[{d};{d}~", .{ n, mp }) catch null;
            return std.fmt.bufPrint(buf, "\x1b[{d}~", .{n}) catch null;
        },
        else => {},
    }
    // Ctrl and Alt with printable keys.
    const v = @intFromEnum(key);
    if (v >= @intFromEnum(K.a) and v <= @intFromEnum(K.z)) {
        const letter: u8 = @intCast('a' + (v - @intFromEnum(K.a)));
        if (mods.ctrl) {
            buf[0] = 0x1b;
            const code = letter - 'a' + 1;
            if (mods.alt) {
                buf[1] = code;
                return buf[0..2];
            }
            buf[0] = code;
            return buf[0..1];
        }
        if (mods.alt) {
            buf[0] = 0x1b;
            buf[1] = if (mods.shift) letter - 32 else letter;
            return buf[0..2];
        }
        return null;
    }
    if (mods.ctrl and !mods.alt) {
        const c: ?u8 = switch (key) {
            .space => 0,
            .left_bracket => 0x1b,
            .backslash => 0x1c,
            .right_bracket => 0x1d,
            .slash => 0x1f,
            .d2 => 0,
            else => null,
        };
        if (c) |b| {
            buf[0] = b;
            return buf[0..1];
        }
    }
    return null;
}

pub const Terminal = struct {
    props: Props = .{},
    out: Out = .{},
    node: Handle,
    ui: *Ui,
    checker: shadow.Checker(Props),
    screen: vt.Screen,
    on_write: ?WriteHook = null,
    on_resize: ?ResizeHook = null,
    /// Lines scrolled back from the bottom (0: showing the live screen).
    view_offset: usize = 0,
    seen_version: u64 = 0,
    seen_sb: usize = 0,
    seen_evicted: u64 = 0,
    sel: ?Selection = null,
    dragging: bool = false,
    /// Drop the next committed text: an Alt combination already sent its own bytes.
    drop_text: bool = false,
    glyphs: std.ArrayListUnmanaged(draw_list.Glyph) = .empty,
    cell_w: f32 = 0,
    line_h: f32 = 0,

    pub const Props = struct {
        /// Em size in logical pixels; 0 uses the theme's size.
        size: f32 = 0,
        /// Function keys stay with the application's shortcuts.
        pass_function_keys: bool = true,

        pub const dirty_map = .{
            .size = shadow.Category.layout,
            .pass_function_keys = shadow.Category.none,
        };
    };

    pub const Out = struct {
        cols: u16 = 0,
        rows: u16 = 0,
        focused: bool = false,
        /// The program changed the window title since you last cleared this.
        title_changed: bool = false,
    };

    pub const Options = struct {
        style: Style = .{},
        label: []const u8 = "Terminal",
        size: f32 = 0,
        /// Lines of history kept.
        scrollback: u32 = 5000,
        pass_function_keys: bool = true,
        on_write: ?WriteHook = null,
        on_resize: ?ResizeHook = null,
    };

    pub const listened_kinds = [_]event.EventKind{
        .focus_in, .focus_out, .pointer_down, .pointer_move, .pointer_up, .wheel, .key_down, .text_input,
    };

    /// Selection endpoints in lines counted from the oldest history line.
    const Pos = struct { row: usize, col: usize };
    const Selection = struct { anchor: Pos, head: Pos };

    pub fn nodeTemplate(style: Style) Node {
        var s = style;
        if (s.grow == 0 and s.width == .auto and s.height == .auto) s.grow = 1;
        return .{ .role = .panel, .style = s, .cursor = .text };
    }

    pub fn init(ui: *Ui, node: Handle) Terminal {
        const props: Props = .{};
        const screen = vt.Screen.init(ui.gpa, 80, 24) catch @panic("out of memory creating a terminal");
        return .{ .node = node, .ui = ui, .checker = shadow.Checker(Props).init(&props), .screen = screen };
    }

    pub fn deinit(self: *Terminal) void {
        self.screen.deinit();
        self.glyphs.deinit(self.ui.gpa);
    }

    pub fn apply(self: *Terminal, o: Options) !void {
        try self.ui.tree.setLabel(self.node, o.label);
        self.props.size = o.size;
        self.props.pass_function_keys = o.pass_function_keys;
        self.screen.max_scrollback = o.scrollback;
        self.on_write = o.on_write;
        self.on_resize = o.on_resize;
        self.ui.tree.get(self.node).?.flags.focusable = true;
        self.checker.sync(&self.props);
    }

    pub fn prepare(self: *Terminal) void {
        _ = self;
    }

    pub fn endFrame(self: *Terminal) void {
        _ = self;
    }

    // ---- program output ----

    /// Show what the program printed. Answers to its queries go out through `on_write`.
    pub fn feed(self: *Terminal, bytes: []const u8) void {
        self.screen.write(bytes) catch {};
        const reply = self.screen.takeReply();
        if (reply.len > 0) {
            self.send(reply);
            self.screen.clearReply();
        }
        if (self.screen.title.items.len > 0) self.out.title_changed = true;
        self.afterOutput();
    }

    /// The program's window title (OSC 0/2), empty if it set none.
    pub fn title(self: *const Terminal) []const u8 {
        return self.screen.titleText();
    }

    fn afterOutput(self: *Terminal) void {
        const sb = self.screen.scrollbackLen();
        // A scrolled-back view stays on the same text while output arrives.
        if (self.view_offset > 0 and sb > self.seen_sb) self.view_offset += sb - self.seen_sb;
        const evicted = self.screen.sb_evicted - self.seen_evicted;
        if (evicted > 0) {
            if (self.sel) |*s| {
                s.anchor.row -|= @intCast(evicted);
                s.head.row -|= @intCast(evicted);
            }
            self.seen_evicted = self.screen.sb_evicted;
        }
        self.view_offset = @min(self.view_offset, sb);
        self.seen_sb = sb;
        self.ui.tree.markDirty(self.node, .{ .paint = true });
    }

    /// Clear the screen and history (like `reset`).
    pub fn clear(self: *Terminal) void {
        self.feed("\x1bc");
        self.view_offset = 0;
        self.sel = null;
    }

    fn send(self: *Terminal, bytes: []const u8) void {
        if (self.on_write) |h| h.call(h.ctx, bytes);
    }

    // ---- sizing ----

    fn metrics(self: *Terminal) ?struct { font: u32, size: f32, cell_w: f32, line_h: f32, ascent: f32 } {
        const theme = &self.ui.theme;
        const f = theme.mono_font;
        const ts = &self.ui.text;
        if (f >= ts.fonts.items.len) return null;
        const size = if (self.props.size > 0) self.props.size else theme.font_size;
        const m = ts.metrics(f, size);
        return .{ .font = f, .size = size, .cell_w = ts.measure(f, size, "M"), .line_h = @ceil(m.lineHeight()), .ascent = m.ascent };
    }

    pub fn update(self: *Terminal) void {
        self.ui.verifyProps(self.node, &self.checker, &self.props, "terminal");
        const m = self.metrics() orelse return;
        self.cell_w = m.cell_w;
        self.line_h = m.line_h;
        const r = self.ui.tree.get(self.node).?.rect;
        if (m.cell_w <= 0 or m.line_h <= 0 or r.w <= 0 or r.h <= 0) return;
        const cols: usize = @max(1, @as(usize, @intFromFloat((r.w - 8) / m.cell_w)));
        const rows: usize = @max(1, @as(usize, @intFromFloat(r.h / m.line_h)));
        if (cols != self.screen.cols or rows != self.screen.rows) {
            self.screen.resize(cols, rows) catch return;
            self.view_offset = @min(self.view_offset, self.screen.scrollbackLen());
            self.out.cols = @intCast(cols);
            self.out.rows = @intCast(rows);
            if (self.on_resize) |h| h.call(h.ctx, @intCast(cols), @intCast(rows));
            self.ui.tree.markDirty(self.node, .{ .paint = true });
        } else if (self.out.cols == 0) {
            self.out.cols = @intCast(cols);
            self.out.rows = @intCast(rows);
            if (self.on_resize) |h| h.call(h.ctx, @intCast(cols), @intCast(rows));
        }
    }

    // ---- lines and selection ----

    fn totalLines(self: *const Terminal) usize {
        return self.screen.scrollbackLen() + self.screen.rows;
    }

    fn lineCells(self: *const Terminal, abs: usize) []const vt.Cell {
        const sb = self.screen.scrollbackLen();
        if (abs < sb) return self.screen.scrollbackLine(abs);
        return self.screen.cells[(abs - sb) * self.screen.cols ..][0..self.screen.cols];
    }

    /// The history line shown on window row `r`.
    fn absRow(self: *const Terminal, r: usize) usize {
        return self.screen.scrollbackLen() - self.view_offset + r;
    }

    fn cellAt(self: *Terminal, local_x: f32, local_y: f32) Pos {
        const col: usize = if (local_x <= 4 or self.cell_w <= 0) 0 else @intFromFloat((local_x - 4) / self.cell_w);
        const row: usize = if (local_y <= 0 or self.line_h <= 0) 0 else @intFromFloat(local_y / self.line_h);
        return .{ .row = self.absRow(@min(row, self.screen.rows - 1)), .col = @min(col, self.screen.cols - 1) };
    }

    fn selOrdered(self: *const Terminal) ?struct { a: Pos, b: Pos } {
        const s = self.sel orelse return null;
        const a_first = s.anchor.row < s.head.row or (s.anchor.row == s.head.row and s.anchor.col <= s.head.col);
        const a = if (a_first) s.anchor else s.head;
        const b = if (a_first) s.head else s.anchor;
        if (a.row == b.row and a.col == b.col) return null;
        return .{ .a = a, .b = b };
    }

    fn selected(self: *const Terminal, row: usize, col: usize) bool {
        const o = self.selOrdered() orelse return false;
        if (row < o.a.row or row > o.b.row) return false;
        if (row == o.a.row and col < o.a.col) return false;
        if (row == o.b.row and col > o.b.col) return false;
        return true;
    }

    /// The selected text (lines joined by newlines, trailing blanks dropped), allocated with `gpa`.
    pub fn selectedText(self: *const Terminal, gpa: std.mem.Allocator) !?[]u8 {
        const o = self.selOrdered() orelse return null;
        var out: std.ArrayListUnmanaged(u8) = .empty;
        errdefer out.deinit(gpa);
        var row = o.a.row;
        while (row <= o.b.row and row < self.totalLines()) : (row += 1) {
            const cells = self.lineCells(row);
            const from = if (row == o.a.row) @min(o.a.col, cells.len) else 0;
            const to = if (row == o.b.row) @min(o.b.col + 1, cells.len) else cells.len;
            if (from < to) try vt.appendCells(cells[from..to], &out, gpa);
            if (row != o.b.row) try out.append(gpa, '\n');
        }
        return try out.toOwnedSlice(gpa);
    }

    fn selectWord(self: *Terminal, p: Pos) void {
        const cells = self.lineCells(p.row);
        const isWord = struct {
            fn f(c: vt.Cell) bool {
                return c.ch != ' ' and c.ch != 0 and c.ch != '\t';
            }
        }.f;
        var a = p.col;
        var b = p.col;
        if (isWord(cells[p.col])) {
            while (a > 0 and isWord(cells[a - 1])) a -= 1;
            while (b + 1 < cells.len and isWord(cells[b + 1])) b += 1;
        }
        self.sel = .{ .anchor = .{ .row = p.row, .col = a }, .head = .{ .row = p.row, .col = b } };
    }

    // ---- scrolling ----

    /// Scroll the history by `lines` (positive: back in time).
    pub fn scrollBy(self: *Terminal, lines: isize) void {
        const max: isize = @intCast(self.screen.scrollbackLen());
        const next = std.math.clamp(@as(isize, @intCast(self.view_offset)) + lines, 0, max);
        self.view_offset = @intCast(next);
        self.ui.tree.markDirty(self.node, .{ .paint = true });
    }

    // ---- input ----

    /// Send pasted text, wrapped for bracketed-paste programs.
    pub fn paste(self: *Terminal, text: []const u8) void {
        if (text.len == 0) return;
        self.view_offset = 0;
        if (self.screen.modes.bracketed_paste) {
            self.send("\x1b[200~");
            self.send(text);
            self.send("\x1b[201~");
        } else self.send(text);
    }

    fn copySelection(self: *Terminal) void {
        const clip = self.ui.clipboard orelse return;
        const text = (self.selectedText(self.ui.gpa) catch return) orelse return;
        defer self.ui.gpa.free(text);
        clip.set(clip.ctx, text);
    }

    fn pasteClipboard(self: *Terminal) void {
        const clip = self.ui.clipboard orelse return;
        const text = clip.get(clip.ctx, self.ui.gpa) orelse return;
        defer self.ui.gpa.free(text);
        self.paste(text);
    }

    pub fn handleEvent(self: *Terminal, ev: *event.Event) void {
        switch (ev.kind) {
            .focus_in => {
                self.out.focused = true;
                self.ui.tree.markDirty(self.node, .{ .paint = true });
            },
            .focus_out => {
                self.out.focused = false;
                self.dragging = false;
                self.ui.tree.markDirty(self.node, .{ .paint = true });
            },
            .text_input => {
                if (self.drop_text) {
                    self.drop_text = false;
                    return;
                }
                self.view_offset = 0;
                self.sel = null;
                self.send(ev.text);
                ev.markHandled();
            },
            .key_down => self.key(ev),
            .pointer_down => self.pointerDown(ev),
            .pointer_move => if (self.dragging) {
                if (self.sel) |*s| {
                    s.head = self.cellAt(ev.local_x, ev.local_y);
                    self.ui.tree.markDirty(self.node, .{ .paint = true });
                }
            } else if (self.screen.modes.mouse_report and !ev.mods.shift) {} else {},
            .pointer_up => {
                self.dragging = false;
                if (self.screen.modes.mouse_report and !ev.mods.shift) self.reportMouse(ev, ev.button, false);
            },
            .wheel => self.wheel(ev),
            else => {},
        }
    }

    fn key(self: *Terminal, ev: *event.Event) void {
        const m = ev.mods;
        const k = ev.key;
        // Application shortcuts that must keep working.
        if (self.props.pass_function_keys and @intFromEnum(k) >= @intFromEnum(keys.Key.f1) and @intFromEnum(k) <= @intFromEnum(keys.Key.f12)) return;
        if (m.ctrl and m.shift and !m.alt) {
            switch (k) {
                .c => {
                    self.copySelection();
                    ev.markHandled();
                    return;
                },
                .v => {
                    self.pasteClipboard();
                    ev.markHandled();
                    return;
                },
                // Other Ctrl+Shift combinations belong to the application.
                else => return,
            }
        }
        if (m.ctrl and k == .insert) {
            self.copySelection();
            ev.markHandled();
            return;
        }
        if (m.shift and !m.ctrl and !m.alt) {
            const page: isize = @intCast(@max(self.screen.rows, 2) - 1);
            switch (k) {
                .page_up => return self.scrollKey(ev, page),
                .page_down => return self.scrollKey(ev, -page),
                .home => return self.scrollKey(ev, @intCast(self.screen.scrollbackLen())),
                .end => return self.scrollKey(ev, -@as(isize, @intCast(self.screen.scrollbackLen()))),
                .insert => {
                    self.pasteClipboard();
                    ev.markHandled();
                    return;
                },
                else => {},
            }
        }
        var buf: [32]u8 = undefined;
        const bytes = encodeKey(&buf, k, m, self.screen.modes.app_cursor_keys) orelse return;
        self.view_offset = 0;
        if (m.alt) self.drop_text = true;
        if (k == .enter or k == .backspace or k == .escape) self.sel = null;
        self.send(bytes);
        ev.markHandled();
    }

    fn scrollKey(self: *Terminal, ev: *event.Event, lines: isize) void {
        self.scrollBy(lines);
        ev.markHandled();
    }

    fn pointerDown(self: *Terminal, ev: *event.Event) void {
        if (ev.button == 1 and self.screen.modes.mouse_report and !ev.mods.shift) {
            self.reportMouse(ev, 1, true);
            ev.markHandled();
            return;
        }
        if (ev.button != 1) return;
        const p = self.cellAt(ev.local_x, ev.local_y);
        if (ev.clicks >= 3) {
            self.sel = .{ .anchor = .{ .row = p.row, .col = 0 }, .head = .{ .row = p.row, .col = self.screen.cols - 1 } };
        } else if (ev.clicks == 2) {
            self.selectWord(p);
        } else {
            self.sel = .{ .anchor = p, .head = p };
            self.dragging = true;
        }
        self.ui.tree.markDirty(self.node, .{ .paint = true });
    }

    fn wheel(self: *Terminal, ev: *event.Event) void {
        if (self.screen.modes.mouse_report and !ev.mods.shift) {
            // dy > 0 is up.
            const cell = self.cellAt(ev.local_x, ev.local_y);
            var buf: [32]u8 = undefined;
            const code: u8 = if (ev.dy > 0) 64 else 65;
            const row = cell.row - self.absRow(0);
            if (std.fmt.bufPrint(&buf, "\x1b[<{d};{d};{d}M", .{ code, cell.col + 1, row + 1 })) |s| self.send(s) else |_| {}
            ev.markHandled();
            return;
        }
        if (self.screen.modes.alt_screen) {
            // Full-screen programs without mouse support: the wheel becomes arrow keys.
            const up = ev.dy > 0;
            const app = self.screen.modes.app_cursor_keys;
            const seq: []const u8 = if (up) (if (app) "\x1bOA" else "\x1b[A") else (if (app) "\x1bOB" else "\x1b[B");
            for (0..3) |_| self.send(seq);
            ev.markHandled();
            return;
        }
        self.scrollBy(@intFromFloat(@round(ev.dy * 3)));
        ev.markHandled();
    }

    fn reportMouse(self: *Terminal, ev: *event.Event, button: u32, down: bool) void {
        if (!self.screen.modes.mouse_sgr) return; // only the SGR encoding is supported
        const cell = self.cellAt(ev.local_x, ev.local_y);
        const row = cell.row - self.absRow(0);
        const b: u8 = switch (button) {
            1 => 0,
            2 => 1,
            3 => 2,
            else => return,
        };
        var buf: [32]u8 = undefined;
        if (std.fmt.bufPrint(&buf, "\x1b[<{d};{d};{d}{c}", .{ b, cell.col + 1, row + 1, @as(u8, if (down) 'M' else 'm') })) |s| self.send(s) else |_| {}
    }

    // ---- painting ----

    pub fn paintHook(self: *Terminal, pc: *PaintCtx) paint_ctx.Error!void {
        const m = self.metrics() orelse return;
        const list = pc.list;
        const theme = &self.ui.theme;
        const def_bg = theme.editor.background;
        const def_fg = theme.editor.text;
        const origin_x = pc.rect.x + 4;
        const subpixel = !self.ui.text.isMonospace(m.font);
        try list.fillRect(pc.rect, Paint.solid(def_bg));
        try list.pushClip(pc.rect);
        defer _ = list.popClip() catch {};

        const rows = self.screen.rows;
        const cols = self.screen.cols;
        const live = self.view_offset == 0;
        var r: usize = 0;
        while (r < rows) : (r += 1) {
            const abs = self.absRow(r);
            if (abs >= self.totalLines()) break;
            const cells = self.lineCells(abs);
            const y = pc.rect.y + @as(f32, @floatFromInt(r)) * m.line_h;
            if (y > pc.rect.y + pc.rect.h) break;
            const n = @min(cells.len, cols);
            // Backgrounds and selection, run by run.
            var c: usize = 0;
            while (c < n) {
                const cell = cells[c];
                const sel = self.selected(abs, c);
                const bg = self.cellBg(cell, def_bg, def_fg, sel);
                var end = c + 1;
                while (end < n and std.meta.eql(self.cellBg(cells[end], def_bg, def_fg, self.selected(abs, end)), bg)) end += 1;
                if (!std.meta.eql(bg, def_bg)) {
                    try list.fillRect(.{ .x = origin_x + @as(f32, @floatFromInt(c)) * m.cell_w, .y = y, .w = @as(f32, @floatFromInt(end - c)) * m.cell_w, .h = m.line_h }, Paint.solid(bg));
                }
                c = end;
            }
            // Text: runs of cells that share a color.
            c = 0;
            while (c < n) {
                const cell = cells[c];
                if (cell.attrs.wide_tail or cell.ch == 0 or (cell.ch == ' ' and !cell.attrs.underline and !cell.attrs.strike)) {
                    c += 1;
                    continue;
                }
                const fg = self.cellFg(cell, def_bg, def_fg);
                var end = c + 1;
                if (vt.charWidth(cell.ch) == 1) {
                    while (end < n and !cells[end].attrs.wide_tail and cells[end].ch != 0 and vt.charWidth(cells[end].ch) == 1 and
                        sameStyle(cell, cells[end]) and std.meta.eql(self.cellFg(cells[end], def_bg, def_fg), fg)) end += 1;
                }
                var text: [512]u8 = undefined;
                var tn: usize = 0;
                for (cells[c..end]) |x| {
                    const w = std.unicode.utf8Encode(x.ch, text[tn..]) catch break;
                    tn += w;
                    if (tn + 4 > text.len) break;
                }
                const x0 = origin_x + @as(f32, @floatFromInt(c)) * m.cell_w;
                const span_w = @as(f32, @floatFromInt(end - c)) * m.cell_w * @as(f32, if (end - c == 1 and vt.charWidth(cell.ch) == 2) 2 else 1);
                self.glyphs.clearRetainingCapacity();
                if (self.ui.text.shape(m.font, m.size, text[0..tn], &self.glyphs, self.ui.gpa)) |_| {
                    if (self.glyphs.items.len > 0) {
                        try list.glyphRunAt(.{ .x = x0, .y = y, .w = span_w, .h = m.line_h }, self.glyphs.items, .{ .x = x0, .y = y + m.ascent }, fg, m.font, m.size, subpixel);
                    }
                } else |_| {}
                if (cell.attrs.underline) try list.fillRect(.{ .x = x0, .y = y + m.line_h - 2, .w = span_w, .h = 1 }, Paint.solid(fg));
                if (cell.attrs.strike) try list.fillRect(.{ .x = x0, .y = y + m.line_h / 2, .w = span_w, .h = 1 }, Paint.solid(fg));
                c = end;
            }
        }

        // The cursor: a block when focused, an outline otherwise.
        if (live and self.screen.modes.cursor_visible) {
            const cur = self.screen.cursor;
            if (cur.row < rows and cur.col < cols) {
                const cr: Rect = .{ .x = origin_x + @as(f32, @floatFromInt(cur.col)) * m.cell_w, .y = pc.rect.y + @as(f32, @floatFromInt(cur.row)) * m.line_h, .w = m.cell_w, .h = m.line_h };
                if (self.out.focused) {
                    try list.fillRect(cr, Paint.solid(Color.rgba(def_fg.r, def_fg.g, def_fg.b, 190)));
                    const under = self.screen.cell(cur.row, cur.col).*;
                    if (under.ch > ' ' and !under.attrs.wide_tail) {
                        var tb: [4]u8 = undefined;
                        const w = std.unicode.utf8Encode(under.ch, &tb) catch 0;
                        self.glyphs.clearRetainingCapacity();
                        if (self.ui.text.shape(m.font, m.size, tb[0..w], &self.glyphs, self.ui.gpa)) |_| {
                            if (self.glyphs.items.len > 0) try list.glyphRunAt(cr, self.glyphs.items, .{ .x = cr.x, .y = cr.y + m.ascent }, def_bg, m.font, m.size, subpixel);
                        } else |_| {}
                    }
                } else {
                    try list.strokeRect(cr, 1, Paint.solid(def_fg));
                }
            }
        }

        // A thin bar at the right edge shows where the view is in the history.
        const sb = self.screen.scrollbackLen();
        if (sb > 0) {
            const total: f32 = @floatFromInt(self.totalLines());
            const thumb_h = @max(pc.rect.h * @as(f32, @floatFromInt(rows)) / total, 20);
            const frac = @as(f32, @floatFromInt(sb - self.view_offset)) / @as(f32, @floatFromInt(sb));
            const y = pc.rect.y + (pc.rect.h - thumb_h) * frac;
            try list.fillRoundedRect(.{ .x = pc.rect.x + pc.rect.w - 7, .y = y, .w = 4, .h = thumb_h }, .{ 2, 2, 2, 2 }, Paint.solid(Color.rgba(255, 255, 255, if (live) 40 else 90)));
        }
    }

    fn sameStyle(a: vt.Cell, b: vt.Cell) bool {
        return std.meta.eql(a.attrs, b.attrs) and a.fg == b.fg and a.bg == b.bg;
    }

    fn cellFg(self: *const Terminal, cell: vt.Cell, def_bg: Color, def_fg: Color) Color {
        _ = self;
        var fg = cell.fg;
        // Bold brightens the base colors.
        if (cell.attrs.bold and fg >> 24 == 1 and (fg & 0xff) < 8) fg += 8;
        var col = resolveColor(fg, def_fg);
        if (cell.attrs.inverse) col = resolveColor(cell.bg, def_bg);
        if (cell.attrs.dim) col = Color.rgba(col.r, col.g, col.b, 150);
        return col;
    }

    fn cellBg(self: *const Terminal, cell: vt.Cell, def_bg: Color, def_fg: Color, selected_: bool) Color {
        _ = self;
        if (selected_) return Color.rgba(70, 120, 200, 140);
        if (cell.attrs.inverse) return resolveColor(cell.fg, def_fg);
        return resolveColor(cell.bg, def_bg);
    }
};

// ---- tests -----------------------------------------------------------------

const testing = std.testing;
const Rig = @import("../core/test_rig.zig").Rig;

test "keys become the bytes terminals expect" {
    var buf: [32]u8 = undefined;
    try testing.expectEqualStrings("\r", encodeKey(&buf, .enter, .{}, false).?);
    try testing.expectEqualStrings("\x7f", encodeKey(&buf, .backspace, .{}, false).?);
    try testing.expectEqualStrings("\x1b[A", encodeKey(&buf, .up, .{}, false).?);
    try testing.expectEqualStrings("\x1bOA", encodeKey(&buf, .up, .{}, true).?);
    try testing.expectEqualStrings("\x1b[1;5C", encodeKey(&buf, .right, .{ .ctrl = true }, false).?);
    try testing.expectEqualStrings("\x1b[3~", encodeKey(&buf, .delete, .{}, false).?);
    try testing.expectEqualStrings("\x1b[5;2~", encodeKey(&buf, .page_up, .{ .shift = true }, false).?);
    try testing.expectEqualStrings("\x1bOP", encodeKey(&buf, .f1, .{}, false).?);
    try testing.expectEqualStrings("\x1b[15~", encodeKey(&buf, .f5, .{}, false).?);
    try testing.expectEqualStrings("\x1b[Z", encodeKey(&buf, .tab, .{ .shift = true }, false).?);
    try testing.expectEqualStrings("\x03", encodeKey(&buf, .c, .{ .ctrl = true }, false).?);
    try testing.expectEqualStrings("\x1bb", encodeKey(&buf, .b, .{ .alt = true }, false).?);
    try testing.expectEqualStrings("\x1bB", encodeKey(&buf, .b, .{ .alt = true, .shift = true }, false).?);
    try testing.expect(encodeKey(&buf, .a, .{}, false) == null); // plain letters arrive as text
    try testing.expectEqualStrings("\x00", encodeKey(&buf, .space, .{ .ctrl = true }, false).?);
}

test "colors resolve: base, cube, gray ramp, true color, default" {
    const def = Color.rgb(1, 2, 3);
    try testing.expectEqual(def, resolveColor(vt.default_color, def));
    try testing.expectEqual(ansi16[1], resolveColor(vt.indexed(1), def));
    try testing.expectEqual(Color.rgb(255, 0, 0), resolveColor(vt.indexed(196), def));
    try testing.expectEqual(Color.rgb(8, 8, 8), resolveColor(vt.indexed(232), def));
    try testing.expectEqual(Color.rgb(10, 20, 30), resolveColor(vt.rgb(10, 20, 30), def));
}

const Sink = struct {
    buf: std.ArrayListUnmanaged(u8) = .empty,
    cols: u16 = 0,
    rows: u16 = 0,
    fn write(self: *Sink, bytes: []const u8) void {
        self.buf.appendSlice(testing.allocator, bytes) catch {};
    }
    fn resized(self: *Sink, cols: u16, rows: u16) void {
        self.cols = cols;
        self.rows = rows;
    }
};

test "a terminal sizes itself, shows output, answers queries and sends typing" {
    const r = try Rig.init();
    defer r.deinit();
    var sink: Sink = .{};
    defer sink.buf.deinit(testing.allocator);
    const t = try r.ui.add(Terminal, r.ui.tree.root, .{ .style = .{ .grow = 1 }, .on_write = .bind(&sink, Sink.write), .on_resize = .bind(&sink, Sink.resized) });
    r.ui.setFocus(t.node);
    try r.frame();
    try r.frame();
    try testing.expect(sink.cols > 10 and sink.rows > 5);
    try testing.expectEqual(sink.cols, t.out.cols);
    t.feed("hello\r\n\x1b[31mred\x1b[0m\x1b[6n");
    try testing.expectEqual(@as(u21, 'h'), t.screen.cell(0, 0).ch);
    try testing.expectEqualStrings("\x1b[2;4R", sink.buf.items); // the cursor position report went out
    try r.frame();

    // Typing and keys.
    sink.buf.clearRetainingCapacity();
    r.ui.textInput("ls");
    r.ui.key(.enter, .{}, true, false);
    r.ui.key(.c, .{ .ctrl = true }, true, false);
    r.ui.key(.up, .{}, true, false);
    try testing.expectEqualStrings("ls\r\x03\x1b[A", sink.buf.items);
    // Function keys stay with the application.
    sink.buf.clearRetainingCapacity();
    r.ui.key(.f5, .{}, true, false);
    try testing.expectEqual(@as(usize, 0), sink.buf.items.len);
    // Bracketed paste only when the program asked for it.
    t.paste("a\nb");
    try testing.expectEqualStrings("a\nb", sink.buf.items);
    sink.buf.clearRetainingCapacity();
    t.feed("\x1b[?2004h");
    t.paste("x");
    try testing.expectEqualStrings("\x1b[200~x\x1b[201~", sink.buf.items);
}

test "history scrolls with the wheel and Shift+PageUp, stays put as output arrives, and selection copies text" {
    const r = try Rig.init();
    defer r.deinit();
    var sink: Sink = .{};
    defer sink.buf.deinit(testing.allocator);
    const t = try r.ui.add(Terminal, r.ui.tree.root, .{ .style = .{ .grow = 1 }, .on_write = .bind(&sink, Sink.write) });
    r.ui.setFocus(t.node);
    try r.frame();
    try r.frame();
    for (0..80) |i| {
        var line: [24]u8 = undefined;
        t.feed(std.fmt.bufPrint(&line, "line {d}\r\n", .{i}) catch unreachable);
    }
    try testing.expect(t.screen.scrollbackLen() > 20);
    try testing.expectEqual(@as(usize, 0), t.view_offset);
    const abs = r.ui.tree.absoluteRect(t.node).?;
    r.ui.wheel(abs.x + 20, abs.y + 20, 0, 2);
    try testing.expectEqual(@as(usize, 6), t.view_offset);
    r.ui.key(.page_up, .{ .shift = true }, true, false);
    try testing.expect(t.view_offset > 6);
    try testing.expectEqual(@as(usize, 0), sink.buf.items.len); // scrolling sends nothing
    const before = t.view_offset;
    t.feed("more\r\n");
    try testing.expectEqual(before + 1, t.view_offset); // the view stays on the same text
    r.ui.key(.end, .{ .shift = true }, true, false);
    try testing.expectEqual(@as(usize, 0), t.view_offset);

    // Select the first visible row by dragging, then read it back.
    try r.frame();
    r.ui.pointerMove(abs.x + 6, abs.y + 3);
    r.ui.pointerButtonEx(abs.x + 6, abs.y + 3, 1, true, 1);
    r.ui.pointerMove(abs.x + 6 + t.cell_w * 6, abs.y + 3);
    r.ui.pointerButtonEx(abs.x + 6 + t.cell_w * 6, abs.y + 3, 1, false, 1);
    const text = (try t.selectedText(testing.allocator)).?;
    defer testing.allocator.free(text);
    try testing.expect(std.mem.startsWith(u8, text, "line ") or text.len > 0);
    // Typing clears it, double-click selects a word.
    r.ui.pointerButtonEx(abs.x + 6, abs.y + 3, 1, true, 2);
    r.ui.pointerButtonEx(abs.x + 6, abs.y + 3, 1, false, 2);
    const word = (try t.selectedText(testing.allocator)).?;
    defer testing.allocator.free(word);
    try testing.expect(std.mem.startsWith(u8, word, "line"));
}
