//! The project's file tree: folders load from disk when first expanded, and
//! activating a file (Enter, double-click) calls `on_open` with its
//! project-relative path.
//!
//!     const files = try FilesPanel.create(&ui, parent, &project, .{
//!         .on_open = OpenFileHook.bind(&app, App.openFile),
//!         .prompt = prompt,                                   // asks for names
//!         .on_changed = ChangeHook.bind(&app, App.fileChanged),
//!     });
//!     defer files.destroy();
//!
//! Right-click an item (or the empty space) for New File, New Folder, Rename,
//! Delete (asks first) and Copy Path. Drag an item onto a folder to move it (the
//! folder under the pointer is outlined; dropping on a file means its folder, on
//! empty space the project root). Every change to the disk is reported to
//! `on_changed` after it happens, so open documents and generated files can follow.
//!
//! IDE-level code: it builds on `TreeView`, `Project` and `Prompt`.

const std = @import("std");
const Handle = @import("../core/handle.zig").Handle;
const Ui = @import("../core/ui.zig").Ui;
const event = @import("../core/event.zig");
const Style = @import("../core/style.zig").Style;
const tree_view = @import("../widgets/tree_view.zig");
const TreeView = tree_view.TreeView;
const project_mod = @import("project.zig");
const prompt_mod = @import("prompt.zig");
const Prompt = prompt_mod.Prompt;
const menu_mod = @import("../widgets/menu.zig");
const paint_ctx = @import("../core/paint_ctx.zig");
const tree_mod = @import("../core/tree.zig");
const Color = @import("../core/geometry.zig").Color;
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

/// What happened to a path (all paths project-relative).
pub const Op = enum {
    /// `a` is the new file or folder.
    created,
    /// `a` was renamed to `b` (same folder).
    renamed,
    /// `a` was moved to `b` (another folder).
    moved,
    /// `a` was deleted.
    deleted,
};

pub const ChangeHook = struct {
    ctx: ?*anyopaque = null,
    call: *const fn (ctx: ?*anyopaque, op: Op, a: []const u8, b: []const u8) void,

    pub fn bind(ctx: anytype, comptime f: anytype) ChangeHook {
        const Ptr = @TypeOf(ctx);
        return .{
            .ctx = @ptrCast(ctx),
            .call = &struct {
                fn thunk(c: ?*anyopaque, op: Op, a: []const u8, b: []const u8) void {
                    f(@as(Ptr, @ptrCast(@alignCast(c.?))), op, a, b);
                }
            }.thunk,
        };
    }
};

pub const Options = struct {
    style: Style = .{},
    on_open: ?OpenFileHook = null,
    /// Asks for the name in New File, New Folder and Rename, and confirms Delete.
    prompt: ?*Prompt = null,
    on_changed: ?ChangeHook = null,
};

const Kind = enum(u64) { file = 0, dir_unloaded = 1, dir_loaded = 2, placeholder = 3 };
const AskKind = enum { new_file, new_folder, rename, delete };
const Action = enum { new_file, new_folder, rename, delete, copy_path, refresh };

