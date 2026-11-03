//! A modal message box: a title, a few lines of text and up to four buttons.
//! For a question the program must ask before going on ("Install it now?").
//!
//!     const mb = try MessageBox.create(&ui, ui.tree.root);        // hidden until shown
//!     defer mb.destroy();
//!     mb.show(.{ .title = "ZVM not found", .message = "ZVM is not installed.\nInstall it now?",
//!                .buttons = &.{ "Install", "Not now" },
//!                .on_choice = .bind(&app, App.chose) });            // fn (*App, index: usize) void
//!
//! `\n` in the message starts a new line (lines are not wrapped). The first
//! button is the default (Enter); Escape chooses `cancel` (default: the last
//! button). The hook runs after the box has closed. While it is open the rest of
//! the window ignores input.

const std = @import("std");
const Handle = @import("../core/handle.zig").Handle;
const Ui = @import("../core/ui.zig").Ui;
const event = @import("../core/event.zig");
const Length = @import("../core/length.zig").Length;
const Edges = @import("../core/style.zig").Edges;
const Color = @import("../core/geometry.zig").Color;
const Label = @import("label.zig").Label;
const Button = @import("button.zig").Button;

pub const max_buttons = 4;
pub const max_lines = 10;

pub const ChoiceHook = struct {
    ctx: ?*anyopaque = null,
    call: *const fn (ctx: ?*anyopaque, index: usize) void,

    pub fn bind(ctx: anytype, comptime f: anytype) ChoiceHook {
        const Ptr = @TypeOf(ctx);
        return .{
            .ctx = @ptrCast(ctx),
            .call = &struct {
                fn thunk(c: ?*anyopaque, index: usize) void {
                    f(@as(Ptr, @ptrCast(@alignCast(c.?))), index);
                }
            }.thunk,
        };
    }
};

pub const Options = struct {
    title: []const u8 = "",
    message: []const u8 = "",
    buttons: []const []const u8 = &.{"OK"},
    /// The button Escape chooses (null: the last one).
    cancel: ?usize = null,
    on_choice: ?ChoiceHook = null,
};

