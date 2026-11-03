//! ZVM (the Zig version manager, https://www.zvm.app) as a service: find it,
//! list the Zig versions it has installed and the ones it can install, read
//! which version a project wants, and build the commands that install and
//! switch versions. No UI here (`zig_versions.zig` is the IDE side).
//!
//!     var z = (try zvm.locate(gpa, io, environ)) orelse return;   // null: ZVM is not installed
//!     defer z.deinit(gpa);
//!     const have = try zvm.installed(gpa, io, z.home);            // "master", "0.17.0", ...
//!     const now = try zvm.current(gpa, io, z.home);               // what `zig` on PATH is
//!     const want = try zvm.projectVersion(gpa, io, project.dir);  // ".zigversion" or build.zig.zon
//!
//! ZVM keeps every version in `<home>/<version>/` (home is `$ZVM_PATH`, else
//! `~/.zvm`) and makes `<home>/bin` point at the one in use, so what is
//! installed and what is current can be read from disk without running ZVM
//! (which prints an upgrade notice and may use the network on every run). The
//! list of versions available to install does need ZVM and the network:
//! `Fetcher` asks for it on a worker thread.

const std = @import("std");
const builtin = @import("builtin");
const worker = @import("../core/worker.zig");

const exe_suffix = if (builtin.os.tag == .windows) ".exe" else "";

pub const Install = struct {
    /// The `zvm` program.
    exe: []u8,
    /// Where ZVM keeps versions (`$ZVM_PATH` or `~/.zvm`).
    home: []u8,

    pub fn deinit(self: Install, gpa: std.mem.Allocator) void {
        gpa.free(self.exe);
        gpa.free(self.home);
    }
};

fn homeDir(environ: ?*const std.process.Environ.Map) ?[]const u8 {
    const m = environ orelse return null;
    if (m.get("HOME")) |h| if (h.len > 0) return h;
    if (m.get("USERPROFILE")) |h| if (h.len > 0) return h;
    return null;
}

/// Where ZVM keeps its versions, whether or not it exists yet.
pub fn zvmHome(gpa: std.mem.Allocator, environ: ?*const std.process.Environ.Map) !?[]u8 {
    if (environ) |m| if (m.get("ZVM_PATH")) |p| if (p.len > 0) return try gpa.dupe(u8, p);
    const h = homeDir(environ) orelse return null;
    return try std.fs.path.join(gpa, &.{ h, ".zvm" });
}

fn exists(io: std.Io, path: []const u8) bool {
    std.Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}

/// Find ZVM: `$ZVM_INSTALL`, then `PATH`, then `<home>/self`. Null if it is not installed.
pub fn locate(gpa: std.mem.Allocator, io: std.Io, environ: ?*const std.process.Environ.Map) !?Install {
    const home = (try zvmHome(gpa, environ)) orelse return null;
    errdefer gpa.free(home);
    var found: ?[]u8 = null;
    errdefer if (found) |f| gpa.free(f);
    const name = "zvm" ++ exe_suffix;
    if (environ) |m| {
        if (m.get("ZVM_INSTALL")) |d| if (d.len > 0) {
            const p = try std.fs.path.join(gpa, &.{ d, name });
            if (exists(io, p)) found = p else gpa.free(p);
        };
        if (found == null) if (m.get("PATH")) |path| {
            var it = std.mem.splitScalar(u8, path, if (builtin.os.tag == .windows) ';' else ':');
            while (it.next()) |d| {
                if (d.len == 0) continue;
                const p = try std.fs.path.join(gpa, &.{ d, name });
                if (exists(io, p)) {
                    found = p;
                    break;
                }
                gpa.free(p);
            }
        };
    }
    if (found == null) {
        const p = try std.fs.path.join(gpa, &.{ home, "self", name });
        if (exists(io, p)) found = p else gpa.free(p);
    }
    const exe = found orelse {
        gpa.free(home);
        return null;
    };
    return .{ .exe = exe, .home = home };
}

// ---- versions --------------------------------------------------------------

