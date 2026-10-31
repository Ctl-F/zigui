//! The IDE's settings: a few values in ZON files, read at startup and again
//! whenever the file is saved from the IDE.
//!
//! Two files are layered, the second overriding the first:
//!   * `$XDG_CONFIG_HOME/zigui-ide/settings.zon` (or `~/.config/zigui-ide/...`): yours, for every project
//!   * `<project>/.zigide/settings.zon`: for this project (shared if you commit it)
//!
//!     .{
//!         .ui_font_size = 14,
//!         .editor_font_size = 13,
//!         .tab_width = 4,
//!     }
//!
//! Unknown keys and values of the wrong type are ignored (and counted in
//! `problems`), so a typo never stops the IDE from starting. The same goes for
//! the keymaps (`keybindings.keymap` next to each settings file).

const std = @import("std");
const zon = @import("../uidoc/zon.zig");
const Project = @import("project.zig").Project;

pub const project_settings = ".zigide/settings.zon";
pub const project_keymap = ".zigide/keybindings.keymap";

pub const Settings = struct {
    /// Em size of the interface text; 0 keeps the theme's.
    ui_font_size: f32 = 0,
    /// Em size of source text; 0 keeps the theme's.
    editor_font_size: f32 = 0,
    tab_width: u32 = 4,
    line_numbers: bool = true,
    folding: bool = true,
    /// The language server command for Zig ("" means `ZIGUI_ZLS` or `zls`). Read at startup.
    language_server: []const u8 = "",
    /// The terminal's shell ("" means `$SHELL`). Read at startup.
    shell: []const u8 = "",
    /// Reopen the files and panel layout of the last session.
    restore_session: bool = true,
    /// How many keys of the files were not understood.
    problems: u32 = 0,

    /// Apply the keys present in `text` over the current values. Strings are
    /// copied into `arena`.
    pub fn apply(self: *Settings, arena: std.mem.Allocator, text: []const u8) void {
        const v = zon.parse(arena, text, null) catch {
            self.problems += 1;
            return;
        };
        for (v.fields() orelse {
            self.problems += 1;
            return;
        }) |f| {
            if (!self.set(arena, f.name, f.value)) self.problems += 1;
        }
    }

    fn num(v: zon.Value) ?f32 {
        return switch (v) {
            .int => |i| @floatFromInt(i),
            .float => |x| @floatCast(x),
            else => null,
        };
    }

    fn set(self: *Settings, arena: std.mem.Allocator, name: []const u8, v: zon.Value) bool {
        const eq = std.mem.eql;
        if (eq(u8, name, "ui_font_size")) {
            self.ui_font_size = num(v) orelse return false;
        } else if (eq(u8, name, "editor_font_size")) {
            self.editor_font_size = num(v) orelse return false;
        } else if (eq(u8, name, "tab_width")) {
            const n = num(v) orelse return false;
            if (n < 1 or n > 16) return false;
            self.tab_width = @intFromFloat(n);
        } else if (eq(u8, name, "line_numbers")) {
            if (v != .bool) return false;
            self.line_numbers = v.bool;
        } else if (eq(u8, name, "folding")) {
            if (v != .bool) return false;
            self.folding = v.bool;
        } else if (eq(u8, name, "restore_session")) {
            if (v != .bool) return false;
            self.restore_session = v.bool;
        } else if (eq(u8, name, "language_server")) {
            if (v != .string) return false;
            self.language_server = arena.dupe(u8, v.string) catch return false;
        } else if (eq(u8, name, "shell")) {
            if (v != .string) return false;
            self.shell = arena.dupe(u8, v.string) catch return false;
        } else return false;
        return true;
    }
};

