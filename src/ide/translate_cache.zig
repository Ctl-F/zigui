//! `zig translate-c` with a cache of its own: turn a C header into Zig source so
//! the IDE can index the declarations a C module offers, without asking the
//! language server and without translating again until something changes. No UI.
//!
//!     const path = (try translate(gpa, io, .{
//!         .zig = "zig", .header = "/proj/c/api.h", .include_dirs = &.{"/proj/c/include"},
//!         .defines = &.{"FOO=1"}, .cache_dir = "/home/me/.cache/zigui-ide/translate-c",
//!     })) orelse return;                     // null: translating failed (see the .failed file)
//!     defer gpa.free(path);                  // an absolute path of a .zig file
//!
//! The result is stored as `<cache_dir>/<header name>-<key>.zig`, where the key
//! hashes the compiler, the header's path, size and modification time, and the
//! include directories and defines. The same inputs give the same file with no
//! process started; a change gives a new key. A failure writes
//! `<name>-<key>.failed` holding the compiler's complaint, so the IDE does not
//! retry on every scan. Headers the header includes are not tracked: touch the
//! top header (or delete the cache folder) after changing those.

const std = @import("std");

pub const Request = struct {
    /// The `zig` program.
    zig: []const u8 = "zig",
    /// The header to translate (absolute).
    header: []const u8,
    /// `-I` directories (absolute).
    include_dirs: []const []const u8 = &.{},
    /// `-isystem` directories (absolute).
    system_include_dirs: []const []const u8 = &.{},
    /// `-DNAME` or `-DNAME=VALUE`, given as `NAME` or `NAME=VALUE`.
    defines: []const []const u8 = &.{},
    cache_dir: []const u8,
};

/// The cache key of a request (hex), from what it depends on.
pub fn keyOf(io: std.Io, r: Request) [16]u8 {
    var h = std.hash.Wyhash.init(0x7a1);
    h.update(r.zig);
    h.update(r.header);
    if (std.Io.Dir.cwd().statFile(io, r.header, .{})) |st| {
        h.update(std.mem.asBytes(&st.size));
        const m: i96 = st.mtime.nanoseconds;
        h.update(std.mem.asBytes(&m));
    } else |_| {}
    for (r.include_dirs) |d| {
        h.update("I");
        h.update(d);
    }
    for (r.system_include_dirs) |d| {
        h.update("S");
        h.update(d);
    }
    for (r.defines) |d| {
        h.update("D");
        h.update(d);
    }
    var out: [16]u8 = undefined;
    _ = std.fmt.bufPrint(&out, "{x:0>16}", .{h.final()}) catch unreachable;
    return out;
}

fn exists(io: std.Io, path: []const u8) bool {
    std.Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}

/// The path of the translated source for `r`, translating (and caching) if needed.
/// Null when the header cannot be translated. Caller frees.
pub fn translate(gpa: std.mem.Allocator, io: std.Io, r: Request) !?[]u8 {
    const key = keyOf(io, r);
    const stem = std.fs.path.stem(r.header);
    const name = try std.fmt.allocPrint(gpa, "{s}-{s}", .{ stem, key });
    defer gpa.free(name);
    const out_path = try std.fmt.allocPrint(gpa, "{s}{c}{s}.zig", .{ r.cache_dir, std.fs.path.sep, name });
    errdefer gpa.free(out_path);
    if (exists(io, out_path)) return out_path;
    const failed_path = try std.fmt.allocPrint(gpa, "{s}{c}{s}.failed", .{ r.cache_dir, std.fs.path.sep, name });
    defer gpa.free(failed_path);
    if (exists(io, failed_path)) {
        gpa.free(out_path);
        return null;
    }

    var argv: std.ArrayListUnmanaged([]const u8) = .empty;
    defer argv.deinit(gpa);
    var owned: std.ArrayListUnmanaged([]u8) = .empty;
    defer {
        for (owned.items) |s| gpa.free(s);
        owned.deinit(gpa);
    }
    try argv.appendSlice(gpa, &.{ r.zig, "translate-c", "-lc" });
    for (r.include_dirs) |d| {
        const a = try std.fmt.allocPrint(gpa, "-I{s}", .{d});
        try owned.append(gpa, a);
        try argv.append(gpa, a);
    }
    for (r.system_include_dirs) |d| {
        try argv.appendSlice(gpa, &.{ "-isystem", d });
    }
    for (r.defines) |d| {
        const a = try std.fmt.allocPrint(gpa, "-D{s}", .{d});
        try owned.append(gpa, a);
        try argv.append(gpa, a);
    }
    try argv.append(gpa, r.header);

    try std.Io.Dir.cwd().createDirPath(io, r.cache_dir);
    const res = std.process.run(gpa, io, .{
        .argv = argv.items,
        .timeout = .{ .duration = .{ .raw = .fromSeconds(180), .clock = .awake } },
    }) catch |err| {
        // The compiler could not even start: not the header's fault, so no marker.
        std.log.warn("translate-c: could not run {s}: {s}", .{ r.zig, @errorName(err) });
        gpa.free(out_path);
        return null;
    };
    defer gpa.free(res.stdout);
    defer gpa.free(res.stderr);
    const ok = switch (res.term) {
        .exited => |c| c == 0 and res.stdout.len > 0,
        else => false,
    };
    if (!ok) {
        std.Io.Dir.cwd().writeFile(io, .{ .sub_path = failed_path, .data = if (res.stderr.len > 0) res.stderr else "translate-c failed\n" }) catch {};
        gpa.free(out_path);
        return null;
    }
    // Write beside the final name and rename, so a half-written file is never read.
    const tmp = try std.fmt.allocPrint(gpa, "{s}.tmp", .{out_path});
    defer gpa.free(tmp);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = tmp, .data = res.stdout });
    try std.Io.Dir.rename(std.Io.Dir.cwd(), tmp, std.Io.Dir.cwd(), out_path, io);
    return out_path;
}

