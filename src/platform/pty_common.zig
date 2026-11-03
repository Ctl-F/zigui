//! Shared pieces of the pseudo-terminal backends (`pty.zig` picks one).

const std = @import("std");
const builtin = @import("builtin");

pub const Event = union(enum) {
    /// Bytes the program wrote (owned: call `deinit`).
    data: []u8,
    /// The program ended with this exit status (or 128 + signal).
    exited: i32,

    pub fn deinit(self: *Event, gpa: std.mem.Allocator) void {
        switch (self.*) {
            .data => |d| gpa.free(d),
            .exited => {},
        }
    }
};

pub const Options = struct {
    /// The program and its arguments (default: `$SHELL` from `environ`, else `/bin/sh`).
    argv: []const []const u8 = &.{},
    cwd: ?[]const u8 = null,
    cols: u16 = 80,
    rows: u16 = 24,
    /// The environment the program starts with (`TERM` and `COLORTERM` are set for it).
    /// Null: just a default `PATH`.
    environ: ?*const std.process.Environ.Map = null,
    /// Called from the reader thread after data arrives.
    wake: ?*const fn () void = null,
};


/// Sleep without an `Io` (reader threads and tests).
pub fn sleepMs(ms: u64) void {
    switch (builtin.os.tag) {
        .windows => std.os.windows.kernel32.Sleep(@intCast(ms)),
        .linux => {
            var ts: std.os.linux.timespec = .{ .sec = @intCast(ms / 1000), .nsec = @intCast((ms % 1000) * 1_000_000) };
            _ = std.os.linux.nanosleep(&ts, null);
        },
        else => {
            var ts: std.c.timespec = .{ .sec = @intCast(ms / 1000), .nsec = @intCast((ms % 1000) * 1_000_000) };
            _ = std.c.nanosleep(&ts, null);
        },
    }
}

/// The program a terminal starts when none is given: `$SHELL`, else the
/// system's default shell (`%COMSPEC%` on Windows).
pub fn defaultShell(environ: ?*const std.process.Environ.Map) []const u8 {
    if (builtin.os.tag == .windows) {
        if (environ) |m| if (m.get("COMSPEC")) |s| return s;
        return "cmd.exe";
    }
    if (environ) |m| if (m.get("SHELL")) |s| return s;
    return "/bin/sh";
}
