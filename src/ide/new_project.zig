//! Creating a project: a folder with a starting set of files.
//!
//!   * `zig_project`: what `zig init` makes (build.zig, build.zig.zon, src/main.zig, src/root.zig)
//!   * `zigui_app`: a window application whose contents come from a UI document: `build.zig`
//!     and `build.zig.zon` (from `zig init`, so the package fingerprint is real, with zigui
//!     added as a path dependency), `main.zig`, `ui/main.ui.zon`, its handlers in `ui/main.zig`,
//!     and the generated `ui_actions.zig` with `.zigide/actions.zon`: open the `.ui.zon` in the
//!     IDE's designer and the Events tab already shows the handler
//!   * `empty`: just a folder with a README (for any language; the IDE needs nothing more)
//!
//!     const made = try new_project.create(gpa, io, "/home/me/code", "myapp", .zigui_app, zigui_root, .{}, &report);
//!     defer gpa.free(made);                     // "/home/me/code/myapp"
//!
//! `zig` must be on PATH for the two Zig templates. `zigui_root` (see `findZiguiRoot`)
//! is the zigui source checkout the new app depends on, written as a relative path.

const std = @import("std");
const project_mod = @import("project.zig");
const handlers = @import("handlers.zig");

pub const Template = enum { zig_project, zigui_app, empty };

pub const Info = struct { template: Template, title: []const u8, detail: []const u8 };

pub const templates = [_]Info{
    .{ .template = .zigui_app, .title = "zigui app", .detail = "A window with a UI document, a button and its handler (needs the zigui source)" },
    .{ .template = .zig_project, .title = "Zig project", .detail = "Executable and library, as `zig init` makes them" },
    .{ .template = .empty, .title = "Empty folder", .detail = "Just a README; for any language" },
};

pub const Error = error{
    InvalidName,
    AlreadyExists,
    /// `zig init` could not run or failed (see `Report.message`).
    ZigInitFailed,
    /// The zigui template needs `zigui_root`.
    NoZiguiSource,
};

/// Why a creation failed, in words.
pub const Report = struct {
    message: [400]u8 = undefined,
    len: usize = 0,

    pub fn text(self: *const Report) []const u8 {
        return self.message[0..self.len];
    }

    fn set(self: *Report, comptime fmt: []const u8, args: anytype) void {
        const s = std.fmt.bufPrint(&self.message, fmt, args) catch self.message[0..0];
        self.len = s.len;
    }
};

/// A project name: a Zig-style identifier of up to 32 characters (it becomes the
/// folder, the package and the program's name).
pub fn validName(name: []const u8) bool {
    return name.len > 0 and name.len <= 32 and std.zig.isValidId(name);
}

/// The zigui source checkout a running IDE was built from, found from its executable's
/// path (`<root>/zig-out/bin/ide` or `<root>/.zig-cache/o/<hash>/ide`) or `ZIGUI_ROOT`.
/// Null when it cannot be found. Caller frees.
pub fn findZiguiRoot(a: std.mem.Allocator, io: std.Io, exe_path: []const u8, environ: ?*const std.process.Environ.Map) !?[]u8 {
    if (environ) |env| if (env.get("ZIGUI_ROOT")) |r| if (isZiguiRoot(io, r)) return try a.dupe(u8, r);
    const markers = [_][]const u8{ "/zig-out/bin/", "/.zig-cache/o/" };
    for (markers) |m| {
        const at = std.mem.lastIndexOf(u8, exe_path, m) orelse continue;
        const root = exe_path[0..at];
        if (isZiguiRoot(io, root)) return try a.dupe(u8, root);
    }
    return null;
}

fn isZiguiRoot(io: std.Io, root: []const u8) bool {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const p = std.fmt.bufPrint(&buf, "{s}/src/root.zig", .{root}) catch return false;
    std.Io.Dir.cwd().access(io, p, .{}) catch return false;
    const z = std.fmt.bufPrint(&buf, "{s}/build.zig.zon", .{root}) catch return false;
    std.Io.Dir.cwd().access(io, z, .{}) catch return false;
    return true;
}

fn fill(a: std.mem.Allocator, template: []const u8, name: []const u8) ![]u8 {
    return std.mem.replaceOwned(u8, a, template, "@@NAME@@", name);
}

