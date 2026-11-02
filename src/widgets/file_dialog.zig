//! A file dialog drawn by the toolkit (so it looks and behaves the same
//! everywhere, and can be tested): a modal panel with a path field, a list of the
//! folder's entries, and OK / Cancel. It chooses a folder, an existing file, a
//! file name to save to, or a new folder inside an existing one.
//!
//!     const dialog = try FileDialog.create(&ui, io, ui.tree.root);   // hidden until shown
//!     defer dialog.destroy();
//!     dialog.show(.{ .title = "Open folder", .mode = .open_folder, .start_dir = "/home/me/projects",
//!                    .on_result = .bind(&app, App.opened) });          // fn (*App, path: []const u8) void
//!
//! The result hook gets an absolute path; Cancel and Escape just close the
//! dialog. Click selects, double-click or Enter opens a folder (or accepts a
//! file), the path field takes a typed path (Enter goes there), Up goes to the
//! parent, Home to the home folder (give `home` in the options), and Hidden
//! shows dot-files. While it is open the rest of the window ignores input.

const std = @import("std");
const Handle = @import("../core/handle.zig").Handle;
const Ui = @import("../core/ui.zig").Ui;
const event = @import("../core/event.zig");
const Length = @import("../core/length.zig").Length;
const Edges = @import("../core/style.zig").Edges;
const Color = @import("../core/geometry.zig").Color;
const Label = @import("label.zig").Label;
const Button = @import("button.zig").Button;
const TextField = @import("text_field.zig").TextField;
const tree_view = @import("tree_view.zig");
const TreeView = tree_view.TreeView;

pub const Mode = enum {
    /// Choose a folder (the one shown, or the selected sub-folder).
    open_folder,
    /// Choose an existing file.
    open_file,
    /// Choose a folder and type a file name.
    save_file,
    /// Choose a folder and type the name of a new folder to make there (the
    /// result is `folder/name`; the dialog does not create it).
    new_folder,
};

