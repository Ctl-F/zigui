//! The module explorer: a tree like the Files panel, but of the code the project
//! uses from outside itself: the Zig standard library, the packages its build
//! depends on, modules from other folders, and translated C headers. Folders
//! load when opened; activating a file calls `on_open` (the files open read-only).
//!
//!     const mp = try ModulesPanel.create(&ui, parent, io, std_dir, .{ .on_open = OpenHook.bind(&app, App.openAt) });
//!     defer mp.destroy();
//!     try mp.setRoots(quick.modRoots());     // whenever the index found its roots (again)
//!
//! IDE-level code: it builds on `TreeView` and the roots `SymbolIndex.roots()` reports.

const std = @import("std");
const Handle = @import("../core/handle.zig").Handle;
const Ui = @import("../core/ui.zig").Ui;
const event = @import("../core/event.zig");
const Style = @import("../core/style.zig").Style;
const tree_view = @import("../widgets/tree_view.zig");
const TreeView = tree_view.TreeView;
const output_panel = @import("output_panel.zig");
const symbol_index = @import("symbol_index.zig");

pub const OpenHook = output_panel.OpenHook;

pub const Options = struct {
    style: Style = .{},
    on_open: ?OpenHook = null,
};

const Kind = enum(u8) { group, dir_unloaded, dir_loaded, file, placeholder };

const Entry = struct { name: []u8, is_dir: bool };

fn lessEntry(_: void, a: Entry, b: Entry) bool {
    if (a.is_dir != b.is_dir) return a.is_dir;
    var i: usize = 0;
    while (i < a.name.len and i < b.name.len) : (i += 1) {
        const ca = std.ascii.toLower(a.name[i]);
        const cb = std.ascii.toLower(b.name[i]);
        if (ca != cb) return ca < cb;
    }
    return a.name.len < b.name.len;
}

