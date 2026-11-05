//! The module graph for a comptime debug session. A project's own build knows its modules, their
//! imports (`@import("mylib")`), dependencies and flags; the IDE asks it instead of guessing:
//! `ZCT_DRYRUN=1 zigct build --verbose` makes the build print the exact `zig build-exe ...`
//! command of every artifact without compiling any (the compile steps of a dry run wait until the
//! build ends). `parse` reads those lines, `plan` builds the arguments that evaluate one file's
//! block inside the module that file belongs to. No process here (`debugger.zig` runs it).
//!
//!     const compiles = try parse(arena, build_stderr);
//!     const p = (try plan(arena, compiles, project_root, target_abs, rel_in_module_fn_path)) orelse return;
//!     p.args;      // for zigct's `zigArgs`
//!     p.files;     // two small files to write first (in the modules' folders); delete them afterwards
//!
//! **How the block is reached.** The artifact's root module keeps all its settings but its root
//! source is replaced by a two-line file that imports a new module, `zct_target`; that module has
//! the settings and dependencies of the module that holds the block, and its root source imports
//! the block's file (and takes the address of the function the block is in). So `@import("name")`
//! of the project's dependencies, target, optimize mode and defines are the real ones.

const std = @import("std");
const comptime_scan = @import("comptime_scan.zig");

pub const Module = struct {
    name: []const u8,
    /// The root source file as the build wrote it (relative to the project folder or absolute).
    root: []const u8,
    /// The per-module arguments before its `-M` (`--dep x`, `-Odebug`, ...).
    group: []const []const u8,
};

pub const Compile = struct {
    /// Everything after the command (`build-exe`, ...).
    args: []const []const u8,
    modules: []const Module,
};

/// `text` without terminal colour codes (`ESC [ ... letter`): the build colours its messages when
/// it thinks it talks to a terminal.
pub fn stripAnsi(a: std.mem.Allocator, text: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    var i: usize = 0;
    while (i < text.len) {
        if (text[i] == 0x1b and i + 1 < text.len and text[i + 1] == '[') {
            i += 2;
            while (i < text.len and !std.ascii.isAlphabetic(text[i])) i += 1;
            i += 1;
            continue;
        }
        try out.append(a, text[i]);
        i += 1;
    }
    return out.toOwnedSlice(a);
}

/// The compile commands in the output of `zig build --verbose` (the build script's own runner and
/// non-compile commands are left out).
pub fn parse(a: std.mem.Allocator, raw_text: []const u8) ![]Compile {
    const text = try stripAnsi(a, raw_text);
    var out: std.ArrayListUnmanaged(Compile) = .empty;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        var line = std.mem.trim(u8, raw, " \r\t");
        const marker = "(verbose): ";
        if (std.mem.indexOf(u8, line, marker)) |at| line = line[at + marker.len ..];
        var toks: std.ArrayListUnmanaged([]const u8) = .empty;
        var it = std.mem.tokenizeScalar(u8, line, ' ');
        while (it.next()) |t| try toks.append(a, t);
        if (toks.items.len < 3) continue;
        const cmd = toks.items[1];
        const ok = std.mem.eql(u8, cmd, "build-exe") or std.mem.eql(u8, cmd, "build-lib") or std.mem.eql(u8, cmd, "build-obj") or std.mem.eql(u8, cmd, "test") or std.mem.eql(u8, cmd, "test-obj");
        if (!ok) continue;
        const args = toks.items[2..];
        var mods: std.ArrayListUnmanaged(Module) = .empty;
        var group_start: usize = 0;
        var is_runner = false;
        var i: usize = 0;
        while (i < args.len) : (i += 1) {
            const t = args[i];
            if (std.mem.indexOf(u8, t, "/compiler/") != null) is_runner = true;
            if (std.mem.startsWith(u8, t, "-M")) {
                const body = t[2..];
                const eq = std.mem.indexOfScalar(u8, body, '=') orelse continue;
                try mods.append(a, .{ .name = body[0..eq], .root = body[eq + 1 ..], .group = args[group_start..i] });
                group_start = i + 1;
            }
        }
        if (is_runner or mods.items.len == 0) continue;
        try out.append(a, .{ .args = args, .modules = mods.items });
    }
    return out.toOwnedSlice(a);
}

