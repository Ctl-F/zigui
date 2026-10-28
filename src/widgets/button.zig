//! Button: a widget with a stable address, its state, and its behavior.
//!
//! The app reads and writes `props` and calls the setters; the toolkit writes
//! `out`. `out.clicked` is frame-scoped (cleared by `Ui.endFrame`) and
//! `out.click_count` only ever grows, so apps that poll less often than they
//! render do not miss clicks. Callbacks and flags come from the same click
//! event and cannot disagree.
//!
//! The widget holds a pointer back to its `Ui`, so the `Ui` must not move
//! after widgets exist.

const std = @import("std");
const Handle = @import("../core/handle.zig").Handle;
const event = @import("../core/event.zig");
const shadow = @import("../core/shadow.zig");
const DirtyFlags = @import("../core/dirty.zig").DirtyFlags;
const theme_mod = @import("theme.zig");
const ButtonColors = theme_mod.ButtonColors;
const paint_ctx = @import("../core/paint_ctx.zig");
const PaintCtx = paint_ctx.PaintCtx;
const Align = @import("../text/block.zig").Align;
const Ui = @import("../core/ui.zig").Ui;
const Style = @import("../core/style.zig").Style;
const Node = @import("../core/tree.zig").Node;

pub const Variant = enum { normal, primary, danger, flat };

/// Draws a button's box into the paint context (and may recolor its text).
/// Set `Theme.button_painter` to restyle every button, or `props.painter` for one.
pub const Painter = *const fn (ctx: *PaintCtx, b: *const Button) paint_ctx.Error!void;

pub const Text = @import("common.zig").Text;

/// A button's link to a command: clicking the button runs the command.
pub const CommandLink = struct {
    ui: *Ui,
    name: []u8,
};

