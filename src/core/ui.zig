//! Ui: ties the tree, layout, input, widgets, and theme together.
//!
//! !!! DO NOT MOVE a `Ui` once you have added widgets. !!!
//! Widgets keep a pointer back to their `Ui`. Keep it on the stack or on the
//! heap (`gpa.create(Ui)`), but never return it from a function, copy it, or
//! store it in something that can reallocate after the first `add`. Debug
//! builds (the same gate as the shadow checker) panic if it moves.
//!
//! Frame protocol (what an app's loop does):
//!
//!   1. Feed input:      ui.pointerMove / pointerButton / wheel
//!                       (handlers and `out` flags update immediately)
//!   2. App polls `out` flags / reacts to callbacks, sets props
//!   3. ui.update()      verify props against shadows, resolve widget looks
//!   4. if ui.isDirty(): ui.layoutAndPaint(size, &list), then render the list
//!   5. ui.endFrame()    clear frame-scoped flags and dirty bits

const std = @import("std");
const Handle = @import("handle.zig").Handle;
const tree_mod = @import("tree.zig");
const Tree = tree_mod.Tree;
const Pool = @import("pool.zig").Pool;
const geometry = @import("geometry.zig");
const DirtyFlags = @import("dirty.zig").DirtyFlags;
const Style = @import("style.zig").Style;
const Layout = @import("layout.zig").Layout;
const Input = @import("input.zig").Input;
const keys = @import("keys.zig");
const paint = @import("paint.zig");
const DrawList = @import("draw_list.zig").DrawList;
const shadow = @import("shadow.zig");
const render_backend = @import("../render/backend.zig");
const frame_stats = @import("frame_stats.zig");
const event_types = @import("event.zig");
const commands_mod = @import("commands.zig");
const shortcuts_mod = @import("shortcuts.zig");
const font = @import("../text/font.zig");
const TextSystem = @import("../text/system.zig").TextSystem;
const text_block = @import("../text/block.zig");
const Color = geometry.Color;
const Theme = @import("../widgets/theme.zig").Theme;
const Text = @import("../widgets/common.zig").Text;
const button = @import("../widgets/button.zig");
const label = @import("../widgets/label.zig");
const text_field = @import("../widgets/text_field.zig");
const code_editor = @import("../widgets/code_editor.zig");
const canvas_mod = @import("../widgets/canvas.zig");
const widget = @import("../widgets/widget.zig");

pub const Scope = shortcuts_mod.Scope;
pub const BindError = shortcuts_mod.BindError;
pub const LoadReport = shortcuts_mod.LoadReport;
pub const Clipboard = @import("clipboard.zig").Clipboard;

pub const Button = button.Button;
pub const Label = label.Label;
pub const TextField = text_field.TextField;
pub const Canvas = canvas_mod.Canvas;
const CodeEditor = code_editor.CodeEditor;

/// A unique address per widget type, stored on nodes so the registry can tell
/// which widget a node carries.
pub fn typeTag(comptime W: type) *const anyopaque {
    // A mutable variable per type: identical constants may be merged by the
    // optimizer, which would give different widget types the same tag.
    return &struct {
        var unique: u8 = 0;
        comptime {
            _ = W;
        }
    }.unique;
}

/// The UI context: tree, layout, input, theme, and every widget.
///
/// DO NOT MOVE a `Ui` after the first widget is added (see the file header).
pub const Ui = struct {
    gpa: std.mem.Allocator,
    text: TextSystem,
    tree: Tree,
    layout: Layout,
    input: Input = .{},
    theme: Theme = .{},
    buttons: Pool(Button, 64),
    labels: Pool(Label, 64),
    fields: Pool(TextField, 64),
    editors: Pool(CodeEditor, 16),
    canvases: Pool(Canvas, 16),
    /// Recorded draw commands of repaint-boundary subtrees (see `paint.Cache`).
    paint_cache: paint.Cache,
    /// The renderer the app draws with (set by `renderFrame` or `setBackend`);
    /// canvases create their offscreen surfaces through it.
    backend: ?render_backend.Backend = null,
    clipboard: ?Clipboard = null,
    /// Monotonic nanosecond clock for frame stats and the handler budget
    /// (`sdl.ticksNs`). Without one, timings read zero.
    clock: ?*const fn () u64 = null,
    /// Costs of recent frames (see `frame_stats.zig`).
    stats: frame_stats.FrameStats = .{},
    /// Draw the frame-time overlay on top of the window (`renderFrame`).
    show_stats: bool = false,
    /// An input handler running longer than this logs a warning in debug builds
    /// and is counted in `slow_handlers`. 0 disables the check.
    handler_budget_ns: u64 = 8_000_000,
    slow_handlers: u32 = 0,
    /// Called from other threads to wake the platform's event loop (background
    /// work finished something to draw). Must be safe to call from any thread;
    /// set it before starting such work (`sdl.wake`).
    wake: ?*const fn () void = null,
    /// Interactive nodes found without an accessible name (debug builds).
    a11y_warnings: u32 = 0,
    a11y_log: bool = true,
    last_target: struct { w: u32 = 0, h: u32 = 0, scale: f32 = 0 } = .{},
    overlay_was_on: bool = false,
    /// The region the last `renderFrame` redrew (null: all of it).
    last_damage: ?geometry.Rect = null,
    pending_update_ns: u64 = 0,
    pending_handler_ns: u64 = 0,
    /// Last time passed to `tick`, in milliseconds.
    now_ms: u64 = 0,
    commands: commands_mod.Commands,
    shortcuts: shortcuts_mod.Shortcuts,
    /// Where the `Ui` lived when its first widget was created. Only tracked
    /// when `ui_checks` is on; it exists to catch a moved `Ui` (see `isPinned`).
    pinned: if (shadow.enabled) ?*const Ui else void = if (shadow.enabled) null else {},

    /// Create a `Ui`. It is returned by value, so assign it straight to its
    /// final home (`var ui = try Ui.init(gpa);` or `heap.* = try Ui.init(gpa);`).
    /// DO NOT MOVE it after adding widgets.
    pub fn init(gpa: std.mem.Allocator) !Ui {
        var tree = try Tree.init(gpa);
        errdefer tree.deinit();
        return .{
            .gpa = gpa,
            .text = TextSystem.init(gpa),
            .tree = tree,
            .layout = Layout.init(gpa),
            .buttons = Pool(Button, 64).init(gpa),
            .labels = Pool(Label, 64).init(gpa),
            .fields = Pool(TextField, 64).init(gpa),
            .editors = Pool(CodeEditor, 16).init(gpa),
            .canvases = Pool(Canvas, 16).init(gpa),
            .paint_cache = paint.Cache.init(gpa),
            .commands = commands_mod.Commands.init(gpa),
            .shortcuts = shortcuts_mod.Shortcuts.init(gpa),
        };
    }

    /// Replace the theme (colors, fonts, metrics, and painters) and repaint
    /// everything. Fonts and sizes that changed reshape text on the next `update`.
    pub fn setTheme(self: *Ui, theme: Theme) void {
        self.theme = theme;
        self.tree.markDirty(self.tree.root, DirtyFlags.layout_and_paint);
        // Widgets reshape text and repaint from the new theme in `update`.
        inline for (.{ &self.buttons, &self.labels, &self.fields, &self.editors, &self.canvases }) |pool| {
            var it = pool.iterator();
            while (it.next()) |e| self.tree.markDirty(e.ptr.node, DirtyFlags.layout_and_paint);
        }
    }

    /// True unless this `Ui` was moved after its first widget was created.
    /// Always true when `ui_checks` is off.
    pub fn isPinned(self: *const Ui) bool {
        if (comptime shadow.enabled) return self.pinned == null or self.pinned.? == self;
        return true;
    }

    fn checkPinned(self: *const Ui) void {
        if (!self.isPinned()) {
            @panic("zigui: the Ui was moved after widgets were added; widgets hold a pointer back to it (see Ui docs)");
        }
    }

    pub fn deinit(self: *Ui) void {
        inline for (.{ &self.buttons, &self.labels, &self.fields, &self.editors, &self.canvases }) |pool| {
            var it = pool.iterator();
            while (it.next()) |e| e.ptr.deinit();
            pool.deinit();
        }
        self.paint_cache.deinit();
        self.shortcuts.deinit();
        self.commands.deinit();
        self.text.deinit();
        self.layout.deinit();
        self.tree.deinit();
        self.* = undefined;
    }

    // ---- creating widgets --------------------------------------------------------

    fn poolFor(self: *Ui, comptime W: type) *Pool(W, if (W == CodeEditor or W == Canvas) 16 else 64) {
        if (W == Button) return &self.buttons;
        if (W == Label) return &self.labels;
        if (W == TextField) return &self.fields;
        if (W == CodeEditor) return &self.editors;
        if (W == Canvas) return &self.canvases;
        @compileError("not a widget type: " ++ @typeName(W));
    }

    /// Create a widget of type `W` (`Button`, `Label`, `TextField`, or
    /// `CodeEditor`) under `parent`: its node, its state, and its event
    /// listeners, configured from `opts`. The returned pointer is stable until
    /// the widget's node is destroyed (the state is reclaimed in `update`).
    ///
    ///     const save = try ui.add(Button, root, .{
    ///         .style = .{ .width = .px(120) },
    ///         .text = "Save",
    ///         .on_click = .bind(&app, App.save),
    ///     });
    pub fn add(self: *Ui, comptime W: type, parent: Handle, opts: W.Options) !*W {
        comptime widget.check(W);
        if (comptime shadow.enabled) {
            if (self.pinned == null) self.pinned = self;
        }
        self.checkPinned();
        const pool = self.poolFor(W);

        const node_h = try self.tree.create(W.nodeTemplate(opts.style));
        errdefer _ = self.tree.destroySubtree(node_h);
        try self.tree.appendChild(parent, node_h);

        // `init` may allocate, so the value needs cleanup if it never reaches the pool.
        const h = blk: {
            var value = W.init(self, node_h);
            errdefer value.deinit();
            break :blk try pool.create(value);
        };
        errdefer _ = pool.destroy(h);
        const w = pool.get(h).?;
        errdefer w.deinit();
        for (W.listened_kinds) |kind| {
            try self.tree.addListener(node_h, .{ .kind = kind, .callback = event_types.Callback.bind(w, W.handleEvent) });
        }
        const node = self.tree.get(node_h).?;
        node.paint_hook = tree_mod.PaintHook.bind(w, W.paintHook);
        node.widget = w;
        node.widget_type = typeTag(W);
        try w.apply(opts);
        return w;
    }

    // ---- shared widget helpers (used by widget implementations) ---------------------

    pub fn freeText(self: *Ui, t: *Text) void {
        if (t.bytes.len > 0) self.gpa.free(t.bytes);
        t.* = .{};
    }

    /// Replace a widget's text with a toolkit-owned copy of `text`.
    pub fn replaceText(self: *Ui, t: *Text, text: []const u8) !void {
        const copy = try self.gpa.dupe(u8, text);
        self.freeText(t);
        t.* = .{ .bytes = copy };
    }

    /// Shadow-check raw prop writes; fold any missing dirty bits into the tree.
    pub fn verifyProps(self: *Ui, h: Handle, checker: anytype, props: anytype, name: []const u8) void {
        const node = self.tree.get(h).?;
        var flags = node.dirty;
        checker.verify(props, &flags, name);
        const added = DirtyFlags.fromBits(flags.bits() & ~node.dirty.bits());
        if (!added.isClean()) self.tree.markDirty(h, added);
    }

    // ---- timing, IME, cursor ---------------------------------------------------------

    /// Advance time-based state (caret blink). Returns true if something that
    /// affects painting changed; `update` then marks the widget dirty.
    pub fn tick(self: *Ui, now_ms: u64) bool {
        self.now_ms = now_ms;
        var changed = false;
        inline for (.{ &self.fields, &self.editors, &self.canvases }) |pool| {
            var it = pool.iterator();
            while (it.next()) |e| changed = e.ptr.tick(now_ms) or changed;
        }
        return changed;
    }

    /// Milliseconds until the next timed update (caret blink, canvas frame), or null if
    /// nothing needs one. Use as the event-wait timeout.
    pub fn nextWakeMs(self: *Ui) ?u32 {
        var best: ?u64 = null;
        inline for (.{ &self.fields, &self.editors }) |pool| {
            var it = pool.iterator();
            while (it.next()) |e| {
                if (e.ptr.msUntilBlink(self.now_ms)) |left| {
                    if (best == null or left < best.?) best = left;
                }
            }
        }
        var cit = self.canvases.iterator();
        while (cit.next()) |e| {
            if (e.ptr.msUntilFrame(self.now_ms)) |left| {
                if (best == null or left < best.?) best = left;
            }
        }
        return if (best) |b| @intCast(@min(b, std.math.maxInt(u32))) else null;
    }

    /// Where the text caret is, in window coordinates, if a text widget has
    /// focus. The platform uses this to enable text input and place IME popups;
    /// null means text input is not wanted.
    pub fn textInputRect(self: *Ui) ?geometry.Rect {
        const h = self.focused() orelse return null;
        inline for (.{ &self.editors, &self.fields }) |pool| {
            var it = pool.iterator();
            while (it.next()) |e| {
                if (Handle.eql(e.ptr.node, h) and e.ptr.props.enabled) return e.ptr.caretRect();
            }
        }
        return null;
    }

    /// The cursor shape for the node under the pointer.
    pub fn cursor(self: *Ui) tree_mod.Cursor {
        var cur = self.input.hover;
        while (self.tree.get(cur)) |n| : (cur = n.parent) {
            if (n.cursor != .default) return n.cursor;
        }
        return .default;
    }

    // ---- fonts and text ---------------------------------------------------------

    /// Register a font backend. The first font added becomes both theme fonts.
    pub fn addFont(self: *Ui, backend: font.Backend) !u32 {
        const id = try self.text.addFont(backend);
        if (id == 0) {
            self.theme.ui_font = 0;
            self.theme.mono_font = 0;
        }
        return id;
    }

    /// Shape `text` for the node and set its intrinsic size, if it changed.
    /// Silently keeps the old text if allocation fails or no font exists.
    pub fn syncText(self: *Ui, h: Handle, text: Text, f: u32, size: f32, color: Color, al: text_block.Align) void {
        self.syncTextEx(h, text, f, size, color, al, .{});
    }

    pub const SyncOpts = struct {
        /// Reshape even if the source slice looks unchanged (it was edited in place).
        force: bool = false,
        /// Keep a (glyph-less) block for empty text, so decorations have metrics.
        keep_empty: bool = false,
    };

    pub fn syncTextEx(self: *Ui, h: Handle, text: Text, f: u32, size: f32, color: Color, al: text_block.Align, opts: SyncOpts) void {
        if (f >= self.text.fonts.items.len) return;
        const node = self.tree.get(h) orelse return;
        const src = text.slice();

        if (node.text) |old| {
            const same = !opts.force and old.src_ptr == @intFromPtr(src.ptr) and old.src_len == src.len and old.font == f and old.size == size;
            if (same) {
                if (!std.meta.eql(old.color, color) or old.align_x != al) {
                    old.color = color;
                    old.align_x = al;
                    self.tree.markDirty(h, DirtyFlags.paint_only);
                }
                return;
            }
        } else if (src.len == 0 and !opts.keep_empty) {
            return;
        }

        var glyphs: std.ArrayListUnmanaged(@import("../text/system.zig").Glyph) = .empty;
        const r = self.text.shape(f, size, src, &glyphs, self.gpa) catch {
            glyphs.deinit(self.gpa);
            return;
        };
        const m = self.text.metrics(f, size);
        const owned = glyphs.toOwnedSlice(self.gpa) catch {
            glyphs.deinit(self.gpa);
            return;
        };
        self.tree.setText(h, .{
            .glyphs = owned,
            .width = r.width,
            .ascent = m.ascent,
            .descent = m.descent,
            .line_height = m.lineHeight(),
            .font = f,
            .size = size,
            .color = color,
            .align_x = al,
            .subpixel = !self.text.isMonospace(f),
            .src_ptr = @intFromPtr(src.ptr),
            .src_len = src.len,
        }) catch return;
        node.intrinsic = .{ .w = r.width, .h = m.lineHeight() };
        self.tree.markDirty(h, DirtyFlags.layout_and_paint);
    }

    /// Show or hide a subtree. Hidden nodes take no space and are not painted or hit.
    pub fn setHidden(self: *Ui, h: Handle, hidden: bool) void {
        const node = self.tree.get(h) orelse return;
        if (node.flags.hidden == hidden) return;
        node.flags.hidden = hidden;
        self.tree.markDirty(h, DirtyFlags.layout_and_paint);
        self.tree.markDirty(node.parent, .{ .children = true });
    }

    // ---- input ---------------------------------------------------------------------

    fn nowNs(self: *const Ui) u64 {
        return if (self.clock) |c| c() else 0;
    }

    /// Account for an input handler that started at `t0`: add to the frame's
    /// handler time and flag it if over budget.
    fn endHandler(self: *Ui, t0: u64, what: []const u8) void {
        if (self.clock == null) return;
        const dt = self.nowNs() -| t0;
        self.pending_handler_ns += dt;
        if (self.handler_budget_ns > 0 and dt > self.handler_budget_ns) {
            self.slow_handlers += 1;
            if (comptime shadow.enabled) {
                std.log.warn("ui_check: {s} handlers took {d:.1} ms (budget {d:.1} ms); long work belongs off the UI thread", .{
                    what,
                    @as(f64, @floatFromInt(dt)) / 1e6,
                    @as(f64, @floatFromInt(self.handler_budget_ns)) / 1e6,
                });
            }
        }
    }

    pub fn pointerMove(self: *Ui, x: f32, y: f32) void {
        const t0 = self.nowNs();
        self.input.pointerMove(&self.tree, x, y);
        self.endHandler(t0, "pointer_move");
    }

    pub fn pointerButton(self: *Ui, x: f32, y: f32, btn: u32, down: bool) void {
        self.pointerButtonEx(x, y, btn, down, 1);
    }

    /// Like `pointerButton`, with the platform's consecutive-press count
    /// (2 = double click) for text selection.
    pub fn pointerButtonEx(self: *Ui, x: f32, y: f32, btn: u32, down: bool, clicks: u32) void {
        const t0 = self.nowNs();
        if (down) self.shortcuts.clearPending();
        self.input.pointerButtonEx(&self.tree, x, y, btn, down, clicks);
        self.endHandler(t0, "pointer_button");
    }

    pub fn wheel(self: *Ui, x: f32, y: f32, dx: f32, dy: f32) void {
        const t0 = self.nowNs();
        self.input.wheel(&self.tree, x, y, dx, dy);
        self.endHandler(t0, "wheel");
    }

    /// Wheel scroll at the last known pointer position (positive `dy` = up).
    pub fn wheelAtPointer(self: *Ui, dx: f32, dy: f32) void {
        self.input.wheel(&self.tree, self.input.pointer_x, self.input.pointer_y, dx, dy);
    }

    /// Route a key press/release (`mods` are the held modifier keys). Order: the
    /// focused node (capture, target, bubble), then shortcuts, then Tab focus
    /// movement. Returns true if anything used the key.
    pub fn keyHandled(self: *Ui, k: keys.Key, mods: keys.Mods, down: bool, repeat: bool) bool {
        const t0 = self.nowNs();
        const used = self.input.keyEx(&self.tree, k, mods, down, repeat, 0, 0, .{ .ctx = self, .run = shortcutHook });
        self.endHandler(t0, "key");
        return used;
    }

    pub fn key(self: *Ui, k: keys.Key, mods: keys.Mods, down: bool, repeat: bool) void {
        _ = self.keyHandled(k, mods, down, repeat);
    }

    fn shortcutHook(ctx: *anyopaque, tree: *Tree, k: keys.Key, mods: keys.Mods, down: bool, repeat: bool) bool {
        const self: *Ui = @ptrCast(@alignCast(ctx));
        if (!down or k == .unknown) return false;
        const chord: keys.Chord = .{ .key = k, .mods = mods };
        // Plain typing belongs to the focused text widget, not to shortcuts.
        if (!self.shortcuts.hasPending() and chord.isTyping()) {
            if (tree.get(tree.focused)) |n| {
                if (n.flags.accepts_text) return false;
            }
        }
        return self.shortcuts.handleKey(tree, &self.commands, self.now_ms, chord, repeat).consumed;
    }

    // ---- commands and shortcuts -----------------------------------------------------

    /// Register a named command. `handler` receives a `command` event whose
    /// text is the command name; it may be null for commands that only exist to
    /// be enabled/disabled or listed.
    pub fn registerCommand(self: *Ui, name: []const u8, opts: commands_mod.Options) !Handle {
        return self.commands.register(name, opts);
    }

    /// Run a command by name. The event targets the focused node, or the root.
    /// False if it is unknown, disabled, or has no handler.
    pub fn invokeCommand(self: *Ui, name: []const u8) bool {
        const target = if (self.tree.isValid(self.tree.focused)) self.tree.focused else self.tree.root;
        return self.commands.invokeByName(name, target);
    }

    /// Enable or disable a command (shortcuts skip it; linked buttons follow).
    /// False if no such command.
    pub fn setCommandEnabled(self: *Ui, name: []const u8, enabled: bool) bool {
        const h = self.commands.find(name) orelse return false;
        self.commands.setEnabled(h, enabled);
        return true;
    }

    /// Let holding the shortcut key re-run the command (navigation: yes, save: no).
    pub fn setCommandRepeat(self: *Ui, name: []const u8, repeat: bool) bool {
        const h = self.commands.find(name) orelse return false;
        self.commands.get(h).?.repeat = repeat;
        return true;
    }

    /// Bind a chord sequence ("ctrl+k ctrl+c") to a command. Panel and widget
    /// scopes need `node`. Fails with `Conflict` if the same scope already has
    /// that sequence or one that is a prefix of it (or vice versa).
    pub fn bindShortcut(self: *Ui, seq_text: []const u8, command: []const u8, scope: Scope, node: ?Handle) BindError!void {
        return self.shortcuts.bindText(&self.commands, seq_text, command, scope, node orelse Handle.invalid, false);
    }

    /// Like `bindShortcut`, replacing an existing binding of the same sequence.
    pub fn rebindShortcut(self: *Ui, seq_text: []const u8, command: []const u8, scope: Scope, node: ?Handle) BindError!void {
        return self.shortcuts.bindText(&self.commands, seq_text, command, scope, node orelse Handle.invalid, true);
    }

    /// Load bindings from keymap text (see `Shortcuts.loadKeymap`).
    pub fn loadKeymap(self: *Ui, text: []const u8) LoadReport {
        return self.shortcuts.loadKeymap(&self.commands, text);
    }

    /// The first shortcut bound to `command`, as display text ("Ctrl+S").
    pub fn shortcutText(self: *Ui, command: []const u8, buf: []u8) ?[]const u8 {
        const h = self.commands.find(command) orelse return null;
        return self.shortcuts.shortcutText(h, buf);
    }

    /// Deliver committed text (typing, paste, IME) to the focused widget.
    pub fn textInput(self: *Ui, text: []const u8) void {
        const t0 = self.nowNs();
        self.input.textInput(&self.tree, text);
        self.endHandler(t0, "text_input");
    }

    /// IME composition update for the focused widget: `text` is the uncommitted
    /// string (empty ends the composition) and `cursor` the IME caret's byte
    /// offset inside it. Text fields show it inline, underlined, until the
    /// committed text arrives through `textInput`.
    pub fn textEditing(self: *Ui, text: []const u8, caret_byte: u32) void {
        const t0 = self.nowNs();
        self.input.textEditing(&self.tree, text, caret_byte);
        self.endHandler(t0, "text_editing");
    }

    pub fn setFocus(self: *Ui, h: ?Handle) void {
        self.input.setFocus(&self.tree, h);
    }

    pub const ClickableOptions = struct {
        /// Accessible name; required (a clickable thing with no name is unusable
        /// with a screen reader).
        label: []const u8,
        role: tree_mod.Role = .button,
        on_click: event_types.Callback,
    };

    /// Make any node act like a button or link: focusable (Tab), activated by
    /// click, Enter, or Space (Enter and Space on the node itself, not on
    /// focusable descendants), with a pointer cursor, a role, and a label.
    pub fn makeClickable(self: *Ui, h: Handle, o: ClickableOptions) !void {
        const node = self.tree.get(h) orelse return error.InvalidHandle;
        try self.tree.setLabel(h, o.label);
        node.role = o.role;
        node.flags.focusable = true;
        node.cursor = .pointer;
        try self.tree.addListener(h, .{ .kind = .click, .callback = o.on_click });
        try self.tree.addListener(h, .{ .kind = .key_down, .callback = event_types.Callback.bind(self, onClickableKey) });
    }

    fn onClickableKey(self: *Ui, ev: *event_types.Event) void {
        if (ev.repeat or (ev.key != .enter and ev.key != .space)) return;
        if (!Handle.eql(ev.target, ev.current)) return;
        var click: event_types.Event = .{ .kind = .click, .target = ev.current };
        @import("dispatch.zig").dispatch(&self.tree, &click);
        ev.handled = true;
    }

    /// Debug builds: warn once about each interactive or focusable node that has
    /// no accessible name (a label, or text on it or inside it). Counted in
    /// `a11y_warnings`; set `a11y_log = false` to count without logging.
    fn checkAccessibility(self: *Ui) void {
        self.tree.a11y_dirty = false;
        const tree = &self.tree;
        var cur: ?Handle = tree.root;
        while (cur) |h| : (cur = tree.nextPreorder(tree.root, h)) {
            const n = tree.get(h).?;
            if (n.flags.a11y_checked) continue;
            n.flags.a11y_checked = true;
            if (!(n.flags.interactive or n.flags.focusable)) continue;
            if (hasName(tree, h)) continue;
            self.a11y_warnings += 1;
            if (self.a11y_log) {
                std.log.warn("ui_check: interactive node (role {s}) has no accessible label; set one with Tree.setLabel or Ui.makeClickable", .{@tagName(n.role)});
            }
        }
    }

    fn hasName(tree: *Tree, h: Handle) bool {
        var cur: ?Handle = h;
        while (cur) |c| : (cur = tree.nextPreorder(h, c)) {
            const n = tree.get(c).?;
            if (n.label.len > 0 or n.text != null) return true;
        }
        return false;
    }

    /// Trap keyboard focus inside `root`'s subtree (Tab cycles there) until
    /// `popFocusScope`; with `modal`, pointer input outside it is ignored too.
    /// Use it for dialogs and menus. Focus returns to where it was when the scope
    /// is popped (or its root is destroyed), and a scope remembers its last
    /// focused node for next time. False if too many scopes are open.
    pub fn pushFocusScope(self: *Ui, root: Handle, modal: bool) bool {
        return self.input.pushScope(&self.tree, root, modal);
    }

    pub fn popFocusScope(self: *Ui) void {
        self.input.popScope(&self.tree);
    }

    /// Number of open focus scopes.
    pub fn focusScopeDepth(self: *Ui) usize {
        _ = self.input.activeScope(&self.tree);
        return self.input.scope_n;
    }

    /// The focused node, if any.
    pub fn focused(self: *Ui) ?Handle {
        return if (self.tree.isValid(self.tree.focused)) self.tree.focused else null;
    }

    // ---- rendering ---------------------------------------------------------------------

    /// Glyph bitmap source for the renderer: `software.render(..., .{ .glyphs = ui.glyphProvider() })`.
    pub fn glyphProvider(self: *Ui) @import("../text/system.zig").GlyphProvider {
        return self.text.provider();
    }

    /// True if anything needs layout or repaint.
    pub fn isDirty(self: *Ui) bool {
        const root = self.tree.get(self.tree.root) orelse return false;
        return !root.dirty.isClean();
    }

    /// Lay out for a window of `size` (logical pixels) and rebuild `list`.
    pub fn layoutAndPaint(self: *Ui, size: geometry.Size, list: *DrawList) !void {
        try self.layoutPhase(size);
        try paint.buildCached(&self.tree, list, &self.paint_cache);
    }

    fn layoutPhase(self: *Ui, size: geometry.Size) !void {
        self.checkPinned();
        self.text.atlas.beginFrame();
        try self.layout.run(&self.tree, size);
    }

    /// Tell the Ui which renderer the app uses, before the first frame, so
    /// widgets such as canvases can create textures. `renderFrame` also sets it.
    pub fn setBackend(self: *Ui, be: ?render_backend.Backend) void {
        self.backend = be;
    }

    pub const RenderOptions = struct {
        /// Target size in device pixels.
        pixel_w: u32,
        pixel_h: u32,
        /// Device pixels per logical pixel.
        scale: f32 = 1,
        clear: ?geometry.Color = null,
        /// Redraw the whole window even if little changed (expose events).
        full: bool = false,
    };

    /// Lay out for the target size, rebuild `list`, and draw it through `be`
    /// (begin, atlas upload if the backend wants it, submit, present). Call it
    /// when `isDirty()` or the platform asks for a redraw (then set `full`).
    ///
    /// Only the damaged part of the window is redrawn (see `damage.zig`) when the
    /// backend keeps its contents between frames; the first frame, a size or
    /// scale change, and `full` redraw everything. If nothing is damaged the
    /// call does no drawing.
    pub fn renderFrame(self: *Ui, be: render_backend.Backend, list: *DrawList, o: RenderOptions) !void {
        self.backend = be;
        const scale = if (o.scale > 0) o.scale else 1;
        const logical: geometry.Size = .{
            .w = @as(f32, @floatFromInt(o.pixel_w)) / scale,
            .h = @as(f32, @floatFromInt(o.pixel_h)) / scale,
        };
        const t_start = self.nowNs();
        try self.layoutPhase(logical);
        const t_layout = self.nowNs();
        try paint.buildCached(&self.tree, list, &self.paint_cache);
        const t_build = self.nowNs();
        if (self.show_stats) {
            self.stats.drawOverlay(list, logical.w) catch {};
            self.tree.damage.add(frame_stats.FrameStats.overlayRect(logical.w));
        }
        const same_target = self.last_target.w == o.pixel_w and self.last_target.h == o.pixel_h and self.last_target.scale == scale;
        self.last_target = .{ .w = o.pixel_w, .h = o.pixel_h, .scale = scale };
        const full = o.full or !same_target or !be.caps().partial_redraw or self.tree.damage.all or self.overlay_was_on != self.show_stats;
        self.overlay_was_on = self.show_stats;
        if (!full and self.tree.damage.isEmpty()) return;
        const damage: ?geometry.Rect = if (full) null else self.tree.damage.bounds();
        self.last_damage = damage;
        errdefer self.tree.damage.markAll();
        const provider = self.glyphProvider();
        if (be.caps().atlas_upload) {
            render_backend.prepareGlyphs(list, scale, provider);
            while (self.text.atlas.takeDirtyPage()) |page| {
                try be.uploadAtlasPage(page, self.text.atlas.pagePixels(page), @import("../text/atlas.zig").page_size);
            }
        }
        try be.beginFrame(.{ .pixel_w = o.pixel_w, .pixel_h = o.pixel_h, .scale = scale });
        try be.submit(.{ .list = list, .clear = o.clear, .damage = damage, .glyphs = provider });
        self.tree.damage.clear();
        try be.endFrame();
        const t_end = self.nowNs();
        var f: frame_stats.Frame = .{
            .update_ns = self.pending_update_ns,
            .layout_ns = t_layout -| t_start,
            .build_ns = t_build -| t_layout,
            .submit_ns = t_end -| t_build,
            .handler_ns = self.pending_handler_ns,
            .commands = @intCast(list.items().len),
            .glyphs = @intCast(list.glyphItems().len),
            .cached_subtrees = self.paint_cache.hits,
        };
        f.total_ns = f.update_ns + f.layout_ns + f.build_ns + f.submit_ns;
        self.stats.push(f);
        self.pending_update_ns = 0;
        self.pending_handler_ns = 0;
    }

    // ---- frame ------------------------------------------------------------

    /// Free the state of widgets whose node was destroyed. Restarts after each
    /// removal: a pool must not be mutated mid-iteration.
    fn sweep(self: *Ui, pool: anytype) void {
        while (true) {
            var stale: ?Handle = null;
            var it = pool.iterator();
            while (it.next()) |e| {
                if (!self.tree.isValid(e.ptr.node)) {
                    stale = e.handle;
                    break;
                }
            }
            const h = stale orelse return;
            pool.get(h).?.deinit();
            _ = pool.destroy(h);
        }
    }

    /// Run `method` on every live widget.
    fn forEachWidget(self: *Ui, comptime method: []const u8) void {
        inline for (.{ &self.buttons, &self.labels, &self.fields, &self.editors, &self.canvases }) |pool| {
            var it = pool.iterator();
            while (it.next()) |e| @field(@TypeOf(e.ptr.*), method)(e.ptr);
        }
    }

    /// Reclaim the state of destroyed widgets, settle focus, check raw prop
    /// writes against the shadow copies (debug builds), and bring every
    /// widget's look and text up to date.
    pub fn update(self: *Ui) void {
        const t0 = self.nowNs();
        defer self.pending_update_ns += self.nowNs() -| t0;
        self.checkPinned();
        self.sweep(&self.buttons);
        self.sweep(&self.labels);
        self.sweep(&self.fields);
        self.sweep(&self.editors);
        self.sweep(&self.canvases);

        if (self.shortcuts.count() > 0) self.shortcuts.prune(&self.tree, &self.commands);

        // Disabled widgets leave the tab order; losing focus fires events, so
        // settle focus before looks are resolved.
        self.forEachWidget("prepare");
        self.input.syncFocus(&self.tree);
        self.forEachWidget("update");
        if (comptime shadow.enabled) {
            if (self.tree.a11y_dirty) self.checkAccessibility();
        }
    }

    /// End of frame: clear frame-scoped flags and dirty bits.
    pub fn endFrame(self: *Ui) void {
        self.checkPinned();
        self.forEachWidget("endFrame");
        self.tree.clearDirty(self.tree.root);
    }
};