pub const Semver = struct { major: u32, minor: u32, patch: u32 };

/// `0.17.0` (nothing after the third number). `master` and `0.18.0-dev...` are not plain.
pub fn parsePlain(text: []const u8) ?Semver {
    var it = std.mem.splitScalar(u8, text, '.');
    var parts: [3]u32 = undefined;
    for (&parts) |*p| {
        const s = it.next() orelse return null;
        if (s.len == 0) return null;
        p.* = std.fmt.parseInt(u32, s, 10) catch return null;
    }
    if (it.next() != null) return null;
    return .{ .major = parts[0], .minor = parts[1], .patch = parts[2] };
}

/// Newest first, `master` before everything, other names last (by name).
pub fn newerFirst(_: void, a: []const u8, b: []const u8) bool {
    const am = std.mem.eql(u8, a, "master");
    const bm = std.mem.eql(u8, b, "master");
    if (am or bm) return am and !bm;
    const sa = parsePlain(a);
    const sb = parsePlain(b);
    if (sa != null and sb != null) {
        if (sa.?.major != sb.?.major) return sa.?.major > sb.?.major;
        if (sa.?.minor != sb.?.minor) return sa.?.minor > sb.?.minor;
        return sa.?.patch > sb.?.patch;
    }
    if (sa != null) return true;
    if (sb != null) return false;
    return std.mem.lessThan(u8, a, b);
}

fn freeNames(gpa: std.mem.Allocator, names: [][]u8) void {
    for (names) |n| gpa.free(n);
    gpa.free(names);
}
pub const freeVersions = freeNames;

/// The versions installed under `home` (folders holding a `zig` program), newest first.
pub fn installed(gpa: std.mem.Allocator, io: std.Io, home: []const u8) ![][]u8 {
    var list: std.ArrayListUnmanaged([]u8) = .empty;
    errdefer {
        for (list.items) |n| gpa.free(n);
        list.deinit(gpa);
    }
    var dir = std.Io.Dir.cwd().openDir(io, home, .{ .iterate = true }) catch return list.toOwnedSlice(gpa);
    defer dir.close(io);
    var it = dir.iterate();
    while (it.next(io) catch null) |e| {
        if (e.kind != .directory and e.kind != .sym_link) continue;
        if (std.mem.eql(u8, e.name, "bin") or std.mem.eql(u8, e.name, "self")) continue;
        const zig = try std.fs.path.join(gpa, &.{ home, e.name, "zig" ++ exe_suffix });
        defer gpa.free(zig);
        if (!exists(io, zig)) continue;
        try list.append(gpa, try gpa.dupe(u8, e.name));
    }
    std.mem.sort([]u8, list.items, {}, struct {
        fn less(c: void, a: []u8, b: []u8) bool {
            return newerFirst(c, a, b);
        }
    }.less);
    return list.toOwnedSlice(gpa);
}

/// The version `<home>/bin` points at (what `zig` on PATH runs), or null.
pub fn current(gpa: std.mem.Allocator, io: std.Io, home: []const u8) ?[]u8 {
    const bin = std.fs.path.join(gpa, &.{ home, "bin" }) catch return null;
    defer gpa.free(bin);
    var dir = std.Io.Dir.cwd().openDir(io, bin, .{}) catch return null;
    defer dir.close(io);
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = dir.realPath(io, &buf) catch return null;
    return gpa.dupe(u8, std.fs.path.basename(buf[0..n])) catch null;
}

/// `<home>/<version>/zig`.
pub fn zigExe(gpa: std.mem.Allocator, home: []const u8, version: []const u8) ![]u8 {
    return std.fs.path.join(gpa, &.{ home, version, "zig" ++ exe_suffix });
}

/// `<home>/<version>/zls` if that ZLS is installed.
pub fn zlsExe(gpa: std.mem.Allocator, io: std.Io, home: []const u8, version: []const u8) ?[]u8 {
    const p = std.fs.path.join(gpa, &.{ home, version, "zls" ++ exe_suffix }) catch return null;
    if (exists(io, p)) return p;
    gpa.free(p);
    return null;
}

