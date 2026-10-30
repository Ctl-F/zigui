//! A terminal emulator's screen: it takes the bytes a program writes to a
//! terminal (text, control characters, escape sequences) and keeps the grid of
//! characters those bytes produce. No UI and no process here; the `Terminal`
//! widget draws a `Screen` and `ide/terminal_panel.zig` connects it to a shell.
//!
//!     var s = try Screen.init(gpa, 80, 24);
//!     defer s.deinit();
//!     try s.write("hello\r\n\x1b[31mred\x1b[0m");
//!     s.cell(0, 0).ch;            // 'h'
//!     s.takeReply();              // bytes to send back to the program (cursor reports...)
//!
//! Understood: UTF-8 text with wide (CJK, emoji) characters; BS, HT, LF, CR, BEL;
//! cursor movement and positioning, erase and insert/delete of characters and
//! lines, scroll regions and scrolling; SGR (16, 256 and true colors, bold, dim,
//! italic, underline, inverse, strikethrough); the alternate screen (vim, less);
//! save/restore cursor; tab stops; cursor-key, bracketed-paste, autowrap and
//! cursor-visibility modes; window titles (OSC 0 and 2); device and cursor
//! position reports. Output that scrolls off the top of the main screen goes to
//! a scrollback buffer.

const std = @import("std");

/// A color: 0 is "the default", otherwise an indexed (0-255) or RGB value.
pub const Color = u32;

pub fn indexed(i: u8) Color {
    return 0x01000000 | @as(u32, i);
}

pub fn rgb(r: u8, g: u8, b: u8) Color {
    return 0x02000000 | (@as(u32, r) << 16) | (@as(u32, g) << 8) | b;
}

pub const default_color: Color = 0;

pub const Attrs = packed struct(u8) {
    bold: bool = false,
    dim: bool = false,
    italic: bool = false,
    underline: bool = false,
    inverse: bool = false,
    strike: bool = false,
    /// The right half of a wide character (its `ch` is 0).
    wide_tail: bool = false,
    _pad: bool = false,
};

pub const Cell = struct {
    ch: u21 = ' ',
    fg: Color = default_color,
    bg: Color = default_color,
    attrs: Attrs = .{},
};

pub const Modes = struct {
    /// Wrap at the right edge (DECAWM).
    autowrap: bool = true,
    cursor_visible: bool = true,
    /// Arrow keys send `ESC O A` instead of `ESC [ A`.
    app_cursor_keys: bool = false,
    /// Pasted text is wrapped in `ESC [200~` ... `ESC [201~`.
    bracketed_paste: bool = false,
    /// The alternate screen is showing.
    alt_screen: bool = false,
    /// Programs asked for mouse reports (1000/1002/1003, SGR 1006).
    mouse_report: bool = false,
    mouse_sgr: bool = false,
};

const State = enum { ground, escape, escape_inter, csi, osc, osc_esc, string };

const max_params = 16;

