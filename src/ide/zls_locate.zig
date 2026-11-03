//! Finding the Zig language server that goes with the installed Zig.
//!
//! ZLS releases follow Zig's: ZLS 0.16 is for Zig 0.16. Looking for a plain `zls`
//! on `PATH` and giving up is not enough (version managers keep one per
//! version in their own folders, and a shell shim is not visible to a program that
//! starts it directly), so every place one is usually installed is searched and
//! the one matching the running Zig's major.minor wins.
//!
//!     const found = try zls_locate.find(a, io, environ, "0.17.0", configured);
//!     // found.path, found.version, found.exact, found.note (what to tell the user)
//!
//! Searched, in order: the explicitly configured command (settings or
//! `ZIGUI_ZLS`; used as is), `PATH`, `$XDG_DATA_HOME/zls/<version>/zls` and
//! `~/.local/share/zls/<version>/zls`, `~/.zvm/<version>/zls`, `~/.local/bin`,
//! `/usr/local/bin`, `/usr/bin`. When no ZLS matches the Zig version, the newest
//! older one is used (it usually works, with gaps) and `note` says so; with none at
//! all, `note` says where it looked.

const std = @import("std");

pub const Candidate = struct {
    path: []const u8,
    /// "0.16.0" (from its folder name or `--version`); "" if unknown.
    version: []const u8,
};

pub const Found = struct {
    path: []const u8,
    version: []const u8,
    /// Same major.minor as the Zig.
    exact: bool,
    /// Something worth showing the user ("" when all is well).
    note: []const u8,
};

pub const Version = struct { major: u32, minor: u32 };

/// `0.17.0`, `0.17.0-dev.12+abc`, `zls 0.16.1`: the major and minor numbers.
pub fn parseVersion(text: []const u8) ?Version {
    var s = std.mem.trim(u8, text, " \n\r\t");
    // Skip a leading word ("zls ").
    if (std.mem.lastIndexOfScalar(u8, s, ' ')) |sp| s = s[sp + 1 ..];
    var it = std.mem.splitScalar(u8, s, '.');
    const major = std.fmt.parseInt(u32, it.next() orelse return null, 10) catch return null;
    const minor_text = it.next() orelse return null;
    var end: usize = 0;
    while (end < minor_text.len and std.ascii.isDigit(minor_text[end])) end += 1;
    const minor = std.fmt.parseInt(u32, minor_text[0..end], 10) catch return null;
    return .{ .major = major, .minor = minor };
}

fn newer(a: Version, b: Version) bool {
    return a.major > b.major or (a.major == b.major and a.minor > b.minor);
}

/// The index of the best candidate for `zig_version`: an exact major.minor match,
/// else the newest one older than it, else the oldest newer one. Null if none.
pub fn choose(cands: []const Candidate, zig_version: []const u8) ?struct { index: usize, exact: bool } {
    const want = parseVersion(zig_version) orelse return if (cands.len > 0) .{ .index = 0, .exact = false } else null;
    var best_older: ?usize = null;
    var best_newer: ?usize = null;
    var unknown: ?usize = null;
    for (cands, 0..) |c, i| {
        const v = parseVersion(c.version) orelse {
            if (unknown == null) unknown = i;
            continue;
        };
        if (v.major == want.major and v.minor == want.minor) return .{ .index = i, .exact = true };
        if (newer(want, v)) {
            if (best_older == null or newer(v, parseVersion(cands[best_older.?].version).?)) best_older = i;
        } else {
            if (best_newer == null or newer(parseVersion(cands[best_newer.?].version).?, v)) best_newer = i;
        }
    }
    if (best_older) |i| return .{ .index = i, .exact = false };
    if (best_newer) |i| return .{ .index = i, .exact = false };
    if (unknown) |i| return .{ .index = i, .exact = false };
    return null;
}

fn exists(io: std.Io, path: []const u8) bool {
    std.Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}

fn addIfExists(a: std.mem.Allocator, io: std.Io, list: *std.ArrayListUnmanaged(Candidate), path: []const u8, version: []const u8) !void {
    if (!exists(io, path)) return;
    for (list.items) |c| if (std.mem.eql(u8, c.path, path)) return;
    try list.append(a, .{ .path = try a.dupe(u8, path), .version = try a.dupe(u8, version) });
}

