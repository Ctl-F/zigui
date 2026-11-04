//! The Tests panel: every `test` in the project's Zig files in a tree by file,
//! with buttons to run all of them, one file, one test, or the ones that failed,
//! and a status next to each test (`[ok]`, `[FAIL]`, `[skip]`, `[..]` running,
//! `[ ]` not run). Select a test to read why it failed; double-click it to open
//! its source.
//!
//!     const tp = try TestPanel.create(&ui, parent, io, &project, .{ .on_open = OpenHook.bind(&app, App.openAt), .wake = sdl.wake });
//!     defer tp.destroy();
//!     tp.refresh();          // rescan the files (on show, after a save)
//!     tp.poll();             // each loop iteration
//!
//! **How a run is done.** Tests are found by reading the files (`test_scan.zig`), not by
//! running anything. Running uses what the project offers:
//!
//! * *All*: `zig build test --summary all` (the step is `Options.step`). Needs a `build.zig`.
//! * *A file or a test*: when `build.zig` accepts `-Dtest-filter` (checked once with
//!   `zig build --help`; the option is what `zig init` projects add and Zig's own build uses),
//!   `zig build test -Dtest-filter=NAME`, which also covers files that need the build's modules.
//!   Without it, `zig test FILE [--test-filter NAME]`, which works for files whose imports
//!   stay inside their folder and fails otherwise (the output says why).
//! * *Failed*: `zig build test` with a `-Dtest-filter` for each failed test (needs the option).
//!
//! `zig test` reports each test as it runs, so those statuses appear live; `zig build test`
//! reports only the failures and a summary, so its tests turn `[ok]` when the run ends.
//! IDE-level code: it builds on `test_scan`, `process.Runner`, `TreeView` and `CodeEditor`.

const std = @import("std");
const Handle = @import("../core/handle.zig").Handle;
const Ui = @import("../core/ui.zig").Ui;
const event = @import("../core/event.zig");
const Style = @import("../core/style.zig").Style;
const Edges = @import("../core/style.zig").Edges;
const Length = @import("../core/length.zig").Length;
const worker = @import("../core/worker.zig");
const process = @import("../platform/process.zig");
const tree_view = @import("../widgets/tree_view.zig");
const TreeView = tree_view.TreeView;
const Button = @import("../widgets/button.zig").Button;
const Label = @import("../widgets/label.zig").Label;
const CodeEditor = @import("../widgets/code_editor.zig").CodeEditor;
const output_panel = @import("output_panel.zig");
const project_mod = @import("project.zig");
const ts = @import("test_scan.zig");

pub const OpenHook = output_panel.OpenHook;

pub const Options = struct {
    style: Style = .{},
    on_open: ?OpenHook = null,
    wake: ?*const fn () void = null,
    /// The `zig` program.
    zig: []const u8 = "zig",
    /// The build step that runs the tests.
    step: []const u8 = "test",
};

const group_flag: u64 = 1 << 40;
const max_output = 2 * 1024 * 1024;

const Scanned = struct {
    index: ts.Index,
    /// `build.zig` takes `-Dtest-filter`.
    filter_ok: bool,
    has_build: bool,
};

const Scope = union(enum) {
    all,
    file: []const u8,
    one: usize,
    failed,
};