pub const ModulesPanel = struct {
    gpa: std.mem.Allocator,
    ui: *Ui,
    io: std.Io,
    tree: *TreeView,
    on_open: ?OpenHook,
    std_dir: ?[]u8,
    /// Absolute path per item (folders and files; groups have none).
    paths: std.AutoHashMapUnmanaged(u32, []u8) = .empty,

    pub fn create(ui: *Ui, parent: Handle, io: std.Io, std_dir: ?[]const u8, opts: Options) !*ModulesPanel {
        const self = try ui.gpa.create(ModulesPanel);
        errdefer ui.gpa.destroy(self);
        var style = opts.style;
        if (std.meta.eql(style, Style{})) style.grow = 1;
        const tv = try ui.add(TreeView, parent, .{
            .style = style,
            .label = "Modules",
            .activate_toggles = true,
            .on_toggle = .bind(self, onToggle),
            .on_activate = .bind(self, onActivate),
        });
        const sd: ?[]u8 = if (std_dir) |d| try ui.gpa.dupe(u8, d) else null;
        self.* = .{ .gpa = ui.gpa, .ui = ui, .io = io, .tree = tv, .on_open = opts.on_open, .std_dir = sd };
        try self.setRoots(&.{});
        return self;
    }

    pub fn destroy(self: *ModulesPanel) void {
        self.freePaths();
        self.paths.deinit(self.gpa);
        if (self.std_dir) |d| self.gpa.free(d);
        self.gpa.destroy(self);
    }

    fn freePaths(self: *ModulesPanel) void {
        var it = self.paths.valueIterator();
        while (it.next()) |v| self.gpa.free(v.*);
        self.paths.clearRetainingCapacity();
    }

    fn kindOf(self: *const ModulesPanel, id: u32) Kind {
        return @enumFromInt(self.tree.userData(id));
    }

    fn remember(self: *ModulesPanel, id: u32, path: []const u8) !void {
        const copy = try self.gpa.dupe(u8, path);
        errdefer self.gpa.free(copy);
        try self.paths.put(self.gpa, id, copy);
    }

    fn addFolder(self: *ModulesPanel, parent: u32, label: []const u8, path: []const u8) !u32 {
        const id = try self.tree.addItem(parent, label);
        try self.remember(id, path);
        self.tree.setUserData(id, @intFromEnum(Kind.dir_unloaded));
        const ph = try self.tree.addItem(id, "");
        self.tree.setUserData(ph, @intFromEnum(Kind.placeholder));
        return id;
    }

    fn addGroup(self: *ModulesPanel, label: []const u8) !u32 {
        const id = try self.tree.addItem(tree_view.no_item, label);
        self.tree.setUserData(id, @intFromEnum(Kind.group));
        return id;
    }

    /// Rebuild the tree: the standard library first, then groups for dependencies,
    /// modules from other folders and translated C. (Everything collapses.)
    pub fn setRoots(self: *ModulesPanel, roots: []const symbol_index.Root) !void {
        self.tree.clear();
        self.freePaths();
        if (self.std_dir) |d| _ = try self.addFolder(tree_view.no_item, "Standard Library", d);
        const groups = [_]struct { origin: symbol_index.Origin, prefix: []const u8, title: []const u8 }{
            .{ .origin = .dependency, .prefix = "dep/", .title = "Dependencies" },
            .{ .origin = .dependency, .prefix = "module/", .title = "Modules" },
            .{ .origin = .c, .prefix = "c/", .title = "C modules (translated)" },
        };
        for (groups) |g| {
            var group: ?u32 = null;
            var count: usize = 0;
            for (roots) |r| {
                if (r.origin != g.origin or !std.mem.startsWith(u8, r.label, g.prefix)) continue;
                count += 1;
                const gid = group orelse blk: {
                    const id = try self.addGroup(g.title);
                    group = id;
                    break :blk id;
                };
                const label = r.label[g.prefix.len..];
                if (r.only_file) |f| {
                    const path = try std.fs.path.join(self.gpa, &.{ r.dir, f });
                    defer self.gpa.free(path);
                    const id = try self.tree.addItem(gid, label);
                    try self.remember(id, path);
                    self.tree.setUserData(id, @intFromEnum(Kind.file));
                } else {
                    _ = try self.addFolder(gid, label, r.dir);
                }
            }
            if (group) |gid| self.tree.setExpanded(gid, true);
        }
    }

    /// Fill folder `dir` with its entries.
    fn load(self: *ModulesPanel, dir: u32) !void {
        const path = self.paths.get(dir) orelse return;
        while (self.tree.childCount(dir) > 0) self.tree.removeItem(self.tree.childAt(dir, 0));
        self.tree.setUserData(dir, @intFromEnum(Kind.dir_loaded));
        var d = std.Io.Dir.cwd().openDir(self.io, path, .{ .iterate = true }) catch return;
        defer d.close(self.io);
        var list: std.ArrayListUnmanaged(Entry) = .empty;
        defer {
            for (list.items) |e| self.gpa.free(e.name);
            list.deinit(self.gpa);
        }
        var it = d.iterate();
        while (it.next(self.io) catch null) |e| {
            if (e.name.len == 0 or e.name[0] == '.') continue;
            const is_dir = e.kind == .directory;
            if (!is_dir and e.kind != .file and e.kind != .sym_link) continue;
            const name = try self.gpa.dupe(u8, e.name);
            list.append(self.gpa, .{ .name = name, .is_dir = is_dir }) catch {
                self.gpa.free(name);
                break;
            };
        }
        std.mem.sort(Entry, list.items, {}, lessEntry);
        for (list.items) |e| {
            const child = try std.fs.path.join(self.gpa, &.{ path, e.name });
            defer self.gpa.free(child);
            if (e.is_dir) {
                _ = try self.addFolder(dir, e.name, child);
            } else {
                const id = try self.tree.addItem(dir, e.name);
                try self.remember(id, child);
                self.tree.setUserData(id, @intFromEnum(Kind.file));
            }
        }
    }

    fn onToggle(self: *ModulesPanel, _: *event.Event) void {
        var it = self.paths.keyIterator();
        var todo: [8]u32 = undefined;
        var n: usize = 0;
        while (it.next()) |k| {
            if (n == todo.len) break;
            if (self.tree.exists(k.*) and self.kindOf(k.*) == .dir_unloaded and self.tree.isExpanded(k.*)) {
                todo[n] = k.*;
                n += 1;
            }
        }
        for (todo[0..n]) |id| self.load(id) catch {};
    }

    fn onActivate(self: *ModulesPanel, _: *event.Event) void {
        const id = self.tree.out.activated_item;
        if (id == tree_view.no_item or !self.tree.exists(id) or self.kindOf(id) != .file) return;
        const path = self.paths.get(id) orelse return;
        if (self.on_open) |h| h.call(h.ctx, path, 1, 1);
    }
};