/// The Zig version a project asks for: the first line of `.zigversion`, else
/// `.minimum_zig_version` in `build.zig.zon`. Only plain versions (`0.16.0`) and
/// `master` count; a development version string is not something to install.
pub fn projectVersion(gpa: std.mem.Allocator, io: std.Io, dir: std.Io.Dir) !?[]u8 {
    if (dir.readFileAlloc(io, ".zigversion", gpa, .limited(256))) |text| {
        defer gpa.free(text);
        const line = std.mem.trim(u8, std.mem.sliceTo(text, '\n'), " \t\r");
        if (isInstallable(line)) return try gpa.dupe(u8, line);
    } else |_| {}
    const zon = dir.readFileAlloc(io, "build.zig.zon", gpa, .limited(256 * 1024)) catch return null;
    defer gpa.free(zon);
    return try minimumFromManifest(gpa, zon);
}

fn isInstallable(v: []const u8) bool {
    return std.mem.eql(u8, v, "master") or parsePlain(v) != null;
}

/// `.minimum_zig_version = "0.16.0"` in a manifest's text.
pub fn minimumFromManifest(gpa: std.mem.Allocator, zon: []const u8) !?[]u8 {
    const key = ".minimum_zig_version";
    var from: usize = 0;
    while (std.mem.indexOfPos(u8, zon, from, key)) |at| {
        from = at + key.len;
        // Skip a `//` comment line holding the key.
        const line_start = if (std.mem.lastIndexOfScalar(u8, zon[0..at], '\n')) |n| n + 1 else 0;
        if (std.mem.indexOf(u8, zon[line_start..at], "//") != null) continue;
        var i = from;
        while (i < zon.len and (zon[i] == ' ' or zon[i] == '\t' or zon[i] == '=')) i += 1;
        if (i >= zon.len or zon[i] != '"') continue;
        const end = std.mem.indexOfScalarPos(u8, zon, i + 1, '"') orelse continue;
        const v = zon[i + 1 .. end];
        if (isInstallable(v)) return try gpa.dupe(u8, v);
    }
    return null;
}

// ---- what can be installed -------------------------------------------------

pub const Remote = struct {
    version: []const u8,
    installed: bool = false,
    /// A ZLS build exists for it.
    zls: bool = false,
};

/// The JSON of `zvm ls-remote --json` (text around the array is skipped).
pub fn parseRemote(arena: std.mem.Allocator, text: []const u8) ![]Remote {
    // ZVM prints a banner before the JSON and an upgrade notice after it.
    const start = std.mem.indexOfScalar(u8, text, '[') orelse return error.BadOutput;
    const end = std.mem.lastIndexOfScalar(u8, text, ']') orelse return error.BadOutput;
    if (end < start) return error.BadOutput;
    const parsed = try std.json.parseFromSliceLeaky([]Remote, arena, text[start .. end + 1], .{ .ignore_unknown_fields = true, .allocate = .alloc_always });
    return parsed;
}

const Snapshot = struct {
    arena: std.heap.ArenaAllocator,
    versions: []Remote,
};

