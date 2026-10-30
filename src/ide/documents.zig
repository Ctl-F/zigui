//! Open files as dock panels: one CodeEditor (with a find bar) per file, tabbed
//! together in the dock. Dirty files show a bullet in their tab, closing a dirty
//! file asks twice (the second close discards), and Save writes through the
//! project.
//!
//!     const docs = try Documents.create(&ui, dock, &project, io, .{ .anchor = welcome_panel });
//!     defer docs.destroy();
//!     try docs.open("src/main.zig", 12, 5);       // line 12, column 5 (1-based; 0 = start)
//!     // each loop iteration:
//!     docs.poll();
//!
//! Files up to 16 MiB are read into memory and are editable. Larger ones are
//! memory-mapped read-only (a mapped file must never be written back while it
//! is mapped). Closing does not destroy panels inside the click that asked: the
//! panel is queued and `poll` removes it.
//!
//! IDE-level code: it builds on `Dock`, `CodeEditor`, `FindBar` and `Project`.

const std = @import("std");
const Handle = @import("../core/handle.zig").Handle;
const Ui = @import("../core/ui.zig").Ui;
const event = @import("../core/event.zig");
const dock_mod = @import("../widgets/dock.zig");
const Dock = dock_mod.Dock;
const Panel = dock_mod.Panel;
const code_editor = @import("../widgets/code_editor.zig");
const CodeEditor = code_editor.CodeEditor;
const FindBar = @import("../widgets/find_bar.zig").FindBar;
const syntax = @import("../editor/syntax.zig");
const project_mod = @import("project.zig");
const Project = project_mod.Project;

pub const max_editable = 16 * 1024 * 1024;

pub const Doc = struct {
    /// Project-relative path.
    path: []u8,
    panel: *Panel,
    editor: *CodeEditor,
    find: *FindBar,
    /// Opened memory-mapped, so not editable.
    read_only: bool,
    /// The bullet is showing in the tab.
    shown_dirty: bool = false,
    /// A close was refused because of unsaved changes.
    warned: bool = false,
    closing: bool = false,

    pub fn isDirty(self: *const Doc) bool {
        return self.editor.editor.isModified();
    }
};

pub const Options = struct {
    /// A panel to open the first document beside (and when no document is open).
    anchor: ?*Panel = null,
};

