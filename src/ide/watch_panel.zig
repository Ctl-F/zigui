//! The Problems panel for continuous build checking: a header with a Start/Stop
//! button and the state, and a list of the errors and warnings of the latest
//! rebuild (`build_watch.zig`). The same diagnostics are drawn as squiggles in
//! the open editors and explained on hover; activating a row opens the spot.
//!
//!     const wp = try WatchPanel.create(&ui, parent, &project, docs, .{ .on_open = OpenHook.bind(&app, App.openAt), .wake = sdl.wake });
//!     defer wp.destroy();
//!     try hover.addProvider(wp.hoverProvider());
//!     wp.start();                 // or wp.toggle()
//!     // each loop iteration:
//!     wp.poll();
//!
//! IDE-level code: it builds on `Watcher`, `Documents`, `TreeView` and editor decorations.

const std = @import("std");
const Handle = @import("../core/handle.zig").Handle;
const Ui = @import("../core/ui.zig").Ui;
const event = @import("../core/event.zig");
const Style = @import("../core/style.zig").Style;
const Edges = @import("../core/style.zig").Edges;
const Length = @import("../core/length.zig").Length;
const Color = @import("../core/geometry.zig").Color;
const tree_view = @import("../widgets/tree_view.zig");
const TreeView = tree_view.TreeView;
const Button = @import("../widgets/button.zig").Button;
const Label = @import("../widgets/label.zig").Label;
const CodeEditor = @import("../widgets/code_editor.zig").CodeEditor;
const Decoration = @import("../widgets/code_editor.zig").Decoration;
const hover_mod = @import("../widgets/hover.zig");
const documents = @import("documents.zig");
const output_panel = @import("output_panel.zig");
const project_mod = @import("project.zig");
const build_watch = @import("build_watch.zig");

pub const OpenHook = output_panel.OpenHook;

/// Decoration owner slot for build diagnostics (0 is find/output, 1 the language server).
pub const deco_owner = 2;

pub const Options = struct {
    style: Style = .{},
    on_open: ?OpenHook = null,
    wake: ?*const fn () void = null,
    /// Build step to watch ("" = the default step).
    step: []const u8 = "",
    incremental: bool = true,
    /// The `zig` program.
    zig: []const u8 = "zig",
};

