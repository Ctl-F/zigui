//! The Debug panel: a toolbar (Continue, Step Over, Step In, Step Out, Stop), the
//! call stack and the breakpoints, the variables of the selected frame, and the
//! debug console (the program's output and the adapter's messages, with a field
//! to evaluate expressions). It shows what a `Debugger`'s session knows and sends
//! the user's commands back; the editors' marks are `debug_marks.zig`.
//!
//!     const dp = try DebugPanel.create(&ui, parent, debugger, .{ .on_open = OpenHook.bind(&app, App.openAt) });
//!     defer dp.destroy();
//!     debugger.on_change = ChangeHook.bind(dp, DebugPanel.refresh);   // or call `refresh()` yourself
//!
//! Variables load as you expand them (a structure's fields are asked from the
//! adapter when its row opens); expanded rows stay open across steps. Selecting a
//! frame shows its variables; double-clicking a frame or a breakpoint opens the
//! file at that line. IDE-level code: `TreeView`, `CodeEditor`, `TextField`.

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
const output_panel = @import("output_panel.zig");
const debugger_mod = @import("debugger.zig");
const session_mod = @import("dap/session.zig");

pub const OpenHook = output_panel.OpenHook;

pub const Options = struct {
    style: Style = .{},
    on_open: ?OpenHook = null,
};

const no_code: u64 = std.math.maxInt(u64);
const placeholder: u64 = std.math.maxInt(u64) - 1;
const max_depth = 6;

