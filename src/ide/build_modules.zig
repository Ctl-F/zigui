//! Finding the code a project's build brings in, so the IDE can index it: the
//! packages listed in `build.zig.zon` (fetched into Zig's package cache, or
//! referenced by path), modules a `build.zig` creates from files outside the
//! project folder, and C headers a `build.zig` translates (`addTranslateC`),
//! which are translated with `zig translate-c` and cached (`translate_cache.zig`).
//!
//! This reads the build files as text instead of running the build, so it sees
//! what is written plainly: `b.addTranslateC(.{ .root_source_file = b.path("c/api.h"), ... })`
//! followed by `translate_c.addIncludePath(b.path("c/include"))` and
//! `translate_c.defineCMacro("NAME", "1")`. Paths or settings computed in code,
//! generated headers and options chosen at build time are not seen. (zls runs the
//! build with its own build runner for exactness; this is the cheap, offline cousin.)
//!
//!     var planner = try Planner.create(gpa, .{ .project_root = project.root, .global_cache = zig_info.global_cache_dir,
//!                                              .translate_cache = "/home/me/.cache/zigui-ide/translate-c", .zig = "zig" });
//!     defer planner.destroy();
//!     const idx = try SymbolIndex.startModules(gpa, &project, planner.planner(), sdl.wake);
//!
//! No UI here.

const std = @import("std");
const symbol_index = @import("symbol_index.zig");
const translate_cache = @import("translate_cache.zig");

// ---- reading build files (text) ---------------------------------------------

/// Index after the string literal that starts at `i` (`src[i] == '"'`).
fn skipString(src: []const u8, i: usize) usize {
    var k = i + 1;
    while (k < src.len) : (k += 1) {
        if (src[k] == '\\') {
            k += 1;
            continue;
        }
        if (src[k] == '"') return k + 1;
        if (src[k] == '\n') return k; // unterminated
    }
    return src.len;
}

/// The index of the bracket matching the one at `open` (`(`, `{` or `[`), skipping strings and `//` comments.
fn matching(src: []const u8, open: usize) ?usize {
    var depth: usize = 0;
    var i = open;
    while (i < src.len) {
        switch (src[i]) {
            '"' => {
                i = skipString(src, i);
                continue;
            },
            '/' => if (i + 1 < src.len and src[i + 1] == '/') {
                i = std.mem.indexOfScalarPos(u8, src, i, '\n') orelse return null;
                continue;
            },
            '(', '{', '[' => depth += 1,
            ')', '}', ']' => {
                depth -= 1;
                if (depth == 0) return i;
            },
            else => {},
        }
        i += 1;
    }
    return null;
}

/// The string literal's content starting the first `"` at or after `from` within `end`.
fn nextString(src: []const u8, from: usize, end: usize) ?struct { text: []const u8, after: usize } {
    const q = std.mem.indexOfScalarPos(u8, src[0..end], from, '"') orelse return null;
    const e = skipString(src, q);
    if (e <= q + 1 or e > end) return null;
    return .{ .text = src[q + 1 .. e - 1], .after = e };
}

/// The literal in the first `path("...")` of `src[from..end]` (a `b.path("x")` LazyPath).
fn pathLiteral(src: []const u8, from: usize, end: usize) ?[]const u8 {
    const at = std.mem.indexOfPos(u8, src[0..end], from, "path(") orelse return null;
    const s = nextString(src, at, end) orelse return null;
    return s.text;
}

/// The expression text of field `.name = ...` inside an options struct `body`, up to the next top-level comma.
fn fieldValue(body: []const u8, name: []const u8) ?[]const u8 {
    var needle_buf: [64]u8 = undefined;
    const needle = std.fmt.bufPrint(&needle_buf, ".{s}", .{name}) catch return null;
    var from: usize = 0;
    while (std.mem.indexOfPos(u8, body, from, needle)) |at| {
        from = at + needle.len;
        var i = from;
        while (i < body.len and (body[i] == ' ' or body[i] == '\t' or body[i] == '\n')) i += 1;
        if (i >= body.len or body[i] != '=') continue;
        i += 1;
        const start = i;
        var depth: usize = 0;
        while (i < body.len) : (i += 1) {
            switch (body[i]) {
                '"' => i = skipString(body, i) - 1,
                '(', '{', '[' => depth += 1,
                ')', '}', ']' => if (depth == 0) return body[start..i] else {
                    depth -= 1;
                },
                ',' => if (depth == 0) return body[start..i],
                else => {},
            }
        }
        return body[start..];
    }
    return null;
}

