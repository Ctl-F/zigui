//! A pseudo-terminal with a program on the other end (a shell), for the
//! integrated terminal. Unlike `process.Runner` (pipes, stdout and stderr kept
//! apart), a PTY makes the program believe it is on a real terminal: it prints
//! colors, prompts, line editing and full-screen interfaces, and its stdout and
//! stderr arrive merged, in order, on the one stream a terminal has.
//!
//!     const pty = try Pty.open(gpa, .{ .argv = &.{"/bin/bash"}, .cols = 80, .rows = 24, .wake = sdl.wake });
//!     defer pty.close();
//!     try pty.write("ls\n");                // keystrokes
//!     pty.resize(120, 30);                  // the window changed
//!     // each loop iteration:
//!     var batch: std.ArrayListUnmanaged(pty_mod.Event) = .empty;
//!     pty.drain(&batch);                    // .data bytes to feed an emulator, .exited when done
//!
//! One backend per system, all with this same interface: Linux (raw system
//! calls, `pty_linux.zig`), macOS and the BSDs (C library, `pty_posix.zig`) and
//! Windows 10+ (ConPTY, `pty_windows.zig`). Other systems fail with
//! `error.Unsupported`. A reader thread reads the program's output and posts
//! events to a queue the UI thread drains.

const std = @import("std");
const builtin = @import("builtin");

const common = @import("pty_common.zig");
pub const Event = common.Event;
pub const Options = common.Options;

pub const supported = switch (builtin.os.tag) {
    .linux, .windows, .macos, .freebsd, .netbsd, .openbsd, .dragonfly => true,
    else => false,
};

pub const Pty = switch (builtin.os.tag) {
    .linux => @import("pty_linux.zig").Pty,
    .windows => @import("pty_windows.zig").Pty,
    .macos, .freebsd, .netbsd, .openbsd, .dragonfly => @import("pty_posix.zig").Pty,
    else => struct {
        pub fn open(_: std.mem.Allocator, _: Options) !*@This() {
            return error.Unsupported;
        }
        pub fn drain(_: *@This(), _: *std.ArrayListUnmanaged(Event)) void {}
        pub fn finished(_: *const @This()) bool {
            return true;
        }
        pub fn write(_: *@This(), _: []const u8) !void {}
        pub fn resize(_: *@This(), _: u16, _: u16) void {}
        pub fn close(_: *@This()) void {}
    },
};

pub const defaultShell = common.defaultShell;

// ---- tests -----------------------------------------------------------------

const testing = std.testing;
const sleepMs = common.sleepMs;
const is_windows = builtin.os.tag == .windows;

fn collect(p: *Pty, out: *std.ArrayListUnmanaged(u8), want: []const u8, exit: *?i32) !void {
    var batch: std.ArrayListUnmanaged(Event) = .empty;
    defer batch.deinit(testing.allocator);
    var tries: usize = 0;
    while (tries < 3000) : (tries += 1) {
        p.drain(&batch);
        for (batch.items) |*e| {
            switch (e.*) {
                .data => |d| try out.appendSlice(testing.allocator, d),
                .exited => |code| exit.* = code,
            }
            e.deinit(testing.allocator);
        }
        batch.clearRetainingCapacity();
        if (want.len > 0 and std.mem.indexOf(u8, out.items, want) != null) return;
        if (want.len == 0 and exit.* != null) return;
        sleepMs(2);
    }
}

test "a program on a pty sees a terminal, its output arrives, and its exit status is reported" {
    if (!supported or is_windows) return error.SkipZigTest;
    const p = try Pty.open(testing.allocator, .{ .argv = &.{ "/bin/sh", "-c", "[ -t 0 ] && [ -t 1 ] && echo tty-yes; echo err >&2; echo \"$TERM\"; stty size; exit 3" }, .cols = 100, .rows = 30 });
    defer p.close();
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(testing.allocator);
    var exit: ?i32 = null;
    try collect(p, &out, "", &exit);
    try testing.expect(std.mem.indexOf(u8, out.items, "tty-yes") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "err") != null); // stderr arrives on the same stream
    try testing.expect(std.mem.indexOf(u8, out.items, "xterm-256color") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "30 100") != null);
    try testing.expectEqual(@as(?i32, 3), exit);
    try testing.expect(p.finished());
}

test "keystrokes reach the program, and resizing is seen" {
    if (!supported or is_windows) return error.SkipZigTest;
    const p = try Pty.open(testing.allocator, .{ .argv = &.{ "/bin/sh", "-c", "read line; echo got:$line; sleep 0.3; stty size" } });
    defer p.close();
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(testing.allocator);
    var exit: ?i32 = null;
    try p.write("hello\n");
    try collect(p, &out, "got:hello", &exit);
    try testing.expect(std.mem.indexOf(u8, out.items, "got:hello") != null);
    p.resize(60, 20);
    try collect(p, &out, "20 60", &exit);
    try testing.expect(std.mem.indexOf(u8, out.items, "20 60") != null);
}

test "closing stops a program that is still running" {
    if (!supported or is_windows) return error.SkipZigTest;
    const p = try Pty.open(testing.allocator, .{ .argv = &.{ "/bin/sh", "-c", "sleep 30" } });
    p.close(); // must not hang or leak
}

test "ConPTY: output arrives and the exit code is reported (Windows only)" {
    if (!is_windows) return error.SkipZigTest;
    const p = try Pty.open(testing.allocator, .{ .argv = &.{ "cmd.exe", "/c", "echo hello-conpty& exit 3" } });
    defer p.close();
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(testing.allocator);
    var exit: ?i32 = null;
    try collect(p, &out, "", &exit);
    try testing.expect(std.mem.indexOf(u8, out.items, "hello-conpty") != null);
    try testing.expectEqual(@as(?i32, 3), exit);
}
