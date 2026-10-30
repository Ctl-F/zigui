//! The UI designer inside the IDE: a `.ui.zon` file shown as text *and* as the
//! visual builder, kept in step both ways, with the Events tab connected to the
//! project's handlers (`handlers.zig`).
//!
//!     const designer = try Designer.create(&ui, dock, docs, &project, io, .{ .center = welcome_panel });
//!     defer designer.destroy();
//!     try designer.open("ui/main.ui.zon");          // text tab + builder panels
//!     designer.poll();                              // each loop iteration
//!
//! One builder serves whichever document is being designed; its panels (Designer
//! toolbar, Toolbox, Outline, Preview, Inspector) are docked beside the editors
//! while a document is open and hidden when the last one closes. Edits in the
//! visual builder replace the file's text (one undo step in the text editor);
//! typing in the text re-reads the document when it parses and shows the problem
//! otherwise. Saving is the document's normal save. In the Events tab, "..."
//! lists the project's handlers, creates a new one (a method added to your
//! struct, named after the widget and event, registered in `ui_actions.zig`) or
//! clears the binding; "Go" opens the handler's source.

const std = @import("std");
const Ui = @import("../core/ui.zig").Ui;
const event = @import("../core/event.zig");
const dock_mod = @import("../widgets/dock.zig");
const Dock = dock_mod.Dock;
const Panel = dock_mod.Panel;
const CodeEditor = @import("../widgets/code_editor.zig").CodeEditor;
const builder_mod = @import("../builder/builder.zig");
const Builder = builder_mod.Builder;
const uidoc = @import("../uidoc/doc.zig");
const zon = @import("../uidoc/zon.zig");
const project_mod = @import("project.zig");
const Project = project_mod.Project;
const documents_mod = @import("documents.zig");
const Documents = documents_mod.Documents;
const Doc = documents_mod.Doc;
const handlers = @import("handlers.zig");

pub const Options = struct {
    /// The panel in the middle group the preview tabs beside.
    center: ?*Panel = null,
};

/// File names the designer opens.
pub fn isUiDocument(path: []const u8) bool {
    return std.mem.endsWith(u8, path, ".ui.zon");
}