pub const DebugPanel = struct {
    gpa: std.mem.Allocator,
    ui: *Ui,
    node: Handle,
    debugger: *debugger_mod.Debugger,
    on_open: ?OpenHook,
    status: *Label,
    continue_btn: *Button,
    over_btn: *Button,
    into_btn: *Button,
    out_btn: *Button,
    stop_btn: *Button,
    stack: *TreeView,
    breakpoints: *TreeView,
    vars: *TreeView,
    console: *CodeEditor,
    input: *TextField,
    /// Variable rows: the reference they stand for (their children), by item.
    var_path: std.AutoHashMapUnmanaged(u32, []u8) = .empty,
    /// Paths of the variable rows the user has opened.
    open_paths: std.StringHashMapUnmanaged(void) = .empty,
    console_shown: usize = 0,
    stop_seen: u32 = 0,

    pub fn create(ui: *Ui, parent: Handle, debugger: *debugger_mod.Debugger, opts: Options) !*DebugPanel {
        const self = try ui.gpa.create(DebugPanel);
        errdefer ui.gpa.destroy(self);
        var style = opts.style;
        style.direction = .column;
        if (std.meta.eql(style.padding, .{})) style.padding = Edges.all(6);
        style.gap = Length.px(4);
        if (style.grow == 0) style.grow = 1;
        const node = try ui.tree.create(.{ .style = style, .role = .panel });
        errdefer _ = ui.tree.destroySubtree(node);
        try ui.tree.appendChild(parent, node);
        try ui.tree.setLabel(node, "Debug");
        const pad = Edges.xy(8, 4);
        const bar = try ui.tree.create(.{ .style = .{ .direction = .row, .gap = Length.px(4), .align_items = .center, .shrink = 0 } });
        try ui.tree.appendChild(node, bar);
        const continue_btn = try ui.add(Button, bar, .{ .text = "Continue", .variant = .primary, .style = .{ .padding = pad }, .on_click = .bind(self, onContinue) });
        const over_btn = try ui.add(Button, bar, .{ .text = "Step Over", .variant = .flat, .style = .{ .padding = pad }, .on_click = .bind(self, onOver) });
        const into_btn = try ui.add(Button, bar, .{ .text = "Step In", .variant = .flat, .style = .{ .padding = pad }, .on_click = .bind(self, onInto) });
        const out_btn = try ui.add(Button, bar, .{ .text = "Step Out", .variant = .flat, .style = .{ .padding = pad }, .on_click = .bind(self, onOut) });
        const stop_btn = try ui.add(Button, bar, .{ .text = "Stop", .variant = .flat, .style = .{ .padding = pad }, .on_click = .bind(self, onStop) });
        const status = try ui.add(Label, bar, .{ .text = "Not debugging. F5 builds and starts the program; F9 sets a breakpoint; Ctrl+F7 debugs a comptime block.", .style = .{ .grow = 1, .padding = Edges.xy(8, 0) } });

        const split = try ui.tree.create(.{ .style = .{ .direction = .row, .gap = Length.px(6), .grow = 1 } });
        try ui.tree.appendChild(node, split);
        // Call stack above breakpoints.
        const left = try ui.tree.create(.{ .style = .{ .direction = .column, .gap = Length.px(2), .grow = 1, .min_width = Length.px(180) } });
        try ui.tree.appendChild(split, left);
        _ = try ui.add(Label, left, .{ .text = "Call Stack", .style = .{ .shrink = 0 } });
        const stack = try ui.add(TreeView, left, .{ .style = .{ .grow = 2 }, .label = "Call stack", .activate_toggles = false, .on_select = .bind(self, onFrame), .on_activate = .bind(self, onOpenFrame) });
        _ = try ui.add(Label, left, .{ .text = "Breakpoints", .style = .{ .shrink = 0 } });
        const bps = try ui.add(TreeView, left, .{ .style = .{ .grow = 1 }, .label = "Breakpoints", .activate_toggles = false, .on_activate = .bind(self, onOpenBreakpoint) });
        const mid = try ui.tree.create(.{ .style = .{ .direction = .column, .gap = Length.px(2), .grow = 2, .min_width = Length.px(200) } });
        try ui.tree.appendChild(split, mid);
        _ = try ui.add(Label, mid, .{ .text = "Variables", .style = .{ .shrink = 0 } });
        const vars = try ui.add(TreeView, mid, .{ .style = .{ .grow = 1 }, .label = "Variables", .activate_toggles = true, .on_toggle = .bind(self, onToggleVar) });
        const right = try ui.tree.create(.{ .style = .{ .direction = .column, .gap = Length.px(2), .grow = 2, .min_width = Length.px(200) } });
        try ui.tree.appendChild(split, right);
        _ = try ui.add(Label, right, .{ .text = "Debug Console", .style = .{ .shrink = 0 } });
        const console = try ui.add(CodeEditor, right, .{
            .style = .{ .grow = 1 },
            .label = "Debug console",
            .read_only = true,
            .line_numbers = false,
            .auto_indent = false,
            .size = 13,
            .language = &@import("../editor/syntax.zig").plain,
        });
        console.setFollowEnd(true);
        const input = try ui.add(TextField, right, .{ .placeholder = "Evaluate an expression", .label = "Evaluate", .style = .{ .shrink = 0 }, .on_submit = .bind(self, onEvaluate) });
        self.* = .{
            .gpa = ui.gpa,
            .ui = ui,
            .node = node,
            .debugger = debugger,
            .on_open = opts.on_open,
            .status = status,
            .continue_btn = continue_btn,
            .over_btn = over_btn,
            .into_btn = into_btn,
            .out_btn = out_btn,
            .stop_btn = stop_btn,
            .stack = stack,
            .breakpoints = bps,
            .vars = vars,
            .console = console,
            .input = input,
        };
        self.refresh();
        return self;
    }

    pub fn destroy(self: *DebugPanel) void {
        self.freePaths();
        self.var_path.deinit(self.gpa);
        var it = self.open_paths.keyIterator();
        while (it.next()) |k| self.gpa.free(k.*);
        self.open_paths.deinit(self.gpa);
        _ = self.ui.tree.destroySubtree(self.node);
        self.gpa.destroy(self);
    }

    fn freePaths(self: *DebugPanel) void {
        var it = self.var_path.valueIterator();
        while (it.next()) |v| self.gpa.free(v.*);
        self.var_path.clearRetainingCapacity();
    }

    fn session(self: *const DebugPanel) *session_mod.Session {
        return self.debugger.session;
    }

    /// Show what the session knows now.
    pub fn refresh(self: *DebugPanel) void {
        const s = self.session();
        self.updateStatus();
        self.updateButtons();
        self.rebuildStack();
        self.rebuildBreakpoints();
        self.rebuildVariables();
        self.updateConsole();
        _ = s;
    }

    fn updateStatus(self: *DebugPanel) void {
        const s = self.session();
        if (self.debugger.preparing()) {
            var pb: [200]u8 = undefined;
            const secs = self.debugger.prepElapsedMs() / 1000;
            return self.status.setText(std.fmt.bufPrint(&pb, "Compile-time debug (zigct): reading the build for the module graph... {d}s (once per version of build.zig; the first time compiles the build script)", .{secs}) catch "Compile-time debug (zigct): reading the build...") catch {};
        }
        var buf: [300]u8 = undefined;
        var buf2: [340]u8 = undefined;
        const text0: []const u8 = switch (s.state) {
            .idle => "Not debugging. F5 builds and starts the program; F9 sets a breakpoint.",
            .starting => "Starting the debugger...",
            .running => "Running...",
            .stopped => std.fmt.bufPrint(&buf, "Stopped ({s}{s}{s})", .{ s.stop_reason, if (s.stop_text.len > 0) ": " else "", s.stop_text }) catch "Stopped",
            .terminated => if (s.failure.len > 0)
                std.fmt.bufPrint(&buf, "Ended: {s}", .{s.failure}) catch "Ended"
            else if (s.isComptime())
                (if ((s.exit_code orelse 0) == 0) "The comptime run finished" else "The compilation failed")
            else if (s.exit_code) |c|
                std.fmt.bufPrint(&buf, "The program exited with code {d}", .{c}) catch "The program exited"
            else
                "The debug session ended",
        };
        // A compile-time session is never to be taken for a runtime one.
        const text = if (s.isComptime() and s.state != .idle) (std.fmt.bufPrint(&buf2, "Compile-time debug (zigct): {s}", .{text0}) catch text0) else text0;
        self.status.setText(text) catch {};
    }

    fn updateButtons(self: *DebugPanel) void {
        const st = self.session().state;
        const stopped = st == .stopped;
        self.continue_btn.setEnabled(stopped);
        self.over_btn.setEnabled(stopped);
        self.into_btn.setEnabled(stopped);
        self.out_btn.setEnabled(stopped);
        self.stop_btn.setEnabled(self.session().active() or self.debugger.preparing());
    }

    // ---- stack and breakpoints ----

    fn rebuildStack(self: *DebugPanel) void {
        const s = self.session();
        self.stack.clear();
        for (s.frames, 0..) |f, i| {
            var buf: [400]u8 = undefined;
            const base = if (f.path.len > 0) std.fs.path.basename(f.path) else "";
            const text = if (f.path.len > 0)
                std.fmt.bufPrint(&buf, "{s}   {s}:{d}", .{ f.name, base, f.line }) catch f.name
            else
                std.fmt.bufPrint(&buf, "{s}", .{f.name}) catch f.name;
            const id = self.stack.addItem(tree_view.no_item, text) catch return;
            self.stack.setUserData(id, i);
            if (i == s.selected) self.stack.select(id);
        }
    }

    fn rebuildBreakpoints(self: *DebugPanel) void {
        const s = self.session();
        self.breakpoints.clear();
        for (s.breakpoints.items, 0..) |b, i| {
            var buf: [500]u8 = undefined;
            const state: []const u8 = if (!b.enabled) " (disabled)" else if (b.verified == .unverified) " (not bound)" else "";
            const cond: []const u8 = if (b.condition.len > 0) "   if " else "";
            const text = std.fmt.bufPrint(&buf, "{s}:{d}{s}{s}{s}", .{ std.fs.path.basename(b.file), b.line, cond, b.condition, state }) catch b.file;
            const id = self.breakpoints.addItem(tree_view.no_item, text) catch return;
            self.breakpoints.setUserData(id, i);
        }
    }

    fn onFrame(self: *DebugPanel, _: *event.Event) void {
        const id = self.stack.selected();
        if (id == tree_view.no_item or !self.stack.exists(id)) return;
        self.session().selectFrame(@intCast(self.stack.userData(id)));
    }

    fn onOpenFrame(self: *DebugPanel, _: *event.Event) void {
        const id = self.stack.out.activated_item;
        if (id == tree_view.no_item or !self.stack.exists(id)) return;
        const i: usize = @intCast(self.stack.userData(id));
        const s = self.session();
        if (i >= s.frames.len) return;
        const f = s.frames[i];
        if (f.path.len == 0) return;
        if (self.on_open) |h| h.call(h.ctx, f.path, f.line, @max(f.column, 1));
    }

    fn onOpenBreakpoint(self: *DebugPanel, _: *event.Event) void {
        const id = self.breakpoints.out.activated_item;
        if (id == tree_view.no_item or !self.breakpoints.exists(id)) return;
        const i: usize = @intCast(self.breakpoints.userData(id));
        const s = self.session();
        if (i >= s.breakpoints.items.len) return;
        const b = s.breakpoints.items[i];
        if (self.on_open) |h| h.call(h.ctx, b.file, b.line, 1);
    }

    // ---- variables ----

    fn pathOf(self: *DebugPanel, parent_path: []const u8, name: []const u8) ?[]u8 {
        return std.fmt.allocPrint(self.gpa, "{s}/{s}", .{ parent_path, name }) catch null;
    }

    fn remember(self: *DebugPanel, id: u32, path: []const u8) void {
        const copy = self.gpa.dupe(u8, path) catch return;
        self.var_path.put(self.gpa, id, copy) catch self.gpa.free(copy);
    }

    fn fillChildren(self: *DebugPanel, parent: u32, reference: i64, path: []const u8, depth: usize) void {
        const s = self.session();
        const vars = s.variables(reference) orelse return;
        for (vars) |v| {
            var buf: [600]u8 = undefined;
            const shown = v.value[0..@min(v.value.len, 300)];
            const text = if (v.type_name.len > 0)
                std.fmt.bufPrint(&buf, "{s} = {s}   ({s})", .{ v.name, shown, v.type_name }) catch v.name
            else
                std.fmt.bufPrint(&buf, "{s} = {s}", .{ v.name, shown }) catch v.name;
            const id = self.vars.addItem(parent, text) catch return;
            self.vars.setUserData(id, if (v.reference > 0) @as(u64, @intCast(v.reference)) else no_code);
            const p = self.pathOf(path, v.name) orelse continue;
            defer self.gpa.free(p);
            self.remember(id, p);
            if (v.reference <= 0) continue;
            const open = self.open_paths.contains(p);
            if (s.variables(v.reference) != null and depth < max_depth) {
                self.fillChildren(id, v.reference, p, depth + 1);
            } else {
                // Not loaded yet: a placeholder gives it an expander.
                const ph = self.vars.addItem(id, "...") catch continue;
                self.vars.setUserData(ph, placeholder);
                if (open) s.expand(v.reference);
            }
            if (open) self.vars.setExpanded(id, true);
        }
    }

    fn rebuildVariables(self: *DebugPanel) void {
        const s = self.session();
        self.vars.clear();
        self.freePaths();
        for (s.scopes, 0..) |sc, i| {
            const id = self.vars.addItem(tree_view.no_item, sc.name) catch return;
            self.vars.setUserData(id, if (sc.reference > 0) @as(u64, @intCast(sc.reference)) else no_code);
            self.remember(id, sc.name);
            if (sc.reference > 0 and s.variables(sc.reference) != null) {
                self.fillChildren(id, sc.reference, sc.name, 0);
            } else if (sc.reference > 0) {
                const ph = self.vars.addItem(id, "...") catch continue;
                self.vars.setUserData(ph, placeholder);
            }
            // Locals (the first scope) open by default; the others when the user opens them.
            if (i == 0 or self.open_paths.contains(sc.name)) self.vars.setExpanded(id, true);
        }
        if (s.state != .stopped) return;
        if (s.scopes.len > 0 and s.variables(s.scopes[0].reference) != null and s.variables(s.scopes[0].reference).?.len == 0) {
            // A frame with nothing to show (or no debug information for its locals).
            if (self.vars.childCount(tree_view.no_item) > 0) {
                const first = self.vars.childAt(tree_view.no_item, 0);
                const note = self.vars.addItem(first, if (s.isComptime()) "(no locals declared yet in this frame)" else "(no variables reported: the debug info may not describe locals, see the debugging docs)") catch return;
                self.vars.setUserData(note, no_code);
            }
        }
    }

    fn onToggleVar(self: *DebugPanel, _: *event.Event) void {
        const s = self.session();
        var it = self.var_path.iterator();
        while (it.next()) |kv| {
            const id = kv.key_ptr.*;
            if (!self.vars.exists(id)) continue;
            const code = self.vars.userData(id);
            if (code == no_code or code == placeholder) continue;
            const path = kv.value_ptr.*;
            const open = self.vars.isExpanded(id);
            if (open) {
                if (!self.open_paths.contains(path)) {
                    if (self.gpa.dupe(u8, path)) |copy| {
                        self.open_paths.put(self.gpa, copy, {}) catch self.gpa.free(copy);
                    } else |_| {}
                }
                s.expand(@intCast(code));
            } else if (self.open_paths.fetchRemove(path)) |old| {
                self.gpa.free(old.key);
            }
        }
    }

    // ---- console ----

    fn updateConsole(self: *DebugPanel) void {
        const s = self.session();
        if (s.console.items.len < self.console_shown) {
            // The console was cleared (a new run).
            self.console_shown = 0;
        }
        while (self.console_shown < s.console.items.len) : (self.console_shown += 1) {
            self.console.appendText(s.console.items[self.console_shown]) catch {};
            self.console.appendText("\n") catch {};
        }
    }

    /// Start with an empty console (a new run).
    pub fn clearConsole(self: *DebugPanel) void {
        const empty = self.gpa.dupe(u8, "") catch return;
        self.console.loadText(empty, true) catch self.gpa.free(empty);
        self.console_shown = self.session().console.items.len;
    }

    fn onEvaluate(self: *DebugPanel, _: *event.Event) void {
        const text = std.mem.trim(u8, self.input.text(), " \t\r\n");
        if (text.len == 0) return;
        self.session().evaluate(text);
        self.input.setText("") catch {};
    }

    // ---- toolbar ----

    fn onContinue(self: *DebugPanel, _: *event.Event) void {
        self.session().continueRun();
    }

    fn onOver(self: *DebugPanel, _: *event.Event) void {
        self.session().stepOver();
    }

    fn onInto(self: *DebugPanel, _: *event.Event) void {
        self.session().stepIn();
    }

    fn onOut(self: *DebugPanel, _: *event.Event) void {
        self.session().stepOut();
    }

    fn onStop(self: *DebugPanel, _: *event.Event) void {
        self.debugger.stop();
    }
};