/// Asks ZVM for the installable versions on a worker thread (it needs the network).
pub const Fetcher = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    exe: []u8,
    queue: worker.Queue(?*Snapshot),
    thread: ?std.Thread = null,
    running_flag: std.atomic.Value(bool) = .init(false),
    current_snap: ?*Snapshot = null,
    batch: std.ArrayListUnmanaged(?*Snapshot) = .empty,
    /// The last fetch failed (no network, ZVM error).
    failed: bool = false,
    fetched: bool = false,

    pub fn start(gpa: std.mem.Allocator, io: std.Io, zvm_exe: []const u8, wake: ?*const fn () void) !*Fetcher {
        const self = try gpa.create(Fetcher);
        errdefer gpa.destroy(self);
        const exe = try gpa.dupe(u8, zvm_exe);
        errdefer gpa.free(exe);
        self.* = .{ .gpa = gpa, .io = io, .exe = exe, .queue = .{ .gpa = gpa, .wake = wake } };
        try self.refresh();
        return self;
    }

    /// Ask again (ignored while a request runs).
    pub fn refresh(self: *Fetcher) !void {
        if (self.running_flag.load(.acquire)) return;
        if (self.thread) |t| t.join();
        self.thread = null;
        self.running_flag.store(true, .release);
        errdefer self.running_flag.store(false, .release);
        self.thread = try std.Thread.spawn(.{}, run, .{self});
    }

    pub fn running(self: *const Fetcher) bool {
        return self.running_flag.load(.acquire);
    }

    /// The latest answer (empty before the first one arrives or when offline).
    pub fn versions(self: *const Fetcher) []const Remote {
        return if (self.current_snap) |s| s.versions else &.{};
    }

    /// Take an arrived answer. True when `versions()` or `failed` changed.
    pub fn poll(self: *Fetcher) bool {
        self.queue.drain(&self.batch);
        defer self.batch.clearRetainingCapacity();
        var changed = false;
        for (self.batch.items) |item| {
            changed = true;
            self.fetched = true;
            if (item) |snap| {
                self.freeSnap(self.current_snap);
                self.current_snap = snap;
                self.failed = false;
            } else self.failed = true;
        }
        return changed;
    }

    fn freeSnap(self: *Fetcher, snap: ?*Snapshot) void {
        const s = snap orelse return;
        s.arena.deinit();
        self.gpa.destroy(s);
    }

    pub fn destroy(self: *Fetcher) void {
        if (self.thread) |t| t.join();
        _ = self.poll();
        self.freeSnap(self.current_snap);
        self.batch.deinit(self.gpa);
        self.queue.deinit();
        self.gpa.free(self.exe);
        self.gpa.destroy(self);
    }

    fn run(self: *Fetcher) void {
        defer self.running_flag.store(false, .release);
        const result = self.fetch() catch null;
        self.queue.push(result) catch {
            self.freeSnap(result);
        };
    }

    fn fetch(self: *Fetcher) !?*Snapshot {
        const res = std.process.run(self.gpa, self.io, .{
            .argv = &.{ self.exe, "--color", "off", "ls-remote", "--json" },
            .timeout = .{ .duration = .{ .raw = .fromSeconds(30), .clock = .awake } },
        }) catch |err| {
            std.log.warn("zvm: could not run {s}: {s}", .{ self.exe, @errorName(err) });
            return null;
        };
        defer self.gpa.free(res.stdout);
        defer self.gpa.free(res.stderr);
        switch (res.term) {
            .exited => |c| if (c != 0) {
                std.log.warn("zvm ls-remote exited with {d}: {s}", .{ c, res.stderr });
                return null;
            },
            else => {
                std.log.warn("zvm ls-remote ended abnormally", .{});
                return null;
            },
        }
        const snap = try self.gpa.create(Snapshot);
        snap.* = .{ .arena = .init(self.gpa), .versions = &.{} };
        snap.versions = parseRemote(snap.arena.allocator(), res.stdout) catch {
            snap.arena.deinit();
            self.gpa.destroy(snap);
            return null;
        };
        return snap;
    }
};

// ---- commands --------------------------------------------------------------

/// The line a person would paste to install ZVM on this system (shown before it runs).
pub const install_script_text = if (builtin.os.tag == .windows)
    "irm https://www.zvm.app/install.ps1 | iex"
else
    "curl -fsSL https://www.zvm.app/install.sh | bash";

/// The program and arguments that run ZVM's official install script.
pub const install_script_argv: []const []const u8 = if (builtin.os.tag == .windows)
    &.{ "powershell", "-NoProfile", "-ExecutionPolicy", "Bypass", "-Command", install_script_text }
else
    &.{ "sh", "-c", install_script_text };