// ---- tests -----------------------------------------------------------------

const testing = std.testing;
const Rig = @import("../core/test_rig.zig").Rig;

const Opened = struct {
    buf: [std.fs.max_path_bytes]u8 = undefined,
    len: usize = 0,
    fn open(self: *Opened, path: []const u8, _: u32, _: u32) void {
        @memcpy(self.buf[0..path.len], path);
        self.len = path.len;
    }
};

test "the tree has the library and groups of modules; folders load when opened; a file opens" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDirPath(testing.io, "std/fs");
    try tmp.dir.createDirPath(testing.io, "pkg/src");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "std/std.zig", .data = "pub const x = 1;\n" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "std/fs/path.zig", .data = "pub fn a() void {}\n" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "pkg/src/root.zig", .data = "pub fn b() void {}\n" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "pkg/.hidden", .data = "x" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "api-123.zig", .data = "pub fn c() void {}\n" });
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(testing.io, &buf);
    const base = try testing.allocator.dupe(u8, buf[0..n]);
    defer testing.allocator.free(base);
    const std_dir = try std.fs.path.join(testing.allocator, &.{ base, "std" });
    defer testing.allocator.free(std_dir);
    const pkg_dir = try std.fs.path.join(testing.allocator, &.{ base, "pkg" });
    defer testing.allocator.free(pkg_dir);

    const r = try Rig.init();
    defer r.deinit();
    var opened: Opened = .{};
    const mp = try ModulesPanel.create(&r.ui, r.ui.tree.root, testing.io, std_dir, .{ .on_open = .bind(&opened, Opened.open) });
    defer mp.destroy();
    try mp.setRoots(&.{
        .{ .label = "dep/zigimg", .dir = pkg_dir, .origin = .dependency },
        .{ .label = "c/api.h", .dir = base, .origin = .c, .only_file = "api-123.zig" },
    });
    try r.frame();
    const tv = mp.tree;
    // Top level: the library, then the "Dependencies" and "C modules" groups.
    try testing.expectEqual(@as(usize, 3), tv.childCount(tree_view.no_item));
    try testing.expectEqualStrings("Standard Library", tv.itemText(tv.childAt(tree_view.no_item, 0)));
    try testing.expectEqualStrings("Dependencies", tv.itemText(tv.childAt(tree_view.no_item, 1)));
    try testing.expectEqualStrings("C modules (translated)", tv.itemText(tv.childAt(tree_view.no_item, 2)));

    // Opening the library loads its folders first, then its files.
    const lib = tv.childAt(tree_view.no_item, 0);
    tv.setExpanded(lib, true);
    mp.onToggle(undefined);
    try testing.expectEqual(@as(usize, 2), tv.childCount(lib));
    try testing.expectEqualStrings("fs", tv.itemText(tv.childAt(lib, 0)));
    try testing.expectEqualStrings("std.zig", tv.itemText(tv.childAt(lib, 1)));
    tv.out.activated_item = tv.childAt(lib, 1);
    mp.onActivate(undefined);
    try testing.expect(std.mem.endsWith(u8, opened.buf[0..opened.len], "std/std.zig"));

    // A package is a folder under its group; hidden files are not listed.
    const deps = tv.childAt(tree_view.no_item, 1);
    const pkg = tv.childAt(deps, 0);
    try testing.expectEqualStrings("zigimg", tv.itemText(pkg));
    tv.setExpanded(pkg, true);
    mp.onToggle(undefined);
    try testing.expectEqual(@as(usize, 1), tv.childCount(pkg));
    try testing.expectEqualStrings("src", tv.itemText(tv.childAt(pkg, 0)));

    // A translated header is one file.
    const c_group = tv.childAt(tree_view.no_item, 2);
    const header = tv.childAt(c_group, 0);
    try testing.expectEqualStrings("api.h", tv.itemText(header));
    tv.out.activated_item = header;
    mp.onActivate(undefined);
    try testing.expect(std.mem.endsWith(u8, opened.buf[0..opened.len], "api-123.zig"));
}
