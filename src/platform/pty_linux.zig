//! Linux backend of `pty.zig`: raw system calls (no libc needed).

const std = @import("std");
const worker = @import("../core/worker.zig");
const common = @import("pty_common.zig");
const Event = common.Event;
const Options = common.Options;
const sleepMs = common.sleepMs;

const linux = std.os.linux;

const TIOCGPTN: u32 = 0x80045430;
const TIOCSPTLCK: u32 = 0x40045431;
const TIOCSCTTY: u32 = 0x540E;
const TIOCSWINSZ: u32 = 0x5414;

const Winsize = extern struct { row: u16, col: u16, xpixel: u16 = 0, ypixel: u16 = 0 };

fn failed(rc: usize) bool {
    return linux.errno(rc) != .SUCCESS;
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

