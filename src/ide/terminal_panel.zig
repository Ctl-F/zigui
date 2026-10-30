//! The IDE's integrated terminal: a `Terminal` widget wired to a shell on a
//! pseudo-terminal (`platform/pty.zig`). The shell starts once the widget knows
//! its size, in the project folder, and follows the widget's size from then on.
//! When the shell exits the panel says so, and the next key press starts a new one.
//!
//!     const term = try TerminalPanel.create(&ui, parent, .{ .cwd = project.root, .environ = init.environ_map, .wake = sdl.wake });
//!     defer term.destroy();
//!     // each loop iteration:
//!     term.poll();
//!     term.runCommand("zig build test");      // types it and presses Enter
//!
//! Everything the program prints (stdout and stderr alike) appears on the one
//! screen, as in any terminal; use the Output panel when you want them apart.

const std = @import("std");
const Handle = @import("../core/handle.zig").Handle;
const Ui = @import("../core/ui.zig").Ui;
const terminal_mod = @import("../widgets/terminal.zig");
const Terminal = terminal_mod.Terminal;
const pty_mod = @import("../platform/pty.zig");

pub const Options = struct {
    /// Where the shell starts.
    cwd: ?[]const u8 = null,
    /// The program to run (default: `$SHELL`).
    argv: []const []const u8 = &.{},
    environ: ?*const std.process.Environ.Map = null,
    wake: ?*const fn () void = null,
    /// The terminal widget's style (default: grows to fill its parent).
    style: @import("../core/style.zig").Style = .{},
};

pub const TerminalPanel = struct {
    gpa: std.mem.Allocator,
    ui: *Ui,
    term: *Terminal,
    pty: ?*pty_mod.Pty = null,
    cwd: ?[]u8,
    argv: [][]u8,
    environ: ?*const std.process.Environ.Map,
    wake: ?*const fn () void,
    cols: u16 = 0,
    rows: u16 = 0,
    /// The shell has exited and not been restarted.
    exited: bool = false,
    batch: std.ArrayListUnmanaged(pty_mod.Event) = .empty,

    pub fn create(ui: *Ui, parent: Handle, opts: Options) !*TerminalPanel {
        const self = try ui.gpa.create(TerminalPanel);
        errdefer ui.gpa.destroy(self);
        const argv = try ui.gpa.alloc([]u8, opts.argv.len);
        var n: usize = 0;
        errdefer {
            for (argv[0..n]) |a| ui.gpa.free(a);
            ui.gpa.free(argv);
        }
        for (opts.argv) |a| {
            argv[n] = try ui.gpa.dupe(u8, a);
            n += 1;
        }
        const cwd = if (opts.cwd) |c| try ui.gpa.dupe(u8, c) else null;
        errdefer if (cwd) |c| ui.gpa.free(c);
        self.* = .{ .gpa = ui.gpa, .ui = ui, .term = undefined, .cwd = cwd, .argv = argv, .environ = opts.environ, .wake = opts.wake };
        var style = opts.style;
        if (style.grow == 0) style.grow = 1;
        self.term = try ui.add(Terminal, parent, .{
            .style = style,
            .label = "Terminal",
            .on_write = .bind(self, onWrite),
            .on_resize = .bind(self, onResize),
        });
        return self;
    }

    pub fn destroy(self: *TerminalPanel) void {
        if (self.pty) |p| p.close();
        for (self.batch.items) |*e| e.deinit(self.gpa);
        self.batch.deinit(self.gpa);
        for (self.argv) |a| self.gpa.free(a);
        self.gpa.free(self.argv);
        if (self.cwd) |c| self.gpa.free(c);
        self.gpa.destroy(self);
    }

    fn start(self: *TerminalPanel) void {
        if (self.cols == 0) return;
        const argv: []const []const u8 = @ptrCast(self.argv);
        self.pty = pty_mod.Pty.open(self.gpa, .{
            .argv = argv,
            .cwd = self.cwd,
            .cols = self.cols,
            .rows = self.rows,
            .environ = self.environ,
            .wake = self.wake,
        }) catch |err| {
            var buf: [96]u8 = undefined;
            self.term.feed(std.fmt.bufPrint(&buf, "could not start a shell: {s}\r\n", .{@errorName(err)}) catch "could not start a shell\r\n");
            self.exited = true;
            return;
        };
        self.exited = false;
    }

    fn onResize(self: *TerminalPanel, cols: u16, rows: u16) void {
        self.cols = cols;
        self.rows = rows;
        if (self.pty) |p| p.resize(cols, rows) else if (!self.exited) self.start();
    }

    fn onWrite(self: *TerminalPanel, bytes: []const u8) void {
        if (self.pty) |p| {
            p.write(bytes) catch {};
        } else if (self.exited) {
            // A key after the shell ended starts a new one.
            self.term.clear();
            self.start();
        }
    }

    /// Take in what the shell printed (call every loop iteration).
    pub fn poll(self: *TerminalPanel) void {
        const p = self.pty orelse return;
        p.drain(&self.batch);
        var ended: ?i32 = null;
        for (self.batch.items) |*e| {
            switch (e.*) {
                .data => |d| self.term.feed(d),
                .exited => |code| ended = code,
            }
            e.deinit(self.gpa);
        }
        self.batch.clearRetainingCapacity();
        if (ended) |code| {
            var buf: [96]u8 = undefined;
            self.term.feed(std.fmt.bufPrint(&buf, "\r\n[shell exited with code {d}; press a key to start another]\r\n", .{code}) catch "\r\n[shell exited]\r\n");
            p.close();
            self.pty = null;
            self.exited = true;
        }
    }

    /// Type `text` and press Enter (as if the user had).
    pub fn runCommand(self: *TerminalPanel, text: []const u8) void {
        const p = self.pty orelse return;
        p.write(text) catch return;
        p.write("\n") catch {};
    }

    pub fn focus(self: *TerminalPanel) void {
        self.ui.setFocus(self.term.node);
    }
};

