//! macOS and BSD backend of `pty.zig`: the C library's pseudo-terminal calls
//! (`posix_openpt`, `fork`, `execve`), because these systems have no stable raw
//! system-call interface. Same design as `pty_linux.zig`: a reader thread polls
//! the master side and posts events to a queue the UI thread drains.
//!
//! Not run by the project's own CI (no macOS machine): it compiles for
//! aarch64-macos and x86_64-macos and follows the same shape as the Linux code.

const std = @import("std");
const c = std.c;
const worker = @import("../core/worker.zig");
const common = @import("pty_common.zig");
const Event = common.Event;
const Options = common.Options;
const sleepMs = common.sleepMs;

// BSD-family values (macOS, FreeBSD, NetBSD, OpenBSD, DragonFly).
const TIOCSWINSZ: c_ulong = 0x80087467;
const TIOCSCTTY: c_ulong = 0x20007461;
const F_SETFD: c_int = 2;
const FD_CLOEXEC: c_int = 1;

const Winsize = extern struct { row: u16, col: u16, xpixel: u16 = 0, ypixel: u16 = 0 };

extern "c" fn posix_openpt(flags: c_int) c_int;
extern "c" fn grantpt(fd: c_int) c_int;
extern "c" fn unlockpt(fd: c_int) c_int;
extern "c" fn ptsname(fd: c_int) ?[*:0]const u8;
extern "c" fn ioctl(fd: c_int, request: c_ulong, ...) c_int;
extern "c" fn fork() c_int;

fn flagsRdwrNoctty() c_int {
    const o: c.O = .{ .ACCMODE = .RDWR, .NOCTTY = true };
    return @bitCast(@as(@typeInfo(c.O).@"struct".backing_integer.?, @bitCast(o)));
}

pub const Pty = struct {
    gpa: std.mem.Allocator,
    master: c_int,
    pid: c_int,
    queue: worker.Queue(Event),
    reader: ?std.Thread = null,
    stop_flag: std.atomic.Value(bool) = .init(false),
    done: std.atomic.Value(bool) = .init(false),

    pub fn open(gpa: std.mem.Allocator, opts: Options) !*Pty {
        const self = try gpa.create(Pty);
        errdefer gpa.destroy(self);

        const master = posix_openpt(flagsRdwrNoctty());
        if (master < 0) return error.OpenFailed;
        errdefer _ = c.close(master);
        if (grantpt(master) != 0 or unlockpt(master) != 0) return error.OpenFailed;
        _ = c.fcntl(master, F_SETFD, FD_CLOEXEC);

        // Everything the child needs is prepared before forking: it only makes
        // system calls until it executes the program.
        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        const a = arena.allocator();
        const slave_name = ptsname(master) orelse return error.OpenFailed;
        const slave = try a.dupeSentinel(u8, std.mem.span(slave_name), 0);
        var ws: Winsize = .{ .row = opts.rows, .col = opts.cols };
        _ = ioctl(master, TIOCSWINSZ, &ws);

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

        const pid = fork();
        if (pid < 0) return error.ForkFailed;
        if (pid == 0) {
            // The child: own session, the slave as controlling terminal and stdio.
            _ = c.setsid();
            const sfd = c.open(slave.ptr, .{ .ACCMODE = .RDWR });
            if (sfd < 0) c._exit(126);
            _ = ioctl(sfd, TIOCSCTTY, @as(c_int, 0));
            _ = c.dup2(sfd, 0);
            _ = c.dup2(sfd, 1);
            _ = c.dup2(sfd, 2);
            if (sfd > 2) _ = c.close(sfd);
            if (cwd_z) |d| _ = c.chdir(d.ptr);
            _ = c.execve("/usr/bin/env", argv, envp);
            c._exit(127);
        }
        self.* = .{ .gpa = gpa, .master = master, .pid = pid, .queue = .{ .gpa = gpa, .wake = opts.wake } };
        errdefer self.queue.deinit();
        self.reader = try std.Thread.spawn(.{}, readLoop, .{self});
        return self;
    }

    fn readLoop(self: *Pty) void {
        var buf: [8192]u8 = undefined;
        var fds = [1]c.pollfd{.{ .fd = self.master, .events = c.POLL.IN, .revents = 0 }};
        while (!self.stop_flag.load(.acquire)) {
            fds[0].revents = 0;
            const pr = c.poll(&fds, 1, 100);
            if (pr < 0) {
                if (c.errno(pr) == .INTR) continue;
                break;
            }
            if (pr == 0) continue;
            const got = c.read(self.master, &buf, buf.len);
            if (got <= 0) break; // EIO once the program and its terminal are gone
            const bytes = self.gpa.dupe(u8, buf[0..@intCast(got)]) catch break;
            self.queue.push(.{ .data = bytes }) catch {
                self.gpa.free(bytes);
                break;
            };
        }
        var status: c_int = 0;
        var reaped = c.waitpid(self.pid, &status, c.W.NOHANG);
        if (reaped == 0) {
            // The terminal closed but the program lingers: give it a moment, then end it.
            sleepMs(200);
            reaped = c.waitpid(self.pid, &status, c.W.NOHANG);
            if (reaped == 0) {
                _ = c.kill(self.pid, .KILL);
                reaped = c.waitpid(self.pid, &status, 0);
            }
        }
        const code: i32 = if (reaped > 0) exitCode(@bitCast(status)) else -1;
        self.queue.push(.{ .exited = code }) catch {};
        self.done.store(true, .release);
    }

    fn exitCode(status: u32) i32 {
        if (status & 0x7f == 0) return @intCast((status >> 8) & 0xff);
        return 128 + @as(i32, @intCast(status & 0x7f));
    }

    pub fn drain(self: *Pty, out: *std.ArrayListUnmanaged(Event)) void {
        self.queue.drain(out);
    }

    pub fn finished(self: *const Pty) bool {
        return self.done.load(.acquire);
    }

    pub fn write(self: *Pty, bytes: []const u8) !void {
        var rest = bytes;
        while (rest.len > 0) {
            const rc = c.write(self.master, rest.ptr, rest.len);
            if (rc < 0) {
                switch (c.errno(rc)) {
                    .INTR => continue,
                    .AGAIN => {
                        sleepMs(1);
                        continue;
                    },
                    else => return error.WriteFailed,
                }
            }
            rest = rest[@intCast(rc)..];
        }
    }

    pub fn resize(self: *Pty, cols: u16, rows: u16) void {
        var ws: Winsize = .{ .row = rows, .col = cols };
        _ = ioctl(self.master, TIOCSWINSZ, &ws);
    }

    pub fn close(self: *Pty) void {
        if (!self.finished()) {
            // Hang up the whole process group, as closing a terminal window does.
            _ = c.kill(-self.pid, .HUP);
            _ = c.kill(self.pid, .HUP);
        }
        self.stop_flag.store(true, .release);
        if (self.reader) |t| t.join();
        _ = c.close(self.master);
        var left: std.ArrayListUnmanaged(Event) = .empty;
        self.queue.drain(&left);
        for (left.items) |*e| e.deinit(self.gpa);
        left.deinit(self.gpa);
        self.queue.deinit();
        self.gpa.destroy(self);
    }
};
