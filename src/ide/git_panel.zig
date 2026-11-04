//! The Git panel: the repository's changes in three groups (staged, changes,
//! untracked, and conflicts when there are any), the diff of the selected file,
//! and buttons to stage, unstage, discard, commit, stash and push. It talks to
//! the `git` program through `git.zig` and shows nothing but a note when the
//! project is not in a repository.
//!
//!     const gp = try GitPanel.create(&ui, parent, io, project.root, .{ .on_open = OpenHook.bind(&app, App.openAt),
//!                                      .overlay = ui.tree.root, .environ = env, .wake = sdl.wake });
//!     defer gp.destroy();
//!     gp.refresh();           // when the panel is shown, after saving, ...
//!     gp.poll();              // each loop iteration
//!
//! Double-clicking a file opens it. Discard (restoring a file or deleting an
//! untracked one) asks first. The panel refreshes itself every few seconds.
//! IDE-level code: it builds on `Git`, `TreeView`, `CodeEditor` and `MessageBox`.

const std = @import("std");
const Handle = @import("../core/handle.zig").Handle;
const Ui = @import("../core/ui.zig").Ui;
const event = @import("../core/event.zig");
const Style = @import("../core/style.zig").Style;
const Edges = @import("../core/style.zig").Edges;
const Length = @import("../core/length.zig").Length;
const tree_view = @import("../widgets/tree_view.zig");
const TreeView = tree_view.TreeView;
const Button = @import("../widgets/button.zig").Button;
const Label = @import("../widgets/label.zig").Label;
const TextField = @import("../widgets/text_field.zig").TextField;
const CodeEditor = @import("../widgets/code_editor.zig").CodeEditor;
const Decoration = @import("../widgets/code_editor.zig").Decoration;
const MessageBox = @import("../widgets/message_box.zig").MessageBox;
const output_panel = @import("output_panel.zig");
const git = @import("git.zig");

pub const OpenHook = output_panel.OpenHook;

pub const Options = struct {
    style: Style = .{},
    /// Called with an absolute path (line and column 1) to open a file.
    on_open: ?OpenHook = null,
    /// Where the Discard question goes (the window's root node).
    overlay: ?Handle = null,
    environ: ?*const std.process.Environ.Map = null,
    wake: ?*const fn () void = null,
};

const Section = enum(u8) { conflicts, staged, changes, untracked };
const section_title = [_][]const u8{ "Merge Conflicts", "Staged Changes", "Changes", "Untracked Files" };
const no_row: u64 = std.math.maxInt(u64);

/// How often the status is read again on its own (milliseconds).
const auto_refresh_ms: u64 = 5000;
const max_diff_bytes = 1 << 20;

