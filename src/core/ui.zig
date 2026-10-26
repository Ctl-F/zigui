//! Ui: ties the tree, layout, input, widgets, and theme together.
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
const button = @import("../widgets/button.zig");
const Theme = @import("../widgets/theme.zig").Theme;
const label = @import("../widgets/label.zig");
const Text = @import("../widgets/common.zig").Text;
const font = @import("../text/font.zig");
const TextSystem = @import("../text/system.zig").TextSystem;
const text_block = @import("../text/block.zig");
const Color = geometry.Color;
const text_field = @import("../widgets/text_field.zig");
const code_editor = @import("../widgets/code_editor.zig");
const EditorCore = @import("../editor/editor.zig").Editor;
const style_mod = @import("style.zig");
const LineEditor = @import("../text/line_editor.zig").LineEditor;
const Stop = @import("../text/system.zig").Stop;
const layout_mod = @import("layout.zig");
const event_types = @import("event.zig");
const commands_mod = @import("commands.zig");
const shortcuts_mod = @import("shortcuts.zig");

pub const Scope = shortcuts_mod.Scope;
pub const BindError = shortcuts_mod.BindError;
pub const LoadReport = shortcuts_mod.LoadReport;

/// A button's link to a command: clicking the button runs the command.
const CommandLink = struct {
    ui: *Ui,
    name: []u8,
};

const Button = button.Button;
const Label = label.Label;
const TextField = text_field.TextField;
const CodeEditor = code_editor.CodeEditor;

/// How long the caret stays on or off, in milliseconds.
const blink_ms: u64 = 530;

pub const Clipboard = @import("clipboard.zig").Clipboard;

const FieldSlot = struct {
    block: TextField,
    checker: shadow.Checker(TextField.Props),
    editor: LineEditor,
    stops: std.ArrayListUnmanaged(Stop) = .empty,
    ui: *Ui,
    /// Content changed: reshape and recompute caret stops.
    text_dirty: bool = true,
    stops_font: u32 = std.math.maxInt(u32),
    stops_size: f32 = 0,
    scroll_x: f32 = 0,
    blink_on: bool = true,
    blink_at: u64 = 0,
    dragging: bool = false,
};

const ButtonSlot = struct {
    block: Button,
    checker: shadow.Checker(Button.Props),
    link: ?*CommandLink = null,
};

const LabelSlot = struct {
    block: Label,
    checker: shadow.Checker(Label.Props),
};