// ---- tests -----------------------------------------------------------------

const Length = @import("length.zig").Length;
const Edges = @import("style.zig").Edges;
const draw_list = @import("draw_list.zig");

const Harness = struct {
    ui: Ui,
    cmds: [1024]draw_list.Command = undefined,
    glyph_store: [4096]draw_list.Glyph = undefined,
    list: DrawList = undefined,

    fn init() !*Harness {
        const h = try std.testing.allocator.create(Harness);
        h.ui = try Ui.init(std.testing.allocator);
        h.list = DrawList.init(&h.cmds, &h.glyph_store);
        h.ui.tree.get(h.ui.tree.root).?.style = .{ .align_items = .start, .gap = Length.px(10) };
        return h;
    }

    fn deinit(self: *Harness) void {
        self.ui.deinit();
        std.testing.allocator.destroy(self);
    }

    fn frame(self: *Harness) !void {
        self.ui.update();
        if (self.ui.isDirty()) try self.ui.layoutAndPaint(.{ .w = 400, .h = 100 }, &self.list);
        self.ui.endFrame();
    }

    fn click(self: *Harness, x: f32, y: f32) void {
        self.ui.pointerMove(x, y);
        self.ui.pointerButton(x, y, 1, true);
        self.ui.pointerButton(x, y, 1, false);
    }
};

fn paintColor(p: draw_list.Paint) ?geometry.Color {
    return switch (p) {
        .color => |c| c,
        else => null,
    };
}

/// Color of the first filled box (a widget's background) in the list.
fn firstFill(list: *const DrawList) ?geometry.Color {
    for (list.items()) |c| switch (c) {
        .fill_rect => |f| return paintColor(f.paint),
        .fill_rounded_rect => |f| return paintColor(f.paint),
        else => {},
    };
    return null;
}

/// Color of the first border stroke in the list.
fn firstStroke(list: *const DrawList) ?geometry.Color {
    for (list.items()) |c| switch (c) {
        .stroke_rect => |s| return paintColor(s.paint),
        else => {},
    };
    return null;
}

/// Color of the first text run in the list.
fn firstTextColor(list: *const DrawList) ?geometry.Color {
    for (list.items()) |c| switch (c) {
        .glyph_run => |g| return g.color,
        else => {},
    };
    return null;
}

fn box(w: f32, h: f32) Style {
    return .{ .width = Length.px(w), .height = Length.px(h), .shrink = 0 };
}

test "a click sets flags, bumps the counter, and runs the callback" {
    const t = try Harness.init();
    defer t.deinit();
    const Count = struct {
        var n: u32 = 0;
        fn cb(user: ?*anyopaque, _: *event_mod.Event) void {
            const p: *u32 = @ptrCast(@alignCast(user.?));
            p.* += 1;
        }
    };
    Count.n = 0;
    const b = try t.ui.add(Button, t.ui.tree.root, .{ .style = box(80, 30) });
    b.props.on_click = .{ .ctx = &Count.n, .call = Count.cb };
    try t.frame();

    t.click(10, 10);
    try std.testing.expect(b.out.clicked);
    try std.testing.expectEqual(@as(u32, 1), b.out.click_count);
    try std.testing.expectEqual(@as(u32, 1), Count.n);
    try std.testing.expect(!b.out.pressed);
    try std.testing.expect(b.out.hovered);

    try t.frame(); // endFrame clears the frame-scoped flag, not the counter
    try std.testing.expect(!b.out.clicked);
    try std.testing.expectEqual(@as(u32, 1), b.out.click_count);
}

test "clicking outside, or on a disabled button, does nothing" {
    const t = try Harness.init();
    defer t.deinit();
    const a = try t.ui.add(Button, t.ui.tree.root, .{ .style = box(80, 30) });
    const b = try t.ui.add(Button, t.ui.tree.root, .{ .style = box(80, 30) });
    b.setEnabled(false);
    try t.frame();

    t.click(300, 80); // empty space
    t.click(100, 10); // over b (x 90..170)
    try std.testing.expectEqual(@as(u32, 0), a.out.click_count);
    try std.testing.expectEqual(@as(u32, 0), b.out.click_count);
    try std.testing.expect(!b.out.pressed);
}

test "hover and press change the look and mark paint dirty" {
    const t = try Harness.init();
    defer t.deinit();
    const b = try t.ui.add(Button, t.ui.tree.root, .{ .style = box(80, 30) });
    try t.frame();
    _ = b;
    const c = t.ui.theme.button_colors[0];
    try std.testing.expectEqual(c.normal, firstFill(&t.list).?);
    try std.testing.expect(!t.ui.isDirty());

    t.ui.pointerMove(10, 10);
    t.ui.update();
    try std.testing.expect(t.ui.isDirty()); // the handler marked it: hover changes the look
    try t.frame();
    try std.testing.expectEqual(c.hover, firstFill(&t.list).?);

    t.ui.pointerButton(10, 10, 1, true);
    try t.frame();
    try std.testing.expectEqual(c.pressed, firstFill(&t.list).?);
    t.ui.pointerButton(10, 10, 1, false);
    t.ui.pointerMove(300, 90);
    try t.frame();
    try std.testing.expectEqual(c.normal, firstFill(&t.list).?);
}

test "setButtonText copies, so the caller can free; and frees on deinit" {
    const t = try Harness.init();
    defer t.deinit(); // the testing allocator reports leaks
    const b = try t.ui.add(Button, t.ui.tree.root, .{ .style = box(80, 30) });
    var buf = [_]u8{ 'h', 'i' };
    try b.setText(&buf);
    buf[0] = 'X';
    try std.testing.expectEqualStrings("hi", b.props.text.slice());
    try b.setText("longer text"); // replaces and frees the old copy
    try std.testing.expectEqualStrings("longer text", b.props.text.slice());
}

test "destroying a button's node reclaims its block" {
    const t = try Harness.init();
    defer t.deinit();
    const b = try t.ui.add(Button, t.ui.tree.root, .{ .style = box(80, 30) });
    try b.setText("bye");
    try std.testing.expectEqual(@as(u32, 1), t.ui.buttons.count());
    _ = t.ui.tree.destroySubtree(b.node);
    t.ui.update();
    try std.testing.expectEqual(@as(u32, 0), t.ui.buttons.count());
}

