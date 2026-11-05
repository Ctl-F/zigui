//! zigct: the comptime debugger. It is a Zig 0.17.0 compiler with a debugger built in
//! (`tools/zigct`), run as `zigct dap-comptime` and spoken to with the Debug Adapter Protocol,
//! so `client.zig` and `session.zig` talk to it like to any adapter. This file finds the
//! binary and has a scripted driver (used by the golden-transcript tests in `test/ct/`).
//!
//! `launch` arguments (all optional but `zigArgs`):
//!     zigArgs    ["root.zig", "--dep", "x", "-Mx=...", ...]   what `zig build-obj` gets
//!     sourceRoot stops only in files below this directory (the standard library is skipped)
//!     cacheDir   the compiler's own cache (never the real one: its ZIR carries extra markers)
//!     stopOnEntry  stop at the first statement in scope
//!     target     {file, startLine, endLine}: ignore everything until a statement in that range
//!                runs; when the block it is in finishes, the session ends

const std = @import("std");
const client_mod = @import("client.zig");
const process = @import("../../platform/process.zig");
const pty_common = @import("../../platform/pty_common.zig");

const testing = std.testing;

pub const version = "0.17.0";

/// The zigct binary: `ZIGUI_ZIGCT`, else `~/.cache/zigui-ide/zigct/<version>/bin/zigct`. Null when not built.
pub fn find(gpa: std.mem.Allocator, io: std.Io, environ: ?*const std.process.Environ.Map) ?[]u8 {
    const env = environ orelse return null;
    if (env.get("ZIGUI_ZIGCT")) |p| return gpa.dupe(u8, p) catch null;
    const home = env.get("HOME") orelse return null;
    const path = std.fmt.allocPrint(gpa, "{s}/.cache/zigui-ide/zigct/{s}/bin/zigct", .{ home, version }) catch return null;
    std.Io.Dir.cwd().access(io, path, .{}) catch {
        gpa.free(path);
        return null;
    };
    return path;
}

const build_sh = @embedFile("zigct_build_sh");
const patch_0001 = @embedFile("zigct_patch_0001");

/// Write the build script and its patch under `~/.cache/zigui-ide/zigct/tool/` and return the
/// script's path (run it with `sh`): zigct is built from the official source on request.
pub fn installTool(gpa: std.mem.Allocator, io: std.Io, environ: ?*const std.process.Environ.Map) ![]u8 {
    const home = (environ orelse return error.NoHome).get("HOME") orelse return error.NoHome;
    const dir = try std.fmt.allocPrint(gpa, "{s}/.cache/zigui-ide/zigct/tool", .{home});
    defer gpa.free(dir);
    const patches = try std.fmt.allocPrint(gpa, "{s}/patches/{s}", .{ dir, version });
    defer gpa.free(patches);
    try std.Io.Dir.cwd().createDirPath(io, patches);
    const script = try std.fmt.allocPrint(gpa, "{s}/build.sh", .{dir});
    errdefer gpa.free(script);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = script, .data = build_sh });
    const patch_path = try std.fmt.allocPrint(gpa, "{s}/0001-zigct-comptime-debugger.patch", .{patches});
    defer gpa.free(patch_path);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = patch_path, .data = patch_0001 });
    return script;
}

// ---- the scripted driver ----