pub const Ui = struct {
    gpa: std.mem.Allocator,
    text: TextSystem,
    tree: Tree,
    layout: Layout,
    input: Input = .{},
    theme: Theme = .{},
    buttons: Pool(ButtonSlot, 64),
    labels: Pool(LabelSlot, 64),
    fields: Pool(FieldSlot, 64),
    editors: Pool(code_editor.Slot, 16),
    clipboard: ?Clipboard = null,
    /// Last time passed to `tick`, in milliseconds.
    now_ms: u64 = 0,
    commands: commands_mod.Commands,
    shortcuts: shortcuts_mod.Shortcuts,

    pub fn init(gpa: std.mem.Allocator) !Ui {
        var tree = try Tree.init(gpa);
        errdefer tree.deinit();
        return .{
            .gpa = gpa,
            .text = TextSystem.init(gpa),
            .tree = tree,
            .layout = Layout.init(gpa),
            .buttons = Pool(ButtonSlot, 64).init(gpa),
            .labels = Pool(LabelSlot, 64).init(gpa),
            .fields = Pool(FieldSlot, 64).init(gpa),
            .editors = Pool(code_editor.Slot, 16).init(gpa),
            .commands = commands_mod.Commands.init(gpa),
            .shortcuts = shortcuts_mod.Shortcuts.init(gpa),
        };
    }

    pub fn deinit(self: *Ui) void {
        var it = self.buttons.iterator();
        while (it.next()) |e| {
            self.freeText(&e.ptr.block.props.text);
            self.freeLink(e.ptr);
        }
        self.buttons.deinit();
        self.shortcuts.deinit();
        self.commands.deinit();
        var lit = self.labels.iterator();
        while (lit.next()) |e| self.freeText(&e.ptr.block.props.text);
        self.labels.deinit();
        var fit = self.fields.iterator();
        while (fit.next()) |e| self.freeField(e.ptr);
        self.fields.deinit();
        var eit = self.editors.iterator();
        while (eit.next()) |e| e.ptr.deinit();
        self.editors.deinit();
        self.text.deinit();
        self.layout.deinit();
        self.tree.deinit();
        self.* = undefined;
    }

    // ---- buttons ----------------------------------------------------------

    /// Create a button node under `parent`. The returned pointer is stable
    /// until the button's node is destroyed (the block is reclaimed in `update`).
    pub fn createButton(self: *Ui, parent: Handle, style: Style) !*Button {
        const node_h = try self.tree.create(.{ .role = .button, .flags = .{ .focusable = true }, .style = style });
        errdefer _ = self.tree.destroySubtree(node_h);
        try self.tree.appendChild(parent, node_h);

        var block: Button = .{ .node = node_h };
        const slot_h = try self.buttons.create(.{ .block = block, .checker = shadow.Checker(Button.Props).init(&block.props) });
        const slot = self.buttons.get(slot_h).?;
        errdefer _ = self.buttons.destroy(slot_h);
        for (button.listened_kinds) |kind| {
            try self.tree.addListener(node_h, .{ .kind = kind, .callback = button.handleEvent, .user_data = &slot.block });
        }
        return &slot.block;
    }

    fn freeText(self: *Ui, t: *Text) void {
        if (t.ptr) |p| self.gpa.free(p[0..t.len]);
        t.* = .{};
    }

    /// Replace a widget's text with a toolkit-owned copy of `text`.
    fn replaceText(self: *Ui, t: *Text, text: []const u8) !void {
        const copy = try self.gpa.dupe(u8, text);
        self.freeText(t);
        t.* = .{ .ptr = copy.ptr, .len = copy.len };
    }

    /// Copy `text` into toolkit-owned storage; the caller may free its own copy.
    pub fn setButtonText(self: *Ui, b: *Button, text: []const u8) !void {
        try self.replaceText(&b.props.text, text);
        self.tree.markDirty(b.node, DirtyFlags.layout_and_paint);
    }

    // ---- labels -----------------------------------------------------------

    pub fn createLabel(self: *Ui, parent: Handle, style: Style, text: []const u8) !*Label {
        const node_h = try self.tree.create(.{ .role = .label, .style = style });
        errdefer _ = self.tree.destroySubtree(node_h);
        try self.tree.appendChild(parent, node_h);

        var blk: Label = .{ .node = node_h };
        const slot_h = try self.labels.create(.{ .block = blk, .checker = shadow.Checker(Label.Props).init(&blk.props) });
        errdefer _ = self.labels.destroy(slot_h);
        const slot = self.labels.get(slot_h).?;
        try self.replaceText(&slot.block.props.text, text);
        slot.checker.sync(&slot.block.props);
        return &slot.block;
    }

    pub fn setLabelText(self: *Ui, l: *Label, text: []const u8) !void {
        try self.replaceText(&l.props.text, text);
        self.tree.markDirty(l.node, DirtyFlags.layout_and_paint);
    }

    // ---- text fields ------------------------------------------------------

    /// Create a single-line text field. The `Ui` must not be moved afterwards
    /// (the field's handlers keep a pointer to it).
    pub fn createTextField(self: *Ui, parent: Handle, style: Style) !*TextField {
        const node_h = try self.tree.create(.{
            .role = .text_field,
            .cursor = .text,
            .flags = .{ .focusable = true, .clip_children = true, .accepts_text = true },
            .style = style,
        });
        errdefer _ = self.tree.destroySubtree(node_h);
        try self.tree.appendChild(parent, node_h);

        var blk: TextField = .{ .node = node_h };
        const slot_h = try self.fields.create(.{
            .block = blk,
            .checker = shadow.Checker(TextField.Props).init(&blk.props),
            .editor = LineEditor.init(self.gpa),
            .ui = self,
        });
        const slot = self.fields.get(slot_h).?;
        errdefer {
            self.freeField(slot);
            _ = self.fields.destroy(slot_h);
        }
        for (field_kinds) |kind| {
            try self.tree.addListener(node_h, .{ .kind = kind, .callback = fieldEvent, .user_data = slot });
        }
        return &slot.block;
    }

    fn slotOf(tf: *TextField) *FieldSlot {
        return @fieldParentPtr("block", tf);
    }

    fn freeField(self: *Ui, slot: *FieldSlot) void {
        self.freeText(&slot.block.props.placeholder);
        slot.stops.deinit(self.gpa);
        slot.editor.deinit();
    }

    /// The field's current text. Valid until the next edit or `setTextFieldText`.
    pub fn textFieldText(self: *Ui, tf: *TextField) []const u8 {
        _ = self;
        return slotOf(tf).editor.text();
    }

    /// Replace the content (caret to the end). This is not a user edit: it does
    /// not set `out.changed` or call `on_change`.
    pub fn setTextFieldText(self: *Ui, tf: *TextField, text: []const u8) !void {
        const slot = slotOf(tf);
        try slot.editor.setText(text);
        self.touchField(slot);
    }

    pub fn setTextFieldPlaceholder(self: *Ui, tf: *TextField, text: []const u8) !void {
        try self.replaceText(&tf.props.placeholder, text);
        self.tree.markDirty(tf.node, DirtyFlags.layout_and_paint);
    }

    fn touchField(self: *Ui, slot: *FieldSlot) void {
        slot.text_dirty = true;
        slot.blink_on = true;
        slot.blink_at = self.now_ms;
        self.tree.markDirty(slot.block.node, DirtyFlags.layout_and_paint);
    }

    /// Caret movement or selection change: repaint, keep the caret visible.
    fn touchCaret(self: *Ui, slot: *FieldSlot) void {
        slot.blink_on = true;
        slot.blink_at = self.now_ms;
        self.tree.markDirty(slot.block.node, DirtyFlags.paint_only);
    }

    const field_kinds = [_]event_types.EventKind{
        .focus_in, .focus_out, .pointer_enter, .pointer_leave,
        .pointer_down, .pointer_move, .pointer_up, .key_down, .text_input,
    };

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

    fn fieldEvent(ev: *event_types.Event, user: ?*anyopaque) callconv(.c) void {
        const slot: *FieldSlot = @ptrCast(@alignCast(user.?));
        const self = slot.ui;
        const props = &slot.block.props;
        const out = &slot.block.out;
        const ed = &slot.editor;

        switch (ev.kind) {
            .focus_in => {
                out.focused = true;
                self.touchCaret(slot);
            },
            .focus_out => {
                out.focused = false;
                slot.dragging = false;
                self.touchCaret(slot);
            },
            .pointer_enter => out.hovered = true,
            .pointer_leave => out.hovered = false,
            .pointer_down => if (props.enabled and ev.button == 1) {
                // Not marked handled: the default action focuses the field.
                const node = self.tree.get(slot.block.node).?;
                const pad = layout_mod.resolveEdges(node.style.padding, null);
                const byte = byteAtX(slot.stops.items, ev.local_x - pad.l + slot.scroll_x);
                if (ev.clicks >= 3) {
                    ed.selectAll();
                } else if (ev.clicks == 2) {
                    ed.selectWordAt(byte);
                } else {
                    ed.setCaret(byte, ev.hasMod(keys.mod_shift));
                }
                slot.dragging = true;
                self.touchCaret(slot);
            },
            .pointer_move => if (slot.dragging) {
                const node = self.tree.get(slot.block.node).?;
                const pad = layout_mod.resolveEdges(node.style.padding, null);
                ed.setCaret(byteAtX(slot.stops.items, ev.local_x - pad.l + slot.scroll_x), true);
                self.touchCaret(slot);
            },
            .pointer_up => slot.dragging = false,
            .text_input => if (props.enabled and !props.read_only) {
                const changed = ed.insert(ev.textSlice()) catch false;
                if (changed) self.afterEdit(slot, ev);
            },
            .key_down => self.fieldKey(slot, ev),
            else => {},
        }
    }

    fn fieldKey(self: *Ui, slot: *FieldSlot, ev: *event_types.Event) void {
        const props = &slot.block.props;
        if (!props.enabled) return;
        const ed = &slot.editor;
        const shift = ev.hasMod(keys.mod_shift);
        const cmd = ev.hasMod(keys.mod_ctrl | keys.mod_gui);
        const word = ev.hasMod(keys.mod_ctrl | keys.mod_alt);
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
            .c => if (cmd) self.copySelection(slot) else return,
            .x => if (cmd) {
                self.copySelection(slot);
                if (writable) edited = ed.deleteSelection();
            } else return,
            .v => if (cmd) {
                if (writable) edited = self.pasteInto(slot);
            } else return,
            .enter => {
                slot.block.out.submitted = true;
                slot.block.out.submit_count +%= 1;
                if (props.on_submit) |cb| cb(ev, props.on_submit_user);
            },
            else => return,
        }
        ev.markHandled();
        if (edited) self.afterEdit(slot, ev) else self.touchCaret(slot);
    }

    fn afterEdit(self: *Ui, slot: *FieldSlot, ev: *event_types.Event) void {
        self.touchField(slot);
        slot.block.out.changed = true;
        slot.block.out.change_count +%= 1;
        if (slot.block.props.on_change) |cb| cb(ev, slot.block.props.on_change_user);
    }

    fn copySelection(self: *Ui, slot: *FieldSlot) void {
        const cb = self.clipboard orelse return;
        if (!slot.editor.hasSelection()) return;
        cb.set(cb.ctx, slot.editor.selectedText());
    }

    /// Paste the clipboard (newlines and tabs become spaces). True if text changed.
    fn pasteInto(self: *Ui, slot: *FieldSlot) bool {
        const cb = self.clipboard orelse return false;
        const bytes = cb.get(cb.ctx, self.gpa) orelse return false;
        defer self.gpa.free(bytes);
        for (bytes) |*b| {
            if (b.* == '\n' or b.* == '\r' or b.* == '\t') b.* = ' ';
        }
        return slot.editor.insert(bytes) catch false;
    }

    /// Per-frame sync for one field: reshape if needed, scroll the caret into
    /// view, and publish selection and caret as paint decorations.
    fn updateField(self: *Ui, slot: *FieldSlot) void {
        const blk = &slot.block;
        const node = self.tree.get(blk.node).?;
        self.verifyProps(blk.node, &slot.checker, &blk.props, "text_field");
        node.flags.focusable = blk.props.enabled;

        const colors = self.theme.field;
        const f = switch (blk.props.font) {
            .ui => self.theme.ui_font,
            .mono => self.theme.mono_font,
        };
        const size = if (blk.props.size > 0) blk.props.size else self.theme.font_size;
        if (f >= self.text.fonts.items.len) return;

        const content = slot.editor.text();
        if (slot.text_dirty or slot.stops_font != f or slot.stops_size != size) {
            slot.stops.clearRetainingCapacity();
            _ = self.text.boundaries(f, size, content, &slot.stops, self.gpa) catch {};
            slot.stops_font = f;
            slot.stops_size = size;
        }
        const empty = content.len == 0;
        const shown: Text = if (empty)
            blk.props.placeholder
        else
            .{ .ptr = content.ptr, .len = content.len };
        const color = if (!blk.props.enabled) colors.text_disabled else if (empty) colors.placeholder else colors.text;
        self.syncTextEx(blk.node, shown, f, size, color, .start, .{ .force = slot.text_dirty, .keep_empty = true });
        slot.text_dirty = false;

        // Look.
        const is_focused = blk.out.focused and blk.props.enabled;
        const look: style_mod.Visual = .{
            .background = if (blk.props.enabled) colors.background else colors.background_disabled,
            .border_color = if (is_focused) colors.border_focus else colors.border,
            .border_width = 1,
            .radius = self.theme.corner_radius,
        };
        if (!std.mem.eql(u8, std.mem.asBytes(&look), std.mem.asBytes(&node.visual))) {
            node.visual = look;
            self.tree.markDirty(blk.node, DirtyFlags.paint_only);
        }

        // Out block.
        const sel = slot.editor.selection();
        blk.out.caret = @intCast(slot.editor.caret);
        blk.out.sel_start = @intCast(sel.start);
        blk.out.sel_end = @intCast(sel.end);

        // Decorations and horizontal scroll.
        const text_node = node.text orelse return;
        const pad = layout_mod.resolveEdges(node.style.padding, null);
        const view_w = @max(node.rect.w - pad.l - pad.r, 0);
        const caret_x = stopX(slot.stops.items, slot.editor.caret);
        const total = if (slot.stops.items.len > 0) slot.stops.items[slot.stops.items.len - 1].x else 0;
        if (view_w > 0) {
            if (caret_x - slot.scroll_x > view_w - 1) slot.scroll_x = caret_x - view_w + 1;
            if (caret_x - slot.scroll_x < 0) slot.scroll_x = caret_x;
            slot.scroll_x = std.math.clamp(slot.scroll_x, 0, @max(total - view_w + 1, 0));
        }
        var decor: text_block.Decor = .{ .scroll_x = slot.scroll_x };
        if (is_focused) {
            if (slot.editor.hasSelection()) {
                decor.sel_on = true;
                decor.sel_x0 = stopX(slot.stops.items, sel.start);
                decor.sel_x1 = stopX(slot.stops.items, sel.end);
                decor.sel_color = colors.selection;
            } else if (slot.blink_on and !blk.props.read_only) {
                decor.caret_on = true;
                decor.caret_x = caret_x;
                decor.caret_color = colors.caret;
            }
        }
        if (!std.mem.eql(u8, std.mem.asBytes(&decor), std.mem.asBytes(&text_node.decor))) {
            text_node.decor = decor;
            self.tree.markDirty(blk.node, DirtyFlags.paint_only);
        }
    }

    /// x of the caret stop at byte offset `byte` (stops are sorted by byte).
    fn stopX(stops: []const Stop, byte: usize) f32 {
        for (stops) |st| if (st.byte >= byte) return st.x;
        return if (stops.len > 0) stops[stops.len - 1].x else 0;
    }

    /// Advance time-based state (caret blink). Returns true if something that
    /// affects painting changed; `update` then marks the field dirty.
    pub fn tick(self: *Ui, now_ms: u64) bool {
        self.now_ms = now_ms;
        var changed = false;
        var it = self.fields.iterator();
        while (it.next()) |e| {
            const slot = e.ptr;
            if (!slot.block.out.focused or !slot.block.props.enabled) continue;
            if (now_ms -% slot.blink_at >= blink_ms) {
                slot.blink_on = !slot.blink_on;
                slot.blink_at = now_ms;
                changed = true;
            }
        }
        var eit = self.editors.iterator();
        while (eit.next()) |e| changed = e.ptr.tick(now_ms) or changed;
        return changed;
    }

    /// Milliseconds until the next timed update (caret blink), or null if
    /// nothing needs one. Use as the event-wait timeout.
    pub fn nextWakeMs(self: *Ui) ?u32 {
        var best: ?u64 = null;
        var it = self.fields.iterator();
        while (it.next()) |e| {
            const slot = e.ptr;
            if (!slot.block.out.focused or !slot.block.props.enabled) continue;
            const elapsed = self.now_ms -% slot.blink_at;
            const left = if (elapsed >= blink_ms) 1 else blink_ms - elapsed;
            if (best == null or left < best.?) best = left;
        }
        var eit = self.editors.iterator();
        while (eit.next()) |e| {
            if (e.ptr.msUntilBlink(self.now_ms)) |left| {
                if (best == null or left < best.?) best = left;
            }
        }
        return if (best) |b| @intCast(b) else null;
    }

    /// Where the text caret is, in window coordinates, if a text field has
    /// focus. The platform uses this to enable text input and place IME popups;
    /// null means text input is not wanted.
    pub fn textInputRect(self: *Ui) ?geometry.Rect {
        const h = self.focused() orelse return null;
        var eit = self.editors.iterator();
        while (eit.next()) |e| {
            if (Handle.eql(e.ptr.block.node, h) and e.ptr.block.props.enabled) return e.ptr.caretRect();
        }
        var it = self.fields.iterator();
        while (it.next()) |e| {
            const slot = e.ptr;
            if (!Handle.eql(slot.block.node, h) or !slot.block.props.enabled) continue;
            const abs = self.tree.absoluteRect(h) orelse return null;
            const node = self.tree.get(h).?;
            const pad = layout_mod.resolveEdges(node.style.padding, null);
            const x = abs.x + pad.l + stopX(slot.stops.items, slot.editor.caret) - slot.scroll_x;
            return .{ .x = x, .y = abs.y, .w = 1, .h = abs.h };
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

    // ---- code editor -------------------------------------------------------------

    const editor_kinds = [_]event_types.EventKind{
        .focus_in, .focus_out, .pointer_enter, .pointer_leave,
        .pointer_down, .pointer_move, .pointer_up, .wheel, .key_down, .text_input,
    };

    /// Create a multi-line code editor. It fills the style's size; the `Ui` must
    /// not be moved afterwards (the widget keeps pointers into it).
    pub fn createCodeEditor(self: *Ui, parent: Handle, style: Style) !*CodeEditor {
        const node_h = try self.tree.create(.{
            .role = .text_field,
            .cursor = .text,
            .flags = .{ .focusable = true, .clip_children = true, .accepts_text = true },
            .style = style,
        });
        errdefer _ = self.tree.destroySubtree(node_h);
        try self.tree.appendChild(parent, node_h);

        var blk: CodeEditor = .{ .node = node_h };
        const slot_h = try self.editors.create(.{
            .gpa = self.gpa,
            .env = .{
                .tree = &self.tree,
                .text = &self.text,
                .theme = &self.theme,
                .clipboard = &self.clipboard,
                .now_ms = &self.now_ms,
            },
            .block = blk,
            .checker = shadow.Checker(CodeEditor.Props).init(&blk.props),
            .editor = EditorCore.init(self.gpa),
        });
        const slot = self.editors.get(slot_h).?;
        errdefer {
            slot.deinit();
            _ = self.editors.destroy(slot_h);
        }
        self.tree.get(node_h).?.paint_hook = .{ .ctx = slot, .run = code_editor.Slot.paintHook };
        for (editor_kinds) |kind| {
            try self.tree.addListener(node_h, .{ .kind = kind, .callback = code_editor.Slot.handleEvent, .user_data = slot });
        }
        return &slot.block;
    }

    fn editorSlot(ed: *CodeEditor) *code_editor.Slot {
        return @fieldParentPtr("block", ed);
    }

    /// The editor core (document, selections, history) behind a code editor.
    /// Edits made through it directly should be followed by `touchCodeEditor`.
    pub fn codeEditorCore(self: *Ui, ed: *CodeEditor) *EditorCore {
        _ = self;
        return &editorSlot(ed).editor;
    }

    /// Ask the widget to repaint (and keep the caret in view) after changing
    /// its core directly.
    pub fn touchCodeEditor(self: *Ui, ed: *CodeEditor) void {
        _ = self;
        const slot = editorSlot(ed);
        slot.repaint = true;
        slot.want_visible = true;
    }

    /// Replace the content with `bytes` as the opened file. If `owned`, the
    /// editor frees it (with the Ui's allocator); otherwise it must outlive the
    /// editor. History is cleared and the text counts as saved.
    pub fn loadCodeEditorText(self: *Ui, ed: *CodeEditor, bytes: []const u8, owned: bool) !void {
        const slot = editorSlot(ed);
        const fresh = try EditorCore.initWithText(self.gpa, bytes, owned);
        slot.editor.deinit();
        slot.editor = fresh;
        slot.scroll_x = 0;
        slot.scroll_y = 0;
        slot.last_version = 0;
        slot.repaint = true;
    }

    pub fn markCodeEditorSaved(self: *Ui, ed: *CodeEditor) void {
        _ = self;
        editorSlot(ed).editor.markSaved();
    }

    /// The whole text, allocated with `gpa`.
    pub fn codeEditorText(self: *Ui, ed: *CodeEditor, gpa: std.mem.Allocator) ![]u8 {
        _ = self;
        const core = &editorSlot(ed).editor;
        return core.doc.textAlloc(gpa, 0, core.doc.len());
    }

    // ---- fonts ------------------------------------------------------------

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
    fn syncText(self: *Ui, h: Handle, text: Text, f: u32, size: f32, color: Color, al: text_block.Align) void {
        self.syncTextEx(h, text, f, size, color, al, .{});
    }

    const SyncOpts = struct {
        /// Reshape even if the source slice looks unchanged (it was edited in place).
        force: bool = false,
        /// Keep a (glyph-less) block for empty text, so decorations have metrics.
        keep_empty: bool = false,
    };

    fn syncTextEx(self: *Ui, h: Handle, text: Text, f: u32, size: f32, color: Color, al: text_block.Align, opts: SyncOpts) void {
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

    pub fn setButtonEnabled(self: *Ui, b: *Button, enabled: bool) void {
        if (b.props.enabled == enabled) return;
        b.props.enabled = enabled;
        self.tree.markDirty(b.node, DirtyFlags.paint_only);
    }

    pub fn setButtonVariant(self: *Ui, b: *Button, variant: button.Variant) void {
        if (b.props.variant == variant) return;
        b.props.variant = variant;
        self.tree.markDirty(b.node, DirtyFlags.paint_only);
    }

    /// Show or hide a subtree. Hidden nodes take no space and are not painted or hit.
    pub fn setHidden(self: *Ui, h: Handle, hidden: bool) void {
        const node = self.tree.get(h) orelse return;
        if (node.flags.hidden == hidden) return;
        node.flags.hidden = hidden;
        self.tree.markDirty(h, DirtyFlags.layout_and_paint);
        self.tree.markDirty(node.parent, .{ .children = true });
    }

    // ---- input ------------------------------------------------------------

    pub fn pointerMove(self: *Ui, x: f32, y: f32) void {
        self.input.pointerMove(&self.tree, x, y);
    }

    pub fn pointerButton(self: *Ui, x: f32, y: f32, btn: u32, down: bool) void {
        self.input.pointerButton(&self.tree, x, y, btn, down);
    }

    /// Like `pointerButton`, with the platform's consecutive-press count
    /// (2 = double click) for text selection.
    pub fn pointerButtonEx(self: *Ui, x: f32, y: f32, btn: u32, down: bool, clicks: u32) void {
        if (down) self.shortcuts.clearPending();
        self.input.pointerButtonEx(&self.tree, x, y, btn, down, clicks);
    }

    pub fn wheel(self: *Ui, x: f32, y: f32, dx: f32, dy: f32) void {
        self.input.wheel(&self.tree, x, y, dx, dy);
    }

    /// Wheel scroll at the last known pointer position (positive `dy` = up).
    pub fn wheelAtPointer(self: *Ui, dx: f32, dy: f32) void {
        self.input.wheel(&self.tree, self.input.pointer_x, self.input.pointer_y, dx, dy);
    }

    /// Route a key press/release (`mods` are `keys.mod_*` bits). Order: the
    /// focused node (capture, target, bubble), then shortcuts, then Tab focus
    /// movement. Returns true if anything used the key.
    pub fn keyHandled(self: *Ui, k: keys.Key, mods: u32, down: bool, repeat: bool) bool {
        return self.input.keyEx(&self.tree, k, mods, down, repeat, 0, 0, .{ .ctx = self, .run = shortcutHook });
    }

    pub fn key(self: *Ui, k: keys.Key, mods: u32, down: bool, repeat: bool) void {
        _ = self.keyHandled(k, mods, down, repeat);
    }

    fn shortcutHook(ctx: *anyopaque, tree: *Tree, k: keys.Key, mods: u32, down: bool, repeat: bool) bool {
        const self: *Ui = @ptrCast(@alignCast(ctx));
        if (!down or k == .unknown) return false;
        const chord: keys.Chord = .{ .key = k, .mods = mods & keys.mod_all };
        // Plain typing belongs to the focused text widget, not to shortcuts.
        if (!self.shortcuts.hasPending() and chord.isTyping()) {
            if (tree.get(tree.focused)) |n| {
                if (n.flags.accepts_text) return false;
            }
        }
        return self.shortcuts.handleKey(tree, &self.commands, self.now_ms, chord, repeat).consumed;
    }

    // ---- commands and shortcuts -----------------------------------------------

    /// Register a named command. `handler` receives a `command` event whose
    /// text is the command name; it may be null for commands that only exist to
    /// be enabled/disabled or listed.
    pub fn registerCommand(self: *Ui, name: []const u8, title: []const u8, handler: ?event_types.Handler, user: ?*anyopaque) !Handle {
        return self.commands.register(name, title, handler, user);
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

    fn linkHandler(ev: *event_types.Event, user: ?*anyopaque) callconv(.c) void {
        _ = ev;
        const link: *CommandLink = @ptrCast(@alignCast(user.?));
        _ = link.ui.invokeCommand(link.name);
    }

    fn freeLink(self: *Ui, slot: *ButtonSlot) void {
        const link = slot.link orelse return;
        self.gpa.free(link.name);
        self.gpa.destroy(link);
        slot.link = null;
    }

    /// Make clicking the button run `command`. The button is enabled only while
    /// the command is (this overrides `props.enabled`), and the command need not
    /// exist yet. Pass the same command to keep a button, menu item, and
    /// shortcut in sync.
    pub fn setButtonCommand(self: *Ui, b: *Button, command: []const u8) !void {
        const slot: *ButtonSlot = @fieldParentPtr("block", b);
        const link = try self.gpa.create(CommandLink);
        errdefer self.gpa.destroy(link);
        link.* = .{ .ui = self, .name = try self.gpa.dupe(u8, command) };
        self.freeLink(slot);
        slot.link = link;
        b.props.on_click = linkHandler;
        b.props.on_click_user = link;
    }

    /// Deliver committed text (typing, paste, IME) to the focused widget.
    pub fn textInput(self: *Ui, text: []const u8) void {
        self.input.textInput(&self.tree, text);
    }

    pub fn setFocus(self: *Ui, h: ?Handle) void {
        self.input.setFocus(&self.tree, h);
    }

    /// The focused node, if any.
    pub fn focused(self: *Ui) ?Handle {
        return if (self.tree.isValid(self.tree.focused)) self.tree.focused else null;
    }

    // ---- frame ------------------------------------------------------------

    /// Reclaim blocks of destroyed buttons, check raw prop writes against the
    /// shadow copies (debug builds), and resolve each widget's look through
    /// the theme's painter.
    pub fn update(self: *Ui) void {
        self.sweep(&self.buttons);
        self.sweep(&self.labels);
        self.sweep(&self.fields);
        self.sweep(&self.editors);

        if (self.shortcuts.count() > 0) self.shortcuts.prune(&self.tree, &self.commands);

        // Buttons linked to a command mirror its enabled state.
        var lit0 = self.buttons.iterator();
        while (lit0.next()) |e| {
            const link = e.ptr.link orelse continue;
            const enabled = if (self.commands.find(link.name)) |h| self.commands.isEnabled(h) else false;
            self.setButtonEnabled(&e.ptr.block, enabled);
        }

        // Disabled buttons leave the tab order; losing focus fires events, so
        // settle focus before looks are resolved.
        var fit = self.buttons.iterator();
        while (fit.next()) |e| self.tree.get(e.ptr.block.node).?.flags.focusable = e.ptr.block.props.enabled;
        self.input.syncFocus(&self.tree);

        var it = self.buttons.iterator();
        while (it.next()) |e| {
            const b = &e.ptr.block;
            const node = self.tree.get(b.node).?;
            self.verifyProps(b.node, &e.ptr.checker, &b.props, "button");
            b.out.focus_visible = b.out.focused and self.input.keyboard;

            const look = self.theme.button_painter(b, &self.theme);
            if (!std.mem.eql(u8, std.mem.asBytes(&look), std.mem.asBytes(&node.visual))) {
                node.visual = look;
                self.tree.markDirty(b.node, DirtyFlags.paint_only);
            }
            const c = self.theme.button_colors[@min(@intFromEnum(b.props.variant), self.theme.button_colors.len - 1)];
            self.syncText(b.node, b.props.text, self.theme.ui_font, self.theme.font_size, if (b.props.enabled) c.text else c.text_disabled, b.props.text_align);
        }

        var fit2 = self.fields.iterator();
        while (fit2.next()) |e| self.updateField(e.ptr);

        var eit2 = self.editors.iterator();
        while (eit2.next()) |e| {
            self.verifyProps(e.ptr.block.node, &e.ptr.checker, &e.ptr.block.props, "code_editor");
            e.ptr.update();
        }

        var lit = self.labels.iterator();
        while (lit.next()) |e| {
            const l = &e.ptr.block;
            self.verifyProps(l.node, &e.ptr.checker, &l.props, "label");
            const f = switch (l.props.font) {
                .ui => self.theme.ui_font,
                .mono => self.theme.mono_font,
            };
            const size = if (l.props.size > 0) l.props.size else self.theme.font_size;
            const color = if (l.props.color.a != 0) l.props.color else self.theme.text_color;
            self.syncText(l.node, l.props.text, f, size, color, l.props.text_align);
            if (self.tree.get(l.node).?.text) |t| {
                l.out.text_width = t.width;
                l.out.text_height = t.line_height;
            }
        }
    }

    /// Free blocks whose node was destroyed. Restarts after each removal: the
    /// pool must not be mutated mid-iteration.
    fn sweep(self: *Ui, pool: anytype) void {
        while (true) {
            var stale: ?Handle = null;
            var it = pool.iterator();
            while (it.next()) |e| {
                if (!self.tree.isValid(e.ptr.block.node)) {
                    stale = e.handle;
                    break;
                }
            }
            const h = stale orelse return;
            self.releaseSlot(pool.get(h).?);
            _ = pool.destroy(h);
        }
    }

    fn releaseSlot(self: *Ui, slot: anytype) void {
        if (@TypeOf(slot) == *FieldSlot) {
            self.freeField(slot);
        } else if (@TypeOf(slot) == *code_editor.Slot) {
            slot.deinit();
        } else {
            self.freeText(&slot.block.props.text);
            if (@TypeOf(slot) == *ButtonSlot) self.freeLink(slot);
        }
    }

    /// Shadow-check raw prop writes; fold any missing dirty bits into the tree.
    fn verifyProps(self: *Ui, h: Handle, checker: anytype, props: anytype, name: []const u8) void {
        const node = self.tree.get(h).?;
        var flags = node.dirty;
        checker.verify(props, &flags, name);
        const added = DirtyFlags.fromBits(flags.bits() & ~node.dirty.bits());
        if (!added.isClean()) self.tree.markDirty(h, added);
    }

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
        self.text.atlas.beginFrame();
        try self.layout.run(&self.tree, size);
        try paint.build(&self.tree, list);
    }

    /// End of frame: clear frame-scoped flags and dirty bits.
    pub fn endFrame(self: *Ui) void {
        var it = self.buttons.iterator();
        while (it.next()) |e| e.ptr.block.out.clicked = false;
        var fit = self.fields.iterator();
        while (fit.next()) |e| {
            e.ptr.block.out.changed = false;
            e.ptr.block.out.submitted = false;
        }
        var eit = self.editors.iterator();
        while (eit.next()) |e| e.ptr.block.out.changed = false;
        self.tree.clearDirty(self.tree.root);
    }
};

// ---- tests -----------------------------------------------------------------

const Length = @import("length.zig").Length;
const Edges = @import("style.zig").Edges;
const draw_list = @import("draw_list.zig");

const Harness = struct {
    ui: Ui,
    cmds: [64]draw_list.Command = undefined,
    glyph_store: [256]draw_list.Glyph = undefined,
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

fn box(w: f32, h: f32) Style {
    return .{ .width = Length.px(w), .height = Length.px(h), .shrink = 0 };
}

test "a click sets flags, bumps the counter, and runs the callback" {
    const t = try Harness.init();
    defer t.deinit();
    const Count = struct {
        var n: u32 = 0;
        fn cb(_: *event_mod.Event, user: ?*anyopaque) callconv(.c) void {
            const p: *u32 = @ptrCast(@alignCast(user.?));
            p.* += 1;
        }
    };
    Count.n = 0;
    const b = try t.ui.createButton(t.ui.tree.root, box(80, 30));
    b.props.on_click = Count.cb;
    b.props.on_click_user = &Count.n;
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
    const a = try t.ui.createButton(t.ui.tree.root, box(80, 30));
    const b = try t.ui.createButton(t.ui.tree.root, box(80, 30));
    t.ui.setButtonEnabled(b, false);
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
    const b = try t.ui.createButton(t.ui.tree.root, box(80, 30));
    try t.frame();
    const node = t.ui.tree.get(b.node).?;
    const c = t.ui.theme.button_colors[0];
    try std.testing.expectEqual(c.normal, node.visual.background);
    try std.testing.expect(!t.ui.isDirty());

    t.ui.pointerMove(10, 10);
    t.ui.update();
    try std.testing.expectEqual(c.hover, node.visual.background);
    try std.testing.expect(t.ui.isDirty());
    try t.frame();

    t.ui.pointerButton(10, 10, 1, true);
    t.ui.update();
    try std.testing.expectEqual(c.pressed, node.visual.background);
    t.ui.pointerButton(10, 10, 1, false);
    t.ui.pointerMove(300, 90);
    try t.frame();
    try std.testing.expectEqual(c.normal, node.visual.background);
}

test "setButtonText copies, so the caller can free; and frees on deinit" {
    const t = try Harness.init();
    defer t.deinit(); // the testing allocator reports leaks
    const b = try t.ui.createButton(t.ui.tree.root, box(80, 30));
    var buf = [_]u8{ 'h', 'i' };
    try t.ui.setButtonText(b, &buf);
    buf[0] = 'X';
    try std.testing.expectEqualStrings("hi", b.props.text.slice());
    try t.ui.setButtonText(b, "longer text"); // replaces and frees the old copy
    try std.testing.expectEqualStrings("longer text", b.props.text.slice());
}

test "destroying a button's node reclaims its block" {
    const t = try Harness.init();
    defer t.deinit();
    const b = try t.ui.createButton(t.ui.tree.root, box(80, 30));
    try t.ui.setButtonText(b, "bye");
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
        fn cb(_: *event_mod.Event, user: ?*anyopaque) callconv(.c) void {
            const c: *@This() = @ptrCast(@alignCast(user.?));
            _ = c.ui.tree.destroySubtree(c.victim);
        }
    };
    const a = try t.ui.createButton(t.ui.tree.root, box(80, 30));
    const victim = try t.ui.createButton(t.ui.tree.root, box(80, 30));
    var ctx: Ctx = .{ .ui = &t.ui, .victim = victim.node };
    a.props.on_click = Ctx.cb;
    a.props.on_click_user = &ctx;
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
    const b = try t.ui.createButton(t.ui.tree.root, box(80, 30));
    try t.frame();
    try std.testing.expect(!t.ui.isDirty());

    b.props.variant = .primary; // raw write, no dirty marking
    t.ui.update(); // warns, self-corrects
    try std.testing.expect(t.ui.isDirty());
    try std.testing.expectEqual(t.ui.theme.button_colors[1].normal, t.ui.tree.get(b.node).?.visual.background);
}

test "variant setter marks paint and swaps colors" {
    const t = try Harness.init();
    defer t.deinit();
    const b = try t.ui.createButton(t.ui.tree.root, box(80, 30));
    try t.frame();
    t.ui.setButtonVariant(b, .danger);
    try std.testing.expect(t.ui.isDirty());
    try t.frame();
    try std.testing.expectEqual(t.ui.theme.button_colors[2].normal, t.ui.tree.get(b.node).?.visual.background);
}

const event_mod = @import("event.zig");

test "buttons paint into the draw list" {
    const t = try Harness.init();
    defer t.deinit();
    _ = try t.ui.createButton(t.ui.tree.root, box(80, 30));
    try t.frame();
    try std.testing.expect(t.list.items().len >= 1);
    try std.testing.expectEqual(Color.rgb(0x4a, 0x4d, 0x52), t.list.items()[0].paint.color);
}

test "setHidden relays out the parent" {
    const t = try Harness.init();
    defer t.deinit();
    const a = try t.ui.createButton(t.ui.tree.root, box(80, 30));
    const b = try t.ui.createButton(t.ui.tree.root, box(80, 30));
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
    const l = try t.h.ui.createLabel(t.h.ui.tree.root, .{}, "Mi");
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
    const l = try ui.createLabel(ui.tree.root, .{}, "ab");
    try t.h.frame();
    const w1 = l.out.text_width;

    var buf = [_]u8{ 'a', 'b', 'c' };
    try ui.setLabelText(l, &buf);
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
    const b = try ui.createButton(ui.tree.root, .{ .padding = Edges.xy(10, 5) });
    try ui.setButtonText(b, "MM"); // 2 * 0.9 * 20 = 36 wide
    try t.h.frame();

    const node = ui.tree.get(b.node).?;
    try std.testing.expectApproxEqAbs(@as(f32, 56), node.rect.w, 0.01); // 36 + 2 * 10
    try std.testing.expectApproxEqAbs(@as(f32, 32), node.rect.h, 0.01); // 22 + 2 * 5

    var found = false;
    for (t.h.list.items()) |cmd| {
        if (cmd.kind != .glyph_run) continue;
        found = true;
        try std.testing.expectEqual(@as(u32, 2), cmd.b);
        const g = t.h.list.glyphItems()[cmd.a];
        try std.testing.expectApproxEqAbs(@as(f32, 10), g.x, 0.01); // content-box left
        // Baseline: padding 5 + half the 2px line gap + ascent 16.
        try std.testing.expectApproxEqAbs(@as(f32, 22), g.y, 0.01);
        try std.testing.expectEqual(ui.theme.button_colors[0].text, cmd.paint.color);
    }
    try std.testing.expect(found);
}

test "disabled buttons use the disabled text color" {
    const t = try TextHarness.init();
    defer t.deinit();
    const ui = &t.h.ui;
    const b = try ui.createButton(ui.tree.root, .{ .padding = Edges.all(4) });
    try ui.setButtonText(b, "x");
    ui.setButtonEnabled(b, false);
    try t.h.frame();
    try std.testing.expectEqual(ui.theme.button_colors[0].text_disabled, ui.tree.get(b.node).?.text.?.color);
}

test "destroying a node frees its text, and text outlives nothing" {
    const t = try TextHarness.init();
    defer t.deinit(); // leak-checked
    const ui = &t.h.ui;
    const l = try ui.createLabel(ui.tree.root, .{}, "temporary");
    const b = try ui.createButton(ui.tree.root, .{});
    try ui.setButtonText(b, "also temporary");
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
    const l = try ui.createLabel(ui.tree.root, .{}, "MMM");
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
        fn cb(_: *event_mod.Event, _: ?*anyopaque) callconv(.c) void {
            n += 1;
        }
    };
    Count.n = 0;
    const a = try ui.createButton(ui.tree.root, box(80, 30));
    const b = try ui.createButton(ui.tree.root, box(80, 30));
    b.props.on_click = Count.cb;
    try t.frame();

    ui.key(.tab, 0, true, false);
    ui.key(.tab, 0, true, false);
    try t.frame();
    try std.testing.expect(!a.out.focused);
    try std.testing.expect(b.out.focused and b.out.focus_visible);
    try std.testing.expectEqual(ui.theme.focus_ring, ui.tree.get(b.node).?.visual.border_color);

    ui.key(.enter, 0, true, false);
    ui.key(.space, 0, true, false);
    ui.key(.space, 0, true, true); // auto-repeat does not re-activate
    try std.testing.expectEqual(@as(u32, 2), b.out.click_count);
    try std.testing.expectEqual(@as(u32, 2), Count.n);
    try std.testing.expect(b.out.clicked);

    // Clicking focuses without drawing the ring.
    t.click(10, 10);
    try t.frame();
    try std.testing.expect(a.out.focused and !b.out.focused);
    try std.testing.expect(!a.out.focus_visible);
    try std.testing.expect(ui.tree.get(a.node).?.visual.border_width == 0);
    try std.testing.expect(Handle.eql(ui.focused().?, a.node));
}

test "disabled buttons are skipped by Tab and cannot be activated by key" {
    const t = try Harness.init();
    defer t.deinit();
    const ui = &t.ui;
    const a = try ui.createButton(ui.tree.root, box(80, 30));
    const dis = try ui.createButton(ui.tree.root, box(80, 30));
    const c = try ui.createButton(ui.tree.root, box(80, 30));
    ui.setButtonEnabled(dis, false);
    try t.frame();

    ui.key(.tab, 0, true, false);
    try t.frame();
    try std.testing.expect(a.out.focused);
    ui.key(.tab, 0, true, false);
    try t.frame();
    try std.testing.expect(c.out.focused and !dis.out.focused);

    // Disabling the focused button drops its focus.
    ui.setButtonEnabled(c, false);
    try t.frame();
    try std.testing.expect(!c.out.focused);
    try std.testing.expect(ui.focused() == null);
}

test "removing the focused button falls back and never leaves a stale focus" {
    const t = try Harness.init();
    defer t.deinit();
    const ui = &t.ui;
    const a = try ui.createButton(ui.tree.root, box(80, 30));
    try t.frame();
    ui.key(.tab, 0, true, false);
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
    fn onChange(_: *event_mod.Event, _: ?*anyopaque) callconv(.c) void {
        changes += 1;
    }
    fn onSubmit(_: *event_mod.Event, _: ?*anyopaque) callconv(.c) void {
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
    const tf = try ui.createTextField(ui.tree.root, .{ .width = Length.px(200), .height = Length.px(28), .padding = Edges.xy(6, 0) });
    tf.props.on_change = FieldCounts.onChange;
    tf.props.on_submit = FieldCounts.onSubmit;
    try t.h.frame();
    ui.setFocus(tf.node);
    try t.h.frame();
    return tf;
}

fn type_(t: *TextHarness, text: []const u8) !void {
    t.h.ui.textInput(text);
    try t.h.frame();
}

fn press(t: *TextHarness, k: keys.Key, mods: u32) !void {
    t.h.ui.key(k, mods, true, false);
    try t.h.frame();
}

test "typing edits the field, sets flags, and calls on_change" {
    const t = try TextHarness.init();
    defer t.deinit();
    const ui = &t.h.ui;
    const tf = try focusedField(t);

    try type_(t, "hello");
    try std.testing.expectEqualStrings("hello", ui.textFieldText(tf));
    try std.testing.expect(tf.out.focused);
    try std.testing.expectEqual(@as(u32, 1), tf.out.change_count);
    try std.testing.expectEqual(@as(u32, 1), FieldCounts.changes);
    try std.testing.expectEqual(@as(u32, 5), tf.out.caret);
    try std.testing.expect(!tf.out.changed); // frame-scoped: cleared by endFrame in frame()

    try type_(t, " \u{e9}");
    try std.testing.expectEqualStrings("hello \u{e9}", ui.textFieldText(tf));
    try press(t, .backspace, 0); // removes the whole two-byte character
    try std.testing.expectEqualStrings("hello ", ui.textFieldText(tf));
    try std.testing.expectEqual(@as(u32, 3), tf.out.change_count);
}

test "navigation, selection, and replacement" {
    const t = try TextHarness.init();
    defer t.deinit();
    const ui = &t.h.ui;
    const tf = try focusedField(t);
    try type_(t, "one two three");

    try press(t, .home, 0);
    try press(t, .right, keys.mod_ctrl); // word right: past "one "
    try std.testing.expectEqual(@as(u32, 4), tf.out.caret);
    try press(t, .right, keys.mod_ctrl | keys.mod_shift);
    try std.testing.expectEqual(@as(u32, 4), tf.out.sel_start);
    try std.testing.expectEqual(@as(u32, 8), tf.out.sel_end);
    try type_(t, "2");
    try std.testing.expectEqualStrings("one 2three", ui.textFieldText(tf));
    try press(t, .end, 0);
    try press(t, .backspace, keys.mod_ctrl); // "2three" is one word
    try std.testing.expectEqualStrings("one ", ui.textFieldText(tf));
    try press(t, .left, 0);
    try press(t, .delete, 0);
    try std.testing.expectEqualStrings("one", ui.textFieldText(tf));
}

test "clipboard: select all, copy, cut, paste (newlines become spaces)" {
    const t = try TextHarness.init();
    defer t.deinit();
    const ui = &t.h.ui;
    const tf = try focusedField(t);
    try type_(t, "abc");

    try press(t, .a, keys.mod_ctrl);
    try std.testing.expectEqual(@as(u32, 0), tf.out.sel_start);
    try std.testing.expectEqual(@as(u32, 3), tf.out.sel_end);
    try press(t, .c, keys.mod_ctrl);
    try std.testing.expectEqualStrings("abc", FakeClip.contents());
    try std.testing.expectEqualStrings("abc", ui.textFieldText(tf));

    try press(t, .x, keys.mod_ctrl);
    try std.testing.expectEqualStrings("", ui.textFieldText(tf));
    FakeClip.put("x\ny\r\nz");
    try press(t, .v, keys.mod_ctrl);
    try std.testing.expectEqualStrings("x y  z", ui.textFieldText(tf));

    // A plain 'a' (no modifier) is not consumed: text arrives via text_input only.
    ui.key(.a, 0, true, false);
    try std.testing.expectEqualStrings("x y  z", ui.textFieldText(tf));
}

test "enter submits; submit flags are frame-scoped" {
    const t = try TextHarness.init();
    defer t.deinit();
    const tf = try focusedField(t);
    t.h.ui.key(.enter, 0, true, false);
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
    try press(t, .backspace, 0);
    try press(t, .a, keys.mod_ctrl);
    try press(t, .c, keys.mod_ctrl);
    try press(t, .x, keys.mod_ctrl);
    try std.testing.expectEqualStrings("keep", ui.textFieldText(tf));
    try std.testing.expectEqualStrings("keep", FakeClip.contents());

    tf.props.read_only = false;
    tf.props.enabled = false;
    try t.h.frame();
    try type_(t, "x");
    try std.testing.expectEqualStrings("keep", ui.textFieldText(tf));
    try std.testing.expect(ui.focused() == null); // disabled fields leave the tab order and lose focus
}

test "text only reaches the focused field" {
    const t = try TextHarness.init();
    defer t.deinit();
    const ui = &t.h.ui;
    const a = try focusedField(t);
    const b = try ui.createTextField(ui.tree.root, .{ .width = Length.px(100), .height = Length.px(28) });
    try t.h.frame();
    try type_(t, "to a");
    try std.testing.expectEqualStrings("to a", ui.textFieldText(a));
    try std.testing.expectEqualStrings("", ui.textFieldText(b));
    try press(t, .tab, 0);
    try type_(t, "to b");
    try std.testing.expectEqualStrings("to b", ui.textFieldText(b));
    try std.testing.expectEqualStrings("to a", ui.textFieldText(a));
}

test "setTextFieldText replaces content without counting as an edit" {
    const t = try TextHarness.init();
    defer t.deinit();
    const ui = &t.h.ui;
    const tf = try focusedField(t);
    try ui.setTextFieldText(tf, "preset");
    try t.h.frame();
    try std.testing.expectEqualStrings("preset", ui.textFieldText(tf));
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
    _ = try ui.setTextFieldText(tf, "ab");
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
        if (c.kind == .fill_rect and c.rect.w == 1 and std.meta.eql(c.paint.color, ui.theme.field.caret)) carets += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), carets);

    try press(t, .a, keys.mod_ctrl);
    var highlight: ?draw_list.Command = null;
    for (t.h.list.items()) |c| {
        if (c.kind == .fill_rect and std.meta.eql(c.paint.color, ui.theme.field.selection)) highlight = c;
    }
    try std.testing.expect(highlight != null);
    try std.testing.expectApproxEqAbs(@as(f32, 44), highlight.?.rect.w, 0.01); // four letters
    try std.testing.expectApproxEqAbs(@as(f32, 6), highlight.?.rect.x, 0.01);
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
    try press(t, .home, 0);
    try std.testing.expectEqual(@as(f32, 0), ui.tree.get(tf.node).?.text.?.decor.scroll_x);
}

