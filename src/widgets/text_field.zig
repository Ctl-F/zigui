//! TextField: single-line editable text. Props, state, and editing behavior in
//! one struct (with a `ui` back-pointer: the `Ui` must not move).
//!
//! The content lives in toolkit-owned storage; read it with `text()` and set it
//! with `setText()`. `out.changed` / `out.submitted` are
//! frame-scoped, the counters only grow, and the callbacks come from the same
//! events, so polling and callbacks never disagree. Programmatic changes via
//! `setText` do not count as edits.
//!
//! Editing: typing, Backspace/Delete, arrows, Home/End, Ctrl/Alt+arrows and
//! Ctrl/Alt+Backspace/Delete by word, Shift to select, Ctrl+A/C/X/V (Cmd on
//! macOS too), mouse click/drag, double-click for a word, triple-click for all,
//! Enter to submit. Not yet: undo/redo, IME composition display, password mode,
//! max length.

const std = @import("std");
const Handle = @import("../core/handle.zig").Handle;
const shadow = @import("../core/shadow.zig");
const event = @import("../core/event.zig");
const keys = @import("../core/keys.zig");
const DirtyFlags = @import("../core/dirty.zig").DirtyFlags;
const Rect = @import("../core/geometry.zig").Rect;
const layout_mod = @import("../core/layout.zig");
const text_block = @import("../text/block.zig");
const Stop = @import("../text/system.zig").Stop;
const LineEditor = @import("../text/line_editor.zig").LineEditor;
const label = @import("label.zig");
const Ui = @import("../core/ui.zig").Ui;
const paint_ctx = @import("../core/paint_ctx.zig");
const PaintCtx = paint_ctx.PaintCtx;
const FieldColors = @import("theme.zig").FieldColors;
const Style = @import("../core/style.zig").Style;
const Node = @import("../core/tree.zig").Node;

pub const Text = @import("common.zig").Text;
pub const Font = label.Font;

/// Draws a field's box and picks its text, selection, and caret colors.
pub const Painter = *const fn (ctx: *PaintCtx, f: *const TextField) paint_ctx.Error!void;

/// How long the caret stays on or off, in milliseconds.
const blink_ms: u64 = 530;