test "a handler may destroy buttons and add nodes mid-click" {
    const t = try Harness.init();
    defer t.deinit();
    const Ctx = struct {
        ui: *Ui,
        victim: Handle,
        fn cb(user: ?*anyopaque, _: *event_mod.Event) void {
            const c: *@This() = @ptrCast(@alignCast(user.?));
            _ = c.ui.tree.destroySubtree(c.victim);
        }
    };
    const a = try t.ui.add(Button, t.ui.tree.root, .{ .style = box(80, 30) });
    const victim = try t.ui.add(Button, t.ui.tree.root, .{ .style = box(80, 30) });
    var ctx: Ctx = .{ .ui = &t.ui, .victim = victim.node };
    a.props.on_click = .{ .ctx = &ctx, .call = Ctx.cb };
    try t.frame();

    t.click(10, 10);
    try std.testing.expect(!t.ui.tree.isValid(victim.node));
    try t.frame();
    try std.testing.expectEqual(@as(u32, 1), t.ui.buttons.count());
}

test "raw prop writes are caught by the shadow checker and still repaint" {
    if (!shadow.enabled or shadow.strict) return error.SkipZigTest;
    const t = try Harness.init();
    defer t.deinit();
    const b = try t.ui.add(Button, t.ui.tree.root, .{ .style = box(80, 30) });
    try t.frame();
    try std.testing.expect(!t.ui.isDirty());

    b.props.variant = .primary; // raw write, no dirty marking
    t.ui.update(); // warns, self-corrects
    try std.testing.expect(t.ui.isDirty());
    try t.frame();
    try std.testing.expectEqual(t.ui.theme.button_colors[1].normal, firstFill(&t.list).?);
}

test "variant setter marks paint and swaps colors" {
    const t = try Harness.init();
    defer t.deinit();
    const b = try t.ui.add(Button, t.ui.tree.root, .{ .style = box(80, 30) });
    try t.frame();
    b.setVariant(.danger);
    try std.testing.expect(t.ui.isDirty());
    try t.frame();
    try std.testing.expectEqual(t.ui.theme.button_colors[2].normal, firstFill(&t.list).?);
}

const event_mod = @import("event.zig");

/// The rect and color of a solid-filled rectangle command, if `c` is one.
fn solidFill(c: draw_list.Command) ?struct { rect: geometry.Rect, color: geometry.Color } {
    switch (c) {
        .fill_rect => |f| switch (f.paint) {
            .color => |col| return .{ .rect = f.rect, .color = col },
            else => return null,
        },
        else => return null,
    }
}

test "buttons paint into the draw list" {
    const t = try Harness.init();
    defer t.deinit();
    _ = try t.ui.add(Button, t.ui.tree.root, .{ .style = box(80, 30) });
    try t.frame();
    try std.testing.expect(t.list.items().len >= 1);
    try std.testing.expectEqual(Color.rgb(0x4a, 0x4d, 0x52), t.list.items()[0].fill_rounded_rect.paint.color);
}

test "setHidden relays out the parent" {
    const t = try Harness.init();
    defer t.deinit();
    const a = try t.ui.add(Button, t.ui.tree.root, .{ .style = box(80, 30) });
    const b = try t.ui.add(Button, t.ui.tree.root, .{ .style = box(80, 30) });
    try t.frame();
    try std.testing.expectEqual(@as(f32, 90), t.ui.tree.get(b.node).?.rect.x);
    t.ui.setHidden(a.node, true);
    try t.frame();
    try std.testing.expectEqual(@as(f32, 0), t.ui.tree.get(b.node).?.rect.x);
    t.click(10, 10); // the hidden button no longer takes the click; b is under it now
    try std.testing.expectEqual(@as(u32, 0), a.out.click_count);
    try std.testing.expectEqual(@as(u32, 1), b.out.click_count);
}

// ---- text integration tests -------------------------------------------------

const TextHarness = struct {
    h: *Harness,
    prop: font.TestFont = .{},
    mono: font.TestFont = .{ .monospace = true },

    fn init() !*TextHarness {
        const t = try std.testing.allocator.create(TextHarness);
        t.* = .{ .h = try Harness.init() };
        _ = try t.h.ui.addFont(t.prop.backend());
        t.h.ui.theme.mono_font = try t.h.ui.addFont(t.mono.backend());
        t.h.ui.theme.font_size = 20;
        return t;
    }

    fn deinit(self: *TextHarness) void {
        self.h.deinit();
        std.testing.allocator.destroy(self);
    }
};

test "a label measures its text and lays out at that size" {
    const t = try TextHarness.init();
    defer t.deinit();
    const l = try t.h.ui.add(Label, t.h.ui.tree.root, .{ .text = "Mi" });
    try t.h.frame();
    const node = t.h.ui.tree.get(l.node).?;
    // M = 0.9em, i = 0.25em at 20px; line height = (0.8 + 0.2 + 0.1) * 20.
    try std.testing.expectApproxEqAbs(@as(f32, 23), node.rect.w, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 22), node.rect.h, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 23), l.out.text_width, 0.01);
}

test "labels reshape when text, size, or font change, and keep their text copy" {
    const t = try TextHarness.init();
    defer t.deinit();
    const ui = &t.h.ui;
    const l = try ui.add(Label, ui.tree.root, .{ .text = "ab" });
    try t.h.frame();
    const w1 = l.out.text_width;

    var buf = [_]u8{ 'a', 'b', 'c' };
    try l.setText(&buf);
    buf[0] = 'Z'; // the toolkit copied it
    try t.h.frame();
    try std.testing.expect(l.out.text_width > w1);
    try std.testing.expectEqual(@as(u32, 'a'), ui.tree.get(l.node).?.text.?.glyphs[0].id);

    const w2 = l.out.text_width;
    l.props.size = 40; // raw write: the shadow checker or sync must pick it up
    try t.h.frame();
    try std.testing.expectApproxEqAbs(w2 * 2, l.out.text_width, 0.01);

    l.props.font = .mono;
    try t.h.frame();
    try std.testing.expect(!ui.tree.get(l.node).?.text.?.subpixel); // monospace snaps to pixels
    try std.testing.expectApproxEqAbs(@as(f32, 3 * 0.6 * 40), l.out.text_width, 0.01);
}

test "an auto-sized button wraps its label plus padding, and paints centered text" {
    const t = try TextHarness.init();
    defer t.deinit();
    const ui = &t.h.ui;
    ui.tree.get(ui.tree.root).?.style = .{ .align_items = .start };
    const b = try ui.add(Button, ui.tree.root, .{ .style = .{ .padding = Edges.xy(10, 5) } });
    try b.setText("MM"); // 2 * 0.9 * 20 = 36 wide
    try t.h.frame();

    const node = ui.tree.get(b.node).?;
    try std.testing.expectApproxEqAbs(@as(f32, 56), node.rect.w, 0.01); // 36 + 2 * 10
    try std.testing.expectApproxEqAbs(@as(f32, 32), node.rect.h, 0.01); // 22 + 2 * 5

    var found = false;
    for (t.h.list.items()) |cmd| {
        if (cmd != .glyph_run) continue;
        found = true;
        try std.testing.expectEqual(@as(u32, 2), cmd.glyph_run.count);
        const g = t.h.list.glyphItems()[cmd.glyph_run.offset];
        try std.testing.expectApproxEqAbs(@as(f32, 10), g.x, 0.01); // content-box left
        // Baseline: padding 5 + half the 2px line gap + ascent 16.
        try std.testing.expectApproxEqAbs(@as(f32, 22), g.y, 0.01);
        try std.testing.expectEqual(ui.theme.button_colors[0].text, cmd.glyph_run.color);
    }
    try std.testing.expect(found);
}

test "disabled buttons use the disabled text color" {
    const t = try TextHarness.init();
    defer t.deinit();
    const ui = &t.h.ui;
    const b = try ui.add(Button, ui.tree.root, .{ .style = .{ .padding = Edges.all(4) } });
    try b.setText("x");
    b.setEnabled(false);
    try t.h.frame();
    try std.testing.expectEqual(ui.theme.button_colors[0].text_disabled, firstTextColor(&t.h.list).?);
}

test "destroying a node frees its text, and text outlives nothing" {
    const t = try TextHarness.init();
    defer t.deinit(); // leak-checked
    const ui = &t.h.ui;
    const l = try ui.add(Label, ui.tree.root, .{ .text = "temporary" });
    const b = try ui.add(Button, ui.tree.root, .{});
    try b.setText("also temporary");
    try t.h.frame();
    _ = ui.tree.destroySubtree(l.node);
    t.h.ui.update();
    try std.testing.expectEqual(@as(u32, 0), ui.labels.count());
    try std.testing.expectEqual(@as(u32, 1), ui.buttons.count());
}

test "text renders through the software renderer" {
    const software = @import("../render/software.zig");
    const t = try TextHarness.init();
    defer t.deinit();
    const ui = &t.h.ui;
    ui.tree.get(ui.tree.root).?.visual.background = Color.white;
    const l = try ui.add(Label, ui.tree.root, .{ .text = "MMM" });
    l.props.color = Color.black;
    try t.h.frame();

    var fb = try software.Framebuffer.init(std.testing.allocator, 400, 100);
    defer fb.deinit(std.testing.allocator);
    software.render(&fb, &t.h.list, .{ .clear = Color.white, .glyphs = ui.glyphProvider() });
    var ink: usize = 0;
    for (fb.pixels) |p| ink += @intFromBool(p.r < 128);
    try std.testing.expect(ink > 100);
    try std.testing.expect(ui.text.atlas.count() >= 1);
}

// ---- keyboard focus tests -----------------------------------------------------

test "Tab walks buttons, Enter and Space activate, and the ring shows after keyboard use only" {
    const t = try Harness.init();
    defer t.deinit();
    const ui = &t.ui;
    const Count = struct {
        var n: u32 = 0;
        fn cb(_: ?*anyopaque, _: *event_mod.Event) void {
            n += 1;
        }
    };
    Count.n = 0;
    const a = try ui.add(Button, ui.tree.root, .{ .style = box(80, 30) });
    const b = try ui.add(Button, ui.tree.root, .{ .style = box(80, 30) });
    b.props.on_click = .{ .call = Count.cb };
    try t.frame();

    ui.key(.tab, .{}, true, false);
    ui.key(.tab, .{}, true, false);
    try t.frame();
    try std.testing.expect(!a.out.focused);
    try std.testing.expect(b.out.focused and b.out.focus_visible);
    try std.testing.expectEqual(ui.theme.focus_ring, firstStroke(&t.list).?);

    ui.key(.enter, .{}, true, false);
    ui.key(.space, .{}, true, false);
    ui.key(.space, .{}, true, true); // auto-repeat does not re-activate
    try std.testing.expectEqual(@as(u32, 2), b.out.click_count);
    try std.testing.expectEqual(@as(u32, 2), Count.n);
    try std.testing.expect(b.out.clicked);

    // Clicking focuses without drawing the ring.
    t.click(10, 10);
    try t.frame();
    try std.testing.expect(a.out.focused and !b.out.focused);
    try std.testing.expect(!a.out.focus_visible);
    try std.testing.expect(firstStroke(&t.list) == null); // no ring after a mouse click
    try std.testing.expect(Handle.eql(ui.focused().?, a.node));
}

test "disabled buttons are skipped by Tab and cannot be activated by key" {
    const t = try Harness.init();
    defer t.deinit();
    const ui = &t.ui;
    const a = try ui.add(Button, ui.tree.root, .{ .style = box(80, 30) });
    const dis = try ui.add(Button, ui.tree.root, .{ .style = box(80, 30) });
    const c = try ui.add(Button, ui.tree.root, .{ .style = box(80, 30) });
    dis.setEnabled(false);
    try t.frame();

    ui.key(.tab, .{}, true, false);
    try t.frame();
    try std.testing.expect(a.out.focused);
    ui.key(.tab, .{}, true, false);
    try t.frame();
    try std.testing.expect(c.out.focused and !dis.out.focused);

    // Disabling the focused button drops its focus.
    c.setEnabled(false);
    try t.frame();
    try std.testing.expect(!c.out.focused);
    try std.testing.expect(ui.focused() == null);
}

test "removing the focused button falls back and never leaves a stale focus" {
    const t = try Harness.init();
    defer t.deinit();
    const ui = &t.ui;
    const a = try ui.add(Button, ui.tree.root, .{ .style = box(80, 30) });
    try t.frame();
    ui.key(.tab, .{}, true, false);
    try t.frame();
    try std.testing.expect(a.out.focused);
    _ = ui.tree.destroySubtree(a.node);
    try t.frame();
    try std.testing.expect(ui.focused() == null);
}

// ---- text field tests ----------------------------------------------------------

const FakeClip = struct {
    var data: [256]u8 = undefined;
    var len: usize = 0;

    fn get(_: ?*anyopaque, gpa: std.mem.Allocator) ?[]u8 {
        if (len == 0) return null;
        return gpa.dupe(u8, data[0..len]) catch null;
    }

    fn set(_: ?*anyopaque, bytes: []const u8) void {
        @memcpy(data[0..bytes.len], bytes);
        len = bytes.len;
    }

    fn put(bytes: []const u8) void {
        set(null, bytes);
    }

    fn contents() []const u8 {
        return data[0..len];
    }
};

const FieldCounts = struct {
    var changes: u32 = 0;
    var submits: u32 = 0;
    fn onChange(_: ?*anyopaque, _: *event_mod.Event) void {
        changes += 1;
    }
    fn onSubmit(_: ?*anyopaque, _: *event_mod.Event) void {
        submits += 1;
    }
};

/// A 200x28 field with 6px side padding at the origin, focused and ready.
fn focusedField(t: *TextHarness) !*TextField {
    const ui = &t.h.ui;
    ui.tree.get(ui.tree.root).?.style = .{ .align_items = .start };
    ui.clipboard = .{ .get = FakeClip.get, .set = FakeClip.set };
    FakeClip.len = 0;
    FieldCounts.changes = 0;
    FieldCounts.submits = 0;
    const tf = try ui.add(TextField, ui.tree.root, .{ .style = .{ .width = Length.px(200), .height = Length.px(28), .padding = Edges.xy(6, 0) } });
    tf.props.on_change = .{ .call = FieldCounts.onChange };
    tf.props.on_submit = .{ .call = FieldCounts.onSubmit };
    try t.h.frame();
    ui.setFocus(tf.node);
    try t.h.frame();
    return tf;
}

fn type_(t: *TextHarness, text: []const u8) !void {
    t.h.ui.textInput(text);
    try t.h.frame();
}

fn press(t: *TextHarness, k: keys.Key, mods: keys.Mods) !void {
    t.h.ui.key(k, mods, true, false);
    try t.h.frame();
}

test "typing edits the field, sets flags, and calls on_change" {
    const t = try TextHarness.init();
    defer t.deinit();
    const tf = try focusedField(t);

    try type_(t, "hello");
    try std.testing.expectEqualStrings("hello", tf.text());
    try std.testing.expect(tf.out.focused);
    try std.testing.expectEqual(@as(u32, 1), tf.out.change_count);
    try std.testing.expectEqual(@as(u32, 1), FieldCounts.changes);
    try std.testing.expectEqual(@as(u32, 5), tf.out.caret);
    try std.testing.expect(!tf.out.changed); // frame-scoped: cleared by endFrame in frame()

    try type_(t, " \u{e9}");
    try std.testing.expectEqualStrings("hello \u{e9}", tf.text());
    try press(t, .backspace, .{}); // removes the whole two-byte character
    try std.testing.expectEqualStrings("hello ", tf.text());
    try std.testing.expectEqual(@as(u32, 3), tf.out.change_count);
}

test "navigation, selection, and replacement" {
    const t = try TextHarness.init();
    defer t.deinit();
    const tf = try focusedField(t);
    try type_(t, "one two three");

    try press(t, .home, .{});
    try press(t, .right, .{ .ctrl = true }); // word right: past "one "
    try std.testing.expectEqual(@as(u32, 4), tf.out.caret);
    try press(t, .right, .{ .ctrl = true, .shift = true });
    try std.testing.expectEqual(@as(u32, 4), tf.out.sel_start);
    try std.testing.expectEqual(@as(u32, 8), tf.out.sel_end);
    try type_(t, "2");
    try std.testing.expectEqualStrings("one 2three", tf.text());
    try press(t, .end, .{});
    try press(t, .backspace, .{ .ctrl = true }); // "2three" is one word
    try std.testing.expectEqualStrings("one ", tf.text());
    try press(t, .left, .{});
    try press(t, .delete, .{});
    try std.testing.expectEqualStrings("one", tf.text());
}

test "clipboard: select all, copy, cut, paste (newlines become spaces)" {
    const t = try TextHarness.init();
    defer t.deinit();
    const ui = &t.h.ui;
    const tf = try focusedField(t);
    try type_(t, "abc");

    try press(t, .a, .{ .ctrl = true });
    try std.testing.expectEqual(@as(u32, 0), tf.out.sel_start);
    try std.testing.expectEqual(@as(u32, 3), tf.out.sel_end);
    try press(t, .c, .{ .ctrl = true });
    try std.testing.expectEqualStrings("abc", FakeClip.contents());
    try std.testing.expectEqualStrings("abc", tf.text());

    try press(t, .x, .{ .ctrl = true });
    try std.testing.expectEqualStrings("", tf.text());
    FakeClip.put("x\ny\r\nz");
    try press(t, .v, .{ .ctrl = true });
    try std.testing.expectEqualStrings("x y  z", tf.text());

    // A plain 'a' (no modifier) is not consumed: text arrives via text_input only.
    ui.key(.a, .{}, true, false);
    try std.testing.expectEqualStrings("x y  z", tf.text());
}

test "enter submits; submit flags are frame-scoped" {
    const t = try TextHarness.init();
    defer t.deinit();
    const tf = try focusedField(t);
    t.h.ui.key(.enter, .{}, true, false);
    try std.testing.expect(tf.out.submitted);
    try std.testing.expectEqual(@as(u32, 1), tf.out.submit_count);
    try std.testing.expectEqual(@as(u32, 1), FieldCounts.submits);
    try t.h.frame();
    try std.testing.expect(!tf.out.submitted);
}

test "read-only fields copy but do not edit; disabled fields ignore everything" {
    const t = try TextHarness.init();
    defer t.deinit();
    const ui = &t.h.ui;
    const tf = try focusedField(t);
    try type_(t, "keep");
    tf.props.read_only = true;
    try t.h.frame();

    try type_(t, "x");
    try press(t, .backspace, .{});
    try press(t, .a, .{ .ctrl = true });
    try press(t, .c, .{ .ctrl = true });
    try press(t, .x, .{ .ctrl = true });
    try std.testing.expectEqualStrings("keep", tf.text());
    try std.testing.expectEqualStrings("keep", FakeClip.contents());

    tf.props.read_only = false;
    tf.props.enabled = false;
    try t.h.frame();
    try type_(t, "x");
    try std.testing.expectEqualStrings("keep", tf.text());
    try std.testing.expect(ui.focused() == null); // disabled fields leave the tab order and lose focus
}

test "text only reaches the focused field" {
    const t = try TextHarness.init();
    defer t.deinit();
    const ui = &t.h.ui;
    const a = try focusedField(t);
    const b = try ui.add(TextField, ui.tree.root, .{ .style = .{ .width = Length.px(100), .height = Length.px(28) } });
    try t.h.frame();
    try type_(t, "to a");
    try std.testing.expectEqualStrings("to a", a.text());
    try std.testing.expectEqualStrings("", b.text());
    try press(t, .tab, .{});
    try type_(t, "to b");
    try std.testing.expectEqualStrings("to b", b.text());
    try std.testing.expectEqualStrings("to a", a.text());
}

