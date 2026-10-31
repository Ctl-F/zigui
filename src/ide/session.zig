//! The IDE remembers the last session in `<project>/.zigide/session.zon`: which
//! files were open (with the caret in each), which tab was active, which UI
//! document was being designed, and how the panels were arranged (`Dock.saveLayout`).
//! It is written when the IDE quits or restarts and read at startup.
//!
//!     try session.save(gpa, &project, docs, dock, designer);
//!     var s = session.load(gpa, &project) orelse ...;       // null: no (usable) file
//!     defer s.deinit();
//!     s.restore(docs, dock, designer);
//!
//! Files that no longer exist are skipped, and a layout that does not fit the
//! panels is tolerated (see `Dock.loadLayout`).

const std = @import("std");
const zon = @import("../uidoc/zon.zig");
const Project = @import("project.zig").Project;
const Documents = @import("documents.zig").Documents;
const Dock = @import("../widgets/dock.zig").Dock;
const designer_mod = @import("designer.zig");

pub const path = ".zigide/session.zon";

pub const Entry = struct { path: []const u8, line: u32, col: u32 };

pub const Session = struct {
    arena: std.heap.ArenaAllocator,
    files: []Entry = &.{},
    active: []const u8 = "",
    designed: []const u8 = "",
    /// The layout as ZON text for `Dock.loadLayout`.
    layout: []const u8 = "",

    pub fn deinit(self: *Session) void {
        self.arena.deinit();
    }

    /// Reopen the files, the design, the layout and the active tab.
    pub fn restore(self: *const Session, docs: *Documents, dock: *Dock, designer: ?*designer_mod.Designer) void {
        for (self.files) |f| {
            _ = docs.open(f.path, f.line, f.col) catch continue;
        }
        if (designer) |d| if (self.designed.len > 0 and docs.find(self.designed) != null) d.open(self.designed) catch {};
        if (self.layout.len > 0) dock.loadLayout(self.layout) catch {};
        if (self.active.len > 0) {
            if (docs.find(self.active)) |d| {
                dock.activatePanel(d.panel);
                docs.ui.setFocus(d.editor.node);
            }
        }
    }
};

/// Write the session. Errors (a read-only project) are returned for the caller to ignore or report.
pub fn save(gpa: std.mem.Allocator, project: *const Project, docs: *Documents, dock: *Dock, designer: ?*designer_mod.Designer) !void {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(gpa);
    try out.appendSlice(gpa, "// The IDE's last session; written when it quits. Safe to delete.\n.{\n    .version = 1,\n");
    if (docs.active()) |a| {
        try out.appendSlice(gpa, "    .active = ");
        try quote(gpa, &out, a.path);
        try out.appendSlice(gpa, ",\n");
    }
    if (designer) |d| if (d.current != null) {
        try out.appendSlice(gpa, "    .designed = ");
        try quote(gpa, &out, d.current_path);
        try out.appendSlice(gpa, ",\n");
    };
    try out.appendSlice(gpa, "    .files = .{\n");
    for (docs.docs.items) |d| {
        try out.appendSlice(gpa, "        .{ .path = ");
        try quote(gpa, &out, d.path);
        try out.print(gpa, ", .line = {d}, .col = {d} }},\n", .{ d.editor.out.caret_line + 1, d.editor.out.caret_column + 1 });
    }
    try out.appendSlice(gpa, "    },\n    .layout = ");
    const layout = try dock.saveLayout(gpa);
    defer gpa.free(layout);
    try out.appendSlice(gpa, std.mem.trimEnd(u8, layout, "\n"));
    try out.appendSlice(gpa, ",\n}\n");
    try project.dir.createDirPath(project.io, ".zigide");
    try project.writeFile(path, out.items);
}

fn quote(gpa: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), s: []const u8) !void {
    try out.append(gpa, '"');
    for (s) |c| {
        if (c == '"' or c == '\\') try out.append(gpa, '\\');
        try out.append(gpa, c);
    }
    try out.append(gpa, '"');
}

/// Read the saved session; null when there is none or it cannot be read.
pub fn load(gpa: std.mem.Allocator, project: *const Project) ?Session {
    const bytes = project.readFile(gpa, path, 4 * 1024 * 1024) catch return null;
    defer gpa.free(bytes);
    var s: Session = .{ .arena = std.heap.ArenaAllocator.init(gpa) };
    errdefer s.arena.deinit();
    const a = s.arena.allocator();
    const v = zon.parse(a, bytes, null) catch return null;
    const str = struct {
        fn get(arena: std.mem.Allocator, value: zon.Value, name: []const u8) []const u8 {
            const f = value.field(name) orelse return "";
            return if (f == .string) arena.dupe(u8, f.string) catch "" else "";
        }
    }.get;
    s.active = str(a, v, "active");
    s.designed = str(a, v, "designed");
    var files: std.ArrayListUnmanaged(Entry) = .empty;
    if (v.field("files")) |fl| for (fl.items() orelse &.{}) |e| {
        const p = str(a, e, "path");
        if (p.len == 0) continue;
        const line = if (e.field("line")) |x| (if (x == .int and x.int > 0) @as(u32, @intCast(x.int)) else 1) else 1;
        const col = if (e.field("col")) |x| (if (x == .int and x.int > 0) @as(u32, @intCast(x.int)) else 1) else 1;
        files.append(a, .{ .path = p, .line = line, .col = col }) catch return null;
    };
    s.files = files.items;
    if (v.field("layout")) |lv| s.layout = zon.render(a, lv) catch "";
    return s;
}