pub const TextField = struct {
    props: Props = .{},
    out: Out = .{},
    node: Handle,
    ui: *Ui,

    // Internal state (not part of the app-facing API).
    checker: shadow.Checker(Props),
    editor: LineEditor,
    stops: std.ArrayListUnmanaged(Stop) = .empty,
    /// Content changed: reshape and recompute caret stops.
    text_dirty: bool = true,
    stops_font: u32 = std.math.maxInt(u32),
    stops_size: f32 = 0,
    scroll_x: f32 = 0,
    blink_on: bool = true,
    blink_at: u64 = 0,
    dragging: bool = false,

    pub const Props = struct {
        /// Shown, dimmed, while the field is empty.
        placeholder: Text = .{},
        enabled: bool = true,
        read_only: bool = false,
        font: Font = .ui,
        /// Em size in logical pixels; 0 uses the theme's size.
        size: f32 = 0,
        on_change: ?event.Callback = null,
        on_submit: ?event.Callback = null,
        /// Overrides the theme's colors for this field.
        colors: ?FieldColors = null,
        /// Overrides the theme's painter for this field (use `setPainter`).
        painter: ?Painter = null,

        pub const dirty_map = .{
            .colors = shadow.Category.paint,
            .placeholder = shadow.Category.layout,
            .enabled = shadow.Category.paint,
            .read_only = shadow.Category.paint,
            .font = shadow.Category.layout,
            .size = shadow.Category.layout,
        };
    };

    pub const Out = struct {
        /// The user edited the text this frame.
        changed: bool = false,
        /// Enter was pressed this frame.
        submitted: bool = false,
        focused: bool = false,
        hovered: bool = false,
        change_count: u32 = 0,
        submit_count: u32 = 0,
        /// Caret and selection as byte offsets into the text.
        caret: u32 = 0,
        sel_start: u32 = 0,
        sel_end: u32 = 0,
    };

    pub const Options = struct {
        style: Style = .{},
        /// Initial content (not counted as an edit).
        text: []const u8 = "",
        placeholder: []const u8 = "",
        enabled: bool = true,
        read_only: bool = false,
        font: Font = .ui,
        size: f32 = 0,
        on_change: ?event.Callback = null,
        on_submit: ?event.Callback = null,
        colors: ?FieldColors = null,
        painter: ?Painter = null,
    };

    pub const listened_kinds = [_]event.EventKind{
        .focus_in, .focus_out, .pointer_enter, .pointer_leave,
        .pointer_down, .pointer_move, .pointer_up, .key_down, .text_input,
    };

    pub fn nodeTemplate(style: Style) Node {
        return .{
            .role = .text_field,
            .cursor = .text,
            .flags = .{ .focusable = true, .clip_children = true, .accepts_text = true },
            .style = style,
        };
    }

    pub fn apply(self: *TextField, o: Options) !void {
        self.props.enabled = o.enabled;
        self.props.read_only = o.read_only;
        self.props.font = o.font;
        self.props.size = o.size;
        self.props.on_change = o.on_change;
        self.props.on_submit = o.on_submit;
        self.props.colors = o.colors;
        self.props.painter = o.painter;
        if (o.text.len > 0) try self.setText(o.text);
        if (o.placeholder.len > 0) try self.setPlaceholder(o.placeholder);
        self.checker.sync(&self.props);
    }

    pub fn init(ui: *Ui, node: Handle) TextField {
        const props: Props = .{};
        return .{
            .node = node,
            .ui = ui,
            .checker = shadow.Checker(Props).init(&props),
            .editor = LineEditor.init(ui.gpa),
        };
    }

    pub fn deinit(self: *TextField) void {
        self.ui.freeText(&self.props.placeholder);
        self.stops.deinit(self.ui.gpa);
        self.editor.deinit();
    }

    // ---- API --------------------------------------------------------------

    /// The field's current text. Valid until the next edit or `setText`.
    pub fn text(self: *TextField) []const u8 {
        return self.editor.text();
    }

    /// Replace the content (caret to the end). This is not a user edit: it does
    /// not set `out.changed` or call `on_change`.
    pub fn setText(self: *TextField, new_text: []const u8) !void {
        try self.editor.setText(new_text);
        self.touchText();
    }

    pub fn setPlaceholder(self: *TextField, new_text: []const u8) !void {
        try self.ui.replaceText(&self.props.placeholder, new_text);
        self.ui.tree.markDirty(self.node, DirtyFlags.layout_and_paint);
    }

    /// The colors in effect: this field's override, else the theme's.
    pub fn colors(self: *const TextField) FieldColors {
        return self.props.colors orelse self.ui.theme.field;
    }

    /// The node's painter hook: runs this field's painter, else the theme's.
    pub fn paintHook(self: *TextField, pc: *PaintCtx) paint_ctx.Error!void {
        const p = self.props.painter orelse self.ui.theme.field_painter;
        try p(pc, self);
    }

    pub fn setPainter(self: *TextField, p: ?Painter) void {
        self.props.painter = p;
        self.ui.tree.markDirty(self.node, DirtyFlags.paint_only);
    }

    fn touchText(self: *TextField) void {
        self.text_dirty = true;
        self.blink_on = true;
        self.blink_at = self.ui.now_ms;
        self.ui.tree.markDirty(self.node, DirtyFlags.layout_and_paint);
    }

    /// Caret movement or selection change: repaint, keep the caret visible.
    fn touchCaret(self: *TextField) void {
        self.blink_on = true;
        self.blink_at = self.ui.now_ms;
        self.ui.tree.markDirty(self.node, DirtyFlags.paint_only);
    }

    // ---- events -----------------------------------------------------------

    /// Byte offset of the caret stop nearest to `x` (relative to the text origin).
    fn byteAtX(stops: []const Stop, x: f32) usize {
        var best: usize = 0;
        var best_d: f32 = std.math.inf(f32);
        for (stops) |st| {
            const d = @abs(st.x - x);
            if (d < best_d) {
                best_d = d;
                best = st.byte;
            }
        }
        return best;
    }

    pub fn handleEvent(self: *TextField, ev: *event.Event) void {
        const props = &self.props;
        const out = &self.out;
        const ed = &self.editor;
        const tree = &self.ui.tree;

        switch (ev.kind) {
            .focus_in => {
                out.focused = true;
                self.touchCaret();
            },
            .focus_out => {
                out.focused = false;
                self.dragging = false;
                self.touchCaret();
            },
            .pointer_enter => out.hovered = true,
            .pointer_leave => out.hovered = false,
            .pointer_down => if (props.enabled and ev.button == 1) {
                // Not marked handled: the default action focuses the field.
                const node = tree.get(self.node).?;
                const pad = layout_mod.resolveEdges(node.style.padding, null);
                const byte = byteAtX(self.stops.items, ev.local_x - pad.l + self.scroll_x);
                if (ev.clicks >= 3) {
                    ed.selectAll();
                } else if (ev.clicks == 2) {
                    ed.selectWordAt(byte);
                } else {
                    ed.setCaret(byte, ev.mods.shift);
                }
                self.dragging = true;
                self.touchCaret();
            },
            .pointer_move => if (self.dragging) {
                const node = tree.get(self.node).?;
                const pad = layout_mod.resolveEdges(node.style.padding, null);
                ed.setCaret(byteAtX(self.stops.items, ev.local_x - pad.l + self.scroll_x), true);
                self.touchCaret();
            },
            .pointer_up => self.dragging = false,
            .text_input => if (props.enabled and !props.read_only) {
                const changed = ed.insert(ev.text) catch false;
                if (changed) self.afterEdit(ev);
            },
            .key_down => self.key(ev),
            else => {},
        }
    }

    fn key(self: *TextField, ev: *event.Event) void {
        const props = &self.props;
        if (!props.enabled) return;
        const ed = &self.editor;
        const shift = ev.mods.shift;
        const cmd = ev.mods.any(.{ .ctrl = true, .gui = true });
        const word = ev.mods.any(.{ .ctrl = true, .alt = true });
        const writable = !props.read_only;
        var edited = false;

        switch (ev.key) {
            .left => ed.moveLeft(shift, word),
            .right => ed.moveRight(shift, word),
            .home => ed.home(shift),
            .end => ed.end(shift),
            .backspace => if (writable) {
                edited = ed.deleteBackward(word);
            },
            .delete => if (writable) {
                edited = ed.deleteForward(word);
            },
            .a => if (cmd) ed.selectAll() else return,
            .c => if (cmd) self.copySelection() else return,
            .x => if (cmd) {
                self.copySelection();
                if (writable) edited = ed.deleteSelection();
            } else return,
            .v => if (cmd) {
                if (writable) edited = self.pasteInto();
            } else return,
            .enter => {
                self.out.submitted = true;
                self.out.submit_count +%= 1;
                if (props.on_submit) |cb| cb.invoke(ev);
            },
            else => return,
        }
        ev.markHandled();
        if (edited) self.afterEdit(ev) else self.touchCaret();
    }

    fn afterEdit(self: *TextField, ev: *event.Event) void {
        self.touchText();
        self.out.changed = true;
        self.out.change_count +%= 1;
        if (self.props.on_change) |cb| cb.invoke(ev);
    }

    fn copySelection(self: *TextField) void {
        const cb = self.ui.clipboard orelse return;
        if (!self.editor.hasSelection()) return;
        cb.set(cb.ctx, self.editor.selectedText());
    }

    /// Paste the clipboard (newlines and tabs become spaces). True if text changed.
    fn pasteInto(self: *TextField) bool {
        const cb = self.ui.clipboard orelse return false;
        const bytes = cb.get(cb.ctx, self.ui.gpa) orelse return false;
        defer self.ui.gpa.free(bytes);
        for (bytes) |*b| {
            if (b.* == '\n' or b.* == '\r' or b.* == '\t') b.* = ' ';
        }
        return self.editor.insert(bytes) catch false;
    }

    // ---- frame ------------------------------------------------------------

    /// Disabled fields leave the tab order.
    pub fn prepare(self: *TextField) void {
        self.ui.tree.get(self.node).?.flags.focusable = self.props.enabled;
    }

    /// x of the caret stop at byte offset `byte` (stops are sorted by byte).
    fn stopX(stops: []const Stop, byte: usize) f32 {
        for (stops) |st| if (st.byte >= byte) return st.x;
        return if (stops.len > 0) stops[stops.len - 1].x else 0;
    }

    /// Per-frame sync: reshape if needed, scroll the caret into view, and
    /// publish selection and caret as paint decorations.
    pub fn update(self: *TextField) void {
        const ui = self.ui;
        const node = ui.tree.get(self.node).?;
        ui.verifyProps(self.node, &self.checker, &self.props, "text_field");

        const f = switch (self.props.font) {
            .ui => ui.theme.ui_font,
            .mono => ui.theme.mono_font,
        };
        const size = if (self.props.size > 0) self.props.size else ui.theme.font_size;
        if (f >= ui.text.fonts.items.len) return;

        const content = self.editor.text();
        if (self.text_dirty or self.stops_font != f or self.stops_size != size) {
            self.stops.clearRetainingCapacity();
            _ = ui.text.boundaries(f, size, content, &self.stops, ui.gpa) catch {};
            self.stops_font = f;
            self.stops_size = size;
        }
        const empty = content.len == 0;
        const shown: Text = if (empty) self.props.placeholder else .{ .bytes = content };
        // Colors are the painter's job; this is only the shaped default.
        ui.syncTextEx(self.node, shown, f, size, ui.theme.text_color, .start, .{ .force = self.text_dirty, .keep_empty = true });
        self.text_dirty = false;
        const is_focused = self.out.focused and self.props.enabled;

        // Out block.
        const sel = self.editor.selection();
        self.out.caret = @intCast(self.editor.caret);
        self.out.sel_start = @intCast(sel.start);
        self.out.sel_end = @intCast(sel.end);

        // Decorations and horizontal scroll.
        const text_node = node.text orelse return;
        const pad = layout_mod.resolveEdges(node.style.padding, null);
        const view_w = @max(node.rect.w - pad.l - pad.r, 0);
        const caret_x = stopX(self.stops.items, self.editor.caret);
        const total = if (self.stops.items.len > 0) self.stops.items[self.stops.items.len - 1].x else 0;
        if (view_w > 0) {
            if (caret_x - self.scroll_x > view_w - 1) self.scroll_x = caret_x - view_w + 1;
            if (caret_x - self.scroll_x < 0) self.scroll_x = caret_x;
            self.scroll_x = std.math.clamp(self.scroll_x, 0, @max(total - view_w + 1, 0));
        }
        var decor: text_block.Decor = .{ .scroll_x = self.scroll_x };
        if (is_focused) {
            if (self.editor.hasSelection()) {
                decor.sel_on = true;
                decor.sel_x0 = stopX(self.stops.items, sel.start);
                decor.sel_x1 = stopX(self.stops.items, sel.end);
            } else if (self.blink_on and !self.props.read_only) {
                decor.caret_on = true;
                decor.caret_x = caret_x;
            }
        }
        if (!std.mem.eql(u8, std.mem.asBytes(&decor), std.mem.asBytes(&text_node.decor))) {
            text_node.decor = decor;
            ui.tree.markDirty(self.node, DirtyFlags.paint_only);
        }
    }

    pub fn endFrame(self: *TextField) void {
        self.out.changed = false;
        self.out.submitted = false;
    }

    // ---- timing and IME -----------------------------------------------------

    /// Blink the caret. Returns true if the blink phase changed.
    pub fn tick(self: *TextField, now: u64) bool {
        if (!self.out.focused or !self.props.enabled) return false;
        if (now -% self.blink_at >= blink_ms) {
            self.blink_on = !self.blink_on;
            self.blink_at = now;
            return true;
        }
        return false;
    }

    pub fn msUntilBlink(self: *const TextField, now: u64) ?u64 {
        if (!self.out.focused or !self.props.enabled) return null;
        const elapsed = now -% self.blink_at;
        return if (elapsed >= blink_ms) 1 else blink_ms - elapsed;
    }

    /// Caret rectangle in window coordinates, for IME placement.
    pub fn caretRect(self: *TextField) ?Rect {
        const abs = self.ui.tree.absoluteRect(self.node) orelse return null;
        const node = self.ui.tree.get(self.node).?;
        const pad = layout_mod.resolveEdges(node.style.padding, null);
        const x = abs.x + pad.l + stopX(self.stops.items, self.editor.caret) - self.scroll_x;
        return .{ .x = x, .y = abs.y, .w = 1, .h = abs.h };
    }
};

/// The default look: a rounded box (highlighted border when focused), with
/// text colored for disabled / placeholder / normal, and selection and caret colors.
pub fn defaultPainter(pc: *PaintCtx, f: *const TextField) paint_ctx.Error!void {
    const c = f.colors();
    const is_focused = f.out.focused and f.props.enabled;
    try pc.box(.{
        .background = if (f.props.enabled) c.background else c.background_disabled,
        .border_color = if (is_focused) c.border_focus else c.border,
        .border_width = 1,
        .radius = f.ui.theme.corner_radius,
    });
    const empty = f.editor.buf.len() == 0;
    pc.text_color = if (!f.props.enabled) c.text_disabled else if (empty) c.placeholder else c.text;
    pc.selection_color = c.selection;
    pc.caret_color = c.caret;
}