pub const WatchPanel = struct {
    gpa: std.mem.Allocator,
    ui: *Ui,
    node: Handle,
    project: *const project_mod.Project,
    docs: *documents.Documents,
    header: *Label,
    toggle_btn: *Button,
    list: *TreeView,
    on_open: ?OpenHook,
    wake: ?*const fn () void,
    step: []u8,
    incremental: bool,
    zig: []u8,
    watcher: ?*build_watch.Watcher = null,
    /// What the editors and list currently show.
    applied_seq: u32 = 0,
    applied_docs: usize = 0,
    /// Why nothing is running, when something went wrong.
    note: [160]u8 = undefined,
    note_len: usize = 0,

    pub fn create(ui: *Ui, parent: Handle, project: *const project_mod.Project, docs: *documents.Documents, opts: Options) !*WatchPanel {
        const self = try ui.gpa.create(WatchPanel);
        errdefer ui.gpa.destroy(self);
        var style = opts.style;
        style.direction = .column;
        if (std.meta.eql(style.padding, .{})) style.padding = Edges.all(6);
        style.gap = Length.px(4);
        if (style.grow == 0) style.grow = 1;
        const node = try ui.tree.create(.{ .style = style, .role = .panel });
        errdefer _ = ui.tree.destroySubtree(node);
        try ui.tree.appendChild(parent, node);
        try ui.tree.setLabel(node, "Problems");
        const row = try ui.tree.create(.{ .style = .{ .direction = .row, .gap = Length.px(8), .align_items = .center, .shrink = 0 } });
        try ui.tree.appendChild(node, row);
        const toggle_btn = try ui.add(Button, row, .{ .text = "Start", .variant = .flat, .style = .{ .padding = Edges.xy(10, 4) }, .on_click = .bind(self, onToggle) });
        const header = try ui.add(Label, row, .{ .text = "", .style = .{ .grow = 1 } });
        const list = try ui.add(TreeView, node, .{
            .style = .{ .grow = 1 },
            .label = "Build problems",
            .activate_toggles = false,
            .on_activate = .bind(self, onActivate),
        });
        const step = try ui.gpa.dupe(u8, opts.step);
        errdefer ui.gpa.free(step);
        const zig = try ui.gpa.dupe(u8, opts.zig);
        self.* = .{
            .gpa = ui.gpa,
            .ui = ui,
            .node = node,
            .project = project,
            .docs = docs,
            .header = header,
            .toggle_btn = toggle_btn,
            .list = list,
            .on_open = opts.on_open,
            .wake = opts.wake,
            .step = step,
            .incremental = opts.incremental,
            .zig = zig,
        };
        self.refreshHeader();
        return self;
    }

    pub fn destroy(self: *WatchPanel) void {
        if (self.watcher) |w| w.destroy();
        self.gpa.free(self.step);
        self.gpa.free(self.zig);
        self.gpa.destroy(self);
    }

    pub fn isRunning(self: *const WatchPanel) bool {
        return if (self.watcher) |w| w.running() else false;
    }

    /// Choose the step and mode for the next start (a running watch restarts).
    pub fn configure(self: *WatchPanel, step: []const u8, incremental: bool) void {
        const changed = !std.mem.eql(u8, step, self.step) or incremental != self.incremental;
        if (changed) {
            if (self.gpa.dupe(u8, step)) |copy| {
                self.gpa.free(self.step);
                self.step = copy;
            } else |_| {}
            self.incremental = incremental;
        }
        if (changed and self.isRunning()) {
            self.stop();
            self.start();
        }
    }

    fn say(self: *WatchPanel, comptime fmt: []const u8, args: anytype) void {
        const s = std.fmt.bufPrint(&self.note, fmt, args) catch self.note[0..0];
        self.note_len = s.len;
    }

    pub fn start(self: *WatchPanel) void {
        if (self.isRunning()) return;
        self.stop();
        self.note_len = 0;
        if (!self.project.hasBuildZig()) {
            self.say("no build.zig in this project", .{});
            return self.refreshHeader();
        }
        self.watcher = build_watch.Watcher.start(self.gpa, self.project.io, self.project.root, .{
            .step = self.step,
            .incremental = self.incremental,
            .wake = self.wake,
            .zig = self.zig,
        }) catch |err| {
            self.say("could not start zig build --watch: {s}", .{@errorName(err)});
            return self.refreshHeader();
        };
        self.applied_seq = 0;
        self.refreshHeader();
    }

    pub fn stop(self: *WatchPanel) void {
        if (self.watcher) |w| {
            w.destroy();
            self.watcher = null;
        }
        self.clearEditors();
        self.list.clear();
        self.applied_seq = 0;
        self.refreshHeader();
    }

    pub fn toggle(self: *WatchPanel) void {
        if (self.isRunning()) self.stop() else self.start();
    }

    fn onToggle(self: *WatchPanel, _: *event.Event) void {
        self.toggle();
    }

    fn refreshHeader(self: *WatchPanel) void {
        self.toggle_btn.setText(if (self.isRunning()) "Stop" else "Start") catch {};
        var buf: [200]u8 = undefined;
        const text: []const u8 = blk: {
            if (self.note_len > 0) break :blk self.note[0..self.note_len];
            const w = self.watcher orelse break :blk "Not running. Start checks the whole build continuously with zig build --watch.";
            if (!w.running()) break :blk std.fmt.bufPrint(&buf, "zig build --watch ended (exit {d})", .{w.exit_code.?}) catch "ended";
            const r = w.latest() orelse break :blk "Watching: first build running...";
            const inc: []const u8 = if (self.incremental) ", incremental" else "";
            break :blk std.fmt.bufPrint(&buf, "Watching{s}: {d} errors, {d} warnings (rebuild {d})", .{ inc, r.errors(), r.warnings(), r.seq }) catch "Watching";
        };
        self.header.setText(text) catch {};
    }

    /// Call every loop iteration.
    pub fn poll(self: *WatchPanel) void {
        const w = self.watcher orelse return;
        const changed = w.poll();
        const r = w.latest();
        if (changed) self.refreshHeader();
        if (r) |res| {
            if (res.seq != self.applied_seq) {
                self.applied_seq = res.seq;
                self.fillList(res);
                self.paintEditors(res);
                self.applied_docs = self.docs.docs.items.len;
            } else if (self.docs.docs.items.len != self.applied_docs) {
                // A file was opened since: it needs its squiggles too.
                self.applied_docs = self.docs.docs.items.len;
                self.paintEditors(res);
            }
        }
    }

    // ---- the list ----

    fn fillList(self: *WatchPanel, res: *const build_watch.Result) void {
        self.list.clear();
        for (res.diags, 0..) |d, i| {
            var buf: [400]u8 = undefined;
            const msg = d.message[0..@min(d.message.len, 200)];
            const text = std.fmt.bufPrint(&buf, "{s}{s}:{d}:{d}  {s}", .{ if (d.severity == .warning) "warning  " else "", d.path, d.line, d.col, msg }) catch msg;
            const id = self.list.addItem(tree_view.no_item, text) catch continue;
            self.list.setUserData(id, i);
        }
    }

    fn onActivate(self: *WatchPanel, _: *event.Event) void {
        const w = self.watcher orelse return;
        const res = w.latest() orelse return;
        const id = self.list.out.activated_item;
        if (id == tree_view.no_item or !self.list.exists(id)) return;
        const i: usize = @intCast(self.list.userData(id));
        if (i >= res.diags.len) return;
        const d = res.diags[i];
        const hook = self.on_open orelse return;
        hook.call(hook.ctx, d.path, d.line, d.col);
    }

    // ---- the editors ----

    const Range = struct { start: usize, end: usize };

    fn rangeIn(ed: *CodeEditor, d: build_watch.Diag) ?Range {
        const doc = &ed.core().doc;
        if (d.line == 0 or d.line > doc.lineCount()) return null;
        const ls = doc.lineStart(d.line - 1);
        const le = doc.lineEnd(d.line - 1);
        const from = @min(ls + (d.col -| 1), le);
        var to = @min(from + d.len, le);
        if (to <= from) to = @min(from + 1, doc.len());
        return .{ .start = from, .end = to };
    }

    fn clearEditors(self: *WatchPanel) void {
        for (self.docs.docs.items) |doc| doc.editor.clearDecorations(deco_owner);
    }

    fn paintEditors(self: *WatchPanel, res: *const build_watch.Result) void {
        for (self.docs.docs.items) |doc| {
            var decos: std.ArrayListUnmanaged(Decoration) = .empty;
            defer decos.deinit(self.gpa);
            for (res.diags) |d| {
                if (!std.mem.eql(u8, d.path, doc.path)) continue;
                const r = rangeIn(doc.editor, d) orelse continue;
                decos.append(self.gpa, .{ .start = r.start, .end = r.end, .kind = if (d.severity == .err) .error_squiggle else .warning_squiggle }) catch {};
            }
            std.mem.sort(Decoration, decos.items, {}, struct {
                fn less(_: void, a: Decoration, b: Decoration) bool {
                    return a.start < b.start;
                }
            }.less);
            if (decos.items.len == 0) doc.editor.clearDecorations(deco_owner) else doc.editor.setDecorations(deco_owner, decos.items) catch {};
        }
    }

    // ---- hover ----

    pub fn hoverProvider(self: *WatchPanel) hover_mod.HoverProvider {
        return hover_mod.HoverProvider.bind(self, hover);
    }

    fn hover(self: *WatchPanel, req: *const hover_mod.HoverRequest, out: *hover_mod.Lines) void {
        const w = self.watcher orelse return;
        const res = w.latest() orelse return;
        const doc = for (self.docs.docs.items) |d| {
            if (d.editor == req.editor) break d;
        } else return;
        const word_end = req.word_start + req.word.len;
        for (res.diags) |d| {
            if (!std.mem.eql(u8, d.path, doc.path)) continue;
            const r = rangeIn(doc.editor, d) orelse continue;
            if (r.start < word_end and req.word_start <= r.end) {
                var buf: [300]u8 = undefined;
                out.add(std.fmt.bufPrint(&buf, "build: {s}", .{d.message[0..@min(d.message.len, 280)]}) catch d.message);
            }
        }
    }
};

