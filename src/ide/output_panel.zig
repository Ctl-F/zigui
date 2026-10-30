//! The Output panel: runs a command (a build, a program) and shows what it
//! prints, stdout and stderr interleaved as they arrive, in a read-only editor
//! that follows the end. Lines that are compiler diagnostics
//! (`path:line:col: error: ...`) are tinted by severity, and double-clicking one
//! calls `on_open` so the host can show that file at that spot.
//!
//!     const out = try OutputPanel.create(&ui, parent, .{ .on_open = OpenHook.bind(&app, App.openAt) });
//!     defer out.destroy();
//!     try out.run(io, &.{ "zig", "build" }, project_dir, sdl.wake);
//!     // in the event loop, each iteration (a worker wakes it when output arrives):
//!     out.poll();
//!
//! This is IDE-level code: it builds on the framework's `process.Runner`,
//! `CodeEditor`, and the Zig output parser in `buildout.zig`.

const std = @import("std");
const Handle = @import("../core/handle.zig").Handle;
const Ui = @import("../core/ui.zig").Ui;
const event = @import("../core/event.zig");
const Style = @import("../core/style.zig").Style;
const Edges = @import("../core/style.zig").Edges;
const Length = @import("../core/length.zig").Length;
const process = @import("../platform/process.zig");
const Label = @import("../widgets/label.zig").Label;
const Button = @import("../widgets/button.zig").Button;
const code_editor = @import("../widgets/code_editor.zig");
const CodeEditor = code_editor.CodeEditor;
const buildout = @import("buildout.zig");

/// Called when a diagnostic line is activated: show `path` at `line`:`col` (1-based).
pub const OpenHook = struct {
    ctx: ?*anyopaque = null,
    call: *const fn (ctx: ?*anyopaque, path: []const u8, line: u32, col: u32) void,

    pub fn bind(ctx: anytype, comptime f: anytype) OpenHook {
        const Ptr = @TypeOf(ctx);
        return .{
            .ctx = @ptrCast(ctx),
            .call = &struct {
                fn thunk(c: ?*anyopaque, path: []const u8, line: u32, col: u32) void {
                    f(@as(Ptr, @ptrCast(@alignCast(c.?))), path, line, col);
                }
            }.thunk,
        };
    }
};

const LineDiag = struct {
    /// The output line it is on (0-based).
    row: usize,
    path: []u8,
    line: u32,
    col: u32,
    severity: buildout.Severity,
};

pub const Options = struct {
    style: Style = .{},
    on_open: ?OpenHook = null,
};

