//! The UI builder (design doc section 13), written in the toolkit itself.
//!
//!     +-----------+------------------------+---------------+
//!     | palette   |  preview               |  inspector    |
//!     | outline   |  (the live document)   |  id, props,   |
//!     |           |                        |  style, events|
//!     +-----------+------------------------+---------------+
//!
//! The document model (`uidoc.Doc`) is edited through `uiedit.Editor`, so every
//! change is an undoable command. The preview is the document instantiated for
//! real (`uiload.instantiate`, lenient so unfinished documents still show).
//!
//! The inspector is generated, not written per widget: props and style are
//! `Form(Dynamic)` over the runtime schema, editing the *live* widget so the
//! preview responds immediately. After each edit the live value is diffed against
//! its defaults (`uidiff`) and the document's sparse record is updated. Edits made
//! in the inspector therefore do not rebuild the preview or the inspector (which
//! would drop focus mid-typing); structural changes, undo, and redo do.
//!
//! Keyboard: Ctrl+Z undo, Ctrl+Shift+Z or Ctrl+Y redo, Ctrl+S save. There is no
//! scroll container yet, so the inspector shows one section at a time (Props,
//! Style, Events).

const std = @import("std");
const Allocator = std.mem.Allocator;
const ui_mod = @import("../core/ui.zig");
const Ui = ui_mod.Ui;
const event = @import("../core/event.zig");
const Handle = @import("../core/handle.zig").Handle;
const Length = @import("../core/length.zig").Length;
const Color = @import("../core/geometry.zig").Color;
const style_mod = @import("../core/style.zig");
const Style = style_mod.Style;
const Edges = style_mod.Edges;
const schema = @import("../core/schema.zig");
const Button = @import("../widgets/button.zig").Button;
const Label = @import("../widgets/label.zig").Label;
const TextField = @import("../widgets/text_field.zig").TextField;
const registry = @import("../widgets/registry.zig");
const form_mod = @import("../forms/form.zig");
const doc_mod = @import("../uidoc/doc.zig");
const edit = @import("../uidoc/edit.zig");
const load = @import("../uidoc/load.zig");
const diff = @import("../uidoc/diff.zig");
const zon = @import("../uidoc/zon.zig");

const DynForm = form_mod.Form(form_mod.Dynamic);

pub const Tab = enum { props, style, events };

/// Called by Save with the document's ZON text (valid only during the call).
pub const SaveHook = struct {
    ctx: ?*anyopaque = null,
    call: *const fn (ctx: ?*anyopaque, text: []const u8) void,
};

pub const Options = struct {
    save: ?SaveHook = null,
    /// Named callbacks the preview binds events to; unknown names are ignored.
    actions: ?*const load.Actions = null,
    inspector_width: f32 = 340,
    side_width: f32 = 230,
};

const panel_bg = Color.rgb(34, 36, 41);
const panel_border = Color.rgb(64, 68, 76);
const preview_bg = Color.rgb(24, 25, 29);
const error_color = Color.rgb(224, 96, 96);

const command_names = [_][]const u8{ "builder.undo", "builder.redo", "builder.save", "builder.delete" };

