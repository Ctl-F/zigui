//! Restarting the running program: start a fresh copy of the executable, then
//! let the caller quit. For building the IDE inside itself: rebuild, then
//! relaunch to run the new build, reopening the same folder and files.
//!
//!     const argv = try relaunch.argv(arena, exe_path, project_root, open_files);
//!     try relaunch.spawnDetached(io, argv);
//!     quit = true;                      // the new instance is already starting
//!
//! The new process is detached (no pipes; it outlives this one). The path of a
//! running executable that was replaced on disk by a rebuild is reported by the
//! system with a " (deleted)" suffix; `cleanPath` removes it so the *new* file
//! is what gets started.

const std = @import("std");

/// `path` without the " (deleted)" marker the OS adds for a replaced executable.
pub fn cleanPath(path: []const u8) []const u8 {
    const marker = " (deleted)";
    return if (std.mem.endsWith(u8, path, marker)) path[0 .. path.len - marker.len] else path;
}

/// The command line for the new instance: the executable, the project folder,
/// and `--open <file>` for each file to reopen. Allocated from `a`.
pub fn argv(a: std.mem.Allocator, exe: []const u8, project_root: []const u8, open_files: []const []const u8) ![]const []const u8 {
    var list: std.ArrayListUnmanaged([]const u8) = .empty;
    try list.append(a, cleanPath(exe));
    try list.append(a, project_root);
    for (open_files) |f| {
        try list.append(a, "--open");
        try list.append(a, f);
    }
    return list.items;
}

/// Start `command` with no standard streams attached; it keeps running after we exit.
pub fn spawnDetached(io: std.Io, command: []const []const u8) !void {
    _ = try std.process.spawn(io, .{
        .argv = command,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    });
}

/// The files named by `--open` arguments in `args` (after the program name and folder).
/// Allocated from `a`.
pub fn openFilesFrom(a: std.mem.Allocator, args: []const []const u8) ![]const []const u8 {
    var list: std.ArrayListUnmanaged([]const u8) = .empty;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--open") and i + 1 < args.len) {
            try list.append(a, args[i + 1]);
            i += 1;
        }
    }
    return list.items;
}

const testing = std.testing;

test "the command line for the new instance, and the marker on a replaced executable" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cmd = try argv(a, "/home/me/ide/zig-out/bin/ide (deleted)", "/home/me/proj", &.{ "src/a.zig", "build.zig" });
    try testing.expectEqual(@as(usize, 6), cmd.len);
    try testing.expectEqualStrings("/home/me/ide/zig-out/bin/ide", cmd[0]);
    try testing.expectEqualStrings("/home/me/proj", cmd[1]);
    try testing.expectEqualStrings("--open", cmd[2]);
    try testing.expectEqualStrings("build.zig", cmd[5]);
    // And back: the new instance reads the same files from its arguments.
    const files = try openFilesFrom(a, cmd[2..]);
    try testing.expectEqual(@as(usize, 2), files.len);
    try testing.expectEqualStrings("src/a.zig", files[0]);
    try testing.expectEqualStrings("/home/me/ide", cleanPath("/home/me/ide"));
}

test "a detached process starts" {
    if (@import("builtin").os.tag != .linux) return error.SkipZigTest;
    try spawnDetached(testing.io, &.{"/bin/true"});
    try testing.expectError(error.FileNotFound, spawnDetached(testing.io, &.{"/nonexistent/program"}));
}
