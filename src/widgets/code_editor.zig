//! CodeEditor: a multi-line text editor widget over the editor core.
//!
//! The state block (`props` / `out`) is the app-facing part. The `Slot`
//! (internal) holds the `Editor` core, scroll state, and scratch buffers, and
//! implements event handling, per-frame sync, and painting.
//!
//! Painting is virtualized: only the lines in view are built and drawn, so a
//! huge document costs the same as a small one. Each visible line is expanded
//! (tabs to spaces), shaped through the text system, and drawn together with
//! its selection rectangles and carets. A gutter shows line numbers and a thin
//! scrollbar thumb shows position.
//!
//! Input: typing, Enter (keeps indentation), Tab / Shift+Tab, Backspace/Delete
//! (Ctrl or Alt for words), arrows, Home/End (Ctrl for document), PageUp/Down,
//! Shift to select, Ctrl+A/C/X/V, Ctrl+Z / Ctrl+Y / Ctrl+Shift+Z, mouse click and
//! drag, double-click for a word, triple-click for a line, Alt+click or
//! Ctrl+Alt+Up/Down for more cursors, Esc to drop extra cursors/selection, wheel
//! to scroll. Not yet: syntax highlighting, find, soft wrap, code folding,
//! IME preedit, bracket matching.

const std = @import("std");
const Handle = @import("../core/handle.zig").Handle;
const event = @import("../core/event.zig");
const keys = @import("../core/keys.zig");
const shadow = @import("../core/shadow.zig");
const tree_mod = @import("../core/tree.zig");
const Tree = tree_mod.Tree;
const DirtyFlags = @import("../core/dirty.zig").DirtyFlags;
const geometry = @import("../core/geometry.zig");
const Rect = geometry.Rect;
const draw_list = @import("../core/draw_list.zig");
const DrawList = draw_list.DrawList;
const Paint = draw_list.Paint;
const Clipboard = @import("../core/clipboard.zig").Clipboard;
const layout_mod = @import("../core/layout.zig");
const text_sys = @import("../text/system.zig");
const TextSystem = text_sys.TextSystem;
const Stop = text_sys.Stop;
const Glyph = text_sys.Glyph;
const Theme = @import("theme.zig").Theme;
const Ui = @import("../core/ui.zig").Ui;
const paint_ctx = @import("../core/paint_ctx.zig");
const PaintCtx = paint_ctx.PaintCtx;
const EditorColors = @import("theme.zig").EditorColors;
const Style = @import("../core/style.zig").Style;
const Node = @import("../core/tree.zig").Node;
const label = @import("label.zig");
const Editor = @import("../editor/editor.zig").Editor;
const Selection = @import("../editor/selection.zig").Selection;
const syntax = @import("../editor/syntax.zig");
const Highlighter = @import("../editor/highlighter.zig").Highlighter;

pub const Font = label.Font;

/// Draws the editor: the default fills the background, then calls
/// `paintContent` for the gutter, text, selections, carets, and scrollbar.
pub const Painter = *const fn (ctx: *PaintCtx, ed: *CodeEditor) paint_ctx.Error!void;

const blink_ms: u64 = 530;
const gutter_pad: f32 = 8;