pub const Button = struct {
    props: Props = .{},
    out: Out = .{},
    node: Handle,
    ui: *Ui,
    /// Internal: verifies raw `props` writes (empty unless `ui_checks` is on).
    checker: shadow.Checker(Props),
    /// Internal: the command this button runs, if linked.
    link: ?*CommandLink = null,

    pub const Props = struct {
        text: Text = .{},
        enabled: bool = true,
        variant: Variant = .normal,
        text_align: Align = .center,
        on_click: ?event.Callback = null,
        /// Overrides the theme's colors for this button (all states).
        colors: ?ButtonColors = null,
        /// Overrides the theme's painter for this button. Use `setPainter` so
        /// the change repaints.
        painter: ?Painter = null,

        pub const dirty_map = .{
            .colors = shadow.Category.paint,
            .text = shadow.Category.layout,
            .enabled = shadow.Category.paint,
            .variant = shadow.Category.paint,
            .text_align = shadow.Category.paint,
        };
    };

    pub const Out = struct {
        /// A click happened this frame.
        clicked: bool = false,
        hovered: bool = false,
        pressed: bool = false,
        /// Has keyboard focus.
        focused: bool = false,
        /// Focused after keyboard use: painters draw a focus ring.
        focus_visible: bool = false,
        /// Total clicks since creation.
        click_count: u32 = 0,
    };

    /// What `Ui.add(Button, parent, .{ ... })` accepts.
    pub const Options = struct {
        style: Style = .{},
        text: []const u8 = "",
        variant: Variant = .normal,
        enabled: bool = true,
        text_align: Align = .center,
        on_click: ?event.Callback = null,
        /// Run this command when clicked (see `setCommand`).
        command: ?[]const u8 = null,
        colors: ?ButtonColors = null,
        painter: ?Painter = null,
    };

    pub const listened_kinds = [_]event.EventKind{ .pointer_enter, .pointer_leave, .pointer_down, .pointer_up, .click, .focus_in, .focus_out, .key_down };

    pub fn themePadding(theme: *const theme_mod.Theme) @import("../core/style.zig").Edges {
        return theme.button_padding;
    }

    pub fn nodeTemplate(style: Style) Node {
        return .{ .role = .button, .flags = .{ .focusable = true }, .style = style };
    }

    pub fn apply(self: *Button, o: Options) !void {
        self.props.variant = o.variant;
        self.props.enabled = o.enabled;
        self.props.text_align = o.text_align;
        self.props.on_click = o.on_click;
        self.props.colors = o.colors;
        self.props.painter = o.painter;
        if (o.text.len > 0) try self.setText(o.text);
        if (o.command) |c| try self.setCommand(c);
        self.checker.sync(&self.props);
    }

    pub fn init(ui: *Ui, node: Handle) Button {
        const props: Props = .{};
        return .{ .node = node, .ui = ui, .checker = shadow.Checker(Props).init(&props) };
    }

    pub fn deinit(self: *Button) void {
        self.ui.freeText(&self.props.text);
        self.freeLink();
    }

    // ---- setters ----------------------------------------------------------

    /// Copy `text` into toolkit-owned storage; the caller may free its own copy.
    pub fn setText(self: *Button, text: []const u8) !void {
        try self.ui.replaceText(&self.props.text, text);
        self.ui.tree.markDirty(self.node, DirtyFlags.layout_and_paint);
    }

    pub fn setEnabled(self: *Button, enabled: bool) void {
        if (self.props.enabled == enabled) return;
        self.props.enabled = enabled;
        self.ui.tree.markDirty(self.node, DirtyFlags.paint_only);
    }

    /// Use `p` instead of the theme's painter for this button (null: back to the theme's).
    pub fn setPainter(self: *Button, p: ?Painter) void {
        self.props.painter = p;
        self.repaint();
    }

    /// The colors in effect: this button's override, else the theme's for its variant.
    pub fn colors(self: *const Button) ButtonColors {
        if (self.props.colors) |c| return c;
        const t = &self.ui.theme;
        return t.button_colors[@min(@intFromEnum(self.props.variant), t.button_colors.len - 1)];
    }

    fn repaint(self: *Button) void {
        self.ui.tree.markDirty(self.node, DirtyFlags.paint_only);
    }

    /// The node's painter hook: runs this button's painter, else the theme's.
    pub fn paintHook(self: *Button, pc: *PaintCtx) paint_ctx.Error!void {
        const p = self.props.painter orelse self.ui.theme.button_painter;
        try p(pc, self);
    }

    pub fn setVariant(self: *Button, variant: Variant) void {
        if (self.props.variant == variant) return;
        self.props.variant = variant;
        self.ui.tree.markDirty(self.node, DirtyFlags.paint_only);
    }

    fn freeLink(self: *Button) void {
        const link = self.link orelse return;
        self.ui.gpa.free(link.name);
        self.ui.gpa.destroy(link);
        self.link = null;
    }

    fn linkClicked(link: *CommandLink, ev: *event.Event) void {
        _ = ev;
        _ = link.ui.invokeCommand(link.name);
    }

    /// Make clicking the button run `command`. The button is enabled only while
    /// the command is (this overrides `props.enabled`), and the command need not
    /// exist yet. Use the same command for a button, a menu item, and a shortcut
    /// to keep them in sync.
    pub fn setCommand(self: *Button, command: []const u8) !void {
        const link = try self.ui.gpa.create(CommandLink);
        errdefer self.ui.gpa.destroy(link);
        link.* = .{ .ui = self.ui, .name = try self.ui.gpa.dupe(u8, command) };
        self.freeLink();
        self.link = link;
        self.props.on_click = event.Callback.bind(link, linkClicked);
    }

    // ---- events -----------------------------------------------------------

    /// Shared listener for every button event kind.
    pub fn handleEvent(b: *Button, ev: *event.Event) void {
        // State that painters read changes here, so every change repaints.
        switch (ev.kind) {
            .focus_in, .focus_out, .pointer_enter, .pointer_leave, .pointer_down, .pointer_up => b.repaint(),
            else => {},
        }
        switch (ev.kind) {
            .focus_in => b.out.focused = true,
            .focus_out => b.out.focused = false,
            // Enter and Space activate, like a click.
            .key_down => if (b.props.enabled and !ev.repeat and (ev.key == .enter or ev.key == .space)) {
                ev.markHandled();
                b.activate(ev);
            },
            .pointer_enter => b.out.hovered = true,
            .pointer_leave => b.out.hovered = false,
            .pointer_down => if (b.props.enabled) {
                b.out.pressed = true;
            },
            .pointer_up => b.out.pressed = false,
            .click => if (b.props.enabled) b.activate(ev),
            else => {},
        }
    }

    /// The one path for clicks and keyboard activation, so flags and callbacks agree.
    fn activate(b: *Button, ev: *event.Event) void {
        b.out.clicked = true;
        b.out.click_count +%= 1;
        if (b.props.on_click) |cb| cb.invoke(ev);
    }

    // ---- frame ------------------------------------------------------------

    /// Before focus is settled for the frame: follow a linked command and make
    /// disabled buttons unfocusable.
    pub fn prepare(self: *Button) void {
        const ui = self.ui;
        if (self.link) |link| {
            const enabled = if (ui.commands.find(link.name)) |h| ui.commands.isEnabled(h) else false;
            self.setEnabled(enabled);
        }
        ui.tree.get(self.node).?.flags.focusable = self.props.enabled;
    }

    /// Verify raw prop writes and keep the node's text in sync. (The look is the
    /// painter's job, at paint time.)
    pub fn update(self: *Button) void {
        const ui = self.ui;
        ui.verifyProps(self.node, &self.checker, &self.props, "button");
        const focus_visible = self.out.focused and ui.input.keyboard;
        if (focus_visible != self.out.focus_visible) {
            self.out.focus_visible = focus_visible;
            self.repaint();
        }
        ui.syncText(self.node, self.props.text, ui.theme.ui_font, ui.theme.font_size, ui.theme.text_color, self.props.text_align);
    }

    pub fn endFrame(self: *Button) void {
        self.out.clicked = false;
    }
};

/// The default look: a rounded box tinted by state, with a focus ring after
/// keyboard use, and text colored for enabled/disabled.
pub fn defaultPainter(pc: *PaintCtx, b: *const Button) paint_ctx.Error!void {
    const theme = &b.ui.theme;
    const c = b.colors();
    const bg = if (!b.props.enabled)
        c.disabled
    else if (b.out.pressed)
        c.pressed
    else if (b.out.hovered)
        c.hover
    else
        c.normal;
    const ring = b.out.focus_visible and b.props.enabled;
    try pc.box(.{
        .background = bg,
        .border_color = if (ring) theme.focus_ring else c.border,
        .border_width = if (ring) theme.focus_ring_width else c.border_width,
        .radius = theme.corner_radius,
    });
    pc.text_color = if (b.props.enabled) c.text else c.text_disabled;
}
