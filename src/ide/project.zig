//! A project: a directory tree the IDE works in. No UI here.
//!
//! Paths inside a project are *relative* to its root, with '/' separators
//! (`src/main.zig`); `absPath` makes a real path for tools. Directory listings
//! skip build output and version-control folders (`excluded`), so the file tree
//! and project-wide search stay readable.

const std = @import("std");
const Io = std.Io;

/// Directory names never shown or searched.
pub const excluded = [_][]const u8{ ".git", ".hg", ".svn", ".zig-cache", "zig-cache", "zig-out", "node_modules", ".zigide" };

pub fn isExcludedName(name: []const u8) bool {
    for (excluded) |e| {
        if (std.mem.eql(u8, e, name)) return true;
    }
    return false;
}

pub const DirEntry = struct {
    name: []u8,
    is_dir: bool,
};

pub fn freeEntries(gpa: std.mem.Allocator, entries: []DirEntry) void {
    for (entries) |e| gpa.free(e.name);
    gpa.free(entries);
}

fn lessEntry(_: void, a: DirEntry, b: DirEntry) bool {
    // Directories first, then names without regard to case.
    if (a.is_dir != b.is_dir) return a.is_dir;
    var i: usize = 0;
    while (i < a.name.len and i < b.name.len) : (i += 1) {
        const ca = std.ascii.toLower(a.name[i]);
        const cb = std.ascii.toLower(b.name[i]);
        if (ca != cb) return ca < cb;
    }
    return a.name.len < b.name.len;
}

pub const Project = struct {
    gpa: std.mem.Allocator,
    io: Io,
    dir: Io.Dir,
    /// Absolute path of the root.
    root: []u8,
    name: []const u8,

    /// Open the directory at `path` (absolute, or relative to the working directory).
    pub fn open(gpa: std.mem.Allocator, io: Io, path: []const u8) !Project {
        const dir = try Io.Dir.cwd().openDir(io, path, .{ .iterate = true });
        errdefer dir.close(io);
        return fromDir(gpa, io, dir);
    }

    /// Wrap an already open (iterable) directory; the project takes it over.
    pub fn fromDir(gpa: std.mem.Allocator, io: Io, dir: Io.Dir) !Project {
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const n = try dir.realPath(io, &buf);
        const root = try gpa.dupe(u8, buf[0..n]);
        return .{ .gpa = gpa, .io = io, .dir = dir, .root = root, .name = std.fs.path.basename(root) };
    }

    pub fn close(self: *Project) void {
        self.dir.close(self.io);
        self.gpa.free(self.root);
        self.* = undefined;
    }

    /// True if the root has a `build.zig`.
    pub fn hasBuildZig(self: *const Project) bool {
        self.dir.access(self.io, "build.zig", .{}) catch return false;
        return true;
    }

    /// The real path of project-relative `rel` (caller frees).
    pub fn absPath(self: *const Project, gpa: std.mem.Allocator, rel: []const u8) ![]u8 {
        if (rel.len == 0) return gpa.dupe(u8, self.root);
        return std.fs.path.join(gpa, &.{ self.root, rel });
    }

    /// The project-relative form of an absolute path inside the project, or null.
    pub fn relPath(self: *const Project, abs: []const u8) ?[]const u8 {
        if (!std.mem.startsWith(u8, abs, self.root)) return null;
        var rest = abs[self.root.len..];
        if (rest.len == 0) return rest;
        if (rest[0] != '/' and rest[0] != '\\') return null;
        rest = rest[1..];
        return rest;
    }

    /// The entries of directory `rel` ("" is the root): directories first, then
    /// files, each sorted by name; excluded folders are left out. Free with `freeEntries`.
    pub fn listDir(self: *const Project, gpa: std.mem.Allocator, rel: []const u8) ![]DirEntry {
        var sub: ?Io.Dir = null;
        defer if (sub) |d| d.close(self.io);
        var dir = self.dir;
        if (rel.len > 0) {
            sub = try self.dir.openDir(self.io, rel, .{ .iterate = true });
            dir = sub.?;
        }
        var list: std.ArrayListUnmanaged(DirEntry) = .empty;
        errdefer {
            for (list.items) |e| gpa.free(e.name);
            list.deinit(gpa);
        }
        var it = dir.iterate();
        while (try it.next(self.io)) |entry| {
            const is_dir = entry.kind == .directory;
            if (is_dir and isExcludedName(entry.name)) continue;
            if (entry.kind != .file and !is_dir and entry.kind != .sym_link) continue;
            const name = try gpa.dupe(u8, entry.name);
            errdefer gpa.free(name);
            try list.append(gpa, .{ .name = name, .is_dir = is_dir });
        }
        std.mem.sort(DirEntry, list.items, {}, lessEntry);
        return list.toOwnedSlice(gpa);
    }

    pub fn readFile(self: *const Project, gpa: std.mem.Allocator, rel: []const u8, max: usize) ![]u8 {
        return self.dir.readFileAlloc(self.io, rel, gpa, .limited(max));
    }

    pub fn writeFile(self: *const Project, rel: []const u8, bytes: []const u8) !void {
        try self.dir.writeFile(self.io, .{ .sub_path = rel, .data = bytes });
    }
};