test "an empty field shows its placeholder, dimmed, and hides it once there is text" {
    const t = try TextHarness.init();
    defer t.deinit();
    const ui = &t.h.ui;
    const tf = try focusedField(t);
    try ui.setTextFieldPlaceholder(tf, "Search");
    try t.h.frame();
    const node = ui.tree.get(tf.node).?;
    try std.testing.expectEqual(@as(usize, 6), node.text.?.glyphs.len);
    try std.testing.expectEqual(ui.theme.field.placeholder, node.text.?.color);

    try type_(t, "hi");
    try std.testing.expectEqual(@as(usize, 2), ui.tree.get(tf.node).?.text.?.glyphs.len);
    try std.testing.expectEqual(ui.theme.field.text, ui.tree.get(tf.node).?.text.?.color);
}

test "focused fields get a highlighted border; the I-beam cursor and IME rect are reported" {
    const t = try TextHarness.init();
    defer t.deinit();
    const ui = &t.h.ui;
    const tf = try focusedField(t);
    try type_(t, "ab");
    try std.testing.expectEqual(ui.theme.field.border_focus, ui.tree.get(tf.node).?.visual.border_color);

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
    try ui.setTextFieldPlaceholder(tf, "placeholder");
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
    fn handler(ev: *event_mod.Event, _: ?*anyopaque) callconv(.c) void {
        const name = ev.textSlice();
        if (len < buf.len) {
            buf[len] = name[name.len - 1];
            len += 1;
        }
        last_target = ev.target;
    }
};

