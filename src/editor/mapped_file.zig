//! Read-only memory-mapped files, for opening huge documents instantly.
//!
//! The file is mapped without prefaulting, so opening costs the same for a
//! kilobyte or a gigabyte; pages come in as they are touched. The bytes are
//! meant to be a piece table's borrowed original (`PieceTable.initMapped`).
//! If another process truncates the file while it is mapped, touching the lost
//! pages faults (SIGBUS); that is inherent to mapping and is why saves should go
//! to a new file and rename.

const std = @import("std");

pub const MappedFile = struct {
    io: std.Io,
    file: std.Io.File,
    map: ?std.Io.File.MemoryMap,
    /// The file's contents (empty for an empty file).
    bytes: []const u8,

    pub fn open(io: std.Io, path: []const u8) !MappedFile {
        const file = try std.Io.Dir.cwd().openFile(io, path, .{});
        errdefer file.close(io);
        const st = try file.stat(io);
        const size: usize = @intCast(st.size);
        if (size == 0) return .{ .io = io, .file = file, .map = null, .bytes = "" };
        var map = try file.createMemoryMap(io, .{
            .len = size,
            .protection = .{ .read = true, .write = false },
            .populate = false,
        });
        errdefer map.destroy(io);
        return .{ .io = io, .file = file, .map = map, .bytes = map.memory[0..size] };
    }

    pub fn close(self: *MappedFile) void {
        if (self.map) |*m| m.destroy(self.io);
        self.file.close(self.io);
        self.* = undefined;
    }
};

test "a mapped file exposes its bytes without reading them up front" {
    const io = std.testing.io;
    const path = ".zig-cache/mapped_file_test.txt";
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = "one\ntwo\nthree\n" });
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};
    var m = try MappedFile.open(io, path);
    defer m.close();
    try std.testing.expectEqualStrings("one\ntwo\nthree\n", m.bytes);
}

test "an empty file maps to no bytes, and a missing one is an error" {
    const io = std.testing.io;
    const path = ".zig-cache/mapped_file_empty.txt";
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = "" });
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};
    var m = try MappedFile.open(io, path);
    defer m.close();
    try std.testing.expectEqual(@as(usize, 0), m.bytes.len);
    try std.testing.expectError(error.FileNotFound, MappedFile.open(io, ".zig-cache/definitely_missing_file"));
}