pub const CCall = struct {
    /// The header as written (`c/api.h`), relative to the build root.
    header: []const u8,
    include_dirs: []const []const u8,
    system_include_dirs: []const []const u8,
    /// `NAME` or `NAME=VALUE`.
    defines: []const []const u8,
};

/// Is the text at `at` inside a `//` comment (on its own line)?
fn inComment(src: []const u8, at: usize) bool {
    const line_start = if (std.mem.lastIndexOfScalar(u8, src[0..at], '\n')) |n| n + 1 else 0;
    return std.mem.indexOf(u8, src[line_start..at], "//") != null;
}

/// The identifier of `const NAME = ` on the statement that contains `at`, if any.
fn declaredName(src: []const u8, at: usize) ?[]const u8 {
    const line_start = (std.mem.lastIndexOfScalar(u8, src[0..at], '\n') orelse 0);
    const stmt = src[line_start..at];
    const c = std.mem.lastIndexOf(u8, stmt, "const ") orelse std.mem.lastIndexOf(u8, stmt, "var ") orelse return null;
    var i = c + (if (std.mem.startsWith(u8, stmt[c..], "const ")) @as(usize, 6) else 4);
    const start = i;
    while (i < stmt.len and (std.ascii.isAlphanumeric(stmt[i]) or stmt[i] == '_')) i += 1;
    if (i == start) return null;
    return stmt[start..i];
}

/// The calls of `<name>.<method>(` in `src`, each as the text between the parentheses.
fn methodCalls(a: std.mem.Allocator, src: []const u8, name: []const u8, method: []const u8) ![][]const u8 {
    var list: std.ArrayListUnmanaged([]const u8) = .empty;
    const needle = try std.fmt.allocPrint(a, "{s}.{s}(", .{ name, method });
    var from: usize = 0;
    while (std.mem.indexOfPos(u8, src, from, needle)) |at| {
        from = at + needle.len;
        const open = at + needle.len - 1;
        const close = matching(src, open) orelse continue;
        try list.append(a, src[open + 1 .. close]);
    }
    return list.toOwnedSlice(a);
}

/// Every `addTranslateC(...)` in a build file with the include paths and defines added to it.
pub fn translateCalls(a: std.mem.Allocator, src: []const u8) ![]CCall {
    var out: std.ArrayListUnmanaged(CCall) = .empty;
    var from: usize = 0;
    const key = "addTranslateC(";
    while (std.mem.indexOfPos(u8, src, from, key)) |at| {
        from = at + key.len;
        if (inComment(src, at)) continue;
        const open = at + key.len - 1;
        const close = matching(src, open) orelse continue;
        const body = src[open + 1 .. close];
        const value = fieldValue(body, "root_source_file") orelse continue;
        const header = pathLiteral(value, 0, value.len) orelse continue;
        var includes: std.ArrayListUnmanaged([]const u8) = .empty;
        var systems: std.ArrayListUnmanaged([]const u8) = .empty;
        var defines: std.ArrayListUnmanaged([]const u8) = .empty;
        if (declaredName(src, at)) |name| {
            for (try methodCalls(a, src, name, "addIncludePath")) |args| {
                if (pathLiteral(args, 0, args.len)) |p| try includes.append(a, p);
            }
            for (try methodCalls(a, src, name, "addSystemIncludePath")) |args| {
                if (pathLiteral(args, 0, args.len)) |p| try systems.append(a, p);
            }
            for (try methodCalls(a, src, name, "defineCMacro")) |args| {
                const first = nextString(args, 0, args.len) orelse continue;
                if (nextString(args, first.after, args.len)) |second| {
                    try defines.append(a, try std.fmt.allocPrint(a, "{s}={s}", .{ first.text, second.text }));
                } else try defines.append(a, first.text);
            }
        }
        try out.append(a, .{
            .header = header,
            .include_dirs = try includes.toOwnedSlice(a),
            .system_include_dirs = try systems.toOwnedSlice(a),
            .defines = try defines.toOwnedSlice(a),
        });
    }
    return out.toOwnedSlice(a);
}