pub const Documents = struct {
    gpa: std.mem.Allocator,
    ui: *Ui,
    io: std.Io,
    dock: *Dock,
    project: *const Project,
    anchor: ?*Panel,
    docs: std.ArrayListUnmanaged(*Doc) = .empty,
    last_opened: ?*Doc = null,
    /// The latest thing worth telling the user (a failed save, a refused close).
    message: [200]u8 = undefined,
    message_len: usize = 0,

    pub fn create(ui: *Ui, dock: *Dock, project: *const Project, io: std.Io, opts: Options) !*Documents {
        const self = try ui.gpa.create(Documents);
        self.* = .{ .gpa = ui.gpa, .ui = ui, .io = io, .dock = dock, .project = project, .anchor = opts.anchor };
        dock.close_hook = .bind(self, onClose);
        return self;
    }

    pub fn destroy(self: *Documents) void {
        if (self.dock.close_hook) |h| {
            if (h.ctx == @as(?*anyopaque, @ptrCast(self))) self.dock.close_hook = null;
        }
        for (self.docs.items) |d| {
            self.dock.destroyPanel(d.panel);
            self.gpa.free(d.path);
            self.gpa.destroy(d);
        }
        self.docs.deinit(self.gpa);
        self.gpa.destroy(self);
    }

    pub fn statusText(self: *const Documents) []const u8 {
        return self.message[0..self.message_len];
    }

    fn say(self: *Documents, comptime fmt: []const u8, args: anytype) void {
        const s = std.fmt.bufPrint(&self.message, fmt, args) catch self.message[0..0];
        self.message_len = s.len;
    }

    pub fn find(self: *const Documents, path: []const u8) ?*Doc {
        for (self.docs.items) |d| {
            if (std.mem.eql(u8, d.path, path)) return d;
        }
        return null;
    }

    /// Show `path` (project-relative), opening it if needed, with the caret at
    /// 1-based `line`/`col` (0 leaves the caret alone for a file already open).
    pub fn open(self: *Documents, path: []const u8, line: usize, col: usize) !*Doc {
        const doc = self.find(path) orelse try self.load(path);
        if (doc.panel.state == .hidden) try self.dock.showPanel(doc.panel);
        self.dock.activatePanel(doc.panel);
        if (line > 0) doc.editor.goTo(line, col);
        self.ui.setFocus(doc.editor.node);
        return doc;
    }

    fn titleFor(self: *const Documents, path: []const u8) []const u8 {
        const base = std.fs.path.basename(path);
        for (self.docs.items) |d| {
            if (std.mem.eql(u8, std.fs.path.basename(d.path), base)) return path;
        }
        return base;
    }

    fn load(self: *Documents, path: []const u8) !*Doc {
        var bytes: ?[]u8 = self.project.readFile(self.gpa, path, max_editable) catch |err| switch (err) {
            error.FileNotFound, error.AccessDenied => return err,
            else => null,
        };
        errdefer if (bytes) |b| self.gpa.free(b);
        const read_only = bytes == null;

        const doc = try self.gpa.create(Doc);
        errdefer self.gpa.destroy(doc);
        const path_copy = try self.gpa.dupe(u8, path);
        errdefer self.gpa.free(path_copy);
        const title = self.titleFor(path);
        const panel = try self.dock.addPanel(title);
        errdefer self.dock.destroyPanel(panel);

        const content = panel.content;
        const find_bar = try self.ui.add(FindBar, content, .{});
        const ed = try self.ui.add(CodeEditor, content, .{
            .style = .{ .grow = 1 },
            .label = "Source",
            .language = syntax.languageForPath(path),
            .folding = true,
            .read_only = read_only,
        });
        find_bar.attach(ed);
        if (bytes) |b| {
            try ed.loadText(b, true);
            bytes = null;
        } else {
            const abs = try self.project.absPath(self.gpa, path);
            defer self.gpa.free(abs);
            try ed.openFile(self.io, abs);
        }
        doc.* = .{ .path = path_copy, .panel = panel, .editor = ed, .find = find_bar, .read_only = read_only };
        panel.user = @intFromPtr(doc);
        try self.docs.append(self.gpa, doc);
        errdefer _ = self.docs.pop();

        var near: ?*Panel = self.anchor;
        if (self.last_opened) |lo| {
            if (lo.panel.state != .hidden) near = lo.panel;
        }
        try self.dock.dockTab(panel, near);
        self.last_opened = doc;
        return doc;
    }

    /// The document being edited: the focused one, else the visible tab of the
    /// last one used.
    pub fn active(self: *Documents) ?*Doc {
        if (self.ui.focused()) |f| {
            for (self.docs.items) |d| {
                if (d.editor.node.eql(f)) return d;
            }
        }
        if (self.last_opened) |lo| return lo;
        return null;
    }

    pub fn save(self: *Documents, doc: *Doc) bool {
        if (doc.read_only) {
            self.say("{s} is too large to edit; it is read-only", .{doc.path});
            return false;
        }
        const text = doc.editor.textAlloc(self.gpa) catch {
            self.say("could not save {s}: out of memory", .{doc.path});
            return false;
        };
        defer self.gpa.free(text);
        self.project.writeFile(doc.path, text) catch |err| {
            self.say("could not save {s}: {s}", .{ doc.path, @errorName(err) });
            return false;
        };
        doc.editor.markSaved();
        doc.warned = false;
        self.say("saved {s}", .{doc.path});
        return true;
    }

    pub fn saveActive(self: *Documents) bool {
        const d = self.active() orelse return false;
        return self.save(d);
    }

    /// Save every modified document; false if any failed.
    pub fn saveAll(self: *Documents) bool {
        var ok = true;
        for (self.docs.items) |d| {
            if (d.isDirty() and !self.save(d)) ok = false;
        }
        return ok;
    }

    pub fn anyDirty(self: *const Documents) bool {
        for (self.docs.items) |d| {
            if (d.isDirty()) return true;
        }
        return false;
    }

    /// Queue `doc` to close without asking; `poll` removes it.
    pub fn discard(self: *Documents, doc: *Doc) void {
        _ = self;
        doc.closing = true;
    }

    fn onClose(self: *Documents, panel: *Panel) bool {
        for (self.docs.items) |d| {
            if (d.panel != panel) continue;
            if (d.isDirty() and !d.warned) {
                d.warned = true;
                self.say("{s} has unsaved changes: save it, or close again to discard", .{d.path});
            } else d.closing = true;
            return true;
        }
        return false;
    }

    /// Call every loop iteration: update dirty bullets and remove closed documents.
    pub fn poll(self: *Documents) void {
        var i: usize = 0;
        while (i < self.docs.items.len) {
            const d = self.docs.items[i];
            if (d.closing) {
                if (self.last_opened == d) self.last_opened = null;
                _ = self.docs.orderedRemove(i);
                self.dock.destroyPanel(d.panel);
                self.gpa.free(d.path);
                self.gpa.destroy(d);
                continue;
            }
            const dirty = d.isDirty();
            if (dirty != d.shown_dirty) {
                d.shown_dirty = dirty;
                if (!dirty) d.warned = false;
                var buf: [std.fs.max_path_bytes + 4]u8 = undefined;
                const base = self.titleFor2(d);
                const t = if (dirty) std.fmt.bufPrint(&buf, "{s} \u{2022}", .{base}) catch base else base;
                self.dock.setTitle(d.panel, t) catch {};
            }
            i += 1;
        }
    }

    /// The tab title for `d` without the bullet.
    fn titleFor2(self: *const Documents, d: *const Doc) []const u8 {
        const base = std.fs.path.basename(d.path);
        for (self.docs.items) |o| {
            if (o != d and std.mem.eql(u8, std.fs.path.basename(o.path), base)) return d.path;
        }
        return base;
    }
};