/// `zon` (a `build.zig.zon`) with a path dependency on zigui added, and its `paths`
/// listing the zigui app's files instead of `src`.
pub fn patchManifest(a: std.mem.Allocator, zon: []const u8, zigui_rel: []const u8) ![]u8 {
    const marker = ".dependencies = .{";
    const at = std.mem.indexOf(u8, zon, marker) orelse return error.InvalidManifest;
    const head = zon[0 .. at + marker.len];
    const tail = zon[at + marker.len ..];
    const with_dep = try std.fmt.allocPrint(a, "{s}\n        .zigui = .{{ .path = \"{s}\" }},{s}", .{ head, zigui_rel, tail });
    defer a.free(with_dep);
    return std.mem.replaceOwned(u8, a, with_dep, "\"src\",", "\"main.zig\",\n        \"ui\",\n        \"ui_actions.zig\",");
}

fn runZigInit(gpa: std.mem.Allocator, io: std.Io, dir: []const u8, zig: []const u8, report: *Report) bool {
    const res = std.process.run(gpa, io, .{ .argv = &.{ zig, "init" }, .cwd = .{ .path = dir } }) catch |err| {
        report.set("could not run `{s} init` ({s}); is zig installed?", .{ zig, @errorName(err) });
        return false;
    };
    defer gpa.free(res.stdout);
    defer gpa.free(res.stderr);
    switch (res.term) {
        .exited => |code| if (code == 0) return true,
        else => {},
    }
    const tail = std.mem.trim(u8, res.stderr, " \n");
    report.set("`zig init` failed: {s}", .{tail[0..@min(tail.len, 300)]});
    return false;
}

/// Which Zig makes the project (the IDE passes ZVM's choice).
pub const Zig = struct {
    /// The program that runs `zig init` (default: `zig` from PATH).
    exe: []const u8 = "zig",
    /// Recorded in `.zigversion` so opening the project selects this version (null: not recorded).
    version: ?[]const u8 = null,
};

/// Make `<parent>/<name>` from `template`. Returns its absolute path (caller frees).
pub fn create(gpa: std.mem.Allocator, io: std.Io, parent: []const u8, name: []const u8, template: Template, zigui_root: ?[]const u8, zig: Zig, report: *Report) ![]u8 {
    if (!validName(name)) {
        report.set("\"{s}\" is not a valid project name: use letters, digits and underscores, starting with a letter", .{name});
        return error.InvalidName;
    }
    if (template == .zigui_app and zigui_root == null) {
        report.set("the zigui source folder was not found (set ZIGUI_ROOT), so the zigui app template is unavailable", .{});
        return error.NoZiguiSource;
    }
    const target = try std.fs.path.join(gpa, &.{ parent, name });
    errdefer gpa.free(target);
    const cwd = std.Io.Dir.cwd();
    // An existing empty folder is fine; anything in it is not.
    if (cwd.openDir(io, target, .{ .iterate = true })) |d| {
        var dir = d;
        defer dir.close(io);
        var it = dir.iterate();
        if (it.next(io) catch null) |_| {
            report.set("{s} already exists and is not empty", .{target});
            return error.AlreadyExists;
        }
    } else |_| {}
    try cwd.createDirPath(io, target);
    var dir = try cwd.openDir(io, target, .{ .iterate = true });
    defer dir.close(io);

    switch (template) {
        .empty => {
            const readme = try std.fmt.allocPrint(gpa, "# {s}\n\nCreated with the zigui IDE.\n", .{name});
            defer gpa.free(readme);
            try dir.writeFile(io, .{ .sub_path = "README.md", .data = readme });
        },
        .zig_project => if (!runZigInit(gpa, io, target, zig.exe, report)) return error.ZigInitFailed,
        .zigui_app => try createZiguiApp(gpa, io, dir, target, name, zigui_root.?, zig.exe, report),
    }
    if (zig.version) |v| {
        const line = try std.fmt.allocPrint(gpa, "{s}\n", .{v});
        defer gpa.free(line);
        try dir.writeFile(io, .{ .sub_path = ".zigversion", .data = line });
    }
    return target;
}