pub const ModuleDef = struct {
    name: []const u8,
    /// As written, relative to the build root.
    root_file: []const u8,
};

/// Modules made with `addModule("name", .{ .root_source_file = b.path("...") })` or `createModule(...)`.
pub fn moduleDefs(a: std.mem.Allocator, src: []const u8) ![]ModuleDef {
    var out: std.ArrayListUnmanaged(ModuleDef) = .empty;
    for ([_][]const u8{ "addModule(", "createModule(" }) |key| {
        var from: usize = 0;
        while (std.mem.indexOfPos(u8, src, from, key)) |at| {
            from = at + key.len;
            if (inComment(src, at)) continue;
            const open = at + key.len - 1;
            const close = matching(src, open) orelse continue;
            const body = src[open + 1 .. close];
            const value = fieldValue(body, "root_source_file") orelse continue;
            const file = pathLiteral(value, 0, value.len) orelse continue;
            // addModule's first argument names it; createModule's are anonymous (named after the file).
            var name: []const u8 = std.fs.path.stem(file);
            if (key[0] == 'a') {
                if (nextString(body, 0, body.len)) |s| {
                    if (std.mem.indexOfScalar(u8, body[0..s.after], '{') == null) name = s.text;
                }
            }
            try out.append(a, .{ .name = name, .root_file = file });
        }
    }
    return out.toOwnedSlice(a);
}

pub const Dep = struct {
    name: []const u8,
    /// `.path = "../x"` (relative to the manifest's folder).
    path: ?[]const u8 = null,
    /// `.hash = "..."`: the folder name under `<global cache>/p/`.
    hash: ?[]const u8 = null,
};

/// The entries of `.dependencies = .{ ... }` in a `build.zig.zon`.
pub fn dependencies(a: std.mem.Allocator, zon: []const u8) ![]Dep {
    var out: std.ArrayListUnmanaged(Dep) = .empty;
    const at = std.mem.indexOf(u8, zon, ".dependencies") orelse return out.toOwnedSlice(a);
    const open = std.mem.indexOfScalarPos(u8, zon, at, '{') orelse return out.toOwnedSlice(a);
    const close = matching(zon, open) orelse return out.toOwnedSlice(a);
    var i = open + 1;
    while (i < close) {
        // An entry: `.name = .{ ... },` (the name may be `@"quoted"`).
        const dot = std.mem.indexOfScalarPos(u8, zon, i, '.') orelse break;
        if (dot >= close) break;
        const eq = std.mem.indexOfScalarPos(u8, zon, dot, '=') orelse break;
        var name = std.mem.trim(u8, zon[dot + 1 .. eq], " \t\n");
        if (std.mem.startsWith(u8, name, "@\"") and name.len >= 3) name = name[2 .. name.len - 1];
        const body_open = std.mem.indexOfScalarPos(u8, zon, eq, '{') orelse break;
        const body_close = matching(zon, body_open) orelse break;
        const body = zon[body_open + 1 .. body_close];
        var dep: Dep = .{ .name = name };
        if (fieldValue(body, "path")) |v| dep.path = stringOf(v);
        if (fieldValue(body, "hash")) |v| dep.hash = stringOf(v);
        if (dep.path != null or dep.hash != null) try out.append(a, dep);
        i = body_close + 1;
    }
    return out.toOwnedSlice(a);
}

fn stringOf(expr: []const u8) ?[]const u8 {
    const s = nextString(expr, 0, expr.len) orelse return null;
    return s.text;
}

// ---- the planner -------------------------------------------------------------

pub const Config = struct {
    project_root: []const u8,
    /// Zig's global cache folder (`zig env`'s `global_cache_dir`): fetched packages live in `p/<hash>`.
    global_cache: ?[]const u8 = null,
    /// Where translated headers are kept (null: C headers are not translated).
    translate_cache: ?[]const u8 = null,
    zig: []const u8 = "zig",
};

