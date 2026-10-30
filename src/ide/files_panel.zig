//! The project's file tree: folders load from disk when first expanded, and
//! activating a file (Enter, double-click) calls `on_open` with its
//! project-relative path.
//!
//!     const files = try FilesPanel.create(&ui, parent, &project, .{ .on_open = OpenFileHook.bind(&app, App.openFile) });
//!     defer files.destroy();
//!
//! IDE-level code: it builds on `TreeView` and `Project`.

const std = @import("std");
const Handle = @import("../core/handle.zig").Handle;
const Ui = @import("../core/ui.zig").Ui;
const event = @import("../core/event.zig");
const Style = @import("../core/style.zig").Style;
const tree_view = @import("../widgets/tree_view.zig");
const TreeView = tree_view.TreeView;
const project_mod = @import("project.zig");
const Project = project_mod.Project;

/// Called with a project-relative path (`src/main.zig`).
pub const OpenFileHook = struct {
    ctx: ?*anyopaque = null,
    call: *const fn (ctx: ?*anyopaque, path: []const u8) void,

    pub fn bind(ctx: anytype, comptime f: anytype) OpenFileHook {
        const Ptr = @TypeOf(ctx);
        return .{
            .ctx = @ptrCast(ctx),
            .call = &struct {
                fn thunk(c: ?*anyopaque, path: []const u8) void {
                    f(@as(Ptr, @ptrCast(@alignCast(c.?))), path);
                }
            }.thunk,
        };
    }
};

pub const Options = struct {
    style: Style = .{},
    on_open: ?OpenFileHook = null,
};

const Kind = enum(u64) { file = 0, dir_unloaded = 1, dir_loaded = 2, placeholder = 3 };