pub const Screen = struct {
    gpa: std.mem.Allocator,
    cols: usize,
    rows: usize,
    cells: []Cell,
    /// The main screen while the alternate one shows (empty otherwise).
    saved_cells: []Cell = &.{},
    saved_cursor_main: Cursor = .{},
    cursor: Cursor = .{},
    saved: Cursor = .{},
    attrs: Attrs = .{},
    fg: Color = default_color,
    bg: Color = default_color,
    top: usize = 0,
    bottom: usize,
    tabs: []bool,
    modes: Modes = .{},
    title: std.ArrayListUnmanaged(u8) = .empty,
    /// Bumped whenever anything visible changes.
    version: u64 = 0,
    bell: bool = false,
    reply: std.ArrayListUnmanaged(u8) = .empty,

    // scrollback (a ring of lines, oldest first)
    sb: std.ArrayListUnmanaged([]Cell) = .empty,
    sb_start: usize = 0,
    max_scrollback: usize = 5000,
    /// Lines that left the scrollback because it was full (lets a selection follow the text).
    sb_evicted: u64 = 0,

    // parser
    state: State = .ground,
    params: [max_params]u32 = @splat(0),
    param_n: usize = 0,
    param_open: bool = false,
    private: u8 = 0,
    inter: u8 = 0,
    osc: std.ArrayListUnmanaged(u8) = .empty,
    utf8: [4]u8 = undefined,
    utf8_have: u3 = 0,
    utf8_need: u3 = 0,

    pub const Cursor = struct { row: usize = 0, col: usize = 0, wrap: bool = false };

    pub fn init(gpa: std.mem.Allocator, cols: usize, rows: usize) !Screen {
        const c = @max(cols, 1);
        const r = @max(rows, 1);
        const cells = try gpa.alloc(Cell, c * r);
        errdefer gpa.free(cells);
        @memset(cells, .{});
        const tabs = try gpa.alloc(bool, c);
        for (tabs, 0..) |*t, i| t.* = i % 8 == 0 and i > 0;
        return .{ .gpa = gpa, .cols = c, .rows = r, .cells = cells, .bottom = r - 1, .tabs = tabs };
    }

    pub fn deinit(self: *Screen) void {
        self.gpa.free(self.cells);
        if (self.saved_cells.len > 0) self.gpa.free(self.saved_cells);
        self.gpa.free(self.tabs);
        self.title.deinit(self.gpa);
        self.reply.deinit(self.gpa);
        self.osc.deinit(self.gpa);
        for (self.sb.items) |l| self.gpa.free(l);
        self.sb.deinit(self.gpa);
    }

    pub fn cell(self: *const Screen, row: usize, col: usize) *Cell {
        return &self.cells[row * self.cols + col];
    }

    fn line(self: *Screen, row: usize) []Cell {
        return self.cells[row * self.cols ..][0..self.cols];
    }

    pub fn titleText(self: *const Screen) []const u8 {
        return self.title.items;
    }

    /// Bytes the program is owed (answers to queries); the caller clears them with `clearReply`.
    pub fn takeReply(self: *const Screen) []const u8 {
        return self.reply.items;
    }

    pub fn clearReply(self: *Screen) void {
        self.reply.clearRetainingCapacity();
    }

    // ---- scrollback ----

    pub fn scrollbackLen(self: *const Screen) usize {
        return self.sb.items.len;
    }

    /// Line `i` of the scrollback, 0 being the oldest.
    pub fn scrollbackLine(self: *const Screen, i: usize) []const Cell {
        return self.sb.items[(self.sb_start + i) % self.sb.items.len];
    }

    fn pushScrollback(self: *Screen, src: []const Cell) void {
        if (self.max_scrollback == 0 or self.modes.alt_screen) return;
        if (self.sb.items.len < self.max_scrollback) {
            const copy = self.gpa.dupe(Cell, src) catch return;
            self.sb.append(self.gpa, copy) catch {
                self.gpa.free(copy);
            };
            return;
        }
        // Full: reuse the oldest line's storage.
        self.sb_evicted +%= 1;
        const slot = &self.sb.items[self.sb_start];
        if (slot.len != src.len) {
            self.gpa.free(slot.*);
            slot.* = self.gpa.dupe(Cell, src) catch {
                slot.* = &.{};
                return;
            };
        } else @memcpy(slot.*, src);
        self.sb_start = (self.sb_start + 1) % self.sb.items.len;
    }

    // ---- editing primitives ----

    fn blank(self: *const Screen) Cell {
        return .{ .ch = ' ', .bg = self.bg };
    }

    fn clearRange(self: *Screen, row: usize, from: usize, to: usize) void {
        const b = self.blank();
        for (self.line(row)[from..to]) |*c| c.* = b;
    }

    /// Scroll the region [top, bottom] up by one line (the top line leaves).
    fn scrollUp(self: *Screen, n: usize) void {
        const region = self.bottom - self.top + 1;
        const count = @min(n, region);
        for (0..count) |_| {
            if (self.top == 0 and !self.modes.alt_screen) self.pushScrollback(self.line(0));
            const dst = self.cells[self.top * self.cols .. (self.bottom) * self.cols];
            const src = self.cells[(self.top + 1) * self.cols .. (self.bottom + 1) * self.cols];
            std.mem.copyForwards(Cell, dst, src);
            self.clearRange(self.bottom, 0, self.cols);
        }
        self.version +%= 1;
    }

    fn scrollDown(self: *Screen, n: usize) void {
        const region = self.bottom - self.top + 1;
        const count = @min(n, region);
        for (0..count) |_| {
            var r = self.bottom;
            while (r > self.top) : (r -= 1) {
                std.mem.copyForwards(Cell, self.line(r), self.line(r - 1));
            }
            self.clearRange(self.top, 0, self.cols);
        }
        self.version +%= 1;
    }

    fn lineFeed(self: *Screen) void {
        if (self.cursor.row == self.bottom) {
            self.scrollUp(1);
        } else if (self.cursor.row + 1 < self.rows) {
            self.cursor.row += 1;
        }
        self.cursor.wrap = false;
    }

    fn reverseIndex(self: *Screen) void {
        if (self.cursor.row == self.top) {
            self.scrollDown(1);
        } else if (self.cursor.row > 0) {
            self.cursor.row -= 1;
        }
        self.cursor.wrap = false;
    }

    fn putChar(self: *Screen, ch: u21) void {
        const w = charWidth(ch);
        if (w == 0) return;
        if (self.cursor.wrap and self.modes.autowrap) {
            self.cursor.col = 0;
            self.lineFeed();
        }
        if (w == 2 and self.cursor.col + 1 >= self.cols) {
            // Not enough room for both halves: wrap first.
            if (self.modes.autowrap) {
                self.clearRange(self.cursor.row, self.cursor.col, self.cols);
                self.cursor.col = 0;
                self.lineFeed();
            } else return;
        }
        const row = self.cursor.row;
        const col = self.cursor.col;
        // Overwriting half of a wide character blanks its other half.
        self.breakWide(row, col);
        self.line(row)[col] = .{ .ch = ch, .fg = self.fg, .bg = self.bg, .attrs = self.attrs };
        if (w == 2) {
            self.breakWide(row, col + 1);
            var tail_attrs = self.attrs;
            tail_attrs.wide_tail = true;
            self.line(row)[col + 1] = .{ .ch = 0, .fg = self.fg, .bg = self.bg, .attrs = tail_attrs };
        }
        const next = col + w;
        if (next >= self.cols) {
            self.cursor.col = self.cols - 1;
            self.cursor.wrap = true;
        } else {
            self.cursor.col = next;
            self.cursor.wrap = false;
        }
        self.version +%= 1;
    }

    fn breakWide(self: *Screen, row: usize, col: usize) void {
        const l = self.line(row);
        if (l[col].attrs.wide_tail and col > 0) l[col - 1] = self.blank();
        if (col + 1 < self.cols and l[col + 1].attrs.wide_tail) l[col + 1] = self.blank();
    }

    // ---- alternate screen ----

    fn enterAlt(self: *Screen) void {
        if (self.modes.alt_screen) return;
        const copy = self.gpa.dupe(Cell, self.cells) catch return;
        self.saved_cells = copy;
        self.saved_cursor_main = self.cursor;
        self.modes.alt_screen = true;
        @memset(self.cells, self.blank());
        self.cursor = .{};
        self.version +%= 1;
    }

    fn leaveAlt(self: *Screen) void {
        if (!self.modes.alt_screen) return;
        self.modes.alt_screen = false;
        if (self.saved_cells.len == self.cells.len) @memcpy(self.cells, self.saved_cells);
        if (self.saved_cells.len > 0) self.gpa.free(self.saved_cells);
        self.saved_cells = &.{};
        self.cursor = self.saved_cursor_main;
        self.version +%= 1;
    }

    // ---- resizing ----

    /// Change the grid size. Content stays anchored at the top; if the cursor
    /// would fall off the bottom, lines move into the scrollback.
    pub fn resize(self: *Screen, cols: usize, rows: usize) !void {
        const nc = @max(cols, 1);
        const nr = @max(rows, 1);
        if (nc == self.cols and nr == self.rows) return;
        if (self.modes.alt_screen) {
            // Programs on the alternate screen redraw after a resize anyway.
            self.leaveAlt();
        }
        // Lines the cursor would lose off the bottom go to the scrollback.
        var drop: usize = 0;
        if (self.cursor.row >= nr) drop = self.cursor.row - nr + 1;
        for (0..drop) |r| self.pushScrollback(self.line(r));
        const cells = try self.gpa.alloc(Cell, nc * nr);
        @memset(cells, .{});
        const copy_rows = @min(self.rows - drop, nr);
        const copy_cols = @min(self.cols, nc);
        for (0..copy_rows) |r| {
            @memcpy(cells[r * nc ..][0..copy_cols], self.cells[(r + drop) * self.cols ..][0..copy_cols]);
        }
        self.gpa.free(self.cells);
        self.cells = cells;
        const tabs = try self.gpa.alloc(bool, nc);
        for (tabs, 0..) |*t, i| t.* = i % 8 == 0 and i > 0;
        self.gpa.free(self.tabs);
        self.tabs = tabs;
        self.cols = nc;
        self.rows = nr;
        self.cursor.row = @min(self.cursor.row -| drop, nr - 1);
        self.cursor.col = @min(self.cursor.col, nc - 1);
        self.cursor.wrap = false;
        self.top = 0;
        self.bottom = nr - 1;
        self.version +%= 1;
    }

    // ---- input ----

    /// Feed bytes the program wrote.
    pub fn write(self: *Screen, bytes: []const u8) !void {
        for (bytes) |b| try self.byte(b);
    }

    fn byte(self: *Screen, b: u8) !void {
        switch (self.state) {
            .ground => try self.ground(b),
            .escape => self.escapeByte(b),
            .escape_inter => {
                // `ESC ( B` and friends: one more byte designates a charset.
                self.state = .ground;
            },
            .csi => self.csiByte(b),
            .osc => {
                if (b == 0x07) {
                    self.oscEnd();
                } else if (b == 0x1b) {
                    self.state = .osc_esc;
                } else if (self.osc.items.len < 4096) try self.osc.append(self.gpa, b);
            },
            .osc_esc => {
                // ESC \ ends the string; anything else abandons it.
                if (b == '\\') self.oscEnd() else self.state = .ground;
            },
            .string => {
                if (b == 0x1b) self.state = .osc_esc else if (b == 0x07) self.state = .ground;
            },
        }
    }

    fn ground(self: *Screen, b: u8) !void {
        if (self.utf8_need > 0) {
            if (b & 0xC0 == 0x80) {
                self.utf8[self.utf8_have] = b;
                self.utf8_have += 1;
                if (self.utf8_have == self.utf8_need) {
                    const cp = std.unicode.utf8Decode(self.utf8[0..self.utf8_need]) catch 0xFFFD;
                    self.utf8_need = 0;
                    self.utf8_have = 0;
                    self.putChar(cp);
                }
                return;
            }
            // A broken sequence: show a replacement and handle this byte fresh.
            self.utf8_need = 0;
            self.utf8_have = 0;
            self.putChar(0xFFFD);
        }
        switch (b) {
            0x1b => self.state = .escape,
            0x07 => self.bell = true,
            0x08 => {
                if (self.cursor.col > 0) self.cursor.col -= 1;
                self.cursor.wrap = false;
            },
            0x09 => {
                var c = self.cursor.col + 1;
                while (c < self.cols - 1 and !self.tabs[c]) c += 1;
                self.cursor.col = @min(c, self.cols - 1);
                self.cursor.wrap = false;
            },
            0x0a, 0x0b, 0x0c => self.lineFeed(),
            0x0d => {
                self.cursor.col = 0;
                self.cursor.wrap = false;
            },
            0x00...0x06, 0x0e...0x1a, 0x1c...0x1f, 0x7f => {},
            0x20...0x7e => self.putChar(b),
            else => {
                if (b & 0xE0 == 0xC0) {
                    self.utf8_need = 2;
                } else if (b & 0xF0 == 0xE0) {
                    self.utf8_need = 3;
                } else if (b & 0xF8 == 0xF0) {
                    self.utf8_need = 4;
                } else {
                    self.putChar(0xFFFD);
                    return;
                }
                self.utf8[0] = b;
                self.utf8_have = 1;
            },
        }
    }

    fn escapeByte(self: *Screen, b: u8) void {
        self.state = .ground;
        switch (b) {
            '[' => {
                self.state = .csi;
                self.params = @splat(0);
                self.param_n = 0;
                self.param_open = false;
                self.private = 0;
                self.inter = 0;
            },
            ']' => {
                self.state = .osc;
                self.osc.clearRetainingCapacity();
            },
            'P', 'X', '^', '_' => {
                self.state = .string;
                self.osc.clearRetainingCapacity();
            },
            '(', ')', '*', '+', '#', '%' => self.state = .escape_inter,
            '7' => self.saved = self.cursor,
            '8' => {
                self.cursor = self.saved;
                self.cursor.row = @min(self.cursor.row, self.rows - 1);
                self.cursor.col = @min(self.cursor.col, self.cols - 1);
            },
            'D' => self.lineFeed(),
            'E' => {
                self.cursor.col = 0;
                self.lineFeed();
            },
            'M' => self.reverseIndex(),
            'H' => self.tabs[self.cursor.col] = true,
            'c' => self.reset(),
            else => {},
        }
    }

    fn reset(self: *Screen) void {
        self.leaveAlt();
        self.attrs = .{};
        self.fg = default_color;
        self.bg = default_color;
        self.modes = .{};
        self.top = 0;
        self.bottom = self.rows - 1;
        @memset(self.cells, .{});
        self.cursor = .{};
        self.saved = .{};
        self.version +%= 1;
    }

    fn param(self: *const Screen, i: usize, default: u32) u32 {
        if (i >= self.param_n) return default;
        const v = self.params[i];
        return if (v == 0) default else v;
    }

    fn csiByte(self: *Screen, b: u8) void {
        switch (b) {
            '0'...'9' => {
                if (self.param_n == 0) self.param_n = 1;
                const i = self.param_n - 1;
                self.params[i] = @min(self.params[i] *| 10 +| (b - '0'), 1_000_000);
                self.param_open = true;
            },
            ';', ':' => {
                if (self.param_n == 0) self.param_n = 1;
                if (self.param_n < max_params) self.param_n += 1;
                self.param_open = false;
            },
            '?', '>', '<', '=' => self.private = b,
            ' ', '!', '"', '#', '$', '\'', '*' => self.inter = b,
            0x40...0x7e => {
                self.state = .ground;
                self.csi(b);
            },
            0x1b => self.state = .escape,
            else => {},
        }
    }

    fn csi(self: *Screen, final: u8) void {
        const n1 = self.param(0, 1);
        switch (final) {
            'A' => self.moveTo(@as(isize, @intCast(self.cursor.row)) - @as(isize, @intCast(n1)), null, true),
            'B', 'e' => self.moveTo(@as(isize, @intCast(self.cursor.row)) + @as(isize, @intCast(n1)), null, true),
            'C', 'a' => self.moveTo(null, @as(isize, @intCast(self.cursor.col)) + @as(isize, @intCast(n1)), false),
            'D' => self.moveTo(null, @as(isize, @intCast(self.cursor.col)) - @as(isize, @intCast(n1)), false),
            'E' => {
                self.moveTo(@as(isize, @intCast(self.cursor.row)) + @as(isize, @intCast(n1)), 0, true);
            },
            'F' => self.moveTo(@as(isize, @intCast(self.cursor.row)) - @as(isize, @intCast(n1)), 0, true),
            'G', '`' => self.moveTo(null, @as(isize, @intCast(n1)) - 1, false),
            'd' => self.moveTo(@as(isize, @intCast(n1)) - 1, null, false),
            'H', 'f' => self.moveTo(@as(isize, @intCast(self.param(0, 1))) - 1, @as(isize, @intCast(self.param(1, 1))) - 1, false),
            'J' => self.eraseDisplay(if (self.param_n == 0) 0 else self.params[0]),
            'K' => self.eraseLine(if (self.param_n == 0) 0 else self.params[0]),
            'L' => self.insertLines(n1),
            'M' => self.deleteLines(n1),
            '@' => self.insertChars(n1),
            'P' => self.deleteChars(n1),
            'X' => {
                const end = @min(self.cursor.col + n1, self.cols);
                self.clearRange(self.cursor.row, self.cursor.col, end);
                self.version +%= 1;
            },
            'S' => self.scrollUp(n1),
            'T' => self.scrollDown(n1),
            'm' => self.sgr(),
            'r' => {
                const t = self.param(0, 1) - 1;
                const bt = @min(self.param(1, @intCast(self.rows)), @as(u32, @intCast(self.rows))) - 1;
                if (t < bt) {
                    self.top = t;
                    self.bottom = bt;
                    self.cursor = .{};
                }
            },
            's' => self.saved = self.cursor,
            'u' => {
                self.cursor = self.saved;
                self.cursor.row = @min(self.cursor.row, self.rows - 1);
                self.cursor.col = @min(self.cursor.col, self.cols - 1);
            },
            'g' => {
                if (self.param_n == 0 or self.params[0] == 0) {
                    self.tabs[self.cursor.col] = false;
                } else if (self.params[0] == 3) @memset(self.tabs, false);
            },
            'h' => self.setMode(true),
            'l' => self.setMode(false),
            'n' => {
                if (self.private == 0) {
                    if (self.param(0, 0) == 6) {
                        var buf: [32]u8 = undefined;
                        const s = std.fmt.bufPrint(&buf, "\x1b[{d};{d}R", .{ self.cursor.row + 1, self.cursor.col + 1 }) catch return;
                        self.reply.appendSlice(self.gpa, s) catch {};
                    } else if (self.param(0, 0) == 5) self.reply.appendSlice(self.gpa, "\x1b[0n") catch {};
                }
            },
            'c' => {
                if (self.private == 0) {
                    self.reply.appendSlice(self.gpa, "\x1b[?62;22c") catch {};
                } else if (self.private == '>') self.reply.appendSlice(self.gpa, "\x1b[>0;0;0c") catch {};
            },
            else => {},
        }
    }

    fn moveTo(self: *Screen, row: ?isize, col: ?isize, keep_col: bool) void {
        _ = keep_col;
        if (row) |r| {
            const lo: isize = 0;
            const hi: isize = @intCast(self.rows - 1);
            self.cursor.row = @intCast(std.math.clamp(r, lo, hi));
        }
        if (col) |c| {
            const hi: isize = @intCast(self.cols - 1);
            self.cursor.col = @intCast(std.math.clamp(c, 0, hi));
        }
        self.cursor.wrap = false;
    }

    fn eraseDisplay(self: *Screen, mode: u32) void {
        const row = self.cursor.row;
        switch (mode) {
            0 => {
                self.clearRange(row, self.cursor.col, self.cols);
                for (row + 1..self.rows) |r| self.clearRange(r, 0, self.cols);
            },
            1 => {
                for (0..row) |r| self.clearRange(r, 0, self.cols);
                self.clearRange(row, 0, @min(self.cursor.col + 1, self.cols));
            },
            2 => for (0..self.rows) |r| self.clearRange(r, 0, self.cols),
            3 => {
                for (self.sb.items) |l| self.gpa.free(l);
                self.sb.clearRetainingCapacity();
                self.sb_start = 0;
            },
            else => {},
        }
        self.version +%= 1;
    }

    fn eraseLine(self: *Screen, mode: u32) void {
        const row = self.cursor.row;
        switch (mode) {
            0 => self.clearRange(row, self.cursor.col, self.cols),
            1 => self.clearRange(row, 0, @min(self.cursor.col + 1, self.cols)),
            2 => self.clearRange(row, 0, self.cols),
            else => {},
        }
        self.version +%= 1;
    }

    fn insertLines(self: *Screen, n: usize) void {
        if (self.cursor.row < self.top or self.cursor.row > self.bottom) return;
        const saved_top = self.top;
        self.top = self.cursor.row;
        self.scrollDown(n);
        self.top = saved_top;
        self.cursor.col = 0;
    }

    fn deleteLines(self: *Screen, n: usize) void {
        if (self.cursor.row < self.top or self.cursor.row > self.bottom) return;
        const saved_top = self.top;
        const was_alt = self.modes.alt_screen;
        self.top = self.cursor.row;
        // Deleted lines are gone, not scrolled into history.
        self.modes.alt_screen = true;
        self.scrollUp(n);
        self.modes.alt_screen = was_alt;
        self.top = saved_top;
        self.cursor.col = 0;
    }

    fn insertChars(self: *Screen, n: usize) void {
        const l = self.line(self.cursor.row);
        const c = self.cursor.col;
        const count = @min(n, self.cols - c);
        std.mem.copyBackwards(Cell, l[c + count ..], l[c .. self.cols - count]);
        self.clearRange(self.cursor.row, c, c + count);
        self.version +%= 1;
    }

    fn deleteChars(self: *Screen, n: usize) void {
        const l = self.line(self.cursor.row);
        const c = self.cursor.col;
        const count = @min(n, self.cols - c);
        std.mem.copyForwards(Cell, l[c .. self.cols - count], l[c + count ..]);
        self.clearRange(self.cursor.row, self.cols - count, self.cols);
        self.version +%= 1;
    }

    fn setMode(self: *Screen, on: bool) void {
        if (self.private != '?') return;
        for (0..@max(self.param_n, 1)) |i| {
            switch (self.params[i]) {
                1 => self.modes.app_cursor_keys = on,
                7 => self.modes.autowrap = on,
                25 => self.modes.cursor_visible = on,
                47, 1047, 1049 => if (on) {
                    if (self.params[i] == 1049) self.saved = self.cursor;
                    self.enterAlt();
                } else {
                    self.leaveAlt();
                    if (self.params[i] == 1049) self.cursor = self.saved;
                },
                1000, 1002, 1003 => self.modes.mouse_report = on,
                1006 => self.modes.mouse_sgr = on,
                2004 => self.modes.bracketed_paste = on,
                else => {},
            }
        }
        self.version +%= 1;
    }

    fn sgr(self: *Screen) void {
        if (self.param_n == 0) {
            self.resetSgr();
            return;
        }
        var i: usize = 0;
        while (i < self.param_n) : (i += 1) {
            const p = self.params[i];
            switch (p) {
                0 => self.resetSgr(),
                1 => self.attrs.bold = true,
                2 => self.attrs.dim = true,
                3 => self.attrs.italic = true,
                4 => self.attrs.underline = true,
                7 => self.attrs.inverse = true,
                9 => self.attrs.strike = true,
                22 => {
                    self.attrs.bold = false;
                    self.attrs.dim = false;
                },
                23 => self.attrs.italic = false,
                24 => self.attrs.underline = false,
                27 => self.attrs.inverse = false,
                29 => self.attrs.strike = false,
                30...37 => self.fg = indexed(@intCast(p - 30)),
                38, 48 => {
                    const target = p == 38;
                    if (i + 1 < self.param_n and self.params[i + 1] == 5 and i + 2 < self.param_n) {
                        const c = indexed(@intCast(@min(self.params[i + 2], 255)));
                        if (target) self.fg = c else self.bg = c;
                        i += 2;
                    } else if (i + 1 < self.param_n and self.params[i + 1] == 2 and i + 4 < self.param_n) {
                        const c = rgb(@intCast(@min(self.params[i + 2], 255)), @intCast(@min(self.params[i + 3], 255)), @intCast(@min(self.params[i + 4], 255)));
                        if (target) self.fg = c else self.bg = c;
                        i += 4;
                    }
                },
                39 => self.fg = default_color,
                40...47 => self.bg = indexed(@intCast(p - 40)),
                49 => self.bg = default_color,
                90...97 => self.fg = indexed(@intCast(p - 90 + 8)),
                100...107 => self.bg = indexed(@intCast(p - 100 + 8)),
                else => {},
            }
        }
    }

    fn resetSgr(self: *Screen) void {
        self.attrs = .{};
        self.fg = default_color;
        self.bg = default_color;
    }

    fn oscEnd(self: *Screen) void {
        self.state = .ground;
        const s = self.osc.items;
        const semi = std.mem.indexOfScalar(u8, s, ';') orelse return;
        const code = std.fmt.parseInt(u32, s[0..semi], 10) catch return;
        if (code == 0 or code == 2) {
            self.title.clearRetainingCapacity();
            self.title.appendSlice(self.gpa, s[semi + 1 ..]) catch {};
            self.version +%= 1;
        }
    }

    // ---- reading text ----

    /// The text of row `row` (trailing blanks trimmed) into `out`.
    pub fn rowText(self: *const Screen, row: usize, out: *std.ArrayListUnmanaged(u8), gpa: std.mem.Allocator) !void {
        try appendCells(self.cells[row * self.cols ..][0..self.cols], out, gpa);
    }
};

