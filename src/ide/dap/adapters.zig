//! Finding a debug adapter on this machine: `lldb-dap` first, then GDB's
//! built-in DAP mode (`gdb --interpreter=dap`, GDB 14 and later). Written for
//! Linux, macOS and Windows alike (executable suffixes, path separators,
//! per-system install places); only Linux is exercised by the project's tests.
//!
//!     const found = try find(gpa, io, environ, "") ;     // "" or the user's `debug.adapter_path`
//!     defer if (found) |f| f.deinit(gpa);
//!     // f.kind, f.name, f.argv (spawn this)
//!     const why = try missingNote(gpa);                  // how to install one, when `find` gave null
//!
//! The adapter kind matters for the launch request: the two adapters spell a few
//! arguments differently (`launchArguments` in `../debugger.zig`).

const std = @import("std");
const builtin = @import("builtin");

pub const Kind = enum { lldb, gdb };

pub const Found = struct {
    kind: Kind,
    /// "lldb-dap" or "gdb", for messages.
    name: []const u8,
    /// The program and its arguments (what to spawn).
    argv: []const []const u8,

    pub fn deinit(self: Found, gpa: std.mem.Allocator) void {
        for (self.argv) |a| gpa.free(a);
        gpa.free(self.argv);
        gpa.free(self.name);
    }
};

const exe_suffix = if (builtin.os.tag == .windows) ".exe" else "";

fn exists(io: std.Io, path: []const u8) bool {
    std.Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}

/// An absolute path of `name` found in the folders of `PATH`, or null.
fn onPath(gpa: std.mem.Allocator, io: std.Io, environ: ?*const std.process.Environ.Map, name: []const u8) !?[]u8 {
    const env = environ orelse return null;
    const path = env.get("PATH") orelse return null;
    var it = std.mem.splitScalar(u8, path, if (builtin.os.tag == .windows) ';' else ':');
    while (it.next()) |dir| {
        if (dir.len == 0) continue;
        const p = try std.fs.path.join(gpa, &.{ dir, name });
        if (exists(io, p)) return p;
        gpa.free(p);
    }
    return null;
}

/// `lldb-dap-18`, `lldb-dap-20` ... in the folders of `PATH` (Debian and Fedora name them that way): the newest.
fn versionedLldb(gpa: std.mem.Allocator, io: std.Io, environ: ?*const std.process.Environ.Map) !?[]u8 {
    const env = environ orelse return null;
    const path = env.get("PATH") orelse return null;
    var best: ?[]u8 = null;
    var best_n: u32 = 0;
    var it = std.mem.splitScalar(u8, path, if (builtin.os.tag == .windows) ';' else ':');
    while (it.next()) |dir| {
        if (dir.len == 0) continue;
        var d = std.Io.Dir.cwd().openDir(io, dir, .{ .iterate = true }) catch continue;
        defer d.close(io);
        var iter = d.iterate();
        while (iter.next(io) catch null) |e| {
            if (!std.mem.startsWith(u8, e.name, "lldb-dap-")) continue;
            const num = std.mem.trimEnd(u8, e.name["lldb-dap-".len..], ".exe");
            const n = std.fmt.parseInt(u32, num, 10) catch continue;
            if (n > best_n) {
                if (best) |b| gpa.free(b);
                best = try std.fs.path.join(gpa, &.{ dir, e.name });
                best_n = n;
            }
        }
    }
    return best;
}