// ---- tests -----------------------------------------------------------------

const testing = std.testing;
const Rig = @import("../core/test_rig.zig").Rig;

fn screenText(t: *Terminal) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(testing.allocator);
    for (0..t.screen.rows) |r| {
        try t.screen.rowText(r, &out, testing.allocator);
        try out.append(testing.allocator, '\n');
    }
    return out.toOwnedSlice(testing.allocator);
}

fn pollUntil(panel: *TerminalPanel, r: *Rig, needle: []const u8) !void {
    var tries: usize = 0;
    while (tries < 3000) : (tries += 1) {
        panel.poll();
        const text = try screenText(panel.term);
        defer testing.allocator.free(text);
        if (std.mem.indexOf(u8, text, needle) != null) return;
        try r.frame();
        var ts: std.os.linux.timespec = .{ .sec = 0, .nsec = 2_000_000 };
        _ = std.os.linux.nanosleep(&ts, null);
    }
    return error.TestExpectedText;
}

test "the shell starts when the terminal has a size, shows output, takes input and reports its exit" {
    if (@import("builtin").os.tag != .linux) return error.SkipZigTest;
    const r = try Rig.init();
    defer r.deinit();
    const panel = try TerminalPanel.create(&r.ui, r.ui.tree.root, .{ .argv = &.{ "/bin/sh", "-c", "echo ready; read x; echo got-$x; exit 4" } });
    defer panel.destroy();
    r.ui.setFocus(panel.term.node);
    try r.frame();
    try r.frame();
    try testing.expect(panel.pty != null);
    try pollUntil(panel, r, "ready");
    // Typing goes to the shell (it echoes the keys and answers).
    r.ui.textInput("abc");
    r.ui.key(.enter, .{}, true, false);
    try pollUntil(panel, r, "got-abc");
    try pollUntil(panel, r, "exited with code 4");
    try testing.expect(panel.exited and panel.pty == null);
    // A key press starts a new shell.
    r.ui.key(.enter, .{}, true, false);
    try testing.expect(panel.pty != null);
    try pollUntil(panel, r, "ready");
}