pub const Driver = struct {
    gpa: std.mem.Allocator,
    runner: *process.Runner,
    client: *client_mod.Client,
    batch: std.ArrayListUnmanaged(process.Event) = .empty,
    /// The last response body, as JSON text (null while waiting).
    answer: ?[]u8 = null,
    answer_ok: bool = true,
    stopped: bool = false,
    stop_reason: [64]u8 = undefined,
    stop_reason_len: usize = 0,
    stop_text: ?[]u8 = null,
    terminated: bool = false,
    adapter_exited: bool = false,
    exit_rounds: u32 = 0,
    stderr: std.ArrayListUnmanaged(u8) = .empty,

    pub fn start(gpa: std.mem.Allocator, io: std.Io, zigct: []const u8, cwd: []const u8) !*Driver {
        const self = try gpa.create(Driver);
        errdefer gpa.destroy(self);
        self.* = .{ .gpa = gpa, .runner = undefined, .client = undefined };
        self.client = try client_mod.Client.create(gpa, .{ .ctx = self, .call = write });
        errdefer self.client.destroy();
        self.client.on_event = client_mod.EventHook.bind(self, onEvent);
        self.runner = try process.Runner.start(gpa, io, .{ .argv = &.{ zigct, "dap-comptime" }, .cwd = cwd, .stdin = true });
        return self;
    }

    pub fn destroy(self: *Driver) void {
        self.runner.destroy();
        for (self.batch.items) |*e| e.deinit(self.gpa);
        self.batch.deinit(self.gpa);
        if (self.answer) |a| self.gpa.free(a);
        if (self.stop_text) |t| self.gpa.free(t);
        self.stderr.deinit(self.gpa);
        self.client.destroy();
        self.gpa.destroy(self);
    }

    fn write(ctx: ?*anyopaque, bytes: []const u8) void {
        const self: *Driver = @ptrCast(@alignCast(ctx.?));
        self.runner.writeStdin(bytes) catch {};
    }

    fn onEvent(self: *Driver, name: []const u8, body: std.json.Value) void {
        if (std.mem.eql(u8, name, "stopped")) {
            self.stopped = true;
            const r = client_mod.strOf(if (body == .object) body.object.get("reason") else null) orelse "";
            self.stop_reason_len = @min(r.len, self.stop_reason.len);
            @memcpy(self.stop_reason[0..self.stop_reason_len], r[0..self.stop_reason_len]);
            if (self.stop_text) |t| self.gpa.free(t);
            const t = client_mod.strOf(if (body == .object) body.object.get("text") else null) orelse "";
            self.stop_text = self.gpa.dupe(u8, t) catch null;
        } else if (std.mem.eql(u8, name, "terminated")) {
            self.terminated = true;
        }
    }

    fn onResponse(self: *Driver, res: *const client_mod.Response) void {
        self.answer_ok = res.ok;
        if (self.answer) |a| self.gpa.free(a);
        self.answer = std.json.Stringify.valueAlloc(self.gpa, res.body, .{}) catch null;
        if (self.answer == null) self.answer = self.gpa.dupe(u8, "null") catch null;
    }

    /// Read what the process wrote (and exits). One step of waiting.
    pub fn pump(self: *Driver) void {
        self.runner.drain(&self.batch);
        for (self.batch.items) |*e| {
            switch (e.*) {
                .chunk => |c| switch (c.stream) {
                    .stdout => self.client.receive(c.bytes),
                    .stderr => self.stderr.appendSlice(self.gpa, c.bytes) catch {},
                },
                .exited => self.adapter_exited = true,
            }
            e.deinit(self.gpa);
        }
        self.batch.clearRetainingCapacity();
        pty_common.sleepMs(2);
    }

    /// The process ended and its output has been read: the exit event can overtake the last
    /// stdout chunk (separate threads), so a few more rounds are given.
    fn exitedForGood(self: *Driver) bool {
        if (!self.adapter_exited) return false;
        self.exit_rounds += 1;
        return self.exit_rounds > 50;
    }

    /// Send a request and wait for its response (the JSON text of its body, owned by the driver until the next call).
    pub fn call(self: *Driver, command: []const u8, args: anytype) ![]const u8 {
        if (self.answer) |a| self.gpa.free(a);
        self.answer = null;
        _ = try self.client.request(command, args, client_mod.ResponseHook.bind(self, onResponse));
        var tries: usize = 0;
        while (self.answer == null) : (tries += 1) {
            if (tries > 30_000 or self.exitedForGood()) return error.NoAnswer;
            self.pump();
        }
        if (!self.answer_ok) return error.Refused;
        return self.answer.?;
    }

    /// Wait until the session stops or ends (the caller cleared `stopped` before resuming: the
    /// event can arrive while the resume request is still being answered).
    pub fn waitStop(self: *Driver) !void {
        var tries: usize = 0;
        while (!self.stopped and !self.terminated) : (tries += 1) {
            if (tries > 30_000 or self.exitedForGood()) return error.NoStop;
            self.pump();
        }
    }
};