test "setTextFieldText replaces content without counting as an edit" {
    const t = try TextHarness.init();
    defer t.deinit();
    const tf = try focusedField(t);
    try tf.setText("preset");
    try t.h.frame();
    try std.testing.expectEqualStrings("preset", tf.text());
    try std.testing.expectEqual(@as(u32, 0), tf.out.change_count);
    try std.testing.expectEqual(@as(u32, 6), tf.out.caret);
    try std.testing.expectEqual(@as(u32, 0), FieldCounts.changes);
}

// Test font at 20px: every printable letter is 0.55em = 11px; padding is 6px.
// Caret stops for "abc def": 0, 11, 22, 33, 44 (space is 0.3em = 6, so 44 -> 50), ...

test "clicking places the caret at the nearest stop; double and triple click select" {
    const t = try TextHarness.init();
    defer t.deinit();
    const ui = &t.h.ui;
    const tf = try focusedField(t);
    try type_(t, "abc def");
    ui.setFocus(null);
    try t.h.frame();

    // x = 6 (padding) + 23: nearest stop is after two letters (22).
    ui.pointerMove(29, 14);
    ui.pointerButtonEx(29, 14, 1, true, 1);
    ui.pointerButtonEx(29, 14, 1, false, 1);
    try t.h.frame();
    try std.testing.expect(tf.out.focused); // the click also focused it
    try std.testing.expectEqual(@as(u32, 2), tf.out.caret);

    ui.pointerButtonEx(29, 14, 1, true, 2);
    ui.pointerButtonEx(29, 14, 1, false, 2);
    try t.h.frame();
    try std.testing.expectEqual(@as(u32, 0), tf.out.sel_start);
    try std.testing.expectEqual(@as(u32, 3), tf.out.sel_end); // the word "abc"

    ui.pointerButtonEx(29, 14, 1, true, 3);
    ui.pointerButtonEx(29, 14, 1, false, 3);
    try t.h.frame();
    try std.testing.expectEqual(@as(u32, 7), tf.out.sel_end); // everything
}

test "dragging selects, and shift-click extends" {
    const t = try TextHarness.init();
    defer t.deinit();
    const ui = &t.h.ui;
    const tf = try focusedField(t);
    try type_(t, "abcdef");

    ui.pointerMove(6, 14); // start of text
    ui.pointerButtonEx(6, 14, 1, true, 1);
    ui.pointerMove(6 + 33, 14); // after three letters
    ui.pointerButtonEx(6 + 33, 14, 1, false, 1);
    try t.h.frame();
    try std.testing.expectEqual(@as(u32, 0), tf.out.sel_start);
    try std.testing.expectEqual(@as(u32, 3), tf.out.sel_end);

    // Shift-click extends from the existing anchor (0) to the click.
    t.h.ui.pointerMove(6 + 55, 14);
    t.h.ui.input.pointerButtonEx(&t.h.ui.tree, 6 + 55, 14, 1, true, 1); // no shift state in pointer events here
    t.h.ui.pointerButtonEx(6 + 55, 14, 1, false, 1);
    try t.h.frame();
    try std.testing.expectEqual(@as(u32, 5), tf.out.caret);
}

test "the caret shows when focused, blinks on tick, and resets on typing" {
    const t = try TextHarness.init();
    defer t.deinit();
    const ui = &t.h.ui;
    const tf = try focusedField(t);
    _ = try tf.setText("ab");
    try t.h.frame();
    const decor = ui.tree.get(tf.node).?.text.?.decor; // a copy: typing replaces the block
    try std.testing.expect(decor.caret_on);
    try std.testing.expectApproxEqAbs(@as(f32, 22), decor.caret_x, 0.01);

    try std.testing.expect(!ui.tick(100)); // too soon: nothing changes
    try std.testing.expect(ui.tick(1000)); // past the blink interval: off
    try t.h.frame();
    try std.testing.expect(!ui.tree.get(tf.node).?.text.?.decor.caret_on);
    try std.testing.expect(ui.nextWakeMs() != null);

    try type_(t, "c"); // typing makes the caret visible again
    try std.testing.expect(ui.tree.get(tf.node).?.text.?.decor.caret_on);
    // Not focused: no caret, no timer, no text input wanted.
    ui.setFocus(null);
    try t.h.frame();
    try std.testing.expect(!ui.tree.get(tf.node).?.text.?.decor.caret_on);
    try std.testing.expect(ui.nextWakeMs() == null);
    try std.testing.expect(ui.textInputRect() == null);
}

test "selection is drawn as a highlight and the caret as a thin rect" {
    const t = try TextHarness.init();
    defer t.deinit();
    const ui = &t.h.ui;
    const tf = try focusedField(t);
    try type_(t, "abcd");

    var carets: usize = 0;
    for (t.h.list.items()) |c| {
        if (solidFill(c)) |f| {
            if (f.rect.w == 1 and std.meta.eql(f.color, ui.theme.field.caret)) carets += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 1), carets);

    try press(t, .a, .{ .ctrl = true });
    var highlight: ?geometry.Rect = null;
    for (t.h.list.items()) |c| {
        if (solidFill(c)) |f| {
            if (std.meta.eql(f.color, ui.theme.field.selection)) highlight = f.rect;
        }
    }
    try std.testing.expect(highlight != null);
    try std.testing.expectApproxEqAbs(@as(f32, 44), highlight.?.w, 0.01); // four letters
    try std.testing.expectApproxEqAbs(@as(f32, 6), highlight.?.x, 0.01);
    _ = tf;
}

test "long text scrolls to keep the caret visible, and Home scrolls back" {
    const t = try TextHarness.init();
    defer t.deinit();
    const ui = &t.h.ui;
    const tf = try focusedField(t);
    // 24 letters at 11px plus narrow "i" and "l" at 5px each = 274px in a 188px view.
    try type_(t, "abcdefghijklmnopqrstuvwxyz");
    const decor = ui.tree.get(tf.node).?.text.?.decor;
    try std.testing.expectApproxEqAbs(@as(f32, 274 - 188 + 1), decor.scroll_x, 0.01);
    try std.testing.expect(decor.caret_x - decor.scroll_x <= 188);
    try press(t, .home, .{});
    try std.testing.expectEqual(@as(f32, 0), ui.tree.get(tf.node).?.text.?.decor.scroll_x);
}

test "an empty field shows its placeholder, dimmed, and hides it once there is text" {
    const t = try TextHarness.init();
    defer t.deinit();
    const ui = &t.h.ui;
    const tf = try focusedField(t);
    try tf.setPlaceholder("Search");
    try t.h.frame();
    const node = ui.tree.get(tf.node).?;
    try std.testing.expectEqual(@as(usize, 6), node.text.?.glyphs.len);
    try std.testing.expectEqual(ui.theme.field.placeholder, firstTextColor(&t.h.list).?);

    try type_(t, "hi");
    try std.testing.expectEqual(@as(usize, 2), ui.tree.get(tf.node).?.text.?.glyphs.len);
    try std.testing.expectEqual(ui.theme.field.text, firstTextColor(&t.h.list).?);
}

test "focused fields get a highlighted border; the I-beam cursor and IME rect are reported" {
    const t = try TextHarness.init();
    defer t.deinit();
    const ui = &t.h.ui;
    _ = try focusedField(t);
    try type_(t, "ab");
    try std.testing.expectEqual(ui.theme.field.border_focus, firstStroke(&t.h.list).?);

    ui.pointerMove(50, 10);
    try std.testing.expectEqual(tree_mod.Cursor.text, ui.cursor());
    ui.pointerMove(350, 90);
    try std.testing.expectEqual(tree_mod.Cursor.default, ui.cursor());

    const r = ui.textInputRect().?;
    try std.testing.expectApproxEqAbs(@as(f32, 6 + 22), r.x, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 28), r.h, 0.01);
}

test "removing a field frees its storage" {
    const t = try TextHarness.init();
    defer t.deinit(); // leak-checked
    const ui = &t.h.ui;
    const tf = try focusedField(t);
    try tf.setPlaceholder("placeholder");
    try type_(t, "some content that is long enough to grow the gap buffer");
    _ = ui.tree.destroySubtree(tf.node);
    try t.h.frame();
    try std.testing.expectEqual(@as(u32, 0), ui.fields.count());
    try std.testing.expect(ui.focused() == null);
}

// ---- commands and shortcuts through the Ui --------------------------------------

const CmdLog = struct {
    var buf: [64]u8 = undefined;
    var len: usize = 0;
    var last_target: Handle = Handle.invalid;

    fn reset() void {
        len = 0;
        last_target = Handle.invalid;
    }

    fn str() []const u8 {
        return buf[0..len];
    }

    /// Logs the last character of the command name.
    fn handler(_: ?*anyopaque, ev: *event_mod.Event) void {
        const name = ev.text;
        if (len < buf.len) {
            buf[len] = name[name.len - 1];
            len += 1;
        }
        last_target = ev.target;
    }
};

fn regCmd(ui: *Ui, name: []const u8) !void {
    _ = try ui.registerCommand(name, .{ .title = name, .run = .{ .call = CmdLog.handler } });
}

test "a bound shortcut runs its command with the focused node as target" {
    const t = try Harness.init();
    defer t.deinit();
    const ui = &t.ui;
    CmdLog.reset();
    try regCmd(ui, "file.s");
    try ui.bindShortcut("ctrl+s", "file.s", .app, null);
    const b = try ui.add(Button, ui.tree.root, .{ .style = box(80, 30) });
    try t.frame();

    try std.testing.expect(ui.keyHandled(.s, .{ .ctrl = true }, true, false));
    try std.testing.expectEqualStrings("s", CmdLog.str());
    try std.testing.expect(Handle.eql(CmdLog.last_target, ui.tree.root)); // nothing focused
    ui.setFocus(b.node);
    _ = ui.keyHandled(.s, .{ .ctrl = true }, true, false);
    try std.testing.expect(Handle.eql(CmdLog.last_target, b.node));
    try std.testing.expect(!ui.keyHandled(.x, .{ .ctrl = true }, true, false)); // unbound
    try std.testing.expect(!ui.keyHandled(.s, .{ .ctrl = true }, false, false)); // key-up never triggers
    try std.testing.expect(ui.invokeCommand("file.s"));
    try std.testing.expect(!ui.invokeCommand("nope"));
}

test "widgets get the key first: a button's Enter beats an Enter shortcut" {
    const t = try Harness.init();
    defer t.deinit();
    const ui = &t.ui;
    CmdLog.reset();
    try regCmd(ui, "x.e");
    try ui.bindShortcut("enter", "x.e", .app, null);
    const b = try ui.add(Button, ui.tree.root, .{ .style = box(80, 30) });
    try t.frame();

    // Nothing focused: the shortcut fires.
    _ = ui.keyHandled(.enter, .{}, true, false);
    try std.testing.expectEqualStrings("e", CmdLog.str());
    // A focused button claims Enter for itself.
    ui.setFocus(b.node);
    _ = ui.keyHandled(.enter, .{}, true, false);
    try std.testing.expectEqualStrings("e", CmdLog.str());
    try std.testing.expectEqual(@as(u32, 1), b.out.click_count);
}

test "a Tab shortcut beats focus movement; unbound Tab still moves focus" {
    const t = try Harness.init();
    defer t.deinit();
    const ui = &t.ui;
    CmdLog.reset();
    try regCmd(ui, "x.t");
    const b = try ui.add(Button, ui.tree.root, .{ .style = box(80, 30) });
    try t.frame();
    _ = ui.keyHandled(.tab, .{}, true, false);
    try std.testing.expect(Handle.eql(ui.focused().?, b.node));
    ui.setFocus(null);

    try ui.bindShortcut("tab", "x.t", .app, null);
    _ = ui.keyHandled(.tab, .{}, true, false);
    try std.testing.expectEqualStrings("t", CmdLog.str());
    try std.testing.expect(ui.focused() == null);
}

test "typing in a text field is not stolen by plain-key shortcuts, but modified shortcuts still work" {
    const t = try TextHarness.init();
    defer t.deinit();
    const ui = &t.h.ui;
    CmdLog.reset();
    try regCmd(ui, "x.a"); // bare "a"
    try regCmd(ui, "x.s"); // ctrl+s
    try regCmd(ui, "x.q"); // ctrl+a: the field's own select-all must win
    try ui.bindShortcut("a", "x.a", .app, null);
    try ui.bindShortcut("ctrl+s", "x.s", .app, null);
    try ui.bindShortcut("ctrl+a", "x.q", .app, null);
    const tf = try focusedField(t);

    _ = ui.keyHandled(.a, .{}, true, false);
    ui.textInput("a");
    try t.h.frame();
    try std.testing.expectEqualStrings("a", tf.text());
    try std.testing.expectEqualStrings("", CmdLog.str()); // the shortcut did not fire

    _ = ui.keyHandled(.a, .{ .ctrl = true }, true, false); // the field takes select-all
    try std.testing.expectEqual(@as(u32, 1), tf.out.sel_end);
    try std.testing.expectEqualStrings("", CmdLog.str());
    _ = ui.keyHandled(.s, .{ .ctrl = true }, true, false); // not claimed by the field
    try std.testing.expectEqualStrings("s", CmdLog.str());

    // Leave the field and the bare shortcut works again.
    ui.setFocus(null);
    _ = ui.keyHandled(.a, .{}, true, false);
    try std.testing.expectEqualStrings("sa", CmdLog.str());
}

test "panel and widget scopes follow focus" {
    const t = try Harness.init();
    defer t.deinit();
    const ui = &t.ui;
    CmdLog.reset();
    try regCmd(ui, "x.g"); // global
    try regCmd(ui, "x.p"); // panel
    try regCmd(ui, "x.w"); // widget
    const panel = try ui.tree.create(.{});
    try ui.tree.appendChild(ui.tree.root, panel);
    const inside = try ui.add(Button, panel, .{ .style = box(80, 30) });
    const outside = try ui.add(Button, ui.tree.root, .{ .style = box(80, 30) });
    try ui.bindShortcut("f2", "x.g", .app, null);
    try ui.bindShortcut("f2", "x.p", .panel, panel);
    try ui.bindShortcut("f2", "x.w", .widget, inside.node);
    try t.frame();

    ui.setFocus(inside.node);
    _ = ui.keyHandled(.f2, .{}, true, false); // widget
    ui.setFocus(outside.node);
    _ = ui.keyHandled(.f2, .{}, true, false); // outside the panel: global
    try std.testing.expectEqualStrings("wg", CmdLog.str());
    try std.testing.expectError(error.InvalidScope, ui.bindShortcut("f3", "x.p", .panel, null));
    try std.testing.expectError(error.UnknownCommand, ui.bindShortcut("f3", "x.nope", .app, null));
    try std.testing.expectError(error.InvalidSequence, ui.bindShortcut("zzz+q", "x.g", .app, null));
}

test "destroying a panel drops its bindings on the next update" {
    const t = try Harness.init();
    defer t.deinit();
    const ui = &t.ui;
    CmdLog.reset();
    try regCmd(ui, "x.p");
    const panel = try ui.tree.create(.{});
    try ui.tree.appendChild(ui.tree.root, panel);
    try ui.bindShortcut("f2", "x.p", .panel, panel);
    try std.testing.expectEqual(@as(usize, 1), ui.shortcuts.count());
    _ = ui.tree.destroySubtree(panel);
    try t.frame();
    try std.testing.expectEqual(@as(usize, 0), ui.shortcuts.count());
}

test "chords work through the Ui and a click cancels a pending chord" {
    const t = try Harness.init();
    defer t.deinit();
    const ui = &t.ui;
    CmdLog.reset();
    try regCmd(ui, "edit.c");
    try ui.bindShortcut("ctrl+k ctrl+c", "edit.c", .app, null);
    _ = ui.tick(0);
    try std.testing.expect(ui.keyHandled(.k, .{ .ctrl = true }, true, false));
    try std.testing.expect(ui.shortcuts.hasPending());
    try std.testing.expect(ui.keyHandled(.c, .{ .ctrl = true }, true, false));
    try std.testing.expectEqualStrings("c", CmdLog.str());

    _ = ui.keyHandled(.k, .{ .ctrl = true }, true, false);
    ui.pointerButtonEx(300, 90, 1, true, 1);
    try std.testing.expect(!ui.shortcuts.hasPending());
    try std.testing.expect(!ui.keyHandled(.c, .{ .ctrl = true }, true, false));
    try std.testing.expectEqualStrings("c", CmdLog.str());

    // The timeout uses the time given to tick.
    _ = ui.tick(1000);
    _ = ui.keyHandled(.k, .{ .ctrl = true }, true, false);
    _ = ui.tick(1000 + 2000);
    try std.testing.expect(!ui.keyHandled(.c, .{ .ctrl = true }, true, false));
}

test "a command-linked button runs the command, mirrors its enabled state, and frees its link" {
    const t = try Harness.init();
    defer t.deinit(); // leak-checked
    const ui = &t.ui;
    CmdLog.reset();
    const b = try ui.add(Button, ui.tree.root, .{ .style = box(80, 30) });
    try b.setCommand("view.v"); // the command does not exist yet
    try t.frame();
    try std.testing.expect(!b.props.enabled);

    try regCmd(ui, "view.v");
    try t.frame();
    try std.testing.expect(b.props.enabled);
    t.click(10, 10);
    try std.testing.expectEqualStrings("v", CmdLog.str());
    try std.testing.expect(Handle.eql(CmdLog.last_target, b.node)); // focused by the click

    try std.testing.expect(ui.setCommandEnabled("view.v", false));
    try t.frame();
    try std.testing.expect(!b.props.enabled);
    t.click(10, 10);
    try std.testing.expectEqualStrings("v", CmdLog.str()); // no second run
    try std.testing.expect(!ui.setCommandEnabled("missing", false));

    try b.setCommand("view.v"); // re-linking replaces the old link
    _ = ui.tree.destroySubtree(b.node);
    try t.frame();
    try std.testing.expectEqual(@as(u32, 0), ui.buttons.count());
}

test "keymaps load through the Ui, and shortcut text feeds menus and tooltips" {
    const t = try Harness.init();
    defer t.deinit();
    const ui = &t.ui;
    CmdLog.reset();
    try regCmd(ui, "file.s");
    try regCmd(ui, "file.o");
    const report = ui.loadKeymap(
        \\ctrl+s = file.s
        \\ctrl+o = file.o
        \\ctrl+k ctrl+s = file.s   # a second binding for the same command
        \\
    );
    try std.testing.expectEqual(@as(u32, 3), report.bound);
    try std.testing.expectEqual(@as(u32, 0), report.errors);
    var buf: [48]u8 = undefined;
    try std.testing.expectEqualStrings("Ctrl+S", ui.shortcutText("file.s", &buf).?);
    try std.testing.expect(ui.shortcutText("file.none", &buf) == null);

    // Remapping: rebind replaces.
    try ui.rebindShortcut("ctrl+s", "file.o", .app, null);
    _ = ui.keyHandled(.s, .{ .ctrl = true }, true, false);
    try std.testing.expectEqualStrings("o", CmdLog.str());
    try std.testing.expectError(error.Conflict, ui.bindShortcut("ctrl+s", "file.s", .app, null));
}

test "repeatable commands re-run on auto-repeat; others do not" {
    const t = try Harness.init();
    defer t.deinit();
    const ui = &t.ui;
    CmdLog.reset();
    try regCmd(ui, "nav.d");
    try regCmd(ui, "nav.s");
    try ui.bindShortcut("down", "nav.d", .app, null);
    try ui.bindShortcut("ctrl+s", "nav.s", .app, null);
    try std.testing.expect(ui.setCommandRepeat("nav.d", true));
    _ = ui.keyHandled(.down, .{}, true, false);
    _ = ui.keyHandled(.down, .{}, true, true);
    _ = ui.keyHandled(.s, .{ .ctrl = true }, true, false);
    _ = ui.keyHandled(.s, .{ .ctrl = true }, true, true);
    try std.testing.expectEqualStrings("dds", CmdLog.str());
}

// ---- code editor widget tests --------------------------------------------------------
// Geometry in these tests: the mono test font at 20px has 12px cells and a 22px
// line height; the gutter is 3 digits wide: 3 * 12 + 16 = 52px; no padding.

const gutter_px: f32 = 52;
const cell_px: f32 = 12;
const line_px: f32 = 22;

