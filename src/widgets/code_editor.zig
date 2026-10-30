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
const common = @import("common.zig");
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
const MappedFile = @import("../editor/mapped_file.zig").MappedFile;
const Indexer = @import("../editor/indexer.zig").Indexer;

pub const Font = label.Font;

/// Draws the editor: the default fills the background, then calls
/// `paintContent` for the gutter, text, selections, carets, and scrollbar.
pub const Painter = *const fn (ctx: *PaintCtx, ed: *CodeEditor) paint_ctx.Error!void;

const blink_ms: u64 = 530;
const gutter_pad: f32 = 8;

/// How many independent decoration sets an editor holds (find uses one,
/// diagnostics another, ...). Owners are small integers chosen by the host.
pub const deco_owners = 8;

pub const DecorationKind = enum {
    /// A tinted background (find matches).
    highlight,
    /// A stronger one (the current match).
    current,
    error_squiggle,
    warning_squiggle,
    info_squiggle,
    /// Whole-line background tints (build output: errors, warnings, notes).
    error_line,
    warning_line,
    note_line,
};

/// A byte range of the text with a look. Ranges follow edits: text before
/// moves nothing, text after shifts, and a range whose text is deleted shrinks.
pub const Decoration = struct {
    start: usize,
    end: usize,
    kind: DecorationKind,
};

/// A folded region: the lines `start + 1 ..= end` are hidden; `start` stays
/// visible with a marker.
pub const Fold = struct {
    start: usize,
    end: usize,
};