fn regCmd(ui: *Ui, name: []const u8) !void {
    _ = try ui.registerCommand(name, name, CmdLog.handler, null);
}

test "a bound shortcut runs its command with the focused node as target" {
    const t = try Harness.init();
    defer t.deinit();
    const ui = &t.ui;
    CmdLog.reset();
    try regCmd(ui, "file.s");
    try ui.bindShortcut("ctrl+s", "file.s", .app, null);
    const b = try ui.createButton(ui.tree.root, box(80, 30));
    try t.frame();

    try std.testing.expect(ui.keyHandled(.s, keys.mod_ctrl, true, false));
    try std.testing.expectEqualStrings("s", CmdLog.str());
    try std.testing.expect(Handle.eql(CmdLog.last_target, ui.tree.root)); // nothing focused
    ui.setFocus(b.node);
    _ = ui.keyHandled(.s, keys.mod_ctrl, true, false);
    try std.testing.expect(Handle.eql(CmdLog.last_target, b.node));
    try std.testing.expect(!ui.keyHandled(.x, keys.mod_ctrl, true, false)); // unbound
    try std.testing.expect(!ui.keyHandled(.s, keys.mod_ctrl, false, false)); // key-up never triggers
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
    const b = try ui.createButton(ui.tree.root, box(80, 30));
    try t.frame();

    // Nothing focused: the shortcut fires.
    _ = ui.keyHandled(.enter, 0, true, false);
    try std.testing.expectEqualStrings("e", CmdLog.str());
    // A focused button claims Enter for itself.
    ui.setFocus(b.node);
    _ = ui.keyHandled(.enter, 0, true, false);
    try std.testing.expectEqualStrings("e", CmdLog.str());
    try std.testing.expectEqual(@as(u32, 1), b.out.click_count);
}