// ---- tests -----------------------------------------------------------------

const testing = std.testing;
const Rig = @import("../core/test_rig.zig").Rig;
const project_mod = @import("project.zig");
const jsonrpc = @import("lsp/jsonrpc.zig");

fn feed(s: *session_mod.Session, comptime fmt: []const u8, args: anytype) void {
    const body = std.fmt.allocPrint(testing.allocator, fmt, args) catch return;
    defer testing.allocator.free(body);
    const framed = jsonrpc.frame(testing.allocator, body) catch return;
    defer testing.allocator.free(framed);
    s.client.receive(framed);
}

const Opened = struct {
    buf: [256]u8 = undefined,
    len: usize = 0,
    line: u32 = 0,
    fn open(self: *Opened, path: []const u8, line: u32, _: u32) void {
        @memcpy(self.buf[0..path.len], path);
        self.len = path.len;
        self.line = line;
    }
};

test "the panel shows a stop: stack, locals that open into fields, breakpoints and the console; toolbar buttons follow the state" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var p = try project_mod.testProject(&tmp);
    defer p.close();
    const r = try Rig.init();
    defer r.deinit();
    const d = try debugger_mod.Debugger.create(testing.allocator, testing.io, &p, null, .{});
    defer d.destroy();
    var opened: Opened = .{};
    const dp = try DebugPanel.create(&r.ui, r.ui.tree.root, d, .{ .on_open = .bind(&opened, Opened.open) });
    defer dp.destroy();
    d.on_change = session_mod.ChangeHook.bind(dp, DebugPanel.refresh);
    const s = d.session;
    try r.frame();
    try testing.expect(!dp.continue_btn.props.enabled and !dp.stop_btn.props.enabled);

    // Drive the session as an adapter would: a stop with two frames, locals, and a structure to open.
    try s.setBreakpoint("/p/a.zig", 5, true, "x > 1");
    s.state = .running;
    feed(s, "{{\"seq\":1,\"type\":\"event\",\"event\":\"output\",\"body\":{{\"category\":\"stdout\",\"output\":\"hello\\n\"}}}}", .{});
    feed(s, "{{\"seq\":2,\"type\":\"event\",\"event\":\"stopped\",\"body\":{{\"reason\":\"breakpoint\",\"threadId\":1}}}}", .{});
    // `stackTrace`, `scopes` and `variables` were requested (the first has sequence 1): answer them.
    feed(s, "{{\"seq\":3,\"type\":\"response\",\"request_seq\":1,\"success\":true,\"command\":\"stackTrace\",\"body\":{{\"stackFrames\":[{{\"id\":7,\"name\":\"inner\",\"source\":{{\"path\":\"/p/a.zig\"}},\"line\":5,\"column\":3}},{{\"id\":8,\"name\":\"main\",\"source\":{{\"path\":\"/p/a.zig\"}},\"line\":12,\"column\":1}}]}}}}", .{});
    feed(s, "{{\"seq\":4,\"type\":\"response\",\"request_seq\":2,\"success\":true,\"command\":\"scopes\",\"body\":{{\"scopes\":[{{\"name\":\"Locals\",\"variablesReference\":10}}]}}}}", .{});
    feed(s, "{{\"seq\":5,\"type\":\"response\",\"request_seq\":3,\"success\":true,\"command\":\"variables\",\"body\":{{\"variables\":[{{\"name\":\"n\",\"value\":\"42\",\"type\":\"i32\",\"variablesReference\":0}},{{\"name\":\"pt\",\"value\":\"{{...}}\",\"type\":\"Point\",\"variablesReference\":20}}]}}}}", .{});
    try r.frame();

    try testing.expect(dp.continue_btn.props.enabled and dp.over_btn.props.enabled and dp.stop_btn.props.enabled);
    try testing.expect(std.mem.indexOf(u8, dp.status.props.text.bytes, "Stopped (breakpoint") != null);
    try testing.expectEqual(@as(usize, 2), dp.stack.childCount(tree_view.no_item));
    try testing.expectEqualStrings("inner   a.zig:5", dp.stack.itemText(dp.stack.childAt(tree_view.no_item, 0)));
    try testing.expectEqual(@as(usize, 1), dp.breakpoints.childCount(tree_view.no_item));
    try testing.expectEqualStrings("a.zig:5   if x > 1", dp.breakpoints.itemText(dp.breakpoints.childAt(tree_view.no_item, 0)));

    // Variables: the Locals scope is open with `n` and `pt`; `pt` has an expander until it is opened.
    const locals = dp.vars.childAt(tree_view.no_item, 0);
    try testing.expectEqualStrings("Locals", dp.vars.itemText(locals));
    try testing.expectEqual(@as(usize, 2), dp.vars.childCount(locals));
    try testing.expectEqualStrings("n = 42   (i32)", dp.vars.itemText(dp.vars.childAt(locals, 0)));
    const pt = dp.vars.childAt(locals, 1);
    try testing.expectEqual(@as(usize, 1), dp.vars.childCount(pt)); // the placeholder
    dp.vars.setExpanded(pt, true);
    dp.onToggleVar(undefined); // asks for the fields (the next request is number 4)
    feed(s, "{{\"seq\":6,\"type\":\"response\",\"request_seq\":4,\"success\":true,\"command\":\"variables\",\"body\":{{\"variables\":[{{\"name\":\"x\",\"value\":\"1\",\"type\":\"i32\",\"variablesReference\":0}}]}}}}", .{});
    try r.frame();
    const pt2 = dp.vars.childAt(dp.vars.childAt(tree_view.no_item, 0), 1);
    try testing.expectEqualStrings("x = 1   (i32)", dp.vars.itemText(dp.vars.childAt(pt2, 0)));
    try testing.expect(dp.vars.isExpanded(pt2)); // the opened row stays open after the rebuild

    // The console shows the program's output.
    const text = try dp.console.editor.doc.textAlloc(testing.allocator, 0, dp.console.editor.doc.len());
    defer testing.allocator.free(text);
    try testing.expect(std.mem.indexOf(u8, text, "hello") != null);

    // Double-clicking a frame opens its file at its line.
    dp.stack.out.activated_item = dp.stack.childAt(tree_view.no_item, 1);
    dp.onOpenFrame(undefined);
    try testing.expectEqualStrings("/p/a.zig", opened.buf[0..opened.len]);
    try testing.expectEqual(@as(u32, 12), opened.line);

    // The program ends: buttons go back to disabled and the status says how it ended.
    feed(s, "{{\"seq\":7,\"type\":\"event\",\"event\":\"exited\",\"body\":{{\"exitCode\":0}}}}", .{});
    feed(s, "{{\"seq\":8,\"type\":\"event\",\"event\":\"terminated\"}}", .{});
    try r.frame();
    try testing.expect(!dp.continue_btn.props.enabled);
    try testing.expect(std.mem.indexOf(u8, dp.status.props.text.bytes, "exited with code 0") != null);
    try testing.expectEqual(@as(usize, 0), dp.stack.childCount(tree_view.no_item));
}