// ---- tests -----------------------------------------------------------------

const testing = std.testing;

test "a header is translated once; the same request reads the cache; a failure is remembered" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "t.h", .data = "#define ANSWER 42\nint add_points(int a, int b);\n" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "bad.h", .data = "this is not C at all (((\n" });
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(testing.io, &buf);
    const root = try testing.allocator.dupe(u8, buf[0..n]);
    defer testing.allocator.free(root);
    const header = try std.fs.path.join(testing.allocator, &.{ root, "t.h" });
    defer testing.allocator.free(header);
    const bad = try std.fs.path.join(testing.allocator, &.{ root, "bad.h" });
    defer testing.allocator.free(bad);
    const cache = try std.fs.path.join(testing.allocator, &.{ root, "cache" });
    defer testing.allocator.free(cache);

    const first = (try translate(testing.allocator, testing.io, .{ .header = header, .cache_dir = cache, .defines = &.{"EXTRA=1"} })) orelse return error.SkipZigTest; // no zig on PATH
    defer testing.allocator.free(first);
    const text = try std.Io.Dir.cwd().readFileAlloc(testing.io, first, testing.allocator, .limited(64 << 20));
    defer testing.allocator.free(text);
    try testing.expect(std.mem.indexOf(u8, text, "add_points") != null);
    try testing.expect(std.mem.indexOf(u8, text, "pub const ANSWER") != null);

    // The same request finds the cached file.
    const again = (try translate(testing.allocator, testing.io, .{ .header = header, .cache_dir = cache, .defines = &.{"EXTRA=1"} })).?;
    defer testing.allocator.free(again);
    try testing.expectEqualStrings(first, again);

    // A header that does not translate gives null, and leaves a note so it is not retried.
    try testing.expect((try translate(testing.allocator, testing.io, .{ .header = bad, .cache_dir = cache })) == null);
    var found_note = false;
    var cache_dir = try tmp.dir.openDir(testing.io, "cache", .{ .iterate = true });
    defer cache_dir.close(testing.io);
    var it = cache_dir.iterate();
    while (try it.next(testing.io)) |e| {
        if (std.mem.endsWith(u8, e.name, ".failed")) found_note = true;
    }
    try testing.expect(found_note);
    try testing.expect((try translate(testing.allocator, testing.io, .{ .header = bad, .cache_dir = cache })) == null);
}

test "different defines give a different cache key" {
    const a = keyOf(testing.io, .{ .header = "/x/a.h", .cache_dir = "/c", .defines = &.{"A"} });
    const b = keyOf(testing.io, .{ .header = "/x/a.h", .cache_dir = "/c", .defines = &.{"B"} });
    const a2 = keyOf(testing.io, .{ .header = "/x/a.h", .cache_dir = "/c", .defines = &.{"A"} });
    try testing.expect(!std.mem.eql(u8, &a, &b));
    try testing.expectEqualSlices(u8, &a, &a2);
}