/// Run a script against zigct and return the transcript. Script lines:
///     root FILE            the file given to the compiler (relative to `dir`)
///     entry                stop at the first statement
///     target FILE A B      only the block spanning lines A..B of FILE
///     break FILE LINE      a breakpoint
///     errors               stop when a compile error is raised
///     run                  start; stops are recorded
///     next | in | out | continue
/// Every stop adds its frames (in scope, innermost first) and the locals of the top frame.
pub fn runScript(gpa: std.mem.Allocator, io: std.Io, zigct: []const u8, zig_lib: []const u8, dir: []const u8, cache: []const u8, script: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(gpa);
    const d = try Driver.start(gpa, io, zigct, dir);
    defer d.destroy();

    var root: []const u8 = "";
    var entry = false;
    var target: ?struct { file: []const u8, a: u32, b: u32 } = null;
    var errors = false;
    var breaks: std.ArrayListUnmanaged(struct { file: []const u8, line: u32 }) = .empty;
    defer breaks.deinit(gpa);

    var lines = std.mem.splitScalar(u8, script, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        if (d.terminated) break; // the session is over; the rest of the script has nothing to act on
        var it = std.mem.tokenizeScalar(u8, line, ' ');
        const verb = it.next().?;
        if (std.mem.eql(u8, verb, "root")) {
            root = it.next().?;
        } else if (std.mem.eql(u8, verb, "entry")) {
            entry = true;
        } else if (std.mem.eql(u8, verb, "errors")) {
            errors = true;
        } else if (std.mem.eql(u8, verb, "target")) {
            const f = it.next().?;
            target = .{ .file = f, .a = try std.fmt.parseInt(u32, it.next().?, 10), .b = try std.fmt.parseInt(u32, it.next().?, 10) };
        } else if (std.mem.eql(u8, verb, "break")) {
            const f = it.next().?;
            try breaks.append(gpa, .{ .file = f, .line = try std.fmt.parseInt(u32, it.next().?, 10) });
        } else if (std.mem.eql(u8, verb, "run")) {
            _ = try d.call("initialize", .{ .adapterID = "zigui-test" });
            const root_abs = try std.fs.path.join(gpa, &.{ dir, root });
            defer gpa.free(root_abs);
            var tfile: ?[]u8 = null;
            defer if (tfile) |t| gpa.free(t);
            if (target) |t| tfile = try std.fs.path.join(gpa, &.{ dir, t.file });
            _ = try d.call("launch", .{
                .zigArgs = [_][]const u8{ root_abs, "--zig-lib-dir", zig_lib },
                .sourceRoot = dir,
                .cacheDir = cache,
                .stopOnEntry = entry,
                .target = if (target) |t| .{ .file = tfile.?, .startLine = t.a, .endLine = t.b } else null,
            });
            for (breaks.items) |b| {
                const bf = try std.fs.path.join(gpa, &.{ dir, b.file });
                defer gpa.free(bf);
                _ = try d.call("setBreakpoints", .{ .source = .{ .path = bf }, .breakpoints = [_]struct { line: u32 }{.{ .line = b.line }} });
            }
            _ = try d.call("setExceptionBreakpoints", .{ .filters = if (errors) &[_][]const u8{"compile_error"} else &[_][]const u8{} });
            d.stopped = false;
            _ = try d.call("configurationDone", .{});
            try d.waitStop();
            try transcript(gpa, d, dir, &out);
        } else if (std.mem.eql(u8, verb, "next") or std.mem.eql(u8, verb, "in") or std.mem.eql(u8, verb, "out") or std.mem.eql(u8, verb, "continue")) {
            const cmd: []const u8 = if (verb[0] == 'n') "next" else if (verb[0] == 'i') "stepIn" else if (verb[0] == 'o') "stepOut" else "continue";
            d.stopped = false;
            _ = try d.call(cmd, .{ .threadId = 1 });
            try d.waitStop();
            try transcript(gpa, d, dir, &out);
        } else return error.BadScript;
    }
    _ = d.call("disconnect", .{}) catch {};
    return out.toOwnedSlice(gpa);
}