/// `<root>/<version>/zls` for every version folder in `root`.
fn scanVersionDirs(a: std.mem.Allocator, io: std.Io, list: *std.ArrayListUnmanaged(Candidate), root: []const u8) !void {
    var dir = std.Io.Dir.cwd().openDir(io, root, .{ .iterate = true }) catch return;
    defer dir.close(io);
    var it = dir.iterate();
    while (it.next(io) catch null) |e| {
        if (e.kind != .directory) continue;
        if (parseVersion(e.name) == null) continue;
        const p = try std.fs.path.join(a, &.{ root, e.name, "zls" });
        try addIfExists(a, io, list, p, e.name);
    }
}

/// The version a `zls` executable reports (`zls --version`), or "".
fn askVersion(a: std.mem.Allocator, io: std.Io, path: []const u8) []const u8 {
    const res = std.process.run(a, io, .{ .argv = &.{ path, "--version" } }) catch return "";
    return std.mem.trim(u8, res.stdout, " \n\r\t");
}

/// Every ZLS that can be found in the usual places.
pub fn collect(a: std.mem.Allocator, io: std.Io, environ: ?*const std.process.Environ.Map) ![]Candidate {
    var list: std.ArrayListUnmanaged(Candidate) = .empty;
    const env = environ;
    if (env) |e| if (e.get("PATH")) |path| {
        var it = std.mem.tokenizeScalar(u8, path, ':');
        while (it.next()) |dir| {
            const p = try std.fs.path.join(a, &.{ dir, "zls" });
            if (!exists(io, p)) continue;
            // A version manager's shim answers `--version` for whichever it selects.
            try addIfExists(a, io, &list, p, askVersion(a, io, p));
        }
    };
    const home: []const u8 = if (env) |e| (e.get("HOME") orelse "") else "";
    if (env) |e| if (e.get("XDG_DATA_HOME")) |x| if (x.len > 0) {
        try scanVersionDirs(a, io, &list, try std.fs.path.join(a, &.{ x, "zls" }));
    };
    if (home.len > 0) {
        try scanVersionDirs(a, io, &list, try std.fs.path.join(a, &.{ home, ".local", "share", "zls" }));
        try scanVersionDirs(a, io, &list, try std.fs.path.join(a, &.{ home, ".zvm" }));
        const local = try std.fs.path.join(a, &.{ home, ".local", "bin", "zls" });
        try addIfExists(a, io, &list, local, askVersion(a, io, local));
    }
    for ([_][]const u8{ "/usr/local/bin/zls", "/usr/bin/zls" }) |p| {
        if (exists(io, p)) try addIfExists(a, io, &list, p, askVersion(a, io, p));
    }
    return list.items;
}

/// Pick the language server to run for Zig `zig_version`. `configured` (the
/// setting or `ZIGUI_ZLS`) wins when given. Null when there is none to run;
/// `note` then (in the returned struct) is not available, so see `missingNote`.
pub fn find(a: std.mem.Allocator, io: std.Io, environ: ?*const std.process.Environ.Map, zig_version: []const u8, configured: []const u8) !?Found {
    if (configured.len > 0) {
        // An explicit choice is respected; a bare name is looked up on PATH by the system.
        if (std.mem.indexOfScalar(u8, configured, '/') != null and !exists(io, configured)) return null;
        return .{ .path = configured, .version = "", .exact = true, .note = "" };
    }
    const cands = try collect(a, io, environ);
    const pick = choose(cands, zig_version) orelse return null;
    const c = cands[pick.index];
    const note = if (pick.exact or c.version.len == 0) "" else try std.fmt.allocPrint(a, "using zls {s} for Zig {s} (no zls {s} build was found); some answers may be missing; Zig > Install ZLS for This Zig Version fetches the right one", .{ c.version, zig_version, zig_version });
    return .{ .path = c.path, .version = c.version, .exact = pick.exact, .note = note };
}

/// What to say when `find` returns null.
pub fn missingNote(a: std.mem.Allocator, zig_version: []const u8, configured: []const u8) ![]const u8 {
    if (configured.len > 0) return std.fmt.allocPrint(a, "the language server \"{s}\" was not found; check the .language_server setting (or ZIGUI_ZLS)", .{configured});
    return std.fmt.allocPrint(a, "no zls found for Zig {s} (looked on PATH, ~/.local/share/zls, ~/.zvm, ~/.local/bin); Zig > Install ZLS for This Zig Version installs one (needs ZVM), or set .language_server in the settings. Offline completion still works", .{zig_version});
}