pub const Builder = struct {
    ui: *Ui,
    gpa: Allocator,
    opts: Options,
    editor: edit.Editor,
    /// uid of the selected document node.
    selected: u32,
    tab: Tab = .props,

    root: Handle = Handle.invalid,
    palette: Handle = Handle.invalid,
    outline: Handle = Handle.invalid,
    preview_host: Handle = Handle.invalid,
    inspector: Handle = Handle.invalid,
    status: *Label = undefined,
    undo_btn: *Button = undefined,
    redo_btn: *Button = undefined,
    delete_btn: *Button = undefined,

    inst: ?load.Instance = null,
    props_form: ?*DynForm = null,
    style_form: ?*DynForm = null,
    id_field: ?*TextField = null,
    text_field: ?*TextField = null,
    event_fields: std.ArrayListUnmanaged(*TextField) = .empty,

    built_version: u32 = 0,
    /// The change being synced came from the inspector (do not rebuild it).
    inspector_edit: bool = false,
    /// Inspector controls are being created: ignore their change notifications.
    building: bool = false,
    command_handles: [command_names.len]Handle = @splat(Handle.invalid),

    pub fn create(ui: *Ui, parent: Handle, initial: doc_mod.Doc, opts: Options) !*Builder {
        const self = try ui.gpa.create(Builder);
        errdefer ui.gpa.destroy(self);
        self.* = .{
            .ui = ui,
            .gpa = ui.gpa,
            .opts = opts,
            .editor = edit.Editor.init(ui.gpa, initial),
            .selected = initial.root.uid,
        };
        // The caller keeps ownership of `doc` if creation fails.
        errdefer {
            self.editor.undo_stack.deinit(self.gpa);
            self.editor.redo_stack.deinit(self.gpa);
        }
        try self.buildChrome(parent);
        errdefer _ = ui.tree.destroySubtree(self.root);
        try self.registerCommands();
        errdefer self.unregisterCommands();
        errdefer {
            self.clearInspector();
            if (self.inst) |*i| i.destroy();
            self.event_fields.deinit(self.gpa);
        }
        try self.rebuildAll();
        return self;
    }

    pub fn destroy(self: *Builder) void {
        self.clearInspector();
        if (self.inst) |*i| i.destroy();
        self.inst = null;
        self.unregisterCommands();
        _ = self.ui.tree.destroySubtree(self.root);
        self.event_fields.deinit(self.gpa);
        self.editor.deinit();
        self.gpa.destroy(self);
    }

    pub fn doc(self: *Builder) *doc_mod.Doc {
        return &self.editor.doc;
    }

    /// The document as ZON text; free with `gpa`.
    pub fn toZon(self: *Builder, gpa: Allocator) ![]u8 {
        return self.editor.doc.toZon(gpa);
    }

    fn selectedNode(self: *Builder) *doc_mod.Node {
        return self.doc().find(self.selected) orelse self.doc().root;
    }

    // ---- chrome ----

    fn node(self: *Builder, parent: Handle, style: Style) !Handle {
        const h = try self.ui.tree.create(.{ .style = style });
        errdefer _ = self.ui.tree.destroySubtree(h);
        try self.ui.tree.appendChild(parent, h);
        return h;
    }

    fn panel(self: *Builder, parent: Handle, style: Style, bg: Color) !Handle {
        const h = try self.node(parent, style);
        self.ui.tree.get(h).?.visual = .{ .background = bg, .border_color = panel_border, .border_width = 1, .radius = 4 };
        return h;
    }

    fn toolbarButton(self: *Builder, parent: Handle, text: []const u8, comptime handler: anytype) !*Button {
        const b = try self.ui.add(Button, parent, .{ .text = text, .variant = .flat });
        b.props.on_click = event.Callback.bind(self, handler);
        return b;
    }

    fn buildChrome(self: *Builder, parent: Handle) !void {
        const ui = self.ui;
        self.root = try self.node(parent, .{ .direction = .column, .gap = Length.px(8), .padding = Edges.all(8), .grow = 1 });
        errdefer _ = ui.tree.destroySubtree(self.root);

        const bar = try self.node(self.root, .{ .direction = .row, .gap = Length.px(6), .align_items = .center });
        self.undo_btn = try self.toolbarButton(bar, "Undo", onUndo);
        self.redo_btn = try self.toolbarButton(bar, "Redo", onRedo);
        self.delete_btn = try self.toolbarButton(bar, "Delete", onDelete);
        _ = try self.toolbarButton(bar, "Up", onUp);
        _ = try self.toolbarButton(bar, "Down", onDown);
        _ = try self.toolbarButton(bar, "Save", onSave);

        const main = try self.node(self.root, .{ .direction = .row, .gap = Length.px(8), .grow = 1 });
        const left = try self.node(main, .{ .direction = .column, .gap = Length.px(8), .width = Length.px(self.opts.side_width), .shrink = 0 });
        self.palette = try self.panel(left, .{ .direction = .column, .gap = Length.px(2), .padding = Edges.all(8) }, panel_bg);
        self.outline = try self.panel(left, .{ .direction = .column, .gap = Length.px(2), .padding = Edges.all(8), .grow = 1 }, panel_bg);
        self.preview_host = try self.panel(main, .{ .direction = .column, .padding = Edges.all(12), .grow = 1 }, preview_bg);
        self.inspector = try self.panel(main, .{
            .direction = .column,
            .gap = Length.px(6),
            .padding = Edges.all(8),
            .width = Length.px(self.opts.inspector_width),
            .shrink = 0,
        }, panel_bg);
        self.status = try ui.add(Label, self.root, .{});

        _ = try ui.add(Label, self.palette, .{ .text = "Add", .size = 15 });
        for (registry.widgets, 0..) |w, i| try self.paletteButton(w.name, i + 1);
        try self.paletteButton(doc_mod.box_type, registry.widgets.len + 1);
    }

    fn paletteButton(self: *Builder, name: []const u8, tag: usize) !void {
        const b = try self.ui.add(Button, self.palette, .{ .text = name, .variant = .flat, .text_align = .start });
        b.props.on_click = event.Callback.bind(self, onPalette);
        self.ui.tree.get(b.node).?.user_data = @ptrFromInt(tag);
    }

    fn tagOf(self: *Builder, h: Handle) usize {
        const n = self.ui.tree.get(h) orelse return 0;
        return @intFromPtr(n.user_data);
    }

    fn registerCommands(self: *Builder) !void {
        const handlers = [_]event.Callback{
            event.Callback.bind(self, onUndo),
            event.Callback.bind(self, onRedo),
            event.Callback.bind(self, onSave),
            event.Callback.bind(self, onDelete),
        };
        const titles = [_][]const u8{ "Undo", "Redo", "Save", "Delete node" };
        var done: usize = 0;
        errdefer for (self.command_handles[0..done]) |h| {
            _ = self.ui.commands.unregister(h);
        };
        for (command_names, 0..) |name, i| {
            self.command_handles[i] = try self.ui.registerCommand(name, .{ .title = titles[i], .run = handlers[i] });
            done += 1;
        }
        try self.ui.bindShortcut("ctrl+z", "builder.undo", .app, null);
        try self.ui.bindShortcut("ctrl+shift+z", "builder.redo", .app, null);
        try self.ui.bindShortcut("ctrl+y", "builder.redo", .app, null);
        try self.ui.bindShortcut("ctrl+s", "builder.save", .app, null);
    }

    fn unregisterCommands(self: *Builder) void {
        for (self.command_handles) |h| _ = self.ui.commands.unregister(h);
        self.command_handles = @splat(Handle.invalid);
    }

    // ---- rebuilding views ----

    fn clearChildren(self: *Builder, h: Handle) void {
        var child = self.ui.tree.get(h).?.first_child;
        while (self.ui.tree.get(child)) |n| {
            const next = n.next;
            _ = self.ui.tree.destroySubtree(child);
            child = next;
        }
    }

    fn rebuildAll(self: *Builder) !void {
        self.built_version = self.editor.version;
        if (self.doc().find(self.selected) == null) self.selected = self.doc().root.uid;
        self.clearInspector();
        if (self.inst) |*i| i.destroy();
        self.inst = null;
        self.inst = try load.instantiate(self.ui, self.preview_host, self.doc(), .{ .actions = self.opts.actions, .strict = false });
        try self.rebuildOutline();
        try self.rebuildInspector();
        self.updateStatus(null);
        self.updateButtons();
    }

    fn rebuildOutline(self: *Builder) !void {
        self.clearChildren(self.outline);
        _ = try self.ui.add(Label, self.outline, .{ .text = "Outline", .size = 15 });
        try self.outlineRows(self.doc().root, 0);
    }

    fn outlineRows(self: *Builder, n: *doc_mod.Node, depth: usize) anyerror!void {
        var buf: [96]u8 = undefined;
        var len: usize = 0;
        const indent = @min(depth * 2, 24);
        @memset(buf[0..indent], ' ');
        len = indent;
        const text = std.fmt.bufPrint(buf[len..], "{s}{s}{s}", .{ n.type_name, if (n.id.len > 0) " #" else "", n.id }) catch buf[len..len];
        const b = try self.ui.add(Button, self.outline, .{
            .text = buf[0 .. len + text.len],
            .variant = if (n.uid == self.selected) .primary else .flat,
            .text_align = .start,
        });
        b.props.on_click = event.Callback.bind(self, onOutline);
        self.ui.tree.get(b.node).?.user_data = @ptrFromInt(n.uid);
        for (n.children.items) |c| try self.outlineRows(c, depth + 1);
    }

    fn clearInspector(self: *Builder) void {
        if (self.props_form) |f| f.destroy();
        if (self.style_form) |f| f.destroy();
        self.props_form = null;
        self.style_form = null;
        self.id_field = null;
        self.text_field = null;
        self.event_fields.clearRetainingCapacity();
        self.clearChildren(self.inspector);
    }

    const Live = struct {
        /// The preview node (a box or a widget's node).
        h: Handle,
        /// Null for boxes and unknown types.
        info: ?*const registry.Info,
        w: ?*anyopaque,
    };

    fn live(self: *Builder, n: *doc_mod.Node) ?Live {
        const inst = self.inst orelse return null;
        const h = inst.handleOf(n.uid) orelse return null;
        const tn = self.ui.tree.get(h) orelse return null;
        return .{ .h = h, .info = registry.infoOf(self.ui, h), .w = tn.widget };
    }

    fn fieldRow(self: *Builder, label: []const u8) !Handle {
        const row = try self.node(self.inspector, .{ .direction = .row, .gap = Length.px(8), .align_items = .center });
        _ = try self.ui.add(Label, row, .{ .text = label, .style = .{ .width = Length.px(70), .shrink = 0 } });
        return row;
    }

    fn rebuildInspector(self: *Builder) !void {
        self.clearInspector();
        self.building = true;
        defer self.building = false;
        const ui = self.ui;
        const n = self.selectedNode();

        var title_buf: [64]u8 = undefined;
        const title = std.fmt.bufPrint(&title_buf, "{s} (#{d})", .{ n.type_name, n.uid }) catch n.type_name;
        _ = try ui.add(Label, self.inspector, .{ .text = title, .size = 15 });

        const id_row = try self.fieldRow("id");
        const idf = try ui.add(TextField, id_row, .{
            .text = n.id,
            .placeholder = "name for lookup",
            .style = .{ .grow = 1 },
            .on_change = event.Callback.bind(self, onIdChange),
        });
        self.id_field = idf;

        const tabs = try self.node(self.inspector, .{ .direction = .row, .gap = Length.px(4) });
        inline for (.{ Tab.props, Tab.style, Tab.events }) |t| {
            const b = try ui.add(Button, tabs, .{
                .text = @tagName(t),
                .variant = if (self.tab == t) .primary else .flat,
            });
            b.props.on_click = event.Callback.bind(self, onTab);
            ui.tree.get(b.node).?.user_data = @ptrFromInt(@as(usize, @intFromEnum(t)) + 1);
        }

        const lv = self.live(n);
        switch (self.tab) {
            .props => {
                const l = lv orelse return;
                const info = l.info orelse {
                    _ = try ui.add(Label, self.inspector, .{ .text = if (std.mem.eql(u8, n.type_name, doc_mod.box_type)) "A box has no props; use Style." else "Unknown widget type." });
                    return;
                };
                if (info.set_text != null) {
                    const row = try self.fieldRow("text");
                    const current = if (n.props.field("text")) |t| (if (t == .string) t.string else "") else "";
                    self.text_field = try ui.add(TextField, row, .{
                        .text = current,
                        .style = .{ .grow = 1 },
                        .on_change = event.Callback.bind(self, onTextChange),
                    });
                }
                const f = try DynForm.createDynamic(ui, self.inspector, info.props, info.propsPtr(l.w.?), .{ .footer = false, .label_width = 110 });
                f.notify = event.Callback.bind(self, onInspectorEdit);
                self.props_form = f;
            },
            .style => {
                const l = lv orelse return;
                const tn = ui.tree.get(l.h).?;
                const f = try DynForm.createDynamic(ui, self.inspector, registry.styleSchema(), &tn.style, .{ .footer = false, .label_width = 110 });
                f.notify = event.Callback.bind(self, onInspectorEdit);
                self.style_form = f;
            },
            .events => {
                const l = lv orelse return;
                const info = l.info orelse {
                    _ = try ui.add(Label, self.inspector, .{ .text = "Boxes have no events." });
                    return;
                };
                if (info.events.len == 0) {
                    _ = try ui.add(Label, self.inspector, .{ .text = "This widget has no events." });
                    return;
                }
                for (info.events) |ev_name| {
                    var name_buf: [48]u8 = undefined;
                    const label = std.fmt.bufPrint(&name_buf, "on {s}", .{ev_name}) catch ev_name;
                    const row = try self.fieldRow(label);
                    var current: []const u8 = "";
                    for (n.on) |b| if (std.mem.eql(u8, b.event, ev_name)) {
                        current = b.action;
                    };
                    const tf = try ui.add(TextField, row, .{
                        .text = current,
                        .placeholder = "action name",
                        .style = .{ .grow = 1 },
                        .on_change = event.Callback.bind(self, onEventEdit),
                    });
                    try self.event_fields.append(self.gpa, tf);
                }
            },
        }
    }

    fn updateStatus(self: *Builder, err: ?anyerror) void {
        var buf: [200]u8 = undefined;
        const text: []const u8 = blk: {
            if (err) |e| break :blk std.fmt.bufPrint(&buf, "Error: {s}", .{@errorName(e)}) catch "Error";
            if (self.inst) |inst| {
                if (inst.problems.items.len > 0) {
                    break :blk std.fmt.bufPrint(&buf, "{d} problem(s): {s}", .{ inst.problems.items.len, inst.problems.items[0].message }) catch "problems";
                }
            }
            break :blk "Ready";
        };
        if (!std.mem.eql(u8, self.status.props.text.bytes, text)) self.status.setText(text) catch {};
        self.status.props.color = if (err != null or (self.inst != null and self.inst.?.problems.items.len > 0)) error_color else Color.transparent;
        self.ui.tree.markDirty(self.status.node, .{ .paint = true });
    }

    fn updateButtons(self: *Builder) void {
        self.undo_btn.setEnabled(self.editor.canUndo());
        self.redo_btn.setEnabled(self.editor.canRedo());
        self.delete_btn.setEnabled(self.selected != self.doc().root.uid);
    }

    /// Bring the views up to date with the document.
    fn sync(self: *Builder) void {
        if (self.editor.version == self.built_version) return;
        if (self.inspector_edit) {
            self.inspector_edit = false;
            self.built_version = self.editor.version;
            self.rebuildOutline() catch |e| self.updateStatus(e);
            self.updateButtons();
            return;
        }
        self.rebuildAll() catch |e| self.updateStatus(e);
    }

    // ---- operations (also what the buttons and shortcuts call) ----

    pub fn select(self: *Builder, uid: u32) void {
        if (self.doc().find(uid) == null or uid == self.selected) return;
        self.editor.breakCoalescing();
        self.selected = uid;
        self.rebuildOutline() catch |e| self.updateStatus(e);
        self.rebuildInspector() catch |e| self.updateStatus(e);
        self.updateButtons();
    }

    pub fn setTab(self: *Builder, tab: Tab) void {
        if (self.tab == tab) return;
        self.tab = tab;
        self.rebuildInspector() catch |e| self.updateStatus(e);
    }

    pub fn undo(self: *Builder) void {
        _ = self.editor.undo() catch |e| return self.updateStatus(e);
        self.sync();
    }

    pub fn redo(self: *Builder) void {
        _ = self.editor.redo() catch |e| return self.updateStatus(e);
        self.sync();
    }

    const defaults = struct {
        const label_props = ".{ .text = \"Label\" }";
        const button_props = ".{ .text = \"Button\" }";
        const box_style = ".{ .direction = .column, .gap = 6, .padding = .{ .left = 8, .top = 8, .right = 8, .bottom = 8 } }";
    };

    /// Add a node of `type_name` inside the selected box, or after the selected
    /// widget, and select it.
    pub fn addWidget(self: *Builder, type_name: []const u8) void {
        self.addWidgetInner(type_name) catch |e| self.updateStatus(e);
    }

    fn addWidgetInner(self: *Builder, type_name: []const u8) !void {
        const sel = self.selectedNode();
        var parent = sel;
        var index = sel.children.items.len;
        if (!std.mem.eql(u8, sel.type_name, doc_mod.box_type)) {
            parent = sel.parent orelse sel;
            index = if (sel.indexInParent()) |i| i + 1 else parent.children.items.len;
        }
        const n = try self.editor.addNode(parent.uid, index, type_name);
        // Starting values belong to the creation step: set them before any other edit.
        const a = self.doc().alloc();
        if (std.mem.eql(u8, type_name, "label")) n.props = try zon.parse(a, defaults.label_props, null);
        if (std.mem.eql(u8, type_name, "button")) n.props = try zon.parse(a, defaults.button_props, null);
        if (std.mem.eql(u8, type_name, doc_mod.box_type)) n.style = try zon.parse(a, defaults.box_style, null);
        self.editor.breakCoalescing();
        self.selected = n.uid;
        self.sync();
    }

    pub fn deleteSelected(self: *Builder) void {
        const n = self.selectedNode();
        const parent = n.parent orelse return;
        self.editor.removeNode(n.uid) catch |e| return self.updateStatus(e);
        self.selected = parent.uid;
        self.sync();
    }

    /// Move the selected node among its siblings by `delta` places.
    pub fn moveSelected(self: *Builder, delta: i32) void {
        const n = self.selectedNode();
        const parent = n.parent orelse return;
        const idx: i64 = @intCast(n.indexInParent().?);
        const target = idx + delta;
        if (target < 0 or target >= parent.children.items.len) return;
        self.editor.moveNode(n.uid, parent.uid, @intCast(target)) catch |e| return self.updateStatus(e);
        self.sync();
    }

    pub fn save(self: *Builder) void {
        const hook = self.opts.save orelse return;
        const text = self.toZon(self.gpa) catch |e| return self.updateStatus(e);
        defer self.gpa.free(text);
        hook.call(hook.ctx, text);
    }

    // ---- event handlers ----

    fn onUndo(self: *Builder, _: *event.Event) void {
        self.undo();
    }

    fn onRedo(self: *Builder, _: *event.Event) void {
        self.redo();
    }

    fn onDelete(self: *Builder, _: *event.Event) void {
        self.deleteSelected();
    }

    fn onUp(self: *Builder, _: *event.Event) void {
        self.moveSelected(-1);
    }

    fn onDown(self: *Builder, _: *event.Event) void {
        self.moveSelected(1);
    }

    fn onSave(self: *Builder, _: *event.Event) void {
        self.save();
    }

    fn onPalette(self: *Builder, ev: *event.Event) void {
        const tag = self.tagOf(ev.current);
        if (tag == 0) return;
        if (tag <= registry.widgets.len) {
            self.addWidget(registry.widgets[tag - 1].name);
        } else self.addWidget(doc_mod.box_type);
    }

    fn onOutline(self: *Builder, ev: *event.Event) void {
        self.select(@intCast(self.tagOf(ev.current)));
    }

    fn onTab(self: *Builder, ev: *event.Event) void {
        const tag = self.tagOf(ev.current);
        if (tag == 0) return;
        self.setTab(@enumFromInt(tag - 1));
    }

    fn markInspectorEdit(self: *Builder, before: u32) void {
        if (self.editor.version == before) return;
        self.inspector_edit = true;
        self.sync();
    }

    fn onIdChange(self: *Builder, _: *event.Event) void {
        if (self.building) return;
        const f = self.id_field orelse return;
        const before = self.editor.version;
        self.editor.setId(self.selected, f.text()) catch |e| return self.updateStatus(e);
        self.markInspectorEdit(before);
    }

    fn onEventEdit(self: *Builder, _: *event.Event) void {
        if (self.building) return;
        const n = self.selectedNode();
        const info = (self.live(n) orelse return).info orelse return;
        const before = self.editor.version;
        for (self.event_fields.items, 0..) |f, i| {
            if (i >= info.events.len) break;
            self.editor.setEvent(n.uid, info.events[i], f.text()) catch |e| return self.updateStatus(e);
        }
        self.markInspectorEdit(before);
    }

    fn onTextChange(self: *Builder, _: *event.Event) void {
        if (self.building) return;
        const f = self.text_field orelse return;
        const n = self.selectedNode();
        const l = self.live(n) orelse return;
        const info = l.info orelse return;
        const text = f.text();
        if (info.set_text) |set_text| {
            set_text(l.w.?, text) catch |e| return self.updateStatus(e);
            self.ui.tree.markDirty(l.h, .{ .layout = true, .paint = true });
        }
        const before = self.editor.version;
        var scratch = std.heap.ArenaAllocator.init(self.gpa);
        defer scratch.deinit();
        const rec = zon.withField(scratch.allocator(), n.props, "text", .{ .string = text }) catch |e| return self.updateStatus(e);
        self.editor.setRecord(n.uid, .props, rec) catch |e| return self.updateStatus(e);
        self.markInspectorEdit(before);
    }

    /// A props or style control changed the live widget: bring the document's
    /// sparse records in line with it.
    fn onInspectorEdit(self: *Builder, _: *event.Event) void {
        if (self.building) return;
        const n = self.selectedNode();
        const l = self.live(n) orelse return;
        self.ui.tree.markDirty(l.h, .{ .layout = true, .paint = true });

        var scratch = std.heap.ArenaAllocator.init(self.gpa);
        defer scratch.deinit();
        const a = scratch.allocator();
        const before = self.editor.version;

        var props: zon.Value = .{ .record = &.{} };
        if (l.info) |info| {
            props = (diff.diff(a, info.props, info.propsPtr(l.w.?), info.props_default) catch |e| return self.updateStatus(e)) orelse props;
            if (info.set_text != null) {
                if (n.props.field("text")) |t| props = zon.withField(a, props, "text", t) catch |e| return self.updateStatus(e);
            }
        }
        const live_style = &self.ui.tree.get(l.h).?.style;
        const default_style: Style = .{};
        const style = (diff.diff(a, registry.styleSchema(), live_style, &default_style) catch |e| return self.updateStatus(e)) orelse zon.Value{ .record = &.{} };

        self.editor.setRecord(n.uid, .props, props) catch |e| return self.updateStatus(e);
        self.editor.setRecord(n.uid, .style, style) catch |e| return self.updateStatus(e);
        self.markInspectorEdit(before);
    }
};