fn transcript(gpa: std.mem.Allocator, d: *Driver, dir: []const u8, out: *std.ArrayListUnmanaged(u8)) !void {
    if (d.terminated) {
        try out.appendSlice(gpa, "terminated\n");
        return;
    }
    const reason = d.stop_reason[0..d.stop_reason_len];
    try out.print(gpa, "stopped {s}", .{reason});
    if (d.stop_text) |t| if (t.len > 0) try out.print(gpa, ": {s}", .{t});
    try out.append(gpa, '\n');
    const st = try d.call("stackTrace", .{ .threadId = 1 });
    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, st, .{});
    defer parsed.deinit();
    var top_id: i64 = 0;
    var first = true;
    const frames = client_mod.arrayOf(parsed.value.object.get("stackFrames"));
    for (frames) |f| {
        const o = f.object;
        if (o.get("presentationHint") != null) continue;
        const path = client_mod.strOf(o.get("source").?.object.get("path")) orelse "";
        const rel = if (std.mem.startsWith(u8, path, dir)) std.mem.trimStart(u8, path[dir.len..], "/") else path;
        try out.print(gpa, "  {s} {s}:{d}\n", .{ client_mod.strOf(o.get("name")) orelse "?", rel, client_mod.intOf(o.get("line")) orelse 0 });
        if (first) {
            top_id = client_mod.intOf(o.get("id")) orelse 0;
            first = false;
        }
    }
    if (first) return;
    const sc = try d.call("scopes", .{ .frameId = top_id });
    var sp = try std.json.parseFromSlice(std.json.Value, gpa, sc, .{});
    defer sp.deinit();
    const ref = client_mod.intOf(client_mod.arrayOf(sp.value.object.get("scopes"))[0].object.get("variablesReference")) orelse 0;
    const vs = try d.call("variables", .{ .variablesReference = ref });
    var vp = try std.json.parseFromSlice(std.json.Value, gpa, vs, .{});
    defer vp.deinit();
    var sep: []const u8 = "  | ";
    for (client_mod.arrayOf(vp.value.object.get("variables"))) |v| {
        try out.print(gpa, "{s}{s} = {s}", .{ sep, client_mod.strOf(v.object.get("name")) orelse "?", client_mod.strOf(v.object.get("value")) orelse "?" });
        sep = ", ";
    }
    if (!std.mem.eql(u8, sep, "  | ")) try out.append(gpa, '\n');
}

// ---- golden transcripts ----

fn zigLibDir(gpa: std.mem.Allocator, io: std.Io) ?[]u8 {
    const r = std.process.run(gpa, io, .{ .argv = &.{ "zig", "env" } }) catch return null;
    defer gpa.free(r.stdout);
    defer gpa.free(r.stderr);
    const key = ".lib_dir = \"";
    const i = std.mem.indexOf(u8, r.stdout, key) orelse return null;
    const rest = r.stdout[i + key.len ..];
    const j = std.mem.indexOfScalar(u8, rest, '"') orelse return null;
    return gpa.dupe(u8, rest[0..j]) catch null;
}