pub const CodeEditor = struct {
    props: Props = .{},
    out: Out = .{},
    node: Handle,
    ui: *Ui,

    // Internal state (not part of the app-facing API).
    checker: shadow.Checker(Props),
    editor: Editor,

    scroll_y: f32 = 0,
    scroll_x: f32 = 0,
    dragging: bool = false,
    blink_on: bool = true,
    blink_at: u64 = 0,
    /// Set by input handling: repaint, and scroll the caret into view.
    repaint: bool = true,
    want_visible: bool = false,
    last_version: u64 = 0,

    // Scratch for building one line at a time.
    display: std.ArrayListUnmanaged(u8) = .empty,
    map: std.ArrayListUnmanaged(u32) = .empty,
    stops: std.ArrayListUnmanaged(Stop) = .empty,
    glyphs: std.ArrayListUnmanaged(Glyph) = .empty,
    spans: std.ArrayListUnmanaged(syntax.Span) = .empty,
    number_buf: [24]u8 = undefined,

    /// Syntax highlighting, if a language is set.
    highlighter: ?Highlighter = null,

    pub fn deinit(self: *CodeEditor) void {
        if (self.highlighter) |*h| h.deinit();
        self.spans.deinit(self.ui.gpa);
        self.editor.deinit();
        self.display.deinit(self.ui.gpa);
        self.map.deinit(self.ui.gpa);
        self.stops.deinit(self.ui.gpa);
        self.glyphs.deinit(self.ui.gpa);
    }

    /// Choose the syntax highlighting language (null for none).
    pub fn setLanguage(self: *CodeEditor, lang: ?*const syntax.Language) !void {
        if (lang) |l| {
            if (self.highlighter) |*h| {
                h.setLanguage(l);
            } else {
                var h = Highlighter.init(self.ui.gpa, l);
                errdefer h.deinit();
                try h.reset(self.editor.doc.lineCount());
                self.highlighter = h;
            }
        } else if (self.highlighter) |*h| {
            h.deinit();
            self.highlighter = null;
        }
        self.repaint = true;
    }

    /// Call after the editor core was replaced.
    pub fn resetHighlighting(self: *CodeEditor) void {
        if (self.highlighter) |*h| h.reset(self.editor.doc.lineCount()) catch {};
    }

    pub fn init(ui: *Ui, node: Handle) CodeEditor {
        const props: Props = .{};
        return .{
            .node = node,
            .ui = ui,
            .checker = shadow.Checker(Props).init(&props),
            .editor = Editor.init(ui.gpa),
        };
    }

    pub const Options = struct {
        style: Style = .{},
        /// Initial text, borrowed: it must outlive the editor (use `loadText`
        /// with `owned = true` to hand over an allocation instead).
        text: []const u8 = "",
        language: ?*const syntax.Language = null,
        font: Font = .mono,
        size: f32 = 0,
        tab_width: u32 = 4,
        enabled: bool = true,
        read_only: bool = false,
        line_numbers: bool = true,
        auto_indent: bool = true,
        on_change: ?event.Callback = null,
        colors: ?EditorColors = null,
        painter: ?Painter = null,
    };

    pub const listened_kinds = [_]event.EventKind{
        .focus_in, .focus_out, .pointer_enter, .pointer_leave,
        .pointer_down, .pointer_move, .pointer_up, .wheel, .key_down, .text_input,
    };

    pub fn nodeTemplate(style: Style) Node {
        return .{
            .role = .text_field,
            .cursor = .text,
            .flags = .{ .focusable = true, .clip_children = true, .accepts_text = true },
            .style = style,
        };
    }

    pub fn apply(self: *CodeEditor, o: Options) !void {
        self.props = .{
            .font = o.font,
            .size = o.size,
            .tab_width = o.tab_width,
            .enabled = o.enabled,
            .read_only = o.read_only,
            .line_numbers = o.line_numbers,
            .auto_indent = o.auto_indent,
            .on_change = o.on_change,
            .colors = o.colors,
            .painter = o.painter,
        };
        if (o.text.len > 0) try self.loadText(o.text, false);
        if (o.language) |l| try self.setLanguage(l);
        self.checker.sync(&self.props);
    }

    // ---- API ------------------------------------------------------------------

    /// The editor core (document, selections, history). Edits made through it
    /// directly should be followed by `invalidate`.
    pub fn core(self: *CodeEditor) *Editor {
        return &self.editor;
    }

    /// Ask the widget to repaint (and keep the caret in view) after changing
    /// its core directly.
    pub fn invalidate(self: *CodeEditor) void {
        self.repaint = true;
        self.want_visible = true;
    }

    /// Replace the content with `bytes` as the opened file. If `owned`, the
    /// editor frees it (with the Ui's allocator); otherwise it must outlive the
    /// editor. History is cleared and the text counts as saved.
    pub fn loadText(self: *CodeEditor, bytes: []const u8, owned: bool) !void {
        const fresh = try Editor.initWithText(self.ui.gpa, bytes, owned);
        self.editor.deinit();
        self.editor = fresh;
        self.scroll_x = 0;
        self.scroll_y = 0;
        self.last_version = 0;
        self.repaint = true;
        self.resetHighlighting();
    }

    pub fn markSaved(self: *CodeEditor) void {
        self.editor.markSaved();
    }

    /// The whole text, allocated with `gpa`.
    pub fn textAlloc(self: *CodeEditor, gpa: std.mem.Allocator) ![]u8 {
        return self.editor.doc.textAlloc(gpa, 0, self.editor.doc.len());
    }

    // ---- metrics -------------------------------------------------------------------

    const Metrics = struct {
        font: u32,
        size: f32,
        line_h: f32,
        ascent: f32,
        descent: f32,
        digit_w: f32,
        cell_w: f32,
    };

    fn metrics(self: *CodeEditor) ?Metrics {
        const theme = &self.ui.theme;
        const f = switch (self.props.font) {
            .ui => theme.ui_font,
            .mono => theme.mono_font,
        };
        const ts = &self.ui.text;
        if (f >= ts.fonts.items.len) return null;
        const size = if (self.props.size > 0) self.props.size else theme.font_size;
        const m = ts.metrics(f, size);
        return .{
            .font = f,
            .size = size,
            .line_h = @ceil(m.lineHeight()),
            .ascent = m.ascent,
            .descent = m.descent,
            .digit_w = ts.measure(f, size, "0"),
            .cell_w = ts.measure(f, size, " "),
        };
    }

    const Geo = struct {
        /// Padding of the node, and the text area inside it (window-relative
        /// offsets from the node's top-left).
        pad: layout_mod.Pad,
        gutter_w: f32,
        view_w: f32,
        view_h: f32,
    };

    fn geometry(self: *CodeEditor, m: Metrics) Geo {
        const node = self.ui.tree.get(self.node).?;
        const pad = layout_mod.resolveEdges(node.style.padding, null);
        var gutter: f32 = 0;
        if (self.props.line_numbers) {
            var digits: usize = 3;
            var n = self.editor.doc.lineCount();
            var d: usize = 0;
            while (n > 0) : (n /= 10) d += 1;
            digits = @max(digits, d);
            gutter = @as(f32, @floatFromInt(digits)) * m.digit_w + gutter_pad * 2;
        }
        return .{
            .pad = pad,
            .gutter_w = gutter,
            .view_w = @max(node.rect.w - pad.l - pad.r - gutter, 0),
            .view_h = @max(node.rect.h - pad.t - pad.b, 0),
        };
    }

    // ---- line view -----------------------------------------------------------------

    /// Expand tabs, build the source-to-display map, and compute caret stops for
    /// one line. Afterwards `display`, `map`, and `stops` describe that line.
    fn buildLine(self: *CodeEditor, line: usize, m: Metrics) !void {
        const ed = &self.editor;
        const src = try ed.doc.range(ed.doc.lineStart(line), ed.doc.lineEnd(line));
        self.display.clearRetainingCapacity();
        self.map.clearRetainingCapacity();
        const tab_w: usize = @max(self.props.tab_width, 1);
        var col: usize = 0;
        for (src) |b| {
            try self.map.append(self.ui.gpa, @intCast(self.display.items.len));
            if (b == '\t') {
                const n = tab_w - col % tab_w;
                try self.display.appendNTimes(self.ui.gpa, ' ', n);
                col += n;
            } else {
                try self.display.append(self.ui.gpa, b);
                if (b & 0xC0 != 0x80) col += 1;
            }
        }
        try self.map.append(self.ui.gpa, @intCast(self.display.items.len));
        self.stops.clearRetainingCapacity();
        _ = try self.ui.text.boundaries(m.font, m.size, self.display.items, &self.stops, self.ui.gpa);
    }

    /// x of the first caret stop at or after `display_byte` (stops are sorted).
    fn stopX(self: *const CodeEditor, display_byte: usize) f32 {
        const items = self.stops.items;
        if (items.len == 0) return 0;
        var lo: usize = 0;
        var hi: usize = items.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (items[mid].byte < display_byte) lo = mid + 1 else hi = mid;
        }
        return items[if (lo < items.len) lo else items.len - 1].x;
    }

    /// x of a document offset within the line built by `buildLine`.
    fn xOfOffset(self: *const CodeEditor, line_start: usize, offset: usize) f32 {
        const rel = @min(offset - line_start, self.map.items.len - 1);
        return self.stopX(self.map.items[rel]);
    }

    /// The valid cursor position (a character boundary in the source) whose x
    /// is nearest to `x` within the built line. A tab is one character, so
    /// clicking inside its span lands on whichever edge is closer.
    fn offsetAtX(self: *const CodeEditor, line_start: usize, x: f32) usize {
        var best: usize = 0;
        var best_d: f32 = std.math.inf(f32);
        for (self.map.items, 0..) |disp, rel| {
            // Skip the middle of multi-byte characters.
            if (rel > 0 and rel < self.map.items.len - 1 and self.editor.doc.byteAt(line_start + rel) & 0xC0 == 0x80) continue;
            const d = @abs(self.stopX(disp) - x);
            if (d < best_d) {
                best_d = d;
                best = rel;
            }
        }
        return line_start + best;
    }

    /// Document offset under a point given relative to the node's top-left.
    fn offsetAtPoint(self: *CodeEditor, local_x: f32, local_y: f32) usize {
        const m = self.metrics() orelse return 0;
        const geo = self.geometry(m);
        const ed = &self.editor;
        const rel_y = local_y - geo.pad.t + self.scroll_y;
        const last = ed.doc.lineCount() - 1;
        const line: usize = if (rel_y <= 0) 0 else @min(@as(usize, @intFromFloat(rel_y / m.line_h)), last);
        self.buildLine(line, m) catch return ed.doc.lineStart(line);
        const x = local_x - geo.pad.l - geo.gutter_w + self.scroll_x;
        return self.offsetAtX(ed.doc.lineStart(line), x);
    }

    // ---- frame sync -------------------------------------------------------------------

    fn touch(self: *CodeEditor, visible: bool) void {
        self.blink_on = true;
        self.blink_at = self.ui.now_ms;
        self.repaint = true;
        if (visible) self.want_visible = true;
    }

    fn afterEdit(self: *CodeEditor, ev: *event.Event, changed: bool) void {
        if (!changed) return;
        self.out.changed = true;
        self.out.change_count +%= 1;
        self.touch(true);
        if (self.props.on_change) |cb| cb.invoke(ev);
    }

    fn maxScrollY(self: *CodeEditor, m: Metrics, geo: Geo) f32 {
        const content = @as(f32, @floatFromInt(self.editor.doc.lineCount())) * m.line_h;
        return @max(content - geo.view_h, 0);
    }

    fn ensureCaretVisible(self: *CodeEditor, m: Metrics, geo: Geo) void {
        const ed = &self.editor;
        const head = ed.primaryHead();
        const line = ed.doc.lineOfOffset(head);
        const top = @as(f32, @floatFromInt(line)) * m.line_h;
        if (top < self.scroll_y) self.scroll_y = top;
        if (top + m.line_h > self.scroll_y + geo.view_h) self.scroll_y = top + m.line_h - geo.view_h;
        if (self.buildLine(line, m)) {
            const cx = self.xOfOffset(ed.doc.lineStart(line), head);
            if (cx - self.scroll_x > geo.view_w - 8) self.scroll_x = cx - geo.view_w + 8;
            if (cx - self.scroll_x < 0) self.scroll_x = cx;
            if (cx < geo.view_w - 8) self.scroll_x = 0;
        } else |_| {}
    }

    /// Disabled editors leave the tab order.
    pub fn prepare(self: *CodeEditor) void {
        self.ui.tree.get(self.node).?.flags.focusable = self.props.enabled;
    }

    pub fn endFrame(self: *CodeEditor) void {
        self.out.changed = false;
    }

    /// Per-frame sync: apply props, notice document changes, keep the caret in
    /// view, refresh `out`, and mark the node dirty if anything needs repainting.
    pub fn update(self: *CodeEditor) void {
        self.ui.verifyProps(self.node, &self.checker, &self.props, "code_editor");
        const tree = &self.ui.tree;
        const node = tree.get(self.node).?;
        self.editor.tab_width = @max(self.props.tab_width, 1);
        self.editor.auto_indent = self.props.auto_indent;
        node.flags.focusable = self.props.enabled;

        if (self.editor.doc.changes.items.len > 0 or self.editor.doc.version != self.last_version) {
            // Subscribers drain the change records here: the highlighter follows
            // every edit so only the affected lines are relexed.
            if (self.highlighter) |*h| {
                for (self.editor.doc.changes.items) |c| {
                    h.onChange(c) catch {
                        h.reset(self.editor.doc.lineCount()) catch {};
                        break;
                    };
                }
            }
            self.editor.doc.clearChanges();
            self.last_version = self.editor.doc.version;
            self.repaint = true;
        }

        if (self.metrics()) |m| {
            const geo = self.geometry(m);
            if (self.want_visible) {
                self.ensureCaretVisible(m, geo);
                self.want_visible = false;
            }
            self.scroll_y = std.math.clamp(self.scroll_y, 0, self.maxScrollY(m, geo));
            self.scroll_x = @max(self.scroll_x, 0);
        }

        const out = &self.out;
        const head = self.editor.primaryHead();
        out.line_count = @intCast(self.editor.doc.lineCount());
        out.caret_line = @intCast(self.editor.doc.lineOfOffset(head));
        out.caret_column = @intCast(self.editor.doc.columnOf(head) catch 0);
        out.selection_count = @intCast(self.editor.sel.items.items.len);
        out.modified = self.editor.isModified();

        if (self.repaint) {
            self.repaint = false;
            tree.markDirty(self.node, DirtyFlags.paint_only);
        }
    }

    // ---- painting ------------------------------------------------------------------------

    /// The colors in effect: this editor's override, else the theme's.
    pub fn palette(self: *const CodeEditor) EditorColors {
        return self.props.colors orelse self.ui.theme.editor;
    }

    /// The node's painter hook: runs this editor's painter, else the theme's.
    pub fn paintHook(self: *CodeEditor, pc: *PaintCtx) paint_ctx.Error!void {
        const p = self.props.painter orelse self.ui.theme.editor_painter;
        try p(pc, self);
    }

    pub fn setPainter(self: *CodeEditor, p: ?Painter) void {
        self.props.painter = p;
        self.repaint = true;
    }

    /// Draw the editor's content (gutter, text, selections, carets, scrollbar)
    /// inside `pc.rect`. Painters call this after drawing their own chrome.
    pub fn paintContent(self: *CodeEditor, pc: *PaintCtx) paint_ctx.Error!void {
        const abs = pc.rect;
        const list = pc.list;
        const m = self.metrics() orelse return;
        const geo = self.geometry(m);
        const colors = self.palette();
        const ed = &self.editor;
        const focused = self.out.focused and self.props.enabled;
        const last_line = ed.doc.lineCount() - 1;
        const first = @min(@as(usize, @intFromFloat(@max(self.scroll_y, 0) / m.line_h)), last_line);
        const count = @as(usize, @intFromFloat(@ceil(geo.view_h / m.line_h))) + 2;
        const stop_line = @min(first + count, last_line + 1);

        const text_area: Rect = .{ .x = abs.x + geo.pad.l + geo.gutter_w, .y = abs.y + geo.pad.t, .w = geo.view_w, .h = geo.view_h };
        const origin_x = text_area.x - self.scroll_x;
        const head_line = ed.doc.lineOfOffset(ed.primaryHead());
        const show_caret = focused and self.blink_on and !self.props.read_only;
        const sel_color = if (focused) colors.selection else colors.selection_unfocused;

        {
            try list.pushClip(text_area);
            defer _ = list.popClip() catch {};
            var line = first;
            while (line < stop_line) : (line += 1) {
                self.buildLine(line, m) catch break;
                const row_y = text_area.y + @as(f32, @floatFromInt(line)) * m.line_h - self.scroll_y;
                const ls = ed.doc.lineStart(line);
                const le = ed.doc.lineEnd(line);

                if (focused and line == head_line and !ed.hasSelectedText()) {
                    try list.fillRect(.{ .x = text_area.x, .y = row_y, .w = text_area.w, .h = m.line_h }, Paint.solid(colors.current_line));
                }
                for (ed.sel.items.items) |s| {
                    if (s.isEmpty() or s.end() < ls or s.start() > le + 1) continue;
                    if (s.start() > le) continue;
                    const a = @max(s.start(), ls);
                    const b = @min(s.end(), le);
                    var x1 = self.xOfOffset(ls, b);
                    if (s.end() > le and line < last_line) x1 += m.cell_w; // the line break is selected too
                    const x0 = self.xOfOffset(ls, a);
                    if (x1 > x0) {
                        try list.fillRect(.{ .x = origin_x + x0, .y = row_y, .w = x1 - x0, .h = m.line_h }, Paint.solid(sel_color));
                    }
                }

                // Text: shape the expanded line, then draw it in colored runs.
                self.glyphs.clearRetainingCapacity();
                _ = self.ui.text.shape(m.font, m.size, self.display.items, &self.glyphs, self.ui.gpa) catch break;
                const baseline = row_y + (m.line_h - (m.ascent + m.descent)) / 2 + m.ascent;
                try self.emitLine(list, m, origin_x, baseline, row_y, line);

                if (show_caret) {
                    for (ed.sel.items.items) |s| {
                        if (s.head < ls or s.head > le) continue;
                        const cx = self.xOfOffset(ls, s.head);
                        try list.fillRect(.{ .x = @round(origin_x + cx), .y = row_y, .w = 1, .h = m.line_h }, Paint.solid(colors.caret));
                    }
                }
            }
        }

        if (self.props.line_numbers and geo.gutter_w > 0) {
            const gutter: Rect = .{ .x = abs.x + geo.pad.l, .y = abs.y + geo.pad.t, .w = geo.gutter_w, .h = geo.view_h };
            try list.pushClip(gutter);
            defer _ = list.popClip() catch {};
            try list.fillRect(gutter, Paint.solid(colors.gutter_background));
            var line = first;
            while (line < stop_line) : (line += 1) {
                const row_y = gutter.y + @as(f32, @floatFromInt(line)) * m.line_h - self.scroll_y;
                const s = std.fmt.bufPrint(&self.number_buf, "{d}", .{line + 1}) catch continue;
                self.glyphs.clearRetainingCapacity();
                const r = self.ui.text.shape(m.font, m.size, s, &self.glyphs, self.ui.gpa) catch continue;
                if (self.glyphs.items.len == 0) continue;
                const baseline = row_y + (m.line_h - (m.ascent + m.descent)) / 2 + m.ascent;
                const x = gutter.x + gutter.w - gutter_pad - r.width;
                const color = if (line == head_line and focused) colors.gutter_text_active else colors.gutter_text;
                try list.glyphRunAt(.{ .x = x, .y = row_y, .w = r.width, .h = m.line_h }, self.glyphs.items, .{ .x = x, .y = baseline }, color, m.font, m.size, !self.ui.text.isMonospace(m.font));
            }
        }

        // Scrollbar thumb.
        const content = @as(f32, @floatFromInt(last_line + 1)) * m.line_h;
        if (content > geo.view_h and geo.view_h > 0) {
            const thumb_h = @max(geo.view_h * geo.view_h / content, 24);
            const track = geo.view_h - thumb_h;
            const max_scroll = content - geo.view_h;
            const y = abs.y + geo.pad.t + (if (max_scroll > 0) track * self.scroll_y / max_scroll else 0);
            try list.fillRoundedRect(.{ .x = abs.x + abs.w - 8, .y = y, .w = 5, .h = thumb_h }, .{ 2.5, 2.5, 2.5, 2.5 }, Paint.solid(colors.scrollbar));
        }
    }

    /// x of a source byte within the line built by `buildLine`.
    fn spanX(self: *const CodeEditor, src_byte: u32) f32 {
        const idx = @min(@as(usize, src_byte), self.map.items.len - 1);
        return self.stopX(self.map.items[idx]);
    }

    /// Draw the shaped glyphs of the built line, split into runs by token color.
    fn emitLine(self: *CodeEditor, list: *DrawList, m: Metrics, origin_x: f32, baseline: f32, row_y: f32, line: usize) draw_list.Error!void {
        const glyphs = self.glyphs.items;
        if (glyphs.len == 0) return;
        const colors = self.palette();
        const subpixel = !self.ui.text.isMonospace(m.font);
        const bounds: Rect = .{ .x = origin_x, .y = row_y, .w = self.stopX(std.math.maxInt(usize)), .h = m.line_h };
        const plain = colors.tokenColor(.plain);

        var have_spans = false;
        if (self.highlighter) |*h| {
            if (h.spansForLine(&self.editor.doc, line, &self.spans)) |_| {
                have_spans = self.spans.items.len > 0;
            } else |_| {}
        }
        if (!have_spans) {
            try list.glyphRunAt(bounds, glyphs, .{ .x = origin_x, .y = baseline }, plain, m.font, m.size, subpixel);
            return;
        }

        const spans = self.spans.items;
        var si: usize = 0;
        var run_start: usize = 0;
        var cur = plain;
        const eps = 0.01;
        for (glyphs, 0..) |g, gi| {
            while (si < spans.len and g.x >= self.spanX(spans[si].end) - eps) si += 1;
            const color = if (si < spans.len and g.x >= self.spanX(spans[si].start) - eps) colors.tokenColor(spans[si].kind) else plain;
            if (gi == 0) {
                cur = color;
            } else if (!std.meta.eql(color, cur)) {
                try list.glyphRunAt(bounds, glyphs[run_start..gi], .{ .x = origin_x, .y = baseline }, cur, m.font, m.size, subpixel);
                run_start = gi;
                cur = color;
            }
        }
        try list.glyphRunAt(bounds, glyphs[run_start..], .{ .x = origin_x, .y = baseline }, cur, m.font, m.size, subpixel);
    }

    // ---- events ----------------------------------------------------------------------------

    fn copy(self: *CodeEditor) void {
        const cb = self.ui.clipboard orelse return;
        if (!self.editor.hasSelectedText()) return;
        const text = self.editor.selectedText(self.ui.gpa) catch return;
        defer self.ui.gpa.free(text);
        cb.set(cb.ctx, text);
    }

    pub fn handleEvent(self: *CodeEditor, ev: *event.Event) void {
        const props = &self.props;
        const out = &self.out;
        const ed = &self.editor;
        const now = self.ui.now_ms;

        switch (ev.kind) {
            .focus_in => {
                out.focused = true;
                self.touch(false);
            },
            .focus_out => {
                out.focused = false;
                self.dragging = false;
                self.touch(false);
            },
            .pointer_enter => out.hovered = true,
            .pointer_leave => out.hovered = false,
            .pointer_down => if (props.enabled and ev.button == 1) {
                const off = self.offsetAtPoint(ev.local_x, ev.local_y);
                if (ev.clicks >= 3) {
                    ed.selectLineAt(off);
                } else if (ev.clicks == 2) {
                    ed.selectWordAt(off) catch {};
                } else if (ev.mods.alt) {
                    ed.addCaret(off);
                } else {
                    ed.setCaret(off, ev.mods.shift);
                }
                self.dragging = true;
                self.touch(true);
            },
            .pointer_move => if (self.dragging) {
                ed.dragPrimaryTo(self.offsetAtPoint(ev.local_x, ev.local_y));
                self.touch(true);
            },
            .pointer_up => self.dragging = false,
            .wheel => {
                if (self.metrics()) |m| {
                    if (ev.mods.shift) {
                        self.scroll_x = @max(self.scroll_x - (ev.dy + ev.dx) * m.line_h * 3, 0);
                    } else {
                        self.scroll_y -= ev.dy * m.line_h * 3;
                        self.scroll_x = @max(self.scroll_x - ev.dx * m.line_h * 3, 0);
                    }
                    self.repaint = true;
                    ev.markHandled();
                }
            },
            .text_input => if (props.enabled and !props.read_only) {
                const changed = ed.typeText(ev.text, now) catch false;
                self.afterEdit(ev, changed);
            },
            .key_down => self.key(ev),
            else => {},
        }
    }

    fn key(self: *CodeEditor, ev: *event.Event) void {
        const props = &self.props;
        if (!props.enabled) return;
        const ed = &self.editor;
        const now = self.ui.now_ms;
        const shift = ev.mods.shift;
        const ctrl = ev.mods.ctrl;
        const alt = ev.mods.alt;
        const cmd = ev.mods.any(.{ .ctrl = true, .gui = true });
        const word = ctrl or alt;
        const writable = !props.read_only;
        const page: isize = if (self.metrics()) |m| blk: {
            const geo = self.geometry(m);
            break :blk @max(@as(isize, @intFromFloat(geo.view_h / m.line_h)) - 1, 1);
        } else 10;
        var edited = false;
        var moved = false;

        const ok = blk: {
            switch (ev.key) {
                .left => {
                    ed.moveLeft(shift, word) catch {};
                    moved = true;
                },
                .right => {
                    ed.moveRight(shift, word) catch {};
                    moved = true;
                },
                .up => {
                    if (ctrl and alt) ed.addCursorVertical(-1) catch {} else ed.moveVertical(-1, shift) catch {};
                    moved = true;
                },
                .down => {
                    if (ctrl and alt) ed.addCursorVertical(1) catch {} else ed.moveVertical(1, shift) catch {};
                    moved = true;
                },
                .page_up => {
                    ed.moveVertical(-page, shift) catch {};
                    moved = true;
                },
                .page_down => {
                    ed.moveVertical(page, shift) catch {};
                    moved = true;
                },
                .home => {
                    if (ctrl) ed.moveToDocStart(shift) else ed.moveToLineStart(shift, true) catch {};
                    moved = true;
                },
                .end => {
                    if (ctrl) ed.moveToDocEnd(shift) else ed.moveToLineEnd(shift) catch {};
                    moved = true;
                },
                .enter => if (writable) {
                    edited = ed.newline(now) catch false;
                } else break :blk false,
                .tab => if (writable) {
                    edited = (if (shift) ed.outdent(now) else ed.tab(now)) catch false;
                    if (!edited) moved = true;
                } else break :blk false,
                .backspace => if (writable) {
                    edited = ed.deleteBackward(word, now) catch false;
                } else break :blk false,
                .delete => if (writable) {
                    edited = ed.deleteForward(word, now) catch false;
                } else break :blk false,
                .a => if (cmd) {
                    ed.selectAll();
                    moved = true;
                } else break :blk false,
                .c => if (cmd) self.copy() else break :blk false,
                .x => if (cmd) {
                    self.copy();
                    if (writable) edited = ed.deleteSelections(now) catch false;
                } else break :blk false,
                .v => if (cmd and writable) {
                    if (self.ui.clipboard) |cb| {
                        if (cb.get(cb.ctx, self.ui.gpa)) |bytes| {
                            defer self.ui.gpa.free(bytes);
                            edited = ed.paste(bytes, now) catch false;
                        }
                    }
                } else break :blk false,
                .z => if (cmd and writable) {
                    edited = (if (shift) ed.redo() else ed.undo()) catch false;
                } else break :blk false,
                .y => if (cmd and writable) {
                    edited = ed.redo() catch false;
                } else break :blk false,
                .escape => if (ed.sel.items.items.len > 1 or ed.hasSelectedText()) {
                    ed.collapseToPrimary();
                    moved = true;
                } else break :blk false,
                else => break :blk false,
            }
            break :blk true;
        };
        if (!ok) return;
        ev.markHandled();
        if (edited) self.afterEdit(ev, true) else if (moved) self.touch(true);
    }

    // ---- timing --------------------------------------------------------------------------------

    /// Blink the caret. Returns true if the blink phase changed.
    pub fn tick(self: *CodeEditor, now: u64) bool {
        if (!self.out.focused or !self.props.enabled) return false;
        if (now -% self.blink_at >= blink_ms) {
            self.blink_on = !self.blink_on;
            self.blink_at = now;
            self.repaint = true;
            return true;
        }
        return false;
    }

    pub fn msUntilBlink(self: *const CodeEditor, now: u64) ?u64 {
        if (!self.out.focused or !self.props.enabled) return null;
        const elapsed = now -% self.blink_at;
        return if (elapsed >= blink_ms) 1 else blink_ms - elapsed;
    }

    /// Caret rectangle in window coordinates, for IME placement.
    pub fn caretRect(self: *CodeEditor) ?Rect {
        const m = self.metrics() orelse return null;
        const geo = self.geometry(m);
        const abs = self.ui.tree.absoluteRect(self.node) orelse return null;
        const head = self.editor.primaryHead();
        const line = self.editor.doc.lineOfOffset(head);
        self.buildLine(line, m) catch return null;
        const x = abs.x + geo.pad.l + geo.gutter_w + self.xOfOffset(self.editor.doc.lineStart(line), head) - self.scroll_x;
        const y = abs.y + geo.pad.t + @as(f32, @floatFromInt(line)) * m.line_h - self.scroll_y;
        return .{ .x = x, .y = y, .w = 1, .h = m.line_h };
    }

    pub const Props = struct {
        font: Font = .mono,
        /// Em size in logical pixels; 0 uses the theme's size.
        size: f32 = 0,
        tab_width: u32 = 4,
        enabled: bool = true,
        read_only: bool = false,
        line_numbers: bool = true,
        auto_indent: bool = true,
        /// Called after each user edit (typing, deleting, paste, undo/redo).
        on_change: ?event.Callback = null,
        /// Overrides the theme's editor colors for this editor.
        colors: ?EditorColors = null,
        /// Overrides the theme's painter for this editor (use `setPainter`).
        painter: ?Painter = null,

        pub const dirty_map = .{
            .colors = shadow.Category.paint,
            .font = shadow.Category.paint,
            .size = shadow.Category.paint,
            .tab_width = shadow.Category.paint,
            .enabled = shadow.Category.paint,
            .read_only = shadow.Category.paint,
            .line_numbers = shadow.Category.paint,
        };
    };

    pub const Out = struct {
        /// The user changed the text this frame.
        changed: bool = false,
        focused: bool = false,
        hovered: bool = false,
        /// Text differs from the last save point (see `markSaved`).
        modified: bool = false,
        change_count: u32 = 0,
        line_count: u32 = 1,
        /// 0-based line and column (code points) of the primary caret.
        caret_line: u32 = 0,
        caret_column: u32 = 0,
        selection_count: u32 = 1,
    };
};

/// The default look: a flat background, then the content.
pub fn defaultPainter(pc: *PaintCtx, ed: *CodeEditor) paint_ctx.Error!void {
    try pc.box(.{ .background = ed.palette().background });
    try ed.paintContent(pc);
}