pub const File = struct {
    /// Absolute.
    path: []const u8,
    content: []const u8,
};

pub const Plan = struct {
    /// Arguments for `zig build-obj` (no output, cache, library-directory or listen flags).
    args: []const []const u8,
    files: []const File,
    /// The module that holds the block.
    module: []const u8,
};

pub const root_wrapper = ".zigct-root.zig";
pub const target_wrapper = ".zigct-target.zig";

fn absOf(a: std.mem.Allocator, project_root: []const u8, p: []const u8) ![]u8 {
    if (std.fs.path.isAbsolute(p)) return a.dupe(u8, p);
    return std.fs.path.resolve(a, &.{ project_root, p });
}

fn inside(dir: []const u8, file: []const u8) bool {
    return file.len > dir.len and std.mem.startsWith(u8, file, dir) and file[dir.len] == '/';
}

/// Dropped from the artifact's arguments: ours replace them, or they are about producing output.
fn dropped(tok: []const u8) enum { no, one, two } {
    const with_value = [_][]const u8{ "--cache-dir", "--global-cache-dir", "--build-root", "--zig-lib-dir", "--name", "-femit-bin", "-femit-h", "-femit-docs", "-femit-asm", "-femit-llvm-ir", "-femit-llvm-bc", "-femit-implib" };
    for (with_value) |w| if (std.mem.eql(u8, tok, w)) return .two;
    if (std.mem.startsWith(u8, tok, "--listen") or std.mem.startsWith(u8, tok, "-femit-") or std.mem.startsWith(u8, tok, "-fno-emit-") or std.mem.eql(u8, tok, "--enable-cache")) return .one;
    return .no;
}

/// A block inside a `test` is evaluated by analyzing like `zig test`, which only takes the tests of
/// the artifact's own (root) module: the file must belong to it.
pub const TestError = error{TestNotInRootModule};

