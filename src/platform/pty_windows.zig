//! Windows backend of `pty.zig`: ConPTY (Windows 10 version 1809 and later).
//! `CreatePseudoConsole` gives a console the program believes in; the terminal
//! side is two pipes carrying VT text, which is exactly what `terminal/vt.zig`
//! understands.
//!
//! Threads: a reader blocks in `ReadFile` on the output pipe and posts data;
//! a waiter watches the process, and when it ends closes the pseudo-console
//! (which ends the output pipe, so the reader finishes), then posts `.exited`.
//!
//! Not run by the project's own CI (no Windows machine): it compiles for
//! x86_64-windows and aarch64-windows but has not been exercised on one. Check
//! it first when something is wrong on Windows.

const std = @import("std");
const worker = @import("../core/worker.zig");
const common = @import("pty_common.zig");
const Event = common.Event;
const Options = common.Options;
const sleepMs = common.sleepMs;

const HANDLE = ?*anyopaque;
const BOOL = c_int;
const DWORD = u32;
const HPCON = ?*anyopaque;
const Coord = extern struct { x: i16, y: i16 };

const StartupInfoW = extern struct {
    cb: DWORD = @sizeOf(StartupInfoW),
    reserved: ?[*:0]u16 = null,
    desktop: ?[*:0]u16 = null,
    title: ?[*:0]u16 = null,
    x: DWORD = 0,
    y: DWORD = 0,
    x_size: DWORD = 0,
    y_size: DWORD = 0,
    x_chars: DWORD = 0,
    y_chars: DWORD = 0,
    fill: DWORD = 0,
    flags: DWORD = 0,
    show: u16 = 0,
    reserved2_size: u16 = 0,
    reserved2: ?*u8 = null,
    std_in: HANDLE = null,
    std_out: HANDLE = null,
    std_err: HANDLE = null,
};
const StartupInfoExW = extern struct {
    info: StartupInfoW = .{},
    attribute_list: ?*anyopaque = null,
};
const ProcessInformation = extern struct {
    process: HANDLE = null,
    thread: HANDLE = null,
    process_id: DWORD = 0,
    thread_id: DWORD = 0,
};

const winapi = std.builtin.CallingConvention.winapi;
extern "kernel32" fn CreatePipe(read: *HANDLE, write: *HANDLE, attrs: ?*anyopaque, size: DWORD) callconv(winapi) BOOL;
extern "kernel32" fn CloseHandle(h: HANDLE) callconv(winapi) BOOL;
extern "kernel32" fn ReadFile(h: HANDLE, buf: [*]u8, len: DWORD, read: ?*DWORD, overlapped: ?*anyopaque) callconv(winapi) BOOL;
extern "kernel32" fn WriteFile(h: HANDLE, buf: [*]const u8, len: DWORD, written: ?*DWORD, overlapped: ?*anyopaque) callconv(winapi) BOOL;
extern "kernel32" fn CreatePseudoConsole(size: Coord, input: HANDLE, output: HANDLE, flags: DWORD, out: *HPCON) callconv(winapi) i32;
extern "kernel32" fn ResizePseudoConsole(h: HPCON, size: Coord) callconv(winapi) i32;
extern "kernel32" fn ClosePseudoConsole(h: HPCON) callconv(winapi) void;
extern "kernel32" fn InitializeProcThreadAttributeList(list: ?*anyopaque, count: DWORD, flags: DWORD, size: *usize) callconv(winapi) BOOL;
extern "kernel32" fn UpdateProcThreadAttribute(list: ?*anyopaque, flags: DWORD, attr: usize, value: ?*anyopaque, size: usize, prev: ?*anyopaque, ret_size: ?*usize) callconv(winapi) BOOL;
extern "kernel32" fn DeleteProcThreadAttributeList(list: ?*anyopaque) callconv(winapi) void;
extern "kernel32" fn CreateProcessW(app: ?[*:0]const u16, cmd: ?[*:0]u16, pattrs: ?*anyopaque, tattrs: ?*anyopaque, inherit: BOOL, flags: DWORD, env: ?*anyopaque, cwd: ?[*:0]const u16, si: *StartupInfoW, pi: *ProcessInformation) callconv(winapi) BOOL;
extern "kernel32" fn WaitForSingleObject(h: HANDLE, ms: DWORD) callconv(winapi) DWORD;
extern "kernel32" fn GetExitCodeProcess(h: HANDLE, code: *DWORD) callconv(winapi) BOOL;
extern "kernel32" fn TerminateProcess(h: HANDLE, code: u32) callconv(winapi) BOOL;

const PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE: usize = 0x00020016;
const EXTENDED_STARTUPINFO_PRESENT: DWORD = 0x00080000;
const CREATE_UNICODE_ENVIRONMENT: DWORD = 0x00000400;
const WAIT_TIMEOUT: DWORD = 258;

/// The command line for `argv` with the quoting `CommandLineToArgvW` undoes.
fn commandLine(a: std.mem.Allocator, argv: []const []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    for (argv, 0..) |arg, i| {
        if (i > 0) try out.append(a, ' ');
        const plain = arg.len > 0 and std.mem.indexOfAny(u8, arg, " \t\n\x0b\"") == null;
        if (plain) {
            try out.appendSlice(a, arg);
            continue;
        }
        try out.append(a, '"');
        var backslashes: usize = 0;
        for (arg) |ch| {
            if (ch == '\\') {
                backslashes += 1;
                continue;
            }
            if (ch == '"') {
                try out.appendNTimes(a, '\\', backslashes * 2 + 1);
            } else {
                try out.appendNTimes(a, '\\', backslashes);
            }
            backslashes = 0;
            try out.append(a, ch);
        }
        try out.appendNTimes(a, '\\', backslashes * 2);
        try out.append(a, '"');
    }
    return out.toOwnedSlice(a);
}

/// A UTF-16 environment block ("A=1\0B=2\0\0") from a map, or null for "inherit".
fn environmentBlock(a: std.mem.Allocator, environ: ?*const std.process.Environ.Map) !?[]u16 {
    const m = environ orelse return null;
    var text: std.ArrayListUnmanaged(u8) = .empty;
    var it = m.iterator();
    while (it.next()) |kv| {
        try text.appendSlice(a, kv.key_ptr.*);
        try text.append(a, '=');
        try text.appendSlice(a, kv.value_ptr.*);
        try text.append(a, 0);
    }
    try text.append(a, 0);
    if (text.items.len == 1) try text.append(a, 0);
    return try std.unicode.utf8ToUtf16LeAlloc(a, text.items);
}