/// What a new settings file starts with.
pub const template =
    \\// zigui IDE settings. Save this file and the IDE applies it.
    \\// Remove a line to go back to its default. This file overrides
    \\// ~/.config/zigui-ide/settings.zon (yours, for every project).
    \\.{
    \\    // Text sizes in logical pixels (0: the theme's size).
    \\    .ui_font_size = 0,
    \\    .editor_font_size = 0,
    \\    // Source editors.
    \\    .tab_width = 4,
    \\    .line_numbers = true,
    \\    .folding = true,
    \\    // Reopen the last session's files and layout at startup.
    \\    .restore_session = true,
    \\    // Read at startup: the Zig language server ("" = $ZIGUI_ZLS or zls) and the terminal's shell ("" = $SHELL).
    \\    .language_server = "",
    \\    .shell = "",
    \\}
    \\
;

/// The keymap file template: how to write bindings, and the IDE's defaults as comments.
pub fn keymapTemplate(a: std.mem.Allocator, defaults: []const [2][]const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    try out.appendSlice(a,
        \\# zigui IDE key bindings. Save this file and the IDE applies it.
        \\# One binding per line: `chord = command`; `ctrl+k ctrl+c = command` is a sequence;
        \\# `ctrl+q = none` removes a binding; `#` starts a comment. Lines here override the defaults
        \\# below (commented out), and ~/.config/zigui-ide/keybindings.keymap is read first.
        \\# Removing a line takes effect after a restart.
        \\
        \\
    );
    for (defaults) |d| try out.print(a, "# {s} = {s}\n", .{ d[0], d[1] });
    return out.items;
}

pub const Loaded = struct {
    arena: std.heap.ArenaAllocator,
    settings: Settings,
    /// Keymap text to apply, global first then the project's (empty if neither exists).
    keymap: []const u8,

    pub fn deinit(self: *Loaded) void {
        self.arena.deinit();
    }
};

/// The user's config directory for the IDE, from the environment (null if unknown).
pub fn globalDir(a: std.mem.Allocator, environ: ?*const std.process.Environ.Map) !?[]u8 {
    const env = environ orelse return null;
    if (env.get("XDG_CONFIG_HOME")) |x| if (x.len > 0) return try std.fs.path.join(a, &.{ x, "zigui-ide" });
    if (env.get("HOME")) |h| if (h.len > 0) return try std.fs.path.join(a, &.{ h, ".config", "zigui-ide" });
    return null;
}

fn readAbs(gpa: std.mem.Allocator, io: std.Io, path: []const u8) ?[]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(256 * 1024)) catch null;
}

/// Read the settings and keymaps (global, then the project's).
pub fn load(gpa: std.mem.Allocator, io: std.Io, project: *const Project, environ: ?*const std.process.Environ.Map) !Loaded {
    var out: Loaded = .{ .arena = std.heap.ArenaAllocator.init(gpa), .settings = .{}, .keymap = "" };
    errdefer out.arena.deinit();
    const a = out.arena.allocator();
    var keymap: std.ArrayListUnmanaged(u8) = .empty;
    if (try globalDir(a, environ)) |dir| {
        const sp = try std.fs.path.join(a, &.{ dir, "settings.zon" });
        if (readAbs(gpa, io, sp)) |text| {
            defer gpa.free(text);
            out.settings.apply(a, text);
        }
        const kp = try std.fs.path.join(a, &.{ dir, "keybindings.keymap" });
        if (readAbs(gpa, io, kp)) |text| {
            defer gpa.free(text);
            try keymap.appendSlice(a, text);
            try keymap.append(a, '\n');
        }
    }
    if (project.readFile(gpa, project_settings, 256 * 1024)) |text| {
        defer gpa.free(text);
        out.settings.apply(a, text);
    } else |_| {}
    if (project.readFile(gpa, project_keymap, 256 * 1024)) |text| {
        defer gpa.free(text);
        try keymap.appendSlice(a, text);
    } else |_| {}
    out.keymap = keymap.items;
    return out;
}

// ---- tests -----------------------------------------------------------------

const testing = std.testing;