// ---- tests -----------------------------------------------------------------

const testing = std.testing;

test "versions parse from folder names and --version output" {
    try testing.expectEqual(Version{ .major = 0, .minor = 17 }, parseVersion("0.17.0").?);
    try testing.expectEqual(Version{ .major = 0, .minor = 17 }, parseVersion("0.17.0-dev.12+abc").?);
    try testing.expectEqual(Version{ .major = 0, .minor = 16 }, parseVersion("zls 0.16.1\n").?);
    try testing.expect(parseVersion("master") == null and parseVersion("") == null and parseVersion("7") == null);
}

test "the matching version wins; otherwise the newest older one; otherwise something" {
    const c = [_]Candidate{
        .{ .path = "/a/0.14.0/zls", .version = "0.14.0" },
        .{ .path = "/a/0.16.0/zls", .version = "0.16.0" },
        .{ .path = "/a/0.18.0/zls", .version = "0.18.0" },
    };
    try testing.expectEqual(@as(usize, 1), choose(&c, "0.16.2").?.index);
    try testing.expect(choose(&c, "0.16.2").?.exact);
    // No 0.17: 0.16 (the newest older) is used, and it is marked not exact.
    const p = choose(&c, "0.17.0").?;
    try testing.expectEqual(@as(usize, 1), p.index);
    try testing.expect(!p.exact);
    // Only newer ones: take the closest newer.
    const only_new = [_]Candidate{ .{ .path = "x", .version = "0.19.0" }, .{ .path = "y", .version = "0.18.0" } };
    try testing.expectEqual(@as(usize, 1), choose(&only_new, "0.17.0").?.index);
    // Unknown versions are a last resort; nothing is nothing.
    const unk = [_]Candidate{.{ .path = "z", .version = "" }};
    try testing.expectEqual(@as(usize, 0), choose(&unk, "0.17.0").?.index);
    try testing.expect(choose(&.{}, "0.17.0") == null);
}

test "version folders under the usual places are found, and an explicit command is respected" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const io = testing.io;
    try tmp.dir.createDirPath(io, "home/.local/share/zls/0.16.0");
    try tmp.dir.createDirPath(io, "home/.local/share/zls/0.14.0");
    try tmp.dir.createDirPath(io, "home/.local/share/zls/notes");
    try tmp.dir.writeFile(io, .{ .sub_path = "home/.local/share/zls/0.16.0/zls", .data = "" });
    try tmp.dir.writeFile(io, .{ .sub_path = "home/.local/share/zls/0.14.0/zls", .data = "" });
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPathFile(io, "home", &buf);
    var env = std.process.Environ.Map.init(testing.allocator);
    defer env.deinit();
    try env.put("HOME", buf[0..n]);
    try env.put("PATH", "/nonexistent");
    const found = (try find(a, io, &env, "0.17.0", "")).?;
    try testing.expect(std.mem.endsWith(u8, found.path, "/0.16.0/zls"));
    try testing.expect(!found.exact);
    try testing.expect(std.mem.indexOf(u8, found.note, "using zls 0.16.0 for Zig 0.17.0") != null);
    const exact = (try find(a, io, &env, "0.14.3", "")).?;
    try testing.expect(exact.exact and exact.note.len == 0 and std.mem.endsWith(u8, exact.path, "/0.14.0/zls"));
    // An explicit path that exists is used as is; one that does not is a clear miss.
    const given = (try find(a, io, &env, "0.17.0", "/some/where/zls-custom")) == null;
    try testing.expect(given);
    const bare = (try find(a, io, &env, "0.17.0", "zls-nightly")).?;
    try testing.expectEqualStrings("zls-nightly", bare.path);
    // Nothing installed: null, with words for the status line.
    var empty_env = std.process.Environ.Map.init(testing.allocator);
    defer empty_env.deinit();
    try empty_env.put("PATH", "/nonexistent");
    try testing.expect((try find(a, io, &empty_env, "0.17.0", "")) == null);
    const note = try missingNote(a, "0.17.0", "");
    try testing.expect(std.mem.indexOf(u8, note, "no zls found for Zig 0.17.0") != null);
}