/// Append `cells` as text, dropping trailing blanks and wide-character tails.
pub fn appendCells(cells: []const Cell, out: *std.ArrayListUnmanaged(u8), gpa: std.mem.Allocator) !void {
    var end = cells.len;
    while (end > 0 and cells[end - 1].ch == ' ' and !cells[end - 1].attrs.wide_tail) end -= 1;
    for (cells[0..end]) |c| {
        if (c.attrs.wide_tail) continue;
        var buf: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(if (c.ch == 0) ' ' else c.ch, &buf) catch continue;
        try out.appendSlice(gpa, buf[0..n]);
    }
}

/// Columns a character takes: 0 (combining), 1, or 2 (wide).
pub fn charWidth(cp: u21) u2 {
    if (cp < 0x300) return 1;
    if ((cp >= 0x300 and cp <= 0x36F) or (cp >= 0x200B and cp <= 0x200F) or (cp >= 0xFE00 and cp <= 0xFE0F) or cp == 0x20E3) return 0;
    if ((cp >= 0x1100 and cp <= 0x115F) or
        (cp >= 0x2E80 and cp <= 0xA4CF) or
        (cp >= 0xAC00 and cp <= 0xD7A3) or
        (cp >= 0xF900 and cp <= 0xFAFF) or
        (cp >= 0xFE30 and cp <= 0xFE6F) or
        (cp >= 0xFF00 and cp <= 0xFF60) or
        (cp >= 0xFFE0 and cp <= 0xFFE6) or
        (cp >= 0x1F300 and cp <= 0x1F64F) or
        (cp >= 0x1F900 and cp <= 0x1F9FF) or
        (cp >= 0x20000 and cp <= 0x3FFFD)) return 2;
    return 1;
}