pub const Designer = struct {
    gpa: std.mem.Allocator,
    ui: *Ui,
    io: std.Io,
    dock: *Dock,
    docs: *Documents,
    project: *const Project,
    center: ?*Panel,
    builder: ?*Builder = null,
    /// The document being designed (its path is copied; the `Doc` may go away).
    current: ?*Doc = null,
    current_path: []u8 = &.{},
    /// One side is writing the other: ignore the echo.
    syncing: bool = false,
    service: handlers.Handlers,
    /// The last `list` result, whose indexes `choose` receives.
    scan: ?handlers.Scan = null,
    /// What is wrong with the text, for the status line ("" when fine).
    problem: [200]u8 = undefined,
    problem_len: usize = 0,

    pub fn create(ui: *Ui, dock: *Dock, docs: *Documents, project: *const Project, io: std.Io, opts: Options) !*Designer {
        const self = try ui.gpa.create(Designer);
        errdefer ui.gpa.destroy(self);
        self.* = .{
            .gpa = ui.gpa,
            .ui = ui,
            .io = io,
            .dock = dock,
            .docs = docs,
            .project = project,
            .center = opts.center,
            .service = try handlers.Handlers.init(ui.gpa, project),
        };
        self.service.on_apply = .{ .ctx = self, .call = applyToBuffer };
        return self;
    }

    pub fn destroy(self: *Designer) void {
        if (self.current) |d| d.editor.removeHooks(self);
        if (self.builder) |b| b.destroy();
        if (self.scan) |*s| s.deinit();
        self.service.deinit();
        self.gpa.free(self.current_path);
        self.gpa.destroy(self);
    }

    /// What is wrong with the document being designed (empty when nothing is).
    pub fn problemText(self: *const Designer) []const u8 {
        return self.problem[0..self.problem_len];
    }

    fn setProblem(self: *Designer, comptime fmt: []const u8, args: anytype) void {
        const s = std.fmt.bufPrint(&self.problem, fmt, args) catch self.problem[0..0];
        self.problem_len = s.len;
    }

    // ---- opening ----

    /// Show `path` (a project-relative `.ui.zon` file) as text and as a design.
    pub fn open(self: *Designer, path: []const u8) !void {
        const doc = try self.docs.open(path, 0, 0);
        try self.attach(doc);
    }

    /// Design the already-open document `doc`.
    pub fn attach(self: *Designer, doc: *Doc) !void {
        if (self.current == doc) {
            self.show();
            return;
        }
        if (self.current) |old| old.editor.removeHooks(self);
        const text = try doc.editor.textAlloc(self.gpa);
        defer self.gpa.free(text);
        var parsed = self.parse(text) orelse blk: {
            // Start from an empty document so the user can fix the text (the builder keeps showing it).
            break :blk try uidoc.Doc.init(self.gpa);
        };
        errdefer parsed.deinit();
        if (self.builder) |b| {
            try b.loadDocument(parsed);
        } else {
            const b = try Builder.create(self.ui, self.ui.tree.root, parsed, .{
                .save = .{ .ctx = self, .call = onBuilderSave },
                .on_change = event.Callback.bind(self, onBuilderChange),
                .dock = self.dock,
                .embedded = true,
                .command_prefix = "designer",
                .handlers = builder_mod.HandlerProvider.bind(self, Provider),
            });
            self.builder = b;
            try b.arrangeIn(self.center);
        }
        self.current = doc;
        const copy = try self.gpa.dupe(u8, doc.path);
        self.gpa.free(self.current_path);
        self.current_path = copy;
        try doc.editor.addEditHook(event.Callback.bind(self, onTextEdit));
        self.show();
    }

    fn show(self: *Designer) void {
        if (self.builder) |b| b.setPanelsVisible(true);
    }

    /// Parse `text`; on failure remember why and return null.
    fn parse(self: *Designer, text: []const u8) ?uidoc.Doc {
        var diag: zon.Diag = .{};
        var problem: uidoc.Problem = .{ .message = "" };
        const d = uidoc.parseDoc(self.gpa, text, &diag, &problem) catch |err| {
            if (err == error.Syntax) {
                self.setProblem("{s}: line {d}:{d}: {s}", .{ self.current_path, diag.line, diag.col, diag.message });
            } else self.setProblem("{s}: {s} {s}", .{ self.current_path, problem.message, problem.detail });
            return null;
        };
        self.problem_len = 0;
        return d;
    }

    // ---- the two views in step ----

    fn onBuilderSave(ctx: ?*anyopaque, _: []const u8) void {
        const self: *Designer = @ptrCast(@alignCast(ctx.?));
        if (self.current) |d| _ = self.docs.save(d);
    }

    /// The builder changed the document: put its text in the editor.
    fn onBuilderChange(self: *Designer, _: *event.Event) void {
        if (self.syncing) return;
        const d = self.current orelse return;
        const b = self.builder orelse return;
        const text = b.toZon(self.gpa) catch return;
        defer self.gpa.free(text);
        self.syncing = true;
        defer self.syncing = false;
        const old_len = d.editor.core().doc.len();
        d.editor.replaceRange(0, old_len, text);
        self.problem_len = 0;
    }

    /// The text changed: if it parses, the builder takes it.
    fn onTextEdit(self: *Designer, _: *event.Event) void {
        if (self.syncing) return;
        const d = self.current orelse return;
        const b = self.builder orelse return;
        const text = d.editor.textAlloc(self.gpa) catch return;
        defer self.gpa.free(text);
        const parsed = self.parse(text) orelse return;
        self.syncing = true;
        defer self.syncing = false;
        b.loadDocument(parsed) catch {};
    }

    /// Call every loop iteration: stop designing a document that was closed.
    pub fn poll(self: *Designer) void {
        const d = self.current orelse return;
        if (self.docs.find(self.current_path) == d) return;
        // The text tab is gone.
        self.current = null;
        if (self.builder) |b| b.setPanelsVisible(false);
        self.problem_len = 0;
    }

    // ---- handlers: the Events tab's provider ----

    /// Edits to a file that is open in an editor go into its buffer (and are saved,
    /// so the disk agrees before the binding file is regenerated).
    fn applyToBuffer(ctx: ?*anyopaque, file: []const u8, edits: []const handlers.FileEdit) bool {
        const self: *Designer = @ptrCast(@alignCast(ctx.?));
        const doc = self.docs.find(file) orelse return false;
        if (doc.read_only) return false;
        const list = self.gpa.alloc(@import("../editor/editor.zig").Edit, edits.len) catch return false;
        defer self.gpa.free(list);
        for (edits, list) |e, *out| out.* = .{ .start = e.start, .end = e.end, .text = e.text };
        doc.editor.applyEdits(list) catch return false;
        return self.docs.save(doc);
    }

    pub const Provider = struct {
        pub fn list(self: *Designer, widget_type: []const u8, event_name: []const u8, out: *builder_mod.HandlerList) void {
            _ = widget_type;
            _ = event_name;
            if (self.scan) |*s| s.deinit();
            self.scan = handlers.scan(self.gpa, self.project) catch null;
            const s = &(self.scan orelse return);
            for (s.handlers, 0..) |h, i| {
                const action = self.service.manifest.actionFor(h.container, h.file, h.name) orelse h.name;
                var buf: [160]u8 = undefined;
                const label = if (h.container.len > 0)
                    std.fmt.bufPrint(&buf, "{s}.{s}", .{ h.container, h.name }) catch h.name
                else
                    h.name;
                out.add(@intCast(i), action, label);
            }
        }

        pub fn choose(self: *Designer, id: u32) ?[]const u8 {
            const s = self.scan orelse return null;
            if (id >= s.handlers.len) return null;
            return self.service.bindExisting(s.handlers[id]) catch null;
        }

        pub fn create(self: *Designer, node_id: []const u8, widget_type: []const u8, event_name: []const u8) ?[]const u8 {
            const base = if (node_id.len > 0) node_id else widget_type;
            const action = self.service.create(base, event_name) catch return null;
            // Show the new function.
            if (self.service.manifest.find(action)) |b| _ = self.openHandler(b.container, b.file, b.function);
            return action;
        }

        pub fn reveal(self: *Designer, action: []const u8) bool {
            const b = self.service.manifest.find(action) orelse return false;
            return self.openHandler(b.container, b.file, b.function);
        }
    };

    fn openHandler(self: *Designer, container: []const u8, file: []const u8, function: []const u8) bool {
        var sc = handlers.scan(self.gpa, self.project) catch return false;
        defer sc.deinit();
        const i = sc.findHandler(container, file, function) orelse return false;
        _ = self.docs.open(file, sc.handlers[i].line, 1) catch return false;
        return true;
    }
};