pub const ResultHook = struct {
    ctx: ?*anyopaque = null,
    call: *const fn (ctx: ?*anyopaque, path: []const u8) void,

    pub fn bind(ctx: anytype, comptime f: anytype) ResultHook {
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
    title: []const u8 = "Choose",
    mode: Mode = .open_folder,
    /// Where to start ("" or a path that cannot be read: the current directory).
    start_dir: []const u8 = "",
    /// The home folder for the Home button ("" hides it).
    home: []const u8 = "",
    /// The name field's initial text (save_file, new_folder).
    name: []const u8 = "",
    /// The OK button's text ("" picks one for the mode).
    ok_label: []const u8 = "",
    /// For open_file: only files ending with this are listed ("" lists all).
    suffix: []const u8 = "",
    on_result: ?ResultHook = null,
};

const Entry = struct { name: []u8, is_dir: bool };

pub const FileDialog = struct {
    gpa: std.mem.Allocator,
    ui: *Ui,
    io: std.Io,
    node: Handle,
    panel: Handle,
    title: *Label,
    path_field: *TextField,
    list: *TreeView,
    name_row: Handle,
    name_field: *TextField,
    status: *Label,
    hidden_btn: *Button,
    home_btn: *Button,
    ok_btn: *Button,
    mode: Mode = .open_folder,
    suffix: []u8 = &.{},
    home: []u8 = &.{},
    hook: ?ResultHook = null,
    /// The folder shown (absolute).
    dir: []u8 = &.{},
    entries: std.ArrayListUnmanaged(Entry) = .empty,
    show_hidden: bool = false,
    open: bool = false,
    scoped: bool = false,

    pub fn create(ui: *Ui, io: std.Io, parent: Handle) !*FileDialog {
        const self = try ui.gpa.create(FileDialog);
        errdefer ui.gpa.destroy(self);
        const tree = &ui.tree;
        // A full-window layer (taking pointer input, dimming what is behind) holding a centered panel.
        const node = try tree.create(.{
            .style = .{ .position = .absolute, .inset = .{ .left = Length.px(0), .top = Length.px(0), .right = Length.px(0), .bottom = Length.px(0) }, .direction = .column, .align_items = .center, .justify = .center },
            .visual = .{ .background = Color.rgba(0, 0, 0, 120) },
            .flags = .{ .hidden = true },
            .role = .panel,
        });
        errdefer _ = tree.destroySubtree(node);
        try tree.appendChild(parent, node);
        try tree.setLabel(node, "File dialog");
        try tree.addListener(node, .{ .kind = .pointer_down, .callback = .bind(self, onBackdrop) });
        const panel = try tree.create(.{
            .style = .{ .direction = .column, .gap = Length.px(8), .padding = Edges.all(14), .width = Length.px(680), .height = Length.px(480), .shrink = 1 },
            .visual = .{ .background = Color.rgb(0x2b, 0x2d, 0x31), .border_color = Color.rgb(0x4a, 0x4d, 0x52), .border_width = 1, .radius = 6 },
            .role = .panel,
        });
        try tree.appendChild(node, panel);
        try tree.addListener(panel, .{ .kind = .key_down, .callback = .bind(self, onKey) });

        const title = try ui.add(Label, panel, .{ .text = "Choose", .size = 16, .style = .{ .shrink = 0 } });
        const nav = try tree.create(.{ .style = .{ .direction = .row, .gap = Length.px(6), .align_items = .center, .shrink = 0 } });
        try tree.appendChild(panel, nav);
        const small = Edges.xy(10, 5);
        _ = try ui.add(Button, nav, .{ .text = "Up", .variant = .flat, .style = .{ .padding = small }, .on_click = .bind(self, onUp) });
        const home_btn = try ui.add(Button, nav, .{ .text = "Home", .variant = .flat, .style = .{ .padding = small }, .on_click = .bind(self, onHome) });
        const path_field = try ui.add(TextField, nav, .{ .label = "Folder", .style = .{ .grow = 1, .min_width = Length.px(120) }, .on_submit = .bind(self, onPathSubmit) });
        const list = try ui.add(TreeView, panel, .{
            .style = .{ .grow = 1 },
            .label = "Files",
            .activate_toggles = false,
            .on_select = .bind(self, onSelect),
            .on_activate = .bind(self, onActivate),
        });
        const name_row = try tree.create(.{ .style = .{ .direction = .row, .gap = Length.px(8), .align_items = .center, .shrink = 0 } });
        try tree.appendChild(panel, name_row);
        _ = try ui.add(Label, name_row, .{ .text = "Name:", .style = .{ .shrink = 0 } });
        const name_field = try ui.add(TextField, name_row, .{ .label = "Name", .style = .{ .grow = 1 }, .on_submit = .bind(self, onNameSubmit) });
        const status = try ui.add(Label, panel, .{ .text = "", .color = Color.rgb(224, 96, 96), .style = .{ .shrink = 0 } });
        const bottom = try tree.create(.{ .style = .{ .direction = .row, .gap = Length.px(8), .align_items = .center, .shrink = 0 } });
        try tree.appendChild(panel, bottom);
        const hidden_btn = try ui.add(Button, bottom, .{ .text = "Hidden", .variant = .flat, .style = .{ .padding = small }, .on_click = .bind(self, onHidden) });
        _ = try ui.add(Label, bottom, .{ .text = "", .style = .{ .grow = 1 } });
        _ = try ui.add(Button, bottom, .{ .text = "Cancel", .style = .{ .padding = Edges.xy(14, 6) }, .on_click = .bind(self, onCancel) });
        const ok_btn = try ui.add(Button, bottom, .{ .text = "OK", .variant = .primary, .style = .{ .padding = Edges.xy(18, 6) }, .on_click = .bind(self, onOk) });
        self.* = .{
            .gpa = ui.gpa, .ui = ui, .io = io, .node = node, .panel = panel, .title = title,
            .path_field = path_field, .list = list, .name_row = name_row, .name_field = name_field,
            .status = status, .hidden_btn = hidden_btn, .home_btn = home_btn, .ok_btn = ok_btn,
        };
        return self;
    }

    pub fn destroy(self: *FileDialog) void {
        if (self.scoped) self.ui.popFocusScope();
        self.clearEntries();
        self.entries.deinit(self.gpa);
        self.gpa.free(self.dir);
        self.gpa.free(self.suffix);
        self.gpa.free(self.home);
        self.gpa.destroy(self);
    }

    fn clearEntries(self: *FileDialog) void {
        for (self.entries.items) |e| self.gpa.free(e.name);
        self.entries.clearRetainingCapacity();
    }

    fn setOwned(self: *FileDialog, slot: *[]u8, text: []const u8) void {
        const copy = self.gpa.dupe(u8, text) catch return;
        self.gpa.free(slot.*);
        slot.* = copy;
    }

    // ---- showing ----

    pub fn show(self: *FileDialog, o: Options) void {
        self.mode = o.mode;
        self.hook = o.on_result;
        self.setOwned(&self.suffix, o.suffix);
        self.setOwned(&self.home, o.home);
        self.title.setText(o.title) catch {};
        const ok = if (o.ok_label.len > 0) o.ok_label else switch (o.mode) {
            .open_folder => "Open",
            .open_file => "Open",
            .save_file => "Save",
            .new_folder => "Create",
        };
        self.ok_btn.setText(ok) catch {};
        const need_name = o.mode == .save_file or o.mode == .new_folder;
        self.ui.setHidden(self.name_row, !need_name);
        self.name_field.setText(o.name) catch {};
        self.ui.setHidden(self.home_btn.node, o.home.len == 0);
        self.status.setText("") catch {};
        var start: []const u8 = o.start_dir;
        if (start.len == 0) start = ".";
        if (!self.navigate(start)) _ = self.navigate(".");
        if (!self.open) {
            self.open = true;
            self.ui.setHidden(self.node, false);
            self.scoped = self.ui.pushFocusScope(self.panel, true);
        }
        self.ui.setFocus(if (need_name) self.name_field.node else self.list.node);
        if (need_name) self.name_field.editor.selectAll();
    }

    pub fn close(self: *FileDialog) void {
        if (!self.open) return;
        self.open = false;
        if (self.scoped) self.ui.popFocusScope();
        self.scoped = false;
        self.ui.setHidden(self.node, true);
    }

    // ---- the folder ----

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

    /// Show `path` (resolved against the current folder); false if it cannot be read.
    pub fn navigate(self: *FileDialog, path: []const u8) bool {
        const abs = (if (std.fs.path.isAbsolute(path) or self.dir.len == 0)
            std.fs.path.resolve(self.gpa, &.{path})
        else
            std.fs.path.resolve(self.gpa, &.{ self.dir, path })) catch return false;
        defer self.gpa.free(abs);
        // A relative start ("." with no folder yet) means the working directory.
        var real_buf: [std.fs.max_path_bytes]u8 = undefined;
        var dir = std.Io.Dir.cwd().openDir(self.io, abs, .{ .iterate = true }) catch {
            self.status.setText("cannot open that folder") catch {};
            return false;
        };
        defer dir.close(self.io);
        const n = dir.realPath(self.io, &real_buf) catch return false;
        const real = real_buf[0..n];
        self.clearEntries();
        var it = dir.iterate();
        while (it.next(self.io) catch null) |e| {
            if (!self.show_hidden and e.name.len > 0 and e.name[0] == '.') continue;
            var is_dir = e.kind == .directory;
            if (e.kind == .sym_link) {
                if (dir.openDir(self.io, e.name, .{})) |d| {
                    d.close(self.io);
                    is_dir = true;
                } else |_| {}
            } else if (e.kind != .directory and e.kind != .file) continue;
            if (!is_dir and self.mode == .open_folder or !is_dir and self.mode == .new_folder) continue;
            if (!is_dir and self.mode == .open_file and self.suffix.len > 0 and !std.mem.endsWith(u8, e.name, self.suffix)) continue;
            const name = self.gpa.dupe(u8, e.name) catch continue;
            self.entries.append(self.gpa, .{ .name = name, .is_dir = is_dir }) catch self.gpa.free(name);
        }
        std.mem.sort(Entry, self.entries.items, {}, lessEntry);
        self.setOwned(&self.dir, real);
        self.path_field.setText(real) catch {};
        self.status.setText("") catch {};
        self.fillList();
        return true;
    }

    fn fillList(self: *FileDialog) void {
        self.list.clear();
        for (self.entries.items, 0..) |e, i| {
            var buf: [std.fs.max_path_bytes]u8 = undefined;
            const text = if (e.is_dir) (std.fmt.bufPrint(&buf, "{s}/", .{e.name}) catch e.name) else e.name;
            const id = self.list.addItem(tree_view.no_item, text) catch continue;
            self.list.setUserData(id, i);
        }
        if (self.entries.items.len > 0) self.list.select(self.list.childAt(tree_view.no_item, 0));
    }

    fn entryOf(self: *const FileDialog, id: u32) ?Entry {
        if (id == tree_view.no_item or !self.list.exists(id)) return null;
        const i: usize = @intCast(self.list.userData(id));
        return if (i < self.entries.items.len) self.entries.items[i] else null;
    }

    fn joined(self: *FileDialog, name: []const u8) ?[]u8 {
        return std.fs.path.join(self.gpa, &.{ self.dir, name }) catch null;
    }

    // ---- events ----

    fn onSelect(self: *FileDialog, _: *event.Event) void {
        const e = self.entryOf(self.list.selected()) orelse return;
        if (!e.is_dir and self.mode == .save_file) self.name_field.setText(e.name) catch {};
    }

    /// Enter or a double-click on an entry.
    fn onActivate(self: *FileDialog, _: *event.Event) void {
        const e = self.entryOf(self.list.out.activated_item) orelse return;
        if (e.is_dir) {
            const p = self.joined(e.name) orelse return;
            defer self.gpa.free(p);
            _ = self.navigate(p);
        } else if (self.mode == .open_file) {
            self.accept();
        } else if (self.mode == .save_file) {
            self.name_field.setText(e.name) catch {};
            self.accept();
        }
    }

    fn onUp(self: *FileDialog, _: *event.Event) void {
        _ = self.navigate("..");
    }

    fn onHome(self: *FileDialog, _: *event.Event) void {
        if (self.home.len > 0) _ = self.navigate(self.home);
    }

    fn onHidden(self: *FileDialog, _: *event.Event) void {
        self.show_hidden = !self.show_hidden;
        self.hidden_btn.setVariant(if (self.show_hidden) .primary else .flat);
        const keep = self.gpa.dupe(u8, self.dir) catch return;
        defer self.gpa.free(keep);
        _ = self.navigate(keep);
    }

    fn onPathSubmit(self: *FileDialog, _: *event.Event) void {
        const typed = self.gpa.dupe(u8, std.mem.trim(u8, self.path_field.text(), " \t")) catch return;
        defer self.gpa.free(typed);
        if (typed.len == 0) return;
        if (!self.navigate(typed)) return;
        self.ui.setFocus(self.list.node);
    }

    fn onNameSubmit(self: *FileDialog, _: *event.Event) void {
        self.accept();
    }

    fn onOk(self: *FileDialog, _: *event.Event) void {
        self.accept();
    }

    fn onCancel(self: *FileDialog, _: *event.Event) void {
        self.close();
    }

    fn onBackdrop(self: *FileDialog, ev: *event.Event) void {
        // A press on the dimmed area outside the panel does nothing (and does not reach what is behind);
        // presses inside the panel bubble through here too and must keep their normal effect.
        if (ev.target.eql(self.node)) ev.markHandled();
    }

    fn onKey(self: *FileDialog, ev: *event.Event) void {
        if (ev.key == .escape) {
            self.close();
            ev.markHandled();
        }
    }

    /// OK: produce the result for the mode, or say what is missing.
    pub fn accept(self: *FileDialog) void {
        var result: ?[]u8 = null;
        defer if (result) |r| self.gpa.free(r);
        switch (self.mode) {
            .open_folder => {
                const e = self.entryOf(self.list.selected());
                // A selected sub-folder is what you mean; with nothing selected, the folder shown.
                result = if (e != null and e.?.is_dir) self.joined(e.?.name) else self.gpa.dupe(u8, self.dir) catch null;
            },
            .open_file => {
                const e = self.entryOf(self.list.selected()) orelse return self.fail("select a file");
                if (e.is_dir) {
                    const p = self.joined(e.name) orelse return;
                    defer self.gpa.free(p);
                    _ = self.navigate(p);
                    return;
                }
                result = self.joined(e.name);
            },
            .save_file, .new_folder => {
                const name = std.mem.trim(u8, self.name_field.text(), " \t");
                if (name.len == 0) return self.fail("type a name");
                if (std.mem.indexOfAny(u8, name, "/\\") != null or std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) return self.fail("a name cannot contain / or be . or ..");
                result = self.joined(name);
            },
        }
        const path = result orelse return;
        const hook = self.hook;
        self.close();
        if (hook) |h| h.call(h.ctx, path);
    }

    fn fail(self: *FileDialog, text: []const u8) void {
        self.status.setText(text) catch {};
    }
};

// ---- tests -----------------------------------------------------------------

const testing = std.testing;
const Rig = @import("../core/test_rig.zig").Rig;

const Got = struct {
    path: [std.fs.max_path_bytes]u8 = undefined,
    len: usize = 0,
    calls: u32 = 0,
    fn on(self: *Got, path: []const u8) void {
        @memcpy(self.path[0..path.len], path);
        self.len = path.len;
        self.calls += 1;
    }
    fn get(self: *const Got) []const u8 {
        return self.path[0..self.len];
    }
};

fn tmpRoot(tmp: *testing.TmpDir, buf: []u8) ![]const u8 {
    const n = try tmp.dir.realPathFile(testing.io, ".", buf);
    return buf[0..n];
}

fn names(d: *FileDialog, buf: *[16][]const u8) [][]const u8 {
    var n: usize = 0;
    for (d.entries.items) |e| {
        if (n == buf.len) break;
        buf[n] = e.name;
        n += 1;
    }
    return buf[0..n];
}

test "listing: folders first, hidden files off by default, navigation up and into folders" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const io = testing.io;
    try tmp.dir.createDirPath(io, "beta/inner");
    try tmp.dir.createDirPath(io, "Alpha");
    try tmp.dir.writeFile(io, .{ .sub_path = "zeta.txt", .data = "z" });
    try tmp.dir.writeFile(io, .{ .sub_path = "a.zig", .data = "a" });
    try tmp.dir.writeFile(io, .{ .sub_path = ".hidden", .data = "h" });
    var rootbuf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try tmpRoot(&tmp, &rootbuf);
    const r = try Rig.init();
    defer r.deinit();
    const d = try FileDialog.create(&r.ui, io, r.ui.tree.root);
    defer d.destroy();
    var got: Got = .{};
    d.show(.{ .title = "Open", .mode = .open_file, .start_dir = root, .on_result = .bind(&got, Got.on) });
    try r.frame();
    try testing.expect(d.open);
    var buf: [16][]const u8 = undefined;
    const list = names(d, &buf);
    try testing.expectEqual(@as(usize, 4), list.len); // hidden file left out
    try testing.expectEqualStrings("Alpha", list[0]);
    try testing.expectEqualStrings("beta", list[1]);
    try testing.expectEqualStrings("a.zig", list[2]);
    try testing.expectEqualStrings("zeta.txt", list[3]);
    try testing.expectEqualStrings(root, d.path_field.text());

    // Into a folder (double-click / Enter), then up again.
    const beta = d.list.childAt(tree_view.no_item, 1);
    d.list.out.activated_item = beta;
    d.onActivate(undefined);
    try testing.expect(std.mem.endsWith(u8, d.dir, "/beta"));
    try testing.expectEqual(@as(usize, 1), d.entries.items.len);
    d.onUp(undefined);
    try testing.expectEqualStrings(root, d.dir);
    // A typed path goes there; a bad one says so and stays.
    try d.path_field.setText("beta/inner");
    d.onPathSubmit(undefined);
    try testing.expect(std.mem.endsWith(u8, d.dir, "/beta/inner"));
    try d.path_field.setText("/definitely/not/here");
    d.onPathSubmit(undefined);
    try testing.expect(std.mem.endsWith(u8, d.dir, "/beta/inner"));
    try testing.expectEqualStrings("cannot open that folder", d.status.props.text.bytes);
    // Hidden files appear when asked.
    _ = d.navigate(root);
    d.onHidden(undefined);
    try testing.expectEqual(@as(usize, 5), d.entries.items.len);
    try testing.expectEqual(@as(u32, 0), got.calls);
}