pub const OutputPanel = struct {
    gpa: std.mem.Allocator,
    ui: *Ui,
    node: Handle,
    editor: *CodeEditor,
    status: *Label,
    stop_btn: *Button,
    clear_btn: *Button,
    on_open: ?OpenHook,
    runner: ?*process.Runner = null,
    batch: std.ArrayListUnmanaged(process.Event) = .empty,
    /// Unfinished line per stream.
    partial: [2]std.ArrayListUnmanaged(u8) = .{ .empty, .empty },
    diags: std.ArrayListUnmanaged(LineDiag) = .empty,
    decos: std.ArrayListUnmanaged(code_editor.Decoration) = .empty,
    title: []u8 = &.{},
    started_ms: u64 = 0,
    /// Exit code of the last run, null while running or never run.
    exit_code: ?u8 = null,
    running: bool = false,

    pub fn create(ui: *Ui, parent: Handle, opts: Options) !*OutputPanel {
        const self = try ui.gpa.create(OutputPanel);
        errdefer ui.gpa.destroy(self);
        var style = opts.style;
        style.direction = .column;
        const node = try ui.tree.create(.{ .style = style, .role = .panel });
        errdefer _ = ui.tree.destroySubtree(node);
        try ui.tree.appendChild(parent, node);
        try ui.tree.setLabel(node, "Output");
        const bar = try ui.tree.create(.{ .style = .{ .direction = .row, .gap = Length.px(6), .align_items = .center, .padding = Edges.xy(6, 4), .shrink = 0 } });
        try ui.tree.appendChild(node, bar);
        const status = try ui.add(Label, bar, .{ .text = "No output yet", .style = .{ .grow = 1 } });
        const stop_btn = try ui.add(Button, bar, .{ .text = "Stop", .variant = .flat, .enabled = false, .on_click = .bind(self, onStop) });
        const clear_btn = try ui.add(Button, bar, .{ .text = "Clear", .variant = .flat, .on_click = .bind(self, onClear) });
        const editor = try ui.add(CodeEditor, node, .{
            .style = .{ .grow = 1 },
            .label = "Output text",
            .read_only = true,
            .line_numbers = false,
            .auto_indent = false,
            .size = 13,
            .language = &@import("../editor/syntax.zig").plain,
        });
        self.* = .{ .gpa = ui.gpa, .ui = ui, .node = node, .editor = editor, .status = status, .stop_btn = stop_btn, .clear_btn = clear_btn, .on_open = opts.on_open };
        editor.setFollowEnd(true);
        try ui.tree.addListener(editor.node, .{ .kind = .pointer_down, .callback = .bind(self, onPointer) });
        return self;
    }

    pub fn destroy(self: *OutputPanel) void {
        if (self.runner) |r| r.destroy();
        for (self.batch.items) |*e| e.deinit(self.gpa);
        self.batch.deinit(self.gpa);
        for (&self.partial) |*p| p.deinit(self.gpa);
        self.freeDiags();
        self.diags.deinit(self.gpa);
        self.decos.deinit(self.gpa);
        self.gpa.free(self.title);
        _ = self.ui.tree.destroySubtree(self.node);
        self.gpa.destroy(self);
    }

    fn freeDiags(self: *OutputPanel) void {
        for (self.diags.items) |d| self.gpa.free(d.path);
        self.diags.clearRetainingCapacity();
    }

    // ---- running ----

    /// Start `argv` (replacing a run in progress). Output goes to the panel
    /// until the next `run` or `clear`.
    pub fn run(self: *OutputPanel, io: std.Io, argv: []const []const u8, cwd: ?[]const u8, wake: ?*const fn () void) !void {
        if (self.runner) |r| {
            r.destroy();
            self.runner = null;
        }
        self.clear();
        const joined = try std.mem.join(self.gpa, " ", argv);
        self.gpa.free(self.title);
        self.title = joined;
        self.echo("$ ", joined);
        self.runner = try process.Runner.start(self.gpa, io, .{ .argv = argv, .cwd = cwd, .wake = wake });
        self.running = true;
        self.exit_code = null;
        self.started_ms = self.ui.now_ms;
        self.stop_btn.setEnabled(true);
        self.setStatus("Running: ");
    }

    /// Ask the running process to end.
    pub fn stop(self: *OutputPanel) void {
        if (self.runner) |r| r.stop();
    }

    /// Empty the panel (a run in progress keeps going and keeps printing).
    pub fn clear(self: *OutputPanel) void {
        self.editor.loadText("", false) catch {};
        self.freeDiags();
        self.decos.clearRetainingCapacity();
        self.editor.clearDecorations(0);
        for (&self.partial) |*p| p.clearRetainingCapacity();
        if (!self.running) self.status.setText("No output yet") catch {};
    }

    fn onStop(self: *OutputPanel, _: *event.Event) void {
        self.stop();
    }

    fn onClear(self: *OutputPanel, _: *event.Event) void {
        self.clear();
    }

    fn setStatus(self: *OutputPanel, prefix: []const u8) void {
        var buf: [512]u8 = undefined;
        const text = std.fmt.bufPrint(&buf, "{s}{s}", .{ prefix, self.title }) catch prefix;
        self.status.setText(text) catch {};
    }

    // ---- output ----

    /// Take in whatever the process has printed since the last call (UI thread;
    /// call it each loop iteration).
    pub fn poll(self: *OutputPanel) void {
        const r = self.runner orelse return;
        r.drain(&self.batch);
        if (self.batch.items.len == 0) return;
        var changed = false;
        for (self.batch.items) |*e| {
            switch (e.*) {
                .chunk => |c| {
                    self.feed(c.stream, c.bytes);
                    changed = true;
                },
                .exited => |term| self.finished(term),
            }
            e.deinit(self.gpa);
        }
        self.batch.clearRetainingCapacity();
        if (changed) self.editor.setDecorations(0, self.decos.items) catch {};
        if (self.runner != null and self.runner.?.finished() and !self.running) {
            self.runner.?.destroy();
            self.runner = null;
        }
    }

    fn feed(self: *OutputPanel, stream: process.Stream, bytes: []const u8) void {
        const p = &self.partial[@intFromEnum(stream)];
        var rest = bytes;
        while (std.mem.indexOfScalar(u8, rest, '\n')) |nl| {
            p.appendSlice(self.gpa, rest[0..nl]) catch return;
            self.addLine(p.items);
            p.clearRetainingCapacity();
            rest = rest[nl + 1 ..];
        }
        p.appendSlice(self.gpa, rest) catch {};
    }

    fn addLine(self: *OutputPanel, raw: []const u8) void {
        var clean: std.ArrayListUnmanaged(u8) = .empty;
        defer clean.deinit(self.gpa);
        buildout.stripAnsi(self.gpa, &clean, std.mem.trimEnd(u8, raw, "\r")) catch return;
        const doc = &self.editor.core().doc;
        const row = doc.lineCount() - 1;
        const start = doc.len();
        clean.append(self.gpa, '\n') catch return;
        self.editor.appendText(clean.items) catch return;
        const line = clean.items[0 .. clean.items.len - 1];
        if (buildout.parseLine(line)) |d| {
            const path = self.gpa.dupe(u8, d.path) catch return;
            self.diags.append(self.gpa, .{ .row = row, .path = path, .line = d.line, .col = d.col, .severity = d.severity }) catch {
                self.gpa.free(path);
                return;
            };
            self.decos.append(self.gpa, .{
                .start = start,
                .end = start + line.len,
                .kind = switch (d.severity) {
                    .err => .error_line,
                    .warning => .warning_line,
                    .note => .note_line,
                },
            }) catch {};
        }
    }

    fn finished(self: *OutputPanel, term: std.process.Child.Term) void {
        // A last line without a newline.
        for (0..2) |i| {
            if (self.partial[i].items.len > 0) {
                self.addLine(self.partial[i].items);
                self.partial[i].clearRetainingCapacity();
            }
        }
        self.running = false;
        self.stop_btn.setEnabled(false);
        const secs = @as(f64, @floatFromInt(self.ui.now_ms -| self.started_ms)) / 1000.0;
        var buf: [600]u8 = undefined;
        const text = switch (term) {
            .exited => |code| blk: {
                self.exit_code = code;
                break :blk std.fmt.bufPrint(&buf, "{s}: {s} (exit {d}, {d:.1} s)", .{ if (code == 0) "Finished" else "Failed", self.title, code, secs }) catch "Finished";
            },
            else => blk: {
                self.exit_code = 255;
                break :blk std.fmt.bufPrint(&buf, "Stopped: {s} ({d:.1} s)", .{ self.title, secs }) catch "Stopped";
            },
        };
        self.status.setText(text) catch {};
        self.echo("[", text);
    }

    /// A line of the panel's own (the command that started, how it ended), not
    /// the process's: `prefix`, `text`, and a closing bracket if `prefix` opened one.
    fn echo(self: *OutputPanel, prefix: []const u8, text: []const u8) void {
        var buf: [700]u8 = undefined;
        const close: []const u8 = if (std.mem.eql(u8, prefix, "[")) "]" else "";
        const line = std.fmt.bufPrint(&buf, "{s}{s}{s}\n", .{ prefix, text, close }) catch return;
        self.editor.appendText(line) catch {};
    }

    // ---- activating a diagnostic ----

    fn onPointer(self: *OutputPanel, ev: *event.Event) void {
        if (ev.button != 1 or ev.clicks < 2) return;
        const hook = self.on_open orelse return;
        const row = self.editor.lineAtPoint(ev.local_y);
        for (self.diags.items) |d| {
            if (d.row == row) {
                hook.call(hook.ctx, d.path, d.line, d.col);
                return;
            }
        }
    }
};