// ---- tests -----------------------------------------------------------------

const testing = std.testing;
const Rig = @import("../core/test_rig.zig").Rig;

fn demoProject(tmp: *testing.TmpDir) !Project {
    const io = testing.io;
    try tmp.dir.createDirPath(io, "ui");
    try tmp.dir.writeFile(io, .{ .sub_path = "main.zig", .data =
        \\const zigui = @import("zigui");
        \\
        \\pub const App = struct {
        \\    pub fn onSave(self: *App, ev: *zigui.event.Event) void {
        \\        _ = self;
        \\        _ = ev;
        \\    }
        \\};
        \\
    });
    try tmp.dir.writeFile(io, .{ .sub_path = "ui/main.ui.zon", .data =
        \\.{ .version = 1, .root = .{ .type = "box", .children = .{
        \\    .{ .type = "button", .id = "save", .props = .{ .text = "Save" } },
        \\} } }
        \\
    });
    const dir = try tmp.dir.openDir(io, ".", .{ .iterate = true });
    return Project.fromDir(testing.allocator, io, dir);
}

test "a UI document opens as text and as a design; the two stay in step" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var p = try demoProject(&tmp);
    defer p.close();
    const r = try Rig.init();
    defer r.deinit();
    const dock = try Dock.create(&r.ui, r.ui.tree.root, .{ .style = .{ .grow = 1 } });
    const welcome = try dock.addPanel("Welcome");
    try dock.dockTab(welcome, null);
    const docs = try Documents.create(&r.ui, dock, &p, testing.io, .{ .anchor = welcome });
    defer docs.destroy();
    const des = try Designer.create(&r.ui, dock, docs, &p, testing.io, .{ .center = welcome });
    defer des.destroy();

    try des.open("ui/main.ui.zon");
    try r.frame();
    const b = des.builder.?;
    try testing.expect(des.current != null);
    try testing.expectEqual(@as(usize, 1), b.doc().root.children.items.len);
    try testing.expectEqualStrings("save", b.doc().root.children.items[0].id);
    // The panels are in the dock, the preview beside the document.
    try testing.expect(b.preview_panel.state == .docked);
    try testing.expect(b.preview_panel.group == welcome.group);

    // Editing the text updates the design.
    const ed = des.current.?.editor;
    const text = try ed.textAlloc(testing.allocator);
    defer testing.allocator.free(text);
    const at = std.mem.indexOf(u8, text, "\"Save\"").?;
    ed.replaceRange(at, at + 6, "\"Store\"");
    try r.frame();
    try testing.expectEqualStrings("", des.problemText());
    try testing.expect(std.mem.indexOf(u8, b.doc().root.children.items[0].props.field("text").?.string, "Store") != null);
    // Broken text is reported and the design keeps its last good state.
    ed.replaceRange(0, 2, "?");
    try testing.expect(des.problemText().len > 0);
    try testing.expectEqual(@as(usize, 1), b.doc().root.children.items.len);
    ed.replaceRange(0, 1, ".{");
    try testing.expectEqualStrings("", des.problemText());

    // A change made in the builder lands in the text (and marks the file modified).
    try testing.expect(des.current.?.isDirty());
    b.select(b.doc().root.children.items[0].uid);
    _ = b.editor.setId(b.selected, "saveBtn") catch {};
    des.onBuilderChange(undefined);
    const text2 = try ed.textAlloc(testing.allocator);
    defer testing.allocator.free(text2);
    try testing.expect(std.mem.indexOf(u8, text2, "saveBtn") != null);

    // Closing the text tab hides the design panels.
    des.current.?.closing = true;
    docs.poll();
    des.poll();
    try testing.expect(des.current == null);
    try testing.expect(b.preview_panel.state == .hidden);
}

