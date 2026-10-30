//! Find in project: a query field with case/whole-word toggles above a tree of
//! results grouped by file. Results stream in while the search runs; activating
//! a hit calls `on_open` with the file, line and column.
//!
//!     const sp = try SearchPanel.create(&ui, parent, &project, .{ .on_open = OpenHook.bind(&app, App.openAt), .wake = sdl.wake });
//!     defer sp.destroy();
//!     sp.setQuery("needle"); sp.start();     // or the user types and presses Enter
//!     // each loop iteration:
//!     sp.poll();
//!
//! IDE-level code: it builds on `Searcher`, `TreeView` and `TextField`.

const std = @import("std");
const Handle = @import("../core/handle.zig").Handle;
const Ui = @import("../core/ui.zig").Ui;
const event = @import("../core/event.zig");
const Style = @import("../core/style.zig").Style;
const Edges = @import("../core/style.zig").Edges;
const Length = @import("../core/length.zig").Length;
const tree_view = @import("../widgets/tree_view.zig");
const TreeView = tree_view.TreeView;
const TextField = @import("../widgets/text_field.zig").TextField;
const Button = @import("../widgets/button.zig").Button;
const Label = @import("../widgets/label.zig").Label;
const search = @import("../editor/search.zig");
const output_panel = @import("output_panel.zig");
const project_mod = @import("project.zig");
const sp = @import("search_project.zig");

/// Same shape as the Output panel's hook: file, 1-based line and column.
pub const OpenHook = output_panel.OpenHook;

pub const Options = struct {
    style: Style = .{},
    on_open: ?OpenHook = null,
    /// Wakes the event loop when results arrive (`sdl.wake`).
    wake: ?*const fn () void = null,
};

const Hit = struct { path_item: u32, line: u32, col: u32 };