// ---- tests -----------------------------------------------------------------

const testing = std.testing;

fn rowStr(s: *const Screen, row: usize) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(testing.allocator);
    try s.rowText(row, &out, testing.allocator);
    return out.toOwnedSlice(testing.allocator);
}

fn expectRow(s: *const Screen, row: usize, want: []const u8) !void {
    const got = try rowStr(s, row);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(want, got);
}

test "text, newlines, carriage returns, backspace and tabs" {
    var s = try Screen.init(testing.allocator, 20, 5);
    defer s.deinit();
    try s.write("hello\r\nworld\x08\x08x\ttab");
    try expectRow(&s, 0, "hello");
    try expectRow(&s, 1, "worxd   tab");
    try testing.expectEqual(@as(usize, 1), s.cursor.row);
    try testing.expectEqual(@as(usize, 11), s.cursor.col);
}

test "autowrap and scrolling push the top line into the scrollback" {
    var s = try Screen.init(testing.allocator, 4, 2);
    defer s.deinit();
    try s.write("abcdefghij");
    try expectRow(&s, 0, "efgh");
    try expectRow(&s, 1, "ij");
    try testing.expectEqual(@as(usize, 1), s.scrollbackLen());
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(testing.allocator);
    try appendCells(s.scrollbackLine(0), &out, testing.allocator);
    try testing.expectEqualStrings("abcd", out.items);
    // With wrap off, text stops at the edge.
    try s.write("\x1b[?7l\x1b[1;1Hxyzzy");
    try expectRow(&s, 0, "xyzy");
}