// ---- tests -----------------------------------------------------------------

const testing = std.testing;

/// A scratch project: src/main.zig, src/util/a.zig, README.md, .git/config, zig-out/x.
pub fn testProject(tmp: *testing.TmpDir) !Project {
    const io = testing.io;
    try tmp.dir.createDirPath(io, "src/util");
    try tmp.dir.createDirPath(io, ".git");
    try tmp.dir.createDirPath(io, "zig-out");
    try tmp.dir.writeFile(io, .{ .sub_path = "src/main.zig", .data = "const std = @import(\"std\");\npub fn main() void {}\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "src/util/a.zig", .data = "pub const answer = 42;\n// std is great\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "README.md", .data = "# demo\nuses STD\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "build.zig", .data = "pub fn build() void {}\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = ".git/config", .data = "std = 1\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "zig-out/x", .data = "std\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "blob.bin", .data = "std\x00\x01\x02" });
    const dir = try tmp.dir.openDir(io, ".", .{ .iterate = true });
    return Project.fromDir(testing.allocator, io, dir);
}

test "listDir sorts directories first, hides excluded folders, and lists subdirectories" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var p = try testProject(&tmp);
    defer p.close();
    const top = try p.listDir(testing.allocator, "");
    defer freeEntries(testing.allocator, top);
    try testing.expectEqualStrings("src", top[0].name);
    try testing.expect(top[0].is_dir);
    for (top) |e| {
        try testing.expect(!std.mem.eql(u8, e.name, ".git"));
        try testing.expect(!std.mem.eql(u8, e.name, "zig-out"));
    }
    // Files follow, in name order ignoring case.
    try testing.expectEqualStrings("blob.bin", top[1].name);
    try testing.expectEqualStrings("build.zig", top[2].name);
    try testing.expectEqualStrings("README.md", top[3].name);
    const src = try p.listDir(testing.allocator, "src");
    defer freeEntries(testing.allocator, src);
    try testing.expectEqual(@as(usize, 2), src.len);
    try testing.expectEqualStrings("util", src[0].name);
    try testing.expectEqualStrings("main.zig", src[1].name);
    try testing.expect(p.hasBuildZig());
}

test "reading, writing, and path conversion" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var p = try testProject(&tmp);
    defer p.close();
    const text = try p.readFile(testing.allocator, "README.md", 1024);
    defer testing.allocator.free(text);
    try testing.expectEqualStrings("# demo\nuses STD\n", text);
    try p.writeFile("src/new.zig", "// hi\n");
    const again = try p.readFile(testing.allocator, "src/new.zig", 1024);
    defer testing.allocator.free(again);
    try testing.expectEqualStrings("// hi\n", again);
    const abs = try p.absPath(testing.allocator, "src/main.zig");
    defer testing.allocator.free(abs);
    try testing.expectEqualStrings("src/main.zig", p.relPath(abs).?);
    try testing.expect(p.relPath("/elsewhere/x") == null);
    try testing.expectError(error.FileNotFound, p.readFile(testing.allocator, "missing.txt", 10));
}