pub const MessageBox = struct {
    gpa: std.mem.Allocator,
    ui: *Ui,
    node: Handle,
    panel: Handle,
    title: *Label,
    lines: [max_lines]*Label,
    buttons: [max_buttons]*Button,
    count: usize = 0,
    cancel: usize = 0,
    hook: ?ChoiceHook = null,
    open: bool = false,
    scoped: bool = false,

    pub fn create(ui: *Ui, parent: Handle) !*MessageBox {
        const self = try ui.gpa.create(MessageBox);
        errdefer ui.gpa.destroy(self);
        const tree = &ui.tree;
        const node = try tree.create(.{
            .style = .{ .position = .absolute, .inset = .{ .left = Length.px(0), .top = Length.px(0), .right = Length.px(0), .bottom = Length.px(0) }, .direction = .column, .align_items = .center, .justify = .center },
            .visual = .{ .background = Color.rgba(0, 0, 0, 120) },
            .flags = .{ .hidden = true },
            .role = .panel,
        });
        errdefer _ = tree.destroySubtree(node);
        try tree.appendChild(parent, node);
        try tree.setLabel(node, "Message");
        try tree.addListener(node, .{ .kind = .pointer_down, .callback = .bind(self, onBackdrop) });
        const panel = try tree.create(.{
            .style = .{ .direction = .column, .gap = Length.px(6), .padding = Edges.all(16), .min_width = Length.px(380), .shrink = 1 },
            .visual = .{ .background = Color.rgb(0x2b, 0x2d, 0x31), .border_color = Color.rgb(0x4a, 0x4d, 0x52), .border_width = 1, .radius = 6 },
            .role = .panel,
        });
        try tree.appendChild(node, panel);
        try tree.addListener(panel, .{ .kind = .key_down, .callback = .bind(self, onKey) });
        const title = try ui.add(Label, panel, .{ .text = "", .size = 16, .style = .{ .shrink = 0, .margin = .{ .bottom = Length.px(4) } } });
        var lines: [max_lines]*Label = undefined;
        for (&lines) |*l| l.* = try ui.add(Label, panel, .{ .text = "", .style = .{ .shrink = 0 } });
        const row = try tree.create(.{ .style = .{ .direction = .row, .gap = Length.px(8), .justify = .end, .margin = .{ .top = Length.px(10) }, .shrink = 0 } });
        try tree.appendChild(panel, row);
        var buttons: [max_buttons]*Button = undefined;
        for (&buttons) |*b| b.* = try ui.add(Button, row, .{ .text = "", .style = .{ .padding = Edges.xy(16, 6) }, .on_click = .bind(self, onButton) });
        self.* = .{ .gpa = ui.gpa, .ui = ui, .node = node, .panel = panel, .title = title, .lines = lines, .buttons = buttons };
        return self;
    }

    pub fn destroy(self: *MessageBox) void {
        if (self.scoped) self.ui.popFocusScope();
        self.gpa.destroy(self);
    }

    pub fn isOpen(self: *const MessageBox) bool {
        return self.open;
    }

    pub fn show(self: *MessageBox, o: Options) void {
        self.hook = o.on_choice;
        self.count = @min(o.buttons.len, max_buttons);
        if (self.count == 0) self.count = 0;
        self.cancel = if (o.cancel) |c| @min(c, self.count -| 1) else self.count -| 1;
        self.title.setText(o.title) catch {};
        var it = std.mem.splitScalar(u8, o.message, '\n');
        for (self.lines) |l| {
            const text = it.next() orelse "";
            l.setText(text) catch {};
            self.ui.setHidden(l.node, text.len == 0 and it.peek() == null);
        }
        for (self.buttons, 0..) |b, i| {
            self.ui.setHidden(b.node, i >= self.count);
            if (i < self.count) {
                b.setText(o.buttons[i]) catch {};
                b.setVariant(if (i == 0) .primary else .flat);
            }
        }
        if (!self.open) {
            self.open = true;
            self.ui.setHidden(self.node, false);
            self.scoped = self.ui.pushFocusScope(self.panel, true);
        }
        if (self.count > 0) self.ui.setFocus(self.buttons[0].node);
    }

    pub fn close(self: *MessageBox) void {
        if (!self.open) return;
        self.open = false;
        if (self.scoped) self.ui.popFocusScope();
        self.scoped = false;
        self.ui.setHidden(self.node, true);
    }

    /// Choose button `index` as if it had been clicked.
    pub fn choose(self: *MessageBox, index: usize) void {
        if (!self.open) return;
        const hook = self.hook;
        self.close();
        if (hook) |h| h.call(h.ctx, index);
    }

    fn onButton(self: *MessageBox, ev: *event.Event) void {
        for (self.buttons, 0..) |b, i| {
            if (ev.current.eql(b.node)) return self.choose(i);
        }
    }

    fn onBackdrop(self: *MessageBox, ev: *event.Event) void {
        if (ev.target.eql(self.node)) ev.markHandled();
    }

    fn onKey(self: *MessageBox, ev: *event.Event) void {
        if (ev.key == .escape and self.count > 0) {
            ev.markHandled();
            self.choose(self.cancel);
        }
    }
};

// ---- tests -----------------------------------------------------------------

const testing = std.testing;
const Rig = @import("../core/test_rig.zig").Rig;

const Got = struct {
    index: ?usize = null,
    fn on(self: *Got, i: usize) void {
        self.index = i;
    }
};

test "a button choice closes the box and reports its index; Escape chooses the cancel button" {
    const r = try Rig.init();
    defer r.deinit();
    const mb = try MessageBox.create(&r.ui, r.ui.tree.root);
    defer mb.destroy();
    var got: Got = .{};
    try r.frame();
    mb.show(.{ .title = "Install?", .message = "line one\nline two", .buttons = &.{ "Yes", "No", "Never" }, .on_choice = .bind(&got, Got.on) });
    try r.frame();
    try testing.expect(mb.isOpen());
    mb.choose(1);
    try testing.expectEqual(@as(?usize, 1), got.index);
    try testing.expect(!mb.isOpen());

    got.index = null;
    mb.show(.{ .title = "t", .message = "m", .buttons = &.{ "A", "B" }, .on_choice = .bind(&got, Got.on) });
    try r.frame();
    r.ui.key(.escape, .{}, true, false);
    try testing.expectEqual(@as(?usize, 1), got.index); // the last button
    try testing.expect(!mb.isOpen());

    got.index = null;
    mb.show(.{ .title = "t", .message = "m", .buttons = &.{ "A", "B" }, .cancel = 0, .on_choice = .bind(&got, Got.on) });
    try r.frame();
    r.ui.key(.escape, .{}, true, false);
    try testing.expectEqual(@as(?usize, 0), got.index);
}