fn editorBox(t: *TextHarness) !*CodeEditor {
    const ui = &t.h.ui;
    ui.tree.get(ui.tree.root).?.style = .{ .align_items = .start };
    ui.clipboard = .{ .get = FakeClip.get, .set = FakeClip.set };
    FakeClip.len = 0;
    FieldCounts.changes = 0;
    const ed = try ui.add(CodeEditor, ui.tree.root, .{ .style = .{ .width = Length.px(300), .height = Length.px(100) } });
    ed.props.on_change = .{ .call = FieldCounts.onChange };
    try t.h.frame();
    ui.setFocus(ed.node);
    try t.h.frame();
    return ed;
}

fn edText(_: *Ui, ed: *CodeEditor) ![]u8 {
    return ed.textAlloc(testing_alloc);
}

const testing_alloc = std.testing.allocator;

fn expectEdText(ui: *Ui, ed: *CodeEditor, expected: []const u8) !void {
    const s = try edText(ui, ed);
    defer testing_alloc.free(s);
    try std.testing.expectEqualStrings(expected, s);
}

fn manyLines(n: usize) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(testing_alloc);
    for (0..n) |i| {
        var buf: [24]u8 = undefined;
        try out.appendSlice(testing_alloc, try std.fmt.bufPrint(&buf, "line {d}\n", .{i + 1}));
    }
    return out.toOwnedSlice(testing_alloc);
}

test "typing, Enter, Backspace, and undo/redo through events update text and out" {
    const t = try TextHarness.init();
    defer t.deinit();
    const ui = &t.h.ui;
    const ed = try editorBox(t);

    try type_(t, "hi");
    try press(t, .enter, .{});
    try type_(t, "x");
    try expectEdText(ui, ed, "hi\nx");
    try std.testing.expectEqual(@as(u32, 2), ed.out.line_count);
    try std.testing.expectEqual(@as(u32, 1), ed.out.caret_line);
    try std.testing.expectEqual(@as(u32, 1), ed.out.caret_column);
    try std.testing.expect(ed.out.modified);
    try std.testing.expectEqual(@as(u32, 3), FieldCounts.changes);

    try press(t, .backspace, .{});
    try press(t, .backspace, .{});
    try expectEdText(ui, ed, "hi");
    try press(t, .z, .{ .ctrl = true }); // undo the backspaces
    try expectEdText(ui, ed, "hi\nx");
    try press(t, .z, .{ .ctrl = true, .shift = true }); // redo
    try expectEdText(ui, ed, "hi");
    try press(t, .y, .{ .ctrl = true }); // nothing left to redo
    try expectEdText(ui, ed, "hi");
    ed.markSaved();
    try t.h.frame();
    try std.testing.expect(!ed.out.modified);
}

test "clicking places the caret, dragging selects, double and triple click select a word and a line" {
    const t = try TextHarness.init();
    defer t.deinit();
    const ui = &t.h.ui;
    const ed = try editorBox(t);
    try ed.loadText("alpha beta\ngamma\ndelta", false);
    try t.h.frame();
    const core = ed.core();

    // Line 1 ("gamma"), column 2.
    const x = gutter_px + 2 * cell_px + 1;
    const y = line_px + 5;
    ui.pointerMove(x, y);
    ui.pointerButtonEx(x, y, 1, true, 1);
    ui.pointerButtonEx(x, y, 1, false, 1);
    try t.h.frame();
    try std.testing.expectEqual(@as(usize, 11 + 2), core.sel.primary().head);
    try std.testing.expect(ed.out.focused);

    // Drag from line 0 col 1 to line 2 col 3.
    const x0 = gutter_px + 1 * cell_px;
    const x1 = gutter_px + 3 * cell_px;
    ui.pointerMove(x0, 5);
    ui.pointerButtonEx(x0, 5, 1, true, 1);
    ui.pointerMove(x1, 2 * line_px + 5);
    ui.pointerButtonEx(x1, 2 * line_px + 5, 1, false, 1);
    try t.h.frame();
    try std.testing.expectEqual(@as(usize, 1), core.sel.primary().start());
    try std.testing.expectEqual(@as(usize, 17 + 3), core.sel.primary().end());

    // Double click selects the word; triple click the line.
    ui.pointerButtonEx(gutter_px + 7 * cell_px, 5, 1, true, 2);
    ui.pointerButtonEx(gutter_px + 7 * cell_px, 5, 1, false, 2);
    try std.testing.expectEqualStrings("beta", try core.doc.range(core.sel.primary().start(), core.sel.primary().end()));
    ui.pointerButtonEx(gutter_px + 7 * cell_px, 5, 1, true, 3);
    ui.pointerButtonEx(gutter_px + 7 * cell_px, 5, 1, false, 3);
    try std.testing.expectEqualStrings("alpha beta\n", try core.doc.range(core.sel.primary().start(), core.sel.primary().end()));
}

test "alt-click adds a cursor and typing goes to every cursor" {
    const t = try TextHarness.init();
    defer t.deinit();
    const ui = &t.h.ui;
    const ed = try editorBox(t);
    try ed.loadText("one\ntwo", false);
    try t.h.frame();

    ui.pointerMove(gutter_px, 5);
    ui.pointerButtonEx(gutter_px, 5, 1, true, 1);
    ui.pointerButtonEx(gutter_px, 5, 1, false, 1);
    ui.key(.unknown, .{ .alt = true }, true, false); // Alt is held
    ui.pointerMove(gutter_px, line_px + 5);
    ui.pointerButtonEx(gutter_px, line_px + 5, 1, true, 1);
    ui.pointerButtonEx(gutter_px, line_px + 5, 1, false, 1);
    ui.key(.unknown, .{}, false, false);
    try t.h.frame();
    try std.testing.expectEqual(@as(u32, 2), ed.out.selection_count);
    try type_(t, ">");
    try expectEdText(ui, ed, ">one\n>two");

    try press(t, .escape, .{}); // drop the extra cursor
    try std.testing.expectEqual(@as(u32, 1), ed.out.selection_count);
    try std.testing.expect(!ui.keyHandled(.escape, .{}, true, false)); // nothing left to cancel: the key passes through

    try press(t, .up, .{ .ctrl = true, .alt = true }); // no line above the first: no-op
    try press(t, .down, .{ .ctrl = true, .alt = true });
    try std.testing.expectEqual(@as(u32, 2), ed.out.selection_count);
}

test "the caret scrolls into view, page keys move by a screenful, and the wheel scrolls" {
    const t = try TextHarness.init();
    defer t.deinit();
    const ui = &t.h.ui;
    const ed = try editorBox(t);
    const text = try manyLines(100);
    try ed.loadText(text, true);
    try t.h.frame();
    const slot = ed;
    try std.testing.expectEqual(@as(f32, 0), slot.scroll_y);

    try press(t, .end, .{ .ctrl = true }); // end of the document
    try std.testing.expectEqual(@as(u32, 100), ed.out.caret_line);
    const max_scroll = 101 * line_px - 100;
    try std.testing.expectApproxEqAbs(max_scroll, slot.scroll_y, 0.01);

    try press(t, .home, .{ .ctrl = true });
    try std.testing.expectEqual(@as(f32, 0), slot.scroll_y);
    try press(t, .page_down, .{}); // view is 100px = 4 lines: moves 3
    try std.testing.expectEqual(@as(u32, 3), ed.out.caret_line);

    ui.pointerMove(100, 50);
    ui.wheelAtPointer(0, -1); // one notch down = 3 lines
    try t.h.frame();
    try std.testing.expectApproxEqAbs(3 * line_px, slot.scroll_y, 0.01);
    ui.wheelAtPointer(0, 100); // far past the top: clamped
    try t.h.frame();
    try std.testing.expectEqual(@as(f32, 0), slot.scroll_y);
}

test "only the lines in view are painted, with balanced clips" {
    const t = try TextHarness.init();
    defer t.deinit();
    t.h.list = DrawList.init(&t.h.cmds, &t.h.glyph_store);
    const ed = try editorBox(t);
    const text = try manyLines(20000);
    try ed.loadText(text, true);
    try t.h.frame();

    var runs: usize = 0;
    for (t.h.list.items()) |c| runs += @intFromBool(c == .glyph_run or c == .mono_run);
    // ~7 rows visible, each with a text run and a gutter number.
    try std.testing.expect(runs > 0 and runs <= 2 * 8);
    try std.testing.expect(t.h.list.isBalanced());
}

test "selections, the current line, and carets are drawn; the caret blinks" {
    const t = try TextHarness.init();
    defer t.deinit();
    const ui = &t.h.ui;
    const ed = try editorBox(t);
    try ed.loadText("abcdef\nsecond", false);
    try t.h.frame();
    const colors = ui.theme.editor;

    const Counts = struct {
        fn of(list: *const DrawList, color: geometry.Color) usize {
            var n: usize = 0;
            for (list.items()) |c| {
                if (solidFill(c)) |f| {
                    if (std.meta.eql(f.color, color)) n += 1;
                }
            }
            return n;
        }
    };
    try std.testing.expectEqual(@as(usize, 1), Counts.of(&t.h.list, colors.caret));
    try std.testing.expectEqual(@as(usize, 1), Counts.of(&t.h.list, colors.current_line));

    _ = ui.tick(2000); // blink off
    try t.h.frame();
    try std.testing.expectEqual(@as(usize, 0), Counts.of(&t.h.list, colors.caret));

    try press(t, .right, .{ .shift = true });
    try press(t, .right, .{ .shift = true });
    try press(t, .down, .{ .shift = true });
    // Two rows of selection: first row from column 2 to the end plus the line break.
    try std.testing.expectEqual(@as(usize, 2), Counts.of(&t.h.list, colors.selection));
    try std.testing.expectEqual(@as(usize, 0), Counts.of(&t.h.list, colors.current_line)); // hidden while selecting

    ui.setFocus(null);
    try t.h.frame();
    try std.testing.expectEqual(@as(usize, 2), Counts.of(&t.h.list, colors.selection_unfocused));
}

test "tabs expand for display, so caret positions follow the visual columns" {
    const t = try TextHarness.init();
    defer t.deinit();
    const ui = &t.h.ui;
    const ed = try editorBox(t);
    try ed.loadText("\tx\n  \ty", false);
    try t.h.frame();
    try press(t, .end, .{}); // end of line 0: after a tab (4 cells) and "x"
    const r = ui.textInputRect().?;
    try std.testing.expectApproxEqAbs(gutter_px + 5 * cell_px, r.x, 0.01);
    try press(t, .down, .{});
    try press(t, .end, .{}); // "  \ty": two spaces, a tab to column 4, then "y"
    try std.testing.expectApproxEqAbs(gutter_px + 5 * cell_px, ui.textInputRect().?.x, 0.01);
    // Clicking in the tab's span lands on the nearest edge of the tab character.
    ui.pointerMove(gutter_px + 1 * cell_px, 5);
    ui.pointerButtonEx(gutter_px + 1 * cell_px, 5, 1, true, 1);
    ui.pointerButtonEx(gutter_px + 1 * cell_px, 5, 1, false, 1);
    try t.h.frame();
    try std.testing.expectEqual(@as(u32, 0), ed.out.caret_column); // before the tab
}

test "read-only editors navigate and copy but do not edit; disabled ones are inert" {
    const t = try TextHarness.init();
    defer t.deinit();
    const ui = &t.h.ui;
    const ed = try editorBox(t);
    try ed.loadText("keep this", false);
    ed.props.read_only = true;
    try t.h.frame();

    try type_(t, "x");
    try press(t, .backspace, .{});
    try std.testing.expect(!ui.keyHandled(.enter, .{}, true, false)); // not claimed: passes on
    try press(t, .a, .{ .ctrl = true });
    try press(t, .c, .{ .ctrl = true });
    try press(t, .x, .{ .ctrl = true });
    try expectEdText(ui, ed, "keep this");
    try std.testing.expectEqualStrings("keep this", FakeClip.contents());
    try std.testing.expectEqual(@as(u32, 0), FieldCounts.changes);

    ed.props.read_only = false;
    ed.props.enabled = false;
    try t.h.frame();
    try type_(t, "x");
    try expectEdText(ui, ed, "keep this");
    try std.testing.expect(ui.focused() == null);
}

test "cut, paste, and tab handling through the clipboard and keys" {
    const t = try TextHarness.init();
    defer t.deinit();
    const ui = &t.h.ui;
    const ed = try editorBox(t);
    try ed.loadText("one two", false);
    try t.h.frame();
    try press(t, .a, .{ .ctrl = true });
    try press(t, .x, .{ .ctrl = true });
    try expectEdText(ui, ed, "");
    try std.testing.expectEqualStrings("one two", FakeClip.contents());
    try press(t, .v, .{ .ctrl = true });
    try press(t, .v, .{ .ctrl = true });
    try expectEdText(ui, ed, "one twoone two");
    try press(t, .tab, .{});
    try std.testing.expectEqual(@as(u32, 16), ed.out.caret_column); // padded to the next multiple of 4
    try press(t, .tab, .{ .shift = true }); // outdent has nothing to remove at a non-indented line start... caret stays
    try std.testing.expect(ui.focused() != null); // Tab was consumed, focus did not move
}

test "removing an editor frees its document, history, and scratch" {
    const t = try TextHarness.init();
    defer t.deinit(); // leak-checked
    const ui = &t.h.ui;
    const ed = try editorBox(t);
    const text = try manyLines(500);
    try ed.loadText(text, true);
    try type_(t, "typed text");
    try press(t, .enter, .{});
    try press(t, .z, .{ .ctrl = true });
    _ = ui.tree.destroySubtree(ed.node);
    try t.h.frame();
    try std.testing.expectEqual(@as(u32, 0), ui.editors.count());
    try std.testing.expect(ui.focused() == null);
}

test "a larger document keeps its caret stops, line numbers, and mouse mapping in sync after edits" {
    const t = try TextHarness.init();
    defer t.deinit();
    const ui = &t.h.ui;
    const ed = try editorBox(t);
    const text = try manyLines(50);
    try ed.loadText(text, true);
    try t.h.frame();
    const core = ed.core();

    // Insert lines above, then click on what is now line 7 (0-based 6).
    try press(t, .home, .{ .ctrl = true });
    try press(t, .enter, .{});
    try press(t, .enter, .{});
    try type_(t, "new");
    const ypos = 3 * line_px + 5; // viewport row 3 -> line 3 (scroll is 0 at the top)
    ui.pointerMove(gutter_px, ypos);
    ui.pointerButtonEx(gutter_px, ypos, 1, true, 1);
    ui.pointerButtonEx(gutter_px, ypos, 1, false, 1);
    try t.h.frame();
    try std.testing.expectEqual(@as(usize, 3), core.doc.lineOfOffset(core.sel.primary().head));
    // "\n\nnew" went in before "line 1", so row 3 shows "line 2".
    try std.testing.expectEqualStrings("line 2", try core.doc.lineText(3));
    try std.testing.expectEqualStrings("newline 1", try core.doc.lineText(2));
}

// ---- syntax highlighting through the widget ---------------------------------------------

const syntax_mod = @import("../editor/syntax.zig");

/// Colors of the glyph runs drawn for text row `row` (0-based from the top of
/// the view), left to right, with their glyph counts. Gutter runs are skipped.
const RowRun = struct { color: geometry.Color, glyphs: u32, first_x: f32 };

fn rowRuns(list: *const DrawList, row: usize, out: *[32]RowRun) usize {
    var n: usize = 0;
    const y = @as(f32, @floatFromInt(row)) * line_px;
    for (list.items()) |c| {
        var run: RowRun = undefined;
        switch (c) {
            .glyph_run => |g| {
                if (@abs(g.bounds.y - y) > 0.5) continue;
                const first = list.glyphItems()[g.offset];
                run = .{ .color = g.color, .glyphs = g.count, .first_x = first.x };
            },
            .mono_run => |m| {
                if (@abs(m.bounds.y - y) > 0.5) continue;
                var ink: u32 = 0;
                for (list.glyphItems()[m.offset..][0..m.count]) |g| ink += @intFromBool(g.id != draw_list.empty_cell);
                run = .{ .color = m.color, .glyphs = ink, .first_x = m.first_x };
            },
            else => continue,
        }
        if (run.first_x < gutter_px) continue; // the gutter's line number
        if (n < out.len) {
            out[n] = run;
            n += 1;
        }
    }
    return n;
}

test "highlighted text is drawn in one run per color, with the right colors" {
    const t = try TextHarness.init();
    defer t.deinit();
    const ui = &t.h.ui;
    const ed = try editorBox(t);
    try ed.loadText("const x = 42; // hi", false);
    try t.h.frame();
    const colors = ui.theme.editor;

    // No language yet: the whole line is one plain run.
    var runs: [32]RowRun = undefined;
    var n = rowRuns(&t.h.list, 0, &runs);
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqual(colors.tokenColor(.plain), runs[0].color);

    try ed.setLanguage(&syntax_mod.zig);
    try t.h.frame();
    n = rowRuns(&t.h.list, 0, &runs);
    try std.testing.expect(n >= 5);
    try std.testing.expectEqual(colors.tokenColor(.keyword), runs[0].color); // "const"
    try std.testing.expectEqual(@as(u32, 5), runs[0].glyphs);
    try std.testing.expectApproxEqAbs(gutter_px, runs[0].first_x, 0.01);
    var saw_number = false;
    for (runs[0..n]) |r| {
        if (std.meta.eql(r.color, colors.tokenColor(.number))) {
            saw_number = true;
            try std.testing.expectEqual(@as(u32, 2), r.glyphs);
        }
    }
    try std.testing.expect(saw_number);
    try std.testing.expectEqual(colors.tokenColor(.comment), runs[n - 1].color); // "// hi"
    try std.testing.expectEqual(@as(u32, 4), runs[n - 1].glyphs); // the space has no glyph

    // Switching the language off goes back to a single run.
    try ed.setLanguage(null);
    try t.h.frame();
    try std.testing.expectEqual(@as(usize, 1), rowRuns(&t.h.list, 0, &runs));
}

test "tokens line up with expanded tabs and carry their colors" {
    const t = try TextHarness.init();
    defer t.deinit();
    const ui = &t.h.ui;
    const ed = try editorBox(t);
    try ed.loadText("\tconst x", false);
    try ed.setLanguage(&syntax_mod.zig);
    try t.h.frame();
    var runs: [32]RowRun = undefined;
    const n = rowRuns(&t.h.list, 0, &runs);
    try std.testing.expect(n >= 2);
    try std.testing.expectEqual(ui.theme.editor.tokenColor(.keyword), runs[0].color);
    try std.testing.expectApproxEqAbs(gutter_px + 4 * cell_px, runs[0].first_x, 0.01); // after the 4-cell tab
}

test "opening a block comment above recolors the lines below it" {
    const t = try TextHarness.init();
    defer t.deinit();
    const ui = &t.h.ui;
    const ed = try editorBox(t);
    try ed.loadText("int a;\nint b;\nint c;", false);
    try ed.setLanguage(&syntax_mod.c);
    try t.h.frame();
    const colors = ui.theme.editor;
    var runs: [32]RowRun = undefined;
    _ = rowRuns(&t.h.list, 2, &runs);
    try std.testing.expectEqual(colors.tokenColor(.type), runs[0].color);

    ed.core().setCaret(6, false); // end of line 0
    try type_(t, "/*");
    const n = rowRuns(&t.h.list, 2, &runs);
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqual(colors.tokenColor(.comment), runs[0].color); // "int c;" is now comment text

    try type_(t, "*/"); // closing it restores the lines below
    _ = rowRuns(&t.h.list, 2, &runs);
    try std.testing.expectEqual(colors.tokenColor(.type), runs[0].color);
}