pub const Planner = struct {
    gpa: std.mem.Allocator,
    project_root: []u8,
    global_cache: ?[]u8,
    translate_cache: ?[]u8,
    zig: []u8,

    pub fn create(gpa: std.mem.Allocator, c: Config) !*Planner {
        const self = try gpa.create(Planner);
        errdefer gpa.destroy(self);
        const root = try gpa.dupe(u8, c.project_root);
        errdefer gpa.free(root);
        const gc: ?[]u8 = if (c.global_cache) |g| try gpa.dupe(u8, g) else null;
        errdefer if (gc) |g| gpa.free(g);
        const tc: ?[]u8 = if (c.translate_cache) |t| try gpa.dupe(u8, t) else null;
        errdefer if (tc) |t| gpa.free(t);
        const zig = try gpa.dupe(u8, c.zig);
        self.* = .{ .gpa = gpa, .project_root = root, .global_cache = gc, .translate_cache = tc, .zig = zig };
        return self;
    }

    pub fn destroy(self: *Planner) void {
        self.gpa.free(self.project_root);
        if (self.global_cache) |g| self.gpa.free(g);
        if (self.translate_cache) |t| self.gpa.free(t);
        self.gpa.free(self.zig);
        self.gpa.destroy(self);
    }

    pub fn planner(self: *Planner) symbol_index.Planner {
        return .{ .ctx = self, .plan = planThunk };
    }

    fn planThunk(ctx: ?*anyopaque, gpa: std.mem.Allocator, arena: std.mem.Allocator, io: std.Io, out: *std.ArrayListUnmanaged(symbol_index.Root)) void {
        const self: *Planner = @ptrCast(@alignCast(ctx.?));
        self.plan(gpa, arena, io, out) catch |err| std.log.warn("build modules: {s}", .{@errorName(err)});
    }

    fn isDir(io: std.Io, path: []const u8) bool {
        var d = std.Io.Dir.cwd().openDir(io, path, .{}) catch return false;
        d.close(io);
        return true;
    }

    fn readText(gpa: std.mem.Allocator, io: std.Io, dir: []const u8, name: []const u8) ?[]u8 {
        const p = std.fs.path.join(gpa, &.{ dir, name }) catch return null;
        defer gpa.free(p);
        return std.Io.Dir.cwd().readFileAlloc(io, p, gpa, .limited(1 << 20)) catch null;
    }

    /// Work out the roots: dependencies (recursively, a few levels), modules from outside the project, translated headers.
    pub fn plan(self: *Planner, gpa: std.mem.Allocator, arena: std.mem.Allocator, io: std.Io, out: *std.ArrayListUnmanaged(symbol_index.Root)) !void {
        var seen: std.StringHashMapUnmanaged(void) = .empty;
        defer seen.deinit(gpa);
        try seen.put(gpa, self.project_root, {});

        const Item = struct { dir: []const u8, depth: u32 };
        var queue: std.ArrayListUnmanaged(Item) = .empty;
        defer queue.deinit(gpa);
        try queue.append(gpa, .{ .dir = self.project_root, .depth = 0 });
        var head: usize = 0;
        while (head < queue.items.len) : (head += 1) {
            const item = queue.items[head];
            const is_project = item.depth == 0;

            if (readText(gpa, io, item.dir, "build.zig.zon")) |zon| {
                defer gpa.free(zon);
                if (item.depth < 3) for (try dependencies(arena, zon)) |dep| {
                    const dir: ?[]const u8 = blk: {
                        if (dep.path) |p| break :blk try std.fs.path.resolve(arena, &.{ item.dir, p });
                        if (dep.hash) |h| if (self.global_cache) |g| break :blk try std.fs.path.join(arena, &.{ g, "p", h });
                        break :blk null;
                    };
                    const d = dir orelse continue;
                    if (seen.contains(d) or !isDir(io, d)) continue;
                    try seen.put(gpa, d, {});
                    try out.append(gpa, .{ .label = try std.fmt.allocPrint(arena, "dep/{s}", .{dep.name}), .dir = d, .origin = .dependency });
                    try queue.append(gpa, .{ .dir = d, .depth = item.depth + 1 });
                };
            }

            const build_zig = readText(gpa, io, item.dir, "build.zig") orelse continue;
            defer gpa.free(build_zig);

            if (is_project) {
                for (try moduleDefs(arena, build_zig)) |m| {
                    const file = try std.fs.path.resolve(arena, &.{ item.dir, m.root_file });
                    // Inside the project it is already indexed.
                    if (std.mem.startsWith(u8, file, self.project_root)) continue;
                    const dir = std.fs.path.dirname(file) orelse continue;
                    if (seen.contains(dir) or !isDir(io, dir)) continue;
                    try seen.put(gpa, dir, {});
                    try out.append(gpa, .{ .label = try std.fmt.allocPrint(arena, "module/{s}", .{m.name}), .dir = dir, .origin = .dependency });
                }
            }

            const cache = self.translate_cache orelse continue;
            for (try translateCalls(arena, build_zig)) |c| {
                const header = try std.fs.path.resolve(arena, &.{ item.dir, c.header });
                std.Io.Dir.cwd().access(io, header, .{}) catch continue; // a generated header: not there to translate
                var includes: std.ArrayListUnmanaged([]const u8) = .empty;
                // The header's own folder, as a C compiler would look first, and what the build added.
                try includes.append(arena, std.fs.path.dirname(header) orelse item.dir);
                for (c.include_dirs) |d| try includes.append(arena, try std.fs.path.resolve(arena, &.{ item.dir, d }));
                var systems: std.ArrayListUnmanaged([]const u8) = .empty;
                for (c.system_include_dirs) |d| try systems.append(arena, try std.fs.path.resolve(arena, &.{ item.dir, d }));
                const translated = translate_cache.translate(gpa, io, .{
                    .zig = self.zig,
                    .header = header,
                    .include_dirs = includes.items,
                    .system_include_dirs = systems.items,
                    .defines = c.defines,
                    .cache_dir = cache,
                }) catch null;
                const path = translated orelse continue;
                defer gpa.free(path);
                try out.append(gpa, .{
                    .label = try std.fmt.allocPrint(arena, "c/{s}", .{std.fs.path.basename(header)}),
                    .dir = try arena.dupe(u8, std.fs.path.dirname(path) orelse cache),
                    .origin = .c,
                    .only_file = try arena.dupe(u8, std.fs.path.basename(path)),
                });
            }
        }
    }
};