// ---- tests -----------------------------------------------------------------

const testing = std.testing;
const builtin = @import("builtin");
const draw_list = @import("../core/draw_list.zig");

const Rig = struct {
    ui: Ui,
    cmds: [4096]draw_list.Command = undefined,
    glyphs: [4096]draw_list.Glyph = undefined,
    list: draw_list.DrawList = undefined,
    prop: @import("../text/font.zig").TestFont = .{},
    mono: @import("../text/font.zig").TestFont = .{ .monospace = true },
    opened_path: [64]u8 = undefined,
    opened_len: usize = 0,
    opened_line: u32 = 0,
    opened_col: u32 = 0,

    fn init() !*Rig {
        const r = try testing.allocator.create(Rig);
        r.* = .{ .ui = try Ui.init(testing.allocator) };
        _ = try r.ui.addFont(r.prop.backend());
        r.ui.theme.mono_font = try r.ui.addFont(r.mono.backend());
        r.list = draw_list.DrawList.init(&r.cmds, &r.glyphs);
        r.ui.tree.get(r.ui.tree.root).?.style = .{ .direction = .column };
        return r;
    }

    fn deinit(self: *Rig) void {
        self.ui.deinit();
        testing.allocator.destroy(self);
    }

    fn frame(self: *Rig) !void {
        self.ui.update();
        try self.ui.layoutAndPaint(.{ .w = 500, .h = 300 }, &self.list);
        self.ui.endFrame();
    }

    fn onOpen(self: *Rig, path: []const u8, line: u32, col: u32) void {
        @memcpy(self.opened_path[0..path.len], path);
        self.opened_len = path.len;
        self.opened_line = line;
        self.opened_col = col;
    }
};