/// Arguments that evaluate the block of `target_abs` (in the module whose folder holds it), or null
/// when no module of any artifact holds the file. `fn_path` is `comptime_scan.Block.fn_path`.
/// With `test_mode` the file must be in the root module of an artifact (`error.TestNotInRootModule`
/// otherwise) and no extra module is made: the wrapper root imports the file.
pub fn plan(a: std.mem.Allocator, compiles: []const Compile, project_root: []const u8, target_abs: []const u8, fn_path: []const u8, test_mode: bool) !?Plan {
    var best: ?struct { c: Compile, m: Module, dir: []const u8, rank: usize } = null;
    var held_elsewhere = false;
    for (compiles) |c| {
        for (c.modules, 0..) |m, idx| {
            const root_abs = try absOf(a, project_root, m.root);
            const dir = std.fs.path.dirname(root_abs) orelse continue;
            if (!inside(dir, target_abs)) continue;
            if (test_mode and idx != 0) {
                held_elsewhere = true;
                continue;
            }
            // The longest folder wins; among equals the artifact's root module, then the first seen.
            const rank = dir.len * 4 + (if (idx == 0) @as(usize, 1) else 0);
            if (best == null or rank > best.?.rank) best = .{ .c = c, .m = m, .dir = dir, .rank = rank };
        }
    }
    const found = best orelse return if (test_mode and held_elsewhere) error.TestNotInRootModule else null;
    const c = found.c;
    const root_mod = c.modules[0];
    const root_dir = std.fs.path.dirname(try absOf(a, project_root, root_mod.root)).?;

    if (test_mode) {
        // One file: the root imports the block's file (same module, so its tests are analyzed).
        const rel_t = target_abs[found.dir.len + 1 ..];
        const src = try comptime_scan.rootSource(a, rel_t, fn_path);
        const files1 = try a.alloc(File, 1);
        files1[0] = .{ .path = try std.fs.path.join(a, &.{ root_dir, root_wrapper }), .content = src };
        var out1: std.ArrayListUnmanaged([]const u8) = .empty;
        var first = true;
        var k: usize = 0;
        while (k < c.args.len) : (k += 1) {
            const t = c.args[k];
            switch (dropped(t)) {
                .two => {
                    k += 1;
                    continue;
                },
                .one => continue,
                .no => {},
            }
            if (std.mem.startsWith(u8, t, "-M") and first) {
                first = false;
                try out1.append(a, try std.fmt.allocPrint(a, "-M{s}={s}", .{ root_mod.name, files1[0].path }));
                continue;
            }
            try out1.append(a, t);
        }
        return .{ .args = try out1.toOwnedSlice(a), .files = files1, .module = root_mod.name };
    }

    // The two files.
    const rel = target_abs[found.dir.len + 1 ..];
    const target_src = try comptime_scan.rootSource(a, rel, fn_path);
    const root_src = try std.fmt.allocPrint(a, "// Made by the zigui IDE for \"Debug comptime\"; deleted when the session ends.\nconst t = @import(\"zct_target\");\ncomptime {{\n    _ = t;\n}}\n", .{});
    const files = try a.alloc(File, 2);
    files[0] = .{ .path = try std.fs.path.join(a, &.{ found.dir, target_wrapper }), .content = target_src };
    files[1] = .{ .path = try std.fs.path.join(a, &.{ root_dir, root_wrapper }), .content = root_src };

    // The arguments: the artifact's own, minus output/cache flags, with the root module's source
    // replaced and `zct_target` added.
    var out: std.ArrayListUnmanaged([]const u8) = .empty;
    var i: usize = 0;
    var first_module = true;
    while (i < c.args.len) : (i += 1) {
        const t = c.args[i];
        switch (dropped(t)) {
            .two => {
                i += 1;
                continue;
            },
            .one => continue,
            .no => {},
        }
        if (std.mem.startsWith(u8, t, "-M") and first_module) {
            first_module = false;
            // Its group (already copied) gets `--dep zct_target` just before it.
            try out.append(a, "--dep");
            try out.append(a, "zct_target");
            try out.append(a, try std.fmt.allocPrint(a, "-M{s}={s}", .{ root_mod.name, files[1].path }));
            continue;
        }
        try out.append(a, t);
    }
    // The module holding the block: its settings and imports, a new name, the wrapper as root.
    for (found.m.group) |t| {
        switch (dropped(t)) {
            .no => try out.append(a, t),
            else => {},
        }
    }
    try out.append(a, try std.fmt.allocPrint(a, "-Mzct_target={s}", .{files[0].path}));
    return .{ .args = try out.toOwnedSlice(a), .files = files, .module = found.m.name };
}

const testing = std.testing;

const sample =
    "info(verbose): /x/zig build-exe --cache-dir .zig-cache --global-cache-dir /g --build-root . --zig-lib-dir /lib --name configurer -fsingle-threaded --dep @build -Mroot=/lib/compiler/configurer.zig -Mmylib=mylib/build.zig --dep mylib -M@build=build.zig --listen=-\n" ++
    "info(verbose): /x/zig build-exe -Odebug --dep mylib -Mroot=src/main.zig -Mmylib=mylib/src/mylib.zig --cache-dir .zig-cache --global-cache-dir /g --build-root . --name depproj --zig-lib-dir /lib/ --listen=-\n" ++
    "thread 1 panic: attempt to use null value\n";