/// `zvm install <version> [--zls]` (strings from `a`).
pub fn installArgv(a: std.mem.Allocator, zvm_exe: []const u8, version: []const u8, with_zls: bool) ![]const []const u8 {
    const base = [_][]const u8{ zvm_exe, "--color", "off", "install", version };
    if (with_zls) return a.dupe([]const u8, &(base ++ [_][]const u8{"--zls"}));
    return a.dupe([]const u8, &base);
}

/// `zvm use <version>`.
pub fn useArgv(a: std.mem.Allocator, zvm_exe: []const u8, version: []const u8) ![]const []const u8 {
    return a.dupe([]const u8, &[_][]const u8{ zvm_exe, "--color", "off", "use", version });
}

/// Run `zvm use <version>` and wait for it. True on success.
pub fn useNow(gpa: std.mem.Allocator, io: std.Io, zvm_exe: []const u8, version: []const u8) bool {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const argv = useArgv(arena.allocator(), zvm_exe, version) catch return false;
    const res = std.process.run(gpa, io, .{
        .argv = argv,
        .timeout = .{ .duration = .{ .raw = .fromSeconds(60), .clock = .awake } },
    }) catch return false;
    defer gpa.free(res.stdout);
    defer gpa.free(res.stderr);
    return switch (res.term) {
        .exited => |c| c == 0,
        else => false,
    };
}

/// What opening a project did about its Zig version.
pub const Auto = struct {
    /// What the project asks for (null: nothing, or ZVM is not installed).
    wanted: ?[]u8 = null,
    /// `zvm use` ran and succeeded: `zig` on PATH is now `wanted`.
    switched: bool = false,
    /// The project wants a version ZVM has not installed.
    missing: bool = false,
    /// `zvm use` ran and failed.
    failed: bool = false,

    pub fn deinit(self: Auto, gpa: std.mem.Allocator) void {
        if (self.wanted) |w| gpa.free(w);
    }
};

/// Make `zig` match what the project in `dir` asks for, if ZVM is installed and
/// has that version. Cheap when nothing needs to change (no process is started).
pub fn autoSwitch(gpa: std.mem.Allocator, io: std.Io, environ: ?*const std.process.Environ.Map, dir: std.Io.Dir) Auto {
    const wanted = (projectVersion(gpa, io, dir) catch null) orelse return .{};
    var out: Auto = .{ .wanted = wanted };
    const z = (locate(gpa, io, environ) catch null) orelse return out;
    defer z.deinit(gpa);
    const have = installed(gpa, io, z.home) catch return out;
    defer freeVersions(gpa, have);
    var present = false;
    for (have) |h| {
        if (std.mem.eql(u8, h, wanted)) present = true;
    }
    if (!present) {
        out.missing = true;
        return out;
    }
    if (current(gpa, io, z.home)) |cur| {
        defer gpa.free(cur);
        if (std.mem.eql(u8, cur, wanted)) return out;
    }
    if (useNow(gpa, io, z.exe, wanted)) out.switched = true else out.failed = true;
    return out;
}

/// Where the "do not offer to install ZVM" marker lives, under the IDE's global settings folder.
pub const declined_marker = "zvm-declined";

// ---- tests -----------------------------------------------------------------

const testing = std.testing;

test "plain versions and ordering" {
    try testing.expect(parsePlain("0.17.0") != null and parsePlain("10.2.33").?.major == 10);
    try testing.expect(parsePlain("master") == null and parsePlain("0.18.0-dev.5") == null and parsePlain("0.17") == null and parsePlain("0.1.2.3") == null);
    var names = [_][]const u8{ "0.15.1", "master", "0.17.0", "0.9.1", "0.16.0", "nightly" };
    std.mem.sort([]const u8, &names, {}, newerFirst);
    try testing.expectEqualStrings("master", names[0]);
    try testing.expectEqualStrings("0.17.0", names[1]);
    try testing.expectEqualStrings("0.16.0", names[2]);
    try testing.expectEqualStrings("0.9.1", names[4]);
    try testing.expectEqualStrings("nightly", names[5]);
}