// ---- tests -----------------------------------------------------------------

const testing = std.testing;

test "addTranslateC calls give the header, include paths and defines" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const src =
        \\const std = @import("std");
        \\pub fn build(b: *std.Build) void {
        \\    // const old = b.addTranslateC(.{ .root_source_file = b.path("old.h") });
        \\    const tc = b.addTranslateC(.{
        \\        .root_source_file = b.path("c/api.h"),
        \\        .target = target,
        \\        .optimize = optimize,
        \\    });
        \\    tc.addIncludePath(b.path("c/include"));
        \\    tc.addSystemIncludePath(b.path("vendor"));
        \\    tc.defineCMacro("FEATURE", "1");
        \\    tc.defineCMacro("PLAIN", null);
        \\    const other = b.addTranslateC(.{ .root_source_file = b.path("x.h") });
        \\    other.addIncludePath(b.path("elsewhere"));
        \\}
    ;
    const calls = try translateCalls(arena.allocator(), src);
    try testing.expectEqual(@as(usize, 2), calls.len); // the commented-out call is not one
    var api: ?CCall = null;
    var other: ?CCall = null;
    for (calls) |c| {
        if (std.mem.eql(u8, c.header, "c/api.h")) api = c;
        if (std.mem.eql(u8, c.header, "x.h")) other = c;
    }
    try testing.expectEqual(@as(usize, 1), api.?.include_dirs.len);
    try testing.expectEqualStrings("c/include", api.?.include_dirs[0]);
    try testing.expectEqualStrings("vendor", api.?.system_include_dirs[0]);
    try testing.expectEqual(@as(usize, 2), api.?.defines.len);
    try testing.expectEqualStrings("FEATURE=1", api.?.defines[0]);
    try testing.expectEqualStrings("PLAIN", api.?.defines[1]);
    try testing.expectEqualStrings("elsewhere", other.?.include_dirs[0]); // not mixed with the other's
}

