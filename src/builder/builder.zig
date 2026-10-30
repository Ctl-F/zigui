//! The UI builder (design doc section 13), written in the toolkit itself.
//!
//!     +-----------+------------------------+---------------+
//!     | palette   |  preview               |  inspector    |
//!     | outline   |  (the live document)   |  props, style,|
//!     | (scrolls) |                        |  layout, events|
//!     +-----------+------------------------+---------------+
//!
//! The document model (`uidoc.Doc`) is edited through `uiedit.Editor`, so every
//! change is an undoable command. The preview is the document instantiated for
//! real (`uiload.instantiate`, lenient so unfinished documents still show).
//!
//! Working with it:
//!   - Click anything in the preview to select it (the preview does not run: it
//!     is a design surface). The selection shows its box and resize handles.
//!   - Drag a node in the preview or the outline to move it: over a box it goes
//!     inside, over a widget or a box's edge beside it, with an insertion marker.
//!     Drag a palette entry to create one where you drop it; clicking the entry
//!     adds it inside the selected box.
//!   - Drag the right, bottom, or corner handle to set a width and height.
//!   - The inspector edits the selected node: Props and Style are generated from
//!     the runtime schema, Layout is a hand-made panel for the things you reach
//!     for most (direction, gap, padding, alignment, sizing), Events binds
//!     actions. It scrolls.
//!   - Structure: duplicate, wrap in a box, unwrap, indent, outdent, move up and
//!     down, delete, copy, cut, and paste (ZON text, so it works across windows).
//!
//! Inspector edits write straight to the live widget and are diffed back into the
//! document (`uidiff`), so the preview and the typing focus survive; structural
//! changes, undo, and redo rebuild the views.
//!
//! Shortcuts work while focus is anywhere in the builder: Ctrl+Z, Ctrl+Shift+Z or
//! Ctrl+Y, Ctrl+S, Ctrl+D (duplicate), Ctrl+C / X / V, Ctrl+G (wrap), Ctrl+Shift+G
//! (unwrap), Delete, Alt+Up / Down (move), Alt+Left / Right (outdent / indent).
//!
//! To embed it in a larger program (an IDE): create it under any parent node,
//! give it a `command_prefix` so several can coexist, watch `on_change` and
//! `modified()`, and load documents with `loadDocument`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ui_mod = @import("../core/ui.zig");
const Ui = ui_mod.Ui;
const event = @import("../core/event.zig");
const Handle = @import("../core/handle.zig").Handle;
const Length = @import("../core/length.zig").Length;
const geometry = @import("../core/geometry.zig");
const Color = geometry.Color;
const Rect = geometry.Rect;
const style_mod = @import("../core/style.zig");
const Style = style_mod.Style;
const Edges = style_mod.Edges;
const tree_mod = @import("../core/tree.zig");
const paint_ctx = @import("../core/paint_ctx.zig");
const PaintCtx = paint_ctx.PaintCtx;
const Button = @import("../widgets/button.zig").Button;
const Label = @import("../widgets/label.zig").Label;
const TextField = @import("../widgets/text_field.zig").TextField;
const ScrollView = @import("../widgets/scroll_view.zig").ScrollView;
const Select = @import("../widgets/select.zig").Select;
const SplitView = @import("../widgets/split_view.zig").SplitView;
const menu_mod = @import("../widgets/menu.zig");
const MenuBar = @import("../widgets/menu_bar.zig").MenuBar;
const TabPanel = @import("../widgets/tab_panel.zig").TabPanel;
const dock_mod = @import("../widgets/dock.zig");
const Dock = dock_mod.Dock;
const tree_view = @import("../widgets/tree_view.zig");
const TreeView = tree_view.TreeView;
const registry = @import("../widgets/registry.zig");
const form_mod = @import("../forms/form.zig");
const doc_mod = @import("../uidoc/doc.zig");
const edit = @import("../uidoc/edit.zig");
const load = @import("../uidoc/load.zig");
const diff = @import("../uidoc/diff.zig");
const zon = @import("../uidoc/zon.zig");
const interact = @import("interact.zig");

const DynForm = form_mod.Form(form_mod.Dynamic);

pub const Tab = enum { props, style, layout, events };

/// Called by Save with the document's ZON text (valid only during the call).
pub const SaveHook = struct {
    ctx: ?*anyopaque = null,
    call: *const fn (ctx: ?*anyopaque, text: []const u8) void,
};

/// One thing the Events tab can offer for an event: an existing handler.
pub const HandlerChoice = struct {
    /// Yours, handed back to `choose`.
    id: u32,
    /// The action name to store in the document.
    action: []const u8,
    /// What the menu shows (`App.onSave`).
    label: []const u8,
};

/// Where a `HandlerProvider` puts its candidates (strings are copied).
pub const HandlerList = struct {
    arena: Allocator,
    items: *std.ArrayListUnmanaged(HandlerChoice),

    pub fn add(self: *HandlerList, id: u32, action: []const u8, label: []const u8) void {
        const a = self.arena.dupe(u8, action) catch return;
        const l = self.arena.dupe(u8, label) catch return;
        self.items.append(self.arena, .{ .id = id, .action = a, .label = l }) catch {};
    }
};

/// What turns an event into a call, supplied by the environment around the
/// builder (the IDE): the handlers that fit an event, making one usable,
/// creating a new one, and showing one's source. Without it the Events tab is
/// a plain text field for the action name.
pub const HandlerProvider = struct {
    ctx: ?*anyopaque = null,
    /// Handlers that suit event `event_name` of a `widget_type` widget.
    list: *const fn (ctx: ?*anyopaque, widget_type: []const u8, event_name: []const u8, out: *HandlerList) void,
    /// Use candidate `id`; returns the action name to store (null: failed).
    choose: *const fn (ctx: ?*anyopaque, id: u32) ?[]const u8,
    /// Create a new handler for a node called `node_id`; returns its action name.
    create: *const fn (ctx: ?*anyopaque, node_id: []const u8, widget_type: []const u8, event_name: []const u8) ?[]const u8,
    /// Show the source of the handler for `action`; false if there is none.
    reveal: *const fn (ctx: ?*anyopaque, action: []const u8) bool,

    /// `HandlerProvider.bind(&service, Service)`: `Service` has methods `list`,
    /// `choose`, `create` and `reveal` taking `*Service` first.
    pub fn bind(ctx: anytype, comptime T: type) HandlerProvider {
        const Ptr = @TypeOf(ctx);
        const G = struct {
            fn list(c: ?*anyopaque, w: []const u8, e: []const u8, out: *HandlerList) void {
                T.list(@as(Ptr, @ptrCast(@alignCast(c.?))), w, e, out);
            }
            fn choose(c: ?*anyopaque, id: u32) ?[]const u8 {
                return T.choose(@as(Ptr, @ptrCast(@alignCast(c.?))), id);
            }
            fn create(c: ?*anyopaque, n: []const u8, w: []const u8, e: []const u8) ?[]const u8 {
                return T.create(@as(Ptr, @ptrCast(@alignCast(c.?))), n, w, e);
            }
            fn reveal(c: ?*anyopaque, a: []const u8) bool {
                return T.reveal(@as(Ptr, @ptrCast(@alignCast(c.?))), a);
            }
        };
        return .{ .ctx = @ptrCast(ctx), .list = G.list, .choose = G.choose, .create = G.create, .reveal = G.reveal };
    }
};

pub const Options = struct {
    save: ?SaveHook = null,
    /// Named callbacks the preview binds events to; unknown names are ignored.
    actions: ?*const load.Actions = null,
    inspector_width: f32 = 340,
    side_width: f32 = 230,
    /// Prefix of the commands this builder registers ("builder.undo", ...). Give
    /// each builder in a program its own.
    command_prefix: []const u8 = "builder",
    /// Called after the document changes (edit, undo, redo, load).
    on_change: ?event.Callback = null,
    /// Put the builder's panels (Toolbox, Outline, Preview, Inspector) in this
    /// dock, which the builder moves under its own toolbar, instead of making
    /// one. Call `Builder.arrange` to dock them in the default layout.
    dock: ?*Dock = null,
    /// Live inside a host's dock instead of owning the window: no menu bar, no
    /// frame around the dock (`parent` of `create` only anchors the builder's
    /// overlay); the toolbar becomes a "Designer" panel. Needs `dock`. Call
    /// `arrangeIn` to place the panels; panel-scoped shortcuts apply wherever
    /// focus is inside one of the builder's panels.
    embedded: bool = false,
    /// The Events tab's handler picker (see `HandlerProvider`).
    handlers: ?HandlerProvider = null,
};

const panel_bg = Color.rgb(34, 36, 41);
const panel_border = Color.rgb(64, 68, 76);
const host_bg = Color.rgb(24, 25, 29);
const frame_bg = Color.rgb(44, 46, 52);
const error_color = Color.rgb(224, 96, 96);
const select_color = Color.rgb(64, 140, 255);
const hover_color = Color.rgba(255, 255, 255, 110);
const drop_color = Color.rgb(255, 170, 40);

const Command = enum {
    undo,
    redo,
    save,
    delete,
    duplicate,
    copy,
    cut,
    paste,
    wrap,
    unwrap,
    up,
    down,
    indent,
    outdent,
    rename,
};
const command_count = @typeInfo(Command).@"enum".field_names.len;
const command_titles = [command_count][]const u8{
    "Undo", "Redo", "Save", "Delete node", "Duplicate", "Copy", "Cut", "Paste", "Wrap in box", "Unwrap", "Move up", "Move down", "Indent", "Outdent", "Rename id",
};

/// Most rectangles the preview overlay can occupy: hover and selection outlines
/// (four edges each), three handles, and a drop marker.
/// Most nodes that can be selected together.
const max_selected = 32;
const overlay_max = 4 + 4 + 3 + 1 + 4 * max_selected;

const Source = enum { preview, outline, palette };

const Press = struct {
    source: Source,
    /// The node being dragged (preview, outline) or 0 for a new one (palette).
    uid: u32,
    /// For palette drags: the type to create.
    type_name: []const u8 = "",
    sx: f32,
    sy: f32,
};

/// Dragging a split view's divider in the preview.
const SplitDrag = struct {
    uid: u32,
    sv: *SplitView,
    start_size: f32,
    start: f32,
};

const Resize = struct {
    handle: interact.ResizeHandle,
    uid: u32,
    start_w: f32,
    start_h: f32,
    sx: f32,
    sy: f32,
};