// ---- tests -----------------------------------------------------------------

const testing = std.testing;

fn newBuilder(ui: *Ui) !*Builder {
    var d = try doc_mod.Doc.init(testing.allocator);
    errdefer d.deinit();
    return Builder.create(ui, ui.tree.root, d, .{});
}

fn typeInto(ui: *Ui, f: *TextField, text: []const u8) void {
    ui.setFocus(f.node);
    ui.key(.a, .{ .ctrl = true }, true, false);
    if (text.len == 0) ui.key(.backspace, .{}, true, false) else ui.textInput(text);
}

fn clickButton(b: *Button) void {
    var ev: event.Event = .{ .kind = .pointer_up, .current = b.node, .target = b.node };
    b.props.on_click.?.invoke(&ev);
}

fn formBinding(f: *DynForm, path: []const u8) @TypeOf(f.bindings.items[0]) {
    for (f.bindings.items) |b| if (b.kind != .presence and std.mem.eql(u8, b.path, path)) return b;
    @panic("no binding");
}

fn paletteButton(b: *Builder, name: []const u8) *Button {
    var child = b.ui.tree.get(b.palette).?.first_child;
    while (b.ui.tree.get(child)) |n| : (child = n.next) {
        if (n.widget_type == ui_mod.typeTag(Button)) {
            const btn: *Button = @ptrCast(@alignCast(n.widget.?));
            if (std.mem.eql(u8, btn.props.text.bytes, name)) return btn;
        }
    }
    @panic("no palette button");
}