test "cursor movement, positioning and erase" {
    var s = try Screen.init(testing.allocator, 10, 4);
    defer s.deinit();
    try s.write("\x1b[2;3Hab\x1b[Aup\x1b[2Bdn");
    try expectRow(&s, 0, "    up");
    try expectRow(&s, 1, "  ab");
    try expectRow(&s, 2, "      dn");
    try expectRow(&s, 3, "");
    try s.write("\x1b[2;1H\x1b[K\x1b[1;1H\x1b[2K");
    try expectRow(&s, 0, "");
    try expectRow(&s, 1, "");
    try s.write("\x1b[2J");
    try expectRow(&s, 3, "");
    try s.write("\x1b[3;4Hq\x1b[1J");
    try expectRow(&s, 2, "");
}

test "colors and attributes" {
    var s = try Screen.init(testing.allocator, 20, 2);
    defer s.deinit();
    try s.write("\x1b[1;31mR\x1b[0mn\x1b[38;5;200mX\x1b[48;2;1;2;3mY\x1b[39;49;4mZ");
    try testing.expectEqual(indexed(1), s.cell(0, 0).fg);
    try testing.expect(s.cell(0, 0).attrs.bold);
    try testing.expectEqual(default_color, s.cell(0, 1).fg);
    try testing.expect(!s.cell(0, 1).attrs.bold);
    try testing.expectEqual(indexed(200), s.cell(0, 2).fg);
    try testing.expectEqual(rgb(1, 2, 3), s.cell(0, 3).bg);
    try testing.expectEqual(indexed(200), s.cell(0, 3).fg);
    try testing.expectEqual(default_color, s.cell(0, 4).bg);
    try testing.expect(s.cell(0, 4).attrs.underline);
    try s.write("\x1b[91;102mB");
    try testing.expectEqual(indexed(9), s.cell(0, 5).fg);
    try testing.expectEqual(indexed(10), s.cell(0, 5).bg);
}

