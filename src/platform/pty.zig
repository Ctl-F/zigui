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
//! Linux only for now (raw system calls, no libc); other systems fail with
//! `error.Unsupported`. A reader thread polls the master side
//! and posts events to a queue the UI thread drains.

const std = @import("std");
const builtin = @import("builtin");
const worker = @import("../core/worker.zig");

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

const linux = std.os.linux;

/// Linux only for now (raw system calls, so no libc is needed); macOS and
/// Windows (ConPTY) would each need their own `open`.
const supported = builtin.os.tag == .linux;

const TIOCGPTN: u32 = 0x80045430;
const TIOCSPTLCK: u32 = 0x40045431;
const TIOCSCTTY: u32 = 0x540E;
const TIOCSWINSZ: u32 = 0x5414;

const Winsize = extern struct { row: u16, col: u16, xpixel: u16 = 0, ypixel: u16 = 0 };

fn failed(rc: usize) bool {
    return linux.errno(rc) != .SUCCESS;
}

fn sleepMs(ms: u64) void {
    var ts: linux.timespec = .{ .sec = @intCast(ms / 1000), .nsec = @intCast((ms % 1000) * 1_000_000) };
    _ = linux.nanosleep(&ts, null);
}

pub const Pty = struct {
    gpa: std.mem.Allocator,
    master: i32,
    pid: i32,
    queue: worker.Queue(Event),
    reader: ?std.Thread = null,
    stop_flag: std.atomic.Value(bool) = .init(false),
    done: std.atomic.Value(bool) = .init(false),

    pub fn open(gpa: std.mem.Allocator, opts: Options) !*Pty {
        if (!supported) return error.Unsupported;
        const self = try gpa.create(Pty);
        errdefer gpa.destroy(self);

        // The master side, unlocked, and the name of its slave.
        const mfd_rc = linux.open("/dev/ptmx", .{ .ACCMODE = .RDWR, .NOCTTY = true, .CLOEXEC = true }, 0);
        if (failed(mfd_rc)) return error.OpenFailed;
        const master: i32 = @intCast(mfd_rc);
        errdefer _ = linux.close(master);
        var unlock: c_int = 0;
        if (failed(linux.ioctl(master, TIOCSPTLCK, @intFromPtr(&unlock)))) return error.OpenFailed;
        var n: c_uint = 0;
        if (failed(linux.ioctl(master, TIOCGPTN, @intFromPtr(&n)))) return error.OpenFailed;
        var slave_buf: [48]u8 = undefined;
        const slave = try std.fmt.bufPrintSentinel(&slave_buf, "/dev/pts/{d}", .{n}, 0);
        var ws: Winsize = .{ .row = opts.rows, .col = opts.cols };
        _ = linux.ioctl(master, TIOCSWINSZ, @intFromPtr(&ws));

        // Everything the child needs is prepared before forking: it only makes
        // system calls until it executes the program.
        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        const a = arena.allocator();
        const shell: []const u8 = blk: {
            if (opts.environ) |m| if (m.get("SHELL")) |sh| break :blk sh;
            break :blk "/bin/sh";
        };
        const base: []const []const u8 = if (opts.argv.len > 0) opts.argv else &.{shell};
        var args: std.ArrayListUnmanaged(?[*:0]const u8) = .empty;
        try args.append(a, "env");
        for (base) |arg| try args.append(a, (try a.dupeSentinel(u8, arg, 0)).ptr);
        try args.append(a, null);
        var env: std.ArrayListUnmanaged(?[*:0]const u8) = .empty;
        var has_path = false;
        if (opts.environ) |m| {
            var it = m.iterator();
            while (it.next()) |kv| {
                const k = kv.key_ptr.*;
                if (std.mem.eql(u8, k, "TERM") or std.mem.eql(u8, k, "COLORTERM")) continue;
                if (std.mem.eql(u8, k, "PATH")) has_path = true;
                try env.append(a, (try std.fmt.allocPrintSentinel(a, "{s}={s}", .{ k, kv.value_ptr.* }, 0)).ptr);
            }
        }
        if (!has_path) try env.append(a, "PATH=/usr/local/bin:/usr/bin:/bin");
        try env.append(a, "TERM=xterm-256color");
        try env.append(a, "COLORTERM=truecolor");
        try env.append(a, null);
        const cwd_z: ?[:0]u8 = if (opts.cwd) |d| try a.dupeSentinel(u8, d, 0) else null;
        const argv: [*:null]const ?[*:0]const u8 = @ptrCast(args.items.ptr);
        const envp: [*:null]const ?[*:0]const u8 = @ptrCast(env.items.ptr);

        const fork_rc = linux.fork();
        if (failed(fork_rc)) return error.ForkFailed;
        if (fork_rc == 0) {
            // The child: own session, the slave as controlling terminal and stdio.
            _ = linux.setsid();
            const sfd_rc = linux.open(slave.ptr, .{ .ACCMODE = .RDWR }, 0);
            if (failed(sfd_rc)) linux.exit(126);
            const sfd: i32 = @intCast(sfd_rc);
            _ = linux.ioctl(sfd, TIOCSCTTY, 0);
            _ = linux.dup2(sfd, 0);
            _ = linux.dup2(sfd, 1);
            _ = linux.dup2(sfd, 2);
            if (sfd > 2) _ = linux.close(sfd);
            if (cwd_z) |d| _ = linux.chdir(d.ptr);
            _ = linux.execve("/usr/bin/env", argv, envp);
            linux.exit(127);
        }
        self.* = .{ .gpa = gpa, .master = master, .pid = @intCast(fork_rc), .queue = .{ .gpa = gpa, .wake = opts.wake } };
        errdefer self.queue.deinit();
        self.reader = try std.Thread.spawn(.{}, readLoop, .{self});
        return self;
    }

    fn readLoop(self: *Pty) void {
        var buf: [8192]u8 = undefined;
        var fds = [1]linux.pollfd{.{ .fd = self.master, .events = linux.POLL.IN, .revents = 0 }};
        while (!self.stop_flag.load(.acquire)) {
            fds[0].revents = 0;
            const pr = linux.poll(&fds, 1, 100);
            if (failed(pr)) {
                if (linux.errno(pr) == .INTR) continue;
                break;
            }
            if (pr == 0) continue;
            const got = linux.read(self.master, &buf, buf.len);
            if (failed(got) or got == 0) break; // EIO once the program and its terminal are gone
            const bytes = self.gpa.dupe(u8, buf[0..got]) catch break;
            self.queue.push(.{ .data = bytes }) catch {
                self.gpa.free(bytes);
                break;
            };
        }
        var status: i32 = 0;
        var reaped = linux.waitpid(self.pid, &status, linux.W.NOHANG);
        if (reaped == 0) {
            // The terminal closed but the program lingers: give it a moment, then end it.
            sleepMs(200);
            reaped = linux.waitpid(self.pid, &status, linux.W.NOHANG);
            if (reaped == 0) {
                _ = linux.kill(self.pid, .KILL);
                reaped = linux.waitpid(self.pid, &status, 0);
            }
        }
        const code: i32 = if (!failed(reaped) and reaped > 0) exitCode(@bitCast(status)) else -1;
        self.queue.push(.{ .exited = code }) catch {};
        self.done.store(true, .release);
    }

    fn exitCode(status: u32) i32 {
        if (status & 0x7f == 0) return @intCast((status >> 8) & 0xff);
        return 128 + @as(i32, @intCast(status & 0x7f));
    }

    /// Move what has arrived onto `out` (UI thread).
    pub fn drain(self: *Pty, out: *std.ArrayListUnmanaged(Event)) void {
        self.queue.drain(out);
    }

    /// True once the program has ended and its exit event is queued.
    pub fn finished(self: *const Pty) bool {
        return self.done.load(.acquire);
    }

    /// Send keystrokes (or pasted text) to the program.
    pub fn write(self: *Pty, bytes: []const u8) !void {
        var rest = bytes;
        while (rest.len > 0) {
            const rc = linux.write(self.master, rest.ptr, rest.len);
            if (failed(rc)) {
                switch (linux.errno(rc)) {
                    .INTR => continue,
                    .AGAIN => {
                        sleepMs(1);
                        continue;
                    },
                    else => return error.WriteFailed,
                }
            }
            rest = rest[rc..];
        }
    }

    /// Tell the program the window is now `cols` by `rows` characters.
    pub fn resize(self: *Pty, cols: u16, rows: u16) void {
        var ws: Winsize = .{ .row = rows, .col = cols };
        _ = linux.ioctl(self.master, TIOCSWINSZ, @intFromPtr(&ws));
    }

    /// End the program (if running), wait for the threads and free everything.
    pub fn close(self: *Pty) void {
        if (!self.finished()) {
            // Hang up the whole process group, as closing a terminal window does.
            _ = linux.kill(-self.pid, .HUP);
            _ = linux.kill(self.pid, .HUP);
        }
        self.stop_flag.store(true, .release);
        if (self.reader) |t| t.join();
        _ = linux.close(self.master);
        var left: std.ArrayListUnmanaged(Event) = .empty;
        self.queue.drain(&left);
        for (left.items) |*e| e.deinit(self.gpa);
        left.deinit(self.gpa);
        self.queue.deinit();
        self.gpa.destroy(self);
    }
};

// ---- tests -----------------------------------------------------------------

const testing = std.testing;

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
    if (!supported) return error.SkipZigTest;
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
    if (!supported) return error.SkipZigTest;
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
    if (!supported) return error.SkipZigTest;
    const p = try Pty.open(testing.allocator, .{ .argv = &.{ "/bin/sh", "-c", "sleep 30" } });
    p.close(); // must not hang or leak
}