pub const TestPanel = struct {
    gpa: std.mem.Allocator,
    ui: *Ui,
    io: std.Io,
    project: *const project_mod.Project,
    node: Handle,
    summary: *Label,
    list: *TreeView,
    detail: *CodeEditor,
    run_btn: *Button,
    failed_btn: *Button,
    stop_btn: *Button,
    all_btn: *Button,
    on_open: ?OpenHook,
    wake: ?*const fn () void,
    zig: []u8,
    step: []u8,
    // Discovery.
    index: ?ts.Index = null,
    filter_ok: bool = false,
    has_build: bool = false,
    scanned_once: bool = false,
    scan_pending: bool = true,
    scan_thread: ?std.Thread = null,
    scan_busy: std.atomic.Value(bool) = .init(false),
    scan_queue: worker.Queue(?*Scanned),
    last_scan_ms: u64 = 0,
    // Per test (parallel to `index.tests`).
    status: []ts.Status = &.{},
    detail_text: []?[]u8 = &.{},
    // The tree.
    test_item: []u32 = &.{},
    file_item: std.ArrayListUnmanaged(struct { file: []const u8, id: u32 }) = .empty,
    // A run.
    runner: ?*process.Runner = null,
    parser: ?ts.Parser = null,
    run_mode: ts.Mode = .build,
    run_text: std.ArrayListUnmanaged(u8) = .empty,
    run_label: [160]u8 = undefined,
    run_label_len: usize = 0,
    /// The tests this run covers (indexes), marked `[..]` while it runs.
    scope_tests: std.ArrayListUnmanaged(usize) = .empty,
    batch: std.ArrayListUnmanaged(process.Event) = .empty,
    exit_ok: bool = false,
    scan_batch: std.ArrayListUnmanaged(?*Scanned) = .empty,

    pub fn create(ui: *Ui, parent: Handle, io: std.Io, project: *const project_mod.Project, opts: Options) !*TestPanel {
        const self = try ui.gpa.create(TestPanel);
        errdefer ui.gpa.destroy(self);
        var style = opts.style;
        style.direction = .column;
        if (std.meta.eql(style.padding, .{})) style.padding = Edges.all(6);
        style.gap = Length.px(4);
        if (style.grow == 0) style.grow = 1;
        const node = try ui.tree.create(.{ .style = style, .role = .panel });
        errdefer _ = ui.tree.destroySubtree(node);
        try ui.tree.appendChild(parent, node);
        try ui.tree.setLabel(node, "Tests");
        const pad = Edges.xy(8, 4);
        const bar = try ui.tree.create(.{ .style = .{ .direction = .row, .gap = Length.px(4), .align_items = .center, .shrink = 0 } });
        try ui.tree.appendChild(node, bar);
        const all_btn = try ui.add(Button, bar, .{ .text = "Run All", .variant = .primary, .style = .{ .padding = pad }, .on_click = .bind(self, onRunAll) });
        const run_btn = try ui.add(Button, bar, .{ .text = "Run", .variant = .flat, .style = .{ .padding = pad }, .enabled = false, .on_click = .bind(self, onRun) });
        const failed_btn = try ui.add(Button, bar, .{ .text = "Run Failed", .variant = .flat, .style = .{ .padding = pad }, .enabled = false, .on_click = .bind(self, onRunFailed) });
        const stop_btn = try ui.add(Button, bar, .{ .text = "Stop", .variant = .flat, .style = .{ .padding = pad }, .enabled = false, .on_click = .bind(self, onStop) });
        _ = try ui.add(Button, bar, .{ .text = "Refresh", .variant = .flat, .style = .{ .padding = pad }, .on_click = .bind(self, onRefresh) });
        const summary = try ui.add(Label, node, .{ .text = "Looking for tests...", .style = .{ .shrink = 0 } });
        // The tests on the left and what the selected one printed on the right (the panel is usually wide, not tall).
        const split = try ui.tree.create(.{ .style = .{ .direction = .row, .gap = Length.px(6), .grow = 1 } });
        try ui.tree.appendChild(node, split);
        const list = try ui.add(TreeView, split, .{
            .style = .{ .grow = 1, .min_width = Length.px(220) },
            .label = "Tests",
            .activate_toggles = false,
            .on_select = .bind(self, onSelect),
            .on_activate = .bind(self, onActivate),
        });
        const detail = try ui.add(CodeEditor, split, .{
            .style = .{ .grow = 2, .min_width = Length.px(200) },
            .label = "Test output",
            .read_only = true,
            .line_numbers = false,
            .auto_indent = false,
            .size = 13,
            .language = &@import("../editor/syntax.zig").plain,
        });
        const zig = try ui.gpa.dupe(u8, opts.zig);
        errdefer ui.gpa.free(zig);
        const step = try ui.gpa.dupe(u8, opts.step);
        self.* = .{
            .gpa = ui.gpa,
            .ui = ui,
            .io = io,
            .project = project,
            .node = node,
            .summary = summary,
            .list = list,
            .detail = detail,
            .run_btn = run_btn,
            .failed_btn = failed_btn,
            .stop_btn = stop_btn,
            .all_btn = all_btn,
            .on_open = opts.on_open,
            .wake = opts.wake,
            .zig = zig,
            .step = step,
            .scan_queue = .{ .gpa = ui.gpa, .wake = opts.wake },
        };
        return self;
    }

    pub fn destroy(self: *TestPanel) void {
        if (self.runner) |r| r.destroy();
        if (self.parser) |*p| p.deinit();
        if (self.scan_thread) |t| t.join();
        var left: std.ArrayListUnmanaged(?*Scanned) = .empty;
        self.scan_queue.drain(&left);
        for (left.items) |m| if (m) |s| {
            var sc = s;
            sc.index.deinit();
            self.gpa.destroy(sc);
        };
        left.deinit(self.gpa);
        self.scan_queue.deinit();
        self.dropIndex();
        self.file_item.deinit(self.gpa);
        self.run_text.deinit(self.gpa);
        self.scope_tests.deinit(self.gpa);
        for (self.batch.items) |*e| e.deinit(self.gpa);
        self.batch.deinit(self.gpa);
        for (self.scan_batch.items) |m| if (m) |sc| {
            var x = sc;
            x.index.deinit();
            self.gpa.destroy(x);
        };
        self.scan_batch.deinit(self.gpa);
        self.gpa.free(self.zig);
        self.gpa.free(self.step);
        _ = self.ui.tree.destroySubtree(self.node);
        self.gpa.destroy(self);
    }

    fn dropIndex(self: *TestPanel) void {
        for (self.detail_text) |d| if (d) |t| self.gpa.free(t);
        self.gpa.free(self.detail_text);
        self.gpa.free(self.status);
        self.gpa.free(self.test_item);
        self.detail_text = &.{};
        self.status = &.{};
        self.test_item = &.{};
        if (self.index) |*i| i.deinit();
        self.index = null;
    }

    pub fn running(self: *const TestPanel) bool {
        return self.runner != null;
    }

    /// Look for tests again soon.
    pub fn refresh(self: *TestPanel) void {
        self.scan_pending = true;
    }

    fn say(self: *TestPanel, comptime fmt: []const u8, args: anytype) void {
        var buf: [300]u8 = undefined;
        self.summary.setText(std.fmt.bufPrint(&buf, fmt, args) catch "") catch {};
    }

    // ---- discovery ----

    fn scanThread(self: *TestPanel) void {
        defer self.scan_busy.store(false, .release);
        const result = self.scanNow() catch null;
        self.scan_queue.push(result) catch {
            if (result) |r| {
                var rr = r;
                rr.index.deinit();
                self.gpa.destroy(rr);
            }
        };
    }

    fn scanNow(self: *TestPanel) !*Scanned {
        const index = try ts.scan(self.gpa, self.io, self.project.dir);
        const s = try self.gpa.create(Scanned);
        s.* = .{ .index = index, .filter_ok = false, .has_build = self.project.hasBuildZig() };
        if (s.has_build) {
            // Does this build take -Dtest-filter? (It lists its options in `zig build --help`.)
            if (std.process.run(self.gpa, self.io, .{
                .argv = &.{ self.zig, "build", "--help" },
                .cwd = .{ .path = self.project.root },
                .timeout = .{ .duration = .{ .raw = .fromSeconds(60), .clock = .awake } },
            })) |res| {
                defer self.gpa.free(res.stdout);
                defer self.gpa.free(res.stderr);
                s.filter_ok = std.mem.indexOf(u8, res.stdout, "-Dtest-filter") != null;
            } else |_| {}
        }
        return s;
    }

    fn startScan(self: *TestPanel) void {
        if (self.scan_busy.load(.acquire)) return;
        if (self.scan_thread) |t| t.join();
        self.scan_thread = null;
        self.scan_busy.store(true, .release);
        self.scan_thread = std.Thread.spawn(.{}, scanThread, .{self}) catch {
            self.scan_busy.store(false, .release);
            return;
        };
    }

    /// Put a finished scan in place, keeping the statuses of tests that are still there.
    fn adopt(self: *TestPanel, s: *Scanned) void {
        defer self.gpa.destroy(s);
        self.filter_ok = s.filter_ok;
        self.has_build = s.has_build;
        const n = s.index.tests.len;
        const status = self.gpa.alloc(ts.Status, n) catch {
            s.index.deinit();
            return;
        };
        @memset(status, .unknown);
        const details = self.gpa.alloc(?[]u8, n) catch {
            self.gpa.free(status);
            s.index.deinit();
            return;
        };
        @memset(details, null);
        if (self.index) |old| {
            for (s.index.tests, 0..) |t, i| {
                for (old.tests, 0..) |o, j| {
                    if (o.kind == t.kind and o.index == t.index and std.mem.eql(u8, o.file, t.file) and std.mem.eql(u8, o.name, t.name)) {
                        status[i] = self.status[j];
                        if (self.detail_text[j]) |d| details[i] = self.gpa.dupe(u8, d) catch null;
                        break;
                    }
                }
            }
        }
        self.dropIndex();
        self.index = s.index;
        self.status = status;
        self.detail_text = details;
        self.scanned_once = true;
        self.rebuildTree();
        self.updateSummary();
    }

    // ---- the tree ----

    fn marker(s: ts.Status) []const u8 {
        return switch (s) {
            .unknown => "[ ]",
            .running => "[..]",
            .passed => "[ok]",
            .failed => "[FAIL]",
            .skipped => "[skip]",
        };
    }

    fn testLabel(self: *const TestPanel, i: usize, buf: []u8) []const u8 {
        const t = self.index.?.tests[i];
        const name: []const u8 = switch (t.kind) {
            .named => t.name,
            .decl => t.name,
            .unnamed => "(unnamed test)",
        };
        return std.fmt.bufPrint(buf, "{s} {s}{s}", .{ marker(self.status[i]), if (t.kind == .decl) "decl " else "", name }) catch name;
    }

    fn rebuildTree(self: *TestPanel) void {
        // Keep the selection across the rebuild.
        var keep: ?usize = null;
        if (self.selectedTest()) |i| keep = i;
        self.list.clear();
        self.file_item.clearRetainingCapacity();
        const idx = self.index orelse return;
        self.gpa.free(self.test_item);
        self.test_item = self.gpa.alloc(u32, idx.tests.len) catch &.{};
        if (self.test_item.len != idx.tests.len) return;
        var group: u32 = tree_view.no_item;
        var current: []const u8 = "";
        for (idx.tests, 0..) |t, i| {
            if (group == tree_view.no_item or !std.mem.eql(u8, current, t.file)) {
                group = self.list.addItem(tree_view.no_item, t.file) catch return;
                self.list.setUserData(group, group_flag | @as(u64, @intCast(self.file_item.items.len)));
                self.file_item.append(self.gpa, .{ .file = t.file, .id = group }) catch return;
                self.list.setExpanded(group, true);
                current = t.file;
            }
            var buf: [400]u8 = undefined;
            const id = self.list.addItem(group, self.testLabel(i, &buf)) catch return;
            self.list.setUserData(id, i);
            self.test_item[i] = id;
        }
        if (keep) |k| if (k < self.test_item.len) self.list.select(self.test_item[k]);
        self.updateGroupLabels();
        self.updateButtons();
    }

    fn setItemStatus(self: *TestPanel, i: usize) void {
        if (i >= self.test_item.len) return;
        var buf: [400]u8 = undefined;
        self.list.setItemText(self.test_item[i], self.testLabel(i, &buf)) catch {};
    }

    fn updateGroupLabels(self: *TestPanel) void {
        const idx = self.index orelse return;
        for (self.file_item.items) |g| {
            var total: usize = 0;
            var failed: usize = 0;
            var passed: usize = 0;
            for (idx.tests, 0..) |t, i| {
                if (!std.mem.eql(u8, t.file, g.file)) continue;
                total += 1;
                if (self.status[i] == .failed) failed += 1;
                if (self.status[i] == .passed) passed += 1;
            }
            var buf: [400]u8 = undefined;
            const text = if (failed > 0)
                std.fmt.bufPrint(&buf, "{s}  ({d} tests, {d} failed)", .{ g.file, total, failed }) catch g.file
            else if (passed == total and total > 0)
                std.fmt.bufPrint(&buf, "{s}  ({d} tests, all passed)", .{ g.file, total }) catch g.file
            else
                std.fmt.bufPrint(&buf, "{s}  ({d} tests)", .{ g.file, total }) catch g.file;
            self.list.setItemText(g.id, text) catch {};
        }
    }

    fn updateSummary(self: *TestPanel) void {
        const idx = self.index orelse return;
        var c: [5]usize = @splat(0);
        for (self.status) |s| c[@intFromEnum(s)] += 1;
        if (idx.tests.len == 0) return self.say("No tests found in the project's .zig files.", .{});
        if (self.runner != null) {
            return self.say("Running {s} ...  {d} passed, {d} failed so far", .{ self.run_label[0..self.run_label_len], c[@intFromEnum(ts.Status.passed)], c[@intFromEnum(ts.Status.failed)] });
        }
        self.say("{d} tests: {d} passed, {d} failed, {d} skipped, {d} not run", .{ idx.tests.len, c[@intFromEnum(ts.Status.passed)], c[@intFromEnum(ts.Status.failed)], c[@intFromEnum(ts.Status.skipped)], c[@intFromEnum(ts.Status.unknown)] + c[@intFromEnum(ts.Status.running)] });
    }

    fn selectedTest(self: *const TestPanel) ?usize {
        const id = self.list.selected();
        if (id == tree_view.no_item or !self.list.exists(id)) return null;
        const code = self.list.userData(id);
        if (code & group_flag != 0) return null;
        return if (self.index != null and code < self.index.?.tests.len) @intCast(code) else null;
    }

    fn selectedFile(self: *const TestPanel) ?[]const u8 {
        const id = self.list.selected();
        if (id == tree_view.no_item or !self.list.exists(id)) return null;
        const code = self.list.userData(id);
        if (code & group_flag == 0) {
            const i = self.selectedTest() orelse return null;
            return self.index.?.tests[i].file;
        }
        const g: usize = @intCast(code & ~group_flag);
        return if (g < self.file_item.items.len) self.file_item.items[g].file else null;
    }

    fn updateButtons(self: *TestPanel) void {
        const busy = self.runner != null;
        self.run_btn.setEnabled(!busy and self.selectedFile() != null);
        var any_failed = false;
        for (self.status) |s| {
            if (s == .failed) any_failed = true;
        }
        self.failed_btn.setEnabled(!busy and any_failed and self.filter_ok);
        self.all_btn.setEnabled(!busy);
        self.stop_btn.setEnabled(busy);
    }

    fn showDetail(self: *TestPanel) void {
        var text: []const u8 = "";
        if (self.selectedTest()) |i| {
            const t = self.index.?.tests[i];
            if (self.detail_text[i]) |d| {
                text = d;
            } else {
                text = switch (self.status[i]) {
                    .passed => "passed",
                    .skipped => "skipped",
                    .running => "running...",
                    else => "not run yet",
                };
            }
            _ = t;
        } else if (self.run_text.items.len > 0) {
            text = self.run_text.items;
        } else {
            text = "Select a test to see its result, or run the tests to see the output here.";
        }
        const copy = self.gpa.dupe(u8, text) catch return;
        self.detail.loadText(copy, true) catch self.gpa.free(copy);
    }

    // ---- running ----

    fn testsOfFile(self: *TestPanel, file: []const u8, out: *std.ArrayListUnmanaged(usize)) void {
        const idx = self.index orelse return;
        for (idx.tests, 0..) |t, i| {
            if (std.mem.eql(u8, t.file, file)) out.append(self.gpa, i) catch {};
        }
    }

    /// Start a run of `scope`. Reports why when it cannot.
    pub fn run(self: *TestPanel, scope: Scope) void {
        if (self.runner != null) return;
        const idx = self.index orelse return self.say("Still looking for tests...", .{});
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        var argv: std.ArrayListUnmanaged([]const u8) = .empty;
        var covered: std.ArrayListUnmanaged(usize) = .empty;
        defer covered.deinit(self.gpa);
        var mode: ts.Mode = .build;
        var label: []const u8 = "all tests";

        switch (scope) {
            .all => {
                if (!self.has_build) return self.say("Run All needs a build.zig with a test step (select a file to run it with `zig test`).", .{});
                argv.appendSlice(a, &.{ self.zig, "build", self.step, "--summary", "all", "--color", "off" }) catch return;
                for (idx.tests, 0..) |_, i| covered.append(self.gpa, i) catch {};
            },
            .file => |file| {
                self.testsOfFile(file, &covered);
                label = file;
                if (self.has_build and self.filter_ok) {
                    const f = std.fmt.allocPrint(a, "-Dtest-filter={s}.", .{ts.stem(file)}) catch return;
                    argv.appendSlice(a, &.{ self.zig, "build", self.step, f, "--summary", "all", "--color", "off" }) catch return;
                } else {
                    mode = .direct;
                    const abs = self.project.absPath(a, file) catch return;
                    argv.appendSlice(a, &.{ self.zig, "test", abs }) catch return;
                }
            },
            .one => |i| {
                const t = idx.tests[i];
                covered.append(self.gpa, i) catch {};
                label = if (t.kind == .unnamed) "an unnamed test" else t.name;
                const full = ts.fullName(a, t) catch return;
                if (self.has_build and self.filter_ok) {
                    const f = std.fmt.allocPrint(a, "-Dtest-filter={s}", .{full}) catch return;
                    argv.appendSlice(a, &.{ self.zig, "build", self.step, f, "--summary", "all", "--color", "off" }) catch return;
                } else {
                    mode = .direct;
                    const abs = self.project.absPath(a, t.file) catch return;
                    argv.appendSlice(a, &.{ self.zig, "test", abs, "--test-filter", full }) catch return;
                }
            },
            .failed => {
                if (!(self.has_build and self.filter_ok)) return self.say("Run Failed needs a build.zig that accepts -Dtest-filter.", .{});
                argv.appendSlice(a, &.{ self.zig, "build", self.step }) catch return;
                for (idx.tests, 0..) |t, i| {
                    if (self.status[i] != .failed) continue;
                    covered.append(self.gpa, i) catch {};
                    const full = ts.fullName(a, t) catch return;
                    const f = std.fmt.allocPrint(a, "-Dtest-filter={s}", .{full}) catch return;
                    argv.append(a, f) catch return;
                }
                argv.appendSlice(a, &.{ "--summary", "all", "--color", "off" }) catch return;
                label = "failed tests";
            },
        }
        if (covered.items.len == 0) return self.say("No tests to run.", .{});

        self.run_text.clearRetainingCapacity();
        const echo = std.mem.join(a, " ", argv.items) catch "";
        self.run_text.print(self.gpa, "$ {s}\n", .{echo}) catch {};
        self.runner = process.Runner.start(self.gpa, self.io, .{ .argv = argv.items, .cwd = self.project.root, .wake = self.wake }) catch |err| {
            return self.say("could not start {s}: {s}", .{ self.zig, @errorName(err) });
        };
        if (self.parser) |*p| p.deinit();
        self.parser = ts.Parser.init(self.gpa, mode);
        self.run_mode = mode;
        self.exit_ok = false;
        self.scope_tests.clearRetainingCapacity();
        for (covered.items) |i| {
            self.scope_tests.append(self.gpa, i) catch {};
            self.status[i] = .running;
            if (self.detail_text[i]) |d| self.gpa.free(d);
            self.detail_text[i] = null;
            self.setItemStatus(i);
        }
        const n = @min(label.len, self.run_label.len);
        @memcpy(self.run_label[0..n], label[0..n]);
        self.run_label_len = n;
        self.updateGroupLabels();
        self.updateButtons();
        self.updateSummary();
    }

    pub fn stop(self: *TestPanel) void {
        if (self.runner) |r| r.stop();
    }

    /// Apply what the parser has seen so far to the tests (live for `zig test`).
    fn applyOutcomes(self: *TestPanel, final: bool) void {
        const p = &(self.parser orelse return);
        const idx = self.index orelse return;
        for (p.outcomes.items) |o| {
            for (idx.tests, 0..) |t, i| {
                if (!ts.matches(t, o.name)) continue;
                if (self.run_mode == .build and o.status == .running) continue;
                const st = if (o.status == .running and !final) ts.Status.running else o.status;
                if (self.status[i] == st and st != .failed) continue;
                self.status[i] = if (st == .running and final) .failed else st;
                if (o.detail.items.len > 0 and (st == .failed)) {
                    if (self.detail_text[i]) |d| self.gpa.free(d);
                    self.detail_text[i] = self.gpa.dupe(u8, o.detail.items) catch null;
                }
                self.setItemStatus(i);
            }
        }
    }

    fn finishRun(self: *TestPanel, code: ?u8) void {
        if (self.parser) |*p| {
            p.finish() catch {};
            self.applyOutcomes(true);
            const had_summary = p.summary != null;
            // A build run only names the failures: the rest of what it covered passed, if the tests ran.
            if (self.run_mode == .build) {
                for (self.scope_tests.items) |i| {
                    if (self.status[i] != .running) continue;
                    self.status[i] = if (had_summary or code == 0) .passed else .unknown;
                    self.setItemStatus(i);
                }
            }
            // In a direct run anything still marked running was filtered out or never reached.
            for (self.scope_tests.items) |i| {
                if (self.status[i] == .running) {
                    self.status[i] = .unknown;
                    self.setItemStatus(i);
                }
            }
        }
        if (self.runner) |r| r.destroy();
        self.runner = null;
        self.updateGroupLabels();
        self.updateButtons();
        self.updateSummary();
        if (self.selectedTest() == null) self.showDetail();
        if (self.selectedTest() != null) self.showDetail();
        // A run that did not get to run any test (a compile error) shows its output.
        var any_result = false;
        for (self.scope_tests.items) |i| {
            if (self.status[i] != .unknown) any_result = true;
        }
        if (!any_result and self.scope_tests.items.len > 0) self.say("The tests did not run (see the output below).", .{});
    }

    // ---- polling ----

    /// Call every loop iteration.
    pub fn poll(self: *TestPanel) void {
        self.scan_queue.drain(&self.scan_batch);
        for (self.scan_batch.items) |m| {
            if (m) |s| self.adopt(s);
        }
        self.scan_batch.clearRetainingCapacity();
        if (self.scan_pending and !self.scan_busy.load(.acquire)) {
            const now = self.ui.now_ms;
            if (!self.scanned_once or now -% self.last_scan_ms > 1500) {
                self.scan_pending = false;
                self.last_scan_ms = now;
                self.startScan();
            }
        }
        const r = self.runner orelse return;
        r.drain(&self.batch);
        var exited: ?u8 = null;
        var ended = false;
        for (self.batch.items) |*e| {
            switch (e.*) {
                .chunk => |c| {
                    if (self.run_text.items.len < max_output) self.run_text.appendSlice(self.gpa, c.bytes) catch {};
                    if (self.parser) |*p| p.feed(c.bytes) catch {};
                },
                .exited => |term| {
                    ended = true;
                    exited = switch (term) {
                        .exited => |code| code,
                        else => null,
                    };
                },
            }
            e.deinit(self.gpa);
        }
        self.batch.clearRetainingCapacity();
        self.applyOutcomes(false);
        if (ended) {
            self.finishRun(exited);
        } else {
            self.updateGroupLabels();
            self.updateSummary();
        }
    }

    // ---- events ----

    fn onSelect(self: *TestPanel, _: *event.Event) void {
        self.updateButtons();
        self.showDetail();
    }

    fn onActivate(self: *TestPanel, _: *event.Event) void {
        const i = self.selectedTest() orelse return;
        const t = self.index.?.tests[i];
        const hook = self.on_open orelse return;
        const abs = self.project.absPath(self.gpa, t.file) catch return;
        defer self.gpa.free(abs);
        hook.call(hook.ctx, abs, t.line, 1);
    }

    fn onRunAll(self: *TestPanel, _: *event.Event) void {
        self.run(.all);
    }

    fn onRun(self: *TestPanel, _: *event.Event) void {
        if (self.selectedTest()) |i| return self.run(.{ .one = i });
        if (self.selectedFile()) |f| self.run(.{ .file = f });
    }

    fn onRunFailed(self: *TestPanel, _: *event.Event) void {
        self.run(.failed);
    }

    fn onStop(self: *TestPanel, _: *event.Event) void {
        self.stop();
    }

    fn onRefresh(self: *TestPanel, _: *event.Event) void {
        self.refresh();
    }
};