/// Places LLVM tools usually are when they are not on PATH.
fn knownLldbPlaces(gpa: std.mem.Allocator, io: std.Io) !?[]u8 {
    const places: []const []const u8 = switch (builtin.os.tag) {
        .macos => &.{ "/opt/homebrew/opt/llvm/bin/lldb-dap", "/usr/local/opt/llvm/bin/lldb-dap", "/Library/Developer/CommandLineTools/usr/bin/lldb-dap", "/Applications/Xcode.app/Contents/Developer/usr/bin/lldb-dap" },
        .windows => &.{ "C:\\Program Files\\LLVM\\bin\\lldb-dap.exe" },
        else => &.{ "/usr/lib/llvm/bin/lldb-dap", "/usr/local/bin/lldb-dap" },
    };
    for (places) |p| {
        if (exists(io, p)) return try gpa.dupe(u8, p);
    }
    if (builtin.os.tag == .linux) {
        // /usr/lib/llvm-NN/bin/lldb-dap
        var d = std.Io.Dir.cwd().openDir(io, "/usr/lib", .{ .iterate = true }) catch return null;
        defer d.close(io);
        var best: ?[]u8 = null;
        var best_n: u32 = 0;
        var it = d.iterate();
        while (it.next(io) catch null) |e| {
            if (!std.mem.startsWith(u8, e.name, "llvm-")) continue;
            const n = std.fmt.parseInt(u32, e.name[5..], 10) catch continue;
            const p = try std.fmt.allocPrint(gpa, "/usr/lib/{s}/bin/lldb-dap", .{e.name});
            if (n > best_n and exists(io, p)) {
                if (best) |b| gpa.free(b);
                best = p;
                best_n = n;
            } else gpa.free(p);
        }
        return best;
    }
    return null;
}

/// GDB's major version from `gdb --version` output ("GNU gdb (Fedora Linux) 17.1-1.fc42" -> 17).
pub fn gdbMajor(version_output: []const u8) ?u32 {
    const first = std.mem.sliceTo(version_output, '\n');
    // The version is the last space-separated word that starts with a digit.
    var it = std.mem.splitBackwardsScalar(u8, first, ' ');
    while (it.next()) |w| {
        if (w.len == 0 or !std.ascii.isDigit(w[0])) continue;
        var end: usize = 0;
        while (end < w.len and std.ascii.isDigit(w[end])) end += 1;
        return std.fmt.parseInt(u32, w[0..end], 10) catch null;
    }
    return null;
}

fn one(gpa: std.mem.Allocator, kind: Kind, name: []const u8, argv: []const []const u8) !Found {
    const copy = try gpa.alloc([]const u8, argv.len);
    var n: usize = 0;
    errdefer {
        for (copy[0..n]) |a| gpa.free(a);
        gpa.free(copy);
    }
    for (argv) |a| {
        copy[n] = try gpa.dupe(u8, a);
        n += 1;
    }
    return .{ .kind = kind, .name = try gpa.dupe(u8, name), .argv = copy };
}

/// The adapter to use: `override` (the setting) if it exists, else `lldb-dap`, else GDB with DAP. Null if none.
pub fn find(gpa: std.mem.Allocator, io: std.Io, environ: ?*const std.process.Environ.Map, override: []const u8) !?Found {
    if (override.len > 0) {
        if (exists(io, override)) {
            const base = std.fs.path.basename(override);
            const kind: Kind = if (std.mem.indexOf(u8, base, "gdb") != null) .gdb else .lldb;
            if (kind == .gdb) return try one(gpa, .gdb, "gdb", &.{ override, "--interpreter=dap" });
            return try one(gpa, .lldb, base, &.{override});
        }
        // A bad override is reported by the caller, not silently replaced.
        return null;
    }
    inline for (.{ "lldb-dap" ++ exe_suffix, "lldb-vscode" ++ exe_suffix }) |name| {
        if (try onPath(gpa, io, environ, name)) |p| {
            defer gpa.free(p);
            return try one(gpa, .lldb, name, &.{p});
        }
    }
    if (try versionedLldb(gpa, io, environ)) |p| {
        defer gpa.free(p);
        return try one(gpa, .lldb, "lldb-dap", &.{p});
    }
    if (try knownLldbPlaces(gpa, io)) |p| {
        defer gpa.free(p);
        return try one(gpa, .lldb, "lldb-dap", &.{p});
    }
    if (try onPath(gpa, io, environ, "gdb" ++ exe_suffix)) |p| {
        defer gpa.free(p);
        // DAP needs GDB 14.
        const res = std.process.run(gpa, io, .{
            .argv = &.{ p, "--version" },
            .timeout = .{ .duration = .{ .raw = .fromSeconds(10), .clock = .awake } },
        }) catch return null;
        defer gpa.free(res.stdout);
        defer gpa.free(res.stderr);
        const major = gdbMajor(res.stdout) orelse return null;
        if (major >= 14) return try one(gpa, .gdb, "gdb", &.{ p, "--interpreter=dap" });
    }
    return null;
}