test "the panel shows output as it arrives, tints diagnostics, and double-click opens them" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const r = try Rig.init();
    defer r.deinit();
    const out = try OutputPanel.create(&r.ui, r.ui.tree.root, .{ .style = .{ .grow = 1 }, .on_open = OpenHook.bind(r, Rig.onOpen) });
    defer out.destroy();
    try r.frame();
    try out.run(testing.io, &.{ "/bin/sh", "-c", "echo building; printf 'src/a.zig:3:7: \\033[31merror\\033[0m: bad thing\\n' 1>&2; echo 'b.zig:1:1: warning: meh'; printf tail" }, null, null);
    try testing.expect(out.running);
    var tries: usize = 0;
    while (out.running and tries < 3000) : (tries += 1) {
        out.poll();
        var ts: std.os.linux.timespec = .{ .sec = 0, .nsec = 1_000_000 };
        _ = std.os.linux.nanosleep(&ts, null);
    }
    out.poll();
    try r.frame();
    try testing.expect(!out.running);
    try testing.expectEqual(@as(?u8, 0), out.exit_code);
    try testing.expect(std.mem.startsWith(u8, out.status.props.text.bytes, "Finished"));

    const text = try out.editor.textAlloc(testing.allocator);
    defer testing.allocator.free(text);
    // stdout and stderr lines both appear, colors stripped, the unterminated tail kept.
    try testing.expect(std.mem.indexOf(u8, text, "building\n") != null);
    try testing.expect(std.mem.indexOf(u8, text, "src/a.zig:3:7: error: bad thing\n") != null);
    try testing.expect(std.mem.indexOf(u8, text, "tail\n[Finished: ") != null);
    try testing.expect(std.mem.startsWith(u8, text, "$ /bin/sh -c "));
    try testing.expectEqual(@as(usize, 2), out.diags.items.len);
    try testing.expectEqual(@as(usize, 2), out.editor.decos[0].items.len);
    try testing.expect(out.editor.decos[0].items[0].kind == .error_line or out.editor.decos[0].items[0].kind == .warning_line);

    // Double-click the error line.
    const diag = for (out.diags.items) |d| {
        if (std.mem.eql(u8, d.path, "src/a.zig")) break d;
    } else return error.TestUnexpectedResult;
    const abs = r.ui.tree.absoluteRect(out.editor.node).?;
    const m = out.editor.metrics().?;
    const geo = out.editor.geometry(m);
    const y = abs.y + geo.pad.t + (@as(f32, @floatFromInt(out.editor.rowOfLine(diag.row))) + 0.5) * m.line_h;
    const x = abs.x + 40;
    r.ui.pointerMove(x, y);
    r.ui.pointerButtonEx(x, y, 1, true, 1);
    r.ui.pointerButtonEx(x, y, 1, false, 1);
    r.ui.pointerButtonEx(x, y, 1, true, 2);
    r.ui.pointerButtonEx(x, y, 1, false, 2);
    try testing.expectEqualStrings("src/a.zig", r.opened_path[0..r.opened_len]);
    try testing.expectEqual(@as(u32, 3), r.opened_line);
    try testing.expectEqual(@as(u32, 7), r.opened_col);

    out.clear();
    try testing.expectEqual(@as(usize, 0), out.diags.items.len);
}

test "a failing command reports its exit code; Stop ends a long run" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const r = try Rig.init();
    defer r.deinit();
    const out = try OutputPanel.create(&r.ui, r.ui.tree.root, .{ .style = .{ .grow = 1 } });
    defer out.destroy();
    try out.run(testing.io, &.{ "/bin/sh", "-c", "exit 4" }, null, null);
    var tries: usize = 0;
    while (out.running and tries < 3000) : (tries += 1) {
        out.poll();
        var ts: std.os.linux.timespec = .{ .sec = 0, .nsec = 1_000_000 };
        _ = std.os.linux.nanosleep(&ts, null);
    }
    out.poll();
    try testing.expectEqual(@as(?u8, 4), out.exit_code);
    try testing.expect(std.mem.startsWith(u8, out.status.props.text.bytes, "Failed"));

    try out.run(testing.io, &.{ "/bin/sh", "-c", "sleep 30" }, null, null);
    try testing.expect(out.stop_btn.props.enabled);
    out.stop();
    tries = 0;
    while (out.running and tries < 3000) : (tries += 1) {
        out.poll();
        var ts: std.os.linux.timespec = .{ .sec = 0, .nsec = 1_000_000 };
        _ = std.os.linux.nanosleep(&ts, null);
    }
    out.poll();
    try testing.expect(!out.running);
    try testing.expect(std.mem.startsWith(u8, out.status.props.text.bytes, "Stopped"));
}