test "the Events tab's provider lists, binds, creates and reveals handlers" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var p = try demoProject(&tmp);
    defer p.close();
    const r = try Rig.init();
    defer r.deinit();
    const dock = try Dock.create(&r.ui, r.ui.tree.root, .{ .style = .{ .grow = 1 } });
    const welcome = try dock.addPanel("Welcome");
    try dock.dockTab(welcome, null);
    const docs = try Documents.create(&r.ui, dock, &p, testing.io, .{ .anchor = welcome });
    defer docs.destroy();
    const des = try Designer.create(&r.ui, dock, docs, &p, testing.io, .{ .center = welcome });
    defer des.destroy();
    try des.open("ui/main.ui.zon");
    try r.frame();

    var items: std.ArrayListUnmanaged(builder_mod.HandlerChoice) = .empty;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var out: builder_mod.HandlerList = .{ .arena = arena.allocator(), .items = &items };
    Designer.Provider.list(des, "button", "click", &out);
    try testing.expectEqual(@as(usize, 1), items.items.len);
    try testing.expectEqualStrings("App.onSave", items.items[0].label);
    try testing.expectEqualStrings("onSave", items.items[0].action);
    const chosen = Designer.Provider.choose(des, items.items[0].id).?;
    try testing.expectEqualStrings("onSave", chosen);

    // Creating opens the main file (the struct's) with a new stub, in the editor buffer.
    const action = Designer.Provider.create(des, "save", "button", "click").?;
    try testing.expectEqualStrings("saveClick", action);
    const main_doc = docs.find("main.zig").?;
    const text = try main_doc.editor.textAlloc(testing.allocator);
    defer testing.allocator.free(text);
    try testing.expect(std.mem.indexOf(u8, text, "pub fn onSaveClick(self: *App, ev: *zigui.event.Event) void") != null);
    // The buffer was saved, so the disk agrees and the binding file names the new method.
    const disk = try p.readFile(testing.allocator, "main.zig", 1 << 20);
    defer testing.allocator.free(disk);
    try testing.expectEqualStrings(text, disk);
    try testing.expect(!main_doc.isDirty());
    const gen = try p.readFile(testing.allocator, handlers.binding_file, 1 << 20);
    defer testing.allocator.free(gen);
    try testing.expect(std.mem.indexOf(u8, gen, "f0.App.onSaveClick") != null);
    try testing.expect(Designer.Provider.reveal(des, "saveClick"));
    try testing.expect(!Designer.Provider.reveal(des, "nonexistent"));
    // The caret is on the new function's line.
    try r.frame();
    const line = main_doc.editor.out.caret_line;
    try testing.expect(line >= 8);
}