test "a Tab shortcut beats focus movement; unbound Tab still moves focus" {
    const t = try Harness.init();
    defer t.deinit();
    const ui = &t.ui;
    CmdLog.reset();
    try regCmd(ui, "x.t");
    const b = try ui.createButton(ui.tree.root, box(80, 30));
    try t.frame();
    _ = ui.keyHandled(.tab, 0, true, false);
    try std.testing.expect(Handle.eql(ui.focused().?, b.node));
    ui.setFocus(null);

    try ui.bindShortcut("tab", "x.t", .app, null);
    _ = ui.keyHandled(.tab, 0, true, false);
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

    _ = ui.keyHandled(.a, 0, true, false);
    ui.textInput("a");
    try t.h.frame();
    try std.testing.expectEqualStrings("a", ui.textFieldText(tf));
    try std.testing.expectEqualStrings("", CmdLog.str()); // the shortcut did not fire

    _ = ui.keyHandled(.a, keys.mod_ctrl, true, false); // the field takes select-all
    try std.testing.expectEqual(@as(u32, 1), tf.out.sel_end);
    try std.testing.expectEqualStrings("", CmdLog.str());
    _ = ui.keyHandled(.s, keys.mod_ctrl, true, false); // not claimed by the field
    try std.testing.expectEqualStrings("s", CmdLog.str());

    // Leave the field and the bare shortcut works again.
    ui.setFocus(null);
    _ = ui.keyHandled(.a, 0, true, false);
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
    const inside = try ui.createButton(panel, box(80, 30));
    const outside = try ui.createButton(ui.tree.root, box(80, 30));
    try ui.bindShortcut("f2", "x.g", .app, null);
    try ui.bindShortcut("f2", "x.p", .panel, panel);
    try ui.bindShortcut("f2", "x.w", .widget, inside.node);
    try t.frame();

    ui.setFocus(inside.node);
    _ = ui.keyHandled(.f2, 0, true, false); // widget
    ui.setFocus(outside.node);
    _ = ui.keyHandled(.f2, 0, true, false); // outside the panel: global
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
    try std.testing.expect(ui.keyHandled(.k, keys.mod_ctrl, true, false));
    try std.testing.expect(ui.shortcuts.hasPending());
    try std.testing.expect(ui.keyHandled(.c, keys.mod_ctrl, true, false));
    try std.testing.expectEqualStrings("c", CmdLog.str());

    _ = ui.keyHandled(.k, keys.mod_ctrl, true, false);
    ui.pointerButtonEx(300, 90, 1, true, 1);
    try std.testing.expect(!ui.shortcuts.hasPending());
    try std.testing.expect(!ui.keyHandled(.c, keys.mod_ctrl, true, false));
    try std.testing.expectEqualStrings("c", CmdLog.str());

    // The timeout uses the time given to tick.
    _ = ui.tick(1000);
    _ = ui.keyHandled(.k, keys.mod_ctrl, true, false);
    _ = ui.tick(1000 + 2000);
    try std.testing.expect(!ui.keyHandled(.c, keys.mod_ctrl, true, false));
}