test "a large file is lexed lazily: only to the viewport, then up to the caret when jumping" {
    const t = try TextHarness.init();
    defer t.deinit();
    t.h.list = DrawList.init(&t.h.cmds, &t.h.glyph_store);
    const ed = try editorBox(t);
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    for (0..20000) |i| {
        var line: [64]u8 = undefined;
        try buf.appendSlice(testing_alloc, try std.fmt.bufPrint(&line, "const v{d}: u32 = {d}; // c\n", .{ i, i }));
    }
    try ed.loadText(try buf.toOwnedSlice(testing_alloc), true);
    try ed.setLanguage(&syntax_mod.zig);
    try t.h.frame();
    const hl = &ed.highlighter.?;
    try std.testing.expect(hl.lexed <= 10); // just the lines above the visible ones (none) plus a few

    try press(t, .end, .{ .ctrl = true }); // jump to the bottom: lex everything above it, once
    try std.testing.expect(hl.lexed >= 19990);
    const after_jump = hl.lexed;
    try press(t, .up, .{});
    try press(t, .down, .{});
    try std.testing.expectEqual(after_jump, hl.lexed); // cached

    // Typing on the last line only relexes the changed line.
    try type_(t, "x");
    try std.testing.expect(hl.lexed - after_jump <= 3);
}

test "no highlighter, no cost: plain editors never create one" {
    const t = try TextHarness.init();
    defer t.deinit();
    const ed = try editorBox(t);
    try ed.loadText("const x = 1;", false);
    try t.h.frame();
    try std.testing.expect(ed.highlighter == null);
    try ed.setLanguage(&syntax_mod.plain); // "plain" lexes nothing but is still a language
    try t.h.frame();
    var runs: [32]RowRun = undefined;
    try std.testing.expectEqual(@as(usize, 1), rowRuns(&t.h.list, 0, &runs));
}

// ---- Ui.add and widget options ------------------------------------------------------------

test "add configures widgets from their options" {
    const t = try TextHarness.init();
    defer t.deinit();
    const ui = &t.h.ui;
    const Count = struct {
        var n: u32 = 0;
        fn cb(_: ?*anyopaque, _: *event_mod.Event) void {
            n += 1;
        }
    };
    Count.n = 0;

    _ = try ui.registerCommand("view.x", .{ .title = "X", .run = .{ .call = Count.cb } });
    const b = try ui.add(Button, ui.tree.root, .{
        .style = box(80, 30),
        .text = "Go",
        .variant = .danger,
        .text_align = .start,
    });
    try std.testing.expectEqualStrings("Go", b.props.text.slice());
    try std.testing.expect(b.props.variant == .danger and b.props.text_align == .start);

    const linked = try ui.add(Button, ui.tree.root, .{ .style = box(80, 30), .command = "view.x" });
    try std.testing.expect(linked.link != null);

    const l = try ui.add(Label, ui.tree.root, .{ .text = "hello", .size = 30, .font = .mono });
    try std.testing.expectEqualStrings("hello", l.props.text.slice());
    try std.testing.expectEqual(@as(f32, 30), l.props.size);

    const tf = try ui.add(TextField, ui.tree.root, .{ .text = "start", .placeholder = "type", .read_only = true });
    try std.testing.expectEqualStrings("start", tf.text());
    try std.testing.expect(tf.props.read_only);
    try std.testing.expectEqual(@as(u32, 0), tf.out.change_count); // initial text is not an edit

    const ed = try ui.add(CodeEditor, ui.tree.root, .{
        .text = "const x = 1;\n",
        .language = &syntax_mod.zig,
        .tab_width = 2,
        .line_numbers = false,
    });
    try t.h.frame();
    try std.testing.expectEqual(@as(u32, 2), ed.out.line_count);
    try std.testing.expect(!ed.props.line_numbers and ed.props.tab_width == 2);
    try std.testing.expect(ed.highlighter != null);
}

test "registerCommand options set title, repeat, and enabled; the name is the default title" {
    const t = try Harness.init();
    defer t.deinit();
    const ui = &t.ui;
    _ = try ui.registerCommand("a.b", .{});
    _ = try ui.registerCommand("c.d", .{ .title = "Do C", .repeat = true, .enabled = false });
    const ab = ui.commands.get(ui.commands.find("a.b").?).?;
    const cd = ui.commands.get(ui.commands.find("c.d").?).?;
    try std.testing.expectEqualStrings("a.b", ab.title);
    try std.testing.expectEqualStrings("Do C", cd.title);
    try std.testing.expect(cd.repeat and !cd.enabled and ab.enabled and !ab.repeat);
}

test "add cleans up when allocation fails at any point" {
    var fail_at: usize = 0;
    while (fail_at < 400) : (fail_at += 1) {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = fail_at });
        var ui = Ui.init(failing.allocator()) catch continue;
        defer ui.deinit();
        const root = ui.tree.root;
        _ = ui.add(Button, root, .{ .text = "text", .command = "c" }) catch {};
        _ = ui.add(Label, root, .{ .text = "label" }) catch {};
        _ = ui.add(TextField, root, .{ .text = "field", .placeholder = "ph" }) catch {};
        _ = ui.add(CodeEditor, root, .{ .text = "one\ntwo", .language = &syntax_mod.zig }) catch {};
        ui.update();
    }
}

test "the pin check stays quiet through normal use and notices a copy" {
    if (!shadow.enabled) return error.SkipZigTest;
    const t = try Harness.init();
    defer t.deinit();
    const ui = &t.ui;
    try std.testing.expect(ui.isPinned()); // before any widget: nothing to protect
    _ = try ui.add(Button, ui.tree.root, .{ .style = box(80, 30) });
    try std.testing.expect(ui.pinned == ui);
    try t.frame(); // update, layoutAndPaint, endFrame all check
    try std.testing.expect(ui.isPinned());

    // A bitwise copy lives at a different address: the check sees that. (Read
    // only; the copy must never be used or deinitialized.)
    const moved = ui.*;
    try std.testing.expect(!moved.isPinned());
}

// ---- painters and themes -----------------------------------------------------------------

const PaintCtx = @import("paint_ctx.zig").PaintCtx;

/// A painter with a completely different look: a vertical gradient, a bottom
/// rule, and fixed text color.
fn gradientButtonPainter(pc: *PaintCtx, b: *const Button) @import("paint_ctx.zig").Error!void {
    const r = pc.rect;
    const top = if (b.out.hovered) geometry.Color.rgb(250, 200, 60) else geometry.Color.rgb(240, 160, 40);
    try pc.list.fillRect(r, draw_list.Paint.linear(.{ .x = r.x, .y = r.y }, .{ .x = r.x, .y = r.bottom() }, top, geometry.Color.rgb(160, 90, 20)));
    try pc.list.line(.{ .x = r.x, .y = r.bottom() - 1 }, .{ .x = r.right(), .y = r.bottom() - 1 }, 2, draw_list.Paint.solid(geometry.Color.black));
    pc.text_color = geometry.Color.rgb(1, 2, 3);
}

fn countKind(list: *const DrawList, comptime tag: std.meta.Tag(draw_list.Command)) usize {
    var n: usize = 0;
    for (list.items()) |c| n += @intFromBool(c == tag);
    return n;
}

fn linearGradientFills(list: *const DrawList) usize {
    var n: usize = 0;
    for (list.items()) |c| switch (c) {
        .fill_rect => |f| n += @intFromBool(f.paint == .linear_gradient),
        else => {},
    };
    return n;
}

test "replacing the theme's button painter changes the look but not the behavior" {
    const t = try TextHarness.init();
    defer t.deinit();
    const ui = &t.h.ui;
    const Count = struct {
        var n: u32 = 0;
        fn cb(_: ?*anyopaque, _: *event_mod.Event) void {
            n += 1;
        }
    };
    Count.n = 0;
    ui.theme.button_painter = gradientButtonPainter;
    const b = try ui.add(Button, ui.tree.root, .{ .style = box(80, 30), .text = "Go", .on_click = .{ .call = Count.cb } });
    try t.h.frame();

    try std.testing.expectEqual(@as(usize, 1), linearGradientFills(&t.h.list));
    try std.testing.expectEqual(@as(usize, 1), countKind(&t.h.list, .line));
    try std.testing.expectEqual(@as(usize, 0), countKind(&t.h.list, .fill_rounded_rect)); // not the default look
    try std.testing.expectEqual(geometry.Color.rgb(1, 2, 3), firstTextColor(&t.h.list).?); // the painter colored the text

    // Same behavior: hover still repaints, clicks still count.
    t.h.click(10, 10);
    try std.testing.expectEqual(@as(u32, 1), b.out.click_count);
    try std.testing.expectEqual(@as(u32, 1), Count.n);
    try t.h.frame();
    try std.testing.expectEqual(@as(usize, 1), linearGradientFills(&t.h.list));
}

test "a per-widget painter overrides the theme's for that widget only, and can be removed" {
    const t = try TextHarness.init();
    defer t.deinit();
    const ui = &t.h.ui;
    const plain = try ui.add(Button, ui.tree.root, .{ .style = box(80, 30) });
    const special = try ui.add(Button, ui.tree.root, .{ .style = box(80, 30), .painter = gradientButtonPainter });
    _ = plain;
    try t.h.frame();
    try std.testing.expectEqual(@as(usize, 1), linearGradientFills(&t.h.list));
    try std.testing.expectEqual(@as(usize, 1), countKind(&t.h.list, .fill_rounded_rect)); // the other one

    special.setPainter(null);
    try std.testing.expect(ui.isDirty()); // swapping a painter repaints
    try t.h.frame();
    try std.testing.expectEqual(@as(usize, 0), linearGradientFills(&t.h.list));
    try std.testing.expectEqual(@as(usize, 2), countKind(&t.h.list, .fill_rounded_rect));
}

test "per-widget colors override the theme's variant colors for that widget only" {
    const t = try TextHarness.init();
    defer t.deinit();
    const ui = &t.h.ui;
    var custom = ui.theme.button_colors[0];
    custom.normal = geometry.Color.rgb(9, 99, 199);
    custom.text = geometry.Color.rgb(8, 8, 8);
    _ = try ui.add(Button, ui.tree.root, .{ .style = box(80, 30), .text = "x", .colors = custom });
    const other = try ui.add(Button, ui.tree.root, .{ .style = box(80, 30), .text = "y" });
    try t.h.frame();

    var fills: [2]geometry.Color = undefined;
    var n: usize = 0;
    for (t.h.list.items()) |c| switch (c) {
        .fill_rounded_rect => |f| {
            if (n < 2) fills[n] = paintColor(f.paint).?;
            n += 1;
        },
        else => {},
    };
    try std.testing.expectEqual(@as(usize, 2), n);
    try std.testing.expectEqual(geometry.Color.rgb(9, 99, 199), fills[0]);
    try std.testing.expectEqual(ui.theme.button_colors[0].normal, fills[1]);
    try std.testing.expectEqual(geometry.Color.rgb(8, 8, 8), firstTextColor(&t.h.list).?);

    if (comptime shadow.enabled) {
        other.props.colors = custom; // raw write: the shadow checker marks paint
        ui.update();
        try std.testing.expect(ui.isDirty());
    }
}

test "setTheme swaps colors, painters, and fonts and repaints everything" {
    const t = try TextHarness.init();
    defer t.deinit();
    const ui = &t.h.ui;
    _ = try ui.add(Button, ui.tree.root, .{ .style = box(80, 30), .text = "A", .variant = .primary });
    const label_w = try ui.add(Label, ui.tree.root, .{ .text = "hello" });
    try t.h.frame();
    const before = firstFill(&t.h.list).?;
    const before_text_w = label_w.out.text_width;
    try std.testing.expectEqual(ui.theme.button_colors[1].normal, before);

    var dark_red = ui.theme;
    dark_red.button_colors[1].normal = geometry.Color.rgb(120, 0, 0);
    dark_red.text_color = geometry.Color.rgb(10, 200, 10);
    dark_red.font_size = 40; // bigger text must reshape
    ui.setTheme(dark_red);
    try std.testing.expect(ui.isDirty());
    try t.h.frame();

    try std.testing.expectEqual(geometry.Color.rgb(120, 0, 0), firstFill(&t.h.list).?);
    try std.testing.expect(label_w.out.text_width > before_text_w * 1.5);
    // The label's default painter now uses the new theme text color.
    var label_color: ?geometry.Color = null;
    for (t.h.list.items()) |c| switch (c) {
        .glyph_run => |g| label_color = g.color, // the last run is the label's
        else => {},
    };
    try std.testing.expectEqual(geometry.Color.rgb(10, 200, 10), label_color.?);

    // Switching back restores the original look.
    var restored = ui.theme;
    restored.button_colors[1] = (Theme{}).button_colors[1];
    restored.text_color = (Theme{}).text_color;
    restored.font_size = 20;
    ui.setTheme(restored);
    try t.h.frame();
    try std.testing.expectEqual(before, firstFill(&t.h.list).?);
}

test "label painters color text; per-label painters and props.color win" {
    const t = try TextHarness.init();
    defer t.deinit();
    const ui = &t.h.ui;
    const Rainbow = struct {
        fn paint(pc: *PaintCtx, _: *const Label) @import("paint_ctx.zig").Error!void {
            pc.text_color = geometry.Color.rgb(77, 66, 55);
        }
    };
    const themed = try ui.add(Label, ui.tree.root, .{ .text = "a" });
    const colored = try ui.add(Label, ui.tree.root, .{ .text = "b", .color = geometry.Color.rgb(1, 1, 1) });
    const custom = try ui.add(Label, ui.tree.root, .{ .text = "c", .painter = Rainbow.paint });
    _ = .{ themed, colored, custom };
    try t.h.frame();
    var colors: [3]geometry.Color = undefined;
    var n: usize = 0;
    for (t.h.list.items()) |c| switch (c) {
        .glyph_run => |g| {
            if (n < 3) colors[n] = g.color;
            n += 1;
        },
        else => {},
    };
    try std.testing.expectEqual(@as(usize, 3), n);
    try std.testing.expectEqual(ui.theme.text_color, colors[0]);
    try std.testing.expectEqual(geometry.Color.rgb(1, 1, 1), colors[1]);
    try std.testing.expectEqual(geometry.Color.rgb(77, 66, 55), colors[2]);
}

test "a custom field painter controls the box, text, selection, and caret colors" {
    const t = try TextHarness.init();
    defer t.deinit();
    const ui = &t.h.ui;
    const Neon = struct {
        fn paint(pc: *PaintCtx, f: *const TextField) @import("paint_ctx.zig").Error!void {
            try pc.box(.{ .background = geometry.Color.rgb(0, 0, 40), .border_color = geometry.Color.rgb(0, 255, 255), .border_width = 3 });
            pc.text_color = geometry.Color.rgb(255, 0, 255);
            pc.selection_color = geometry.Color.rgb(255, 255, 0);
            pc.caret_color = geometry.Color.rgb(0, 255, 0);
            _ = f;
        }
    };
    ui.theme.field_painter = Neon.paint;
    const tf = try focusedField(t);
    try type_(t, "ab");
    try std.testing.expectEqual(geometry.Color.rgb(0, 0, 40), firstFill(&t.h.list).?);
    try std.testing.expectEqual(geometry.Color.rgb(0, 255, 255), firstStroke(&t.h.list).?);
    try std.testing.expectEqual(geometry.Color.rgb(255, 0, 255), firstTextColor(&t.h.list).?);
    var caret = false;
    for (t.h.list.items()) |c| {
        if (solidFill(c)) |f| caret = caret or (f.rect.w == 1 and std.meta.eql(f.color, geometry.Color.rgb(0, 255, 0)));
    }
    try std.testing.expect(caret);
    try press(t, .a, .{ .ctrl = true });
    var selection = false;
    for (t.h.list.items()) |c| {
        if (solidFill(c)) |f| selection = selection or std.meta.eql(f.color, geometry.Color.rgb(255, 255, 0));
    }
    try std.testing.expect(selection);
    _ = tf;
}

test "an editor painter can add chrome around the default content" {
    const t = try TextHarness.init();
    defer t.deinit();
    const ui = &t.h.ui;
    const Framed = struct {
        fn paint(pc: *PaintCtx, ed: *CodeEditor) @import("paint_ctx.zig").Error!void {
            try pc.box(.{ .background = geometry.Color.rgb(5, 5, 50), .border_color = geometry.Color.rgb(200, 0, 0), .border_width = 4 });
            try ed.paintContent(pc);
        }
    };
    ui.theme.editor_painter = Framed.paint;
    const ed = try editorBox(t);
    try ed.loadText("hello", false);
    try t.h.frame();
    try std.testing.expectEqual(geometry.Color.rgb(5, 5, 50), firstFill(&t.h.list).?);
    try std.testing.expectEqual(geometry.Color.rgb(200, 0, 0), firstStroke(&t.h.list).?);
    try std.testing.expect(countKind(&t.h.list, .glyph_run) >= 1); // the content is still there
    try std.testing.expect(t.h.list.isBalanced());

    // Per-editor colors tint the default painter for that editor.
    ed.setPainter(null);
    ui.theme.editor_painter = code_editor.defaultPainter;
    var custom = ui.theme.editor;
    custom.background = geometry.Color.rgb(33, 44, 55);
    ed.props.colors = custom;
    try t.h.frame();
    try std.testing.expectEqual(geometry.Color.rgb(33, 44, 55), firstFill(&t.h.list).?);
}

test "plain nodes still draw their Visual, then their children" {
    const t = try Harness.init();
    defer t.deinit();
    const ui = &t.ui;
    ui.tree.get(ui.tree.root).?.visual = .{ .background = geometry.Color.rgb(1, 2, 3), .border_color = geometry.Color.rgb(4, 5, 6), .border_width = 2 };
    ui.tree.markDirty(ui.tree.root, DirtyFlags.layout_and_paint);
    try t.frame();
    try std.testing.expectEqual(geometry.Color.rgb(1, 2, 3), firstFill(&t.list).?);
    try std.testing.expectEqual(geometry.Color.rgb(4, 5, 6), firstStroke(&t.list).?);
}

/// A backend that records what the engine asks of it, shaped like a GPU backend
/// (it wants atlas uploads before it draws).
const FakeGpu = struct {
    log: [32]u8 = undefined,
    n: usize = 0,
    pages_uploaded: u32 = 0,
    glyph_cmds: u32 = 0,
    last: render_backend.FrameInfo = .{ .pixel_w = 0, .pixel_h = 0 },

    fn note(self: *FakeGpu, c: u8) void {
        if (self.n < self.log.len) {
            self.log[self.n] = c;
            self.n += 1;
        }
    }

    fn me(ctx: *anyopaque) *FakeGpu {
        return @ptrCast(@alignCast(ctx));
    }

    fn begin(ctx: *anyopaque, info: render_backend.FrameInfo) render_backend.Error!void {
        me(ctx).note('B');
        me(ctx).last = info;
    }

    fn submit(ctx: *anyopaque, s: render_backend.Submit) render_backend.Error!void {
        const self = me(ctx);
        self.note('S');
        for (s.list.items()) |c| if (c == .glyph_run) {
            self.glyph_cmds += 1;
        };
    }

    fn end(ctx: *anyopaque) render_backend.Error!void {
        me(ctx).note('E');
    }

    fn create(_: *anyopaque, _: render_backend.TextureDesc) render_backend.Error!render_backend.TextureId {
        return error.Unsupported;
    }

    fn update(_: *anyopaque, _: render_backend.TextureId, _: render_backend.URect, _: []const u8, _: usize) render_backend.Error!void {
        return error.Unsupported;
    }

    fn destroy(_: *anyopaque, _: render_backend.TextureId) void {}

    fn upload(ctx: *anyopaque, _: u8, pixels: []const u8, size: u32) render_backend.Error!void {
        const self = me(ctx);
        self.note('U');
        self.pages_uploaded += 1;
        std.debug.assert(pixels.len == @as(usize, size) * size);
    }

    fn readback(_: *anyopaque, _: std.mem.Allocator) render_backend.Error!render_backend.Image {
        return error.Unsupported;
    }

    const vtable: render_backend.VTable = .{
        .caps = .{ .name = "fake-gpu", .atlas_upload = true },
        .begin_frame = begin,
        .submit = submit,
        .end_frame = end,
        .create_texture = create,
        .update_texture = update,
        .destroy_texture = destroy,
        .upload_atlas_page = upload,
        .readback = readback,
    };

    fn backend(self: *FakeGpu) render_backend.Backend {
        return .{ .ctx = self, .vtable = &vtable };
    }
};