test "the artifact's modules are read; the build script's own runner is left out" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const cs = try parse(arena.allocator(), sample);
    try testing.expectEqual(@as(usize, 1), cs.len);
    try testing.expectEqual(@as(usize, 2), cs[0].modules.len);
    try testing.expectEqualStrings("root", cs[0].modules[0].name);
    try testing.expectEqualStrings("src/main.zig", cs[0].modules[0].root);
    try testing.expectEqualStrings("mylib/src/mylib.zig", cs[0].modules[1].root);
    // `--dep mylib` and `-Odebug` belong to the root module.
    try testing.expectEqual(@as(usize, 3), cs[0].modules[0].group.len);
}

test "a block in the root module: the root is replaced by a wrapper and zct_target gets the module's settings" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cs = try parse(a, sample);
    const p = (try plan(a, cs, "/proj", "/proj/src/main.zig", "", false)).?;
    try testing.expectEqualStrings("root", p.module);
    try testing.expectEqualStrings("/proj/src/.zigct-target.zig", p.files[0].path);
    try testing.expectEqualStrings("/proj/src/.zigct-root.zig", p.files[1].path);
    try testing.expect(std.mem.indexOf(u8, p.files[0].content, "@import(\"main.zig\")") != null);
    var joined: std.ArrayListUnmanaged(u8) = .empty;
    for (p.args) |t| {
        try joined.appendSlice(a, t);
        try joined.append(a, ' ');
    }
    const s = joined.items;
    try testing.expect(std.mem.indexOf(u8, s, "--dep zct_target -Mroot=/proj/src/.zigct-root.zig") != null);
    try testing.expect(std.mem.indexOf(u8, s, "-Mmylib=mylib/src/mylib.zig") != null);
    try testing.expect(std.mem.indexOf(u8, s, "-Odebug --dep mylib -Mzct_target=/proj/src/.zigct-target.zig") != null);
    // Output and cache flags are gone.
    try testing.expect(std.mem.indexOf(u8, s, "--listen") == null);
    try testing.expect(std.mem.indexOf(u8, s, "--cache-dir") == null);
    try testing.expect(std.mem.indexOf(u8, s, "--name") == null);
}

test "a block in a dependency's folder is reached through that module" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cs = try parse(a, sample);
    const p = (try plan(a, cs, "/proj", "/proj/mylib/src/helpers.zig", "tools.run", false)).?;
    try testing.expectEqualStrings("mylib", p.module);
    try testing.expectEqualStrings("/proj/mylib/src/.zigct-target.zig", p.files[0].path);
    try testing.expect(std.mem.indexOf(u8, p.files[0].content, "_ = &m.tools.run;") != null);
    try testing.expectEqualStrings("/proj/src/.zigct-root.zig", p.files[1].path);
    try testing.expect((try plan(a, cs, "/proj", "/elsewhere/x.zig", "", false)) == null);
}

test "test mode: the root wrapper imports the file directly; a file of another module is refused" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cs = try parse(a, sample);
    const p = (try plan(a, cs, "/proj", "/proj/src/util.zig", "", true)).?;
    try testing.expectEqual(@as(usize, 1), p.files.len);
    try testing.expectEqualStrings("/proj/src/.zigct-root.zig", p.files[0].path);
    try testing.expect(std.mem.indexOf(u8, p.files[0].content, "@import(\"util.zig\")") != null);
    for (p.args) |t| try testing.expect(!std.mem.eql(u8, t, "zct_target"));
    try testing.expectError(error.TestNotInRootModule, plan(a, cs, "/proj", "/proj/mylib/src/helpers.zig", "", true));
}

test "colour codes in the build's output do not hide the compile commands" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const coloured = "\x1b[32m\x1b[1minfo\x1b[0m\x1b[2m\x1b[1m(verbose): \x1b[0m/home/u/.cache/zigct/bin/zigct build-exe -Odebug --dep Lib -Mroot=src/main.zig -MLib=src/root.zig --cache-dir c --name N --listen=-\n";
    const cs = try parse(a, coloured);
    try testing.expectEqual(@as(usize, 1), cs.len);
    try testing.expectEqualStrings("Lib", cs[0].modules[1].name);
    try testing.expectEqualStrings("src/root.zig", cs[0].modules[1].root);
}