fn outlineButtons(b: *Builder) usize {
    var count: usize = 0;
    var child = b.ui.tree.get(b.outline).?.first_child;
    while (b.ui.tree.get(child)) |n| : (child = n.next) {
        if (n.widget_type == ui_mod.typeTag(Button)) count += 1;
    }
    return count;
}

test "a builder starts with an empty box selected and a ready status" {
    var ui = try Ui.init(testing.allocator);
    defer ui.deinit();
    const b = try newBuilder(&ui);
    defer b.destroy();
    try testing.expectEqual(b.doc().root.uid, b.selected);
    try testing.expectEqualStrings("Ready", b.status.props.text.bytes);
    try testing.expect(!b.undo_btn.props.enabled and !b.redo_btn.props.enabled and !b.delete_btn.props.enabled);
    try testing.expectEqual(@as(usize, 1), outlineButtons(b));
}

test "the palette adds widgets inside the selected box; the preview and outline follow" {
    var ui = try Ui.init(testing.allocator);
    defer ui.deinit();
    const b = try newBuilder(&ui);
    defer b.destroy();
    clickButton(paletteButton(b, "label"));
    clickButton(paletteButton(b, "button"));
    try testing.expectEqual(@as(usize, 2), b.doc().root.children.items.len);
    try testing.expectEqualStrings("Label", b.doc().root.children.items[0].props.field("text").?.string);
    // The new button is selected; the next add lands after it, in the same box.
    try testing.expectEqual(b.doc().root.children.items[1].uid, b.selected);
    clickButton(paletteButton(b, "label"));
    try testing.expectEqual(@as(usize, 3), b.doc().root.children.items.len);
    try testing.expectEqual(@as(usize, 4), outlineButtons(b));
    // The preview is the real thing.
    const h = b.inst.?.handleOf(b.doc().root.children.items[1].uid).?;
    const btn: *Button = @ptrCast(@alignCast(ui.tree.get(h).?.widget.?));
    try testing.expectEqualStrings("Button", btn.props.text.bytes);
    try testing.expect(b.undo_btn.props.enabled);
}