test "a command-linked button runs the command, mirrors its enabled state, and frees its link" {
    const t = try Harness.init();
    defer t.deinit(); // leak-checked
    const ui = &t.ui;
    CmdLog.reset();
    const b = try ui.createButton(ui.tree.root, box(80, 30));
    try ui.setButtonCommand(b, "view.v"); // the command does not exist yet
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

    try ui.setButtonCommand(b, "view.v"); // re-linking replaces the old link
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
    _ = ui.keyHandled(.s, keys.mod_ctrl, true, false);
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
    _ = ui.keyHandled(.down, 0, true, false);
    _ = ui.keyHandled(.down, 0, true, true);
    _ = ui.keyHandled(.s, keys.mod_ctrl, true, false);
    _ = ui.keyHandled(.s, keys.mod_ctrl, true, true);
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
    const ed = try ui.createCodeEditor(ui.tree.root, .{ .width = Length.px(300), .height = Length.px(100) });
    ed.props.on_change = FieldCounts.onChange;
    try t.h.frame();
    ui.setFocus(ed.node);
    try t.h.frame();
    return ed;
}

fn edText(ui: *Ui, ed: *CodeEditor) ![]u8 {
    return ui.codeEditorText(ed, testing_alloc);
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
    try press(t, .enter, 0);
    try type_(t, "x");
    try expectEdText(ui, ed, "hi\nx");
    try std.testing.expectEqual(@as(u32, 2), ed.out.line_count);
    try std.testing.expectEqual(@as(u32, 1), ed.out.caret_line);
    try std.testing.expectEqual(@as(u32, 1), ed.out.caret_column);
    try std.testing.expect(ed.out.modified);
    try std.testing.expectEqual(@as(u32, 3), FieldCounts.changes);

    try press(t, .backspace, 0);
    try press(t, .backspace, 0);
    try expectEdText(ui, ed, "hi");
    try press(t, .z, keys.mod_ctrl); // undo the backspaces
    try expectEdText(ui, ed, "hi\nx");
    try press(t, .z, keys.mod_ctrl | keys.mod_shift); // redo
    try expectEdText(ui, ed, "hi");
    try press(t, .y, keys.mod_ctrl); // nothing left to redo
    try expectEdText(ui, ed, "hi");
    ui.markCodeEditorSaved(ed);
    try t.h.frame();
    try std.testing.expect(!ed.out.modified);
}