const AbsDrag = struct {
    uid: u32,
    start_left: f32,
    start_top: f32,
    sx: f32,
    sy: f32,
};

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
    /// The grid of palette buttons inside `palette`.
    palette_grid: Handle = Handle.invalid,
    outline: *TreeView = undefined,
    /// The outline's scroll view (the tree's own).
    outline_scroll: *ScrollView = undefined,
    /// Whether each document node's outline item was expanded, by uid; nodes
    /// not seen before start expanded.
    outline_expanded: std.AutoHashMapUnmanaged(u32, bool) = .empty,
    /// Document uid to outline item.
    outline_items: std.AutoHashMapUnmanaged(u32, u32) = .empty,
    syncing_outline: bool = false,
    /// The other selected nodes, besides `selected` (the primary one).
    extra: std.ArrayListUnmanaged(u32) = .empty,
    preview_host: Handle = Handle.invalid,
    preview_frame: Handle = Handle.invalid,
    inspector_tabs: Handle = Handle.invalid,
    /// The inspector's sections (props, style, layout, events) are panels of
    /// their own dock, so they can be tabbed, stacked or floated.
    inspector_dock: *Dock = undefined,
    section_panels: [4]*dock_mod.Panel = undefined,
    section_scrolls: [4]*ScrollView = undefined,
    /// Where the section being built puts its widgets.
    cur_content: Handle = Handle.invalid,
    status: *Label = undefined,
    buttons: [command_count]?*Button = @splat(null),
    /// Preview frame size in pixels; null grows to fill the preview area.
    frame_w: ?f32 = null,
    frame_h: ?f32 = null,

    inst: ?load.Instance = null,
    props_form: ?*DynForm = null,
    style_form: ?*DynForm = null,
    id_field: ?*TextField = null,
    text_field: ?*TextField = null,
    event_fields: std.ArrayListUnmanaged(*TextField) = .empty,
    /// The Events tab's menu: choices from the provider, and the event it is for.
    choice_arena: std.heap.ArenaAllocator = undefined,
    choices: []const HandlerChoice = &.{},
    choice_event: usize = 0,
    /// Embedded: the toolbar's panel.
    tools_panel: ?*dock_mod.Panel = null,
    layout_fields: [layout_field_count]?*TextField = @splat(null),

    built_version: u32 = 0,
    saved_version: u32 = 0,
    /// The change being synced came from the inspector (do not rebuild it).
    inspector_edit: bool = false,
    /// Inspector controls are being created: ignore their change notifications.
    building: bool = false,

    // Interaction state.
    hover: u32 = 0,
    press: ?Press = null,
    dragging: bool = false,
    drop: ?interact.Drop = null,
    last_overlay: [overlay_max]Rect = undefined,
    last_overlay_n: usize = 0,
    last_outline_marker: bool = false,
    resize: ?Resize = null,
    split_drag: ?SplitDrag = null,
    menu_bar: ?*MenuBar = null,
    /// The dock holding the panels below (the caller's, or one made here).
    dock: *Dock = undefined,
    owns_dock: bool = false,
    toolbox_panel: *dock_mod.Panel = undefined,
    outline_panel: *dock_mod.Panel = undefined,
    preview_panel: *dock_mod.Panel = undefined,
    inspector_panel: *dock_mod.Panel = undefined,
    /// The inline editor for a node's id (double-click in the outline).
    rename: ?*TextField = null,
    rename_uid: u32 = 0,
    /// The inline editor sets the node's `text` prop (preview) instead of its id (outline).
    rename_text: bool = false,
    /// Moving an absolutely positioned node: it follows the pointer by insets.
    abs_drag: ?AbsDrag = null,
    /// Counter for edit gestures (a resize drag): its edits merge into one step.
    gesture: u32 = 0,
    gesture_active: bool = false,
    /// A drag just ended on a button: ignore the click that follows it.
    swallow_click: bool = false,

    clip_text: ?[]u8 = null,
    command_names: [command_count][]u8 = @splat(&.{}),
    command_handles: [command_count]Handle = @splat(Handle.invalid),

    pub fn create(ui: *Ui, parent: Handle, initial: doc_mod.Doc, opts: Options) !*Builder {
        const self = try ui.gpa.create(Builder);
        errdefer ui.gpa.destroy(self);
        self.* = .{
            .ui = ui,
            .gpa = ui.gpa,
            .opts = opts,
            .editor = edit.Editor.init(ui.gpa, initial),
            .selected = initial.root.uid,
            .choice_arena = std.heap.ArenaAllocator.init(ui.gpa),
        };
        // The caller keeps ownership of `doc` if creation fails.
        errdefer {
            self.editor.undo_stack.deinit(self.gpa);
            self.editor.redo_stack.deinit(self.gpa);
            self.editor.batch_cmds.deinit(self.gpa);
        }
        try self.buildChrome(parent);
        errdefer _ = ui.tree.destroySubtree(self.root);
        errdefer if (self.menu_bar) |mb| mb.destroy();
        try self.registerCommands();
        errdefer self.unregisterCommands();
        try self.addMenus();
        if (self.owns_dock) try self.arrange();
        errdefer {
            self.clearInspector();
            if (self.inst) |*i| i.destroy();
            self.event_fields.deinit(self.gpa);
            self.outline_expanded.deinit(self.gpa);
            self.outline_items.deinit(self.gpa);
            self.extra.deinit(self.gpa);
        }
        try self.rebuildAll();
        return self;
    }

    pub fn destroy(self: *Builder) void {
        self.clearInspector();
        if (self.inst) |*i| i.destroy();
        self.inst = null;
        self.ui.closeMenu();
        if (self.menu_bar) |mb| mb.destroy();
        self.menu_bar = null;
        self.unregisterCommands();
        if (!self.owns_dock) {
            // The dock is the caller's: take our panels out of it first.
            for ([_]*dock_mod.Panel{ self.toolbox_panel, self.outline_panel, self.preview_panel, self.inspector_panel }) |p| self.dock.destroyPanel(p);
            if (self.tools_panel) |p| self.dock.destroyPanel(p);
        }
        _ = self.ui.tree.destroySubtree(self.root);
        self.event_fields.deinit(self.gpa);
        self.choice_arena.deinit();
        self.outline_expanded.deinit(self.gpa);
        self.outline_items.deinit(self.gpa);
        self.extra.deinit(self.gpa);
        if (self.clip_text) |t| self.gpa.free(t);
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

    /// True if the document differs from the last `markSaved` (or load).
    pub fn modified(self: *const Builder) bool {
        return self.editor.version != self.saved_version;
    }

    /// Record that the current document is what is on disk.
    pub fn markSaved(self: *Builder) void {
        self.saved_version = self.editor.version;
        self.updateButtons();
    }

    /// Replace the document (history is cleared). Takes ownership of `new_doc`.
    pub fn loadDocument(self: *Builder, new_doc: doc_mod.Doc) !void {
        self.clearInspector();
        if (self.inst) |*i| i.destroy();
        self.inst = null;
        self.press = null;
        self.dragging = false;
        self.drop = null;
        self.resize = null;
        self.hover = 0;
        self.editor.deinit();
        self.editor = edit.Editor.init(self.gpa, new_doc);
        self.selected = new_doc.root.uid;
        self.saved_version = 0;
        try self.rebuildAll();
    }

    // ---- chrome ----

    fn node(self: *Builder, parent: Handle, style: Style) !Handle {
        const h = try self.ui.tree.create(.{ .style = style });
        errdefer _ = self.ui.tree.destroySubtree(h);
        try self.ui.tree.appendChild(parent, h);
        return h;
    }

    /// Style a dock panel's content node as one of the builder's boxes.
    fn skin(self: *Builder, h: Handle, style: Style, bg: Color) void {
        const n = self.ui.tree.get(h).?;
        n.style = style;
        n.visual = .{ .background = bg, .border_color = panel_border, .border_width = 1, .radius = 4 };
    }

    /// Dock the four panels in the default layout (toolbox over outline on the
    /// left, preview in the middle, inspector on the right). Done for you when
    /// the builder made its own dock.
    /// Dock the panels in a host's dock: the preview as a tab of `center` (a panel
    /// in the middle group; null: a group of its own), the inspector, outline and
    /// toolbox in a column on the right, and the toolbar above the preview.
    pub fn arrangeIn(self: *Builder, center: ?*dock_mod.Panel) !void {
        const d = self.dock;
        try d.dockTab(self.preview_panel, center);
        try d.dockRoot(self.inspector_panel, .right, self.opts.inspector_width);
        try d.dockSplit(self.outline_panel, self.inspector_panel, .top, palette_height + 240);
        try d.dockSplit(self.toolbox_panel, self.outline_panel, .top, palette_height);
        if (self.tools_panel) |tp| try d.dockSplit(tp, self.preview_panel, .top, 104);
    }

    /// Show or hide all of the builder's panels (embedded: when a UI document is or is not being designed).
    pub fn setPanelsVisible(self: *Builder, visible: bool) void {
        const all = [_]?*dock_mod.Panel{ self.tools_panel, self.toolbox_panel, self.outline_panel, self.preview_panel, self.inspector_panel };
        for (all) |maybe| {
            const p = maybe orelse continue;
            if (visible) {
                if (p.state == .hidden) self.dock.showPanel(p) catch {};
            } else if (p.state != .hidden) self.dock.closePanel(p);
        }
    }

    pub fn arrange(self: *Builder) !void {
        const d = self.dock;
        try d.dockTab(self.preview_panel, null);
        try d.dockSplit(self.inspector_panel, self.preview_panel, .right, self.opts.inspector_width);
        try d.dockSplit(self.outline_panel, self.preview_panel, .left, self.opts.side_width);
        try d.dockSplit(self.toolbox_panel, self.outline_panel, .top, palette_height);
    }

    fn panel(self: *Builder, parent: Handle, style: Style, bg: Color) !Handle {
        const h = try self.node(parent, style);
        self.ui.tree.get(h).?.visual = .{ .background = bg, .border_color = panel_border, .border_width = 1, .radius = 4 };
        return h;
    }

    /// Width of the dividers between the main regions (the gap they replace).
    const split_gap: f32 = 8;
    /// The palette's starting height: its title and five rows of buttons.
    const palette_height: f32 = 210;

    const tool_button_style: Style = .{ .padding = Edges.xy(7, 3), .shrink = 0 };

    fn toolbarButton(self: *Builder, parent: Handle, text: []const u8, cmd: Command) !void {
        const b = try self.ui.add(Button, parent, .{ .text = text, .variant = .flat, .style = tool_button_style });
        b.props.on_click = event.Callback.bind(self, onToolbar);
        self.ui.tree.get(b.node).?.user_data = @ptrFromInt(@as(usize, @intFromEnum(cmd)) + 1);
        self.buttons[@intFromEnum(cmd)] = b;
    }

    /// The Undo/Redo/... buttons and the frame size presets.
    fn buildToolbar(self: *Builder, bar: Handle) !void {
        const ui = self.ui;
        const order = [_]struct { []const u8, Command }{
            .{ "Undo", .undo },   .{ "Redo", .redo },       .{ "Dup", .duplicate }, .{ "Wrap", .wrap },    .{ "Unwrap", .unwrap },
            .{ "In", .indent },   .{ "Out", .outdent },     .{ "Up", .up },         .{ "Down", .down },    .{ "Delete", .delete },
            .{ "Cut", .cut },     .{ "Copy", .copy },       .{ "Paste", .paste },   .{ "Save", .save },
        };
        for (order) |o| try self.toolbarButton(bar, o[0], o[1]);
        _ = try self.node(bar, .{ .width = Length.px(12), .shrink = 0 });
        _ = try ui.add(Label, bar, .{ .text = "Frame:" });
        const presets = [_][]const u8{ "Fill", "360x640", "800x600", "1280x720" };
        for (presets, 0..) |p, i| {
            const b = try ui.add(Button, bar, .{ .text = p, .variant = .flat, .style = tool_button_style });
            b.props.on_click = event.Callback.bind(self, onFramePreset);
            ui.tree.get(b.node).?.user_data = @ptrFromInt(i + 1);
        }
    }

    fn buildChrome(self: *Builder, parent: Handle) !void {
        const ui = self.ui;
        if (self.opts.embedded) {
            // A zero-size anchor at the window's origin: the inline editors position against it.
            self.root = try self.node(parent, .{ .position = .absolute, .inset = .{ .left = Length.px(0), .top = Length.px(0) } });
            errdefer _ = ui.tree.destroySubtree(self.root);
        } else {
            self.root = try self.node(parent, .{ .direction = .column, .gap = Length.px(8), .padding = Edges.all(8), .grow = 1 });
            errdefer _ = ui.tree.destroySubtree(self.root);
            ui.tree.get(self.root).?.role = .panel;

            self.menu_bar = try MenuBar.create(ui, self.root, .{});
            errdefer {
                self.menu_bar.?.destroy();
                self.menu_bar = null;
            }
            const bar = try self.node(self.root, .{ .direction = .row, .gap = Length.px(4), .align_items = .center });
            try self.buildToolbar(bar);
        }

        // The regions are dock panels: Toolbox, Outline, Preview and Inspector.
        // (`arrange` docks them side by side; the user can rearrange them.)
        if (self.opts.dock) |d| {
            self.dock = d;
            if (!self.opts.embedded) {
                try ui.tree.appendChild(self.root, d.node);
                ui.tree.get(d.node).?.style.grow = 1;
            }
        } else {
            self.dock = try Dock.create(ui, self.root, .{ .style = .{ .grow = 1 } });
            self.owns_dock = true;
        }
        const dock = self.dock;
        self.toolbox_panel = try dock.addPanel("Toolbox");
        self.outline_panel = try dock.addPanel("Outline");
        self.preview_panel = try dock.addPanel("Preview");
        self.inspector_panel = try dock.addPanel("Inspector");
        if (self.opts.embedded) {
            const tp = try dock.addPanel("Designer");
            self.tools_panel = tp;
            self.skin(tp.content, .{ .direction = .column, .gap = Length.px(4), .padding = Edges.all(6), .grow = 1 }, panel_bg);
            // The status line goes above the toolbar: a wrapping row's height is only its first line's.
            self.status = try ui.add(Label, tp.content, .{ .style = .{ .shrink = 0 } });
            const bar = try self.node(tp.content, .{ .direction = .row, .gap = Length.px(4), .align_items = .center, .wrap = true, .shrink = 0 });
            try self.buildToolbar(bar);
        }

        self.palette = self.toolbox_panel.content;
        self.skin(self.palette, .{ .direction = .column, .gap = Length.px(2), .padding = Edges.all(8), .grow = 1 }, panel_bg);
        const outline_panel = self.outline_panel.content;
        self.skin(outline_panel, .{ .direction = .column, .gap = Length.px(4), .padding = Edges.all(8), .grow = 1 }, panel_bg);
        _ = try ui.add(Label, outline_panel, .{ .text = "Outline", .size = 15 });
        self.outline = try ui.add(TreeView, outline_panel, .{
            .style = .{ .grow = 1 },
            .label = "Outline",
            .on_select = event.Callback.bind(self, onOutlineSelect),
            .on_activate = event.Callback.bind(self, onOutlineActivate),
            .activate_toggles = false,
            .multi_select = true,
        });
        for ([_]event.EventKind{ .pointer_down, .pointer_move, .pointer_up }) |kind| {
            try ui.tree.addListener(self.outline.node, .{ .kind = kind, .callback = event.Callback.bind(self, onOutlinePointer) });
        }
        self.outline_scroll = self.outline.scroll;
        self.outline_scroll.overlay = tree_mod.PaintHook.bind(self, paintOutlineOverlay);

        self.preview_host = self.preview_panel.content;
        self.skin(self.preview_host, .{ .direction = .column, .padding = Edges.all(12), .grow = 1 }, host_bg);
        {
            const h = ui.tree.get(self.preview_host).?;
            h.flags.clip_children = true;
            h.flags.focusable = true;
            h.role = .panel;
            h.overlay_hook = tree_mod.PaintHook.bind(self, paintPreviewOverlay);
            for ([_]event.EventKind{ .pointer_down, .pointer_move, .pointer_up, .click }) |kind| {
                try ui.tree.addListener(self.preview_host, .{ .kind = kind, .capture = true, .callback = event.Callback.bind(self, onPreviewPointer) });
            }
            try ui.tree.addListener(self.preview_host, .{ .kind = .pointer_leave, .callback = event.Callback.bind(self, onPreviewLeave) });
        }
        try ui.tree.setLabel(self.preview_host, "Preview");
        self.preview_frame = try self.node(self.preview_host, .{ .direction = .column, .shrink = 0 });
        ui.tree.get(self.preview_frame).?.visual = .{ .background = frame_bg };
        try self.applyFrameSize();

        const inspector = self.inspector_panel.content;
        self.skin(inspector, .{ .direction = .column, .gap = Length.px(6), .padding = Edges.all(8), .grow = 1 }, panel_bg);
        self.inspector_tabs = try self.node(inspector, .{ .direction = .column, .gap = Length.px(6), .shrink = 0 });
        self.inspector_dock = try Dock.create(ui, inspector, .{ .style = .{ .grow = 1 } });
        const section_names = [4][]const u8{ "Props", "Style", "Layout", "Events" };
        for (section_names, 0..) |name, i| {
            const sp = try self.inspector_dock.addPanel(name);
            ui.tree.get(sp.content).?.style.padding = Edges.all(2);
            self.section_panels[i] = sp;
            self.section_scrolls[i] = try ui.add(ScrollView, sp.content, .{
                .style = .{ .grow = 1 },
                .content_style = .{ .direction = .column, .gap = Length.px(6), .padding = .{ .right = Length.px(10) } },
            });
        }
        // Tabs of one group to begin with; drag one to stack or float it.
        try self.inspector_dock.dockTab(self.section_panels[0], null);
        for (self.section_panels[1..]) |sp| try self.inspector_dock.dockTab(sp, self.section_panels[0]);
        self.inspector_dock.activatePanel(self.section_panels[0]);
        if (self.tools_panel == null) self.status = try ui.add(Label, self.root, .{});

        _ = try ui.add(Label, self.palette, .{ .text = "Add (click or drag)", .size = 15 });
        // The buttons scroll when the toolbox is made small.
        const palette_scroll = try ui.add(ScrollView, self.palette, .{ .style = .{ .grow = 1 }, .content_style = .{ .direction = .column, .padding = .{ .right = Length.px(10) } } });
        self.palette_grid = try self.node(palette_scroll.contentNode(), .{ .grid_columns = 2, .gap = Length.px(4), .shrink = 0 });
        for (registry.widgets, 0..) |w, i| try self.paletteButton(w.name, i + 1);
        try self.paletteButton(doc_mod.box_type, registry.widgets.len + 1);
    }

    fn applyFrameSize(self: *Builder) !void {
        const n = self.ui.tree.get(self.preview_frame).?;
        n.style.width = if (self.frame_w) |w| Length.px(w) else .auto;
        n.style.height = if (self.frame_h) |h| Length.px(h) else .auto;
        n.style.grow = if (self.frame_h == null) 1 else 0;
        n.style.align_self = if (self.frame_w == null) null else .start;
        self.ui.tree.markDirty(self.preview_frame, .{ .layout = true, .paint = true });
    }

    /// Fix the preview frame to `w` by `h` pixels, or let it fill the area.
    pub fn setFrame(self: *Builder, w: ?f32, h: ?f32) void {
        self.frame_w = w;
        self.frame_h = h;
        self.applyFrameSize() catch {};
    }

    fn paletteButton(self: *Builder, name: []const u8, tag: usize) !void {
        const b = try self.ui.add(Button, self.palette_grid, .{ .text = name, .variant = .flat, .text_align = .start, .style = .{ .padding = Edges.xy(8, 4) } });
        b.props.on_click = event.Callback.bind(self, onPalette);
        self.ui.tree.get(b.node).?.user_data = @ptrFromInt(tag);
        try self.ui.tree.addListener(b.node, .{ .kind = .pointer_down, .callback = event.Callback.bind(self, onPalettePointer) });
        try self.ui.tree.addListener(b.node, .{ .kind = .pointer_move, .callback = event.Callback.bind(self, onPalettePointer) });
        try self.ui.tree.addListener(b.node, .{ .kind = .pointer_up, .callback = event.Callback.bind(self, onPalettePointer) });
    }

    fn tagOf(self: *Builder, h: Handle) usize {
        const n = self.ui.tree.get(h) orelse return 0;
        return @intFromPtr(n.user_data);
    }

    // ---- commands and shortcuts ----

    const shortcut_table = [_]struct { []const u8, Command }{
        .{ "ctrl+z", .undo },       .{ "ctrl+shift+z", .redo }, .{ "ctrl+y", .redo },      .{ "ctrl+s", .save },
        .{ "ctrl+d", .duplicate },  .{ "ctrl+c", .copy },       .{ "ctrl+x", .cut },       .{ "ctrl+v", .paste },
        .{ "ctrl+g", .wrap },       .{ "ctrl+shift+g", .unwrap }, .{ "delete", .delete },  .{ "alt+up", .up },
        .{ "alt+down", .down },     .{ "alt+right", .indent },  .{ "alt+left", .outdent }, .{ "f2", .rename },
    };

    fn registerCommands(self: *Builder) !void {
        var done: usize = 0;
        errdefer {
            for (0..done) |i| {
                _ = self.ui.commands.unregister(self.command_handles[i]);
                self.gpa.free(self.command_names[i]);
                self.command_names[i] = &.{};
            }
        }
        inline for (0..command_count) |i| {
            const name = try std.fmt.allocPrint(self.gpa, "{s}.{s}", .{ self.opts.command_prefix, @tagName(@as(Command, @enumFromInt(i))) });
            errdefer self.gpa.free(name);
            self.command_handles[i] = try self.ui.registerCommand(name, .{
                .title = command_titles[i],
                .run = event.Callback.bind(self, onCommand),
            });
            self.command_names[i] = name;
            done += 1;
        }
        // Panel scope: they work while focus is anywhere in this builder and
        // leave other windows' keys alone.
        for (shortcut_table) |s| {
            if (self.opts.embedded) {
                // The panels are not under `root`: bind to each of them.
                for ([_]*dock_mod.Panel{ self.toolbox_panel, self.outline_panel, self.preview_panel, self.inspector_panel }) |p| {
                    self.ui.bindShortcut(s[0], self.command_names[@intFromEnum(s[1])], .panel, p.content) catch |e| {
                        std.log.warn("builder: cannot bind {s}: {s}", .{ s[0], @errorName(e) });
                    };
                }
            } else self.ui.bindShortcut(s[0], self.command_names[@intFromEnum(s[1])], .panel, self.root) catch |e| {
                std.log.warn("builder: cannot bind {s}: {s}", .{ s[0], @errorName(e) });
            };
        }
    }

    fn unregisterCommands(self: *Builder) void {
        for (0..command_count) |i| {
            if (self.command_names[i].len > 0) {
                _ = self.ui.commands.unregister(self.command_handles[i]);
                self.gpa.free(self.command_names[i]);
                self.command_names[i] = &.{};
            }
        }
    }

    /// Run a command by its short name's index (shortcuts arrive as `command`
    /// events carrying the full name).
    fn onCommand(self: *Builder, ev: *event.Event) void {
        for (self.command_names, 0..) |name, i| {
            if (std.mem.eql(u8, name, ev.text)) return self.run(@enumFromInt(i));
        }
    }

    fn onToolbar(self: *Builder, ev: *event.Event) void {
        const tag = self.tagOf(ev.current);
        if (tag == 0) return;
        self.run(@enumFromInt(tag - 1));
    }

    fn run(self: *Builder, cmd: Command) void {
        switch (cmd) {
            .undo => self.undo(),
            .redo => self.redo(),
            .save => self.save(),
            .delete => self.deleteSelected(),
            .duplicate => self.duplicateSelected(),
            .copy => self.copySelected(),
            .cut => self.cutSelected(),
            .paste => self.pasteClipboard(),
            .wrap => self.wrapSelected(),
            .unwrap => self.unwrapSelected(),
            .up => self.moveSelected(-1),
            .down => self.moveSelected(1),
            .indent => self.runStructural(.indent),
            .outdent => self.runStructural(.outdent),
            .rename => self.beginRename(self.selected),
        }
    }

    // ---- menus ----

    fn cmdItem(self: *Builder, label: []const u8, cmd: Command) menu_mod.Item {
        return .{ .label = label, .command = self.command_names[@intFromEnum(cmd)] };
    }

    const separator: menu_mod.Item = .{ .separator = true };

    fn addMenus(self: *Builder) !void {
        const mb = self.menu_bar orelse return;
        try mb.addMenu("File", &.{self.cmdItem("Save", .save)}, null);
        try mb.addMenu("Edit", &.{
            self.cmdItem("Undo", .undo),
            self.cmdItem("Redo", .redo),
            separator,
            self.cmdItem("Cut", .cut),
            self.cmdItem("Copy", .copy),
            self.cmdItem("Paste", .paste),
            separator,
            self.cmdItem("Duplicate", .duplicate),
            self.cmdItem("Delete", .delete),
            separator,
            self.cmdItem("Rename id", .rename),
        }, null);
        try self.addViewMenu(mb);
        try mb.addMenu("Structure", &.{
            self.cmdItem("Wrap in box", .wrap),
            self.cmdItem("Unwrap", .unwrap),
            separator,
            self.cmdItem("Indent", .indent),
            self.cmdItem("Outdent", .outdent),
            self.cmdItem("Move up", .up),
            self.cmdItem("Move down", .down),
        }, null);
    }

    /// View: one item per dock panel, to show or hide it.
    fn addViewMenu(self: *Builder, mb: *MenuBar) !void {
        var items: [16]menu_mod.Item = undefined;
        var n: usize = 0;
        for (self.dock.panels.items) |p| {
            if (n == items.len) break;
            items[n] = .{ .label = p.title };
            n += 1;
        }
        if (n < items.len) {
            items[n] = .{ .separator = true };
            n += 1;
        }
        for (self.inspector_dock.panels.items) |p| {
            if (n == items.len) break;
            items[n] = .{ .label = p.title };
            n += 1;
        }
        try mb.addMenu("View", items[0..n], menu_mod.PickHook.bind(self, onViewPick));
    }

    fn onViewPick(self: *Builder, index: usize) void {
        var d = self.dock;
        var i = index;
        if (i >= d.panels.items.len) {
            // Past the main panels and the separator: the inspector's sections.
            i -= d.panels.items.len + 1;
            d = self.inspector_dock;
            if (i >= d.panels.items.len) return;
        }
        const p = d.panels.items[i];
        if (p.state == .hidden) d.showPanel(p) catch {} else d.closePanel(p);
    }

    /// The right-click menu for the selected node: the common commands, then
    /// a submenu of the widget's own actions (`registry.Info.actions`).
    fn openContextMenu(self: *Builder, x: f32, y: f32) void {
        var items: [18]menu_mod.Item = undefined;
        var n: usize = 0;
        const common = [_]menu_mod.Item{
            self.cmdItem("Cut", .cut),
            self.cmdItem("Copy", .copy),
            self.cmdItem("Paste", .paste),
            self.cmdItem("Duplicate", .duplicate),
            self.cmdItem("Delete", .delete),
            separator,
            self.cmdItem("Wrap in box", .wrap),
            self.cmdItem("Unwrap", .unwrap),
            self.cmdItem("Indent", .indent),
            self.cmdItem("Outdent", .outdent),
            self.cmdItem("Move up", .up),
            self.cmdItem("Move down", .down),
            separator,
            self.cmdItem("Rename id", .rename),
        };
        for (common) |it| {
            items[n] = it;
            n += 1;
        }
        var labels: [8][96]u8 = undefined;
        var subs: [8]menu_mod.Item = undefined;
        var sub_n: usize = 0;
        const sel = self.selectedNode();
        if (self.live(sel)) |l| {
            if (l.info) |info| {
                for (info.actions, 0..) |act, i| {
                    if (sub_n == subs.len) break;
                    const on = self.actionIsOn(l, act);
                    const label = if (on and act.label_when_on.len > 0) act.label_when_on else act.label;
                    const text = std.fmt.bufPrint(&labels[i], "{s}", .{label}) catch label;
                    subs[sub_n] = .{ .label = text, .checked = act.checkable and on, .on_pick = menu_mod.PickHook.bind(self, onWidgetAction) };
                    sub_n += 1;
                }
                if (sub_n > 0) {
                    items[n] = separator;
                    n += 1;
                    items[n] = .{ .label = info.name, .submenu = subs[0..sub_n] };
                    n += 1;
                }
            }
        }
        self.ui.openMenu(items[0..n], x, y, .{}) catch |e| self.updateStatus(e);
    }

    fn actionIsOn(self: *Builder, l: Live, act: anytype) bool {
        const v = registry.getProp(self.ui, l.h, act.toggle) catch return false;
        return v == .bool and v.bool;
    }

    /// A widget-specific menu action: flip its bool prop, then record it.
    fn onWidgetAction(self: *Builder, index: usize) void {
        const n = self.selectedNode();
        const l = self.live(n) orelse return;
        const info = l.info orelse return;
        if (index >= info.actions.len) return;
        const act = info.actions[index];
        const on = self.actionIsOn(l, act);
        registry.setProp(self.ui, l.h, act.toggle, .{ .bool = !on }) catch |e| return self.updateStatus(e);
        var ev: event.Event = .{ .kind = .click };
        self.onInspectorEdit(&ev);
        self.rebuildInspector() catch |e| self.updateStatus(e);
    }

    // ---- renaming ----

    /// Edit a node's id in place over its outline row.
    pub fn beginRename(self: *Builder, uid: u32) void {
        const item = self.outline_items.get(uid) orelse return;
        const row = self.outline.rowRect(item) orelse return;
        const n = self.doc().find(uid) orelse return;
        self.openInlineEditor(uid, false, row, n.id, "id", "Node id");
    }

    /// Edit a button's or label's text in place over the preview.
    pub fn beginTextEdit(self: *Builder, uid: u32) void {
        const n = self.doc().find(uid) orelse return;
        const inst = self.inst orelse return;
        const h = inst.handleOf(uid) orelse return;
        const info = registry.infoOf(self.ui, h) orelse return;
        if (!hasTextProp(info)) return;
        const rect = self.ui.tree.absoluteRect(h) orelse return;
        const current = if (n.props.field("text")) |t| (if (t == .string) t.string else "") else "";
        self.openInlineEditor(uid, true, .{ .x = rect.x - 4, .y = rect.y, .w = @max(rect.w + 8, 100), .h = @max(rect.h, 24) }, current, "text", "Widget text");
    }

    fn hasTextProp(info: *const registry.Info) bool {
        for (info.props.fields) |f| {
            if (std.mem.eql(u8, f.name, "text")) return true;
        }
        return false;
    }

    fn openInlineEditor(self: *Builder, uid: u32, text_prop: bool, row: Rect, initial: []const u8, placeholder: []const u8, label: []const u8) void {
        self.cancelRename();
        const root_r = self.ui.tree.absoluteRect(self.root) orelse return;
        const tf = self.ui.add(TextField, self.root, .{
            .text = initial,
            .placeholder = placeholder,
            .label = label,
            .style = .{
                .position = .absolute,
                .width = Length.px(@max(row.w, 140)),
                .height = Length.px(row.h + 4),
                .inset = .{ .left = Length.px(row.x - root_r.x), .top = Length.px(row.y - root_r.y - 2) },
            },
            .on_submit = event.Callback.bind(self, onRenameSubmit),
        }) catch return;
        self.rename_text = text_prop;
        self.ui.tree.addListener(tf.node, .{ .kind = .key_down, .callback = event.Callback.bind(self, onRenameKey) }) catch {};
        self.ui.tree.addListener(tf.node, .{ .kind = .focus_out, .callback = event.Callback.bind(self, onRenameBlur) }) catch {};
        self.rename = tf;
        self.rename_uid = uid;
        self.ui.setFocus(tf.node);
        tf.editor.selectAll();
    }

    fn endRename(self: *Builder) ?*TextField {
        const tf = self.rename orelse return null;
        self.rename = null;
        return tf;
    }

    fn cancelRename(self: *Builder) void {
        const tf = self.endRename() orelse return;
        _ = self.ui.tree.destroySubtree(tf.node);
    }

    /// Apply the typed id to the node and close the editor.
    fn commitRename(self: *Builder) void {
        const tf = self.endRename() orelse return;
        if (self.rename_text) {
            self.commitTextEdit(tf);
            return;
        }
        const before = self.editor.version;
        const failed = if (self.editor.setId(self.rename_uid, tf.text())) |_| false else |e| blk: {
            self.updateStatus(e);
            break :blk true;
        };
        _ = self.ui.tree.destroySubtree(tf.node);
        if (failed) return;
        self.markInspectorEdit(before);
        self.rebuildInspector() catch |e| self.updateStatus(e);
    }

    /// Write the typed text into the node's `props.text`; the preview is rebuilt.
    fn commitTextEdit(self: *Builder, tf: *TextField) void {
        defer _ = self.ui.tree.destroySubtree(tf.node);
        const n = self.doc().find(self.rename_uid) orelse return;
        const props = zon.withField(self.doc().alloc(), n.props, "text", .{ .string = self.doc().alloc().dupe(u8, tf.text()) catch return }) catch |e| return self.updateStatus(e);
        self.editor.setRecord(n.uid, .props, props) catch |e| return self.updateStatus(e);
        self.editor.breakCoalescing();
        self.sync();
    }

    fn onRenameSubmit(self: *Builder, _: *event.Event) void {
        self.commitRename();
        self.ui.setFocus(self.outline.node);
    }

    fn onRenameBlur(self: *Builder, _: *event.Event) void {
        self.commitRename();
    }

    fn onRenameKey(self: *Builder, ev: *event.Event) void {
        if (ev.key != .escape) return;
        ev.markHandled();
        self.cancelRename();
        self.ui.setFocus(self.outline.node);
    }

    fn onOutlineActivate(self: *Builder, _: *event.Event) void {
        const item = self.outline.out.activated_item;
        if (item == tree_view.no_item) return;
        const uid: u32 = @intCast(self.outline.userData(item));
        self.select(uid);
        self.beginRename(uid);
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
        var k: usize = 0;
        for (self.extra.items) |u| {
            if (self.doc().find(u) != null and u != self.selected) {
                self.extra.items[k] = u;
                k += 1;
            }
        }
        self.extra.shrinkRetainingCapacity(k);
        self.clearInspector();
        if (self.inst) |*i| i.destroy();
        self.inst = null;
        self.inst = try load.instantiate(self.ui, self.preview_frame, self.doc(), .{ .actions = self.opts.actions, .strict = false });
        // Tag the live nodes with their document uid so a click can find its node.
        var it = self.inst.?.by_uid.iterator();
        while (it.next()) |e| {
            if (self.ui.tree.get(e.value_ptr.*)) |n| n.user_data = @ptrFromInt(e.key_ptr.*);
        }
        self.applyRootDefaults();
        try self.rebuildOutline();
        try self.rebuildInspector();
        self.updateStatus(null);
        self.updateButtons();
        self.repaintOverlays();
    }

    /// The document root plays the window's role in the preview: it fills the
    /// frame unless the document says otherwise, so `fill` heights inside it
    /// have something to fill. Edits to the root diff against the same base.
    fn applyRootDefaults(self: *Builder) void {
        const inst = self.inst orelse return;
        const root = self.doc().root;
        if (root.style.field("grow") != null) return;
        if (self.ui.tree.get(inst.root)) |n| n.style.grow = 1;
    }

    /// The strips the preview overlay paints for the box `r`: its outline (and
    /// resize handles for a selection). Big boxes only damage their edges.
    fn outlineStrips(r: Rect, handles: bool, out: []Rect, n: *usize) void {
        const t: f32 = 6; // stroke plus slack
        const strips = [4]Rect{
            .{ .x = r.x - t, .y = r.y - t, .w = r.w + 2 * t, .h = 2 * t },
            .{ .x = r.x - t, .y = r.bottom() - t, .w = r.w + 2 * t, .h = 2 * t },
            .{ .x = r.x - t, .y = r.y + t, .w = 2 * t, .h = @max(r.h - 2 * t, 0) },
            .{ .x = r.right() - t, .y = r.y + t, .w = 2 * t, .h = @max(r.h - 2 * t, 0) },
        };
        for (strips) |s| {
            out[n.*] = s;
            n.* += 1;
        }
        if (handles) {
            inline for (.{ interact.ResizeHandle.right, interact.ResizeHandle.bottom, interact.ResizeHandle.corner }) |hd| {
                const hr = interact.handleRect(r, hd);
                out[n.*] = .{ .x = hr.x - 3, .y = hr.y - 3, .w = hr.w + 6, .h = hr.h + 6 };
                n.* += 1;
            }
        }
    }

    /// The areas the preview overlay paints now: only those (and where it was
    /// before) need repainting when hover, selection, or the drop marker changes.
    fn overlayRects(self: *Builder, out: *[overlay_max]Rect) usize {
        var n: usize = 0;
        const inst = self.inst orelse return 0;
        if (self.hover != 0 and self.hover != self.selected) {
            if (inst.handleOf(self.hover)) |h| {
                if (self.ui.tree.absoluteRect(h)) |r| outlineStrips(r, false, out, &n);
            }
        }
        if (self.selectionRect()) |r| outlineStrips(r, self.selected != self.doc().root.uid and self.extra.items.len == 0, out, &n);
        for (self.extra.items) |uid| {
            if (inst.handleOf(uid)) |h| {
                if (self.ui.tree.absoluteRect(h)) |r| outlineStrips(r, false, out, &n);
            }
        }
        if (self.drop) |d| {
            out[n] = .{ .x = d.indicator.x - 4, .y = d.indicator.y - 4, .w = d.indicator.w + 8, .h = d.indicator.h + 8 };
            n += 1;
        }
        return n;
    }

    fn repaintOverlays(self: *Builder) void {
        // What was drawn before is still on screen: repaint it, and where the
        // overlay goes now.
        for (self.last_overlay[0..self.last_overlay_n]) |r| self.ui.tree.invalidateRect(self.preview_host, r);
        var now: [overlay_max]Rect = undefined;
        const n = self.overlayRects(&now);
        for (now[0..n]) |r| self.ui.tree.invalidateRect(self.preview_host, r);
        self.last_overlay = now;
        self.last_overlay_n = n;
        // The outline's drop marker lives in its own panel.
        if (self.dragging or self.drop != null or self.last_outline_marker) {
            self.ui.tree.markDirty(self.outline_scroll.node, .{ .paint = true });
            self.last_outline_marker = self.dragging and self.drop != null;
        }
    }

    /// Rebuild the outline's items from the document, keeping what the user
    /// expanded and collapsed.
    fn rebuildOutline(self: *Builder) !void {
        var it = self.outline_items.iterator();
        while (it.next()) |e| try self.outline_expanded.put(self.gpa, e.key_ptr.*, self.outline.isExpanded(e.value_ptr.*));
        self.syncing_outline = true;
        defer self.syncing_outline = false;
        self.outline.clear();
        self.outline_items.clearRetainingCapacity();
        try self.outlineItems(self.doc().root, tree_view.no_item);
        self.syncOutlineSelection();
    }

    fn outlineItems(self: *Builder, n: *doc_mod.Node, parent: u32) anyerror!void {
        var buf: [96]u8 = undefined;
        const text = std.fmt.bufPrint(&buf, "{s}{s}{s}", .{ n.type_name, if (n.id.len > 0) " #" else "", n.id }) catch n.type_name;
        const item = try self.outline.addItem(parent, text);
        self.outline.setUserData(item, n.uid);
        try self.outline_items.put(self.gpa, n.uid, item);
        self.outline.setExpanded(item, self.outline_expanded.get(n.uid) orelse true);
        for (n.children.items) |c| try self.outlineItems(c, item);
    }

    /// Show the document's selection in the outline.
    fn syncOutlineSelection(self: *Builder) void {
        const primary = self.outline_items.get(self.selected) orelse return;
        const was = self.syncing_outline;
        self.syncing_outline = true;
        defer self.syncing_outline = was;
        var items: [max_selected]u32 = undefined;
        var k: usize = 0;
        for (self.extra.items) |uid| {
            if (self.outline_items.get(uid)) |it| {
                items[k] = it;
                k += 1;
            }
        }
        self.outline.setSelection(items[0..k], primary);
    }

    fn clearInspector(self: *Builder) void {
        if (self.props_form) |f| f.destroy();
        if (self.style_form) |f| f.destroy();
        self.props_form = null;
        self.style_form = null;
        self.id_field = null;
        self.text_field = null;
        self.event_fields.clearRetainingCapacity();
        self.layout_fields = @splat(null);
        self.clearChildren(self.inspector_tabs);
        for (self.section_scrolls) |sc| self.clearChildren(sc.contentNode());
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

    /// The node the inspector section being built adds to.
    fn content(self: *Builder) Handle {
        return self.cur_content;
    }

    fn fieldRow(self: *Builder, label: []const u8) !Handle {
        const row = try self.node(self.content(), .{ .direction = .row, .gap = Length.px(8), .align_items = .center });
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
        const title = if (self.extra.items.len > 0)
            std.fmt.bufPrint(&title_buf, "{s} (#{d}) + {d} more", .{ n.type_name, n.uid, self.extra.items.len }) catch n.type_name
        else
            std.fmt.bufPrint(&title_buf, "{s} (#{d})", .{ n.type_name, n.uid }) catch n.type_name;
        _ = try ui.add(Label, self.inspector_tabs, .{ .text = title, .size = 15 });

        const id_row = try self.node(self.inspector_tabs, .{ .direction = .row, .gap = Length.px(8), .align_items = .center });
        _ = try ui.add(Label, id_row, .{ .text = "id", .style = .{ .width = Length.px(70), .shrink = 0 } });
        self.id_field = try ui.add(TextField, id_row, .{
            .text = n.id,
            .placeholder = "name for lookup",
            .style = .{ .grow = 1 },
            .on_change = event.Callback.bind(self, onIdChange),
        });

        const lv = self.live(n);
        inline for (.{ Tab.props, Tab.style, Tab.layout, Tab.events }) |t| {
            self.cur_content = self.section_scrolls[@intFromEnum(t)].contentNode();
            try self.buildSection(t, n, lv);
        }
    }

    fn buildSection(self: *Builder, tab: Tab, n: *doc_mod.Node, lv: ?Live) !void {
        const ui = self.ui;
        switch (tab) {
            .props => {
                const l = lv orelse return;
                const info = l.info orelse {
                    _ = try ui.add(Label, self.content(), .{ .text = if (std.mem.eql(u8, n.type_name, doc_mod.box_type)) "A box has no props; use Style and Layout." else "Unknown widget type." });
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
                const f = try DynForm.createDynamic(ui, self.content(), info.props, info.propsPtr(l.w.?), .{ .footer = false, .label_width = 110 });
                f.notify = event.Callback.bind(self, onInspectorEdit);
                self.props_form = f;
            },
            .style => {
                const l = lv orelse return;
                const tn = ui.tree.get(l.h).?;
                const f = try DynForm.createDynamic(ui, self.content(), registry.styleSchema(), &tn.style, .{ .footer = false, .label_width = 110 });
                f.notify = event.Callback.bind(self, onInspectorEdit);
                self.style_form = f;
            },
            .layout => if (lv) |l| try self.buildLayoutTab(n, l),
            .events => {
                const l = lv orelse return;
                const info = l.info orelse {
                    _ = try ui.add(Label, self.content(), .{ .text = "Boxes have no events." });
                    return;
                };
                if (info.events.len == 0) {
                    _ = try ui.add(Label, self.content(), .{ .text = "This widget has no events." });
                    return;
                }
                for (info.events, 0..) |ev_name, event_index| {
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
                    if (self.opts.handlers != null) {
                        const pick = try ui.add(Button, row, .{ .text = "...", .variant = .flat, .style = tool_button_style, .on_click = event.Callback.bind(self, onHandlerMenu) });
                        ui.tree.get(pick.node).?.user_data = @ptrFromInt(event_index + 1);
                        const go = try ui.add(Button, row, .{ .text = "Go", .variant = .flat, .style = tool_button_style, .on_click = event.Callback.bind(self, onHandlerGo) });
                        ui.tree.get(go.node).?.user_data = @ptrFromInt(event_index + 1);
                    }
                }
            },
        }
    }

    // ---- the Layout tab ----

    const layout_field_count = 14;
    const LayoutField = enum(u8) { gap, padding, margin, width_px, height_px, grow, shrink, grid_columns, grid_span, grid_row_span, inset_left, inset_top, inset_right, inset_bottom };
    const LayoutChoice = enum(u8) { layout_mode, direction, align_items, justify, width_mode, height_mode, align_self, position, wrap };

    /// A drop-down for one of the Layout tab's choices.
    fn layoutButtonGroup(self: *Builder, label: []const u8, group: LayoutChoice, names: []const []const u8, current: usize) !void {
        const row = try self.fieldRow(label);
        const sel = try self.ui.add(Select, row, .{
            .items = names,
            .selected = @intCast(current),
            .style = .{ .grow = 1 },
            .on_change = event.Callback.bind(self, onLayoutSelect),
        });
        self.ui.tree.get(sel.node).?.user_data = @ptrFromInt(@as(usize, @intFromEnum(group)) << 8);
    }

    fn layoutField(self: *Builder, label: []const u8, which: LayoutField, value: f32) !void {
        const row = try self.fieldRow(label);
        var buf: [32]u8 = undefined;
        const text = std.fmt.bufPrint(&buf, "{d}", .{value}) catch "0";
        self.layout_fields[@intFromEnum(which)] = try self.ui.add(TextField, row, .{
            .text = text,
            .style = .{ .grow = 1 },
            .on_change = event.Callback.bind(self, onLayoutField),
        });
    }

    /// An inset field: blank means auto (that side is free).
    fn insetField(self: *Builder, label: []const u8, which: LayoutField, value: Length) !void {
        const row = try self.fieldRow(label);
        var buf: [32]u8 = undefined;
        const text = switch (value) {
            .pixels => |p| std.fmt.bufPrint(&buf, "{d}", .{p}) catch "",
            else => "",
        };
        self.layout_fields[@intFromEnum(which)] = try self.ui.add(TextField, row, .{
            .text = text,
            .placeholder = "auto",
            .style = .{ .grow = 1 },
            .on_change = event.Callback.bind(self, onLayoutField),
        });
    }

    fn lengthMode(l: Length) usize {
        return switch (l) {
            .auto => 0,
            .fill => 1,
            .fit => 2,
            .pixels, .percent => 3,
        };
    }

    fn lengthPx(l: Length) f32 {
        return switch (l) {
            .pixels => |p| p,
            else => 0,
        };
    }

    fn buildLayoutTab(self: *Builder, n: *doc_mod.Node, l: Live) !void {
        const st = self.ui.tree.get(l.h).?.style;
        if (interact.isContainer(n.type_name)) {
            _ = try self.ui.add(Label, self.content(), .{ .text = "Container", .size = 15 });
            try self.layoutButtonGroup("layout", .layout_mode, &.{ "row", "column", "grid" }, if (st.grid_columns > 0) 2 else @intFromEnum(st.direction));
            if (st.grid_columns > 0) try self.layoutField("grid columns", .grid_columns, @floatFromInt(st.grid_columns));
            try self.layoutField("gap", .gap, lengthPx(st.gap));
            try self.layoutField("padding", .padding, lengthPx(st.padding.left));
            try self.layoutButtonGroup("align", .align_items, &.{ "start", "center", "end", "stretch" }, @intFromEnum(st.align_items));
            try self.layoutButtonGroup("justify", .justify, &.{ "start", "center", "end" }, @min(@intFromEnum(st.justify), 2));
            try self.layoutButtonGroup("wrap", .wrap, &.{ "no", "yes" }, @intFromBool(st.wrap));
        }
        if (n.parent) |p| {
            const pl = self.live(p);
            if (pl != null and self.ui.tree.get(pl.?.h).?.style.grid_columns > 0) {
                try self.layoutField("grid span", .grid_span, @floatFromInt(st.grid_span));
                try self.layoutField("grid row span", .grid_row_span, @floatFromInt(st.grid_row_span));
            }
        }
        if (n != self.doc().root) {
            _ = try self.ui.add(Label, self.content(), .{ .text = "Position", .size = 15 });
            try self.layoutButtonGroup("mode", .position, &.{ "flow", "absolute" }, @intFromEnum(st.position));
            if (st.position == .absolute) {
                try self.insetField("left", .inset_left, st.inset.left);
                try self.insetField("top", .inset_top, st.inset.top);
                try self.insetField("right", .inset_right, st.inset.right);
                try self.insetField("bottom", .inset_bottom, st.inset.bottom);
            }
        }
        _ = try self.ui.add(Label, self.content(), .{ .text = "Size", .size = 15 });
        try self.layoutButtonGroup("width", .width_mode, &.{ "auto", "fill", "fit", "px" }, lengthMode(st.width));
        try self.layoutField("width px", .width_px, lengthPx(st.width));
        try self.layoutButtonGroup("height", .height_mode, &.{ "auto", "fill", "fit", "px" }, lengthMode(st.height));
        try self.layoutField("height px", .height_px, lengthPx(st.height));
        try self.layoutField("grow", .grow, st.grow);
        try self.layoutField("shrink", .shrink, st.shrink);
        try self.layoutField("margin", .margin, lengthPx(st.margin.left));
        const self_idx: usize = if (st.align_self) |a| @as(usize, @intFromEnum(a)) + 1 else 0;
        try self.layoutButtonGroup("align self", .align_self, &.{ "auto", "start", "center", "end", "stretch" }, self_idx);
    }

    fn onLayoutSelect(self: *Builder, ev: *event.Event) void {
        if (self.building) return;
        const tn = self.ui.tree.get(ev.current) orelse return;
        const sel: *Select = @ptrCast(@alignCast(tn.widget orelse return));
        const group: LayoutChoice = @enumFromInt(self.tagOf(ev.current) >> 8);
        self.applyLayoutChoice(group, sel.props.selected);
    }

    fn applyLayoutChoice(self: *Builder, group: LayoutChoice, choice: usize) void {
        var buf: [max_selected]u32 = undefined;
        for (self.selection(&buf)) |uid| {
            const n = self.doc().find(uid) orelse continue;
            const l = self.live(n) orelse continue;
            const st = &self.ui.tree.get(l.h).?.style;
            switch (group) {
                .layout_mode => if (choice == 2) {
                    if (st.grid_columns == 0) st.grid_columns = 2;
                } else {
                    st.grid_columns = 0;
                    st.direction = @enumFromInt(choice);
                },
                .direction => st.direction = @enumFromInt(choice),
                .align_items => st.align_items = @enumFromInt(choice),
                .justify => st.justify = @enumFromInt(choice),
                .width_mode => st.width = modeLength(choice, st.width),
                .height_mode => st.height = modeLength(choice, st.height),
                .align_self => st.align_self = if (choice == 0) null else @enumFromInt(choice - 1),
                .position => st.position = @enumFromInt(choice),
                .wrap => st.wrap = choice == 1,
            }
            self.commitLiveStyle(l.h);
        }
        // The panel may change shape (absolute insets, grid span): rebuild it.
        self.rebuildInspector() catch |e| self.updateStatus(e);
    }

    fn modeLength(choice: usize, cur: Length) Length {
        return switch (choice) {
            0 => .auto,
            1 => .fill,
            2 => .fit,
            else => switch (cur) {
                .pixels => cur,
                else => Length.px(100),
            },
        };
    }

    /// A Layout-tab text field changed: apply that field to every selected node.
    fn onLayoutField(self: *Builder, ev: *event.Event) void {
        if (self.building) return;
        var only: ?usize = null;
        for (self.layout_fields, 0..) |maybe, i| {
            if (maybe) |f| {
                if (f.node.eql(ev.current)) only = i;
            }
        }
        var buf: [max_selected]u32 = undefined;
        for (self.selection(&buf)) |uid| {
            const n = self.doc().find(uid) orelse continue;
            const l = self.live(n) orelse continue;
            const st = &self.ui.tree.get(l.h).?.style;
            for (self.layout_fields, 0..) |maybe, i| {
                const f = maybe orelse continue;
                if (only != null and only.? != i) continue;
                applyLayoutField(st, @enumFromInt(i), f);
            }
            self.commitLiveStyle(l.h);
        }
    }

    fn applyLayoutField(st: *Style, which: LayoutField, f: *TextField) void {
        if (@intFromEnum(which) >= @intFromEnum(LayoutField.inset_left)) {
            const text = std.mem.trim(u8, f.text(), " ");
            const len: Length = if (text.len == 0) .auto else Length.px(std.fmt.parseFloat(f32, text) catch return);
            switch (which) {
                .inset_left => st.inset.left = len,
                .inset_top => st.inset.top = len,
                .inset_right => st.inset.right = len,
                .inset_bottom => st.inset.bottom = len,
                else => {},
            }
            return;
        }
        const v = std.fmt.parseFloat(f32, std.mem.trim(u8, f.text(), " ")) catch return;
        if (!std.math.isFinite(v)) return;
        switch (which) {
            .gap => if (lengthPx(st.gap) != v) {
                st.gap = Length.px(v);
            },
            .padding => if (lengthPx(st.padding.left) != v) {
                st.padding = Edges.all(v);
            },
            .margin => if (lengthPx(st.margin.left) != v) {
                st.margin = Edges.all(v);
            },
            .width_px => if (lengthPx(st.width) != v and st.width != .fill and st.width != .fit and st.width != .auto) {
                st.width = Length.px(v);
            },
            .height_px => if (lengthPx(st.height) != v and st.height != .fill and st.height != .fit and st.height != .auto) {
                st.height = Length.px(v);
            },
            .grow => st.grow = v,
            .shrink => st.shrink = v,
            .grid_columns => if (v >= 0 and v <= 64 and @as(f32, @floatFromInt(st.grid_columns)) != v) {
                st.grid_columns = @intFromFloat(v);
            },
            .grid_span => if (v >= 1 and v <= 64 and @as(f32, @floatFromInt(st.grid_span)) != v) {
                st.grid_span = @intFromFloat(v);
            },
            .grid_row_span => if (v >= 1 and v <= 64 and @as(f32, @floatFromInt(st.grid_row_span)) != v) {
                st.grid_row_span = @intFromFloat(v);
            },
            else => {},
        }
    }

    /// The live node's style changed: relayout, and bring the document's style
    /// record in line (one coalesced undo step per field).
    fn commitLiveStyle(self: *Builder, h: Handle) void {
        self.ui.tree.markDirty(h, .{ .layout = true, .paint = true });
        // The live node knows its document node (its uid is the node's user data).
        const n = self.doc().find(@intCast(self.tagOf(h))) orelse self.selectedNode();
        var scratch = std.heap.ArenaAllocator.init(self.gpa);
        defer scratch.deinit();
        var default_style: Style = .{};
        if (self.inst) |inst| {
            if (inst.root.eql(h)) default_style.grow = 1;
        }
        const live_style = &self.ui.tree.get(h).?.style;
        const rec = (diff.diff(scratch.allocator(), registry.styleSchema(), live_style, &default_style) catch |e| return self.updateStatus(e)) orelse zon.Value{ .record = &.{} };
        const before = self.editor.version;
        self.editor.setRecordIn(n.uid, .style, rec, if (self.gesture_active) self.gesture else 0) catch |e| return self.updateStatus(e);
        self.markInspectorEdit(before);
        self.repaintOverlays();
    }

    // ---- status ----

    fn updateStatus(self: *Builder, err: ?anyerror) void {
        var buf: [200]u8 = undefined;
        const text: []const u8 = blk: {
            if (err) |e| break :blk std.fmt.bufPrint(&buf, "Error: {s}", .{@errorName(e)}) catch "Error";
            if (self.inst) |inst| {
                if (inst.problems.items.len > 0) {
                    break :blk std.fmt.bufPrint(&buf, "{d} problem(s): {s}", .{ inst.problems.items.len, inst.problems.items[0].message }) catch "problems";
                }
            }
            break :blk if (self.modified()) "Modified" else "Ready";
        };
        if (!std.mem.eql(u8, self.status.props.text.bytes, text)) self.status.setText(text) catch {};
        self.status.props.color = if (err != null or (self.inst != null and self.inst.?.problems.items.len > 0)) error_color else Color.transparent;
        self.ui.tree.markDirty(self.status.node, .{ .paint = true });
    }

    fn updateButtons(self: *Builder) void {
        const n = self.selectedNode();
        const is_root = n == self.doc().root;
        const idx = n.indexInParent();
        const siblings: usize = if (n.parent) |p| p.children.items.len else 0;
        const can_indent = blk: {
            const i = idx orelse break :blk false;
            if (i == 0) break :blk false;
            const prev = n.parent.?.children.items[i - 1];
            break :blk interact.isContainer(prev.type_name);
        };
        const multi = self.extra.items.len > 0;
        var enabled = [command_count]bool{
            self.editor.canUndo(),
            self.editor.canRedo(),
            true,
            !is_root,
            !is_root,
            true,
            !is_root,
            true,
            !is_root,
            !is_root and n.children.items.len > 0,
            idx != null and idx.? > 0,
            idx != null and idx.? + 1 < siblings,
            can_indent,
            n.parent != null and n.parent.?.parent != null,
            true,
        };
        if (multi) {
            // Only deleting and duplicating act on a whole selection.
            for (0..command_count) |i| {
                const c: Command = @enumFromInt(i);
                enabled[i] = switch (c) {
                    .undo, .redo, .save, .delete, .duplicate, .copy, .cut, .paste => enabled[i],
                    // Moving and wrapping need the nodes to share a parent.
                    .wrap, .up, .down => self.commonParent() != null,
                    else => false,
                };
            }
        }
        for (self.buttons, 0..) |maybe, i| {
            if (maybe) |b| b.setEnabled(enabled[i]);
        }
        // Menu items follow their commands.
        for (self.command_names, 0..) |name, i| {
            if (name.len > 0) _ = self.ui.setCommandEnabled(name, enabled[i]);
        }
    }

    /// Bring the views up to date with the document.
    fn sync(self: *Builder) void {
        if (self.editor.version == self.built_version) return;
        defer if (self.opts.on_change) |cb| {
            var ev: event.Event = .{ .kind = .command };
            cb.invoke(&ev);
        };
        if (self.inspector_edit) {
            self.inspector_edit = false;
            self.built_version = self.editor.version;
            self.rebuildOutline() catch |e| self.updateStatus(e);
            self.updateButtons();
            self.updateStatus(null);
            return;
        }
        self.rebuildAll() catch |e| self.updateStatus(e);
    }

    // ---- operations (also what the buttons and shortcuts call) ----

    pub fn select(self: *Builder, uid: u32) void {
        if (self.doc().find(uid) == null or (uid == self.selected and self.extra.items.len == 0)) return;
        self.editor.breakCoalescing();
        self.selected = uid;
        self.extra.clearRetainingCapacity();
        self.revealInTabs(uid);
        self.syncOutlineSelection();
        self.rebuildInspector() catch |e| self.updateStatus(e);
        self.updateButtons();
        self.repaintOverlays();
    }

    /// Select several nodes; `primary` is the one the inspector shows.
    pub fn selectMany(self: *Builder, primary: u32, others: []const u32) void {
        if (self.doc().find(primary) == null) return;
        self.editor.breakCoalescing();
        self.selected = primary;
        self.extra.clearRetainingCapacity();
        for (others) |u| {
            if (u == primary or self.doc().find(u) == null or self.extra.items.len + 1 >= max_selected) continue;
            self.extra.append(self.gpa, u) catch {};
        }
        self.afterSelectionChange();
    }

    /// Ctrl-click: add `uid` to the selection (and make it primary), or remove it.
    pub fn toggleInSelection(self: *Builder, uid: u32) void {
        if (self.doc().find(uid) == null) return;
        self.editor.breakCoalescing();
        if (uid == self.selected) {
            self.selected = self.extra.pop() orelse return;
        } else if (std.mem.indexOfScalar(u32, self.extra.items, uid)) |i| {
            _ = self.extra.orderedRemove(i);
        } else {
            if (self.extra.items.len + 1 >= max_selected) return;
            self.extra.append(self.gpa, self.selected) catch return;
            self.selected = uid;
        }
        self.afterSelectionChange();
    }

    /// Show the tabs that contain `uid` (selecting a node on a hidden tab page
    /// brings that page forward).
    fn revealInTabs(self: *Builder, uid: u32) void {
        const inst = self.inst orelse return;
        var child = self.doc().find(uid) orelse return;
        while (child.parent) |p| : (child = p) {
            if (!std.mem.eql(u8, p.type_name, "tab_view")) continue;
            const h = inst.handleOf(p.uid) orelse continue;
            const tn = self.ui.tree.get(h) orelse continue;
            if (tn.widget_type != ui_mod.typeTag(TabPanel)) continue;
            const tabs: *TabPanel = @ptrCast(@alignCast(tn.widget orelse continue));
            if (child.indexInParent()) |i| tabs.setActive(i);
        }
    }

    fn afterSelectionChange(self: *Builder) void {
        self.revealInTabs(self.selected);
        self.syncOutlineSelection();
        self.rebuildInspector() catch |e| self.updateStatus(e);
        self.updateButtons();
        self.repaintOverlays();
    }

    /// The selected nodes, primary first.
    fn selection(self: *Builder, buf: *[max_selected]u32) []const u32 {
        buf[0] = self.selected;
        var n: usize = 1;
        for (self.extra.items) |u| {
            if (n == buf.len) break;
            buf[n] = u;
            n += 1;
        }
        return buf[0..n];
    }

    pub fn selectionCount(self: *const Builder) usize {
        return 1 + self.extra.items.len;
    }

    /// Bring an inspector section forward (when it is a tab of a group).
    pub fn setTab(self: *Builder, tab: Tab) void {
        self.tab = tab;
        self.inspector_dock.activatePanel(self.section_panels[@intFromEnum(tab)]);
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
        const pane_style = ".{ .direction = .column, .gap = 6, .padding = .{ .left = 8, .top = 8, .right = 8, .bottom = 8 }, .width = .fill, .height = .fill }";
        const box_style = ".{ .direction = .column, .gap = 6, .padding = .{ .left = 8, .top = 8, .right = 8, .bottom = 8 }, .width = .fill, .height = .fill }";
        /// Area widgets start filling their parent.
        const area_style = ".{ .width = .fill, .height = .fill }";
    };

    /// Add a node of `type_name` inside the selected box, or after the selected
    /// widget, and select it.
    pub fn addWidget(self: *Builder, type_name: []const u8) void {
        const sel = self.selectedNode();
        var parent = sel;
        var index = sel.children.items.len;
        if (!interact.isContainer(sel.type_name)) {
            parent = sel.parent orelse sel;
            index = if (sel.indexInParent()) |i| i + 1 else parent.children.items.len;
        }
        self.addWidgetAt(type_name, parent.uid, index);
    }

    /// Add a node of `type_name` under `parent` at `index` and select it.
    pub fn addWidgetAt(self: *Builder, type_name: []const u8, parent: u32, index: usize) void {
        self.addWidgetInner(type_name, parent, index) catch |e| self.updateStatus(e);
    }

    fn addWidgetInner(self: *Builder, type_name: []const u8, parent: u32, index: usize) !void {
        // A widget with starting children is one undo step.
        const multi = std.mem.eql(u8, type_name, "split_view") or std.mem.eql(u8, type_name, "tab_view") or std.mem.eql(u8, type_name, "dock");
        if (multi) self.editor.beginBatch();
        errdefer if (multi) self.editor.abortBatch();
        const n = try self.editor.addNode(parent, index, type_name);
        // Starting values belong to the creation step: set them before any other edit.
        const a = self.doc().alloc();
        if (std.mem.eql(u8, type_name, "label")) n.props = try zon.parse(a, defaults.label_props, null);
        if (std.mem.eql(u8, type_name, "button")) n.props = try zon.parse(a, defaults.button_props, null);
        if (std.mem.eql(u8, type_name, doc_mod.box_type)) n.style = try zon.parse(a, defaults.box_style, null);
        for ([_][]const u8{ "scroll_view", "code_editor", "canvas", "tab_view", "dock", "tree_view" }) |area| {
            if (std.mem.eql(u8, type_name, area)) n.style = try zon.parse(a, defaults.area_style, null);
        }
        if (std.mem.eql(u8, type_name, "tree_view")) n.props = try zon.parse(a, ".{ .items = \"Parent\\n  Child 1\\n  Child 2\" }", null);
        if (std.mem.eql(u8, type_name, "menu_bar")) n.props = try zon.parse(a, ".{ .menus = \"File\\n  New\\n  Open\\nEdit\\n  Undo\" }", null);
        if (std.mem.eql(u8, type_name, "dock")) {
            n.props = try zon.parse(a, ".{ .titles = \"Panel 1\\nPanel 2\" }", null);
            // Each panel starts as a box that fills it.
            for (0..2) |_| {
                const page = try self.editor.addNode(n.uid, n.children.items.len, doc_mod.box_type);
                page.style = try zon.parse(a, defaults.pane_style, null);
            }
        }
        if (std.mem.eql(u8, type_name, "tab_view")) {
            n.props = try zon.parse(a, ".{ .titles = \"Tab 1\\nTab 2\" }", null);
            // Each tab starts with a box page that fills it.
            for (0..2) |_| {
                const page = try self.editor.addNode(n.uid, n.children.items.len, doc_mod.box_type);
                page.style = try zon.parse(a, defaults.pane_style, null);
            }
        }
        if (std.mem.eql(u8, type_name, "split_view")) {
            n.style = try zon.parse(a, defaults.area_style, null);
            // A split view always has two panes: start them as boxes.
            for (0..2) |_| {
                const pane = try self.editor.addNode(n.uid, n.children.items.len, doc_mod.box_type);
                pane.style = try zon.parse(a, defaults.pane_style, null);
            }
        }
        if (multi) try self.editor.endBatch();
        self.editor.breakCoalescing();
        self.selected = n.uid;
        self.sync();
    }

    /// The selected nodes that are not the root and have no selected ancestor
    /// (an operation on them covers their descendants).
    fn selectionRoots(self: *Builder, out: *[max_selected]u32) []const u32 {
        var all_buf: [max_selected]u32 = undefined;
        const all = self.selection(&all_buf);
        var k: usize = 0;
        for (all) |uid| {
            const n = self.doc().find(uid) orelse continue;
            if (n.parent == null) continue;
            var covered = false;
            var p = n.parent;
            while (p) |pn| : (p = pn.parent) {
                if (std.mem.indexOfScalar(u32, all, pn.uid) != null) covered = true;
            }
            if (covered) continue;
            out[k] = uid;
            k += 1;
        }
        return out[0..k];
    }

    fn deleteMany(self: *Builder) void {
        var buf: [max_selected]u32 = undefined;
        const uids = self.selectionRoots(&buf);
        if (uids.len == 0) return;
        const parent = self.doc().find(uids[0]).?.parent.?;
        self.editor.beginBatch();
        for (uids) |uid| {
            self.editor.removeNode(uid) catch |e| {
                self.editor.abortBatch();
                return self.updateStatus(e);
            };
        }
        self.editor.endBatch() catch |e| return self.updateStatus(e);
        self.editor.breakCoalescing();
        self.selected = parent.uid;
        self.extra.clearRetainingCapacity();
        self.sync();
    }

    fn duplicateMany(self: *Builder) void {
        var buf: [max_selected]u32 = undefined;
        const uids = self.selectionRoots(&buf);
        if (uids.len == 0) return;
        var copies: [max_selected]u32 = undefined;
        self.editor.beginBatch();
        for (uids, 0..) |uid, i| {
            const c = self.editor.duplicateNode(uid) catch |e| {
                self.editor.abortBatch();
                return self.updateStatus(e);
            };
            copies[i] = c.uid;
        }
        self.editor.endBatch() catch |e| return self.updateStatus(e);
        self.editor.breakCoalescing();
        self.selected = copies[uids.len - 1];
        self.extra.clearRetainingCapacity();
        for (copies[0 .. uids.len - 1]) |u| self.extra.append(self.gpa, u) catch {};
        self.sync();
    }

    pub fn deleteSelected(self: *Builder) void {
        if (self.extra.items.len > 0) return self.deleteMany();
        const n = self.selectedNode();
        const parent = n.parent orelse return;
        self.editor.removeNode(n.uid) catch |e| return self.updateStatus(e);
        self.selected = parent.uid;
        self.sync();
    }

    pub fn duplicateSelected(self: *Builder) void {
        if (self.extra.items.len > 0) return self.duplicateMany();
        const n = self.selectedNode();
        const copy = self.editor.duplicateNode(n.uid) catch |e| return self.updateStatus(e);
        self.selected = copy.uid;
        self.sync();
    }

    pub fn wrapSelected(self: *Builder) void {
        if (self.extra.items.len > 0) return self.wrapMany();
        const n = self.selectedNode();
        const w = self.editor.wrapNode(n.uid, doc_mod.box_type) catch |e| return self.updateStatus(e);
        w.style = zon.parse(self.doc().alloc(), defaults.box_style, null) catch w.style;
        self.selected = w.uid;
        self.sync();
    }

    pub fn unwrapSelected(self: *Builder) void {
        const n = self.selectedNode();
        const first_child = if (n.children.items.len > 0) n.children.items[0].uid else return;
        self.editor.unwrapNode(n.uid) catch |e| return self.updateStatus(e);
        self.selected = first_child;
        self.sync();
    }

    const Structural = enum { indent, outdent };

    fn runStructural(self: *Builder, which: Structural) void {
        const n = self.selectedNode();
        (switch (which) {
            .indent => self.editor.indentNode(n.uid),
            .outdent => self.editor.outdentNode(n.uid),
        }) catch |e| return self.updateStatus(e);
        self.sync();
    }

    /// Move the selected node among its siblings by `delta` places.
    /// Move every selected node one place up or down among its siblings.
    fn moveMany(self: *Builder, delta: i32) void {
        const parent = self.commonParent() orelse return self.updateStatusText("The selected nodes need the same parent to move together");
        var buf: [max_selected]u32 = undefined;
        const roots = self.orderedRoots(&buf);
        self.editor.beginBatch();
        const order_len = roots.len;
        var step: usize = 0;
        while (step < order_len) : (step += 1) {
            // Up: first to last; down: last to first, so blocks keep their shape.
            const uid = if (delta < 0) roots[step] else roots[order_len - 1 - step];
            const n = self.doc().find(uid).?;
            const idx: i64 = @intCast(n.indexInParent().?);
            const target = idx + delta;
            if (target < 0 or target >= parent.children.items.len) continue;
            if (std.mem.indexOfScalar(u32, roots, parent.children.items[@intCast(target)].uid) != null) continue; // blocked by a selected neighbor
            self.editor.moveNode(uid, parent.uid, @intCast(target)) catch |e| {
                self.editor.abortBatch();
                return self.updateStatus(e);
            };
        }
        self.editor.endBatch() catch |e| return self.updateStatus(e);
        self.editor.breakCoalescing();
        self.sync();
    }

    /// Put the selected siblings into one new box, where the first one was.
    fn wrapMany(self: *Builder) void {
        const parent = self.commonParent() orelse return self.updateStatusText("The selected nodes need the same parent to be wrapped together");
        var buf: [max_selected]u32 = undefined;
        const roots = self.orderedRoots(&buf);
        const first = self.doc().find(roots[0]).?.indexInParent().?;
        self.editor.beginBatch();
        const w = self.editor.addNode(parent.uid, first, doc_mod.box_type) catch |e| {
            self.editor.abortBatch();
            return self.updateStatus(e);
        };
        for (roots, 0..) |u, i| {
            self.editor.moveNode(u, w.uid, i) catch |e| {
                self.editor.abortBatch();
                return self.updateStatus(e);
            };
        }
        self.editor.endBatch() catch |e| return self.updateStatus(e);
        w.style = zon.parse(self.doc().alloc(), defaults.box_style, null) catch w.style;
        self.editor.breakCoalescing();
        self.selected = w.uid;
        self.extra.clearRetainingCapacity();
        self.sync();
    }

    pub fn moveSelected(self: *Builder, delta: i32) void {
        if (self.extra.items.len > 0) return self.moveMany(delta);
        const n = self.selectedNode();
        const parent = n.parent orelse return;
        const idx: i64 = @intCast(n.indexInParent().?);
        const target = idx + delta;
        if (target < 0 or target >= parent.children.items.len) return;
        self.editor.moveNode(n.uid, parent.uid, @intCast(target)) catch |e| return self.updateStatus(e);
        self.sync();
    }

    /// Move node `uid` to `parent` at `index` (see `Editor.moveNode`).
    pub fn moveTo(self: *Builder, uid: u32, parent: u32, index: usize) void {
        self.editor.moveNode(uid, parent, index) catch |e| return self.updateStatus(e);
        self.selected = uid;
        self.sync();
    }

    pub fn save(self: *Builder) void {
        const hook = self.opts.save orelse return;
        const text = self.toZon(self.gpa) catch |e| return self.updateStatus(e);
        defer self.gpa.free(text);
        hook.call(hook.ctx, text);
        self.markSaved();
        self.updateStatus(null);
    }

    // ---- clipboard ----

    /// The selection's top-most nodes in document order.
    fn orderedRoots(self: *Builder, out: *[max_selected]u32) []const u32 {
        var buf: [max_selected]u32 = undefined;
        const roots = self.selectionRoots(&buf);
        var k: usize = 0;
        self.collectInOrder(self.doc().root, roots, out, &k);
        return out[0..k];
    }

    fn collectInOrder(self: *Builder, n: *doc_mod.Node, set: []const u32, out: *[max_selected]u32, k: *usize) void {
        if (std.mem.indexOfScalar(u32, set, n.uid) != null and k.* < out.len) {
            out[k.*] = n.uid;
            k.* += 1;
            return;
        }
        for (n.children.items) |c| self.collectInOrder(c, set, out, k);
    }

    /// The common parent of the selection's top-most nodes, or null if they differ.
    fn commonParent(self: *Builder) ?*doc_mod.Node {
        var buf: [max_selected]u32 = undefined;
        const roots = self.orderedRoots(&buf);
        if (roots.len == 0) return null;
        const p = self.doc().find(roots[0]).?.parent orelse return null;
        for (roots[1..]) |u| {
            if (self.doc().find(u).?.parent != p) return null;
        }
        return p;
    }

    pub fn copySelected(self: *Builder) void {
        var text: []u8 = undefined;
        if (self.extra.items.len > 0) {
            var buf: [max_selected]u32 = undefined;
            const roots = self.orderedRoots(&buf);
            if (roots.len == 0) return;
            var arena = std.heap.ArenaAllocator.init(self.gpa);
            defer arena.deinit();
            const vals = arena.allocator().alloc(zon.Value, roots.len) catch |e| return self.updateStatus(e);
            for (roots, vals) |u, *v| v.* = self.doc().nodeToValue(self.doc().find(u).?) catch |e| return self.updateStatus(e);
            text = zon.render(self.gpa, .{ .list = vals }) catch |e| return self.updateStatus(e);
        } else {
            const n = self.selectedNode();
            const v = self.doc().nodeToValue(n) catch |e| return self.updateStatus(e);
            text = zon.render(self.gpa, v) catch |e| return self.updateStatus(e);
        }
        if (self.clip_text) |old| self.gpa.free(old);
        self.clip_text = text;
        if (self.ui.clipboard) |cb| cb.set(cb.ctx, text);
    }

    pub fn cutSelected(self: *Builder) void {
        self.copySelected();
        self.deleteSelected();
    }

    /// Paste the clipboard's ZON node into the selected box (or after the
    /// selected widget).
    pub fn pasteClipboard(self: *Builder) void {
        var from_system: ?[]u8 = null;
        defer if (from_system) |t| self.gpa.free(t);
        if (self.ui.clipboard) |cb| from_system = cb.get(cb.ctx, self.gpa);
        const text = from_system orelse (self.clip_text orelse return);
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        const v = zon.parse(arena.allocator(), text, null) catch return self.updateStatusText("The clipboard does not hold a UI node");
        const sel = self.selectedNode();
        var parent = sel;
        var index = sel.children.items.len;
        if (!interact.isContainer(sel.type_name)) {
            parent = sel.parent orelse sel;
            index = if (sel.indexInParent()) |i| i + 1 else parent.children.items.len;
        }
        // A list of nodes (a multi-selection was copied) pastes them all.
        if (v == .list and v.list.len > 0) {
            var pasted: [max_selected]u32 = undefined;
            var k: usize = 0;
            self.editor.beginBatch();
            for (v.list) |item| {
                if (k == pasted.len) break;
                const pn = self.editor.pasteValue(parent.uid, index + k, item) catch {
                    self.editor.abortBatch();
                    return self.updateStatusText("The clipboard does not hold UI nodes");
                };
                pasted[k] = pn.uid;
                k += 1;
            }
            self.editor.endBatch() catch |e| return self.updateStatus(e);
            self.editor.breakCoalescing();
            self.selected = pasted[k - 1];
            self.extra.clearRetainingCapacity();
            for (pasted[0 .. k - 1]) |u| self.extra.append(self.gpa, u) catch {};
            self.sync();
            return;
        }
        const pasted = self.editor.pasteValue(parent.uid, index, v) catch return self.updateStatusText("The clipboard does not hold a UI node");
        self.editor.breakCoalescing();
        self.selected = pasted.uid;
        self.extra.clearRetainingCapacity();
        self.sync();
    }

    fn updateStatusText(self: *Builder, text: []const u8) void {
        self.status.setText(text) catch {};
        self.status.props.color = error_color;
        self.ui.tree.markDirty(self.status.node, .{ .paint = true });
    }

    // ---- toolbar and panel handlers ----

    fn onFramePreset(self: *Builder, ev: *event.Event) void {
        switch (self.tagOf(ev.current)) {
            1 => self.setFrame(null, null),
            2 => self.setFrame(360, 640),
            3 => self.setFrame(800, 600),
            4 => self.setFrame(1280, 720),
            else => {},
        }
    }

    fn onPalette(self: *Builder, ev: *event.Event) void {
        if (self.swallow_click) {
            self.swallow_click = false;
            return;
        }
        const tag = self.tagOf(ev.current);
        if (tag == 0) return;
        self.addWidget(self.paletteType(tag));
    }

    fn paletteType(_: *Builder, tag: usize) []const u8 {
        return if (tag <= registry.widgets.len) registry.widgets[tag - 1].name else doc_mod.box_type;
    }

    fn onOutlineSelect(self: *Builder, _: *event.Event) void {
        if (self.syncing_outline) return;
        const primary_item = self.outline.selected();
        if (primary_item == tree_view.no_item) return;
        const primary: u32 = @intCast(self.outline.userData(primary_item));
        var items: [max_selected]u32 = undefined;
        var others: [max_selected]u32 = undefined;
        var k: usize = 0;
        for (self.outline.selectedItems(&items)) |it| {
            if (it == primary_item) continue;
            others[k] = @intCast(self.outline.userData(it));
            k += 1;
        }
        self.selectMany(primary, others[0..k]);
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

    /// The "..." button of an event row: a menu of handlers that fit, "New
    /// handler..." and "No handler".
    fn onHandlerMenu(self: *Builder, ev: *event.Event) void {
        const prov = self.opts.handlers orelse return;
        const tag = self.tagOf(ev.current);
        if (tag == 0) return;
        const n = self.selectedNode();
        const info = (self.live(n) orelse return).info orelse return;
        const i = tag - 1;
        if (i >= info.events.len) return;
        _ = self.choice_arena.reset(.retain_capacity);
        const a = self.choice_arena.allocator();
        var list: std.ArrayListUnmanaged(HandlerChoice) = .empty;
        var out: HandlerList = .{ .arena = a, .items = &list };
        prov.list(prov.ctx, n.type_name, info.events[i], &out);
        self.choices = list.items;
        self.choice_event = i;
        var current: []const u8 = "";
        for (n.on) |b| if (std.mem.eql(u8, b.event, info.events[i])) {
            current = b.action;
        };
        const items = a.alloc(menu_mod.Item, list.items.len + 2) catch return;
        for (list.items, 0..) |c, k| items[k] = .{ .label = c.label, .checked = std.mem.eql(u8, c.action, current) };
        items[list.items.len] = .{ .label = "New handler..." };
        items[list.items.len + 1] = .{ .label = "No handler", .enabled = current.len > 0 };
        const rect = self.ui.tree.absoluteRect(ev.current) orelse return;
        self.ui.openMenu(items, rect.x, rect.bottom(), .{ .on_pick = menu_mod.PickHook.bind(self, onHandlerPicked), .anchor = rect, .owner = ev.current, .min_width = 200 }) catch |e| self.updateStatus(e);
    }

    fn onHandlerPicked(self: *Builder, index: usize) void {
        const prov = self.opts.handlers orelse return;
        const n = self.selectedNode();
        const info = (self.live(n) orelse return).info orelse return;
        const i = self.choice_event;
        if (i >= info.events.len or i >= self.event_fields.items.len) return;
        var action: []const u8 = "";
        if (index < self.choices.len) {
            action = prov.choose(prov.ctx, self.choices[index].id) orelse return self.updateStatusText("Could not use that handler");
        } else if (index == self.choices.len) {
            action = prov.create(prov.ctx, n.id, n.type_name, info.events[i]) orelse return self.updateStatusText("Could not create a handler");
        }
        self.setEventAction(i, action);
    }

    /// Bind (or with "" unbind) event `i` of the selected node and show it in the field.
    fn setEventAction(self: *Builder, i: usize, action: []const u8) void {
        const n = self.selectedNode();
        const info = (self.live(n) orelse return).info orelse return;
        const before = self.editor.version;
        self.editor.setEvent(n.uid, info.events[i], action) catch |e| return self.updateStatus(e);
        self.building = true;
        self.event_fields.items[i].setText(action) catch {};
        self.building = false;
        self.markInspectorEdit(before);
    }

    /// The "Go" button of an event row: show the handler's source.
    fn onHandlerGo(self: *Builder, ev: *event.Event) void {
        const prov = self.opts.handlers orelse return;
        const tag = self.tagOf(ev.current);
        if (tag == 0 or tag - 1 >= self.event_fields.items.len) return;
        const action = self.event_fields.items[tag - 1].text();
        if (action.len == 0) return self.updateStatusText("This event has no handler");
        if (!prov.reveal(prov.ctx, action)) self.updateStatusText("No handler is known by that name");
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
        self.repaintOverlays();
    }

    // ---- pointer interaction: preview ----

    const drag_threshold: f32 = 4;

    fn framePick(self: *Builder, x: f32, y: f32) ?*doc_mod.Node {
        const hit = self.ui.tree.nodeAt(self.preview_frame, x, y) orelse return null;
        return interact.docNodeAt(self.ui, self.doc(), self.preview_frame, hit);
    }

    fn selectionRect(self: *Builder) ?Rect {
        const inst = self.inst orelse return null;
        const h = inst.handleOf(self.selected) orelse return null;
        return self.ui.tree.absoluteRect(h);
    }

    fn onPreviewLeave(self: *Builder, _: *event.Event) void {
        if (self.hover != 0) {
            self.hover = 0;
            self.repaintOverlays();
        }
    }

    fn onPreviewPointer(self: *Builder, ev: *event.Event) void {
        // The preview is a design surface: its widgets never see the pointer.
        ev.stopPropagation();
        ev.handled = true;
        switch (ev.kind) {
            .pointer_down => {
                if (ev.button == 3) {
                    self.ui.setFocus(self.preview_host);
                    const hit = self.framePick(ev.x, ev.y) orelse self.doc().root;
                    self.select(hit.uid);
                    self.openContextMenu(ev.x, ev.y);
                    return;
                }
                if (ev.button != 1) return;
                self.ui.setFocus(self.preview_host);
                if (ev.clicks >= 2) {
                    // Double-click a button or label: edit its text in place.
                    const target = self.framePick(ev.x, ev.y) orelse self.doc().root;
                    self.select(target.uid);
                    self.beginTextEdit(target.uid);
                    if (self.rename != null) return;
                }
                if (self.dividerAt(ev.x, ev.y)) |d| {
                    self.select(d.uid);
                    const vertical = d.sv.props.vertical;
                    self.split_drag = .{ .uid = d.uid, .sv = d.sv, .start_size = d.sv.props.first_size, .start = if (vertical) ev.y else ev.x };
                    self.gesture +%= 1;
                    if (self.gesture == 0) self.gesture = 1;
                    self.gesture_active = true;
                    self.editor.breakCoalescing();
                    return;
                }
                if (self.selectionRect()) |r| {
                    if (self.selected != self.doc().root.uid) {
                        if (interact.handleAt(r, ev.x, ev.y)) |h| {
                            self.resize = .{ .handle = h, .uid = self.selected, .start_w = r.w, .start_h = r.h, .sx = ev.x, .sy = ev.y };
                            self.gesture +%= 1;
                            if (self.gesture == 0) self.gesture = 1;
                            self.gesture_active = true;
                            self.editor.breakCoalescing();
                            return;
                        }
                    }
                }
                // Empty frame space belongs to the root.
                const hit = self.framePick(ev.x, ev.y) orelse self.doc().root;
                if (ev.mods.ctrl or ev.mods.gui or ev.mods.shift) return self.toggleInSelection(hit.uid);
                self.select(hit.uid);
                self.press = .{ .source = .preview, .uid = hit.uid, .sx = ev.x, .sy = ev.y };
            },
            .pointer_move => {
                if (self.split_drag != null) return self.splitDragTo(ev.x, ev.y);
                if (self.resize != null) return self.resizeTo(ev.x, ev.y);
                if (self.press != null) return self.dragTo(ev.x, ev.y);
                const hover: u32 = if (self.framePick(ev.x, ev.y)) |n| n.uid else 0;
                if (hover != self.hover) {
                    self.hover = hover;
                    self.repaintOverlays();
                }
            },
            .pointer_up => {
                if (self.split_drag != null) return self.finishSplitDrag();
                if (self.resize != null) return self.finishResize();
                self.finishDrag(ev.x, ev.y);
            },
            else => {},
        }
    }

    /// The split view whose divider is under the point, if any.
    fn dividerAt(self: *Builder, x: f32, y: f32) ?struct { uid: u32, sv: *SplitView } {
        const hit = self.ui.tree.nodeAt(self.preview_frame, x, y) orelse return null;
        const hn = self.ui.tree.get(hit) orelse return null;
        const pn = self.ui.tree.get(hn.parent) orelse return null;
        if (pn.widget_type != ui_mod.typeTag(SplitView)) return null;
        const sv: *SplitView = @ptrCast(@alignCast(pn.widget orelse return null));
        if (!sv.divider.eql(hit)) return null;
        const uid: u32 = @intCast(@intFromPtr(pn.user_data));
        if (uid == 0) return null;
        return .{ .uid = uid, .sv = sv };
    }

    fn splitDragTo(self: *Builder, x: f32, y: f32) void {
        const d = self.split_drag orelse return;
        const delta = (if (d.sv.props.vertical) y else x) - d.start;
        d.sv.setFirstSize(@round(if (d.sv.props.anchor_second) d.start_size - delta else d.start_size + delta));
        const n = self.doc().find(d.uid) orelse return;
        const l = self.live(n) orelse return;
        var scratch = std.heap.ArenaAllocator.init(self.gpa);
        defer scratch.deinit();
        const a = scratch.allocator();
        const info = l.info orelse return;
        const props = (diff.diff(a, info.props, info.propsPtr(l.w.?), info.props_default) catch |e| return self.updateStatus(e)) orelse zon.Value{ .record = &.{} };
        self.editor.setRecordIn(n.uid, .props, props, self.gesture) catch |e| return self.updateStatus(e);
        self.repaintOverlays();
    }

    fn finishSplitDrag(self: *Builder) void {
        self.split_drag = null;
        self.gesture_active = false;
        self.editor.breakCoalescing();
        self.rebuildInspector() catch |e| self.updateStatus(e);
        self.repaintOverlays();
    }

    fn resizeTo(self: *Builder, x: f32, y: f32) void {
        const r = self.resize orelse return;
        const n = self.doc().find(r.uid) orelse return;
        const l = self.live(n) orelse return;
        const st = &self.ui.tree.get(l.h).?.style;
        const dx = x - r.sx;
        const dy = y - r.sy;
        const grow_w = r.handle == .right or r.handle == .corner;
        const grow_h = r.handle == .bottom or r.handle == .corner;
        if (grow_w) st.width = Length.px(@round(@max(r.start_w + dx, 8)));
        if (grow_h) st.height = Length.px(@round(@max(r.start_h + dy, 8)));
        if (grow_w or grow_h) {
            // Pushing a size on a flexible node should hold: no shrinking it back.
            st.shrink = 0;
        }
        const saved_selected = self.selected;
        self.selected = r.uid;
        self.commitLiveStyle(l.h);
        self.selected = saved_selected;
    }

    fn finishResize(self: *Builder) void {
        self.resize = null;
        self.gesture_active = false;
        self.editor.breakCoalescing();
        self.rebuildInspector() catch |e| self.updateStatus(e);
        self.repaintOverlays();
    }

    // ---- pointer interaction: dragging nodes ----

    fn pointInside(self: *Builder, h: Handle, x: f32, y: f32) bool {
        const r = self.ui.tree.absoluteRect(h) orelse return false;
        return x >= r.x and y >= r.y and x < r.right() and y < r.bottom();
    }

    fn draggedNode(self: *Builder) ?*doc_mod.Node {
        const p = self.press orelse return null;
        if (p.uid == 0) return null;
        return self.doc().find(p.uid);
    }

    fn dragTo(self: *Builder, x: f32, y: f32) void {
        const p = self.press orelse return;
        if (self.abs_drag != null) return self.absMoveTo(x, y);
        if (!self.dragging) {
            if (std.math.hypot(x - p.sx, y - p.sy) < drag_threshold) return;
            if (p.uid != 0 and p.uid == self.doc().root.uid) return; // the root does not move
            if (p.source == .preview and self.beginAbsoluteDrag(p)) return self.absMoveTo(x, y);
            self.dragging = true;
        }
        const old = self.drop;
        self.drop = self.dropAt(x, y);
        if (!dropEql(old, self.drop)) self.repaintOverlays();
    }

    /// An absolutely positioned node is dragged by changing its insets, not
    /// reordered. True if `p` is such a node (and the gesture has started).
    fn beginAbsoluteDrag(self: *Builder, p: Press) bool {
        const n = self.doc().find(p.uid) orelse return false;
        const l = self.live(n) orelse return false;
        const st = self.ui.tree.get(l.h).?.style;
        if (st.position != .absolute) return false;
        const parent_rect = self.ui.tree.absoluteRect(self.ui.tree.get(l.h).?.parent) orelse return false;
        const my = self.ui.tree.absoluteRect(l.h) orelse return false;
        const left = switch (st.inset.left) {
            .pixels => |v| v,
            else => my.x - parent_rect.x,
        };
        const top = switch (st.inset.top) {
            .pixels => |v| v,
            else => my.y - parent_rect.y,
        };
        self.abs_drag = .{ .uid = p.uid, .start_left = left, .start_top = top, .sx = p.sx, .sy = p.sy };
        self.gesture +%= 1;
        if (self.gesture == 0) self.gesture = 1;
        self.gesture_active = true;
        self.editor.breakCoalescing();
        return true;
    }

    fn absMoveTo(self: *Builder, x: f32, y: f32) void {
        const d = self.abs_drag orelse return;
        const n = self.doc().find(d.uid) orelse return;
        const l = self.live(n) orelse return;
        const st = &self.ui.tree.get(l.h).?.style;
        st.inset.left = Length.px(@round(d.start_left + (x - d.sx)));
        st.inset.top = Length.px(@round(d.start_top + (y - d.sy)));
        st.inset.right = .auto;
        st.inset.bottom = .auto;
        const saved = self.selected;
        self.selected = d.uid;
        self.commitLiveStyle(l.h);
        self.selected = saved;
    }

    fn dropEql(a: ?interact.Drop, b: ?interact.Drop) bool {
        if (a == null or b == null) return a == null and b == null;
        return a.?.parent == b.?.parent and a.?.index == b.?.index;
    }

    fn dropAt(self: *Builder, x: f32, y: f32) ?interact.Drop {
        const inst = self.inst orelse return null;
        const dragged = self.draggedNode();
        if (self.pointInside(self.preview_frame, x, y)) {
            return interact.previewDrop(self.ui, &inst, self.doc(), self.preview_frame, dragged, x, y);
        }
        if (self.pointInside(self.outline_scroll.node, x, y)) {
            var rows: [256]interact.Row = undefined;
            const n = self.outlineRowRects(&rows);
            return interact.outlineDrop(self.doc(), rows[0..n], dragged, y);
        }
        return null;
    }

    fn outlineRowRects(self: *Builder, out: []interact.Row) usize {
        var n: usize = 0;
        for (self.outline.visibleItems()) |item| {
            if (n == out.len) break;
            const r = self.outline.rowRect(item) orelse continue;
            out[n] = .{ .uid = @intCast(self.outline.userData(item)), .rect = r };
            n += 1;
        }
        return n;
    }

    fn finishDrag(self: *Builder, x: f32, y: f32) void {
        const p = self.press orelse return;
        if (self.abs_drag != null) {
            self.abs_drag = null;
            self.press = null;
            self.gesture_active = false;
            self.editor.breakCoalescing();
            self.rebuildInspector() catch |e| self.updateStatus(e);
            self.repaintOverlays();
            return;
        }
        const was_dragging = self.dragging;
        const drop = if (was_dragging) self.dropAt(x, y) else null;
        self.press = null;
        self.dragging = false;
        self.drop = null;
        self.repaintOverlays();
        if (was_dragging) self.swallow_click = p.source == .palette;
        if (!was_dragging) return;
        const target = drop orelse return;
        if (p.uid != 0) {
            self.moveTo(p.uid, target.parent, target.index);
        } else {
            self.addWidgetAt(p.type_name, target.parent, target.index);
        }
    }

    // ---- pointer interaction: outline rows and palette entries ----

    fn onOutlinePointer(self: *Builder, ev: *event.Event) void {
        switch (ev.kind) {
            .pointer_down => {
                const item = self.outline.itemAt(ev.x, ev.y);
                if (item == tree_view.no_item) return;
                const uid: u32 = @intCast(self.outline.userData(item));
                if (ev.button == 3) {
                    self.select(uid);
                    self.openContextMenu(ev.x, ev.y);
                } else if (ev.button == 1) {
                    self.press = .{ .source = .outline, .uid = uid, .sx = ev.x, .sy = ev.y };
                }
            },
            .pointer_move => if (self.press != null and self.press.?.source == .outline) self.dragTo(ev.x, ev.y),
            .pointer_up => if (self.press != null and self.press.?.source == .outline) self.finishDrag(ev.x, ev.y),
            else => {},
        }
    }

    fn onPalettePointer(self: *Builder, ev: *event.Event) void {
        switch (ev.kind) {
            .pointer_down => if (ev.button == 1) {
                const tag = self.tagOf(ev.current);
                self.press = .{ .source = .palette, .uid = 0, .type_name = self.paletteType(tag), .sx = ev.x, .sy = ev.y };
            },
            .pointer_move => if (self.press != null and self.press.?.source == .palette) self.dragTo(ev.x, ev.y),
            .pointer_up => if (self.press != null and self.press.?.source == .palette) self.finishDrag(ev.x, ev.y),
            else => {},
        }
    }

    // ---- overlays ----

    fn strokeRect(pc: *PaintCtx, r: Rect, width: f32, color: Color) paint_ctx.Error!void {
        try pc.list.strokeRect(r, width, .{ .color = color });
    }

    fn paintPreviewOverlay(self: *Builder, pc: *PaintCtx) paint_ctx.Error!void {
        const inst = self.inst orelse return;
        // Hover.
        if (self.hover != 0 and self.hover != self.selected and !self.dragging) {
            if (inst.handleOf(self.hover)) |h| {
                if (self.ui.tree.absoluteRect(h)) |r| try strokeRect(pc, r, 1, hover_color);
            }
        }
        // The other selected nodes.
        for (self.extra.items) |uid| {
            if (inst.handleOf(uid)) |h| {
                if (self.ui.tree.absoluteRect(h)) |r| try strokeRect(pc, r, 2, select_color);
            }
        }
        // Selection.
        if (self.selectionRect()) |r| {
            try strokeRect(pc, r, 2, select_color);
            if (self.selected != self.doc().root.uid and !self.dragging and self.extra.items.len == 0) {
                inline for (.{ interact.ResizeHandle.right, interact.ResizeHandle.bottom, interact.ResizeHandle.corner }) |hd| {
                    const hr = interact.handleRect(r, hd);
                    try pc.list.fillRect(hr, .{ .color = Color.white });
                    try strokeRect(pc, hr, 1, select_color);
                }
            }
        }
        // Drop marker.
        if (self.dragging) {
            if (self.drop) |d| {
                if (self.pointInside(self.preview_frame, d.indicator.x + 1, d.indicator.y + 1) or true) {
                    try pc.list.fillRect(d.indicator, .{ .color = drop_color });
                }
            }
        }
    }

    fn paintOutlineOverlay(self: *Builder, pc: *PaintCtx) paint_ctx.Error!void {
        _ = pc;
        _ = self;
    }
};

// ---- tests -----------------------------------------------------------------

const testing = std.testing;
const font = @import("../text/font.zig");
const draw_list = @import("../core/draw_list.zig");

const Rig = struct {
    ui: Ui,
    prop: font.TestFont = .{},
    mono: font.TestFont = .{ .monospace = true },
    height: f32 = 800,
    cmds: [8192]draw_list.Command = undefined,
    glyphs: [16384]draw_list.Glyph = undefined,
    list: draw_list.DrawList = undefined,
    b: *Builder = undefined,

    fn init(doc: ?doc_mod.Doc, opts: Options) !*Rig {
        const r = try testing.allocator.create(Rig);
        errdefer testing.allocator.destroy(r);
        r.* = .{ .ui = try Ui.init(testing.allocator) };
        errdefer r.ui.deinit();
        r.list = draw_list.DrawList.init(&r.cmds, &r.glyphs);
        _ = try r.ui.addFont(r.prop.backend());
        r.ui.theme.mono_font = try r.ui.addFont(r.mono.backend());
        r.ui.theme.font_size = 14;
        r.ui.tree.get(r.ui.tree.root).?.style = .{ .direction = .column };
        const d = doc orelse try doc_mod.Doc.init(testing.allocator);
        r.b = try Builder.create(&r.ui, r.ui.tree.root, d, opts);
        try r.frame();
        return r;
    }

    fn deinit(self: *Rig) void {
        self.b.destroy();
        self.ui.deinit();
        testing.allocator.destroy(self);
    }

    fn frame(self: *Rig) !void {
        self.ui.update();
        try self.ui.layoutAndPaint(.{ .w = 1280, .h = self.height }, &self.list);
        self.ui.endFrame();
    }

    fn click(self: *Rig, x: f32, y: f32) !void {
        self.ui.pointerMove(x, y);
        self.ui.pointerButtonEx(x, y, 1, true, 1);
        self.ui.pointerButtonEx(x, y, 1, false, 1);
        try self.frame();
    }

    /// Press at `from`, move through `via` (if any), release at `to`.
    fn drag(self: *Rig, from: [2]f32, to: [2]f32) !void {
        self.ui.pointerMove(from[0], from[1]);
        self.ui.pointerButtonEx(from[0], from[1], 1, true, 1);
        try self.frame();
        const steps = 6;
        for (1..steps + 1) |i| {
            const t = @as(f32, @floatFromInt(i)) / steps;
            self.ui.pointerMove(from[0] + (to[0] - from[0]) * t, from[1] + (to[1] - from[1]) * t);
            try self.frame();
        }
        self.ui.pointerButtonEx(to[0], to[1], 1, false, 1);
        try self.frame();
    }

    fn center(self: *Rig, h: Handle) [2]f32 {
        const r = self.ui.tree.absoluteRect(h).?;
        return .{ r.x + r.w / 2, r.y + r.h / 2 };
    }

    fn liveOf(self: *Rig, uid: u32) Handle {
        return self.b.inst.?.handleOf(uid).?;
    }
};

const sample_doc =
    \\.{ .root = .{ .type = "box", .id = "root", .style = .{ .direction = .column, .gap = 10, .padding = 10, .align_items = .start }, .children = .{
    \\    .{ .type = "box", .id = "a", .style = .{ .width = 120, .height = 40 } },
    \\    .{ .type = "box", .id = "b", .style = .{ .width = 120, .height = 40 } },
    \\    .{ .type = "label", .id = "t", .props = .{ .text = "text" } },
    \\} } }
;

fn sampleRig() !*Rig {
    return Rig.init(try doc_mod.parseDoc(testing.allocator, sample_doc, null, null), .{});
}

fn byId(b: *Builder, id: []const u8) *doc_mod.Node {
    return findIn(b.doc().root, id).?;
}

fn findIn(n: *doc_mod.Node, id: []const u8) ?*doc_mod.Node {
    if (std.mem.eql(u8, n.id, id)) return n;
    for (n.children.items) |c| if (findIn(c, id)) |hit| return hit;
    return null;
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

fn paletteButton(b: *Builder, name: []const u8) *Button {
    var child = b.ui.tree.get(b.palette_grid).?.first_child;
    while (b.ui.tree.get(child)) |n| : (child = n.next) {
        if (n.widget_type == ui_mod.typeTag(Button)) {
            const btn: *Button = @ptrCast(@alignCast(n.widget.?));
            if (std.mem.eql(u8, btn.props.text.bytes, name)) return btn;
        }
    }
    @panic("no palette button");
}

/// The outline row node of document node `uid`.
fn outlineRow(b: *Builder, uid: u32) Handle {
    return b.outline.rowNode(b.outline_items.get(uid).?);
}

fn outlineCount(b: *Builder) u32 {
    return @intCast(b.outline.visibleItems().len);
}

/// Pick the option named `name` in the first Layout-tab drop-down that offers it.
fn chooseOption(b: *Builder, name: []const u8) !void {
    var c = b.ui.tree.get(b.section_scrolls[@intFromEnum(Tab.layout)].contentNode()).?.first_child;
    while (b.ui.tree.get(c)) |n| : (c = n.next) {
        var cc = n.first_child;
        while (b.ui.tree.get(cc)) |m| : (cc = m.next) {
            if (m.widget_type != ui_mod.typeTag(Select)) continue;
            const sel: *Select = @ptrCast(@alignCast(m.widget.?));
            for (0..sel.count()) |i| {
                if (std.mem.eql(u8, sel.itemLabel(i), name)) {
                    sel.setSelected(i);
                    return;
                }
            }
        }
    }
    return error.NoSuchOption;
}

fn formBinding(f: *DynForm, path: []const u8) @TypeOf(f.bindings.items[0]) {
    for (f.bindings.items) |bd| if (bd.kind != .presence and std.mem.eql(u8, bd.path, path)) return bd;
    @panic("no binding");
}


test "a builder starts with an empty box selected and a ready status" {
    const r = try Rig.init(null, .{});
    defer r.deinit();
    const b = r.b;
    try testing.expectEqual(b.doc().root.uid, b.selected);
    try testing.expectEqualStrings("Ready", b.status.props.text.bytes);
    try testing.expect(!b.buttons[@intFromEnum(Command.undo)].?.props.enabled);
    try testing.expect(!b.buttons[@intFromEnum(Command.delete)].?.props.enabled);
    try testing.expectEqual(@as(u32, 1), outlineCount(b));
    try testing.expect(!b.modified());
}

test "the palette adds widgets inside the selected box; the preview and outline follow" {
    const r = try Rig.init(null, .{});
    defer r.deinit();
    const b = r.b;
    clickButton(paletteButton(b, "label"));
    clickButton(paletteButton(b, "button"));
    try testing.expectEqual(@as(usize, 2), b.doc().root.children.items.len);
    try testing.expectEqualStrings("Label", b.doc().root.children.items[0].props.field("text").?.string);
    try testing.expectEqual(b.doc().root.children.items[1].uid, b.selected);
    clickButton(paletteButton(b, "label")); // lands after the selected widget
    try testing.expectEqual(@as(usize, 3), b.doc().root.children.items.len);
    try testing.expectEqual(@as(u32, 4), outlineCount(b));
    const h = b.inst.?.handleOf(b.doc().root.children.items[1].uid).?;
    const btn: *Button = @ptrCast(@alignCast(r.ui.tree.get(h).?.widget.?));
    try testing.expectEqualStrings("Button", btn.props.text.bytes);
    try testing.expect(b.modified());
}

test "clicking in the preview selects the node under the pointer and not the widget" {
    const r = try sampleRig();
    defer r.deinit();
    const b = r.b;
    try r.frame();
    const pb = r.center(r.liveOf(byId(b, "b").uid));
    try r.click(pb[0], pb[1]);
    try testing.expectEqual(byId(b, "b").uid, b.selected);
    const pt = r.center(r.liveOf(byId(b, "t").uid));
    try r.click(pt[0], pt[1]);
    try testing.expectEqual(byId(b, "t").uid, b.selected);
    // The inspector follows, and the outline row is highlighted.
    try testing.expect(b.props_form != null);
    try testing.expect(b.outline.selected() == b.outline_items.get(byId(b, "t").uid).?);
    // Clicking the empty frame selects the root.
    const frame = r.ui.tree.absoluteRect(b.preview_frame).?;
    try r.click(frame.right() - 6, frame.bottom() - 6);
    try testing.expectEqual(b.doc().root.uid, b.selected);
}

test "dragging in the preview moves the node: reorder, reparent, and the drop marker shows" {
    const r = try sampleRig();
    defer r.deinit();
    const b = r.b;
    try r.frame();
    const a = byId(b, "a");
    const bb = byId(b, "b");
    // Drag a to the bottom edge of b: a ends up after b.
    const ra = r.ui.tree.absoluteRect(r.liveOf(bb.uid)).?;
    try r.drag(r.center(r.liveOf(a.uid)), .{ ra.x + 20, ra.bottom() - 3 });
    try testing.expectEqual(bb, b.doc().root.children.items[0]);
    try testing.expectEqual(a, b.doc().root.children.items[1]);
    try testing.expectEqual(a.uid, b.selected);
    b.undo();
    try testing.expectEqual(a, b.doc().root.children.items[0]);

    // Drag the label into the middle of box b: it becomes b's child.
    const t = byId(b, "t");
    try r.frame();
    try r.drag(r.center(r.liveOf(t.uid)), r.center(r.liveOf(byId(b, "b").uid)));
    try testing.expectEqual(byId(b, "b"), t.parent.?);
    try testing.expectEqual(@as(usize, 2), b.doc().root.children.items.len);
}

test "a drag that stays under the threshold only selects" {
    const r = try sampleRig();
    defer r.deinit();
    const b = r.b;
    try r.frame();
    const a = byId(b, "a");
    const c = r.center(r.liveOf(a.uid));
    try r.drag(c, .{ c[0] + 2, c[1] + 1 });
    try testing.expectEqual(a.uid, b.selected);
    try testing.expectEqual(a, b.doc().root.children.items[0]);
    try testing.expect(!b.modified());
}

test "the root cannot be dragged, and dropping outside the preview does nothing" {
    const r = try sampleRig();
    defer r.deinit();
    const b = r.b;
    try r.frame();
    const frame = r.ui.tree.absoluteRect(b.preview_frame).?;
    try r.drag(.{ frame.right() - 6, frame.bottom() - 6 }, .{ 20, 780 });
    try testing.expect(!b.modified());
    const a = byId(b, "a");
    try r.drag(r.center(r.liveOf(a.uid)), .{ 1270, 790 }); // off in the corner of the window
    try testing.expectEqual(a, b.doc().root.children.items[0]);
    try testing.expect(!b.modified());
}

test "dragging a palette entry creates the widget where it is dropped" {
    const r = try sampleRig();
    defer r.deinit();
    const b = r.b;
    try r.frame();
    const bb = byId(b, "b");
    const rb = r.ui.tree.absoluteRect(r.liveOf(bb.uid)).?;
    const from = r.center(paletteButton(b, "button").node);
    try r.drag(from, .{ rb.x + 20, rb.y + 2 }); // the top edge of b: before it
    try testing.expectEqual(@as(usize, 4), b.doc().root.children.items.len);
    try testing.expectEqualStrings("button", b.doc().root.children.items[1].type_name);
    try testing.expectEqual(b.doc().root.children.items[1].uid, b.selected);
    // The click that follows a drag does not add a second one.
    try testing.expectEqual(@as(usize, 4), b.doc().root.children.items.len);
    b.undo();
    try testing.expectEqual(@as(usize, 3), b.doc().root.children.items.len);
}

test "outline rows select by click and reorder by drag" {
    const r = try sampleRig();
    defer r.deinit();
    const b = r.b;
    try r.frame();
    const a = byId(b, "a");
    const t = byId(b, "t");
    try r.click(r.center(outlineRow(b, t.uid))[0], r.center(outlineRow(b, t.uid))[1]);
    try testing.expectEqual(t.uid, b.selected);
    // Drag the label's row onto the top of a's row: it moves before a.
    const row_a = r.ui.tree.absoluteRect(outlineRow(b, a.uid)).?;
    try r.drag(r.center(outlineRow(b, t.uid)), .{ row_a.x + 20, row_a.y + 2 });
    try testing.expectEqual(t, b.doc().root.children.items[0]);
    b.undo();
    try r.frame();
    try testing.expectEqual(a, b.doc().root.children.items[0]);
    // Dragging a row into the middle of a box row nests it.
    const row_b = r.ui.tree.absoluteRect(outlineRow(b, byId(b, "b").uid)).?;
    try r.drag(r.center(outlineRow(b, t.uid)), .{ row_b.x + 20, row_b.y + row_b.h / 2 });
    try testing.expectEqual(byId(b, "b"), byId(b, "t").parent.?);
}

test "resize handles set a width and height, as one undo step" {
    const r = try sampleRig();
    defer r.deinit();
    const b = r.b;
    try r.frame();
    const a = byId(b, "a");
    b.select(a.uid);
    try r.frame();
    const rect = r.ui.tree.absoluteRect(r.liveOf(a.uid)).?;
    const corner = interact.handleRect(rect, .corner);
    try r.drag(.{ corner.x + 4, corner.y + 4 }, .{ corner.x + 4 + 30, corner.y + 4 + 20 });
    try testing.expectEqual(@as(i64, 150), byId(b, "a").style.field("width").?.int);
    try testing.expectEqual(@as(i64, 60), byId(b, "a").style.field("height").?.int);
    const live = r.ui.tree.get(r.liveOf(a.uid)).?;
    try testing.expectEqual(@as(f32, 150), live.style.width.pixels);
    b.undo(); // the many drag moves are one step
    try testing.expectEqual(@as(i64, 120), byId(b, "a").style.field("width").?.int);
    try testing.expectEqual(@as(i64, 40), byId(b, "a").style.field("height").?.int);
    // The right handle only changes the width.
    try r.frame();
    const rect2 = r.ui.tree.absoluteRect(r.liveOf(a.uid)).?;
    const right = interact.handleRect(rect2, .right);
    try r.drag(.{ right.x + 4, right.y + 4 }, .{ right.x + 4 - 40, right.y + 4 });
    try testing.expectEqual(@as(i64, 80), byId(b, "a").style.field("width").?.int);
    try testing.expectEqual(@as(i64, 40), byId(b, "a").style.field("height").?.int);
}

test "structure buttons: duplicate, wrap, unwrap, indent, outdent, move, delete" {
    const r = try sampleRig();
    defer r.deinit();
    const b = r.b;
    const a = byId(b, "a");
    b.select(a.uid);
    clickButton(b.buttons[@intFromEnum(Command.duplicate)].?);
    try testing.expectEqual(@as(usize, 4), b.doc().root.children.items.len);
    try testing.expect(b.selected != a.uid and b.doc().root.children.items[1].uid == b.selected);
    clickButton(b.buttons[@intFromEnum(Command.wrap)].?);
    try testing.expectEqualStrings("box", b.selectedNode().type_name);
    try testing.expectEqual(@as(usize, 1), b.selectedNode().children.items.len);
    clickButton(b.buttons[@intFromEnum(Command.unwrap)].?);
    try testing.expectEqual(@as(usize, 4), b.doc().root.children.items.len);
    b.select(byId(b, "b").uid);
    clickButton(b.buttons[@intFromEnum(Command.up)].?);
    try testing.expectEqual(byId(b, "b"), b.doc().root.children.items[1]);
    clickButton(b.buttons[@intFromEnum(Command.indent)].?); // into the box before it (the duplicate of a)
    try testing.expectEqual(@as(usize, 1), b.doc().root.children.items[0].children.items.len + b.doc().root.children.items[1].children.items.len);
    clickButton(b.buttons[@intFromEnum(Command.outdent)].?);
    try testing.expectEqual(@as(usize, 4), b.doc().root.children.items.len);
    clickButton(b.buttons[@intFromEnum(Command.delete)].?);
    try testing.expectEqual(@as(usize, 3), b.doc().root.children.items.len);
    try testing.expectEqual(b.doc().root.uid, b.selected);
    try testing.expect(!b.buttons[@intFromEnum(Command.delete)].?.props.enabled); // the root cannot be deleted
}

test "copy, cut, and paste round-trip a subtree through ZON" {
    const r = try sampleRig();
    defer r.deinit();
    const b = r.b;
    b.select(byId(b, "a").uid);
    b.copySelected();
    try testing.expect(std.mem.indexOf(u8, b.clip_text.?, ".id = \"a\"") != null);
    b.select(b.doc().root.uid);
    b.pasteClipboard();
    try testing.expectEqual(@as(usize, 4), b.doc().root.children.items.len);
    const pasted = b.doc().root.children.items[3];
    try testing.expectEqual(pasted.uid, b.selected);
    try testing.expectEqualStrings("box", pasted.type_name);
    b.select(byId(b, "t").uid);
    b.cutSelected();
    try testing.expectEqual(@as(usize, 3), b.doc().root.children.items.len);
    b.pasteClipboard();
    try testing.expectEqualStrings("label", b.selectedNode().type_name);
    // Garbage on the clipboard does not change the document.
    const before = b.editor.version;
    if (b.clip_text) |t| testing.allocator.free(t);
    b.clip_text = try testing.allocator.dupe(u8, "not zon at all (");
    b.pasteClipboard();
    try testing.expectEqual(before, b.editor.version);
}

test "shortcuts work while focus is in the builder, and only there" {
    const r = try sampleRig();
    defer r.deinit();
    const b = r.b;
    b.select(byId(b, "a").uid);
    r.ui.setFocus(b.preview_host);
    r.ui.key(.d, .{ .ctrl = true }, true, false); // duplicate
    try testing.expectEqual(@as(usize, 4), b.doc().root.children.items.len);
    r.ui.key(.z, .{ .ctrl = true }, true, false); // undo
    try testing.expectEqual(@as(usize, 3), b.doc().root.children.items.len);
    r.ui.key(.y, .{ .ctrl = true }, true, false); // redo
    try testing.expectEqual(@as(usize, 4), b.doc().root.children.items.len);
    b.select(byId(b, "t").uid); // undo/redo reset the selection to the root
    r.ui.setFocus(b.preview_host);
    r.ui.key(.delete, .{}, true, false);
    try testing.expectEqual(@as(usize, 3), b.doc().root.children.items.len);
    // Outside the builder's panel the keys do nothing to it.
    r.ui.setFocus(null);
    const before = b.editor.version;
    r.ui.key(.z, .{ .ctrl = true }, true, false);
    try testing.expectEqual(before, b.editor.version);
}

test "inspector edits update the live widget and the document, and undo as one step" {
    const r = try sampleRig();
    defer r.deinit();
    const b = r.b;
    const t = byId(b, "t");
    b.select(t.uid);
    const live: *Label = @ptrCast(@alignCast(r.ui.tree.get(r.liveOf(t.uid)).?.widget.?));
    const form = b.props_form.?;
    typeInto(&r.ui, formBinding(form, "text").field.?, "Hi");
    typeInto(&r.ui, formBinding(form, "text").field.?, "Hello");
    try testing.expectEqualStrings("Hello", live.props.text.bytes);
    try testing.expectEqualStrings("Hello", t.props.field("text").?.string);
    try testing.expect(b.props_form == form); // not rebuilt by typing
    b.undo();
    try testing.expectEqualStrings("text", t.props.field("text").?.string);
}

test "the layout tab changes direction, gap, alignment, and sizes live and in the document" {
    const r = try sampleRig();
    defer r.deinit();
    const b = r.b;
    const root_n = b.doc().root;
    b.select(root_n.uid);
    b.setTab(.layout);
    try testing.expect(b.layout_fields[@intFromEnum(Builder.LayoutField.gap)] != null);
    typeInto(&r.ui, b.layout_fields[@intFromEnum(Builder.LayoutField.gap)].?, "24");
    try testing.expectEqual(@as(i64, 24), root_n.style.field("gap").?.int);
    typeInto(&r.ui, b.layout_fields[@intFromEnum(Builder.LayoutField.padding)].?, "6");
    try testing.expectEqual(@as(i64, 6), root_n.style.field("padding").?.field("left").?.int);

    // A direction button changes the container and the preview's layout.
    try chooseOption(b, "row");
        try testing.expect(root_n.style.field("direction") == null); // row is the default: nothing to record
    try r.frame();
    const ra = r.ui.tree.absoluteRect(r.liveOf(byId(b, "a").uid)).?;
    const rb = r.ui.tree.absoluteRect(r.liveOf(byId(b, "b").uid)).?;
    try testing.expect(rb.x > ra.right()); // side by side now
    try testing.expectEqual(ra.y, rb.y);

    // Size section for a child: width mode "fill".
    b.select(byId(b, "a").uid);
    b.setTab(.layout);
    try chooseOption(b, "fill");
    try testing.expectEqualStrings("fill", byId(b, "a").style.field("width").?.tag);
    b.undo();
    try testing.expectEqual(@as(i64, 120), byId(b, "a").style.field("width").?.int);
}

test "the layout tab switches a node to absolute positioning and edits its insets" {
    const r = try sampleRig();
    defer r.deinit();
    const b = r.b;
    const a = byId(b, "a");
    b.select(a.uid);
    b.setTab(.layout);
    // Find the "absolute" button in the Position group.
    try chooseOption(b, "absolute");
    try testing.expectEqualStrings("absolute", a.style.field("position").?.tag);
    try testing.expect(b.layout_fields[@intFromEnum(Builder.LayoutField.inset_left)] != null);
    typeInto(&r.ui, b.layout_fields[@intFromEnum(Builder.LayoutField.inset_left)].?, "40");
    typeInto(&r.ui, b.layout_fields[@intFromEnum(Builder.LayoutField.inset_top)].?, "25");
    try testing.expectEqual(@as(i64, 40), a.style.field("inset").?.field("left").?.int);
    try r.frame();
    // It left the flow: b moved up to where a was, and a sits where the insets say.
    const root_rect = r.ui.tree.absoluteRect(r.liveOf(b.doc().root.uid)).?;
    const ra = r.ui.tree.absoluteRect(r.liveOf(a.uid)).?;
    try testing.expectEqual(root_rect.x + 40, ra.x);
    try testing.expectEqual(root_rect.y + 25, ra.y);
    // Blank means auto again.
    typeInto(&r.ui, b.layout_fields[@intFromEnum(Builder.LayoutField.inset_top)].?, "");
    try testing.expect(a.style.field("inset").?.field("top") == null);
    b.undo();
    b.undo();
    b.undo();
    try testing.expect(a.style.field("position") == null);
}

test "dragging an absolute node changes its insets instead of reordering" {
    const r = try Rig.init(try doc_mod.parseDoc(testing.allocator,
        \\.{ .root = .{ .type = "box", .id = "root", .style = .{ .width = 300, .height = 200, .align_items = .start }, .children = .{
        \\    .{ .type = "box", .id = "flow", .style = .{ .width = 50, .height = 20 } },
        \\    .{ .type = "box", .id = "free", .style = .{ .position = .absolute, .width = 60, .height = 40, .inset = .{ .left = 100, .top = 80 } } },
        \\} } }
    , null, null), .{});
    defer r.deinit();
    const b = r.b;
    try r.frame();
    const free = byId(b, "free");
    const c = r.center(r.liveOf(free.uid));
    try r.drag(c, .{ c[0] + 30, c[1] - 20 });
    try testing.expectEqual(free, b.doc().root.children.items[1]); // not reordered
    try testing.expectEqual(@as(i64, 130), free.style.field("inset").?.field("left").?.int);
    try testing.expectEqual(@as(i64, 60), free.style.field("inset").?.field("top").?.int);
    b.undo(); // the whole drag is one step
    try testing.expectEqual(@as(i64, 100), free.style.field("inset").?.field("left").?.int);
    try testing.expectEqual(@as(i64, 80), free.style.field("inset").?.field("top").?.int);
}

test "adding a split view creates its two panes as one undoable step" {
    const r = try Rig.init(null, .{});
    defer r.deinit();
    const b = r.b;
    clickButton(paletteButton(b, "split_view"));
    const sv = b.selectedNode();
    try testing.expectEqualStrings("split_view", sv.type_name);
    try testing.expectEqual(@as(usize, 2), sv.children.items.len);
    b.undo();
    try testing.expectEqual(@as(usize, 0), b.doc().root.children.items.len);
    b.redo();
    try testing.expectEqual(@as(usize, 2), b.doc().root.children.items[0].children.items.len);
    // The panes show up in the preview, each hosting its box, and take drops.
    try r.frame();
    const pane = b.doc().root.children.items[0].children.items[1];
    try testing.expect(r.ui.tree.absoluteRect(r.liveOf(pane.uid)).?.w > 0);
    b.select(b.doc().root.uid);
    clickButton(paletteButton(b, "label"));
    try testing.expectEqual(@as(usize, 2), b.doc().root.children.items.len);
}

test "the layout tab's wrap toggle reflows a container" {
    const r = try Rig.init(try doc_mod.parseDoc(testing.allocator,
        \\.{ .root = .{ .type = "box", .id = "root", .style = .{ .direction = .row, .width = 100, .height = 100, .align_items = .start }, .children = .{
        \\    .{ .type = "box", .style = .{ .width = 60, .height = 20, .shrink = 0 } },
        \\    .{ .type = "box", .style = .{ .width = 60, .height = 20, .shrink = 0 } },
        \\} } }
    , null, null), .{});
    defer r.deinit();
    const b = r.b;
    b.select(b.doc().root.uid);
    b.setTab(.layout);
    try r.frame();
    const second = b.doc().root.children.items[1];
    try testing.expectEqual(r.ui.tree.absoluteRect(r.liveOf(b.doc().root.children.items[0].uid)).?.y, r.ui.tree.absoluteRect(r.liveOf(second.uid)).?.y);
    try chooseOption(b, "yes");
    try testing.expect(b.doc().root.style.field("wrap").?.bool);
    try r.frame();
    try testing.expect(r.ui.tree.absoluteRect(r.liveOf(second.uid)).?.y > r.ui.tree.absoluteRect(r.liveOf(b.doc().root.children.items[0].uid)).?.y);
}

test "the inspector and outline scroll when they overflow" {
    const r = try sampleRig();
    defer r.deinit();
    const b = r.b;
    r.height = 420;
    for (0..40) |_| b.addWidget("button");
    try r.frame();
    try r.frame();
    try testing.expect(b.outline_scroll.out.overflowing);
    try testing.expect(b.outline_scroll.out.content_h > b.outline_scroll.out.view_h);
    b.select(byId(b, "a").uid);
    b.setTab(.style);
    try r.frame();
    try r.frame();
    try testing.expect(b.section_scrolls[@intFromEnum(Tab.style)].out.overflowing); // the style form is long
    b.section_scrolls[@intFromEnum(Tab.style)].scrollTo(0, 100);
    try r.frame();
    try testing.expectEqual(@as(f32, 100), b.section_scrolls[@intFromEnum(Tab.style)].out.scroll_y);
}

test "ids and event bindings go into the document" {
    const r = try Rig.init(null, .{});
    defer r.deinit();
    const b = r.b;
    b.addWidget("button");
    const n = b.selectedNode();
    typeInto(&r.ui, b.id_field.?, "ok");
    try testing.expectEqualStrings("ok", n.id);
    b.setTab(.events);
    try testing.expectEqual(@as(usize, 1), b.event_fields.items.len);
    typeInto(&r.ui, b.event_fields.items[0], "confirm");
    try testing.expectEqualStrings("click", n.on[0].event);
    try testing.expectEqualStrings("confirm", n.on[0].action);
    b.undo();
    try testing.expectEqual(@as(usize, 0), n.on.len);
}

test "modified tracking, on_change, save, and loading a document" {
    const Sink = struct {
        var saved: ?[]u8 = null;
        var changes: u32 = 0;
        fn hook(_: ?*anyopaque, t: []const u8) void {
            if (saved) |s| testing.allocator.free(s);
            saved = testing.allocator.dupe(u8, t) catch null;
        }
        fn changed(_: *event.Event) void {
            changes += 1;
        }
    };
    Sink.saved = null;
    Sink.changes = 0;
    defer if (Sink.saved) |s| testing.allocator.free(s);
    const r = try Rig.init(null, .{ .save = .{ .call = Sink.hook }, .on_change = event.Callback.fromFn(Sink.changed) });
    defer r.deinit();
    const b = r.b;
    try testing.expect(!b.modified());
    b.addWidget("label");
    try testing.expect(b.modified());
    try testing.expectEqualStrings("Modified", b.status.props.text.bytes);
    try testing.expectEqual(@as(u32, 1), Sink.changes);
    b.save();
    try testing.expect(!b.modified());
    try testing.expect(std.mem.indexOf(u8, Sink.saved.?, "label") != null);
    b.undo();
    try testing.expect(b.modified()); // differs from what was saved
    try testing.expectEqual(@as(u32, 2), Sink.changes);

    var fresh = try doc_mod.parseDoc(testing.allocator, sample_doc, null, null);
    errdefer fresh.deinit();
    try b.loadDocument(fresh);
    try testing.expect(!b.modified());
    try testing.expect(!b.editor.canUndo());
    try testing.expectEqual(@as(u32, 4), outlineCount(b));
    try testing.expectEqual(@as(usize, 3), b.doc().root.children.items.len);
}

test "two builders in one Ui keep separate commands" {
    var ui = try Ui.init(testing.allocator);
    defer ui.deinit();
    const one = try Builder.create(&ui, ui.tree.root, try doc_mod.Doc.init(testing.allocator), .{ .command_prefix = "one" });
    defer one.destroy();
    const two = try Builder.create(&ui, ui.tree.root, try doc_mod.Doc.init(testing.allocator), .{ .command_prefix = "two" });
    defer two.destroy();
    try testing.expect(ui.commands.find("one.undo") != null);
    try testing.expect(ui.commands.find("two.undo") != null);
    one.addWidget("label");
    try testing.expect(one.modified() and !two.modified());
}

test "a document with problems still previews and says what is wrong" {
    var d = try doc_mod.parseDoc(testing.allocator,
        \\.{ .root = .{ .type = "box", .children = .{
        \\    .{ .type = "button", .props = .{ .variant = .huge } },
        \\    .{ .type = "label", .props = .{ .text = "still here" } },
        \\} } }
    , null, null);
    errdefer d.deinit();
    const r = try Rig.init(d, .{});
    defer r.deinit();
    try testing.expect(std.mem.indexOf(u8, r.b.status.props.text.bytes, "1 problem") != null);
    try testing.expectEqual(@as(u32, 3), outlineCount(r.b));
}

test "creating and destroying builders frees everything, including under allocation failure" {
    var i: usize = 0;
    while (i < 300) : (i += 1) {
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
        b.duplicateSelected();
        b.undo();
        b.destroy();
    }
}

test "the layout tab makes a container a grid and sets a child's span" {
    const r = try Rig.init(null, .{});
    defer r.deinit();
    const b = r.b;
    clickButton(paletteButton(b, "button"));
    const first = b.selectedNode();
    b.select(b.doc().root.uid);
    clickButton(paletteButton(b, "button"));
    b.select(b.doc().root.uid);
    b.setTab(.layout);
    try r.frame();
    try chooseOption(b, "grid");
    try testing.expect(b.layout_fields[@intFromEnum(Builder.LayoutField.grid_columns)] != null);
    typeInto(&r.ui, b.layout_fields[@intFromEnum(Builder.LayoutField.grid_columns)].?, "2");
    try testing.expectEqual(@as(i64, 2), b.doc().root.style.field("grid_columns").?.int);
    // A child of a grid gets a span field.
    b.select(first.uid);
    try r.frame();
    try testing.expect(b.layout_fields[@intFromEnum(Builder.LayoutField.grid_span)] != null);
    typeInto(&r.ui, b.layout_fields[@intFromEnum(Builder.LayoutField.grid_span)].?, "2");
    try testing.expectEqual(@as(i64, 2), first.style.field("grid_span").?.int);
    typeInto(&r.ui, b.layout_fields[@intFromEnum(Builder.LayoutField.grid_row_span)].?, "3");
    try testing.expectEqual(@as(i64, 3), first.style.field("grid_row_span").?.int);
}

fn doubleClick(r: *Rig, pt: [2]f32) !void {
    r.ui.pointerMove(pt[0], pt[1]);
    r.ui.pointerButtonEx(pt[0], pt[1], 1, true, 1);
    r.ui.pointerButtonEx(pt[0], pt[1], 1, false, 1);
    r.ui.pointerButtonEx(pt[0], pt[1], 1, true, 2);
    r.ui.pointerButtonEx(pt[0], pt[1], 1, false, 2);
    try r.frame();
}

test "double-clicking an outline row edits the node's id in place" {
    const r = try sampleRig();
    defer r.deinit();
    const b = r.b;
    try r.frame();
    const t = byId(b, "t");
    try doubleClick(r, r.center(outlineRow(b, t.uid)));
    try testing.expect(b.rename != null);
    try testing.expectEqual(t.uid, b.rename_uid);
    try testing.expectEqualStrings("t", b.rename.?.text());
    // The old id is selected, so typing replaces it; Enter applies it.
    r.ui.textInput("label_1");
    try r.frame();
    r.ui.key(.enter, .{}, true, false);
    try r.frame();
    try testing.expect(b.rename == null);
    try testing.expectEqualStrings("label_1", t.id);
    try testing.expect(b.outline.itemText(b.outline_items.get(t.uid).?).len > 0);
    // It is one undo step.
    b.undo();
    try testing.expectEqualStrings("t", t.id);
}

test "Escape cancels a rename; clicking away applies it" {
    const r = try sampleRig();
    defer r.deinit();
    const b = r.b;
    try r.frame();
    const a = byId(b, "a");
    b.select(a.uid);
    b.beginRename(a.uid);
    try testing.expect(b.rename != null);
    r.ui.textInput("zzz");
    r.ui.key(.escape, .{}, true, false);
    try r.frame();
    try testing.expect(b.rename == null);
    try testing.expectEqualStrings("a", a.id);

    b.beginRename(a.uid);
    r.ui.textInput("kept");
    try r.frame();
    try r.click(r.center(outlineRow(b, byId(b, "b").uid))[0], r.center(outlineRow(b, byId(b, "b").uid))[1]);
    try testing.expect(b.rename == null);
    try testing.expectEqualStrings("kept", a.id);
}

test "right-clicking a node in the preview selects it and opens a menu of commands" {
    const r = try sampleRig();
    defer r.deinit();
    const b = r.b;
    try r.frame();
    const a = byId(b, "a");
    const pt = r.center(r.liveOf(a.uid));
    r.ui.pointerMove(pt[0], pt[1]);
    r.ui.pointerButtonEx(pt[0], pt[1], 3, true, 1);
    r.ui.pointerButtonEx(pt[0], pt[1], 3, false, 1);
    try r.frame();
    try testing.expectEqual(a.uid, b.selected);
    try testing.expect(r.ui.menuOpen());
    try r.frame();
    var dup: ?usize = null;
    for (r.ui.menu.?.entries, 0..) |e, i| {
        if (std.mem.eql(u8, e.label, "Duplicate")) dup = i;
    }
    try testing.expect(dup != null);
    try testing.expect(r.ui.menu.?.entries[dup.?].enabled);
    const before = b.doc().root.children.items.len;
    const row = r.center(r.ui.menu.?.entries[dup.?].row);
    try r.click(row[0], row[1]);
    try testing.expect(!r.ui.menuOpen());
    try testing.expectEqual(before + 1, b.doc().root.children.items.len);
}

test "right-clicking an outline row opens the menu; the root's Delete is disabled" {
    const r = try sampleRig();
    defer r.deinit();
    const b = r.b;
    try r.frame();
    const pt = r.center(outlineRow(b, b.doc().root.uid));
    r.ui.pointerMove(pt[0], pt[1]);
    r.ui.pointerButtonEx(pt[0], pt[1], 3, true, 1);
    r.ui.pointerButtonEx(pt[0], pt[1], 3, false, 1);
    try r.frame();
    try testing.expect(r.ui.menuOpen());
    for (r.ui.menu.?.entries) |e| {
        if (std.mem.eql(u8, e.label, "Delete")) try testing.expect(!e.enabled);
    }
    r.ui.key(.escape, .{}, true, false);
    try r.frame();
    try testing.expect(!r.ui.menuOpen());
}

test "the menu bar offers the commands and runs them" {
    const r = try sampleRig();
    defer r.deinit();
    const b = r.b;
    try r.frame();
    const mb = b.menu_bar.?;
    try testing.expectEqual(@as(usize, 4), mb.tops.items.len); // File, Edit, View, Structure
    const edit_btn = r.center(mb.tops.items[1].button.node);
    try r.click(edit_btn[0], edit_btn[1]);
    try testing.expect(r.ui.menuOpen());
    try r.frame();
    var undo_entry: ?usize = null;
    for (r.ui.menu.?.entries, 0..) |e, i| {
        if (std.mem.eql(u8, e.label, "Undo")) undo_entry = i;
    }
    try testing.expect(!r.ui.menu.?.entries[undo_entry.?].enabled); // nothing to undo yet
    r.ui.closeMenu();
}

test "new area widgets fill their parent, and the split view's divider can be dragged in the preview" {
    const r = try sampleRig();
    defer r.deinit();
    const b = r.b;
    b.select(b.doc().root.uid);
    clickButton(paletteButton(b, "split_view"));
    const sv_node = b.selectedNode();
    try testing.expectEqualStrings("fill", sv_node.style.field("width").?.tag);
    try testing.expectEqualStrings("fill", sv_node.style.field("height").?.tag);
    for (sv_node.children.items) |pane| {
        try testing.expectEqualStrings("fill", pane.style.field("width").?.tag);
        try testing.expectEqualStrings("fill", pane.style.field("height").?.tag);
    }
    b.select(b.doc().root.uid);
    clickButton(paletteButton(b, "canvas"));
    try testing.expectEqualStrings("fill", b.selectedNode().style.field("height").?.tag);
    b.select(b.doc().root.uid);
    clickButton(paletteButton(b, "box"));
    try testing.expectEqualStrings("fill", b.selectedNode().style.field("width").?.tag);

    // Drag the divider: the document records the new first_size.
    try r.frame();
    const sv = r.ui.tree.get(r.liveOf(sv_node.uid)).?;
    const split: *SplitView = @ptrCast(@alignCast(sv.widget.?));
    try testing.expect(sv_node.props.field("first_size") == null);
    const dv = r.ui.tree.absoluteRect(split.divider).?;
    const from = [2]f32{ dv.x + dv.w / 2, dv.y + dv.h / 2 };
    try r.drag(from, .{ from[0] + 30, from[1] });
    try testing.expect(sv_node.props.field("first_size") != null);
    try testing.expect(split.props.first_size > 240);
    const dragged = split.props.first_size;
    b.undo();
    try testing.expect(sv_node.props.field("first_size") == null or sv_node.props.field("first_size").?.float != dragged);
}

test "the context menu has a submenu of the widget's own actions" {
    const r = try sampleRig();
    defer r.deinit();
    const b = r.b;
    b.select(b.doc().root.uid);
    clickButton(paletteButton(b, "split_view"));
    const sv = b.selectedNode();
    try r.frame();
    try testing.expect(sv.props.field("vertical") == null);

    b.openContextMenu(100, 100);
    try r.frame();
    var m = r.ui.menu.?;
    var sub_idx: ?usize = null;
    for (m.entries, 0..) |e, i| {
        if (e.sub.len > 0 and std.mem.eql(u8, e.label, "split_view")) sub_idx = i;
    }
    try testing.expect(sub_idx != null);
    const at = r.center(m.entries[sub_idx.?].row);
    r.ui.pointerMove(at[0], at[1]);
    try r.frame();
    try r.frame();
    const child = m.child.?;
    try testing.expectEqualStrings("Make vertical", child.entries[0].label);
    try testing.expect(child.entries[1].label.len > 0 and !child.entries[1].checked);
    const pick = r.center(child.entries[0].row);
    try r.click(pick[0], pick[1]);
    try testing.expect(!r.ui.menuOpen());
    try testing.expect(sv.props.field("vertical").?.bool);
    const live: *SplitView = @ptrCast(@alignCast(r.ui.tree.get(r.liveOf(sv.uid)).?.widget.?));
    try testing.expect(live.props.vertical);
    b.undo();
    try testing.expect(sv.props.field("vertical") == null or !sv.props.field("vertical").?.bool);

    // With it vertical, the entry reads the other way round.
    b.redo();
    try r.frame();
    b.openContextMenu(100, 100);
    try r.frame();
    m = r.ui.menu.?;
    const at2 = r.center(m.entries[sub_idx.?].row);
    r.ui.pointerMove(at2[0], at2[1]);
    try r.frame();
    try r.frame();
    try testing.expectEqualStrings("Make horizontal", r.ui.menu.?.child.?.entries[0].label);
    r.ui.closeMenu();
}

test "the Layout tab offers grid for containers" {
    const r = try sampleRig();
    defer r.deinit();
    const b = r.b;
    b.select(b.doc().root.uid);
    b.setTab(.layout);
    try r.frame();
    try testing.expect(b.layout_fields[@intFromEnum(Builder.LayoutField.grid_columns)] == null);
    try chooseOption(b, "grid");
    try testing.expectEqual(@as(i64, 2), b.doc().root.style.field("grid_columns").?.int);
    try chooseOption(b, "column");
    try testing.expect(b.doc().root.style.field("grid_columns") == null or b.doc().root.style.field("grid_columns").?.int == 0);
}

test "ctrl-click in the outline selects several nodes; delete and duplicate act on all, as one undo step" {
    const r = try sampleRig();
    defer r.deinit();
    const b = r.b;
    try r.frame();
    const a = byId(b, "a");
    const bb = byId(b, "b");
    const t = byId(b, "t");
    const pa = r.center(outlineRow(b, a.uid));
    try r.click(pa[0], pa[1]);
    try testing.expectEqual(a.uid, b.selected);
    r.ui.input.mods = .{ .ctrl = true };
    const pt = r.center(outlineRow(b, t.uid));
    try r.click(pt[0], pt[1]);
    r.ui.input.mods = .{};
    try testing.expectEqual(@as(usize, 2), b.selectionCount());
    try testing.expectEqual(t.uid, b.selected);
    try testing.expect(std.mem.indexOfScalar(u32, b.extra.items, a.uid) != null);
    // Single-node commands (unwrap, indent, rename...) step aside.
    try testing.expect(!b.buttons[@intFromEnum(Command.unwrap)].?.props.enabled);
    try testing.expect(b.buttons[@intFromEnum(Command.delete)].?.props.enabled);

    b.duplicateSelected();
    try r.frame();
    try testing.expectEqual(@as(usize, 5), b.doc().root.children.items.len);
    try testing.expectEqual(@as(usize, 2), b.selectionCount()); // the copies are selected
    b.undo();
    try r.frame();
    try testing.expectEqual(@as(usize, 3), b.doc().root.children.items.len);

    // Select a and t again and delete both.
    b.select(a.uid);
    b.toggleInSelection(t.uid);
    b.deleteSelected();
    try r.frame();
    try testing.expectEqual(@as(usize, 1), b.doc().root.children.items.len);
    try testing.expectEqual(bb.uid, b.doc().root.children.items[0].uid);
    try testing.expectEqual(@as(usize, 1), b.selectionCount());
    b.undo();
    try r.frame();
    try testing.expectEqual(@as(usize, 3), b.doc().root.children.items.len);
}

test "ctrl-click in the preview toggles membership; layout choices apply to every selected node" {
    const r = try sampleRig();
    defer r.deinit();
    const b = r.b;
    try r.frame();
    const a = byId(b, "a");
    const bb = byId(b, "b");
    b.select(a.uid);
    const pb = r.center(r.liveOf(bb.uid));
    r.ui.input.mods = .{ .ctrl = true };
    try r.click(pb[0], pb[1]);
    r.ui.input.mods = .{};
    try testing.expectEqual(@as(usize, 2), b.selectionCount());
    try testing.expectEqual(bb.uid, b.selected);

    b.setTab(.layout);
    try r.frame();
    try chooseOption(b, "fill"); // the width drop-down comes first
    try testing.expectEqualStrings("fill", a.style.field("width").?.tag);
    try testing.expectEqualStrings("fill", bb.style.field("width").?.tag);
    // A text field edits all of them too: grow.
    typeInto(&r.ui, b.layout_fields[@intFromEnum(Builder.LayoutField.grow)].?, "2");
    try testing.expectEqual(@as(f64, 2), a.style.field("grow").?.float);
    try testing.expectEqual(@as(f64, 2), bb.style.field("grow").?.float);
    // Ctrl-clicking a selected node removes it.
    r.ui.input.mods = .{ .ctrl = true };
    try r.click(pb[0], pb[1]);
    r.ui.input.mods = .{};
    try testing.expectEqual(@as(usize, 1), b.selectionCount());
    try testing.expectEqual(a.uid, b.selected);
}

test "double-clicking a button or label in the preview edits its text in place" {
    const r = try sampleRig();
    defer r.deinit();
    const b = r.b;
    try r.frame();
    const t = byId(b, "t");
    try doubleClick(r, r.center(r.liveOf(t.uid)));
    try testing.expect(b.rename != null and b.rename_text);
    try testing.expectEqualStrings("text", b.rename.?.text());
    r.ui.textInput("Hello there");
    try r.frame();
    r.ui.key(.enter, .{}, true, false);
    try r.frame();
    try testing.expect(b.rename == null);
    try testing.expectEqualStrings("Hello there", t.props.field("text").?.string);
    const live: *Label = @ptrCast(@alignCast(r.ui.tree.get(r.liveOf(t.uid)).?.widget.?));
    try testing.expectEqualStrings("Hello there", live.props.text.bytes);
    b.undo();
    try testing.expectEqualStrings("text", t.props.field("text").?.string);

    // A plain box has no text: double-click does nothing.
    try doubleClick(r, r.center(r.liveOf(byId(b, "a").uid)));
    try testing.expect(b.rename == null);
}

test "copy, cut, paste, move, and wrap work on a multi-selection" {
    const r = try sampleRig();
    defer r.deinit();
    const b = r.b;
    try r.frame();
    const a = byId(b, "a");
    const bb = byId(b, "b");
    const t = byId(b, "t");
    // Copy a and t and paste them into b (a container): they go inside it.
    b.select(a.uid);
    b.toggleInSelection(t.uid);
    b.copySelected();
    b.select(bb.uid);
    b.pasteClipboard();
    try r.frame();
    try testing.expectEqual(@as(usize, 2), bb.children.items.len);
    try testing.expectEqual(@as(usize, 2), b.selectionCount()); // the pasted nodes are selected
    b.undo();
    try r.frame();
    try testing.expectEqual(@as(usize, 0), bb.children.items.len);

    // Cut removes them (one undo step brings both back).
    b.select(a.uid);
    b.toggleInSelection(t.uid);
    b.cutSelected();
    try r.frame();
    try testing.expectEqual(@as(usize, 1), b.doc().root.children.items.len);
    b.undo();
    try r.frame();
    try testing.expectEqual(@as(usize, 3), b.doc().root.children.items.len);

    // Move up: b and t each go up one place (a, b, t -> b, t, a).
    b.select(bb.uid);
    b.toggleInSelection(t.uid);
    b.moveSelected(-1);
    try r.frame();
    try testing.expectEqual(bb, b.doc().root.children.items[0]);
    try testing.expectEqual(t, b.doc().root.children.items[1]);
    try testing.expectEqual(a, b.doc().root.children.items[2]);
    b.undo();
    try r.frame();
    try testing.expectEqual(a, b.doc().root.children.items[0]);

    // Wrap a and b in one new box.
    b.select(a.uid);
    b.toggleInSelection(bb.uid);
    b.wrapSelected();
    try r.frame();
    try testing.expectEqual(@as(usize, 2), b.doc().root.children.items.len);
    const w = b.selectedNode();
    try testing.expectEqualStrings("box", w.type_name);
    try testing.expectEqual(@as(usize, 2), w.children.items.len);
    try testing.expectEqual(a, w.children.items[0]);
    try testing.expectEqual(bb, w.children.items[1]);
    b.undo();
    try r.frame();
    try testing.expectEqual(@as(usize, 3), b.doc().root.children.items.len);
}

test "a tab view from the palette starts with two filled pages, and selecting inside one shows its tab" {
    const r = try sampleRig();
    defer r.deinit();
    const b = r.b;
    b.select(b.doc().root.uid);
    clickButton(paletteButton(b, "tab_view"));
    const tv = b.selectedNode();
    try testing.expectEqual(@as(usize, 2), tv.children.items.len);
    try testing.expectEqualStrings("Tab 1\nTab 2", tv.props.field("titles").?.string);
    try testing.expectEqualStrings("fill", tv.style.field("height").?.tag);
    try r.frame();
    try r.frame();
    const tabs: *TabPanel = @ptrCast(@alignCast(r.ui.tree.get(r.liveOf(tv.uid)).?.widget.?));
    try testing.expectEqual(@as(usize, 2), tabs.tabCount());
    try testing.expectEqual(@as(usize, 0), tabs.activeTab());
    // Select the second page: its tab comes forward.
    b.select(tv.children.items[1].uid);
    try testing.expectEqual(@as(usize, 1), tabs.activeTab());
    try r.frame();
    try testing.expect(!r.ui.tree.get(r.liveOf(tv.children.items[1].uid)).?.flags.hidden);
}

test "every registered widget is in the toolbox, and the new ones build from their default document" {
    const r = try sampleRig();
    defer r.deinit();
    const b = r.b;
    // One palette button per registry entry, plus box.
    var buttons: usize = 0;
    var c = b.ui.tree.get(b.palette_grid).?.first_child;
    while (b.ui.tree.get(c)) |n| : (c = n.next) buttons += 1;
    try testing.expectEqual(registry.widgets.len + 1, buttons);
    for (registry.widgets) |w| _ = paletteButton(b, w.name);

    for ([_][]const u8{ "tree_view", "menu_bar", "dock", "tab_view", "select" }) |name| {
        b.select(b.doc().root.uid);
        clickButton(paletteButton(b, name));
        try testing.expectEqualStrings(name, b.selectedNode().type_name);
    }
    try r.frame();
    try r.frame();
    // (The sample document's own `.padding = 10` is the one known problem.)
    for (b.inst.?.problems.items) |pr| try testing.expect(std.mem.startsWith(u8, pr.message, "style.padding"));
    // The tree view and menu bar read their defaults from text props.
    const tv = b.doc().root.children.items[b.doc().root.children.items.len - 5];
    try testing.expectEqualStrings("tree_view", tv.type_name);
    const tree: *TreeView = @ptrCast(@alignCast(r.ui.tree.get(r.liveOf(tv.uid)).?.widget.?));
    try testing.expectEqual(@as(usize, 1), tree.childCount(tree_view.no_item));
    try testing.expectEqual(@as(usize, 2), tree.childCount(tree.childAt(tree_view.no_item, 0)));
}

test "the inspector's sections are dock tabs that can be stacked, and all stay up to date" {
    const r = try sampleRig();
    defer r.deinit();
    const b = r.b;
    b.select(byId(b, "t").uid);
    try r.frame();
    try r.frame();
    // One group of four tabs to begin with.
    const props = b.section_panels[@intFromEnum(Tab.props)];
    const layout = b.section_panels[@intFromEnum(Tab.layout)];
    try testing.expect(props.group == layout.group);
    try testing.expectEqual(@as(usize, 4), props.group.?.panels.items.len);
    // setTab brings a section forward.
    b.setTab(.layout);
    try r.frame();
    try testing.expectEqual(@as(usize, 2), props.group.?.tabs.?.activeTab());
    // Stack Layout under Props: both visible, both built.
    try b.inspector_dock.dockSplit(layout, props, .bottom, 220);
    try r.frame();
    try r.frame();
    try testing.expect(props.group != layout.group);
    try testing.expect(b.props_form != null);
    try testing.expect(b.layout_fields[@intFromEnum(Builder.LayoutField.gap)] == null); // a label has no gap field... but the size ones exist
    try testing.expect(b.layout_fields[@intFromEnum(Builder.LayoutField.width_px)] != null);
    // Selecting another node refreshes both.
    b.select(byId(b, "a").uid);
    try r.frame();
    try testing.expect(b.layout_fields[@intFromEnum(Builder.LayoutField.gap)] != null);
    typeInto(&r.ui, b.layout_fields[@intFromEnum(Builder.LayoutField.gap)].?, "30");
    try testing.expectEqual(@as(i64, 30), byId(b, "a").style.field("gap").?.int);
    // Closing a section and bringing it back.
    b.inspector_dock.closePanel(layout);
    try testing.expect(layout.state == .hidden);
    try b.inspector_dock.showPanel(layout);
    try testing.expect(layout.state == .docked);
}

const FakeHandlers = struct {
    created: u32 = 0,
    revealed: [32]u8 = undefined,
    revealed_len: usize = 0,
    last_node: [32]u8 = undefined,
    last_node_len: usize = 0,

    pub fn list(self: *FakeHandlers, widget_type: []const u8, event_name: []const u8, out: *HandlerList) void {
        _ = self;
        if (std.mem.eql(u8, widget_type, "button") and std.mem.eql(u8, event_name, "click")) {
            out.add(7, "save", "App.onSave");
            out.add(8, "quit", "App.onQuit");
        }
    }
    pub fn choose(self: *FakeHandlers, id: u32) ?[]const u8 {
        _ = self;
        return if (id == 7) "save" else "quit";
    }
    pub fn create(self: *FakeHandlers, node_id: []const u8, widget_type: []const u8, event_name: []const u8) ?[]const u8 {
        _ = widget_type;
        _ = event_name;
        self.created += 1;
        @memcpy(self.last_node[0..node_id.len], node_id);
        self.last_node_len = node_id.len;
        return "okClick";
    }
    pub fn reveal(self: *FakeHandlers, action: []const u8) bool {
        @memcpy(self.revealed[0..action.len], action);
        self.revealed_len = action.len;
        return true;
    }
};

fn eventsButton(b: *Builder, text: []const u8) *Button {
    var stack: [64]Handle = undefined;
    var n: usize = 0;
    stack[n] = b.section_scrolls[@intFromEnum(Tab.events)].contentNode();
    n += 1;
    while (n > 0) {
        n -= 1;
        const node = b.ui.tree.get(stack[n]) orelse continue;
        if (node.widget_type == ui_mod.typeTag(Button)) {
            const btn: *Button = @ptrCast(@alignCast(node.widget.?));
            if (std.mem.eql(u8, btn.props.text.bytes, text)) return btn;
        }
        var c = node.first_child;
        while (b.ui.tree.get(c)) |cn| : (c = cn.next) {
            if (n < stack.len) {
                stack[n] = c;
                n += 1;
            }
        }
    }
    @panic("no such button in the Events tab");
}

test "the Events tab offers handlers from the provider: choose, create, go to, clear" {
    var fake: FakeHandlers = .{};
    const d = try doc_mod.parseDoc(testing.allocator, ".{ .root = .{ .type = \"box\", .children = .{ .{ .type = \"button\", .id = \"ok\", .props = .{ .text = \"OK\" } } } } }", null, null);
    const r = try Rig.init(d, .{ .handlers = HandlerProvider.bind(&fake, FakeHandlers) });
    defer r.deinit();
    const b = r.b;
    const ok = byId(b, "ok");
    b.select(ok.uid);
    b.setTab(.events);
    try r.frame();
    try testing.expectEqual(@as(usize, 1), b.event_fields.items.len);

    // "..." opens a menu: the two handlers, "New handler...", "No handler".
    clickButton(eventsButton(b, "..."));
    try testing.expect(r.ui.menuOpen());
    try testing.expectEqual(@as(usize, 2), b.choices.len);
    try testing.expectEqualStrings("App.onQuit", b.choices[1].label);
    r.ui.closeMenu();

    // Choosing one binds it and shows it in the field.
    b.onHandlerPicked(0);
    try testing.expectEqualStrings("save", ok.on[0].action);
    try testing.expectEqualStrings("save", b.event_fields.items[0].text());
    // Creating gets a name from the provider, with the node's id as the base.
    b.onHandlerPicked(2);
    try testing.expectEqual(@as(u32, 1), fake.created);
    try testing.expectEqualStrings("ok", fake.last_node[0..fake.last_node_len]);
    try testing.expectEqualStrings("okClick", ok.on[0].action);
    // "Go" asks the provider to show the source.
    clickButton(eventsButton(b, "Go"));
    try testing.expectEqualStrings("okClick", fake.revealed[0..fake.revealed_len]);
    // "No handler" clears it, and undo brings it back.
    b.onHandlerPicked(3);
    try testing.expectEqual(@as(usize, 0), ok.on.len);
    b.undo();
    try testing.expectEqualStrings("okClick", byId(b, "ok").on[0].action);
}