test "modules and dependencies are read from the build files" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const defs = try moduleDefs(a,
        \\const m = b.addModule("shared", .{ .root_source_file = b.path("../shared/src/root.zig") });
        \\const private = b.createModule(.{ .root_source_file = b.path("src/util.zig") });
    );
    try testing.expectEqual(@as(usize, 2), defs.len);
    try testing.expectEqualStrings("shared", defs[0].name);
    try testing.expectEqualStrings("../shared/src/root.zig", defs[0].root_file);
    try testing.expectEqualStrings("util", defs[1].name);

    const deps = try dependencies(a,
        \\.{
        \\    .name = .app,
        \\    .fingerprint = 0xc4df00112233aabb,
        \\    .dependencies = .{
        \\        .zigimg = .{
        \\            .url = "https://github.com/zigimg/zigimg/archive/abc.tar.gz",
        \\            .hash = "zigimg-0.1.0-AAAAAB",
        \\        },
        \\        .@"local-lib" = .{ .path = "../lib" },
        \\        .lazy = .{ .url = "https://x", .hash = "lazy-1-BBBB", .lazy = true },
        \\    },
        \\    .paths = .{ "" },
        \\}
    );
    try testing.expectEqual(@as(usize, 3), deps.len);
    try testing.expectEqualStrings("zigimg", deps[0].name);
    try testing.expectEqualStrings("zigimg-0.1.0-AAAAAB", deps[0].hash.?);
    try testing.expectEqualStrings("local-lib", deps[1].name);
    try testing.expectEqualStrings("../lib", deps[1].path.?);
    try testing.expectEqualStrings("lazy-1-BBBB", deps[2].hash.?);
}

test "the planner finds fetched and path dependencies, outside modules and translated headers" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const a = testing.allocator;
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(testing.io, &buf);
    const base = try a.dupe(u8, buf[0..n]);
    defer a.free(base);
    // proj/ depends on a fetched package (in cache/p/pkg-1) and a sibling path dependency (../lib); it also has a C header.
    try tmp.dir.createDirPath(testing.io, "proj/c");
    try tmp.dir.createDirPath(testing.io, "cache/p/pkg-1/src");
    try tmp.dir.createDirPath(testing.io, "lib/src");
    try tmp.dir.createDirPath(testing.io, "shared");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "proj/build.zig.zon", .data = ".{ .name = .proj, .dependencies = .{ .pkg = .{ .url = \"u\", .hash = \"pkg-1\" }, .lib = .{ .path = \"../lib\" } } }" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "proj/build.zig", .data =
        \\pub fn build(b: *std.Build) void {
        \\    _ = b.addModule("shared", .{ .root_source_file = b.path("../shared/s.zig") });
        \\    const tc = b.addTranslateC(.{ .root_source_file = b.path("c/api.h") });
        \\    tc.defineCMacro("FOO", "1");
        \\}
    });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "proj/c/api.h", .data = "int api_call(int x);\n" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "cache/p/pkg-1/src/root.zig", .data = "pub fn fromPkg() void {}\n" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "lib/src/root.zig", .data = "pub fn fromLib() void {}\n" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "shared/s.zig", .data = "pub fn fromShared() void {}\n" });

    const proj = try std.fs.path.join(a, &.{ base, "proj" });
    defer a.free(proj);
    const gc = try std.fs.path.join(a, &.{ base, "cache" });
    defer a.free(gc);
    const tcache = try std.fs.path.join(a, &.{ base, "tcache" });
    defer a.free(tcache);
    const pl = try Planner.create(a, .{ .project_root = proj, .global_cache = gc, .translate_cache = tcache });
    defer pl.destroy();
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var roots: std.ArrayListUnmanaged(symbol_index.Root) = .empty;
    defer roots.deinit(a);
    try pl.plan(a, arena.allocator(), testing.io, &roots);

    var labels: [4]bool = .{ false, false, false, false };
    for (roots.items) |r| {
        if (std.mem.eql(u8, r.label, "dep/pkg")) labels[0] = r.origin == .dependency and std.mem.endsWith(u8, r.dir, "cache/p/pkg-1");
        if (std.mem.eql(u8, r.label, "dep/lib")) labels[1] = std.mem.endsWith(u8, r.dir, "/lib");
        if (std.mem.eql(u8, r.label, "module/shared")) labels[2] = std.mem.endsWith(u8, r.dir, "/shared");
        if (std.mem.eql(u8, r.label, "c/api.h")) labels[3] = r.origin == .c and r.only_file != null; // needs zig on PATH
    }
    try testing.expect(labels[0] and labels[1] and labels[2]);
    if (!labels[3]) return error.SkipZigTest; // no zig to translate with
}