pub const SearchPanel = struct {
    gpa: std.mem.Allocator,
    ui: *Ui,
    node: Handle,
    project: *const project_mod.Project,
    field: *TextField,
    case_btn: *Button,
    word_btn: *Button,
    status: *Label,
    results: *TreeView,
    on_open: ?OpenHook,
    wake: ?*const fn () void,
    searcher: ?*sp.Searcher = null,
    batch: std.ArrayListUnmanaged(sp.Event) = .empty,
    case_sensitive: bool = false,
    whole_word: bool = false,
    /// Per result item id: the hit it stands for (files have `line == 0`).
    hits: std.AutoHashMapUnmanaged(u32, Hit) = .empty,
    /// File item per path of the current search, and the file's path.
    files: std.StringHashMapUnmanaged(u32) = .empty,
    file_paths: std.AutoHashMapUnmanaged(u32, []u8) = .empty,
    total: u32 = 0,

    pub fn create(ui: *Ui, parent: Handle, project: *const project_mod.Project, opts: Options) !*SearchPanel {
        const self = try ui.gpa.create(SearchPanel);
        errdefer ui.gpa.destroy(self);
        var style = opts.style;
        style.direction = .column;
        if (std.meta.eql(style.padding, .{})) style.padding = Edges.all(6);
        style.gap = Length.px(4);
        if (style.grow == 0) style.grow = 1;
        const node = try ui.tree.create(.{ .style = style, .role = .panel });
        errdefer _ = ui.tree.destroySubtree(node);
        try ui.tree.appendChild(parent, node);
        try ui.tree.setLabel(node, "Search");
        const row = try ui.tree.create(.{ .style = .{ .direction = .row, .gap = Length.px(4), .align_items = .center, .shrink = 0 } });
        try ui.tree.appendChild(node, row);
        const pad = Edges.xy(8, 4);
        const field = try ui.add(TextField, row, .{
            .placeholder = "Find in project",
            .label = "Find in project",
            .style = .{ .grow = 1, .min_width = Length.px(100) },
            .on_submit = .bind(self, onSubmit),
        });
        const case_btn = try ui.add(Button, row, .{ .text = "Aa", .variant = .flat, .style = .{ .padding = pad }, .on_click = .bind(self, onToggle) });
        const word_btn = try ui.add(Button, row, .{ .text = "W", .variant = .flat, .style = .{ .padding = pad }, .on_click = .bind(self, onToggle) });
        _ = try ui.add(Button, row, .{ .text = "Search", .variant = .flat, .style = .{ .padding = pad }, .on_click = .bind(self, onSubmit) });
        const status = try ui.add(Label, node, .{ .text = "" });
        const results = try ui.add(TreeView, node, .{
            .style = .{ .grow = 1 },
            .label = "Search results",
            .activate_toggles = false,
            .on_activate = .bind(self, onActivate),
        });
        self.* = .{
            .gpa = ui.gpa,
            .ui = ui,
            .node = node,
            .project = project,
            .field = field,
            .case_btn = case_btn,
            .word_btn = word_btn,
            .status = status,
            .results = results,
            .on_open = opts.on_open,
            .wake = opts.wake,
        };
        return self;
    }

    pub fn destroy(self: *SearchPanel) void {
        if (self.searcher) |s| s.destroy();
        self.freeResults();
        self.hits.deinit(self.gpa);
        self.files.deinit(self.gpa);
        self.file_paths.deinit(self.gpa);
        self.batch.deinit(self.gpa);
        self.gpa.destroy(self);
    }

    fn freeResults(self: *SearchPanel) void {
        var it = self.file_paths.valueIterator();
        while (it.next()) |v| self.gpa.free(v.*);
        self.file_paths.clearRetainingCapacity();
        self.files.clearRetainingCapacity();
        self.hits.clearRetainingCapacity();
    }

    pub fn setQuery(self: *SearchPanel, q: []const u8) void {
        self.field.setText(q) catch {};
    }

    pub fn setOptions(self: *SearchPanel, case_sensitive: bool, whole_word: bool) void {
        self.case_sensitive = case_sensitive;
        self.whole_word = whole_word;
        self.case_btn.setVariant(if (case_sensitive) .primary else .flat);
        self.word_btn.setVariant(if (whole_word) .primary else .flat);
    }

    /// Is a search still running?
    pub fn running(self: *const SearchPanel) bool {
        if (self.searcher) |s| return !s.finished();
        return false;
    }

    /// Search the project for the query field's text, replacing earlier results.
    pub fn start(self: *SearchPanel) void {
        if (self.searcher) |s| {
            s.destroy();
            self.searcher = null;
        }
        self.results.clear();
        self.freeResults();
        self.total = 0;
        const q = self.field.text();
        if (q.len == 0) {
            self.status.setText("") catch {};
            return;
        }
        self.searcher = sp.Searcher.start(self.gpa, self.project, q, .{ .case_sensitive = self.case_sensitive, .whole_word = self.whole_word }, self.wake) catch {
            self.status.setText("could not start the search") catch {};
            return;
        };
        self.status.setText("Searching...") catch {};
    }

    /// Stop a running search (results so far stay).
    pub fn cancel(self: *SearchPanel) void {
        if (self.searcher) |s| s.cancel();
    }

    /// Call every loop iteration: add arrived results to the tree.
    pub fn poll(self: *SearchPanel) void {
        const s = self.searcher orelse return;
        s.drain(&self.batch);
        for (self.batch.items) |*e| {
            self.apply(e) catch {};
            e.deinit(self.gpa);
        }
        self.batch.clearRetainingCapacity();
    }

    fn apply(self: *SearchPanel, e: *sp.Event) !void {
        switch (e.*) {
            .hit => |h| {
                const file_item = self.files.get(h.path) orelse blk: {
                    const id = try self.results.addItem(tree_view.no_item, h.path);
                    const key = try self.gpa.dupe(u8, h.path);
                    errdefer self.gpa.free(key);
                    try self.file_paths.put(self.gpa, id, key);
                    try self.files.put(self.gpa, key, id);
                    try self.hits.put(self.gpa, id, .{ .path_item = id, .line = 0, .col = 0 });
                    self.results.setExpanded(id, true);
                    break :blk id;
                };
                var buf: [320]u8 = undefined;
                const label = std.fmt.bufPrint(&buf, "{d}:{d}  {s}", .{ h.line, h.col, h.text }) catch h.text;
                const id = try self.results.addItem(file_item, label);
                try self.hits.put(self.gpa, id, .{ .path_item = file_item, .line = h.line, .col = h.col });
                self.total += 1;
                self.showStatus(false, null);
            },
            .done => |d| self.showStatus(true, d),
        }
    }

    fn showStatus(self: *SearchPanel, done: bool, summary: ?sp.Summary) void {
        var buf: [96]u8 = undefined;
        const files = self.files.count();
        const msg = if (done) blk: {
            const sm = summary.?;
            const tail: []const u8 = if (sm.truncated) " (stopped at the limit)" else if (sm.cancelled) " (cancelled)" else "";
            break :blk std.fmt.bufPrint(&buf, "{d} results in {d} files{s}", .{ self.total, files, tail }) catch "";
        } else std.fmt.bufPrint(&buf, "{d} results in {d} files...", .{ self.total, files }) catch "";
        self.status.setText(msg) catch {};
    }

    fn onSubmit(self: *SearchPanel, _: *event.Event) void {
        self.start();
    }

    fn onToggle(self: *SearchPanel, ev: *event.Event) void {
        if (ev.current.eql(self.case_btn.node)) self.setOptions(!self.case_sensitive, self.whole_word) else self.setOptions(self.case_sensitive, !self.whole_word);
        if (self.field.text().len > 0) self.start();
    }

    fn onActivate(self: *SearchPanel, _: *event.Event) void {
        const id = self.results.out.activated_item;
        const h = self.hits.get(id) orelse return;
        const path = self.file_paths.get(h.path_item) orelse return;
        const hook = self.on_open orelse return;
        hook.call(hook.ctx, path, if (h.line == 0) 1 else h.line, if (h.col == 0) 1 else h.col);
    }
};