test "the manifest's minimum_zig_version is read, comments and development versions are not" {
    const a = testing.allocator;
    const v = (try minimumFromManifest(a, ".{\n    .name = .x,\n    .minimum_zig_version = \"0.16.0\",\n}\n")).?;
    defer a.free(v);
    try testing.expectEqualStrings("0.16.0", v);
    try testing.expect((try minimumFromManifest(a, "    // .minimum_zig_version = \"0.15.1\",\n")) == null);
    try testing.expect((try minimumFromManifest(a, ".{ .minimum_zig_version = \"0.17.0-dev.12+abc\" }")) == null);
    try testing.expect((try minimumFromManifest(a, ".{ .name = .x }")) == null);
}

test ".zigversion wins over the manifest" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const a = testing.allocator;
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "build.zig.zon", .data = ".{ .minimum_zig_version = \"0.15.2\" }" });
    const from_zon = (try projectVersion(a, testing.io, tmp.dir)).?;
    defer a.free(from_zon);
    try testing.expectEqualStrings("0.15.2", from_zon);
    try tmp.dir.writeFile(testing.io, .{ .sub_path = ".zigversion", .data = "0.16.0\n" });
    const from_file = (try projectVersion(a, testing.io, tmp.dir)).?;
    defer a.free(from_file);
    try testing.expectEqualStrings("0.16.0", from_file);
    try tmp.dir.writeFile(testing.io, .{ .sub_path = ".zigversion", .data = "garbage" });
    const fallback = (try projectVersion(a, testing.io, tmp.dir)).?;
    defer a.free(fallback);
    try testing.expectEqualStrings("0.15.2", fallback);
}

test "the remote list parses past the banner line" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const out = "Terminal color output: OFF\n[{\"version\":\"0.17.0\",\"installed\":true,\"zls\":true},{\"version\":\"0.14.1\",\"installed\":false,\"zls\":false},{\"version\":\"master\",\"installed\":true,\"zls\":false,\"remoteVersion\":\"0.18.0-dev\",\"outdated\":true}]\n\n  Notice  \n\nZVM v0.9.4 is available. You are currently on v0.9.1.\n";
    const list = try parseRemote(arena.allocator(), out);
    try testing.expectEqual(@as(usize, 3), list.len);
    try testing.expect(list[0].installed and list[0].zls);
    try testing.expect(!list[1].installed and !list[1].zls);
    try testing.expectEqualStrings("master", list[2].version);
    try testing.expectError(error.BadOutput, parseRemote(arena.allocator(), "no json here"));
}

fn makeVersion(tmp: *testing.TmpDir, name: []const u8) !void {
    var buf: [64]u8 = undefined;
    const sub = try std.fmt.bufPrint(&buf, "{s}/zig" ++ exe_suffix, .{name});
    try tmp.dir.createDirPath(testing.io, name);
    try tmp.dir.writeFile(testing.io, .{ .sub_path = sub, .data = "x" });
}

test "installed versions are the folders holding a zig program; the bin link says which is current" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const a = testing.allocator;
    try makeVersion(&tmp, "0.16.0");
    try makeVersion(&tmp, "0.17.0");
    try makeVersion(&tmp, "master");
    try tmp.dir.createDirPath(testing.io, "self"); // not a version
    try tmp.dir.createDirPath(testing.io, "0.14.0"); // empty: a failed install
    try tmp.dir.symLink(testing.io, "0.16.0", "bin", .{ .is_directory = true });
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(testing.io, &buf);
    const home = buf[0..n];

    const have = try installed(a, testing.io, home);
    defer freeVersions(a, have);
    try testing.expectEqual(@as(usize, 3), have.len);
    try testing.expectEqualStrings("master", have[0]);
    try testing.expectEqualStrings("0.17.0", have[1]);
    try testing.expectEqualStrings("0.16.0", have[2]);
    const now = current(a, testing.io, home).?;
    defer a.free(now);
    try testing.expectEqualStrings("0.16.0", now);
    const exe = try zigExe(a, home, "0.17.0");
    defer a.free(exe);
    try testing.expect(std.mem.endsWith(u8, exe, "0.17.0/zig"));
}