// ---- tests -----------------------------------------------------------------

const testing = std.testing;
const Rig = @import("../core/test_rig.zig").Rig;

test "a session round-trips: files with carets, the active tab, and the panel arrangement" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const io = testing.io;
    try tmp.dir.createDirPath(io, "src");
    try tmp.dir.writeFile(io, .{ .sub_path = "src/a.zig", .data = "const a = 1;\nconst b = 2;\nconst c = 3;\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "src/b.zig", .data = "pub fn f() void {}\n" });
    const dir = try tmp.dir.openDir(io, ".", .{ .iterate = true });
    var p = try Project.fromDir(testing.allocator, io, dir);
    defer p.close();
    const r = try Rig.init();
    defer r.deinit();
    const dock = try Dock.create(&r.ui, r.ui.tree.root, .{ .style = .{ .grow = 1 } });
    const welcome = try dock.addPanel("Welcome");
    try dock.dockTab(welcome, null);
    const side = try dock.addPanel("Files");
    try dock.dockRoot(side, .left, 200);
    const docs = try Documents.create(&r.ui, dock, &p, io, .{ .anchor = welcome });
    defer docs.destroy();
    _ = try docs.open("src/a.zig", 2, 7);
    const b = try docs.open("src/b.zig", 1, 5);
    try r.frame();
    dock.activatePanel(b.panel);
    try r.frame();
    try save(testing.allocator, &p, docs, dock, null);

    var s = load(testing.allocator, &p).?;
    defer s.deinit();
    try testing.expectEqual(@as(usize, 2), s.files.len);
    try testing.expectEqualStrings("src/a.zig", s.files[0].path);
    try testing.expectEqual(@as(u32, 2), s.files[0].line);
    try testing.expectEqual(@as(u32, 7), s.files[0].col);
    try testing.expectEqualStrings("src/b.zig", s.active);
    try testing.expect(std.mem.indexOf(u8, s.layout, "Files") != null);

    // A fresh IDE: restore reopens both files, with the carets, and the same layout.
    const r2 = try Rig.init();
    defer r2.deinit();
    const dock2 = try Dock.create(&r2.ui, r2.ui.tree.root, .{ .style = .{ .grow = 1 } });
    const welcome2 = try dock2.addPanel("Welcome");
    try dock2.dockTab(welcome2, null);
    const side2 = try dock2.addPanel("Files");
    try dock2.dockTab(side2, welcome2); // arranged differently before the restore
    const docs2 = try Documents.create(&r2.ui, dock2, &p, io, .{ .anchor = welcome2 });
    defer docs2.destroy();
    s.restore(docs2, dock2, null);
    try r2.frame();
    try testing.expect(docs2.find("src/a.zig") != null and docs2.find("src/b.zig") != null);
    try r2.frame();
    try testing.expectEqual(@as(u32, 1), docs2.find("src/a.zig").?.editor.out.caret_line);
    try testing.expectEqual(@as(u32, 6), docs2.find("src/a.zig").?.editor.out.caret_column);
    try testing.expect(side2.group != welcome2.group); // the Files panel is docked left again
    try testing.expect(docs2.active().? == docs2.find("src/b.zig").?);
    // No file, or junk: no session.
    try p.writeFile(path, "not zon at all");
    try testing.expect(load(testing.allocator, &p) == null);
}

test "files that no longer exist are skipped" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const io = testing.io;
    try tmp.dir.createDirPath(io, ".zigide");
    try tmp.dir.writeFile(io, .{ .sub_path = "x.zig", .data = "const x = 1;\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = ".zigide/session.zon", .data = ".{ .files = .{ .{ .path = \"gone.zig\", .line = 3, .col = 1 }, .{ .path = \"x.zig\", .line = 1, .col = 1 } }, .active = \"gone.zig\" }" });
    const dir = try tmp.dir.openDir(io, ".", .{ .iterate = true });
    var p = try Project.fromDir(testing.allocator, io, dir);
    defer p.close();
    const r = try Rig.init();
    defer r.deinit();
    const dock = try Dock.create(&r.ui, r.ui.tree.root, .{});
    const welcome = try dock.addPanel("Welcome");
    try dock.dockTab(welcome, null);
    const docs = try Documents.create(&r.ui, dock, &p, io, .{ .anchor = welcome });
    defer docs.destroy();
    var s = load(testing.allocator, &p).?;
    defer s.deinit();
    s.restore(docs, dock, null);
    try testing.expectEqual(@as(usize, 1), docs.docs.items.len);
}