test "clicking places the caret, dragging selects, double and triple click select a word and a line" {
    const t = try TextHarness.init();
    defer t.deinit();
    const ui = &t.h.ui;
    const ed = try editorBox(t);
    try ui.loadCodeEditorText(ed, "alpha beta\ngamma\ndelta", false);
    try t.h.frame();
    const core = ui.codeEditorCore(ed);

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
    try ui.loadCodeEditorText(ed, "one\ntwo", false);
    try t.h.frame();

    ui.pointerMove(gutter_px, 5);
    ui.pointerButtonEx(gutter_px, 5, 1, true, 1);
    ui.pointerButtonEx(gutter_px, 5, 1, false, 1);
    ui.key(.unknown, keys.mod_alt, true, false); // Alt is held
    ui.pointerMove(gutter_px, line_px + 5);
    ui.pointerButtonEx(gutter_px, line_px + 5, 1, true, 1);
    ui.pointerButtonEx(gutter_px, line_px + 5, 1, false, 1);
    ui.key(.unknown, 0, false, false);
    try t.h.frame();
    try std.testing.expectEqual(@as(u32, 2), ed.out.selection_count);
    try type_(t, ">");
    try expectEdText(ui, ed, ">one\n>two");

    try press(t, .escape, 0); // drop the extra cursor
    try std.testing.expectEqual(@as(u32, 1), ed.out.selection_count);
    try std.testing.expect(!ui.keyHandled(.escape, 0, true, false)); // nothing left to cancel: the key passes through

    try press(t, .up, keys.mod_ctrl | keys.mod_alt); // no line above the first: no-op
    try press(t, .down, keys.mod_ctrl | keys.mod_alt);
    try std.testing.expectEqual(@as(u32, 2), ed.out.selection_count);
}

