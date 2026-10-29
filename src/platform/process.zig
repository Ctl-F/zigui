//! Run a child process and get its output without blocking the UI.
//!
//! `Runner.start` spawns the process with piped stdin/stdout/stderr and starts a
//! reader thread per output stream plus one that waits for exit. Output arrives
//! as `Event`s in a queue that the UI thread `drain`s (the queue calls `wake`
//! after each push, so a sleeping loop runs). Stdout and stderr stay separate
//! so a front end can style them differently.
//!
//!     const run = try Runner.start(gpa, io, .{ .argv = &.{ "zig", "build" }, .cwd = project_dir, .wake = sdl.wake });
//!     defer run.destroy();
//!     // each frame:
//!     var batch: std.ArrayListUnmanaged(process.Event) = .empty;
//!     run.drain(&batch);
//!     for (batch.items) |*e| { ...; e.deinit(gpa); }
//!     batch.clearRetainingCapacity();
//!
//! `stop` asks the process to end (SIGTERM; killing on Windows is not wired yet).

const std = @import("std");
const builtin = @import("builtin");
const worker = @import("../core/worker.zig");

pub const Stream = enum { stdout, stderr };

pub const Event = union(enum) {
    /// Bytes the child wrote (owned by the event: call `deinit`).
    chunk: struct { stream: Stream, bytes: []u8 },
    /// The process ended.
    exited: std.process.Child.Term,

    pub fn deinit(self: *Event, gpa: std.mem.Allocator) void {
        switch (self.*) {
            .chunk => |c| gpa.free(c.bytes),
            .exited => {},
        }
    }
};

pub const Options = struct {
    argv: []const []const u8,
    /// Working directory (default: ours).
    cwd: ?[]const u8 = null,
    /// Keep a pipe to the child's stdin (`writeStdin`); otherwise it reads nothing.
    stdin: bool = false,
    /// Called from the reader threads after output arrives (see `Queue.wake`).
    wake: ?*const fn () void = null,
};