test "selecting through the outline switches the inspector" {
    var ui = try Ui.init(testing.allocator);
    defer ui.deinit();
    const b = try newBuilder(&ui);
    defer b.destroy();
    b.addWidget("button");
    const btn_uid = b.selected;
    b.select(b.doc().root.uid);
    try testing.expect(b.props_form == null); // a box has no props
    b.select(btn_uid);
    try testing.expect(b.props_form != null);
    try testing.expect(b.text_field == null); // buttons carry text as a prop, in the form
    _ = formBinding(b.props_form.?, "text");
    b.addWidget("text_field");
    try testing.expect(b.text_field != null); // content widgets get a Text row
}

test "inspector edits update the live widget and the document, and undo as one step" {
    var ui = try Ui.init(testing.allocator);
    defer ui.deinit();
    const b = try newBuilder(&ui);
    defer b.destroy();
    b.addWidget("button");
    const uid = b.selected;
    const n = b.doc().find(uid).?;
    const live: *Button = @ptrCast(@alignCast(ui.tree.get(b.inst.?.handleOf(uid).?).?.widget.?));
    const form = b.props_form.?;

    typeInto(&ui, formBinding(form, "text").field.?, "Hi");
    typeInto(&ui, formBinding(form, "text").field.?, "Hello");
    try testing.expectEqualStrings("Hello", live.props.text.bytes);
    try testing.expectEqualStrings("Hello", n.props.field("text").?.string);
    clickButton(formBinding(form, "variant").button.?); // normal -> primary
    try testing.expectEqualStrings("primary", n.props.field("variant").?.tag);
    // The inspector and preview were not rebuilt by those edits.
    try testing.expect(b.props_form == form);
    try testing.expect(live == @as(*Button, @ptrCast(@alignCast(ui.tree.get(b.inst.?.handleOf(uid).?).?.widget.?))));

    b.undo(); // variant
    try testing.expect(n.props.field("variant") == null);
    try testing.expectEqualStrings("Hello", n.props.field("text").?.string);
    b.undo(); // both text edits coalesced
    try testing.expectEqualStrings("Button", n.props.field("text").?.string);
    b.redo();
    try testing.expectEqualStrings("Hello", n.props.field("text").?.string);
    // After undo/redo the preview shows the document again.
    const live2: *Button = @ptrCast(@alignCast(ui.tree.get(b.inst.?.handleOf(uid).?).?.widget.?));
    try testing.expectEqualStrings("Hello", live2.props.text.bytes);
}