// ---- tests -----------------------------------------------------------------

const testing = std.testing;
const Rig = @import("../core/test_rig.zig").Rig;

const Got = struct {
    buf: [64]u8 = undefined,
    len: usize = 0,
    line: u32 = 0,
    col: u32 = 0,
    fn open(self: *Got, path: []const u8, line: u32, col: u32) void {
        @memcpy(self.buf[0..path.len], path);
        self.len = path.len;
        self.line = line;
        self.col = col;
    }
};

test "results group by file and activating a hit opens it at its position" {
    if (@import("builtin").os.tag != .linux) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var p = try project_mod.testProject(&tmp);
    defer p.close();
    const r = try Rig.init();
    defer r.deinit();
    var got: Got = .{};
    const panel = try SearchPanel.create(&r.ui, r.ui.tree.root, &p, .{ .on_open = .bind(&got, Got.open) });
    defer panel.destroy();
    try r.frame();
    panel.setQuery("answer");
    panel.start();
    var tries: usize = 0;
    while (panel.running() and tries < 3000) : (tries += 1) {
        var ts: std.os.linux.timespec = .{ .sec = 0, .nsec = 1_000_000 };
        _ = std.os.linux.nanosleep(&ts, null);
    }
    panel.poll();
    panel.poll();
    try r.frame();
    const tv = panel.results;
    try testing.expectEqual(@as(usize, 1), tv.childCount(tree_view.no_item));
    const file = tv.childAt(tree_view.no_item, 0);
    try testing.expectEqualStrings("src/util/a.zig", tv.itemText(file));
    try testing.expectEqual(@as(usize, 1), tv.childCount(file));
    const hit = tv.childAt(file, 0);
    try testing.expectEqualStrings("1:11  pub const answer = 42;", tv.itemText(hit));
    tv.out.activated_item = hit;
    panel.onActivate(undefined);
    try testing.expectEqualStrings("src/util/a.zig", got.buf[0..got.len]);
    try testing.expectEqual(@as(u32, 1), got.line);
    try testing.expectEqual(@as(u32, 11), got.col);

    // A new search replaces the results; an empty query clears them.
    panel.setQuery("");
    panel.start();
    try testing.expectEqual(@as(usize, 0), tv.childCount(tree_view.no_item));
}