/// Width of the fold-arrow column in the gutter.
const fold_w: f32 = 14;

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
    /// With `want_visible`: put the caret line in the middle of the view if it is off screen.
    center_caret: bool = false,
    want_visible: bool = false,
    last_version: u64 = 0,

    // Scratch for building one line at a time.
    display: std.ArrayListUnmanaged(u8) = .empty,
    /// IME composition (uncommitted text), drawn over the text at the primary caret.
    preedit: std.ArrayListUnmanaged(u8) = .empty,
    preedit_cursor: u32 = 0,
    map: std.ArrayListUnmanaged(u32) = .empty,
    stops: std.ArrayListUnmanaged(Stop) = .empty,
    glyphs: std.ArrayListUnmanaged(Glyph) = .empty,
    spans: std.ArrayListUnmanaged(syntax.Span) = .empty,
    number_buf: [24]u8 = undefined,

    /// Syntax highlighting, if a language is set.
    highlighter: ?Highlighter = null,
    /// Decorations by owner (see `setDecorations`).
    decos: [deco_owners]std.ArrayListUnmanaged(Decoration) = @splat(.empty),
    deco_max_len: [deco_owners]usize = @splat(0),
    /// Folded regions, sorted by `start`, never overlapping.
    folds: std.ArrayListUnmanaged(Fold) = .empty,
    follow: bool = false,
    /// A file opened with `openFile`: the mapping the text borrows, and the
    /// background scan still indexing its lines.
    mapped: ?MappedFile = null,
    indexer: ?*Indexer = null,

    pub fn deinit(self: *CodeEditor) void {
        self.releaseFile(false);
        if (self.highlighter) |*h| h.deinit();
        self.spans.deinit(self.ui.gpa);
        for (&self.decos) |*d| d.deinit(self.ui.gpa);
        self.folds.deinit(self.ui.gpa);
        self.editor.deinit();
        self.releaseFile(true);
        self.display.deinit(self.ui.gpa);
        self.preedit.deinit(self.ui.gpa);
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
    /// Stop indexing; unmap the file if `unmap` (only once the editor no longer
    /// borrows its bytes).
    fn releaseFile(self: *CodeEditor, unmap: bool) void {
        if (self.indexer) |ix| ix.destroy();
        self.indexer = null;
        if (unmap) {
            if (self.mapped) |*m| m.close();
            self.mapped = null;
        }
    }

    fn wakeUi(ctx: ?*anyopaque) void {
        const ui: *Ui = @ptrCast(@alignCast(ctx.?));
        if (ui.wake) |w| w();
    }

    /// Open `path` as the document without reading it: the file is memory-mapped
    /// (read-only) and shown at once, while a background thread indexes its lines.
    /// Until indexing finishes (`out.indexing`) the line count grows, the text
    /// cannot be edited, and jumps past the indexed part stop short. Set
    /// `Ui.wake` so the event loop wakes as the scan makes progress. Needs the
    /// `Io` the program uses for files.
    pub fn openFile(self: *CodeEditor, io: std.Io, path: []const u8) !void {
        var mapped = try MappedFile.open(io, path);
        errdefer mapped.close();
        var fresh = try Editor.initMapped(self.ui.gpa, mapped.bytes);
        errdefer fresh.deinit();
        var indexer: ?*Indexer = null;
        if (fresh.doc.isIndexing()) {
            indexer = try Indexer.start(self.ui.gpa, mapped.bytes, .{ .wake = .{ .ctx = self.ui, .call = wakeUi } });
        }
        self.releaseFile(false);
        self.editor.deinit();
        if (self.mapped) |*old| old.close();
        self.editor = fresh;
        self.mapped = mapped;
        self.indexer = indexer;
        self.scroll_x = 0;
        self.scroll_y = 0;
        self.last_version = 0;
        self.repaint = true;
        self.resetHighlighting();
    }

    /// Move newline offsets the worker has found into the document's index.
    fn pumpIndex(self: *CodeEditor) void {
        const ix = self.indexer orelse return;
        var chunks: [@import("../editor/indexer.zig").ring_len]@import("../editor/indexer.zig").Chunk = undefined;
        const n = ix.take(&chunks);
        if (n == 0) return;
        for (chunks[0..n]) |c| {
            defer self.ui.gpa.free(c.offsets);
            self.editor.doc.table.appendOriginalIndex(c.offsets, c.scanned_to) catch {};
        }
        self.resetHighlighting();
        self.repaint = true;
        if (!self.editor.doc.isIndexing()) {
            ix.destroy();
            self.indexer = null;
        }
    }

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
        /// Accessible name (for screen readers).
        label: []const u8 = "Code editor",
        language: ?*const syntax.Language = null,
        font: Font = .mono,
        size: f32 = 0,
        tab_width: u32 = 4,
        enabled: bool = true,
        read_only: bool = false,
        line_numbers: bool = true,
        auto_indent: bool = true,
        folding: bool = false,
        on_change: ?event.Callback = null,
        on_find: ?event.Callback = null,
        colors: ?EditorColors = null,
        painter: ?Painter = null,
    };

    pub const actions = [_]common.Action{
        .{ .label = "Line numbers", .toggle = "line_numbers", .checkable = true },
        .{ .label = "Read only", .toggle = "read_only", .checkable = true },
        .{ .label = "Auto indent", .toggle = "auto_indent", .checkable = true },
    };

    pub const listened_kinds = [_]event.EventKind{
        .focus_in, .focus_out, .pointer_enter, .pointer_leave,
        .pointer_down, .pointer_move, .pointer_up, .wheel, .key_down, .text_input, .text_editing,
    };

    pub fn nodeTemplate(style: Style) Node {
        return .{
            .role = .text_field,
            .cursor = .text,
            .flags = .{ .focusable = true, .clip_children = true, .accepts_text = true, .repaint_boundary = true },
            .style = style,
        };
    }

    pub fn apply(self: *CodeEditor, o: Options) !void {
        try self.ui.tree.setLabel(self.node, o.label);
        self.props = .{
            .font = o.font,
            .size = o.size,
            .tab_width = o.tab_width,
            .enabled = o.enabled,
            .read_only = o.read_only,
            .line_numbers = o.line_numbers,
            .auto_indent = o.auto_indent,
            .on_change = o.on_change,
            .on_find = o.on_find,
            .folding = o.folding,
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
        self.releaseFile(false);
        self.editor.deinit();
        if (self.mapped) |*old| old.close();
        self.mapped = null;
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

    pub const Metrics = struct {
        font: u32,
        size: f32,
        line_h: f32,
        ascent: f32,
        descent: f32,
        digit_w: f32,
        cell_w: f32,
    };

    pub fn metrics(self: *CodeEditor) ?Metrics {
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

    pub const Geo = struct {
        /// Padding of the node, and the text area inside it (window-relative
        /// offsets from the node's top-left).
        pad: layout_mod.Pad,
        gutter_w: f32,
        view_w: f32,
        view_h: f32,
    };

    pub fn geometry(self: *CodeEditor, m: Metrics) Geo {
        const node = self.ui.tree.get(self.node).?;
        const pad = layout_mod.resolveEdges(node.style.padding, null);
        var gutter: f32 = 0;
        if (self.props.folding) gutter += fold_w;
        if (self.props.line_numbers) {
            var digits: usize = 3;
            var n = self.editor.doc.lineCount();
            var d: usize = 0;
            while (n > 0) : (n /= 10) d += 1;
            digits = @max(digits, d);
            gutter += @as(f32, @floatFromInt(digits)) * m.digit_w + gutter_pad * 2;
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
        const line: usize = if (rel_y <= 0) self.lineAtRow(0) else @min(self.lineAtRow(@as(usize, @intFromFloat(rel_y / m.line_h))), last);
        self.buildLine(line, m) catch return ed.doc.lineStart(line);
        const x = local_x - geo.pad.l - geo.gutter_w + self.scroll_x;
        return self.offsetAtX(ed.doc.lineStart(line), x);
    }

    // ---- frame sync -------------------------------------------------------------------

    /// Show `composition` as an uncommitted IME string over the text at the
    /// primary caret (empty clears it).
    fn setPreedit(self: *CodeEditor, composition: []const u8, ime_caret: u32) void {
        self.preedit.clearRetainingCapacity();
        self.preedit_cursor = 0;
        if (composition.len > 0) {
            if (self.preedit.appendSlice(self.ui.gpa, composition)) {
                self.preedit_cursor = @min(ime_caret, @as(u32, @intCast(composition.len)));
            } else |_| {}
        }
        self.touch(true);
    }

    /// Width of `bytes` shaped in the editor's font.
    fn shapedWidth(self: *CodeEditor, m: Metrics, bytes: []const u8) f32 {
        self.glyphs.clearRetainingCapacity();
        const r = self.ui.text.shape(m.font, m.size, bytes, &self.glyphs, self.ui.gpa) catch return 0;
        return r.width;
    }

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
        const content = @as(f32, @floatFromInt(self.visibleRows())) * m.line_h;
        return @max(content - geo.view_h, 0);
    }

    fn ensureCaretVisible(self: *CodeEditor, m: Metrics, geo: Geo) void {
        const ed = &self.editor;
        const head = ed.primaryHead();
        const line = ed.doc.lineOfOffset(head);
        const top = @as(f32, @floatFromInt(self.rowOfLine(line))) * m.line_h;
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
        self.pumpIndex();
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
            self.remapDecorations();
            self.remapFolds();
            self.editor.doc.clearChanges();
            self.last_version = self.editor.doc.version;
            self.repaint = true;
        }

        self.revealCaret();
        if (self.metrics()) |m| {
            const geo = self.geometry(m);
            // Wait for the first layout (an unsized view would scroll to the wrong place).
            if (self.want_visible and geo.view_h >= m.line_h) {
                const was = self.scroll_y;
                self.ensureCaretVisible(m, geo);
                if (self.center_caret and self.scroll_y != was) {
                    const line = self.editor.doc.lineOfOffset(self.editor.primaryHead());
                    const top = @as(f32, @floatFromInt(self.rowOfLine(line))) * m.line_h;
                    self.scroll_y = @max(0, top - (geo.view_h - m.line_h) / 2);
                }
                self.want_visible = false;
                self.center_caret = false;
            }
            if (self.follow) self.scroll_y = self.maxScrollY(m, geo);
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
        out.indexing = self.editor.doc.isIndexing();
        out.index_progress = self.editor.doc.table.indexProgress();

        if (self.repaint) {
            self.repaint = false;
            tree.markDirty(self.node, DirtyFlags.paint_only);
        }
    }

    // ---- folding ---------------------------------------------------------------------------

    /// Leading whitespace width of `line` in columns, or null for a blank line.
    fn lineIndent(self: *CodeEditor, line: usize) ?usize {
        const doc = &self.editor.doc;
        const text = doc.range(doc.lineStart(line), doc.lineEnd(line)) catch return null;
        const tab_w = @max(self.props.tab_width, 1);
        var col: usize = 0;
        for (text) |ch| switch (ch) {
            ' ' => col += 1,
            '\t' => col += tab_w - col % tab_w,
            else => return col,
        };
        return null;
    }

    /// The last line of the region that starts at `line` (the lines below it
    /// that are indented further), or null if nothing is nested under it.
    pub fn foldEndOf(self: *CodeEditor, line: usize) ?usize {
        const lines = self.editor.doc.lineCount();
        const base = self.lineIndent(line) orelse return null;
        var next = line + 1;
        while (next < lines and self.lineIndent(next) == null) next += 1;
        if (next >= lines) return null;
        if ((self.lineIndent(next) orelse 0) <= base) return null;
        var end = next;
        var i = next + 1;
        while (i < lines) : (i += 1) {
            const ind = self.lineIndent(i) orelse continue;
            if (ind <= base) break;
            end = i;
        }
        return end;
    }

    pub fn isFoldable(self: *CodeEditor, line: usize) bool {
        return self.foldEndOf(line) != null;
    }

    fn foldStartingAt(self: *const CodeEditor, line: usize) ?Fold {
        for (self.folds.items) |f| {
            if (f.start == line) return f;
            if (f.start > line) break;
        }
        return null;
    }

    /// The fold hiding `line`, if it is inside one (not the start line).
    fn foldHiding(self: *const CodeEditor, line: usize) ?Fold {
        for (self.folds.items) |f| {
            if (line > f.start and line <= f.end) return f;
            if (f.start > line) break;
        }
        return null;
    }

    pub fn isFolded(self: *const CodeEditor, line: usize) bool {
        return self.foldStartingAt(line) != null;
    }

    /// Lines shown (every line minus the folded ones).
    pub fn visibleRows(self: *const CodeEditor) usize {
        var hidden: usize = 0;
        for (self.folds.items) |f| hidden += f.end - f.start;
        return self.editor.doc.lineCount() - hidden;
    }

    /// The display row of `line` (a hidden line shares its fold's row).
    pub fn rowOfLine(self: *const CodeEditor, line: usize) usize {
        var row = line;
        for (self.folds.items) |f| {
            if (f.end < line) {
                row -= f.end - f.start;
            } else if (f.start < line) {
                // Inside the fold: shows as its start line.
                row -= line - f.start;
                break;
            } else break;
        }
        return row;
    }

    /// The document line shown on display row `row`.
    pub fn lineAtRow(self: *const CodeEditor, row: usize) usize {
        var line = row;
        for (self.folds.items) |f| {
            if (line > f.start) line += f.end - f.start else break;
        }
        return line;
    }

    /// Fold the region starting at `line` (or the nearest region containing it).
    pub fn fold(self: *CodeEditor, line: usize) void {
        var l = line;
        // A line inside a region folds that region: look upward for a start that has an end past `line`.
        while (true) {
            if (self.foldStartingAt(l) != null) return;
            if (self.foldEndOf(l)) |end| {
                if (end >= line or l == line) {
                    self.addFold(.{ .start = l, .end = end });
                    return;
                }
            }
            if (l == 0) return;
            l -= 1;
            if (line - l > 2000) return;
        }
    }

    fn addFold(self: *CodeEditor, f: Fold) void {
        // A new fold swallows folds nested inside it.
        var kept: usize = 0;
        for (self.folds.items) |old| {
            if (old.start >= f.start and old.end <= f.end) continue;
            self.folds.items[kept] = old;
            kept += 1;
        }
        self.folds.shrinkRetainingCapacity(kept);
        var at: usize = 0;
        while (at < self.folds.items.len and self.folds.items[at].start < f.start) at += 1;
        self.folds.insert(self.ui.gpa, at, f) catch return;
        self.repaint = true;
        // The caret must not stay on a hidden line.
        self.revealCaretOutside(f);
    }

    pub fn unfold(self: *CodeEditor, line: usize) void {
        var i: usize = 0;
        while (i < self.folds.items.len) : (i += 1) {
            const f = self.folds.items[i];
            if (f.start == line or (line > f.start and line <= f.end)) {
                _ = self.folds.orderedRemove(i);
                self.repaint = true;
                return;
            }
        }
    }

    pub fn toggleFold(self: *CodeEditor, line: usize) void {
        if (self.isFolded(line)) self.unfold(line) else self.fold(line);
    }

    /// Fold every top-level region (regions nested inside stay open inside it).
    pub fn foldAll(self: *CodeEditor) void {
        self.folds.clearRetainingCapacity();
        var line: usize = 0;
        const lines = self.editor.doc.lineCount();
        while (line < lines) {
            if (self.foldEndOf(line)) |end| {
                self.folds.append(self.ui.gpa, .{ .start = line, .end = end }) catch return;
                line = end + 1;
            } else line += 1;
        }
        self.repaint = true;
        if (self.folds.items.len > 0) self.revealCaretOutside(self.folds.items[0]);
        for (self.folds.items) |f| self.revealCaretOutside(f);
    }

    pub fn unfoldAll(self: *CodeEditor) void {
        if (self.folds.items.len == 0) return;
        self.folds.clearRetainingCapacity();
        self.repaint = true;
    }

    /// If the primary caret is on a line hidden by `f`, move it to the fold's start line end.
    fn revealCaretOutside(self: *CodeEditor, f: Fold) void {
        const ed = &self.editor;
        const line = ed.doc.lineOfOffset(ed.primaryHead());
        if (line > f.start and line <= f.end) {
            ed.setCaret(ed.doc.lineEnd(f.start), false);
            self.want_visible = true;
        }
    }

    /// Typing or searching into a hidden line opens the fold around it.
    fn revealCaret(self: *CodeEditor) void {
        if (self.folds.items.len == 0) return;
        const ed = &self.editor;
        for (ed.sel.items.items) |s| {
            const line = ed.doc.lineOfOffset(s.head);
            if (self.foldHiding(line)) |f| self.unfold(f.start);
        }
    }

    /// Keep folds on their lines through edits: a fold below an edit shifts
    /// with it; one the edit touches opens (its lines changed shape).
    fn remapFolds(self: *CodeEditor) void {
        if (self.folds.items.len == 0) return;
        for (self.editor.doc.changes.items) |c| {
            const delta: isize = @as(isize, @intCast(c.inserted_lines)) - @as(isize, @intCast(c.removed_lines));
            const touched_end = c.start_line + c.removed_lines;
            var kept: usize = 0;
            for (self.folds.items) |f| {
                var g = f;
                if (c.start_line > f.end) {
                    // Below the fold: unaffected.
                } else if (touched_end < f.start) {
                    g.start = @intCast(@as(isize, @intCast(g.start)) + delta);
                    g.end = @intCast(@as(isize, @intCast(g.end)) + delta);
                } else if (c.start_line == f.start and c.removed_lines == 0 and c.inserted_lines == 0) {
                    // An edit inside the start line's own text: the fold stays.
                } else continue;
                self.folds.items[kept] = g;
                kept += 1;
            }
            self.folds.shrinkRetainingCapacity(kept);
        }
        self.repaint = true;
    }

    /// Move the caret `delta` display rows (folded lines count as one row).
    fn moveRows(self: *CodeEditor, delta: isize, extend: bool) void {
        const ed = &self.editor;
        if (self.folds.items.len == 0) {
            ed.moveVertical(delta, extend) catch {};
            return;
        }
        const line = ed.doc.lineOfOffset(ed.primaryHead());
        const row: isize = @intCast(self.rowOfLine(line));
        const last: isize = @intCast(self.visibleRows() - 1);
        const target_row: usize = @intCast(std.math.clamp(row + delta, 0, last));
        const target = self.lineAtRow(target_row);
        ed.moveVertical(@as(isize, @intCast(target)) - @as(isize, @intCast(line)), extend) catch {};
    }

    /// The line whose fold arrow is at this point of the gutter, if any.
    fn foldColumnLine(self: *CodeEditor, local_x: f32, local_y: f32) ?usize {
        const m = self.metrics() orelse return null;
        const geo = self.geometry(m);
        const x0 = geo.pad.l + geo.gutter_w - fold_w;
        if (local_x < x0 or local_x >= geo.pad.l + geo.gutter_w) return null;
        const rel_y = local_y - geo.pad.t + self.scroll_y;
        if (rel_y < 0) return null;
        const line = self.lineAtRow(@intFromFloat(rel_y / m.line_h));
        if (line >= self.editor.doc.lineCount()) return null;
        return if (self.isFolded(line) or self.isFoldable(line)) line else null;
    }

    /// The center of display row `row`'s fold arrow, relative to the node's
    /// top-left (for hosts that script or test clicks on it).
    pub fn foldArrowAt(self: *CodeEditor, row: usize) ?struct { x: f32, y: f32 } {
        const m = self.metrics() orelse return null;
        const geo = self.geometry(m);
        if (!self.props.folding) return null;
        return .{
            .x = geo.pad.l + geo.gutter_w - fold_w / 2,
            .y = geo.pad.t + (@as(f32, @floatFromInt(row)) + 0.5) * m.line_h - self.scroll_y,
        };
    }

    fn drawFoldArrow(self: *CodeEditor, list: *DrawList, m: Metrics, gutter: Rect, row_y: f32, line: usize) draw_list.Error!void {
        const folded = self.isFolded(line);
        if (!folded and !self.isFoldable(line)) return;
        const colors = self.palette();
        const paint = Paint.solid(colors.gutter_text_active);
        const cx = gutter.x + gutter.w - fold_w / 2;
        const cy = row_y + m.line_h / 2;
        if (folded) {
            try list.line(.{ .x = cx - 2, .y = cy - 4 }, .{ .x = cx + 2, .y = cy }, 1.4, paint);
            try list.line(.{ .x = cx + 2, .y = cy }, .{ .x = cx - 2, .y = cy + 4 }, 1.4, paint);
        } else {
            try list.line(.{ .x = cx - 4, .y = cy - 2 }, .{ .x = cx, .y = cy + 2 }, 1.4, paint);
            try list.line(.{ .x = cx, .y = cy + 2 }, .{ .x = cx + 4, .y = cy - 2 }, 1.4, paint);
        }
    }

    // ---- decorations -----------------------------------------------------------------------

    /// Replace owner `owner`'s decorations with `items` (sorted by `start`).
    pub fn setDecorations(self: *CodeEditor, owner: u8, items: []const Decoration) !void {
        std.debug.assert(owner < deco_owners);
        const list = &self.decos[owner];
        list.clearRetainingCapacity();
        try list.appendSlice(self.ui.gpa, items);
        var longest: usize = 0;
        for (items) |d| longest = @max(longest, d.end -| d.start);
        self.deco_max_len[owner] = longest;
        self.repaint = true;
    }

    pub fn clearDecorations(self: *CodeEditor, owner: u8) void {
        std.debug.assert(owner < deco_owners);
        if (self.decos[owner].items.len == 0) return;
        self.decos[owner].clearRetainingCapacity();
        self.deco_max_len[owner] = 0;
        self.repaint = true;
    }

    /// Select [start, end) and scroll it into view.
    pub fn selectRange(self: *CodeEditor, start: usize, end: usize) void {
        self.editor.setCaret(start, false);
        self.editor.setCaret(end, true);
        self.want_visible = true;
        self.repaint = true;
    }

    /// Put the caret at 1-based `line` and `col` (a byte column, clamped to the
    /// line) and scroll it into view; unfolds nothing.
    pub fn goTo(self: *CodeEditor, line: usize, col: usize) void {
        const doc = &self.editor.doc;
        const ln = @min(if (line == 0) 0 else line - 1, doc.lineCount() -| 1);
        const start = doc.lineStart(ln);
        const at = @min(start + (if (col == 0) 0 else col - 1), doc.lineEnd(ln));
        self.editor.setCaret(at, false);
        self.want_visible = true;
        self.center_caret = true;
        self.repaint = true;
    }

    /// Add text at the end of the document without touching the caret or the
    /// undo history (a log, a terminal scrollback). With `follow` the view stays
    /// at the bottom while text arrives, until the user scrolls up.
    pub fn appendText(self: *CodeEditor, bytes: []const u8) !void {
        if (bytes.len == 0) return;
        try self.editor.doc.apply(.{ .kind = .insert, .offset = self.editor.doc.len(), .text = bytes });
        self.repaint = true;
    }

    /// Keep the view scrolled to the end as text is appended (set false when
    /// the user scrolls up; true again at the bottom).
    pub fn setFollowEnd(self: *CodeEditor, follow: bool) void {
        self.follow = follow;
    }

    /// The document line shown at a point relative to the node's top-left.
    pub fn lineAtPoint(self: *CodeEditor, local_y: f32) usize {
        const m = self.metrics() orelse return 0;
        const geo = self.geometry(m);
        const rel_y = local_y - geo.pad.t + self.scroll_y;
        const last = self.editor.doc.lineCount() - 1;
        if (rel_y <= 0) return self.lineAtRow(0);
        return @min(self.lineAtRow(@intFromFloat(rel_y / m.line_h)), last);
    }

    fn remapPos(pos: usize, c: @import("../editor/document.zig").Change) usize {
        if (pos >= c.offset + c.removed_len) return pos - c.removed_len + c.inserted_len;
        if (pos > c.offset) return c.offset;
        return pos;
    }

    /// Keep decorations on their text through the edits just made.
    fn remapDecorations(self: *CodeEditor) void {
        for (&self.decos, 0..) |*list, owner| {
            if (list.items.len == 0) continue;
            for (self.editor.doc.changes.items) |c| {
                for (list.items) |*d| {
                    d.start = remapPos(d.start, c);
                    d.end = remapPos(d.end, c);
                }
            }
            var kept: usize = 0;
            var longest: usize = 0;
            for (list.items) |d| {
                if (d.end <= d.start) continue;
                list.items[kept] = d;
                kept += 1;
                longest = @max(longest, d.end - d.start);
            }
            list.shrinkRetainingCapacity(kept);
            self.deco_max_len[owner] = longest;
        }
    }

    /// Draw the decorations that touch the line [ls, le]: backgrounds before
    /// the text, squiggles after it.
    fn drawDecorations(self: *CodeEditor, list: *DrawList, m: Metrics, origin_x: f32, row_y: f32, ls: usize, le: usize, backgrounds: bool) draw_list.Error!void {
        const colors = self.palette();
        for (self.decos, 0..) |ds, owner| {
            if (ds.items.len == 0) continue;
            // First range that could reach this line: starts are sorted.
            var lo: usize = 0;
            var hi: usize = ds.items.len;
            const floor = ls -| self.deco_max_len[owner];
            while (lo < hi) {
                const mid = (lo + hi) / 2;
                if (ds.items[mid].start < floor) lo = mid + 1 else hi = mid;
            }
            var i = lo;
            while (i < ds.items.len and ds.items[i].start <= le) : (i += 1) {
                const d = ds.items[i];
                if (d.end < ls or d.end == d.start) continue;
                const is_bg = switch (d.kind) {
                    .highlight, .current, .error_line, .warning_line, .note_line => true,
                    else => false,
                };
                if (is_bg != backgrounds) continue;
                const a = @max(d.start, ls);
                const b = @min(d.end, le);
                if (b <= a) continue;
                const x0 = origin_x + self.xOfOffset(ls, a);
                const x1 = origin_x + self.xOfOffset(ls, b);
                switch (d.kind) {
                    .highlight => try list.fillRect(.{ .x = x0, .y = row_y, .w = x1 - x0, .h = m.line_h }, Paint.solid(colors.find_match)),
                    .current => try list.fillRect(.{ .x = x0, .y = row_y, .w = x1 - x0, .h = m.line_h }, Paint.solid(colors.find_current)),
                    .error_line, .warning_line, .note_line => {
                        const tint = switch (d.kind) {
                            .error_line => colors.line_error,
                            .warning_line => colors.line_warning,
                            else => colors.line_note,
                        };
                        // The whole row, not just the text.
                        try list.fillRect(.{ .x = origin_x + self.scroll_x, .y = row_y, .w = 4000, .h = m.line_h }, Paint.solid(tint));
                    },
                    .error_squiggle, .warning_squiggle, .info_squiggle => {
                        const color = switch (d.kind) {
                            .error_squiggle => colors.squiggle_error,
                            .warning_squiggle => colors.squiggle_warning,
                            else => colors.squiggle_info,
                        };
                        const base = row_y + m.line_h - 2;
                        var x = x0;
                        var up = false;
                        while (x < x1) {
                            const nx = @min(x + 3, x1);
                            const y0: f32 = if (up) base - 1.5 else base;
                            const y1: f32 = if (up) base else base - 1.5;
                            try list.line(.{ .x = x, .y = y0 }, .{ .x = nx, .y = y1 }, 1, Paint.solid(color));
                            x = nx;
                            up = !up;
                        }
                    },
                }
            }
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
        const rows = self.visibleRows();
        const first_row = @min(@as(usize, @intFromFloat(@max(self.scroll_y, 0) / m.line_h)), rows - 1);
        const count = @as(usize, @intFromFloat(@ceil(geo.view_h / m.line_h))) + 2;
        const stop_row = @min(first_row + count, rows);

        const text_area: Rect = .{ .x = abs.x + geo.pad.l + geo.gutter_w, .y = abs.y + geo.pad.t, .w = geo.view_w, .h = geo.view_h };
        const origin_x = text_area.x - self.scroll_x;
        const head_line = ed.doc.lineOfOffset(ed.primaryHead());
        const show_caret = focused and self.blink_on and !self.props.read_only;
        const sel_color = if (focused) colors.selection else colors.selection_unfocused;

        {
            try list.pushClip(text_area);
            defer _ = list.popClip() catch {};
            var row = first_row;
            while (row < stop_row) : (row += 1) {
                const line = self.lineAtRow(row);
                if (line > last_line) break;
                try self.buildLine(line, m);
                const row_y = text_area.y + @as(f32, @floatFromInt(row)) * m.line_h - self.scroll_y;
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

                try self.drawDecorations(list, m, origin_x, row_y, ls, le, true);

                // Text: shape the expanded line, then draw it in colored runs.
                self.glyphs.clearRetainingCapacity();
                _ = try self.ui.text.shape(m.font, m.size, self.display.items, &self.glyphs, self.ui.gpa);
                const baseline = row_y + (m.line_h - (m.ascent + m.descent)) / 2 + m.ascent;
                try self.emitLine(list, m, origin_x, baseline, row_y, line);
                try self.drawDecorations(list, m, origin_x, row_y, ls, le, false);
                if (self.foldStartingAt(line) != null) {
                    // A marker after the line: the hidden lines are folded here.
                    const mx = @round(origin_x + self.xOfOffset(ls, le)) + 8;
                    const my = row_y + m.line_h / 2;
                    for (0..3) |k| try list.fillRect(.{ .x = mx + @as(f32, @floatFromInt(k)) * 5, .y = my, .w = 2, .h = 2 }, Paint.solid(colors.gutter_text_active));
                }

                const composing = self.preedit.items.len > 0 and line == head_line and focused;
                if (show_caret and !composing) {
                    for (ed.sel.items.items) |s| {
                        if (s.head < ls or s.head > le) continue;
                        const cx = self.xOfOffset(ls, s.head);
                        try list.fillRect(.{ .x = @round(origin_x + cx), .y = row_y, .w = 1, .h = m.line_h }, Paint.solid(colors.caret));
                    }
                }
                if (composing) {
                    // The IME composition: drawn over the text at the caret, on an
                    // opaque patch, underlined, with the IME's own caret inside it.
                    const px = origin_x + self.xOfOffset(ls, ed.primaryHead());
                    const inner = self.shapedWidth(m, self.preedit.items[0..self.preedit_cursor]);
                    const pw = self.shapedWidth(m, self.preedit.items); // leaves the glyphs for drawing
                    try list.fillRect(.{ .x = px, .y = row_y, .w = pw, .h = m.line_h }, Paint.solid(colors.background));
                    if (self.glyphs.items.len > 0) {
                        try list.glyphRunAt(.{ .x = px, .y = row_y, .w = pw, .h = m.line_h }, self.glyphs.items, .{ .x = px, .y = baseline }, colors.text, m.font, m.size, !self.ui.text.isMonospace(m.font));
                    }
                    try list.fillRect(.{ .x = px, .y = baseline + 2, .w = pw, .h = 1 }, Paint.solid(colors.text));
                    if (show_caret) try list.fillRect(.{ .x = @round(px + inner), .y = row_y, .w = 1, .h = m.line_h }, Paint.solid(colors.caret));
                }
            }
        }

        if ((self.props.line_numbers or self.props.folding) and geo.gutter_w > 0) {
            const gutter: Rect = .{ .x = abs.x + geo.pad.l, .y = abs.y + geo.pad.t, .w = geo.gutter_w, .h = geo.view_h };
            try list.pushClip(gutter);
            defer _ = list.popClip() catch {};
            try list.fillRect(gutter, Paint.solid(colors.gutter_background));
            var row = first_row;
            while (row < stop_row) : (row += 1) {
                const line = self.lineAtRow(row);
                if (line > last_line) break;
                const row_y = gutter.y + @as(f32, @floatFromInt(row)) * m.line_h - self.scroll_y;
                if (self.props.folding) try self.drawFoldArrow(list, m, gutter, row_y, line);
                if (!self.props.line_numbers) continue;
                const s = std.fmt.bufPrint(&self.number_buf, "{d}", .{line + 1}) catch continue;
                self.glyphs.clearRetainingCapacity();
                const r = try self.ui.text.shape(m.font, m.size, s, &self.glyphs, self.ui.gpa);
                if (self.glyphs.items.len == 0) continue;
                const baseline = row_y + (m.line_h - (m.ascent + m.descent)) / 2 + m.ascent;
                const x = gutter.x + gutter.w - (if (self.props.folding) fold_w else 0) - gutter_pad - r.width;
                const color = if (line == head_line and focused) colors.gutter_text_active else colors.gutter_text;
                try list.glyphRunAt(.{ .x = x, .y = row_y, .w = r.width, .h = m.line_h }, self.glyphs.items, .{ .x = x, .y = baseline }, color, m.font, m.size, !self.ui.text.isMonospace(m.font));
            }
        }

        // Scrollbar thumb.
        const content = @as(f32, @floatFromInt(rows)) * m.line_h;
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
            try self.emitRun(list, m, bounds, glyphs, origin_x, baseline, plain, subpixel);
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
                try self.emitRun(list, m, bounds, glyphs[run_start..gi], origin_x, baseline, cur, subpixel);
                run_start = gi;
                cur = color;
            }
        }
        try self.emitRun(list, m, bounds, glyphs[run_start..], origin_x, baseline, cur, subpixel);
    }

    /// One colored run. Monospace text goes in as cells (ids only) when its
    /// positions sit on the cell grid, else as positioned glyphs.
    fn emitRun(self: *CodeEditor, list: *DrawList, m: Metrics, bounds: Rect, run: []const draw_list.Glyph, origin_x: f32, baseline: f32, color: @import("../core/geometry.zig").Color, subpixel: bool) draw_list.Error!void {
        if (!subpixel and try list.monoRunAt(bounds, run, .{ .x = origin_x, .y = baseline }, color, m.font, m.size, m.cell_w)) return;
        _ = self;
        try list.glyphRunAt(bounds, run, .{ .x = origin_x, .y = baseline }, color, m.font, m.size, subpixel);
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
                if (self.preedit.items.len > 0) self.setPreedit("", 0);
                self.touch(false);
            },
            .text_editing => if (props.enabled and !props.read_only) self.setPreedit(ev.text, ev.preedit_cursor),
            .pointer_enter => out.hovered = true,
            .pointer_leave => out.hovered = false,
            .pointer_down => if (props.enabled and ev.button == 1) {
                if (self.props.folding) {
                    if (self.foldColumnLine(ev.local_x, ev.local_y)) |fl| {
                        self.toggleFold(fl);
                        ev.markHandled();
                        return;
                    }
                }
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
                if (self.preedit.items.len > 0) self.setPreedit("", 0); // being committed
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
                    if (ctrl and alt) ed.addCursorVertical(-1) catch {} else self.moveRows(-1, shift);
                    moved = true;
                },
                .down => {
                    if (ctrl and alt) ed.addCursorVertical(1) catch {} else self.moveRows(1, shift);
                    moved = true;
                },
                .page_up => {
                    self.moveRows(-page, shift);
                    moved = true;
                },
                .page_down => {
                    self.moveRows(page, shift);
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
                .left_bracket => if (cmd and shift and props.folding) {
                    self.fold(ed.doc.lineOfOffset(ed.primaryHead()));
                    moved = true;
                } else break :blk false,
                .right_bracket => if (cmd and shift and props.folding) {
                    self.unfold(ed.doc.lineOfOffset(ed.primaryHead()));
                    moved = true;
                } else break :blk false,
                .f, .h => if (cmd and props.on_find != null) {
                    props.on_find.?.invoke(ev);
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
        var x = abs.x + geo.pad.l + geo.gutter_w + self.xOfOffset(self.editor.doc.lineStart(line), head) - self.scroll_x;
        if (self.preedit.items.len > 0) x += self.shapedWidth(m, self.preedit.items[0..self.preedit_cursor]);
        const y = abs.y + geo.pad.t + @as(f32, @floatFromInt(self.rowOfLine(line))) * m.line_h - self.scroll_y;
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
        /// Fold arrows in the gutter and fold commands (regions come from indentation).
        folding: bool = false,
        /// Called after each user edit (typing, deleting, paste, undo/redo).
        on_change: ?event.Callback = null,
        /// Ctrl+F / Ctrl+H pressed in the editor: the host shows its find bar
        /// (the callback's `ev.key` is `.f` for find and `.h` for replace).
        on_find: ?event.Callback = null,
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
        /// A file opened with `openFile` is still being indexed: lines are still
        /// being counted and editing is off.
        indexing: bool = false,
        index_progress: f32 = 1,
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