test "insert and delete characters and lines, scroll regions" {
    var s = try Screen.init(testing.allocator, 8, 5);
    defer s.deinit();
    try s.write("abcdef\x1b[1;3H\x1b[2@");
    try expectRow(&s, 0, "ab  cdef");
    try s.write("\x1b[1;1H\x1b[3P");
    try expectRow(&s, 0, " cdef");
    try s.write("\x1b[1;1H\x1b[2J1\r\n2\r\n3\r\n4\r\n5");
    // Region rows 2-4: scrolling inside it leaves rows 1 and 5 alone.
    try s.write("\x1b[2;4r\x1b[4;1H\n");
    try expectRow(&s, 0, "1");
    try expectRow(&s, 1, "3");
    try expectRow(&s, 2, "4");
    try expectRow(&s, 3, "");
    try expectRow(&s, 4, "5");
    try testing.expectEqual(@as(usize, 0), s.scrollbackLen()); // a region does not feed history
    // Insert a line at row 2 pushes 3,4 down within the region.
    try s.write("\x1b[2;1H\x1b[L");
    try expectRow(&s, 1, "");
    try expectRow(&s, 2, "3");
    try expectRow(&s, 3, "4");
    try s.write("\x1b[M");
    try expectRow(&s, 1, "3");
    // Reverse index at the region top scrolls down.
    try s.write("\x1b[2;1H\x1bM");
    try expectRow(&s, 1, "");
    try expectRow(&s, 2, "3");
}