pub const GitPanel = struct {
    gpa: std.mem.Allocator,
    ui: *Ui,
    node: Handle,
    git: *git.Git,
    on_open: ?OpenHook,
    box: ?*MessageBox,
    // Widgets.
    body: Handle,
    branch: *Label,
    push_btn: *Button,
    list: *TreeView,
    stage_btn: *Button,
    unstage_btn: *Button,
    discard_btn: *Button,
    diff: *CodeEditor,
    message: *TextField,
    status_line: *Label,
    stash_label: *Label,
    // State.
    status: ?*git.Status = null,
    /// True when the folder is not in a repository (or git is missing): only a note shows.
    no_repo: bool = false,
    refresh_pending: bool = true,
    diff_pending: bool = false,
    last_refresh_ms: u64 = 0,
    /// The row the diff belongs to.
    shown_path: ?[]u8 = null,
    shown_section: Section = .changes,
    /// What a pending Discard confirmation is about.
    discard_path: ?[]u8 = null,
    discard_untracked: bool = false,

    pub fn create(ui: *Ui, parent: Handle, io: std.Io, root: []const u8, opts: Options) !*GitPanel {
        const self = try ui.gpa.create(GitPanel);
        errdefer ui.gpa.destroy(self);
        const g = try git.Git.init(ui.gpa, io, root, opts.environ, opts.wake);
        errdefer g.deinit();
        var style = opts.style;
        style.direction = .column;
        if (std.meta.eql(style.padding, .{})) style.padding = Edges.all(6);
        style.gap = Length.px(4);
        if (style.grow == 0) style.grow = 1;
        const node = try ui.tree.create(.{ .style = style, .role = .panel });
        errdefer _ = ui.tree.destroySubtree(node);
        try ui.tree.appendChild(parent, node);
        try ui.tree.setLabel(node, "Git");

        const pad = Edges.xy(8, 4);
        const branch = try ui.add(Label, node, .{ .text = "Git", .style = .{ .shrink = 0 } });
        const top = try ui.tree.create(.{ .style = .{ .direction = .row, .gap = Length.px(4), .align_items = .center, .shrink = 0 } });
        try ui.tree.appendChild(node, top);
        _ = try ui.add(Button, top, .{ .text = "Refresh", .variant = .flat, .style = .{ .padding = pad }, .on_click = .bind(self, onRefresh) });
        const push_btn = try ui.add(Button, top, .{ .text = "Push", .variant = .flat, .style = .{ .padding = pad }, .on_click = .bind(self, onPush) });

        // Everything else hides when there is no repository.
        const body = try ui.tree.create(.{ .style = .{ .direction = .column, .gap = Length.px(4), .grow = 1 } });
        try ui.tree.appendChild(node, body);
        const list = try ui.add(TreeView, body, .{
            .style = .{ .grow = 1, .min_height = Length.px(90) },
            .label = "Changes",
            .activate_toggles = false,
            .on_select = .bind(self, onSelect),
            .on_activate = .bind(self, onActivate),
        });
        const acts = try ui.tree.create(.{ .style = .{ .direction = .row, .gap = Length.px(4), .shrink = 0 } });
        try ui.tree.appendChild(body, acts);
        const stage_btn = try ui.add(Button, acts, .{ .text = "Stage", .variant = .flat, .style = .{ .padding = pad }, .enabled = false, .on_click = .bind(self, onStage) });
        const unstage_btn = try ui.add(Button, acts, .{ .text = "Unstage", .variant = .flat, .style = .{ .padding = pad }, .enabled = false, .on_click = .bind(self, onUnstage) });
        const discard_btn = try ui.add(Button, acts, .{ .text = "Discard", .variant = .flat, .style = .{ .padding = pad }, .enabled = false, .on_click = .bind(self, onDiscard) });
        const acts2 = try ui.tree.create(.{ .style = .{ .direction = .row, .gap = Length.px(4), .shrink = 0 } });
        try ui.tree.appendChild(body, acts2);
        _ = try ui.add(Button, acts2, .{ .text = "Stage All", .variant = .flat, .style = .{ .padding = pad }, .on_click = .bind(self, onStageAll) });
        _ = try ui.add(Button, acts2, .{ .text = "Unstage All", .variant = .flat, .style = .{ .padding = pad }, .on_click = .bind(self, onUnstageAll) });
        const diff = try ui.add(CodeEditor, body, .{
            .style = .{ .grow = 2, .min_height = Length.px(80) },
            .label = "Diff",
            .read_only = true,
            .line_numbers = false,
            .auto_indent = false,
            .size = 13,
            .language = &@import("../editor/syntax.zig").plain,
        });
        const commit_row = try ui.tree.create(.{ .style = .{ .direction = .row, .gap = Length.px(4), .align_items = .center, .shrink = 0 } });
        try ui.tree.appendChild(body, commit_row);
        const message = try ui.add(TextField, commit_row, .{ .placeholder = "Message (commit or stash)", .label = "Commit message", .style = .{ .grow = 1 }, .on_submit = .bind(self, onCommit) });
        _ = try ui.add(Button, commit_row, .{ .text = "Commit", .variant = .primary, .style = .{ .padding = pad }, .on_click = .bind(self, onCommit) });
        const stash_row = try ui.tree.create(.{ .style = .{ .direction = .row, .gap = Length.px(4), .align_items = .center, .shrink = 0 } });
        try ui.tree.appendChild(body, stash_row);
        _ = try ui.add(Button, stash_row, .{ .text = "Stash", .variant = .flat, .style = .{ .padding = pad }, .on_click = .bind(self, onStash) });
        _ = try ui.add(Button, stash_row, .{ .text = "Pop Stash", .variant = .flat, .style = .{ .padding = pad }, .on_click = .bind(self, onPop) });
        const stash_label = try ui.add(Label, stash_row, .{ .text = "", .style = .{ .grow = 1 } });
        const status_line = try ui.add(Label, node, .{ .text = "", .style = .{ .shrink = 0 } });

        const box: ?*MessageBox = if (opts.overlay) |o| try MessageBox.create(ui, o) else null;
        self.* = .{
            .gpa = ui.gpa,
            .ui = ui,
            .node = node,
            .git = g,
            .on_open = opts.on_open,
            .box = box,
            .body = body,
            .branch = branch,
            .push_btn = push_btn,
            .list = list,
            .stage_btn = stage_btn,
            .unstage_btn = unstage_btn,
            .discard_btn = discard_btn,
            .diff = diff,
            .message = message,
            .status_line = status_line,
            .stash_label = stash_label,
        };
        return self;
    }

    pub fn destroy(self: *GitPanel) void {
        if (self.box) |b| b.destroy();
        self.git.deinit();
        self.dropStatus();
        if (self.shown_path) |p| self.gpa.free(p);
        if (self.discard_path) |p| self.gpa.free(p);
        _ = self.ui.tree.destroySubtree(self.node);
        self.gpa.destroy(self);
    }

    fn dropStatus(self: *GitPanel) void {
        if (self.status) |s| {
            s.deinit();
            self.gpa.destroy(s);
            self.status = null;
        }
    }

    pub fn say(self: *GitPanel, comptime fmt: []const u8, args: anytype) void {
        var buf: [300]u8 = undefined;
        self.status_line.setText(std.fmt.bufPrint(&buf, fmt, args) catch "") catch {};
    }

    /// Read the repository's status again (soon, if a job is running).
    pub fn refresh(self: *GitPanel) void {
        self.refresh_pending = true;
    }

    pub fn inRepo(self: *const GitPanel) bool {
        return self.status != null;
    }

    // ---- rows ----

    fn rowCode(section: Section, index: usize) u64 {
        return (@as(u64, @intFromEnum(section)) << 32) | @as(u64, @intCast(index));
    }

    const Row = struct { section: Section, entry: git.Entry };

    fn rowOf(self: *const GitPanel, id: u32) ?Row {
        const st = self.status orelse return null;
        if (id == tree_view.no_item or !self.list.exists(id)) return null;
        const code = self.list.userData(id);
        if (code == no_row) return null;
        const index: usize = @intCast(code & 0xffff_ffff);
        if (index >= st.entries.len) return null;
        const sec: Section = @enumFromInt(@as(u8, @intCast(code >> 32)));
        return .{ .section = sec, .entry = st.entries[index] };
    }

    fn selectedRow(self: *const GitPanel) ?Row {
        return self.rowOf(self.list.selected());
    }

    fn inSection(e: git.Entry, s: Section) bool {
        return switch (s) {
            .conflicts => e.conflicted(),
            .staged => e.staged(),
            .changes => e.changed(),
            .untracked => e.untracked(),
        };
    }

    fn statusLetter(row: Row) u8 {
        return switch (row.section) {
            .staged => row.entry.x,
            .changes => row.entry.y,
            .untracked => 'U',
            .conflicts => '!',
        };
    }

    fn rebuildList(self: *GitPanel) void {
        // Remember what was selected so a refresh does not lose the place.
        var keep_path: ?[]u8 = null;
        defer if (keep_path) |p| self.gpa.free(p);
        var keep_section: Section = .changes;
        if (self.selectedRow()) |r| {
            keep_path = self.gpa.dupe(u8, r.entry.path) catch null;
            keep_section = r.section;
        }
        self.list.clear();
        const st = self.status orelse return;
        var reselect: u32 = tree_view.no_item;
        inline for ([_]Section{ .conflicts, .staged, .changes, .untracked }) |sec| {
            var n: usize = 0;
            for (st.entries) |e| {
                if (inSection(e, sec)) n += 1;
            }
            if (n > 0) {
                var buf: [64]u8 = undefined;
                const title = std.fmt.bufPrint(&buf, "{s} ({d})", .{ section_title[@intFromEnum(sec)], n }) catch section_title[@intFromEnum(sec)];
                if (self.list.addItem(tree_view.no_item, title)) |parent| {
                    self.list.setUserData(parent, no_row);
                    self.list.setExpanded(parent, true);
                    for (st.entries, 0..) |e, i| {
                        if (!inSection(e, sec)) continue;
                        var lbuf: [512]u8 = undefined;
                        const row: Row = .{ .section = sec, .entry = e };
                        const label = if (e.orig) |o|
                            std.fmt.bufPrint(&lbuf, "{c}  {s}  <- {s}", .{ statusLetter(row), e.path, o }) catch e.path
                        else
                            std.fmt.bufPrint(&lbuf, "{c}  {s}", .{ statusLetter(row), e.path }) catch e.path;
                        if (self.list.addItem(parent, label)) |id| {
                            self.list.setUserData(id, rowCode(sec, i));
                            if (keep_path) |kp| {
                                if (sec == keep_section and std.mem.eql(u8, kp, e.path)) reselect = id;
                            }
                        } else |_| {}
                    }
                } else |_| {}
            }
        }
        if (reselect != tree_view.no_item) self.list.select(reselect);
        self.updateButtons();
    }

    fn updateButtons(self: *GitPanel) void {
        const r = self.selectedRow() orelse {
            self.stage_btn.setEnabled(false);
            self.unstage_btn.setEnabled(false);
            self.discard_btn.setEnabled(false);
            return;
        };
        self.stage_btn.setEnabled(r.section != .staged);
        self.unstage_btn.setEnabled(r.section == .staged);
        self.discard_btn.setEnabled(r.section == .changes or r.section == .untracked);
    }

    fn showHeader(self: *GitPanel) void {
        const st = self.status orelse return;
        var buf: [200]u8 = undefined;
        const text = if (st.upstream) |u|
            std.fmt.bufPrint(&buf, "{s}  ->  {s}   ahead {d}, behind {d}", .{ st.branch, u, st.ahead, st.behind }) catch st.branch
        else
            std.fmt.bufPrint(&buf, "{s}  (no upstream)", .{st.branch}) catch st.branch;
        self.branch.setText(text) catch {};
        self.push_btn.setText(if (st.upstream == null) "Publish Branch" else "Push") catch {};
        var sbuf: [48]u8 = undefined;
        self.stash_label.setText(std.fmt.bufPrint(&sbuf, "{d} stashed", .{st.stashes}) catch "") catch {};
    }

    // ---- polling ----

    /// Call every loop iteration: take finished jobs, start what is waiting.
    pub fn poll(self: *GitPanel) void {
        if (self.git.poll()) |d0| {
            var done = d0;
            defer done.deinit(self.gpa);
            self.handle(&done);
        }
        if (self.git.busy()) return;
        const now = self.ui.now_ms;
        const interval: u64 = if (self.no_repo) auto_refresh_ms * 3 else auto_refresh_ms;
        if (now -% self.last_refresh_ms > interval) self.refresh_pending = true;
        if (self.refresh_pending) {
            self.refresh_pending = false;
            self.last_refresh_ms = now;
            _ = self.git.submit(.{ .kind = .status });
            return;
        }
        if (self.diff_pending) {
            self.diff_pending = false;
            self.requestDiff();
        }
    }

    fn handle(self: *GitPanel, done: *git.Done) void {
        switch (done.kind) {
            .status => {
                if (done.status) |s| {
                    // Take over the status (the Done no longer owns it).
                    self.dropStatus();
                    self.status = s;
                    done.status = null;
                    self.no_repo = false;
                    self.ui.setHidden(self.body, false);
                    self.push_btn.setEnabled(true);
                    self.showHeader();
                    self.rebuildList();
                    self.diff_pending = true;
                } else {
                    self.dropStatus();
                    self.no_repo = true;
                    self.list.clear();
                    self.ui.setHidden(self.body, true);
                    self.push_btn.setEnabled(false);
                    self.branch.setText(if (done.problem.len > 0) done.problem else "not a git repository") catch {};
                }
            },
            .diff => {
                const p = self.shown_path orelse return;
                if (!std.mem.eql(u8, p, done.path)) return; // a newer selection is waiting
                self.showDiff(done.text);
            },
            .action => {
                if (done.ok) {
                    if (std.mem.eql(u8, done.label, "commit")) self.message.setText("") catch {};
                    self.say("{s}: done{s}{s}", .{ done.label, if (done.text.len > 0) " - " else "", firstLine(done.text) });
                } else {
                    self.say("{s} failed: {s}", .{ done.label, firstLine(done.text) });
                }
                self.refresh_pending = true;
            },
        }
    }

    fn firstLine(s: []const u8) []const u8 {
        const nl = std.mem.indexOfScalar(u8, s, '\n') orelse s.len;
        return s[0..@min(nl, 200)];
    }

    // ---- the diff ----

    fn requestDiff(self: *GitPanel) void {
        const row = self.selectedRow() orelse {
            if (self.shown_path) |p| self.gpa.free(p);
            self.shown_path = null;
            self.showDiff("");
            return;
        };
        if (self.shown_path) |p| self.gpa.free(p);
        self.shown_path = self.gpa.dupe(u8, row.entry.path) catch null;
        self.shown_section = row.section;
        _ = self.git.submit(.{
            .kind = .diff,
            .path = row.entry.path,
            .staged = row.section == .staged,
            .untracked = row.section == .untracked,
        });
    }

    fn showDiff(self: *GitPanel, text: []const u8) void {
        var shown = text;
        var truncated = false;
        if (shown.len > max_diff_bytes) {
            shown = shown[0..max_diff_bytes];
            truncated = true;
        }
        const body = if (shown.len == 0) "(no changes to show)" else shown;
        const copy = if (truncated)
            std.fmt.allocPrint(self.gpa, "{s}\n... (diff cut at 1 MiB)\n", .{body}) catch return
        else
            self.gpa.dupe(u8, body) catch return;
        self.diff.loadText(copy, true) catch {
            self.gpa.free(copy);
            return;
        };
        var decos: std.ArrayListUnmanaged(Decoration) = .empty;
        defer decos.deinit(self.gpa);
        var pos: usize = 0;
        while (pos < copy.len) {
            const nl = std.mem.indexOfScalarPos(u8, copy, pos, '\n') orelse copy.len;
            const kind: ?@import("../widgets/code_editor.zig").DecorationKind = switch (git.diffLineKind(copy[pos..nl])) {
                .added => .added_line,
                .removed => .error_line,
                .hunk => .note_line,
                else => null,
            };
            if (kind) |k| decos.append(self.gpa, .{ .start = pos, .end = @max(nl, pos + 1), .kind = k }) catch break;
            pos = nl + 1;
        }
        if (decos.items.len == 0) self.diff.clearDecorations(0) else self.diff.setDecorations(0, decos.items) catch {};
    }

    // ---- events ----

    fn onSelect(self: *GitPanel, _: *event.Event) void {
        self.updateButtons();
        self.diff_pending = true;
    }

    fn onActivate(self: *GitPanel, _: *event.Event) void {
        const row = self.rowOf(self.list.out.activated_item) orelse return;
        const st = self.status orelse return;
        const hook = self.on_open orelse return;
        const abs = std.fs.path.join(self.gpa, &.{ st.top, row.entry.path }) catch return;
        defer self.gpa.free(abs);
        hook.call(hook.ctx, abs, 1, 1);
    }

    fn onRefresh(self: *GitPanel, _: *event.Event) void {
        self.refresh();
    }

    fn start(self: *GitPanel, label: []const u8, args: []const []const u8) void {
        if (!self.git.submit(.{ .kind = .action, .args = args, .label = label })) self.say("git is busy; try again in a moment", .{});
    }

    fn onStage(self: *GitPanel, _: *event.Event) void {
        const r = self.selectedRow() orelse return;
        self.start("stage", &.{ "add", "--", r.entry.path });
    }

    fn onUnstage(self: *GitPanel, _: *event.Event) void {
        const r = self.selectedRow() orelse return;
        const initial = if (self.status) |s| s.initial else false;
        if (initial) {
            self.start("unstage", &.{ "rm", "--cached", "-r", "-q", "--", r.entry.path });
        } else {
            self.start("unstage", &.{ "restore", "--staged", "--", r.entry.path });
        }
    }

    fn onStageAll(self: *GitPanel, _: *event.Event) void {
        self.start("stage all", &.{ "add", "-A" });
    }

    fn onUnstageAll(self: *GitPanel, _: *event.Event) void {
        const initial = if (self.status) |s| s.initial else false;
        if (initial) self.start("unstage all", &.{ "rm", "--cached", "-r", "-q", "--", "." }) else self.start("unstage all", &.{ "restore", "--staged", "--", "." });
    }

    fn onDiscard(self: *GitPanel, _: *event.Event) void {
        const r = self.selectedRow() orelse return;
        if (r.section != .changes and r.section != .untracked) return;
        const box = self.box orelse return;
        if (self.discard_path) |p| self.gpa.free(p);
        self.discard_path = self.gpa.dupe(u8, r.entry.path) catch return;
        self.discard_untracked = r.section == .untracked;
        var buf: [400]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "{s}\n\n{s}\nThis cannot be undone.", .{ r.entry.path, if (r.section == .untracked) "The untracked file will be deleted." else "Your changes to the file will be lost." }) catch "Discard?";
        box.show(.{ .title = "Discard changes?", .message = msg, .buttons = &.{ "Discard", "Cancel" }, .on_choice = .bind(self, onDiscardChoice) });
    }

    fn onDiscardChoice(self: *GitPanel, index: usize) void {
        const path = self.discard_path orelse return;
        if (index != 0) return;
        if (self.discard_untracked) {
            self.start("discard", &.{ "clean", "-f", "-q", "--", path });
        } else {
            self.start("discard", &.{ "restore", "--", path });
        }
    }

    fn onCommit(self: *GitPanel, _: *event.Event) void {
        const st = self.status orelse return;
        if (st.count(.staged) == 0) return self.say("nothing is staged: stage files first", .{});
        const msg = std.mem.trim(u8, self.message.text(), " \t\r\n");
        if (msg.len == 0) return self.say("type a commit message first", .{});
        self.start("commit", &.{ "commit", "-m", msg });
    }

    fn onStash(self: *GitPanel, _: *event.Event) void {
        const msg = std.mem.trim(u8, self.message.text(), " \t\r\n");
        if (msg.len == 0) self.start("stash", &.{ "stash", "push", "-u" }) else self.start("stash", &.{ "stash", "push", "-u", "-m", msg });
    }

    fn onPop(self: *GitPanel, _: *event.Event) void {
        self.start("stash pop", &.{ "stash", "pop" });
    }

    fn onPush(self: *GitPanel, _: *event.Event) void {
        const st = self.status orelse return;
        if (st.upstream == null) self.start("push", &.{ "push", "-u", "origin", st.branch }) else self.start("push", &.{"push"});
    }
};