fn createZiguiApp(gpa: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, target: []const u8, name: []const u8, zigui_root: []const u8, zig_exe: []const u8, report: *Report) !void {
    // `zig init` gives a manifest with a real fingerprint; its sample sources are not wanted.
    if (!runZigInit(gpa, io, target, zig_exe, report)) return error.ZigInitFailed;
    dir.deleteTree(io, "src") catch {};

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const rel = try std.fs.path.relativeAllocPosix(a, "/", target, zigui_root);
    const zon = try dir.readFileAlloc(io, "build.zig.zon", a, .limited(64 * 1024));
    try dir.writeFile(io, .{ .sub_path = "build.zig.zon", .data = try patchManifest(a, zon, rel) });
    try dir.writeFile(io, .{ .sub_path = "build.zig", .data = try fill(a, @embedFile("templates/zigui_app/build.zig.tmpl"), name) });
    try dir.writeFile(io, .{ .sub_path = "main.zig", .data = try fill(a, @embedFile("templates/zigui_app/main.zig.tmpl"), name) });
    try dir.createDirPath(io, "ui");
    try dir.writeFile(io, .{ .sub_path = "ui/main.ui.zon", .data = @embedFile("templates/zigui_app/ui/main.ui.zon.tmpl") });
    try dir.writeFile(io, .{ .sub_path = "ui/main.zig", .data = @embedFile("templates/zigui_app/ui/main.zig.tmpl") });
    const readme = try std.fmt.allocPrint(a, "# {s}\n\nA zigui application. `zig build run` starts it from this folder; the window's contents are\n`ui/main.ui.zon` (edit it in the zigui IDE's designer or as text) and its button's click is\n`Main.onHelloClick` in `ui/main.zig`. `ui_actions.zig` is generated by the IDE from\n`.zigide/actions.zon`: do not edit it.\n", .{name});
    try dir.writeFile(io, .{ .sub_path = "README.md", .data = readme });

    // The handler registry: the manifest binds the document's action name to the method.
    const dir2 = try std.Io.Dir.cwd().openDir(io, target, .{ .iterate = true });
    var project = try project_mod.Project.fromDir(gpa, io, dir2);
    defer project.close();
    var h = try handlers.Handlers.init(gpa, &project);
    defer h.deinit();
    try h.manifest.bind("helloClick", "Main", "onHelloClick", "ui/main.zig");
    try h.manifest.setDefault("Main", "ui/main.zig");
    try h.commit();
}

// ---- tests -----------------------------------------------------------------

const testing = std.testing;

test "names must be identifiers of a sensible length" {
    try testing.expect(validName("myapp") and validName("My_App2") and validName("_x"));
    try testing.expect(!validName("") and !validName("2fast") and !validName("my-app") and !validName("has space") and !validName("fn"));
    try testing.expect(!validName("a_name_that_is_far_too_long_for_a_package"));
}

test "the manifest gets a zigui path dependency and the app's file list" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const zon =
        \\.{
        \\    .name = .demo,
        \\    .dependencies = .{
        \\        // See `zig fetch --save`
        \\    },
        \\    .paths = .{
        \\        "build.zig",
        \\        "src",
        \\    },
        \\}
    ;
    const out = try patchManifest(a, zon, "../../zigui");
    try testing.expect(std.mem.indexOf(u8, out, ".dependencies = .{\n        .zigui = .{ .path = \"../../zigui\" },\n        // See") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"main.zig\",\n        \"ui\",\n        \"ui_actions.zig\",") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"src\"") == null);
    try testing.expectError(error.InvalidManifest, patchManifest(a, ".{ .name = .x }", "x"));
}

test "the zigui source is found from the executable's path" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const io = testing.io;
    try tmp.dir.createDirPath(io, "ui_src/src");
    try tmp.dir.createDirPath(io, "ui_src/zig-out/bin");
    try tmp.dir.writeFile(io, .{ .sub_path = "ui_src/src/root.zig", .data = "" });
    try tmp.dir.writeFile(io, .{ .sub_path = "ui_src/build.zig.zon", .data = ".{}" });
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPathFile(io, "ui_src", &buf);
    const root = buf[0..n];
    var path_buf: [std.fs.max_path_bytes + 32]u8 = undefined;
    const exe = try std.fmt.bufPrint(&path_buf, "{s}/zig-out/bin/ide", .{root});
    const found = (try findZiguiRoot(testing.allocator, io, exe, null)).?;
    defer testing.allocator.free(found);
    try testing.expectEqualStrings(root, found);
    const cached = try std.fmt.bufPrint(&path_buf, "{s}/.zig-cache/o/abc/ide", .{root});
    const found2 = (try findZiguiRoot(testing.allocator, io, cached, null)).?;
    defer testing.allocator.free(found2);
    try testing.expectEqualStrings(root, found2);
    try testing.expect((try findZiguiRoot(testing.allocator, io, "/usr/bin/ide", null)) == null);
    // ZIGUI_ROOT wins.
    var env = std.process.Environ.Map.init(testing.allocator);
    defer env.deinit();
    try env.put("ZIGUI_ROOT", root);
    const found3 = (try findZiguiRoot(testing.allocator, io, "/usr/bin/ide", &env)).?;
    defer testing.allocator.free(found3);
    try testing.expectEqualStrings(root, found3);
}