test "each mode produces its kind of result, and Cancel and Escape close without one" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const io = testing.io;
    try tmp.dir.createDirPath(io, "proj/src");
    try tmp.dir.writeFile(io, .{ .sub_path = "proj/main.zig", .data = "m" });
    try tmp.dir.writeFile(io, .{ .sub_path = "proj/notes.md", .data = "n" });
    var rootbuf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try tmpRoot(&tmp, &rootbuf);
    const r = try Rig.init();
    defer r.deinit();
    const d = try FileDialog.create(&r.ui, io, r.ui.tree.root);
    defer d.destroy();
    var got: Got = .{};
    const hook = ResultHook.bind(&got, Got.on);

    // open_folder: files are not listed; with nothing selected, the folder shown is the answer...
    d.show(.{ .mode = .open_folder, .start_dir = root, .on_result = hook });
    try r.frame();
    try testing.expectEqual(@as(usize, 1), d.entries.items.len); // proj/
    d.list.select(tree_view.no_item); // nothing selected
    d.accept();
    try testing.expectEqualStrings(root, got.get());
    try testing.expect(!d.open);
    // ...and a selected sub-folder is the answer when one is.
    d.show(.{ .mode = .open_folder, .start_dir = root, .on_result = hook });
    d.accept();
    try testing.expect(std.mem.endsWith(u8, got.get(), "/proj"));

    // open_file: needs a selected file, and respects the suffix filter.
    d.show(.{ .mode = .open_file, .start_dir = root, .suffix = ".zig", .on_result = hook });
    _ = d.navigate("proj");
    try testing.expectEqual(@as(usize, 2), d.entries.items.len); // src/ and main.zig (not notes.md)
    d.list.select(d.list.childAt(tree_view.no_item, 1));
    d.accept();
    try testing.expect(std.mem.endsWith(u8, got.get(), "/proj/main.zig"));
    d.show(.{ .mode = .open_file, .start_dir = root, .on_result = hook });
    d.list.select(tree_view.no_item);
    const before = got.calls;
    d.accept();
    try testing.expectEqual(before, got.calls); // "select a file"
    try testing.expectEqualStrings("select a file", d.status.props.text.bytes);
    d.close();

    // new_folder: a name is required and cannot contain a slash; the result is folder/name.
    d.show(.{ .mode = .new_folder, .start_dir = root, .name = "", .on_result = hook });
    d.accept();
    try testing.expectEqualStrings("type a name", d.status.props.text.bytes);
    try d.name_field.setText("a/b");
    d.accept();
    try testing.expect(d.open);
    try d.name_field.setText("fresh");
    d.accept();
    try testing.expect(std.mem.endsWith(u8, got.get(), "/fresh") and std.mem.startsWith(u8, got.get(), root));
    // save_file: same shape, with the label "Save".
    d.show(.{ .mode = .save_file, .start_dir = root, .name = "out.txt", .on_result = hook });
    try testing.expectEqualStrings("Save", d.ok_btn.props.text.bytes);
    d.accept();
    try testing.expect(std.mem.endsWith(u8, got.get(), "/out.txt"));

    // Cancel and Escape do not call the hook; the dialog is modal while open.
    const calls = got.calls;
    d.show(.{ .mode = .open_folder, .start_dir = root, .on_result = hook });
    try testing.expectEqual(@as(usize, 1), r.ui.focusScopeDepth());
    r.ui.key(.escape, .{}, true, false);
    try testing.expect(!d.open);
    try testing.expectEqual(@as(usize, 0), r.ui.focusScopeDepth());
    d.show(.{ .mode = .open_folder, .start_dir = root, .on_result = hook });
    d.onCancel(undefined);
    try testing.expect(!d.open);
    try testing.expectEqual(calls, got.calls);
}