// ---- tests -----------------------------------------------------------------

const testing = std.testing;
const builtin = @import("builtin");
const Rig = @import("../core/test_rig.zig").Rig;

fn pump(r: *Rig, gp: *GitPanel, tries: usize, cond: *const fn (*GitPanel) bool) !void {
    var i: usize = 0;
    while (i < tries and !cond(gp)) : (i += 1) {
        gp.poll();
        try r.frame();
        @import("../platform/pty_common.zig").sleepMs(2);
    }
}

fn hasRows(gp: *GitPanel) bool {
    return gp.list.childCount(tree_view.no_item) > 0;
}

test "the panel lists changes, shows a diff, stages, unstages and commits" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(testing.io, &buf);
    const root = try testing.allocator.dupe(u8, buf[0..n]);
    defer testing.allocator.free(root);
    // A repository with one commit and then a modified file and a new one.
    {
        const g = try git.Git.init(testing.allocator, testing.io, root, null, null);
        defer g.deinit();
        const i = g.run(&.{ "init", "-q" }) catch return error.SkipZigTest;
        i.deinit(testing.allocator);
        for ([_][]const []const u8{ &.{ "config", "user.email", "t@example.com" }, &.{ "config", "user.name", "T" }, &.{ "config", "commit.gpgsign", "false" } }) |a| (try g.run(a)).deinit(testing.allocator);
        try tmp.dir.writeFile(testing.io, .{ .sub_path = "f.txt", .data = "one\n" });
        (try g.run(&.{ "add", "f.txt" })).deinit(testing.allocator);
        (try g.run(&.{ "commit", "-q", "-m", "first" })).deinit(testing.allocator);
    }
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "f.txt", .data = "one\ntwo\n" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "new.txt", .data = "hello\n" });

    const r = try Rig.init();
    defer r.deinit();
    const gp = try GitPanel.create(&r.ui, r.ui.tree.root, testing.io, root, .{});
    defer gp.destroy();
    try r.frame();
    try pump(r, gp, 3000, hasRows);
    try testing.expect(gp.inRepo());
    const tv = gp.list;
    // Two groups: Changes (f.txt) and Untracked Files (new.txt).
    try testing.expectEqual(@as(usize, 2), tv.childCount(tree_view.no_item));
    try testing.expect(std.mem.startsWith(u8, tv.itemText(tv.childAt(tree_view.no_item, 0)), "Changes (1)"));
    const changed = tv.childAt(tv.childAt(tree_view.no_item, 0), 0);
    try testing.expectEqualStrings("M  f.txt", tv.itemText(changed));

    // Selecting a row shows its diff, with the added line tinted.
    tv.select(changed);
    gp.onSelect(undefined);
    var i: usize = 0;
    while (i < 3000 and gp.diff.decos[0].items.len == 0) : (i += 1) {
        gp.poll();
        try r.frame();
        @import("../platform/pty_common.zig").sleepMs(2);
    }
    const added = blk: {
        for (gp.diff.decos[0].items) |d| if (d.kind == .added_line) break :blk true;
        break :blk false;
    };
    try testing.expect(added);

    // Stage it, and the row moves to Staged Changes.
    gp.onStage(undefined);
    i = 0;
    while (i < 3000 and !(gp.status != null and gp.status.?.count(.staged) == 1)) : (i += 1) {
        gp.poll();
        try r.frame();
        @import("../platform/pty_common.zig").sleepMs(2);
    }
    try testing.expectEqual(@as(usize, 1), gp.status.?.count(.staged));
    try testing.expect(std.mem.startsWith(u8, tv.itemText(tv.childAt(tree_view.no_item, 0)), "Staged Changes (1)"));

    // Commit needs a message; then the staged group is gone.
    gp.onCommit(undefined);
    try testing.expect(std.mem.indexOf(u8, gp.status_line.props.text.bytes, "message") != null);
    try gp.message.setText("second");
    gp.onCommit(undefined);
    i = 0;
    while (i < 3000 and !(gp.status != null and gp.status.?.count(.staged) == 0 and gp.status.?.count(.changed) == 0)) : (i += 1) {
        gp.poll();
        try r.frame();
        @import("../platform/pty_common.zig").sleepMs(2);
    }
    try testing.expectEqual(@as(usize, 0), gp.status.?.count(.staged));
    try testing.expectEqualStrings("", gp.message.text()); // cleared after the commit
}

test "outside a repository only a note shows" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(testing.io, &buf);
    var env = std.process.Environ.Map.init(testing.allocator);
    defer env.deinit();
    try env.put("PATH", "/usr/bin:/bin:/usr/local/bin");
    try env.put("GIT_CEILING_DIRECTORIES", std.fs.path.dirname(buf[0..n]) orelse "/");
    const r = try Rig.init();
    defer r.deinit();
    const gp = try GitPanel.create(&r.ui, r.ui.tree.root, testing.io, buf[0..n], .{ .environ = &env });
    defer gp.destroy();
    try r.frame();
    var i: usize = 0;
    while (i < 3000 and !gp.no_repo) : (i += 1) {
        gp.poll();
        try r.frame();
        @import("../platform/pty_common.zig").sleepMs(2);
    }
    try testing.expect(gp.no_repo and !gp.inRepo());
    try testing.expect(r.ui.tree.get(gp.body).?.flags.hidden);
}