test "the caret scrolls into view, page keys move by a screenful, and the wheel scrolls" {
    const t = try TextHarness.init();
    defer t.deinit();
    const ui = &t.h.ui;
    const ed = try editorBox(t);
    const text = try manyLines(100);
    try ui.loadCodeEditorText(ed, text, true);
    try t.h.frame();
    const slot = Ui.editorSlot(ed);
    try std.testing.expectEqual(@as(f32, 0), slot.scroll_y);

    try press(t, .end, keys.mod_ctrl); // end of the document
    try std.testing.expectEqual(@as(u32, 100), ed.out.caret_line);
    const max_scroll = 101 * line_px - 100;
    try std.testing.expectApproxEqAbs(max_scroll, slot.scroll_y, 0.01);

    try press(t, .home, keys.mod_ctrl);
    try std.testing.expectEqual(@as(f32, 0), slot.scroll_y);
    try press(t, .page_down, 0); // view is 100px = 4 lines: moves 3
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
    const ui = &t.h.ui;
    t.h.list = DrawList.init(&t.h.cmds, &t.h.glyph_store);
    const ed = try editorBox(t);
    const text = try manyLines(20000);
    try ui.loadCodeEditorText(ed, text, true);
    try t.h.frame();

    var runs: usize = 0;
    for (t.h.list.items()) |c| runs += @intFromBool(c.kind == .glyph_run);
    // ~7 rows visible, each with a text run and a gutter number.
    try std.testing.expect(runs > 0 and runs <= 2 * 8);
    try std.testing.expect(t.h.list.isBalanced());
}

test "selections, the current line, and carets are drawn; the caret blinks" {
    const t = try TextHarness.init();
    defer t.deinit();
    const ui = &t.h.ui;
    const ed = try editorBox(t);
    try ui.loadCodeEditorText(ed, "abcdef\nsecond", false);
    try t.h.frame();
    const colors = ui.theme.editor;

    const Counts = struct {
        fn of(list: *const DrawList, color: geometry.Color) usize {
            var n: usize = 0;
            for (list.items()) |c| {
                if (c.kind == .fill_rect and std.meta.eql(c.paint.color, color)) n += 1;
            }
            return n;
        }
    };
    try std.testing.expectEqual(@as(usize, 1), Counts.of(&t.h.list, colors.caret));
    try std.testing.expectEqual(@as(usize, 1), Counts.of(&t.h.list, colors.current_line));

    _ = ui.tick(2000); // blink off
    try t.h.frame();
    try std.testing.expectEqual(@as(usize, 0), Counts.of(&t.h.list, colors.caret));

    try press(t, .right, keys.mod_shift);
    try press(t, .right, keys.mod_shift);
    try press(t, .down, keys.mod_shift);
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
    try ui.loadCodeEditorText(ed, "\tx\n  \ty", false);
    try t.h.frame();
    try press(t, .end, 0); // end of line 0: after a tab (4 cells) and "x"
    const r = ui.textInputRect().?;
    try std.testing.expectApproxEqAbs(gutter_px + 5 * cell_px, r.x, 0.01);
    try press(t, .down, 0);
    try press(t, .end, 0); // "  \ty": two spaces, a tab to column 4, then "y"
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
    try ui.loadCodeEditorText(ed, "keep this", false);
    ed.props.read_only = true;
    try t.h.frame();

    try type_(t, "x");
    try press(t, .backspace, 0);
    try std.testing.expect(!ui.keyHandled(.enter, 0, true, false)); // not claimed: passes on
    try press(t, .a, keys.mod_ctrl);
    try press(t, .c, keys.mod_ctrl);
    try press(t, .x, keys.mod_ctrl);
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
    try ui.loadCodeEditorText(ed, "one two", false);
    try t.h.frame();
    try press(t, .a, keys.mod_ctrl);
    try press(t, .x, keys.mod_ctrl);
    try expectEdText(ui, ed, "");
    try std.testing.expectEqualStrings("one two", FakeClip.contents());
    try press(t, .v, keys.mod_ctrl);
    try press(t, .v, keys.mod_ctrl);
    try expectEdText(ui, ed, "one twoone two");
    try press(t, .tab, 0);
    try std.testing.expectEqual(@as(u32, 16), ed.out.caret_column); // padded to the next multiple of 4
    try press(t, .tab, keys.mod_shift); // outdent has nothing to remove at a non-indented line start... caret stays
    try std.testing.expect(ui.focused() != null); // Tab was consumed, focus did not move
}

test "removing an editor frees its document, history, and scratch" {
    const t = try TextHarness.init();
    defer t.deinit(); // leak-checked
    const ui = &t.h.ui;
    const ed = try editorBox(t);
    const text = try manyLines(500);
    try ui.loadCodeEditorText(ed, text, true);
    try type_(t, "typed text");
    try press(t, .enter, 0);
    try press(t, .z, keys.mod_ctrl);
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
    try ui.loadCodeEditorText(ed, text, true);
    try t.h.frame();
    const core = ui.codeEditorCore(ed);

    // Insert lines above, then click on what is now line 7 (0-based 6).
    try press(t, .home, keys.mod_ctrl);
    try press(t, .enter, 0);
    try press(t, .enter, 0);
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