pub const FilesPanel = struct {
    gpa: std.mem.Allocator,
    ui: *Ui,
    project: *const Project,
    tree: *TreeView,
    on_open: ?OpenFileHook,
    prompt: ?*Prompt,
    on_changed: ?ChangeHook,
    /// Project-relative path per item id (the root has "").
    paths: std.AutoHashMapUnmanaged(u32, []u8) = .empty,
    /// The last thing worth telling the user (a refused move, a name that exists).
    message: [200]u8 = undefined,
    message_len: usize = 0,
    /// The item a context menu or question is about (its path, owned) and what is being asked.
    target: []u8 = &.{},
    ask_kind: AskKind = .new_file,
    menu_actions: [8]Action = undefined,
    // Drag and drop.
    press_item: u32 = tree_view.no_item,
    press_x: f32 = 0,
    press_y: f32 = 0,
    dragging: bool = false,
    /// The folder item that would receive the drop, or `no_item`.
    drop_dir: u32 = tree_view.no_item,

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
        self.* = .{ .gpa = ui.gpa, .ui = ui, .project = project, .tree = tv, .on_open = opts.on_open, .prompt = opts.prompt, .on_changed = opts.on_changed };
        errdefer self.destroy();
        try self.reload();
        for ([_]event.EventKind{ .pointer_down, .pointer_move, .pointer_up }) |k| {
            try ui.tree.addListener(tv.node, .{ .kind = k, .callback = .bind(self, onPointer) });
        }
        tv.scroll.overlay = tree_mod.PaintHook.bind(self, paintOverlay);
        return self;
    }

    pub fn destroy(self: *FilesPanel) void {
        self.gpa.free(self.target);
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

    // ---- keeping the tree in step with the disk ----

    fn idOfPath(self: *const FilesPanel, rel: []const u8) ?u32 {
        var it = self.paths.iterator();
        while (it.next()) |e| {
            if (std.mem.eql(u8, e.value_ptr.*, rel) and self.tree.exists(e.key_ptr.*)) return e.key_ptr.*;
        }
        return null;
    }

    fn lessLen(_: void, a: []u8, b: []u8) bool {
        return a.len < b.len;
    }

    /// Read the tree again from disk, keeping the folders that were open open.
    pub fn refresh(self: *FilesPanel) void {
        var open: std.ArrayListUnmanaged([]u8) = .empty;
        defer {
            for (open.items) |p| self.gpa.free(p);
            open.deinit(self.gpa);
        }
        var it = self.paths.iterator();
        while (it.next()) |e| {
            const id = e.key_ptr.*;
            if (e.value_ptr.*.len == 0 or !self.tree.exists(id)) continue;
            if (self.kindOf(id) == .dir_loaded and self.tree.isExpanded(id)) {
                const copy = self.gpa.dupe(u8, e.value_ptr.*) catch continue;
                open.append(self.gpa, copy) catch self.gpa.free(copy);
            }
        }
        std.mem.sort([]u8, open.items, {}, lessLen); // parents before their children
        self.reload() catch return;
        for (open.items) |rel| self.expandPath(rel);
    }

    fn expandPath(self: *FilesPanel, rel: []const u8) void {
        const id = self.idOfPath(rel) orelse return;
        if (self.kindOf(id) == .dir_unloaded) self.load(id) catch {};
        self.tree.setExpanded(id, true);
    }

    /// Show `rel` in the tree: open the folders above it and select it.
    pub fn selectPath(self: *FilesPanel, rel: []const u8) void {
        var at: usize = 0;
        while (std.mem.indexOfScalarPos(u8, rel, at, '/')) |slash| {
            self.expandPath(rel[0..slash]);
            at = slash + 1;
        }
        const id = self.idOfPath(rel) orelse return;
        self.tree.select(id);
        self.tree.ensureVisible(id);
    }

    pub fn statusText(self: *const FilesPanel) []const u8 {
        return self.message[0..self.message_len];
    }

    fn say(self: *FilesPanel, comptime fmt: []const u8, args: anytype) void {
        const s = std.fmt.bufPrint(&self.message, fmt, args) catch self.message[0..0];
        self.message_len = s.len;
    }

    fn changed(self: *FilesPanel, op: Op, a: []const u8, b: []const u8) void {
        if (self.on_changed) |h| h.call(h.ctx, op, a, b);
    }

    fn describe(err: anyerror) []const u8 {
        return switch (err) {
            error.AlreadyExists, error.PathAlreadyExists => "something with that name already exists",
            error.NotFound, error.FileNotFound => "it no longer exists",
            error.IntoItself => "a folder cannot be moved into itself",
            error.AccessDenied, error.PermissionDenied => "permission denied",
            else => @errorName(err),
        };
    }

    // ---- the context menu ----

    fn dirOf(rel: []const u8) []const u8 {
        return std.fs.path.dirname(rel) orelse "";
    }

    /// The folder an item stands for: itself if it is one, else the folder holding it.
    fn containingDir(self: *const FilesPanel, id: u32) []const u8 {
        const rel = self.paths.get(id) orelse return "";
        return if (self.kindOf(id) == .file) dirOf(rel) else rel;
    }

    fn setTarget(self: *FilesPanel, rel: []const u8) void {
        const copy = self.gpa.dupe(u8, rel) catch return;
        self.gpa.free(self.target);
        self.target = copy;
    }

    fn openMenu(self: *FilesPanel, id: u32, x: f32, y: f32) void {
        const has_item = id != tree_view.no_item and self.paths.get(id) != null and self.kindOf(id) != .placeholder;
        if (has_item) {
            self.tree.select(id);
            self.setTarget(self.paths.get(id).?);
        } else self.setTarget("");
        const is_root = !has_item or self.target.len == 0;
        var items: [6]menu_mod.Item = undefined;
        items[0] = .{ .label = "New File..." };
        items[1] = .{ .label = "New Folder..." };
        items[2] = .{ .label = "Rename...", .enabled = !is_root };
        items[3] = .{ .label = "Delete", .enabled = !is_root };
        items[4] = .{ .label = "Copy Path", .enabled = !is_root };
        items[5] = .{ .label = "Refresh" };
        self.menu_actions = .{ .new_file, .new_folder, .rename, .delete, .copy_path, .refresh, undefined, undefined };
        self.ui.openMenu(&items, x, y, .{ .on_pick = menu_mod.PickHook.bind(self, onMenuPick), .min_width = 160 }) catch {};
    }

    fn onMenuPick(self: *FilesPanel, index: usize) void {
        if (index >= 6) return;
        self.run(self.menu_actions[index]);
    }

    /// Do `action` on the item the menu was opened for.
    pub fn run(self: *FilesPanel, action: Action) void {
        const rel = self.target;
        var buf: [320]u8 = undefined;
        switch (action) {
            .new_file, .new_folder => {
                const id = self.idOfPath(rel);
                const dir = if (rel.len == 0) "" else if (id) |i| self.containingDir(i) else dirOf(rel);
                self.setTarget(dir);
                const kind: AskKind = if (action == .new_file) .new_file else .new_folder;
                const where = if (dir.len == 0) self.project.name else dir;
                self.ask(kind, std.fmt.bufPrint(&buf, "New {s} in {s}:", .{ if (action == .new_file) "file" else "folder", where }) catch "New:", "");
            },
            .rename => self.ask(.rename, std.fmt.bufPrint(&buf, "Rename {s} to:", .{std.fs.path.basename(rel)}) catch "Rename to:", std.fs.path.basename(rel)),
            .delete => self.ask(.delete, std.fmt.bufPrint(&buf, "Delete {s}{s}? Enter to delete:", .{ rel, if (self.project.isDir(rel)) " and everything in it" else "" }) catch "Delete? Enter to delete:", ""),
            .copy_path => {
                const cb = self.ui.clipboard orelse return;
                if (self.project.absPath(self.gpa, rel)) |abs| {
                    defer self.gpa.free(abs);
                    cb.set(cb.ctx, abs);
                    self.say("copied {s}", .{abs});
                } else |_| {}
            },
            .refresh => self.refresh(),
        }
    }

    fn ask(self: *FilesPanel, kind: AskKind, title: []const u8, initial: []const u8) void {
        const p = self.prompt orelse return self.say("no question bar is available", .{});
        self.ask_kind = kind;
        p.ask(title, initial, prompt_mod.SubmitHook.bind(self, onAnswer));
    }

    /// A relative path of plain names: no leading slash, no `..`, nothing empty.
    fn validRelPath(text: []const u8) bool {
        if (text.len == 0 or text[0] == '/') return false;
        var it = std.mem.splitScalar(u8, text, '/');
        while (it.next()) |seg| {
            if (!Project.validEntryName(seg)) return false;
        }
        return true;
    }

    fn joinRel(self: *FilesPanel, dir: []const u8, name: []const u8) ?[]u8 {
        if (dir.len == 0) return self.gpa.dupe(u8, name) catch null;
        return std.fs.path.join(self.gpa, &.{ dir, name }) catch null;
    }

    fn onAnswer(self: *FilesPanel, text: []const u8) void {
        const answer = std.mem.trim(u8, text, " \t");
        switch (self.ask_kind) {
            .new_file, .new_folder => {
                if (!validRelPath(answer)) return self.say("\"{s}\" is not a valid name", .{answer});
                const rel = self.joinRel(self.target, answer) orelse return;
                defer self.gpa.free(rel);
                const is_file = self.ask_kind == .new_file;
                (if (is_file) self.project.createEmptyFile(rel) else self.project.makeFolder(rel)) catch |err| return self.say("cannot create {s}: {s}", .{ rel, describe(err) });
                self.changed(.created, rel, "");
                self.refresh();
                self.selectPath(rel);
                if (is_file) if (self.on_open) |h| h.call(h.ctx, rel);
            },
            .rename => {
                if (!Project.validEntryName(answer)) return self.say("\"{s}\" is not a valid name", .{answer});
                const old = self.gpa.dupe(u8, self.target) catch return;
                defer self.gpa.free(old);
                if (std.mem.eql(u8, std.fs.path.basename(old), answer)) return;
                const new = self.joinRel(dirOf(old), answer) orelse return;
                defer self.gpa.free(new);
                self.project.moveEntry(old, new) catch |err| return self.say("cannot rename {s}: {s}", .{ old, describe(err) });
                self.changed(.renamed, old, new);
                self.refresh();
                self.selectPath(new);
            },
            .delete => {
                const old = self.gpa.dupe(u8, self.target) catch return;
                defer self.gpa.free(old);
                self.project.deleteEntry(old) catch |err| return self.say("cannot delete {s}: {s}", .{ old, describe(err) });
                self.changed(.deleted, old, "");
                self.refresh();
            },
        }
    }

    // ---- drag and drop ----

    /// Where dropping `src_id` onto the item under the pointer would put it: that folder's item, or null
    /// when it would not move anywhere (same folder, into itself, or nothing there).
    fn dropTarget(self: *FilesPanel, src_id: u32, over: u32) ?u32 {
        const src = self.paths.get(src_id) orelse return null;
        if (src.len == 0) return null;
        var dir_item: u32 = over;
        if (over == tree_view.no_item) {
            dir_item = self.idOfPath("") orelse return null;
        } else if (self.kindOf(over) == .file) {
            dir_item = self.tree.parentOf(over);
        } else if (self.kindOf(over) == .placeholder) return null;
        if (dir_item == tree_view.no_item) return null;
        const dst = self.paths.get(dir_item) orelse return null;
        if (std.mem.eql(u8, dirOf(src), dst)) return null; // already there
        if (std.mem.eql(u8, src, dst)) return null;
        if (dst.len > src.len and std.mem.startsWith(u8, dst, src) and dst[src.len] == '/') return null; // into itself
        return dir_item;
    }

    fn onPointer(self: *FilesPanel, ev: *event.Event) void {
        switch (ev.kind) {
            .pointer_down => {
                if (ev.button == 3) {
                    const id = self.tree.itemAt(ev.x, ev.y);
                    self.openMenu(id, ev.x, ev.y);
                    ev.markHandled();
                    return;
                }
                if (ev.button != 1) return;
                self.press_item = self.tree.itemAt(ev.x, ev.y);
                self.press_x = ev.x;
                self.press_y = ev.y;
                self.dragging = false;
            },
            .pointer_move => {
                if (self.press_item == tree_view.no_item) return;
                if (!self.dragging) {
                    const dx = ev.x - self.press_x;
                    const dy = ev.y - self.press_y;
                    if (dx * dx + dy * dy < 36) return;
                    self.dragging = true;
                }
                const over = self.tree.itemAt(ev.x, ev.y);
                const next = self.dropTarget(self.press_item, over) orelse tree_view.no_item;
                if (next != self.drop_dir) {
                    self.drop_dir = next;
                    self.ui.tree.markDirty(self.tree.scroll.node, .{ .paint = true });
                }
            },
            .pointer_up => {
                const was = self.dragging;
                const src = self.press_item;
                const dst = self.drop_dir;
                self.press_item = tree_view.no_item;
                self.dragging = false;
                self.drop_dir = tree_view.no_item;
                self.ui.tree.markDirty(self.tree.scroll.node, .{ .paint = true });
                if (was and src != tree_view.no_item and dst != tree_view.no_item) self.moveItem(src, dst);
            },
            else => {},
        }
    }

    fn moveItem(self: *FilesPanel, src_id: u32, dst_dir_id: u32) void {
        const src = self.gpa.dupe(u8, self.paths.get(src_id) orelse return) catch return;
        defer self.gpa.free(src);
        const dst_dir = self.paths.get(dst_dir_id) orelse return;
        const new = self.joinRel(dst_dir, std.fs.path.basename(src)) orelse return;
        defer self.gpa.free(new);
        self.project.moveEntry(src, new) catch |err| return self.say("cannot move {s}: {s}", .{ src, describe(err) });
        self.changed(.moved, src, new);
        self.say("moved {s} to {s}", .{ src, if (dst_dir.len == 0) self.project.name else dst_dir });
        self.refresh();
        self.selectPath(new);
    }

    fn paintOverlay(self: *FilesPanel, pc: *paint_ctx.PaintCtx) paint_ctx.Error!void {
        if (!self.dragging or self.drop_dir == tree_view.no_item) return;
        const r = self.tree.rowRect(self.drop_dir) orelse return;
        try pc.list.strokeRect(r, 2, .{ .color = Color.rgb(255, 170, 40) });
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

const Changes = struct {
    ops: [16]Op = undefined,
    a: [16][96]u8 = undefined,
    b: [16][96]u8 = undefined,
    alen: [16]usize = undefined,
    blen: [16]usize = undefined,
    n: usize = 0,
    fn on(self: *Changes, op: Op, a: []const u8, b: []const u8) void {
        if (self.n == 16) return;
        self.ops[self.n] = op;
        @memcpy(self.a[self.n][0..a.len], a);
        self.alen[self.n] = a.len;
        @memcpy(self.b[self.n][0..b.len], b);
        self.blen[self.n] = b.len;
        self.n += 1;
    }
    fn first(self: *const Changes, i: usize) []const u8 {
        return self.a[i][0..self.alen[i]];
    }
    fn second(self: *const Changes, i: usize) []const u8 {
        return self.b[i][0..self.blen[i]];
    }
};

fn reply(r: *Rig, text: []const u8) void {
    r.ui.textInput(text);
    r.ui.key(.enter, .{}, true, false);
}

test "New File, New Folder, Rename and Delete go through the question bar and report what they did" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var p = try project_mod.testProject(&tmp);
    defer p.close();
    const r = try Rig.init();
    defer r.deinit();
    const prompt = try Prompt.create(&r.ui, r.ui.tree.root);
    defer prompt.destroy();
    var opened: Opened = .{};
    var ch: Changes = .{};
    const fp = try FilesPanel.create(&r.ui, r.ui.tree.root, &p, .{ .on_open = .bind(&opened, Opened.open), .prompt = prompt, .on_changed = .bind(&ch, Changes.on) });
    defer fp.destroy();
    try r.frame();
    const tv = fp.tree;

    // Right-click on the `src` folder: the menu offers the actions; New File asks inside it.
    const src_id = fp.idOfPath("src").?;
    fp.openMenu(src_id, 40, 40);
    try testing.expect(r.ui.menuOpen());
    r.ui.closeMenu();
    try testing.expectEqualStrings("src", fp.target);
    fp.run(.new_file);
    try testing.expect(prompt.open);
    reply(r, "extra.zig");
    try testing.expect(p.exists("src/extra.zig"));
    try testing.expectEqual(Op.created, ch.ops[0]);
    try testing.expectEqualStrings("src/extra.zig", ch.first(0));
    try testing.expectEqualStrings("src/extra.zig", opened.get()); // a new file opens
    try testing.expectEqualStrings("src/extra.zig", fp.selectedPath().?); // and is shown, selected
    try testing.expect(fp.tree.isExpanded(fp.idOfPath("src").?)); // its folder opened up

    // New Folder on a *file* means the folder holding it; nested names make parents.
    fp.setTarget("src/extra.zig");
    fp.run(.new_folder);
    reply(r, "pkg/inner");
    try testing.expect(p.isDir("src/pkg/inner"));
    // A bad or existing name is refused with a message, and nothing changes.
    fp.setTarget("src");
    fp.run(.new_file);
    reply(r, "extra.zig");
    try testing.expect(std.mem.indexOf(u8, fp.statusText(), "already exists") != null);
    fp.run(.new_file);
    reply(r, "../escape.zig");
    try testing.expect(std.mem.indexOf(u8, fp.statusText(), "not a valid name") != null);
    try testing.expect(!p.exists("escape.zig"));

    // Rename keeps the folder; the old name is gone.
    fp.setTarget("README.md");
    fp.run(.rename);
    try testing.expectEqualStrings("README.md", prompt.text());
    reply(r, "GUIDE.md"); // replaces the selected text
    try testing.expect(!p.exists("README.md") and p.exists("GUIDE.md"));
    const last = ch.n - 1;
    try testing.expectEqual(Op.renamed, ch.ops[last]);
    try testing.expectEqualStrings("README.md", ch.first(last));
    try testing.expectEqualStrings("GUIDE.md", ch.second(last));
    try testing.expectEqualStrings("GUIDE.md", fp.selectedPath().?);

    // Delete asks first; Escape leaves everything alone, Enter deletes (a folder with its contents).
    fp.setTarget("src/util");
    fp.run(.delete);
    r.ui.key(.escape, .{}, true, false);
    try testing.expect(p.exists("src/util/a.zig"));
    fp.run(.delete);
    r.ui.key(.enter, .{}, true, false);
    try testing.expect(!p.exists("src/util"));
    try testing.expectEqual(Op.deleted, ch.ops[ch.n - 1]);
    try testing.expect(fp.idOfPath("src/util") == null);
    _ = tv;
}

test "dragging an item onto a folder moves it; nonsense drops do nothing" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var p = try project_mod.testProject(&tmp);
    defer p.close();
    const r = try Rig.init();
    defer r.deinit();
    var ch: Changes = .{};
    const fp = try FilesPanel.create(&r.ui, r.ui.tree.root, &p, .{ .on_changed = .bind(&ch, Changes.on) });
    defer fp.destroy();
    try r.frame();
    try r.frame();
    const readme = fp.idOfPath("README.md").?;
    const src = fp.idOfPath("src").?;
    const from = fp.tree.rowRect(readme).?;
    const to = fp.tree.rowRect(src).?;
    const fx = from.x + 30;
    const fy = from.y + from.h / 2;
    r.ui.pointerMove(fx, fy);
    r.ui.pointerButtonEx(fx, fy, 1, true, 1);
    // A small wiggle is not a drag.
    r.ui.pointerMove(fx + 2, fy);
    try testing.expect(!fp.dragging);
    // Move over the folder: it is the drop target, and the move happens on release.
    r.ui.pointerMove(to.x + 30, to.y + to.h / 2);
    try r.frame();
    try testing.expect(fp.dragging and fp.drop_dir == src);
    r.ui.pointerButtonEx(to.x + 30, to.y + to.h / 2, 1, false, 1);
    try testing.expect(p.exists("src/README.md") and !p.exists("README.md"));
    try testing.expectEqual(Op.moved, ch.ops[0]);
    try testing.expectEqualStrings("README.md", ch.first(0));
    try testing.expectEqualStrings("src/README.md", ch.second(0));
    try testing.expect(std.mem.indexOf(u8, fp.statusText(), "moved README.md to src") != null);
    try testing.expectEqualStrings("src/README.md", fp.selectedPath().?);
    try r.frame();

    // Dropping the folder into itself, or onto its own folder, is not a target.
    const src2 = fp.idOfPath("src").?;
    const util = fp.idOfPath("src/util").?;
    try testing.expect(fp.dropTarget(src2, util) == null); // into itself
    try testing.expect(fp.dropTarget(src2, src2) == null);
    const main = fp.idOfPath("src/main.zig").?;
    try testing.expect(fp.dropTarget(main, util) != null); // a file onto a sibling folder: fine
    try testing.expect(fp.dropTarget(main, fp.idOfPath("src/README.md").?) == null); // onto a file in its own folder: same folder
    // Dropping on empty space means the root: a file two levels down can come back out.
    const a = fp.idOfPath("src/util/a.zig") orelse blk: {
        fp.expandPath("src/util");
        break :blk fp.idOfPath("src/util/a.zig").?;
    };
    try testing.expect(fp.dropTarget(a, tree_view.no_item) == fp.idOfPath(""));
    // A move onto an existing name is refused.
    try p.writeFile("src/util/main.zig", "x");
    fp.refresh();
    fp.moveItem(fp.idOfPath("src/main.zig").?, fp.idOfPath("src/util").?);
    try testing.expect(std.mem.indexOf(u8, fp.statusText(), "already exists") != null);
    try testing.expect(p.exists("src/main.zig"));
}

test "refresh keeps open folders open" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var p = try project_mod.testProject(&tmp);
    defer p.close();
    const r = try Rig.init();
    defer r.deinit();
    const fp = try FilesPanel.create(&r.ui, r.ui.tree.root, &p, .{});
    defer fp.destroy();
    fp.expandPath("src");
    fp.expandPath("src/util");
    try p.createEmptyFile("src/util/new.zig");
    fp.refresh();
    try testing.expect(fp.tree.isExpanded(fp.idOfPath("src/util").?));
    try testing.expect(fp.idOfPath("src/util/new.zig") != null);
}