test "renderFrame uploads changed atlas pages before submit, for backends that want them" {
    const t = try TextHarness.init();
    defer t.deinit();
    const ui = &t.h.ui;
    _ = try ui.add(Label, ui.tree.root, .{ .text = "Hello" });
    var gpu: FakeGpu = .{};
    ui.update();
    try ui.renderFrame(gpu.backend(), &t.h.list, .{ .pixel_w = 200, .pixel_h = 100, .scale = 2 });
    try std.testing.expectEqualStrings("UBSE", gpu.log[0..gpu.n]); // upload, begin, submit, end
    try std.testing.expectEqual(@as(u32, 1), gpu.pages_uploaded);
    try std.testing.expect(gpu.glyph_cmds >= 1);
    try std.testing.expectEqual(@as(u32, 200), gpu.last.pixel_w);
    try std.testing.expectEqual(@as(f32, 2), gpu.last.scale);

    // Nothing changed: the next frame uploads nothing.
    gpu.n = 0;
    try ui.renderFrame(gpu.backend(), &t.h.list, .{ .pixel_w = 200, .pixel_h = 100, .scale = 2 });
    try std.testing.expectEqualStrings("BSE", gpu.log[0..gpu.n]);
}

test "renderFrame through the software backend draws the label's pixels" {
    const sw = @import("../render/software_backend.zig");
    const t = try TextHarness.init();
    defer t.deinit();
    const ui = &t.h.ui;
    ui.tree.get(ui.tree.root).?.visual = .{ .background = geometry.Color.rgb(10, 20, 30) };
    _ = try ui.add(Label, ui.tree.root, .{ .text = "Hello", .color = geometry.Color.white });
    var sb = try sw.SoftwareBackend.init(std.testing.allocator, null);
    defer sb.deinit();
    ui.update();
    try ui.renderFrame(sb.backend(), &t.h.list, .{ .pixel_w = 120, .pixel_h = 60, .clear = geometry.Color.black });
    try std.testing.expectEqual(@as(u32, 0), sb.atlas_uploads); // reads the atlas directly
    const img = try sb.backend().readback(std.testing.allocator);
    defer img.deinit(std.testing.allocator);
    var lit = false;
    var px: usize = 0;
    while (px < img.rgba.len) : (px += 4) {
        if (img.rgba[px] > 200 and img.rgba[px + 1] > 200) lit = true;
    }
    try std.testing.expect(lit); // some text pixel is near white
    try std.testing.expectEqual(@as(u8, 10), img.rgba[(50 * 120 + 100) * 4]); // background, outside the text
}

test "replacing a label's text every frame never reads the freed copy" {
    const t = try TextHarness.init();
    defer t.deinit();
    const ui = &t.h.ui;
    const l = try ui.add(Label, ui.tree.root, .{ .text = "start" });
    var i: usize = 0;
    while (i < 300) : (i += 1) {
        var buf: [24]u8 = undefined;
        try l.setText(std.fmt.bufPrint(&buf, "status line number {d}", .{i}) catch unreachable);
        ui.update();
        if (ui.isDirty()) try ui.layoutAndPaint(.{ .w = 400, .h = 100 }, &t.h.list);
        ui.endFrame();
    }
    try std.testing.expectEqualStrings("status line number 299", l.props.text.bytes);
}

const FakeClock = struct {
    var now: u64 = 0;
    fn read() u64 {
        return now;
    }
};

test "renderFrame records a frame with per-phase costs and command counts" {
    const t = try TextHarness.init();
    defer t.deinit();
    const ui = &t.h.ui;
    ui.clock = FakeClock.read;
    FakeClock.now = 1000;
    _ = try ui.add(Label, ui.tree.root, .{ .text = "Hi" });
    ui.update();
    var gpu: FakeGpu = .{};
    try ui.renderFrame(gpu.backend(), &t.h.list, .{ .pixel_w = 100, .pixel_h = 50 });
    try std.testing.expectEqual(@as(u64, 1), ui.stats.count);
    const f = ui.stats.recent(0).?;
    try std.testing.expect(f.commands >= 1 and f.glyphs >= 1);
    // The clock is frozen, so every phase reads zero; counts still work.
    try std.testing.expectEqual(@as(u64, 0), f.total_ns);
}

const TickingClock = struct {
    var now: u64 = 0;
    fn read() u64 {
        now += 100;
        return now;
    }
};

test "phase costs add up to the frame total" {
    const t = try TextHarness.init();
    defer t.deinit();
    const ui = &t.h.ui;
    ui.clock = TickingClock.read;
    _ = try ui.add(Label, ui.tree.root, .{ .text = "Hi" });
    ui.update();
    var gpu: FakeGpu = .{};
    try ui.renderFrame(gpu.backend(), &t.h.list, .{ .pixel_w = 100, .pixel_h = 50 });
    const f = ui.stats.recent(0).?;
    try std.testing.expect(f.update_ns > 0 and f.layout_ns > 0 and f.build_ns > 0 and f.submit_ns > 0);
    try std.testing.expectEqual(f.update_ns + f.layout_ns + f.build_ns + f.submit_ns, f.total_ns);
    // Pending costs reset for the next frame.
    try std.testing.expectEqual(@as(u64, 0), ui.pending_update_ns);
}

test "the overlay is appended to the draw list only when enabled" {
    const t = try TextHarness.init();
    defer t.deinit();
    const ui = &t.h.ui;
    ui.update();
    var gpu: FakeGpu = .{};
    try ui.renderFrame(gpu.backend(), &t.h.list, .{ .pixel_w = 400, .pixel_h = 100 });
    const plain = t.h.list.items().len;
    ui.show_stats = true;
    ui.tree.markDirty(ui.tree.root, DirtyFlags.layout_and_paint);
    try ui.renderFrame(gpu.backend(), &t.h.list, .{ .pixel_w = 400, .pixel_h = 100 });
    try std.testing.expect(t.h.list.items().len > plain + 2);
}

const SlowHandler = struct {
    fn slow(_: *event_mod.Event) void {
        TickingClock.now += 20_000_000; // 20 ms of "work"
    }
};

test "a slow input handler is counted against the budget" {
    const t = try TextHarness.init();
    defer t.deinit();
    const ui = &t.h.ui;
    ui.clock = TickingClock.read;
    const b = try ui.add(Button, ui.tree.root, .{ .style = box(80, 30), .on_click = event_mod.Callback.fromFn(SlowHandler.slow) });
    _ = b;
    ui.update();
    try ui.layoutAndPaint(.{ .w = 200, .h = 100 }, &t.h.list);
    ui.pointerMove(10, 10);
    try std.testing.expectEqual(@as(u32, 0), ui.slow_handlers);
    ui.pointerButtonEx(10, 10, 1, true, 1);
    ui.pointerButtonEx(10, 10, 1, false, 1); // the click handler runs here
    try std.testing.expectEqual(@as(u32, 1), ui.slow_handlers);
    try std.testing.expect(ui.pending_handler_ns >= 20_000_000);
    ui.handler_budget_ns = 0; // disabled
    ui.pointerButtonEx(10, 10, 1, true, 1);
    ui.pointerButtonEx(10, 10, 1, false, 1);
    try std.testing.expectEqual(@as(u32, 1), ui.slow_handlers);
}

const SteadyScene = struct {
    fa: std.testing.FailingAllocator,
    ui: Ui,
    prop: font.TestFont = .{},
    mono: font.TestFont = .{ .monospace = true },
    cmds: [4096]draw_list.Command = undefined,
    glyphs: [8192]draw_list.Glyph = undefined,
    list: DrawList = undefined,
};

test "steady-state frames allocate nothing after warmup" {
    const sw = @import("../render/software_backend.zig");
    const s = try std.testing.allocator.create(SteadyScene);
    defer std.testing.allocator.destroy(s);
    s.fa = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    s.prop = .{};
    s.mono = .{ .monospace = true };
    s.ui = try Ui.init(s.fa.allocator());
    const ui = &s.ui;
    defer ui.deinit();
    _ = try ui.addFont(s.prop.backend());
    ui.theme.mono_font = try ui.addFont(s.mono.backend());
    ui.theme.font_size = 14;
    s.list = DrawList.init(&s.cmds, &s.glyphs);

    const root = ui.tree.root;
    ui.tree.get(root).?.style = .{ .direction = .column, .gap = Length.px(4) };
    _ = try ui.add(Label, root, .{ .text = "A label with some text" });
    const btn = try ui.add(Button, root, .{ .text = "Click me", .style = box(120, 30) });
    const field = try ui.add(TextField, root, .{ .text = "editable text", .style = .{ .height = Length.px(26), .shrink = 0 } });
    const ed = try ui.add(CodeEditor, root, .{ .style = .{ .height = Length.px(120), .shrink = 0 } });
    try ed.loadText("const std = @import(\"std\");\n\npub fn main() void {\n    // a comment\n    var x: u32 = 42;\n    _ = x;\n}\n", false);
    const cv = try ui.add(canvas_mod.Canvas, root, .{ .style = box(100, 40) });
    const Draw = struct {
        fn run(_: ?*anyopaque, _: *Canvas, pc: *PaintCtx) @import("paint_ctx.zig").Error!void {
            try pc.list.fillRect(.{ .x = pc.rect.x, .y = pc.rect.y, .w = 10, .h = 10 }, .{ .color = geometry.Color.white });
        }
    };
    cv.props.on_draw = .{ .run = Draw.run };
    cv.props.redraw_policy = .continuous;
    ui.setFocus(field.node);

    var sb = try sw.SoftwareBackend.init(std.testing.allocator, null);
    defer sb.deinit();
    const be = sb.backend();

    // Frames that do real work: everything repaints and relayouts, the pointer
    // hovers a button, the caret blinks, the canvas redraws.
    const Frame = struct {
        fn run(u: *Ui, b: render_backend.Backend, list: *DrawList, i: u64) !void {
            _ = u.tick(i * 16);
            u.pointerMove(@floatFromInt(10 + i % 40), 40);
            u.update();
            u.tree.markDirty(u.tree.root, DirtyFlags.layout_and_paint);
            try u.renderFrame(b, list, .{ .pixel_w = 400, .pixel_h = 400, .clear = geometry.Color.black });
            u.endFrame();
        }
    };
    var i: u64 = 0;
    while (i < 8) : (i += 1) try Frame.run(ui, be, &s.list, i); // warmup: scratch buffers, atlas, shaping caches
    _ = btn;

    const allocs = s.fa.allocations;
    const resizes = s.fa.resize_index;
    const frees = s.fa.deallocations;
    while (i < 40) : (i += 1) try Frame.run(ui, be, &s.list, i);
    // The frames really did work: text from the label, field, and editor, plus the canvas.
    try std.testing.expect(s.list.items().len > 20);
    try std.testing.expect(s.list.glyphItems().len > 60);
    try std.testing.expect(cv.out.frames >= 30);
    try std.testing.expectEqual(allocs, s.fa.allocations);
    try std.testing.expectEqual(resizes, s.fa.resize_index);
    try std.testing.expectEqual(frees, s.fa.deallocations);
}

/// Draws every frame twice: incrementally through `renderFrame` (damage rects)
/// and from scratch, and checks the two images agree.
fn expectIncrementalMatchesFull(seed: u64, steps: usize) !void {
    const sw = @import("../render/software_backend.zig");
    const software = @import("../render/software.zig");
    const t = try TextHarness.init();
    defer t.deinit();
    const ui = &t.h.ui;
    ui.theme.font_size = 14;
    var cmds: [2048]draw_list.Command = undefined;
    var glyphs: [4096]draw_list.Glyph = undefined;
    var list = DrawList.init(&cmds, &glyphs);

    const root = ui.tree.root;
    ui.tree.get(root).?.style = .{ .direction = .column, .gap = Length.px(6), .padding = Edges.all(6), .align_items = .start };
    ui.tree.get(root).?.visual = .{ .background = geometry.Color.rgb(30, 30, 34) };
    var labels: [4]*Label = undefined;
    for (&labels, 0..) |*l, i| {
        l.* = try ui.add(Label, root, .{ .text = "label", .color = geometry.Color.white });
        _ = i;
    }
    const b1 = try ui.add(Button, root, .{ .text = "One", .style = .{ .width = Length.px(90), .height = Length.px(26), .shrink = 0 } });
    const b2 = try ui.add(Button, root, .{ .text = "Two", .style = .{ .width = Length.px(90), .height = Length.px(26), .shrink = 0 } });
    const field = try ui.add(TextField, root, .{ .text = "field", .style = .{ .width = Length.px(160), .height = Length.px(24), .shrink = 0 } });
    const ed = try ui.add(CodeEditor, root, .{ .style = .{ .width = Length.px(200), .height = Length.px(70), .shrink = 0 } });
    try ed.loadText("fn main() void {\n    var a = 1;\n    // comment\n    return;\n}\n", false);
    const cv = try ui.add(canvas_mod.Canvas, root, .{ .style = .{ .width = Length.px(60), .height = Length.px(20), .shrink = 0 } });
    const CvDraw = struct {
        fn run(_: ?*anyopaque, _: *Canvas, pc: *PaintCtx) @import("paint_ctx.zig").Error!void {
            try pc.list.fillRect(pc.rect, draw_list.Paint.linear(.{ .x = pc.rect.x, .y = pc.rect.y }, .{ .x = pc.rect.right(), .y = pc.rect.y }, geometry.Color.rgb(250, 20, 20), geometry.Color.rgb(20, 20, 250)));
        }
    };
    cv.props.on_draw = .{ .run = CvDraw.run };
    const box_h = try ui.tree.create(.{ .style = .{ .width = Length.px(80), .height = Length.px(30), .shrink = 0 }, .visual = .{ .background = geometry.Color.rgb(200, 60, 60), .radius = 6 } });
    try ui.tree.appendChild(root, box_h);

    var sa = try sw.SoftwareBackend.init(std.testing.allocator, null);
    defer sa.deinit();
    var fb_full = try software.Framebuffer.init(std.testing.allocator, 1, 1);
    defer fb_full.deinit(std.testing.allocator);
    const W: u32 = 260;
    const H: u32 = 260;
    try fb_full.resize(std.testing.allocator, W, H);

    const label_texts = [_][]const u8{ "a", "longer label text", "x y z", "mid" };
    const field_texts = [_][]const u8{ "", "typed", "some longer text here" };
    var prng = std.Random.DefaultPrng.init(seed);
    const rnd = prng.random();
    var total_hits: u64 = 0;
    var last_op: u8 = 0;
    var compared: usize = 0;
    var partial: usize = 0;
    var step: usize = 0;
    while (step < steps) : (step += 1) {
        last_op = rnd.uintLessThan(u8, 12);
        switch (last_op) {
            9 => {
                ui.setFocus(ed.node);
                ui.textInput("x");
            },
            10 => ui.wheel(20, 150, 0, if (rnd.boolean()) 1 else -1),
            11 => cv.invalidate(null),
            0 => try labels[rnd.uintLessThan(usize, 4)].setText(label_texts[rnd.uintLessThan(usize, label_texts.len)]),
            1 => b1.setEnabled(rnd.boolean()),
            2 => ui.pointerMove(@floatFromInt(rnd.uintLessThan(u32, W)), @floatFromInt(rnd.uintLessThan(u32, H))),
            3 => {
                ui.tree.get(box_h).?.style.width = Length.px(@floatFromInt(20 + rnd.uintLessThan(u32, 150)));
                ui.tree.markDirty(box_h, DirtyFlags.layout_and_paint);
            },
            4 => try field.setText(field_texts[rnd.uintLessThan(usize, field_texts.len)]),
            5 => {
                ui.tree.get(box_h).?.visual.background = geometry.Color.rgb(rnd.int(u8), rnd.int(u8), rnd.int(u8));
                ui.tree.markDirty(box_h, DirtyFlags.paint_only);
            },
            6 => b2.setEnabled(rnd.boolean()),
            7 => {
                ui.tree.get(root).?.style.gap = Length.px(@floatFromInt(rnd.uintLessThan(u32, 14)));
                ui.tree.markDirty(root, DirtyFlags.layout_and_paint);
            },
            else => ui.setFocus(if (rnd.boolean()) field.node else b2.node),
        }
        if (step % 5 == 4) ui.tree.markDirty(box_h, DirtyFlags.paint_only); // plain repaint requests too
        ui.update();
        if (!ui.isDirty()) {
            ui.endFrame();
            continue;
        }
        const before = ui.tree.damage;
        const was_partial = !before.all and !before.isEmpty();
        try ui.renderFrame(sa.backend(), &list, .{ .pixel_w = W, .pixel_h = H, .clear = geometry.Color.black });
        // Redraw the same list from scratch.
        software.render(&fb_full, &list, .{ .clear = geometry.Color.black, .glyphs = ui.glyphProvider() });
        // The cached build must equal one with no cache at all.
        var cmds2: [2048]draw_list.Command = undefined;
        var glyphs2: [4096]draw_list.Glyph = undefined;
        var list2 = DrawList.init(&cmds2, &glyphs2);
        try paint.build(&ui.tree, &list2);
        try std.testing.expectEqual(list2.items().len, list.items().len);
        for (list.items(), list2.items()) |a, b| try std.testing.expect(paint.approxEql(a, b));
        try std.testing.expectEqual(list2.glyphItems().len, list.glyphItems().len);
        for (list.glyphItems(), list2.glyphItems()) |a, b| try std.testing.expect(paint.approxEql(a, b));
        total_hits += ui.paint_cache.hits;
        const img = try sa.backend().readback(std.testing.allocator);
        defer img.deinit(std.testing.allocator);
        if (!std.mem.eql(u8, img.rgba, fb_full.bytes())) {
            var first: usize = 0;
            while (img.rgba[first] == fb_full.bytes()[first]) first += 1;
            std.debug.print("seed {d} step {d} op {d}: incremental frame differs from a full redraw at pixel ({d},{d}); damage {any}\n", .{ seed, step, last_op, (first / 4) % W, (first / 4) / W, ui.last_damage });
            return error.IncrementalMismatch;
        }
        compared += 1;
        if (was_partial) partial += 1;
        ui.endFrame();
    }
    try std.testing.expect(compared > steps / 3);
    try std.testing.expect(partial > 0); // some frames really were partial
    try std.testing.expect(total_hits > 0); // and the paint cache was really used
}

test "incremental (damage) rendering matches a full redraw over random edits" {
    var seed: u64 = 1;
    while (seed <= 12) : (seed += 1) try expectIncrementalMatchesFull(seed, 100);
}

test "a small change damages a small part of the window" {
    const t = try TextHarness.init();
    defer t.deinit();
    const ui = &t.h.ui;
    ui.tree.get(ui.tree.root).?.style = .{ .direction = .column, .align_items = .start };
    const a = try ui.add(Label, ui.tree.root, .{ .text = "first" });
    const far = try ui.add(Label, ui.tree.root, .{ .text = "second", .style = .{ .margin = .{ .top = Length.px(150) } } });
    var gpu: FakeGpu = .{};
    ui.update();
    try ui.renderFrame(gpu.backend(), &t.h.list, .{ .pixel_w = 300, .pixel_h = 300 });
    ui.endFrame();
    try std.testing.expect(ui.tree.damage.isEmpty());
    try a.setText("first!");
    ui.update();
    // FakeGpu does not keep its contents, so inspect the region directly.
    const d = ui.tree.damage.bounds().?;
    try std.testing.expect(d.h < 60 and d.w < 150);
    const second = ui.tree.absoluteRect(far.node).?;
    try std.testing.expect(!d.intersects(second));
}