test "ZVM is found through ZVM_INSTALL, and reported missing when it is nowhere" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const a = testing.allocator;
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(testing.io, &buf);
    const root = buf[0..n];
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try env.put("HOME", root);
    try env.put("PATH", "/nonexistent-dir");
    try testing.expect((try locate(a, testing.io, &env)) == null);
    try tmp.dir.createDirPath(testing.io, ".zvm/self");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = ".zvm/self/zvm", .data = "#!/bin/sh\n" });
    const found = (try locate(a, testing.io, &env)).?;
    defer found.deinit(a);
    try testing.expect(std.mem.endsWith(u8, found.exe, ".zvm/self/zvm"));
    try testing.expect(std.mem.endsWith(u8, found.home, ".zvm"));
}

test "the fetcher runs ZVM and parses its answer, and reports failure" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const a = testing.allocator;
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "fake_zvm", .data = "#!/bin/sh\necho 'Terminal color output: OFF'\necho '[{\"version\":\"0.17.0\",\"installed\":true,\"zls\":true},{\"version\":\"0.14.1\",\"installed\":false,\"zls\":false}]'\n" });
    try tmp.dir.setFilePermissions(testing.io, "fake_zvm", .executable_file, .{});
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(testing.io, &buf);
    const exe = try std.fs.path.join(a, &.{ buf[0..n], "fake_zvm" });
    defer a.free(exe);
    const f = try Fetcher.start(a, testing.io, exe, null);
    defer f.destroy();
    var tries: usize = 0;
    while (!f.poll() and tries < 5000) : (tries += 1) common_sleep(2);
    try testing.expectEqual(@as(usize, 2), f.versions().len);
    try testing.expect(f.versions()[0].installed and !f.failed);

    const bad = try Fetcher.start(a, testing.io, "/nonexistent/zvm", null);
    defer bad.destroy();
    tries = 0;
    while (!bad.poll() and tries < 5000) : (tries += 1) common_sleep(2);
    try testing.expect(bad.failed and bad.versions().len == 0);
}

fn common_sleep(ms: u64) void {
    @import("../platform/pty_common.zig").sleepMs(ms);
}

test "autoSwitch does nothing without a request, reports a missing version, and skips a version already in use" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const a = testing.allocator;
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(testing.io, &buf);
    const root = buf[0..n];
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try env.put("HOME", root);
    try env.put("PATH", "/nonexistent-dir");
    try tmp.dir.createDirPath(testing.io, "proj");
    var proj = try tmp.dir.openDir(testing.io, "proj", .{ .iterate = true });
    defer proj.close(testing.io);

    const none = autoSwitch(a, testing.io, &env, proj);
    defer none.deinit(a);
    try testing.expect(none.wanted == null and !none.switched);

    try proj.writeFile(testing.io, .{ .sub_path = ".zigversion", .data = "0.16.0\n" });
    const no_zvm = autoSwitch(a, testing.io, &env, proj);
    defer no_zvm.deinit(a);
    try testing.expectEqualStrings("0.16.0", no_zvm.wanted.?);
    try testing.expect(!no_zvm.missing); // no ZVM: nothing to install with

    try tmp.dir.createDirPath(testing.io, ".zvm/self");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = ".zvm/self/zvm", .data = "#!/bin/sh\n" });
    try makeVersion(&tmp, ".zvm/0.17.0");
    const missing = autoSwitch(a, testing.io, &env, proj);
    defer missing.deinit(a);
    try testing.expect(missing.missing and !missing.switched);

    try tmp.dir.symLink(testing.io, "0.17.0", ".zvm/bin", .{ .is_directory = true });
    try proj.writeFile(testing.io, .{ .sub_path = ".zigversion", .data = "0.17.0\n" });
    const same = autoSwitch(a, testing.io, &env, proj);
    defer same.deinit(a);
    try testing.expect(!same.missing and !same.switched and !same.failed);
}