test "style edits and the style tab" {
    var ui = try Ui.init(testing.allocator);
    defer ui.deinit();
    const b = try newBuilder(&ui);
    defer b.destroy();
    b.addWidget("label");
    const n = b.selectedNode();
    b.setTab(.style);
    try testing.expect(b.style_form != null and b.props_form == null);
    typeInto(&ui, formBinding(b.style_form.?, "grow").field.?, "2");
    typeInto(&ui, formBinding(b.style_form.?, "width").field.?, "120");
    try testing.expectEqual(@as(i64, 120), n.style.field("width").?.int);
    try testing.expectEqual(@as(f64, 2), n.style.field("grow").?.float);
    const live = ui.tree.get(b.inst.?.handleOf(n.uid).?).?;
    try testing.expectEqual(@as(f32, 120), live.style.width.pixels);
    // Padding is nested: its fields are edited by path.
    typeInto(&ui, formBinding(b.style_form.?, "padding.left").field.?, "9");
    try testing.expectEqual(@as(i64, 9), n.style.field("padding").?.field("left").?.int);
}

test "boxes can be styled in the inspector" {
    var ui = try Ui.init(testing.allocator);
    defer ui.deinit();
    const b = try newBuilder(&ui);
    defer b.destroy();
    b.setTab(.style);
    try testing.expect(b.style_form != null);
    typeInto(&ui, formBinding(b.style_form.?, "gap").field.?, "14");
    try testing.expectEqual(@as(i64, 14), b.doc().root.style.field("gap").?.int);
    b.setTab(.props);
    try testing.expect(b.props_form == null);
    b.setTab(.events);
    try testing.expectEqual(@as(usize, 0), b.event_fields.items.len);
}