test "the alternate screen keeps the main screen intact" {
    var s = try Screen.init(testing.allocator, 10, 3);
    defer s.deinit();
    try s.write("main\x1b[?1049h");
    try testing.expect(s.modes.alt_screen);
    try expectRow(&s, 0, "");
    try s.write("vim!\r\n\r\n\r\n\r\n");
    try testing.expectEqual(@as(usize, 0), s.scrollbackLen());
    try s.write("\x1b[?1049l");
    try testing.expect(!s.modes.alt_screen);
    try expectRow(&s, 0, "main");
    try testing.expectEqual(@as(usize, 4), s.cursor.col);
}

test "UTF-8, wide characters, broken sequences" {
    var s = try Screen.init(testing.allocator, 6, 2);
    defer s.deinit();
    try s.write("a\xc3\xa9\xe4\xb8\xad!");
    try testing.expectEqual(@as(u21, 0xe9), s.cell(0, 1).ch);
    try testing.expectEqual(@as(u21, 0x4e2d), s.cell(0, 2).ch);
    try testing.expect(s.cell(0, 3).attrs.wide_tail);
    try testing.expectEqual(@as(u21, '!'), s.cell(0, 4).ch);
    try expectRow(&s, 0, "a\u{e9}\u{4e2d}!");
    // A wide character that does not fit wraps to the next line.
    try s.write("\xe4\xb8\xad\xe4\xb8\xad");
    try testing.expectEqual(@as(u21, 0x4e2d), s.cell(1, 0).ch);
    // An interrupted multi-byte sequence becomes U+FFFD, then the byte is handled.
    try s.write("\x1b[2J\x1b[H\xe4\xb8X");
    try testing.expectEqual(@as(u21, 0xFFFD), s.cell(0, 0).ch);
    try testing.expectEqual(@as(u21, 'X'), s.cell(0, 1).ch);
}