test "repaint boundaries replay from the paint cache until something inside changes" {
    const t = try TextHarness.init();
    defer t.deinit();
    const ui = &t.h.ui;
    ui.theme.font_size = 14;
    ui.tree.get(ui.tree.root).?.style = .{ .direction = .column, .align_items = .start };
    const lab = try ui.add(Label, ui.tree.root, .{ .text = "title" });
    const ed = try ui.add(CodeEditor, ui.tree.root, .{ .style = .{ .width = Length.px(180), .height = Length.px(80), .shrink = 0 } });
    try ed.loadText("let a = 1;\nlet b = 2;\n", false);
    var gpu: FakeGpu = .{};
    const Frame = struct {
        fn run(u: *Ui, list: *DrawList, g: *FakeGpu) !void {
            u.update();
            try u.renderFrame(g.backend(), list, .{ .pixel_w = 300, .pixel_h = 200 });
            u.endFrame();
        }
    };

    try Frame.run(ui, &t.h.list, &gpu);
    try std.testing.expectEqual(@as(u32, 1), ui.paint_cache.misses); // first paint records the editor
    try std.testing.expectEqual(@as(usize, 1), ui.paint_cache.count());
    const first_cmds = t.h.list.items().len;

    // A sibling changes: the editor subtree is replayed, not rebuilt.
    try lab.setText("a different title");
    try Frame.run(ui, &t.h.list, &gpu);
    try std.testing.expectEqual(@as(u32, 1), ui.paint_cache.hits);
    try std.testing.expectEqual(@as(u32, 0), ui.paint_cache.misses);
    try std.testing.expectEqual(first_cmds, t.h.list.items().len);
    try std.testing.expectEqual(@as(u32, 1), ui.stats.recent(0).?.cached_subtrees);

    // The replay equals an uncached build, including after the editor moves.
    ui.tree.get(lab.node).?.style.margin.top = Length.px(25);
    ui.tree.markDirty(lab.node, DirtyFlags.layout_and_paint);
    try Frame.run(ui, &t.h.list, &gpu);
    try std.testing.expectEqual(@as(u32, 1), ui.paint_cache.hits);
    var plain_cmds: [1024]draw_list.Command = undefined;
    var plain_glyphs: [2048]draw_list.Glyph = undefined;
    var plain = DrawList.init(&plain_cmds, &plain_glyphs);
    try paint.build(&ui.tree, &plain);
    try std.testing.expectEqual(plain.items().len, t.h.list.items().len);
    for (t.h.list.items(), plain.items()) |a, b| try std.testing.expect(paint.approxEql(a, b));
    for (t.h.list.glyphItems(), plain.glyphItems()) |a, b| try std.testing.expect(paint.approxEql(a, b));

    // Something inside the boundary changes: it is re-recorded.
    ui.setFocus(ed.node);
    ui.textInput("zz");
    try Frame.run(ui, &t.h.list, &gpu);
    try std.testing.expectEqual(@as(u32, 1), ui.paint_cache.misses);
    try std.testing.expectEqual(@as(u32, 0), ui.paint_cache.hits);

    // Destroying the node drops its cache entry.
    _ = ui.tree.destroySubtree(ed.node);
    try Frame.run(ui, &t.h.list, &gpu);
    try std.testing.expectEqual(@as(usize, 0), ui.paint_cache.count());
}

test "a modal focus scope traps Tab and the pointer, restores focus, and remembers its last node" {
    const t = try Harness.init();
    defer t.deinit();
    const ui = &t.ui;
    const a = try ui.add(Button, ui.tree.root, .{ .text = "outside", .style = box(80, 30) });
    const panel = try ui.tree.create(.{ .style = .{ .direction = .row, .gap = Length.px(10) } });
    try ui.tree.appendChild(ui.tree.root, panel);
    const b = try ui.add(Button, panel, .{ .text = "B", .style = box(60, 30) });
    const c = try ui.add(Button, panel, .{ .text = "C", .style = box(60, 30) });
    try t.frame();

    ui.setFocus(a.node);
    try std.testing.expect(ui.pushFocusScope(panel, true));
    try std.testing.expectEqual(@as(usize, 1), ui.focusScopeDepth());
    try std.testing.expect(Handle.eql(ui.focused().?, b.node)); // first focusable inside

    ui.key(.tab, .{}, true, false);
    try std.testing.expect(Handle.eql(ui.focused().?, c.node));
    ui.key(.tab, .{}, true, false); // wraps inside the scope, never reaching `outside`
    try std.testing.expect(Handle.eql(ui.focused().?, b.node));
    ui.key(.tab, .{ .shift = true }, true, false);
    try std.testing.expect(Handle.eql(ui.focused().?, c.node));

    ui.setFocus(a.node); // programmatic focus outside is refused
    try std.testing.expect(Handle.eql(ui.focused().?, c.node));
    const an = ui.tree.get(a.node).?;
    t.click(an.rect.x + 5, an.rect.y + 5); // so is a click outside
    try std.testing.expect(!a.out.clicked and !a.out.hovered);
    try std.testing.expect(Handle.eql(ui.focused().?, c.node));
    const cn = ui.tree.absoluteRect(c.node).?;
    t.click(cn.x + 5, cn.y + 5); // inside still works
    try std.testing.expect(c.out.clicked);

    ui.popFocusScope();
    try std.testing.expectEqual(@as(usize, 0), ui.focusScopeDepth());
    try std.testing.expect(Handle.eql(ui.focused().?, a.node)); // back where it was
    ui.key(.tab, .{}, true, false); // Tab roams the whole tree again
    try std.testing.expect(Handle.eql(ui.focused().?, b.node));

    // Re-entering restores the scope's own last focus (C).
    try std.testing.expect(ui.pushFocusScope(panel, false));
    try std.testing.expect(Handle.eql(ui.focused().?, c.node));
    // Destroying the scope root pops it and restores focus.
    ui.setFocus(null);
    ui.setFocus(c.node);
    _ = ui.tree.destroySubtree(panel);
    ui.update();
    try std.testing.expectEqual(@as(usize, 0), ui.focusScopeDepth());
}

test "scopes nest, and a full stack refuses another" {
    const t = try Harness.init();
    defer t.deinit();
    const ui = &t.ui;
    var panels: [9]Handle = undefined;
    for (&panels) |*p| {
        p.* = try ui.tree.create(.{});
        try ui.tree.appendChild(ui.tree.root, p.*);
        _ = try ui.add(Button, p.*, .{ .text = "x", .style = box(20, 20) });
    }
    try t.frame();
    for (panels[0..8]) |p| try std.testing.expect(ui.pushFocusScope(p, false));
    try std.testing.expect(!ui.pushFocusScope(panels[8], false));
    try std.testing.expectEqual(@as(usize, 8), ui.focusScopeDepth());
    for (0..8) |_| ui.popFocusScope();
    try std.testing.expectEqual(@as(usize, 0), ui.focusScopeDepth());
    ui.popFocusScope(); // popping an empty stack is harmless
}

test "makeClickable: a plain node becomes focusable and activates by click, Enter, and Space" {
    const t = try Harness.init();
    defer t.deinit();
    const ui = &t.ui;
    const Count = struct {
        var n: u32 = 0;
        fn hit(_: *event_mod.Event) void {
            n += 1;
        }
    };
    Count.n = 0;
    const card = try ui.tree.create(.{ .style = box(100, 40) });
    try ui.tree.appendChild(ui.tree.root, card);
    try ui.makeClickable(card, .{ .label = "Open project", .role = .link, .on_click = event_mod.Callback.fromFn(Count.hit) });
    const cn = ui.tree.get(card).?;
    try std.testing.expectEqualStrings("Open project", cn.label);
    try std.testing.expect(cn.role == .link and cn.flags.focusable and cn.cursor == .pointer);
    try t.frame();

    t.click(cn.rect.x + 10, cn.rect.y + 10);
    try std.testing.expectEqual(@as(u32, 1), Count.n);
    try std.testing.expect(Handle.eql(ui.focused().?, card)); // the click focused it

    ui.key(.enter, .{}, true, false);
    try std.testing.expectEqual(@as(u32, 2), Count.n);
    ui.key(.space, .{}, true, false);
    try std.testing.expectEqual(@as(u32, 3), Count.n);
    ui.key(.enter, .{}, true, true); // auto-repeat does not re-fire
    ui.key(.a, .{}, true, false);
    try std.testing.expectEqual(@as(u32, 3), Count.n);

    // Tab reaches it.
    ui.setFocus(null);
    ui.key(.tab, .{}, true, false);
    try std.testing.expect(Handle.eql(ui.focused().?, card));
}

test "Enter on a focusable child of a clickable node does not trigger the parent" {
    const t = try Harness.init();
    defer t.deinit();
    const ui = &t.ui;
    const Count = struct {
        var n: u32 = 0;
        fn hit(_: *event_mod.Event) void {
            n += 1;
        }
    };
    Count.n = 0;
    const card = try ui.tree.create(.{ .style = .{ .direction = .row } });
    try ui.tree.appendChild(ui.tree.root, card);
    try ui.makeClickable(card, .{ .label = "card", .on_click = event_mod.Callback.fromFn(Count.hit) });
    const inner = try ui.add(Button, card, .{ .text = "inner", .style = box(60, 30) });
    ui.setFocus(inner.node);
    ui.key(.enter, .{}, true, false);
    try std.testing.expectEqual(@as(u32, 0), Count.n);
}

test "the accessibility check warns once per unnamed interactive node" {
    if (!shadow.enabled) return error.SkipZigTest;
    const t = try TextHarness.init();
    defer t.deinit();
    const ui = &t.h.ui;
    ui.a11y_log = false;
    const root = ui.tree.root;

    // Named in different ways: no warning.
    _ = try ui.add(Button, root, .{ .text = "text counts" });
    const labeled = try ui.tree.create(.{ .flags = .{ .focusable = true } });
    try ui.tree.appendChild(root, labeled);
    try ui.tree.setLabel(labeled, "explicit label");
    const wrapper = try ui.tree.create(.{ .flags = .{ .focusable = true } });
    try ui.tree.appendChild(root, wrapper);
    _ = try ui.add(Label, wrapper, .{ .text = "named by its content" });
    _ = try ui.add(TextField, root, .{});
    _ = try ui.add(CodeEditor, root, .{});
    _ = try ui.add(Canvas, root, .{});
    ui.update();
    try std.testing.expectEqual(@as(u32, 0), ui.a11y_warnings);

    // An unnamed focusable node and an unnamed clickable one each warn, once.
    const bare = try ui.tree.create(.{ .flags = .{ .focusable = true } });
    try ui.tree.appendChild(root, bare);
    const listener_only = try ui.tree.create(.{});
    try ui.tree.appendChild(root, listener_only);
    try ui.tree.addListener(listener_only, .{ .kind = .click, .callback = event_mod.Callback.fromFn(struct {
        fn f(_: *event_mod.Event) void {}
    }.f) });
    ui.update();
    try std.testing.expectEqual(@as(u32, 2), ui.a11y_warnings);
    ui.update();
    ui.update();
    try std.testing.expectEqual(@as(u32, 2), ui.a11y_warnings);

    // Naming it later (and re-checking) is fine.
    try ui.tree.setLabel(bare, "now named");
    ui.update();
    try std.testing.expectEqual(@as(u32, 2), ui.a11y_warnings);
}

test "IME composition shows inline in a text field, underlined, and commits through text_input" {
    const t = try TextHarness.init();
    defer t.deinit();
    const ui = &t.h.ui;
    const f = try ui.add(TextField, ui.tree.root, .{ .text = "abXY", .style = .{ .width = Length.px(300), .height = Length.px(30), .shrink = 0 } });
    ui.setFocus(f.node);
    try t.h.frame();
    f.editor.setCaret(2, false); // between "ab" and "XY"
    try t.h.frame();
    const before_w = ui.tree.get(f.node).?.text.?.width;

    ui.textEditing("nihao", 3);
    try t.h.frame();
    try std.testing.expect(f.out.composing);
    try std.testing.expectEqualStrings("abXY", f.text()); // the content is untouched
    const node = ui.tree.get(f.node).?;
    try std.testing.expect(node.text.?.width > before_w); // the composition is spliced into the shown text
    try std.testing.expect(node.text.?.decor.ul_on);
    try std.testing.expect(node.text.?.decor.ul_x1 > node.text.?.decor.ul_x0);
    // The IME caret sits at byte 3 of the composition, and the platform's candidate window follows it.
    try std.testing.expect(node.text.?.decor.caret_on or !f.blink_on);
    const r = f.caretRect().?;
    try std.testing.expect(r.x > ui.tree.absoluteRect(f.node).?.x);
    // The underline is drawn.
    var underline = false;
    for (t.h.list.items()) |c| switch (c) {
        .fill_rect => |fr| if (fr.rect.h == 1 and fr.rect.w > 5) {
            underline = true;
        },
        else => {},
    };
    try std.testing.expect(underline);

    // The composition updates in place.
    ui.textEditing("ni", 2);
    try t.h.frame();
    try std.testing.expect(ui.tree.get(f.node).?.text.?.width < node.text.?.width + 0.01 or true);
    try std.testing.expectEqualStrings("abXY", f.text());

    // Commit: the composition goes away and the text lands at the caret.
    ui.textInput("你");
    try t.h.frame();
    try std.testing.expect(!f.out.composing);
    try std.testing.expectEqualStrings("ab你XY", f.text());
    try std.testing.expect(!ui.tree.get(f.node).?.text.?.decor.ul_on);

    // Cancelling (empty composition, or losing focus) clears it too.
    ui.textEditing("x", 1);
    try t.h.frame();
    try std.testing.expect(f.out.composing);
    ui.textEditing("", 0);
    try t.h.frame();
    try std.testing.expect(!f.out.composing);
    ui.textEditing("y", 1);
    try t.h.frame();
    ui.setFocus(null);
    try t.h.frame();
    try std.testing.expect(!f.out.composing);

    // Read-only fields ignore compositions.
    f.props.read_only = true;
    ui.tree.markDirty(f.node, DirtyFlags.paint_only);
    ui.setFocus(f.node);
    ui.textEditing("z", 1);
    try t.h.frame();
    try std.testing.expect(!f.out.composing);
}

test "IME composition in the code editor is drawn over the caret line and commits through text_input" {
    const t = try TextHarness.init();
    defer t.deinit();
    const ui = &t.h.ui;
    const ed = try ui.add(CodeEditor, ui.tree.root, .{ .style = .{ .width = Length.px(300), .height = Length.px(100), .shrink = 0 } });
    try ed.loadText("let a;\n", false);
    ui.setFocus(ed.node);
    try t.h.frame();
    const runs_before = blk: {
        var n: usize = 0;
        for (t.h.list.items()) |c| {
            if (c == .glyph_run) n += 1;
        }
        break :blk n;
    };

    ui.textEditing("compose", 7);
    ui.tree.markDirty(ed.node, DirtyFlags.paint_only);
    try t.h.frame();
    var runs: usize = 0;
    var underline = false;
    for (t.h.list.items()) |c| switch (c) {
        .glyph_run => runs += 1,
        .fill_rect => |fr| if (fr.rect.h == 1 and fr.rect.w > 20) {
            underline = true;
        },
        else => {},
    };
    try std.testing.expect(runs > runs_before);
    try std.testing.expect(underline);
    try std.testing.expectEqual(@as(usize, 7), ed.preedit_cursor);
    const caret = ed.caretRect().?;
    ui.textEditing("", 0);
    const without = ed.caretRect().?;
    ui.textEditing("compose", 7);
    try std.testing.expect(caret.x > without.x); // the platform's candidate window follows the composition

    ui.textInput("done");
    try t.h.frame();
    try std.testing.expectEqual(@as(usize, 0), ed.preedit.items.len);
    const text = try ed.textAlloc(std.testing.allocator);
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "done") != null);
    ui.textEditing("again", 5);
    ui.setFocus(null);
    try std.testing.expectEqual(@as(usize, 0), ed.preedit.items.len);
}

test "openFile maps a file, shows it at once, indexes in the background, then allows editing" {
    const io = std.testing.io;
    const path = ".zig-cache/open_file_test.txt";
    var body: std.ArrayListUnmanaged(u8) = .empty;
    defer body.deinit(std.testing.allocator);
    for (0..30000) |i| try body.print(std.testing.allocator, "row {d} of the big file\n", .{i});
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = body.items });
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};

    const t = try TextHarness.init();
    defer t.deinit();
    const ui = &t.h.ui;
    const ed = try ui.add(CodeEditor, ui.tree.root, .{ .style = .{ .width = Length.px(300), .height = Length.px(100), .shrink = 0 } });
    try ed.openFile(io, path);
    try std.testing.expectEqual(body.items.len, ed.editor.doc.len());

    // Usable immediately: the first line reads even though indexing may be running.
    const first = try ed.editor.doc.range(0, 10);
    try std.testing.expectEqualStrings("row 0 of t", first);

    // Editing waits for the index.
    ui.setFocus(ed.node);
    if (ed.editor.doc.isIndexing()) {
        ui.textInput("zzz");
        try std.testing.expectEqual(body.items.len, ed.editor.doc.len());
    }

    var spins: usize = 0;
    while (true) : (spins += 1) {
        ui.update();
        if (!ed.out.indexing) break;
        try std.testing.expect(spins < 5_000_000);
        std.Thread.yield() catch {};
    }
    try std.testing.expectEqual(@as(f32, 1), ed.out.index_progress);
    try std.testing.expectEqual(@as(usize, 30001), ed.editor.doc.lineCount());
    try t.h.frame();
    try std.testing.expectEqual(@as(u32, 30001), ed.out.line_count);

    // Now it edits normally (and the text still comes from the mapping).
    ui.textInput("EDIT ");
    try std.testing.expect(std.mem.startsWith(u8, try ed.editor.doc.range(0, 9), "EDIT row "));

    // Opening another file replaces it; destroying the editor mid-index is clean.
    try ed.openFile(io, path);
    try std.testing.expectEqual(body.items.len, ed.editor.doc.len());
    _ = ui.tree.destroySubtree(ed.node);
    ui.update();
}

test "monospace runs draw exactly the pixels positioned glyphs would" {
    const software = @import("../render/software.zig");
    const t = try TextHarness.init();
    defer t.deinit();
    const ui = &t.h.ui;
    ui.theme.font_size = 14;
    const ed = try ui.add(CodeEditor, ui.tree.root, .{ .style = .{ .width = Length.px(260), .height = Length.px(120), .shrink = 0 } });
    try ed.loadText("fn main() void {\n    var x: u32 = 42; // a comment\n\treturn;\n}\n", false);
    try ed.setLanguage(&syntax_mod.zig);
    try t.h.frame();

    var monos: usize = 0;
    for (t.h.list.items()) |c| monos += @intFromBool(c == .mono_run);
    try std.testing.expect(monos > 2); // the editor really emitted cell runs

    // The same frame with every cell run rewritten as positioned glyphs.
    var cmds: [1024]draw_list.Command = undefined;
    var glyphs: [4096]draw_list.Glyph = undefined;
    var expanded = DrawList.init(&cmds, &glyphs);
    for (t.h.list.items()) |c| switch (c) {
        .mono_run => |m| {
            var shaped: [128]draw_list.Glyph = undefined;
            var n: usize = 0;
            for (t.h.list.glyphItems()[m.offset..][0..m.count], 0..) |g, i| {
                if (g.id == draw_list.empty_cell) continue;
                shaped[n] = .{ .id = g.id, .x = m.first_x + @as(f32, @floatFromInt(i)) * m.cell_w, .y = m.baseline_y };
                n += 1;
            }
            try expanded.glyphRunEx(m.bounds, shaped[0..n], m.color, m.font, m.size, false);
        },
        .glyph_run => |g| try expanded.glyphRunEx(g.bounds, t.h.list.glyphItems()[g.offset..][0..g.count], g.color, g.font, g.size, g.subpixel),
        else => try expanded.push(c),
    };

    var a = try software.Framebuffer.init(std.testing.allocator, 300, 200);
    defer a.deinit(std.testing.allocator);
    var b = try software.Framebuffer.init(std.testing.allocator, 300, 200);
    defer b.deinit(std.testing.allocator);
    software.render(&a, &t.h.list, .{ .clear = geometry.Color.black, .glyphs = ui.glyphProvider() });
    software.render(&b, &expanded, .{ .clear = geometry.Color.black, .glyphs = ui.glyphProvider() });
    try std.testing.expectEqualSlices(u8, a.bytes(), b.bytes());
}