test "ids and event bindings go into the document" {
    var ui = try Ui.init(testing.allocator);
    defer ui.deinit();
    const b = try newBuilder(&ui);
    defer b.destroy();
    b.addWidget("button");
    const n = b.selectedNode();
    typeInto(&ui, b.id_field.?, "ok");
    try testing.expectEqualStrings("ok", n.id);
    try testing.expect(b.inst.?.find("ok") == null); // applied on the next structural rebuild
    b.setTab(.events);
    try testing.expectEqual(@as(usize, 1), b.event_fields.items.len);
    typeInto(&ui, b.event_fields.items[0], "confirm");
    try testing.expectEqualStrings("click", n.on[0].event);
    try testing.expectEqualStrings("confirm", n.on[0].action);
    b.undo();
    try testing.expectEqual(@as(usize, 0), n.on.len);
    // Saved text includes everything.
    b.redo();
    const text = try b.toZon(testing.allocator);
    defer testing.allocator.free(text);
    try testing.expect(std.mem.indexOf(u8, text, ".id = \"ok\"") != null);
    try testing.expect(std.mem.indexOf(u8, text, ".click = \"confirm\"") != null);
}

test "delete and move work on the selected node; the root is protected" {
    var ui = try Ui.init(testing.allocator);
    defer ui.deinit();
    const b = try newBuilder(&ui);
    defer b.destroy();
    b.addWidget("label");
    const first = b.selected;
    b.addWidget("button");
    const second = b.selected;
    b.moveSelected(-1);
    try testing.expectEqual(second, b.doc().root.children.items[0].uid);
    b.moveSelected(-1); // already first
    try testing.expectEqual(second, b.doc().root.children.items[0].uid);
    b.moveSelected(1);
    try testing.expectEqual(first, b.doc().root.children.items[0].uid);

    b.deleteSelected();
    try testing.expectEqual(@as(usize, 1), b.doc().root.children.items.len);
    try testing.expectEqual(b.doc().root.uid, b.selected);
    b.deleteSelected(); // the root stays
    try testing.expectEqual(@as(usize, 1), b.doc().root.children.items.len);
    b.undo();
    try testing.expectEqual(@as(usize, 2), b.doc().root.children.items.len);
    try testing.expectEqual(@as(usize, 3), outlineButtons(b));
}