/// Run `test/ct/NAME.script` and compare with `NAME.golden` (set ZIGUI_UPDATE_GOLDEN=1 to rewrite it).
fn golden(name: []const u8) !void {
    const gpa = testing.allocator;
    const io = testing.io;
    var env = try testing.environ.createMap(gpa);
    defer env.deinit();
    const zigct = find(gpa, io, &env) orelse {
        std.debug.print("zigct is not built: skipping the comptime debugger transcripts (tools/zigct/build.sh)\n", .{});
        return error.SkipZigTest;
    };
    defer gpa.free(zigct);
    const lib = zigLibDir(gpa, io) orelse return error.SkipZigTest;
    defer gpa.free(lib);

    const cwd = try std.process.currentPathAlloc(io, gpa);
    defer gpa.free(cwd);
    const dir = try std.fs.path.join(gpa, &.{ cwd, "test", "ct" });
    defer gpa.free(dir);
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const cache = try std.fmt.allocPrint(gpa, "{s}/.zig-cache/tmp/{s}", .{ cwd, tmp.sub_path });
    defer gpa.free(cache);

    const script_path = try std.fmt.allocPrint(gpa, "test/ct/{s}.script", .{name});
    defer gpa.free(script_path);
    const script = try std.Io.Dir.cwd().readFileAlloc(io, script_path, gpa, .limited(1 << 20));
    defer gpa.free(script);
    const got = try runScript(gpa, io, zigct, lib, dir, cache, script);
    defer gpa.free(got);

    const golden_path = try std.fmt.allocPrint(gpa, "test/ct/{s}.golden", .{name});
    defer gpa.free(golden_path);
    if (env.get("ZIGUI_UPDATE_GOLDEN") != null) {
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = golden_path, .data = got });
        return;
    }
    const want = try std.Io.Dir.cwd().readFileAlloc(io, golden_path, gpa, .limited(1 << 20));
    defer gpa.free(want);
    if (!std.mem.eql(u8, want, got)) {
        std.debug.print("--- expected ({s})\n{s}--- got\n{s}---\n", .{ golden_path, want, got });
        return error.TestExpectedEqual;
    }
}

test "zigct: breakpoints, stepping in/over/out and comptime var in a loop" {
    try golden("loop");
}

test "zigct: structs, arrays, slices and enums as locals" {
    try golden("values");
}

test "zigct: stop at a compile error before the stack unwinds" {
    try golden("error");
}

test "zigct: a target block in another file, entry stop, the session ends with the block" {
    try golden("target");
}

test "the build script and the patch are embedded" {
    try testing.expect(std.mem.startsWith(u8, build_sh, "#!/bin/sh"));
    try testing.expect(std.mem.indexOf(u8, patch_0001, "zct_hook.zig") != null);
}

test "installTool writes the build script and the patch where the script expects them" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd = try std.process.currentPathAlloc(io, gpa);
    defer gpa.free(cwd);
    const home = try std.fmt.allocPrint(gpa, "{s}/.zig-cache/tmp/{s}", .{ cwd, tmp.sub_path });
    defer gpa.free(home);
    var env = std.process.Environ.Map.init(gpa);
    defer env.deinit();
    try env.put("HOME", home);
    const script = try installTool(gpa, io, &env);
    defer gpa.free(script);
    try testing.expect(std.mem.endsWith(u8, script, "/zigct/tool/build.sh"));
    const sh = try std.Io.Dir.cwd().readFileAlloc(io, script, gpa, .limited(1 << 20));
    defer gpa.free(sh);
    try testing.expectEqualStrings(build_sh, sh);
    const dir = std.fs.path.dirname(script).?;
    const pp = try std.fmt.allocPrint(gpa, "{s}/patches/0.17.0/0001-zigct-comptime-debugger.patch", .{dir});
    defer gpa.free(pp);
    const patch = try std.Io.Dir.cwd().readFileAlloc(io, pp, gpa, .limited(1 << 22));
    defer gpa.free(patch);
    try testing.expectEqualStrings(patch_0001, patch);
}