// ---- tests -----------------------------------------------------------------

const testing = std.testing;
const Rig = @import("test_rig.zig").Rig;

test "open, edit, save, and close documents" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var p = try project_mod.testProject(&tmp);
    defer p.close();
    const r = try Rig.init();
    defer r.deinit();
    const dock = try Dock.create(&r.ui, r.ui.tree.root, .{ .style = .{ .grow = 1 } });
    const welcome = try dock.addPanel("Welcome");
    try dock.dockTab(welcome, null);
    const docs = try Documents.create(&r.ui, dock, &p, testing.io, .{ .anchor = welcome });
    defer docs.destroy();

    const d = try docs.open("src/main.zig", 2, 5);
    try r.frame();
    try testing.expect(docs.find("src/main.zig") == d);
    try testing.expectEqual(@as(usize, 1), docs.docs.items.len);
    try testing.expectEqualStrings("main.zig", d.panel.title);
    // Same panel group as the anchor (tabs of one group).
    try testing.expect(d.panel.group == welcome.group);
    try testing.expectEqual(@as(u32, 1), d.editor.out.caret_line);
    // Opening again reuses the document.
    try testing.expect((try docs.open("src/main.zig", 0, 0)) == d);
    try testing.expectEqual(@as(usize, 1), docs.docs.items.len);

    // Edit -> bullet in the title; save -> clean again and on disk.
    try testing.expect(!d.isDirty());
    d.editor.editor.setCaret(0, false);
    _ = try d.editor.editor.typeText("// edited\n", 0);
    try r.frame();
    docs.poll();
    try testing.expect(d.isDirty());
    try testing.expectEqualStrings("main.zig \u{2022}", d.panel.title);
    // First close is refused, second discards.
    docs.dock.requestClose(d.panel);
    try testing.expect(!d.closing);
    try testing.expect(std.mem.indexOf(u8, docs.statusText(), "unsaved") != null);
    try testing.expect(docs.save(d));
    docs.poll();
    try testing.expectEqualStrings("main.zig", d.panel.title);
    const disk = try p.readFile(testing.allocator, "src/main.zig", 1024);
    defer testing.allocator.free(disk);
    try testing.expect(std.mem.startsWith(u8, disk, "// edited\n"));

    // A clean document closes at once (on the next poll).
    docs.dock.requestClose(d.panel);
    try testing.expect(d.closing);
    docs.poll();
    try testing.expectEqual(@as(usize, 0), docs.docs.items.len);
    try testing.expect(dock.panelNamed("main.zig") == null);

    // Same file names disambiguate by path; missing files fail cleanly.
    _ = try docs.open("src/main.zig", 0, 0);
    try testing.expectError(error.FileNotFound, docs.open("nope.zig", 0, 0));
    try r.frame();
}