// ---- tests -----------------------------------------------------------------

const testing = std.testing;
const builtin = @import("builtin");
const Rig = @import("../core/test_rig.zig").Rig;

fn pump(r: *Rig, tp: *TestPanel, tries: usize, cond: *const fn (*TestPanel) bool) !void {
    var i: usize = 0;
    while (i < tries and !cond(tp)) : (i += 1) {
        tp.poll();
        try r.frame();
        @import("../platform/pty_common.zig").sleepMs(2);
    }
}

fn scanned(tp: *TestPanel) bool {
    return tp.scanned_once;
}

fn runDone(tp: *TestPanel) bool {
    return tp.runner == null;
}

test "the panel lists tests by file, runs a file with zig test, and shows live statuses and failure details" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var p = try project_mod.testProject(&tmp);
    defer p.close();
    // The scratch project's own src/main.zig is replaced by one with three tests.
    try p.writeFile("src/main.zig",
        \\const std = @import("std");
        \\test "passes" { try std.testing.expectEqual(@as(i32, 3), 1 + 2); }
        \\test "fails" { try std.testing.expectEqual(@as(i32, 4), 1 + 2); }
        \\test "skips" { return error.SkipZigTest; }
        \\
    );
    const r = try Rig.init();
    defer r.deinit();
    const tp = try TestPanel.create(&r.ui, r.ui.tree.root, testing.io, &p, .{});
    defer tp.destroy();
    try r.frame();
    try pump(r, tp, 6000, scanned);
    try testing.expect(tp.scanned_once);
    try testing.expectEqual(@as(usize, 3), tp.index.?.tests.len);
    const tv = tp.list;
    // One file group holding three tests, all "not run".
    try testing.expectEqual(@as(usize, 1), tv.childCount(tree_view.no_item));
    const group = tv.childAt(tree_view.no_item, 0);
    try testing.expectEqual(@as(usize, 3), tv.childCount(group));
    try testing.expectEqualStrings("[ ] passes", tv.itemText(tv.childAt(group, 0)));

    // Run the file. (testProject has a build.zig without a test-filter option, so this is `zig test`.)
    tv.select(group);
    tp.onSelect(undefined);
    try testing.expect(tp.run_btn.props.enabled);
    tp.onRun(undefined);
    if (!tp.running()) return error.SkipZigTest; // no zig on PATH
    try pump(r, tp, 20000, runDone);
    try testing.expect(!tp.running());
    try testing.expectEqualStrings("[ok] passes", tv.itemText(tv.childAt(group, 0)));
    try testing.expectEqualStrings("[FAIL] fails", tv.itemText(tv.childAt(group, 1)));
    try testing.expectEqualStrings("[skip] skips", tv.itemText(tv.childAt(group, 2)));
    try testing.expect(std.mem.indexOf(u8, tv.itemText(group), "1 failed") != null);

    // Selecting the failed test shows why.
    tv.select(tv.childAt(group, 1));
    tp.onSelect(undefined);
    const shown = try tp.detail.editor.doc.textAlloc(testing.allocator, 0, tp.detail.editor.doc.len());
    defer testing.allocator.free(shown);
    try testing.expect(std.mem.indexOf(u8, shown, "expected 4, found 3") != null);
    try testing.expect(tp.failed_btn.props.enabled == tp.filter_ok);

    // A single test runs on its own (`--test-filter`) and the others keep their status.
    tv.select(tv.childAt(group, 0));
    tp.onRun(undefined);
    try pump(r, tp, 20000, runDone);
    try testing.expectEqualStrings("[ok] passes", tv.itemText(tv.childAt(group, 0)));
    try testing.expectEqualStrings("[FAIL] fails", tv.itemText(tv.childAt(group, 1)));
}

test "Run All needs a build.zig, and says so" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "a.zig", .data = "test \"x\" {}\n" });
    const dir = try tmp.dir.openDir(testing.io, ".", .{ .iterate = true });
    var p = try project_mod.Project.fromDir(testing.allocator, testing.io, dir);
    defer p.close();
    const r = try Rig.init();
    defer r.deinit();
    const tp = try TestPanel.create(&r.ui, r.ui.tree.root, testing.io, &p, .{});
    defer tp.destroy();
    try r.frame();
    try pump(r, tp, 6000, scanned);
    tp.run(.all);
    try testing.expect(!tp.running());
    try testing.expect(std.mem.indexOf(u8, tp.summary.props.text.bytes, "needs a build.zig") != null);
}
