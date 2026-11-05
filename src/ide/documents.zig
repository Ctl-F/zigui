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
const Completion = @import("../widgets/completion.zig").Completion;
const hover_mod = @import("../widgets/hover.zig");
const Assist = @import("lsp_assist.zig").Assist;
const ZigCompleter = @import("zig_complete.zig").ZigCompleter;
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

/// How new editors are set up (and `applyDefaults` updates the open ones).
pub const EditorDefaults = struct {
    size: f32 = 0,
    tab_width: u32 = 4,
    line_numbers: bool = true,
    folding: bool = true,
};

/// Called after a document was saved.
pub const SavedHook = struct {
    ctx: ?*anyopaque = null,
    call: *const fn (ctx: ?*anyopaque, doc: *Doc) void,
};

/// Called when the gutter's marks column of `doc` is clicked: the 0-based line.
pub const GutterHook = struct {
    ctx: ?*anyopaque = null,
    call: *const fn (ctx: ?*anyopaque, doc: *Doc, line: usize) void,
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
    defaults: EditorDefaults = .{},
    on_saved: ?SavedHook = null,
    /// A click on the marks column of an editor (breakpoints).
    on_gutter: ?GutterHook = null,
    /// Suggestions for every editor opened from now on (see `enableCompletion`).
    completion: ?*Completion = null,
    zig: ?*ZigCompleter = null,
    lsp: ?*Assist = null,
    hover: ?*hover_mod.Hover = null,
    signature: ?*hover_mod.SignatureHelp = null,
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
            self.releaseEditor(d.editor);
            self.dock.destroyPanel(d.panel);
            self.gpa.free(d.path);
            self.gpa.destroy(d);
        }
        self.docs.deinit(self.gpa);
        self.gpa.destroy(self);
    }

    /// Give every editor opened from now on a suggestion list. `zig` (optional)
    /// is told where each file lives so relative imports resolve. Both must
    /// outlive the documents.
    pub fn enableCompletion(self: *Documents, completion: *Completion, zig: ?*ZigCompleter) void {
        self.completion = completion;
        self.zig = zig;
    }

    /// Give every editor opened from now on hover tooltips and signature help.
    /// Both must outlive the documents.
    pub fn enableHints(self: *Documents, hover: *hover_mod.Hover, signature: *hover_mod.SignatureHelp) void {
        self.hover = hover;
        self.signature = signature;
    }

    /// Tell a language server (see `lsp_assist.zig`) about every file opened,
    /// edited, saved and closed from now on. It must outlive the documents.
    pub fn enableLsp(self: *Documents, lsp: *Assist) void {
        self.lsp = lsp;
    }

    fn under(path: []const u8, root: []const u8) bool {
        return std.mem.eql(u8, path, root) or (path.len > root.len and std.mem.startsWith(u8, path, root) and path[root.len] == '/');
    }

    /// A file or folder was renamed or moved on disk (`old` and `new` are project-relative):
    /// the documents for it (or for files inside it) follow: path, tab title, language,
    /// and the language server's idea of where the file is. Unsaved changes stay in the buffer.
    pub fn pathChanged(self: *Documents, old: []const u8, new: []const u8) void {
        for (self.docs.items) |d| {
            if (!under(d.path, old)) continue;
            const fresh = std.mem.concat(self.gpa, u8, &.{ new, d.path[old.len..] }) catch continue;
            if (self.lsp) |l| l.detach(d.editor);
            self.gpa.free(d.path);
            d.path = fresh;
            d.editor.setLanguage(syntax.languageForPath(fresh)) catch {};
            if (self.lsp) |l| {
                if (self.project.absPath(self.gpa, fresh)) |abs| {
                    defer self.gpa.free(abs);
                    l.attach(d.editor, abs) catch {};
                } else |_| {}
            }
            if (self.zig) |z| {
                if (self.project.absPath(self.gpa, fresh)) |abs| {
                    defer self.gpa.free(abs);
                    z.setDir(d.editor, std.fs.path.dirname(abs) orelse self.project.root) catch {};
                } else |_| {}
            }
            // Titles may now collide (or stop colliding): refresh them all.
            d.shown_dirty = !d.isDirty();
        }
        self.poll();
        for (self.docs.items) |d| {
            var buf: [std.fs.max_path_bytes + 4]u8 = undefined;
            const base = self.titleFor2(d);
            const t = if (d.isDirty()) std.fmt.bufPrint(&buf, "{s} \u{2022}", .{base}) catch base else base;
            self.dock.setTitle(d.panel, t) catch {};
        }
    }

    /// A file or folder was deleted: close the documents for it without asking.
    pub fn closeUnder(self: *Documents, path: []const u8) void {
        for (self.docs.items) |d| {
            if (under(d.path, path)) d.closing = true;
        }
        self.poll();
    }

    /// Apply `defaults` to every open editor (after changing them).
    pub fn applyDefaults(self: *Documents) void {
        const d = self.defaults;
        for (self.docs.items) |doc| doc.editor.configure(d.size, d.tab_width, d.line_numbers, d.folding);
    }

    fn releaseEditor(self: *Documents, ed: *CodeEditor) void {
        if (self.lsp) |l| l.detach(ed);
        if (self.hover) |h| h.detach(ed);
        if (self.signature) |g| g.detach(ed);
        if (self.completion) |c| c.detach(ed);
        if (self.zig) |z| z.forget(ed);
    }

    pub fn statusText(self: *const Documents) []const u8 {
        return self.message[0..self.message_len];
    }

    fn say(self: *Documents, comptime fmt: []const u8, args: anytype) void {
        const s = std.fmt.bufPrint(&self.message, fmt, args) catch self.message[0..0];
        self.message_len = s.len;
    }

    /// The real path of a document path: absolute paths (files outside the
    /// project, like the standard library) are returned as they are.
    fn absOf(self: *const Documents, path: []const u8) ![]u8 {
        if (std.fs.path.isAbsolute(path)) return self.gpa.dupe(u8, path);
        return self.project.absPath(self.gpa, path);
    }

    fn onGutter(self: *Documents, ev: *@import("../core/event.zig").Event) void {
        const h = self.on_gutter orelse return;
        for (self.docs.items) |d| {
            if (d.editor.node.eql(ev.current)) return h.call(h.ctx, d, d.editor.gutter_click_line);
        }
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
        const external = std.fs.path.isAbsolute(path);
        var bytes: ?[]u8 = (if (external)
            std.Io.Dir.cwd().readFileAlloc(self.io, path, self.gpa, .limited(max_editable))
        else
            self.project.readFile(self.gpa, path, max_editable)) catch |err| switch (err) {
            error.FileNotFound, error.AccessDenied => return err,
            else => null,
        };
        errdefer if (bytes) |b| self.gpa.free(b);
        // Files outside the project (the standard library) are for reading.
        const read_only = bytes == null or external;

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
            .folding = self.defaults.folding,
            .line_numbers = self.defaults.line_numbers,
            .tab_width = self.defaults.tab_width,
            .size = self.defaults.size,
            .read_only = read_only,
            .gutter_marks = true,
            .on_gutter = .bind(self, onGutter),
        });
        find_bar.attach(ed);
        if (self.hover) |h| try h.attach(ed);
        if (self.signature) |g| try g.attach(ed);
        if (self.completion) |c| {
            try c.attach(ed);
            if (self.zig) |z| {
                const abs = try self.absOf(path);
                defer self.gpa.free(abs);
                try z.setDir(ed, std.fs.path.dirname(abs) orelse self.project.root);
            }
        }
        if (bytes) |b| {
            try ed.loadText(b, true);
            bytes = null;
        } else {
            const abs = try self.absOf(path);
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
        if (self.lsp) |l| {
            const abs = self.absOf(path) catch null;
            if (abs) |a| {
                defer self.gpa.free(a);
                l.attach(ed, a) catch {};
            }
        }
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
            self.say("{s} is read-only (outside the project or too large)", .{doc.path});
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
        if (self.lsp) |l| l.saved(doc.editor);
        if (self.on_saved) |h| h.call(h.ctx, doc);
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
                self.releaseEditor(d.editor);
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
const Rig = @import("../core/test_rig.zig").Rig;

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

test "renaming or moving files updates their open documents; deleting closes them" {
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
    const main = try docs.open("src/main.zig", 0, 0);
    const util = try docs.open("src/util/a.zig", 0, 0);
    try r.frame();
    // Unsaved text survives a rename of the file itself.
    _ = try main.editor.editor.typeText("// x\n", 0);
    docs.poll();
    try testing.expectEqualStrings("main.zig \u{2022}", main.panel.title);
    try p.moveEntry("src/main.zig", "src/app.zig");
    docs.pathChanged("src/main.zig", "src/app.zig");
    try testing.expectEqualStrings("src/app.zig", main.path);
    try testing.expectEqualStrings("app.zig \u{2022}", main.panel.title);
    try testing.expect(docs.find("src/app.zig") == main and docs.find("src/main.zig") == null);
    try testing.expect(docs.save(main)); // saving writes to the new place
    const text = try p.readFile(testing.allocator, "src/app.zig", 1024);
    defer testing.allocator.free(text);
    try testing.expect(std.mem.startsWith(u8, text, "// x\n"));
    // Moving a folder moves the documents inside it.
    try p.moveEntry("src/util", "util");
    docs.pathChanged("src/util", "util");
    try testing.expectEqualStrings("util/a.zig", util.path);
    try testing.expect(docs.find("util/a.zig") == util);
    // A sibling whose name merely starts the same is not affected.
    docs.pathChanged("src/ap", "elsewhere");
    try testing.expectEqualStrings("src/app.zig", main.path);
    // Deleting closes.
    docs.closeUnder("util");
    try testing.expectEqual(@as(usize, 1), docs.docs.items.len);
    try testing.expect(docs.find("util/a.zig") == null);
}