test "nesting: a box added inside a box takes later additions" {
    var ui = try Ui.init(testing.allocator);
    defer ui.deinit();
    const b = try newBuilder(&ui);
    defer b.destroy();
    b.addWidget("box");
    const inner = b.selected;
    b.addWidget("label");
    try testing.expectEqual(inner, b.selectedNode().parent.?.uid);
    try testing.expectEqual(@as(usize, 1), b.doc().find(inner).?.children.items.len);
    try testing.expectEqual(@as(usize, 1), b.doc().root.children.items.len);
}

test "save hands the ZON text to the hook; the text loads back to the same document" {
    var ui = try Ui.init(testing.allocator);
    defer ui.deinit();
    const Sink = struct {
        var text: ?[]u8 = null;
        fn hook(_: ?*anyopaque, t: []const u8) void {
            text = testing.allocator.dupe(u8, t) catch null;
        }
    };
    Sink.text = null;
    defer if (Sink.text) |t| testing.allocator.free(t);
    var d = try doc_mod.Doc.init(testing.allocator);
    errdefer d.deinit();
    const b = try Builder.create(&ui, ui.tree.root, d, .{ .save = .{ .call = Sink.hook } });
    defer b.destroy();
    b.addWidget("label");
    b.addWidget("button");
    b.save();
    const saved = Sink.text.?;
    var back = try doc_mod.parseDoc(testing.allocator, saved, null, null);
    defer back.deinit();
    const again = try back.toZon(testing.allocator);
    defer testing.allocator.free(again);
    try testing.expectEqualStrings(saved, again);
}

test "shortcuts run undo and redo" {
    var ui = try Ui.init(testing.allocator);
    defer ui.deinit();
    const b = try newBuilder(&ui);
    defer b.destroy();
    b.addWidget("label");
    ui.key(.z, .{ .ctrl = true }, true, false);
    try testing.expectEqual(@as(usize, 0), b.doc().root.children.items.len);
    ui.key(.y, .{ .ctrl = true }, true, false);
    try testing.expectEqual(@as(usize, 1), b.doc().root.children.items.len);
}

test "a document with problems still previews and says what is wrong" {
    var ui = try Ui.init(testing.allocator);
    defer ui.deinit();
    var d = try doc_mod.parseDoc(testing.allocator,
        \\.{ .root = .{ .type = "box", .children = .{
        \\    .{ .type = "button", .props = .{ .variant = .huge } },
        \\    .{ .type = "label", .props = .{ .text = "still here" } },
        \\} } }
    , null, null);
    errdefer d.deinit();
    const b = try Builder.create(&ui, ui.tree.root, d, .{});
    defer b.destroy();
    try testing.expect(std.mem.indexOf(u8, b.status.props.text.bytes, "1 problem") != null);
    try testing.expect(b.inst.?.problems.items.len == 1);
    try testing.expectEqual(@as(usize, 3), outlineButtons(b));
}

test "creating and destroying builders frees everything, including under allocation failure" {
    var i: usize = 0;
    while (i < 200) : (i += 1) {
        var fa = std.testing.FailingAllocator.init(testing.allocator, .{ .fail_index = i });
        var ui = Ui.init(fa.allocator()) catch continue;
        defer ui.deinit();
        var d = doc_mod.Doc.init(fa.allocator()) catch continue;
        const b = Builder.create(&ui, ui.tree.root, d, .{}) catch {
            d.deinit();
            continue;
        };
        b.addWidget("button");
        b.addWidget("box");
        b.undo();
        b.destroy();
    }
}