pub const Pty = struct {
    gpa: std.mem.Allocator,
    /// Our ends of the two pipes.
    input_write: HANDLE,
    output_read: HANDLE,
    hpc: HPCON,
    process: HANDLE,
    queue: worker.Queue(Event),
    reader: ?std.Thread = null,
    waiter: ?std.Thread = null,
    lock: std.atomic.Mutex = .unlocked,
    pc_closed: bool = false,
    stop_flag: std.atomic.Value(bool) = .init(false),
    done: std.atomic.Value(bool) = .init(false),

    pub fn open(gpa: std.mem.Allocator, opts: Options) !*Pty {
        const self = try gpa.create(Pty);
        errdefer gpa.destroy(self);

        var in_read: HANDLE = null;
        var in_write: HANDLE = null;
        var out_read: HANDLE = null;
        var out_write: HANDLE = null;
        if (CreatePipe(&in_read, &in_write, null, 0) == 0) return error.OpenFailed;
        errdefer _ = CloseHandle(in_write);
        if (CreatePipe(&out_read, &out_write, null, 0) == 0) {
            _ = CloseHandle(in_read);
            return error.OpenFailed;
        }
        errdefer _ = CloseHandle(out_read);

        var hpc: HPCON = null;
        const size: Coord = .{ .x = @intCast(opts.cols), .y = @intCast(opts.rows) };
        const hr = CreatePseudoConsole(size, in_read, out_write, 0, &hpc);
        // The pseudo-console keeps its own copies of these two ends.
        _ = CloseHandle(in_read);
        _ = CloseHandle(out_write);
        if (hr < 0) return error.Unsupported; // Windows older than 10 1809
        errdefer ClosePseudoConsole(hpc);

        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        const a = arena.allocator();

        // The attribute list that attaches the process to the pseudo-console.
        var list_size: usize = 0;
        _ = InitializeProcThreadAttributeList(null, 1, 0, &list_size);
        const list_mem = try a.alignedAlloc(u8, .@"16", list_size);
        const list: ?*anyopaque = list_mem.ptr;
        if (InitializeProcThreadAttributeList(list, 1, 0, &list_size) == 0) return error.OpenFailed;
        defer DeleteProcThreadAttributeList(list);
        if (UpdateProcThreadAttribute(list, 0, PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE, hpc, @sizeOf(HPCON), null, null) == 0) return error.OpenFailed;

        const base: []const []const u8 = if (opts.argv.len > 0) opts.argv else &.{common.defaultShell(opts.environ)};
        const cmd8 = try commandLine(a, base);
        const cmd = try std.unicode.utf8ToUtf16LeAllocZ(a, cmd8);
        const env = try environmentBlock(a, opts.environ);
        const cwd: ?[:0]u16 = if (opts.cwd) |d| try std.unicode.utf8ToUtf16LeAllocZ(a, d) else null;

        var si: StartupInfoExW = .{};
        si.info.cb = @sizeOf(StartupInfoExW);
        si.attribute_list = list;
        var pi: ProcessInformation = .{};
        const flags = EXTENDED_STARTUPINFO_PRESENT | CREATE_UNICODE_ENVIRONMENT;
        if (CreateProcessW(null, cmd.ptr, null, null, 0, flags, if (env) |e| e.ptr else null, if (cwd) |d| d.ptr else null, &si.info, &pi) == 0) return error.SpawnFailed;
        _ = CloseHandle(pi.thread);

        self.* = .{
            .gpa = gpa,
            .input_write = in_write,
            .output_read = out_read,
            .hpc = hpc,
            .process = pi.process,
            .queue = .{ .gpa = gpa, .wake = opts.wake },
        };
        errdefer self.queue.deinit();
        self.reader = try std.Thread.spawn(.{}, readLoop, .{self});
        self.waiter = std.Thread.spawn(.{}, waitLoop, .{self}) catch |err| {
            _ = TerminateProcess(self.process, 1);
            self.closePseudoConsole();
            self.reader.?.join();
            return err;
        };
        return self;
    }

    fn closePseudoConsole(self: *Pty) void {
        while (!self.lock.tryLock()) std.atomic.spinLoopHint();
        defer self.lock.unlock();
        if (self.pc_closed) return;
        self.pc_closed = true;
        ClosePseudoConsole(self.hpc);
    }

    fn readLoop(self: *Pty) void {
        var buf: [8192]u8 = undefined;
        while (true) {
            var got: DWORD = 0;
            if (ReadFile(self.output_read, &buf, buf.len, &got, null) == 0 or got == 0) break; // the pipe ends when the console closes
            const bytes = self.gpa.dupe(u8, buf[0..got]) catch break;
            self.queue.push(.{ .data = bytes }) catch {
                self.gpa.free(bytes);
                break;
            };
        }
    }

    fn waitLoop(self: *Pty) void {
        while (WaitForSingleObject(self.process, 100) == WAIT_TIMEOUT) {
            if (self.stop_flag.load(.acquire)) {
                _ = TerminateProcess(self.process, 1);
                break;
            }
        }
        var code: DWORD = 0;
        const have = GetExitCodeProcess(self.process, &code) != 0;
        // Closing the console flushes what is left and ends the output pipe.
        self.closePseudoConsole();
        if (self.reader) |t| t.join();
        self.reader = null;
        self.queue.push(.{ .exited = if (have) @bitCast(code) else -1 }) catch {};
        self.done.store(true, .release);
        if (self.queue.wake) |w| w();
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
            var n: DWORD = 0;
            const chunk: DWORD = @intCast(@min(rest.len, 1 << 16));
            if (WriteFile(self.input_write, rest.ptr, chunk, &n, null) == 0) return error.WriteFailed;
            rest = rest[n..];
        }
    }

    pub fn resize(self: *Pty, cols: u16, rows: u16) void {
        while (!self.lock.tryLock()) std.atomic.spinLoopHint();
        defer self.lock.unlock();
        if (self.pc_closed) return;
        _ = ResizePseudoConsole(self.hpc, .{ .x = @intCast(cols), .y = @intCast(rows) });
    }

    pub fn close(self: *Pty) void {
        self.stop_flag.store(true, .release);
        if (self.waiter) |t| t.join();
        _ = CloseHandle(self.process);
        _ = CloseHandle(self.input_write);
        _ = CloseHandle(self.output_read);
        var left: std.ArrayListUnmanaged(Event) = .empty;
        self.queue.drain(&left);
        for (left.items) |*e| e.deinit(self.gpa);
        left.deinit(self.gpa);
        self.queue.deinit();
        self.gpa.destroy(self);
    }
};