pub const FilesPanel = struct {
    gpa: std.mem.Allocator,
    ui: *Ui,
    project: *const Project,
    tree: *TreeView,
    on_open: ?OpenFileHook,
    /// Project-relative path per item id (the root has "").
    paths: std.AutoHashMapUnmanaged(u32, []u8) = .empty,

    pub fn create(ui: *Ui, parent: Handle, project: *const Project, opts: Options) !*FilesPanel {
        const self = try ui.gpa.create(FilesPanel);
        errdefer ui.gpa.destroy(self);
        var style = opts.style;
        if (std.meta.eql(style, Style{})) style.grow = 1;
        const tv = try ui.add(TreeView, parent, .{
            .style = style,
            .label = "Files",
            .activate_toggles = true,
            .on_toggle = .bind(self, onToggle),
            .on_activate = .bind(self, onActivate),
        });
        self.* = .{ .gpa = ui.gpa, .ui = ui, .project = project, .tree = tv, .on_open = opts.on_open };
        errdefer self.destroy();
        try self.reload();
        return self;
    }

    pub fn destroy(self: *FilesPanel) void {
        self.freePaths();
        self.paths.deinit(self.gpa);
        self.gpa.destroy(self);
    }

    fn freePaths(self: *FilesPanel) void {
        var it = self.paths.valueIterator();
        while (it.next()) |v| self.gpa.free(v.*);
        self.paths.clearRetainingCapacity();
    }

    /// Re-read the project root from disk (collapses everything).
    pub fn reload(self: *FilesPanel) !void {
        self.tree.clear();
        self.freePaths();
        const root = try self.tree.addItem(tree_view.no_item, self.project.name);
        try self.remember(root, "");
        self.tree.setUserData(root, @intFromEnum(Kind.dir_unloaded));
        try self.load(root);
        self.tree.setExpanded(root, true);
    }

    fn remember(self: *FilesPanel, id: u32, path: []const u8) !void {
        const copy = try self.gpa.dupe(u8, path);
        errdefer self.gpa.free(copy);
        try self.paths.put(self.gpa, id, copy);
    }

    fn kindOf(self: *const FilesPanel, id: u32) Kind {
        return @enumFromInt(self.tree.userData(id));
    }

    /// Fill folder `dir` with its entries (folders get a placeholder child so
    /// they show an expander).
    fn load(self: *FilesPanel, dir: u32) !void {
        const rel = self.paths.get(dir) orelse return;
        // Drop whatever is there (a placeholder, or the previous listing).
        while (self.tree.childCount(dir) > 0) self.tree.removeItem(self.tree.childAt(dir, 0));
        const entries = self.project.listDir(self.gpa, rel) catch {
            self.tree.setUserData(dir, @intFromEnum(Kind.dir_loaded));
            return;
        };
        defer project_mod.freeEntries(self.gpa, entries);
        for (entries) |e| {
            const id = try self.tree.addItem(dir, e.name);
            const child_rel = if (rel.len == 0) try self.gpa.dupe(u8, e.name) else try std.fs.path.join(self.gpa, &.{ rel, e.name });
            defer self.gpa.free(child_rel);
            try self.remember(id, child_rel);
            if (e.is_dir) {
                self.tree.setUserData(id, @intFromEnum(Kind.dir_unloaded));
                const ph = try self.tree.addItem(id, "");
                self.tree.setUserData(ph, @intFromEnum(Kind.placeholder));
            }
        }
        self.tree.setUserData(dir, @intFromEnum(Kind.dir_loaded));
    }

    fn onToggle(self: *FilesPanel, _: *event.Event) void {
        // Load any folder that was just opened and has not been read yet.
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

    fn onActivate(self: *FilesPanel, _: *event.Event) void {
        const id = self.tree.out.activated_item;
        if (id == tree_view.no_item or self.kindOf(id) != .file) return;
        const path = self.paths.get(id) orelse return;
        if (self.on_open) |h| h.call(h.ctx, path);
    }

    /// The project-relative path of the selected item, or null.
    pub fn selectedPath(self: *const FilesPanel) ?[]const u8 {
        const id = self.tree.selected();
        if (id == tree_view.no_item) return null;
        return self.paths.get(id);
    }
};

// ---- tests -----------------------------------------------------------------

const testing = std.testing;
const Rig = @import("../core/test_rig.zig").Rig;

const Opened = struct {
    buf: [128]u8 = undefined,
    len: usize = 0,
    fn open(self: *Opened, path: []const u8) void {
        @memcpy(self.buf[0..path.len], path);
        self.len = path.len;
    }
    fn get(self: *const Opened) []const u8 {
        return self.buf[0..self.len];
    }
};

test "folders load when expanded and activating a file opens it" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var p = try project_mod.testProject(&tmp);
    defer p.close();
    const r = try Rig.init();
    defer r.deinit();
    var opened: Opened = .{};
    const fp = try FilesPanel.create(&r.ui, r.ui.tree.root, &p, .{ .on_open = .bind(&opened, Opened.open) });
    defer fp.destroy();
    try r.frame();
    const tv = fp.tree;
    const root = tv.childAt(tree_view.no_item, 0);
    try testing.expect(tv.isExpanded(root));
    // src, blob.bin, build.zig, README.md (no .git or zig-out).
    try testing.expectEqual(@as(usize, 4), tv.childCount(root));
    const src = tv.childAt(root, 0);
    try testing.expectEqualStrings("src", tv.itemText(src));
    // A folder holds only a placeholder until opened.
    try testing.expectEqual(@as(usize, 1), tv.childCount(src));
    tv.setExpanded(src, true);
    fp.onToggle(undefined);
    try testing.expectEqual(@as(usize, 2), tv.childCount(src));
    const util = tv.childAt(src, 0);
    const main = tv.childAt(src, 1);
    try testing.expectEqualStrings("util", tv.itemText(util));
    try testing.expectEqualStrings("main.zig", tv.itemText(main));
    // Activate the file and then a folder.
    tv.out.activated_item = main;
    fp.onActivate(undefined);
    try testing.expectEqualStrings("src/main.zig", opened.get());
    tv.select(main);
    try testing.expectEqualStrings("src/main.zig", fp.selectedPath().?);
    opened.len = 0;
    tv.out.activated_item = util;
    fp.onActivate(undefined);
    try testing.expectEqual(@as(usize, 0), opened.len);
}