test "an empty project is a folder with a README; bad names and busy folders are refused" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPathFile(testing.io, ".", &buf);
    const parent = buf[0..n];
    var report: Report = .{};
    const path = try create(testing.allocator, testing.io, parent, "scratch", .empty, null, .{}, &report);
    defer testing.allocator.free(path);
    try testing.expect(std.mem.endsWith(u8, path, "/scratch"));
    const readme = try tmp.dir.readFileAlloc(testing.io, "scratch/README.md", testing.allocator, .limited(4096));
    defer testing.allocator.free(readme);
    try testing.expect(std.mem.startsWith(u8, readme, "# scratch"));
    try testing.expectError(error.AlreadyExists, create(testing.allocator, testing.io, parent, "scratch", .empty, null, .{}, &report));
    try testing.expect(std.mem.indexOf(u8, report.text(), "not empty") != null);
    try testing.expectError(error.InvalidName, create(testing.allocator, testing.io, parent, "bad name", .empty, null, .{}, &report));
    try testing.expectError(error.NoZiguiSource, create(testing.allocator, testing.io, parent, "fine", .zigui_app, null, .{}, &report));

    // A chosen Zig version is recorded so opening the project selects it again.
    const v = try create(testing.allocator, testing.io, parent, "versioned", .empty, null, .{ .version = "0.16.0" }, &report);
    defer testing.allocator.free(v);
    const zv = try tmp.dir.readFileAlloc(testing.io, "versioned/.zigversion", testing.allocator, .limited(64));
    defer testing.allocator.free(zv);
    try testing.expectEqualStrings("0.16.0\n", zv);
}

test "a zigui app project has its files, a patched manifest and a registered handler" {
    if (@import("builtin").os.tag != .linux) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDirPath(testing.io, "code");
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPathFile(testing.io, "code", &buf);
    const parent = buf[0..n];
    var report: Report = .{};
    const path = create(testing.allocator, testing.io, parent, "zapp", .zigui_app, "/opt/zigui", .{}, &report) catch |err| {
        if (err == error.ZigInitFailed) return error.SkipZigTest; // no zig on PATH
        return err;
    };
    defer testing.allocator.free(path);
    const read = struct {
        fn f(d: std.Io.Dir, p: []const u8) ![]u8 {
            return d.readFileAlloc(testing.io, p, testing.allocator, .limited(1 << 20));
        }
    }.f;
    var dir = try std.Io.Dir.cwd().openDir(testing.io, path, .{});
    defer dir.close(testing.io);
    const zon = try read(dir, "build.zig.zon");
    defer testing.allocator.free(zon);
    try testing.expect(std.mem.indexOf(u8, zon, ".name = .zapp") != null);
    try testing.expect(std.mem.indexOf(u8, zon, ".fingerprint = 0x") != null); // a real one, from zig init
    try testing.expect(std.mem.indexOf(u8, zon, ".zigui = .{ .path = \"") != null and std.mem.indexOf(u8, zon, "/opt/zigui\" }") != null);
    const build = try read(dir, "build.zig");
    defer testing.allocator.free(build);
    try testing.expect(std.mem.indexOf(u8, build, ".name = \"zapp\"") != null);
    const main = try read(dir, "main.zig");
    defer testing.allocator.free(main);
    try testing.expect(std.mem.indexOf(u8, main, "sdl.Window.create(\"zapp\"") != null);
    try testing.expectError(error.FileNotFound, dir.access(testing.io, "src", .{}));
    // The UI document parses, and the registry knows its action.
    const ui_text = try read(dir, "ui/main.ui.zon");
    defer testing.allocator.free(ui_text);
    var doc = try @import("../uidoc/doc.zig").parseDoc(testing.allocator, ui_text, null, null);
    defer doc.deinit();
    try testing.expectEqual(@as(usize, 2), doc.root.children.items.len);
    try testing.expectEqualStrings("helloClick", doc.root.children.items[1].on[0].action);
    const actions = try read(dir, "ui_actions.zig");
    defer testing.allocator.free(actions);
    try testing.expect(std.mem.indexOf(u8, actions, "\"helloClick\", zigui.event.Callback.bind(ctx.main, f0.Main.onHelloClick)") != null);
    const manifest = try read(dir, ".zigide/actions.zon");
    defer testing.allocator.free(manifest);
    try testing.expect(std.mem.indexOf(u8, manifest, "\"onHelloClick\"") != null);
}

test "a zig project is what zig init makes" {
    if (@import("builtin").os.tag != .linux) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPathFile(testing.io, ".", &buf);
    var report: Report = .{};
    const path = create(testing.allocator, testing.io, buf[0..n], "hello", .zig_project, null, .{}, &report) catch |err| {
        if (err == error.ZigInitFailed) return error.SkipZigTest;
        return err;
    };
    defer testing.allocator.free(path);
    try tmp.dir.access(testing.io, "hello/build.zig", .{});
    try tmp.dir.access(testing.io, "hello/src/main.zig", .{});
}