test "settings apply over defaults; bad keys and values are counted, not fatal" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var s: Settings = .{};
    s.apply(arena.allocator(), ".{ .tab_width = 2, .editor_font_size = 15.5, .folding = false, .shell = \"/bin/zsh\", .nonsense = 1, .line_numbers = \"yes\", .tab_width2 = 3 }");
    try testing.expectEqual(@as(u32, 2), s.tab_width);
    try testing.expectEqual(@as(f32, 15.5), s.editor_font_size);
    try testing.expect(!s.folding and s.line_numbers);
    try testing.expectEqualStrings("/bin/zsh", s.shell);
    try testing.expectEqual(@as(u32, 3), s.problems);
    // A second file overrides only what it names.
    s.apply(arena.allocator(), ".{ .tab_width = 8 }");
    try testing.expectEqual(@as(u32, 8), s.tab_width);
    try testing.expectEqual(@as(f32, 15.5), s.editor_font_size);
    var bad: Settings = .{};
    bad.apply(arena.allocator(), "this is not zon");
    try testing.expectEqual(@as(u32, 1), bad.problems);
    try testing.expectEqual(@as(u32, 4), bad.tab_width);
    // Out-of-range tab widths are rejected.
    var t: Settings = .{};
    t.apply(arena.allocator(), ".{ .tab_width = 0 }");
    try testing.expectEqual(@as(u32, 4), t.tab_width);
    try testing.expectEqual(@as(u32, 1), t.problems);
}

test "the template parses cleanly with no problems" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var s: Settings = .{};
    s.apply(arena.allocator(), template);
    try testing.expectEqual(@as(u32, 0), s.problems);
    try testing.expectEqual(@as(u32, 4), s.tab_width);
}

test "global and project files layer, with keymaps in the same order" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const io = testing.io;
    try tmp.dir.createDirPath(io, "home/zigui-ide");
    try tmp.dir.createDirPath(io, "proj/.zigide");
    try tmp.dir.writeFile(io, .{ .sub_path = "home/zigui-ide/settings.zon", .data = ".{ .tab_width = 2, .editor_font_size = 12 }" });
    try tmp.dir.writeFile(io, .{ .sub_path = "home/zigui-ide/keybindings.keymap", .data = "ctrl+q = file.quit\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "proj/.zigide/settings.zon", .data = ".{ .tab_width = 3 }" });
    try tmp.dir.writeFile(io, .{ .sub_path = "proj/.zigide/keybindings.keymap", .data = "ctrl+q = none\n" });
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPathFile(io, "home", &buf);
    var env = std.process.Environ.Map.init(testing.allocator);
    defer env.deinit();
    try env.put("XDG_CONFIG_HOME", buf[0..n]);
    const dir = try tmp.dir.openDir(io, "proj", .{ .iterate = true });
    var p = try Project.fromDir(testing.allocator, io, dir);
    defer p.close();
    var loaded = try load(testing.allocator, io, &p, &env);
    defer loaded.deinit();
    try testing.expectEqual(@as(u32, 3), loaded.settings.tab_width); // the project wins
    try testing.expectEqual(@as(f32, 12), loaded.settings.editor_font_size); // the user's stays
    try testing.expectEqualStrings("ctrl+q = file.quit\n\nctrl+q = none\n", loaded.keymap);
    // Nothing configured: defaults.
    var env2 = std.process.Environ.Map.init(testing.allocator);
    defer env2.deinit();
    const dir2 = try tmp.dir.openDir(io, "home", .{ .iterate = true });
    var p2 = try Project.fromDir(testing.allocator, io, dir2);
    defer p2.close();
    var none = try load(testing.allocator, io, &p2, &env2);
    defer none.deinit();
    try testing.expectEqual(@as(u32, 4), none.settings.tab_width);
    try testing.expectEqualStrings("", none.keymap);
}

test "the keymap template lists defaults as comments and loads as no bindings" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const t = try keymapTemplate(arena.allocator(), &.{ .{ "ctrl+s", "file.save" }, .{ "f5", "ide.run" } });
    try testing.expect(std.mem.indexOf(u8, t, "# ctrl+s = file.save\n# f5 = ide.run\n") != null);
}