test "queries are answered and titles recorded" {
    var s = try Screen.init(testing.allocator, 10, 5);
    defer s.deinit();
    try s.write("\x1b[3;4H\x1b[6n");
    try testing.expectEqualStrings("\x1b[3;4R", s.takeReply());
    s.clearReply();
    try s.write("\x1b[c");
    try testing.expect(std.mem.startsWith(u8, s.takeReply(), "\x1b[?"));
    try s.write("\x1b]0;my title\x07\x1b]2;second\x1b\\");
    try testing.expectEqualStrings("second", s.titleText());
    // Unknown strings and sequences are swallowed.
    try s.write("\x1bP1$r\x1b\\\x1b[?9999hok\x1b(B");
    try expectRow(&s, 2, "   ok");
}

test "modes: cursor keys, bracketed paste, cursor visibility, save and restore" {
    var s = try Screen.init(testing.allocator, 10, 5);
    defer s.deinit();
    try s.write("\x1b[?1h\x1b[?2004h\x1b[?25l");
    try testing.expect(s.modes.app_cursor_keys and s.modes.bracketed_paste and !s.modes.cursor_visible);
    try s.write("\x1b[?1l\x1b[?2004l\x1b[?25h");
    try testing.expect(!s.modes.app_cursor_keys and !s.modes.bracketed_paste and s.modes.cursor_visible);
    try s.write("\x1b[3;3H\x1b7\x1b[1;1H\x1b8x");
    try testing.expectEqual(@as(u21, 'x'), s.cell(2, 2).ch);
}

test "resize keeps content at the top and pushes lines out when the cursor would be lost" {
    var s = try Screen.init(testing.allocator, 5, 4);
    defer s.deinit();
    try s.write("one\r\ntwo\r\nthree\r\nfour");
    try s.resize(8, 2);
    try testing.expectEqual(@as(usize, 2), s.scrollbackLen());
    try expectRow(&s, 0, "three");
    try expectRow(&s, 1, "four");
    try testing.expectEqual(@as(usize, 1), s.cursor.row);
    try s.resize(3, 4);
    try expectRow(&s, 0, "thr");
    try testing.expect(s.cursor.col < 3);
}

test "scrollback is bounded and ordered" {
    var s = try Screen.init(testing.allocator, 3, 1);
    defer s.deinit();
    s.max_scrollback = 3;
    try s.write("a\r\nb\r\nc\r\nd\r\ne\r\nf");
    try testing.expectEqual(@as(usize, 3), s.scrollbackLen());
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(testing.allocator);
    for (0..3) |i| try appendCells(s.scrollbackLine(i), &out, testing.allocator);
    try testing.expectEqualStrings("cde", out.items);
}