// ---- tests -----------------------------------------------------------------

const testing = std.testing;
const Rig = @import("../core/test_rig.zig").Rig;
const Dock = @import("../widgets/dock.zig").Dock;

const Opened = struct {
    buf: [64]u8 = undefined,
    len: usize = 0,
    line: u32 = 0,
    col: u32 = 0,
    fn open(self: *Opened, path: []const u8, line: u32, col: u32) void {
        @memcpy(self.buf[0..path.len], path);
        self.len = path.len;
        self.line = line;
        self.col = col;
    }
};

test "a rebuild's errors become a list, squiggles with hover text, and a jump" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var p = try project_mod.testProject(&tmp);
    defer p.close();
    // A fake zig that reports one error in src/main.zig (`std`, line 1, columns 7-9) and keeps running.
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "fake_zig", .data = "#!/bin/sh\nprintf 'src/main.zig:1:7: error: no good\\n  x\\n  ^~~\\nBuild Summary: 0/1 steps succeeded (1 failed)\\n' >&2\nsleep 30\n" });
    try tmp.dir.setFilePermissions(testing.io, "fake_zig", .executable_file, .{});
    const fake = try std.fs.path.join(testing.allocator, &.{ p.root, "fake_zig" });
    defer testing.allocator.free(fake);

    const r = try Rig.init();
    defer r.deinit();
    const dock = try Dock.create(&r.ui, r.ui.tree.root, .{ .style = .{ .grow = 1 } });
    const welcome = try dock.addPanel("Welcome");
    try dock.dockTab(welcome, null);
    const docs = try documents.Documents.create(&r.ui, dock, &p, testing.io, .{ .anchor = welcome });
    defer docs.destroy();
    var opened: Opened = .{};
    const wp = try WatchPanel.create(&r.ui, r.ui.tree.root, &p, docs, .{ .on_open = .bind(&opened, Opened.open), .zig = fake });
    defer wp.destroy();
    const d = try docs.open("src/main.zig", 1, 1);
    try r.frame();

    wp.start();
    try testing.expect(wp.isRunning());
    var tries: usize = 0;
    while (wp.applied_seq == 0 and tries < 3000) : (tries += 1) {
        wp.poll();
        @import("../platform/pty_common.zig").sleepMs(2);
    }
    try r.frame();
    try testing.expectEqual(@as(usize, 1), wp.list.childCount(tree_view.no_item));
    try testing.expect(std.mem.startsWith(u8, wp.list.itemText(wp.list.childAt(tree_view.no_item, 0)), "src/main.zig:1:7  no good"));
    try testing.expectEqual(@as(usize, 1), d.editor.decos[deco_owner].items.len);
    try testing.expectEqual(@as(usize, 6), d.editor.decos[deco_owner].items[0].start);
    try testing.expectEqual(@as(usize, 9), d.editor.decos[deco_owner].items[0].end);

    // Hovering `std` explains it.
    var lines: std.ArrayListUnmanaged([]const u8) = .empty;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var out: hover_mod.Lines = .{ .arena = arena.allocator(), .list = &lines };
    wp.hover(&.{ .editor = d.editor, .word = "std", .word_start = 6, .line_before = "const " }, &out);
    try testing.expectEqual(@as(usize, 1), lines.items.len);
    try testing.expectEqualStrings("build: no good", lines.items[0]);

    // Activating the row opens the spot.
    wp.list.out.activated_item = wp.list.childAt(tree_view.no_item, 0);
    wp.onActivate(undefined);
    try testing.expectEqualStrings("src/main.zig", opened.buf[0..opened.len]);
    try testing.expectEqual(@as(u32, 1), opened.line);
    try testing.expectEqual(@as(u32, 7), opened.col);

    // Stopping removes everything.
    wp.stop();
    try testing.expect(!wp.isRunning());
    try testing.expectEqual(@as(usize, 0), d.editor.decos[deco_owner].items.len);
    try testing.expectEqual(@as(usize, 0), wp.list.childCount(tree_view.no_item));
}