pub const Runner = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    child: std.process.Child,
    queue: worker.Queue(Event),
    readers: [2]?std.Thread = .{ null, null },
    waiter: ?std.Thread = null,
    done: std.atomic.Value(bool) = .init(false),
    pid_valid: bool = true,

    pub fn start(gpa: std.mem.Allocator, io: std.Io, opts: Options) !*Runner {
        const self = try gpa.create(Runner);
        errdefer gpa.destroy(self);
        const child = try std.process.spawn(io, .{
            .argv = opts.argv,
            .cwd = if (opts.cwd) |p| .{ .path = p } else .inherit,
            .stdin = if (opts.stdin) .pipe else .ignore,
            .stdout = .pipe,
            .stderr = .pipe,
        });
        self.* = .{ .gpa = gpa, .io = io, .child = child, .queue = .{ .gpa = gpa, .wake = opts.wake } };
        errdefer self.queue.deinit();
        self.readers[0] = try std.Thread.spawn(.{}, readLoop, .{ self, Stream.stdout });
        errdefer if (self.readers[0]) |t| t.join();
        self.readers[1] = try std.Thread.spawn(.{}, readLoop, .{ self, Stream.stderr });
        errdefer if (self.readers[1]) |t| t.join();
        self.waiter = try std.Thread.spawn(.{}, waitLoop, .{self});
        return self;
    }

    fn readLoop(self: *Runner, which: Stream) void {
        const file = (if (which == .stdout) self.child.stdout else self.child.stderr) orelse return;
        var buf: [4096]u8 = undefined;
        while (true) {
            var vec = [_][]u8{&buf};
            const n = file.readStreaming(self.io, &vec) catch return;
            if (n == 0) return;
            const bytes = self.gpa.dupe(u8, buf[0..n]) catch return;
            self.queue.push(.{ .chunk = .{ .stream = which, .bytes = bytes } }) catch {
                self.gpa.free(bytes);
                return;
            };
        }
    }

    fn waitLoop(self: *Runner) void {
        // The readers see end-of-file when the child (and anything inheriting
        // its pipes) is done; wait for them, then reap the child.
        for (self.readers) |maybe| if (maybe) |t| t.join();
        self.readers = .{ null, null };
        const term = self.child.wait(self.io) catch std.process.Child.Term{ .unknown = 0 };
        self.pid_valid = false;
        self.queue.push(.{ .exited = term }) catch {};
        self.done.store(true, .release);
    }

    /// Move the output and exit events that arrived onto `out` (UI thread).
    pub fn drain(self: *Runner, out: *std.ArrayListUnmanaged(Event)) void {
        self.queue.drain(out);
    }

    /// True once the process has exited and its exit event has been queued.
    pub fn finished(self: *const Runner) bool {
        return self.done.load(.acquire);
    }

    /// Write to the child's stdin (needs `Options.stdin`).
    pub fn writeStdin(self: *Runner, bytes: []const u8) !void {
        const f = self.child.stdin orelse return error.NoStdin;
        var buf: [256]u8 = undefined;
        var w = f.writerStreaming(self.io, &buf);
        try w.interface.writeAll(bytes);
        try w.interface.flush();
    }

    /// Ask the process to end.
    pub fn stop(self: *Runner) void {
        if (builtin.os.tag == .windows) return;
        if (self.finished()) return;
        if (self.child.id) |pid| std.posix.kill(pid, .TERM) catch {};
    }

    /// Stop the process if it is still running, wait for the threads, free everything.
    pub fn destroy(self: *Runner) void {
        if (!self.finished()) {
            if (builtin.os.tag != .windows) {
                if (self.child.id) |pid| std.posix.kill(pid, .KILL) catch {};
            }
        }
        if (self.waiter) |t| t.join();
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

fn waitForExit(run: *Runner, out: *std.ArrayListUnmanaged(Event)) !void {
    var tries: usize = 0;
    while (!run.finished() and tries < 2000) : (tries += 1) {
        run.drain(out);
        std.Thread.yield() catch {};
        var ts: std.os.linux.timespec = .{ .sec = 0, .nsec = 1_000_000 };
        _ = std.os.linux.nanosleep(&ts, null);
    }
    run.drain(out);
    try testing.expect(run.finished());
}

fn collect(batch: []Event, stream: Stream, gpa: std.mem.Allocator) ![]u8 {
    var all: std.ArrayListUnmanaged(u8) = .empty;
    errdefer all.deinit(gpa);
    for (batch) |e| switch (e) {
        .chunk => |c| if (c.stream == stream) try all.appendSlice(gpa, c.bytes),
        .exited => {},
    };
    return all.toOwnedSlice(gpa);
}

test "a child's stdout and stderr stay separate and its exit status arrives" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const run = try Runner.start(testing.allocator, testing.io, .{ .argv = &.{ "/bin/sh", "-c", "echo out; echo err 1>&2; exit 3" } });
    defer run.destroy();
    var batch: std.ArrayListUnmanaged(Event) = .empty;
    defer {
        for (batch.items) |*e| e.deinit(testing.allocator);
        batch.deinit(testing.allocator);
    }
    try waitForExit(run, &batch);
    const out = try collect(batch.items, .stdout, testing.allocator);
    defer testing.allocator.free(out);
    const err = try collect(batch.items, .stderr, testing.allocator);
    defer testing.allocator.free(err);
    try testing.expectEqualStrings("out\n", out);
    try testing.expectEqualStrings("err\n", err);
    var exit: ?u8 = null;
    for (batch.items) |e| switch (e) {
        .exited => |t| exit = switch (t) {
            .exited => |c| c,
            else => 255,
        },
        .chunk => {},
    };
    try testing.expectEqual(@as(?u8, 3), exit);
}

test "stdin reaches the child; the working directory is honored; stop ends a long run" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    {
        const run = try Runner.start(testing.allocator, testing.io, .{ .argv = &.{ "/bin/sh", "-c", "read x; echo got $x; pwd" }, .stdin = true, .cwd = "/tmp" });
        defer run.destroy();
        try run.writeStdin("hello\n");
        var batch: std.ArrayListUnmanaged(Event) = .empty;
        defer {
            for (batch.items) |*e| e.deinit(testing.allocator);
            batch.deinit(testing.allocator);
        }
        try waitForExit(run, &batch);
        const out = try collect(batch.items, .stdout, testing.allocator);
        defer testing.allocator.free(out);
        try testing.expectEqualStrings("got hello\n/tmp\n", out);
    }
    {
        const run = try Runner.start(testing.allocator, testing.io, .{ .argv = &.{ "/bin/sh", "-c", "sleep 30" } });
        defer run.destroy();
        run.stop();
        var batch: std.ArrayListUnmanaged(Event) = .empty;
        defer {
            for (batch.items) |*e| e.deinit(testing.allocator);
            batch.deinit(testing.allocator);
        }
        try waitForExit(run, &batch);
        var signaled = false;
        for (batch.items) |e| switch (e) {
            .exited => |t| signaled = t == .signal,
            .chunk => {},
        };
        try testing.expect(signaled);
    }
}