/// What to tell a user who has no adapter.
pub fn missingNote(gpa: std.mem.Allocator, override: []const u8) ![]u8 {
    if (override.len > 0) return std.fmt.allocPrint(gpa, "the debug adapter {s} (setting debug.adapter_path) does not exist", .{override});
    const how = switch (builtin.os.tag) {
        .macos => "install LLVM (brew install llvm) or the Xcode command line tools",
        .windows => "install LLVM from https://llvm.org (it includes lldb-dap)",
        else => "install LLDB (package lldb or lldb-NN: it provides lldb-dap) or GDB 14 or later",
    };
    return std.fmt.allocPrint(gpa, "no debug adapter found (looked for lldb-dap and gdb on PATH): {s}, or set debug.adapter_path", .{how});
}

// ---- tests -----------------------------------------------------------------

const testing = std.testing;

test "GDB's major version is read from its banner" {
    try testing.expectEqual(@as(?u32, 17), gdbMajor("GNU gdb (Fedora Linux) 17.1-1.fc42\nCopyright (C) 2025\n"));
    try testing.expectEqual(@as(?u32, 12), gdbMajor("GNU gdb (Ubuntu 12.1-0ubuntu1~22.04) 12.1\n"));
    try testing.expect(gdbMajor("no version here") == null);
}

test "an override wins, a missing one finds nothing, and lldb-dap beats a versioned name on PATH" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "lldb-dap-18", .data = "#!/bin/sh\n" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "lldb-dap-20", .data = "#!/bin/sh\n" });
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(testing.io, &buf);
    const dir = buf[0..n];
    var env = std.process.Environ.Map.init(testing.allocator);
    defer env.deinit();
    try env.put("PATH", dir);

    // Only versioned names: the newest.
    const v = (try find(testing.allocator, testing.io, &env, "")).?;
    defer v.deinit(testing.allocator);
    try testing.expect(v.kind == .lldb);
    try testing.expect(std.mem.endsWith(u8, v.argv[0], "lldb-dap-20"));

    // The plain name is preferred.
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "lldb-dap", .data = "#!/bin/sh\n" });
    const p = (try find(testing.allocator, testing.io, &env, "")).?;
    defer p.deinit(testing.allocator);
    try testing.expect(std.mem.endsWith(u8, p.argv[0], "/lldb-dap"));

    // An override (here a "gdb") picks the GDB style; a missing override finds nothing.
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "mygdb", .data = "#!/bin/sh\n" });
    const over = try std.fs.path.join(testing.allocator, &.{ dir, "mygdb" });
    defer testing.allocator.free(over);
    const g = (try find(testing.allocator, testing.io, &env, over)).?;
    defer g.deinit(testing.allocator);
    try testing.expect(g.kind == .gdb);
    try testing.expectEqualStrings("--interpreter=dap", g.argv[1]);
    try testing.expect((try find(testing.allocator, testing.io, &env, "/nonexistent/adapter")) == null);
}

test "with nothing installed the note says how to get an adapter" {
    const note = try missingNote(testing.allocator, "");
    defer testing.allocator.free(note);
    try testing.expect(std.mem.indexOf(u8, note, "debug.adapter_path") != null);
    const bad = try missingNote(testing.allocator, "/x/y");
    defer testing.allocator.free(bad);
    try testing.expect(std.mem.indexOf(u8, bad, "/x/y") != null);
}
