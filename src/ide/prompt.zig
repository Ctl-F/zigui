//! A one-line question for the user: a label and a text field in a bar that
//! appears in the layout while it is open ("Rename handler to: ____"). Enter
//! submits, Escape cancels, and focus goes back to where it was.
//!
//!     const prompt = try Prompt.create(&ui, parent);       // hidden until asked
//!     prompt.ask("Name of the new file:", "untitled.ui.zon", .bind(&app, App.onName));
//!     // fn onName(self: *App, text: []const u8) void       (the bar closes first)
//!
//! `setTitle` changes the question while it is open and `keepOpen` makes the
//! next Enter leave the bar up (for "this will change 3 files, press Enter
//! again").

const std = @import("std");
const Handle = @import("../core/handle.zig").Handle;
const Ui = @import("../core/ui.zig").Ui;
const event = @import("../core/event.zig");
const Label = @import("../widgets/label.zig").Label;
const TextField = @import("../widgets/text_field.zig").TextField;
const Length = @import("../core/length.zig").Length;
const Edges = @import("../core/style.zig").Edges;
const Color = @import("../core/geometry.zig").Color;

pub const SubmitHook = struct {
    ctx: ?*anyopaque = null,
    call: *const fn (ctx: ?*anyopaque, text: []const u8) void,

    pub fn bind(ctx: anytype, comptime f: anytype) SubmitHook {
        const Ptr = @TypeOf(ctx);
        return .{
            .ctx = @ptrCast(ctx),
            .call = &struct {
                fn thunk(c: ?*anyopaque, text: []const u8) void {
                    f(@as(Ptr, @ptrCast(@alignCast(c.?))), text);
                }
            }.thunk,
        };
    }
};

pub const Prompt = struct {
    gpa: std.mem.Allocator,
    ui: *Ui,
    node: Handle,
    label: *Label,
    field: *TextField,
    hook: ?SubmitHook = null,
    /// Where focus was when the question was asked.
    previous: Handle = Handle.invalid,
    open: bool = false,
    /// The next submit leaves the bar open.
    keep_open: bool = false,

    pub fn create(ui: *Ui, parent: Handle) !*Prompt {
        const self = try ui.gpa.create(Prompt);
        errdefer ui.gpa.destroy(self);
        const node = try ui.tree.create(.{
            .style = .{ .direction = .row, .gap = Length.px(8), .align_items = .center, .padding = Edges.xy(8, 4), .shrink = 0 },
            .visual = .{ .background = Color.rgb(0x2b, 0x2d, 0x31) },
            .flags = .{ .hidden = true },
            .role = .panel,
        });
        errdefer _ = ui.tree.destroySubtree(node);
        try ui.tree.appendChild(parent, node);
        const label = try ui.add(Label, node, .{ .text = "", .style = .{ .shrink = 0 } });
        const field = try ui.add(TextField, node, .{ .label = "Answer", .style = .{ .grow = 1 }, .on_submit = .bind(self, onSubmit) });
        self.* = .{ .gpa = ui.gpa, .ui = ui, .node = node, .label = label, .field = field };
        try ui.tree.addListener(field.node, .{ .kind = .key_down, .callback = .bind(self, onKey) });
        return self;
    }

    pub fn destroy(self: *Prompt) void {
        self.gpa.destroy(self);
    }

    /// Show the bar with `title` and `initial` text selected; `hook` gets the answer.
    pub fn ask(self: *Prompt, title: []const u8, initial: []const u8, hook: SubmitHook) void {
        self.hook = hook;
        self.keep_open = false;
        if (!self.open) self.previous = self.ui.tree.focused;
        self.open = true;
        self.label.setText(title) catch {};
        self.field.setText(initial) catch {};
        self.ui.setHidden(self.node, false);
        self.ui.setFocus(self.field.node);
        self.field.editor.selectAll();
    }

    pub fn setTitle(self: *Prompt, title: []const u8) void {
        self.label.setText(title) catch {};
    }

    pub fn text(self: *Prompt) []const u8 {
        return self.field.text();
    }

    pub fn close(self: *Prompt) void {
        if (!self.open) return;
        self.open = false;
        self.ui.setHidden(self.node, true);
        if (self.ui.tree.isValid(self.previous)) self.ui.setFocus(self.previous);
        self.previous = Handle.invalid;
    }

    fn onSubmit(self: *Prompt, _: *event.Event) void {
        const hook = self.hook orelse return self.close();
        // The answer is copied: closing and the hook may change the field.
        const answer = self.gpa.dupe(u8, self.field.text()) catch return;
        defer self.gpa.free(answer);
        self.keep_open = false;
        // The hook may call `ask` again (a follow-up question) or `keepOpen`.
        const was_open = self.open;
        self.close();
        if (!was_open) return;
        hook.call(hook.ctx, answer);
        if (self.keep_open and !self.open) self.ask(self.label.props.text.bytes, answer, hook);
    }

    /// From inside the hook: leave the bar up with the same text (it was closed to
    /// hand focus back; this reopens it).
    pub fn keepOpen(self: *Prompt) void {
        self.keep_open = true;
    }

    fn onKey(self: *Prompt, ev: *event.Event) void {
        if (ev.key == .escape and self.open) {
            self.close();
            ev.markHandled();
        }
    }
};

const testing = std.testing;
const Rig = @import("../core/test_rig.zig").Rig;

const Answers = struct {
    got: [64]u8 = undefined,
    len: usize = 0,
    calls: u32 = 0,
    prompt: ?*Prompt = null,
    again: bool = false,
    fn on(self: *Answers, text: []const u8) void {
        @memcpy(self.got[0..text.len], text);
        self.len = text.len;
        self.calls += 1;
        if (self.again) if (self.prompt) |p| p.keepOpen();
    }
};

test "ask, answer with Enter, cancel with Escape; focus returns" {
    const r = try Rig.init();
    defer r.deinit();
    const other = try r.ui.add(TextField, r.ui.tree.root, .{});
    r.ui.setFocus(other.node);
    const p = try Prompt.create(&r.ui, r.ui.tree.root);
    defer p.destroy();
    try r.frame();
    var a: Answers = .{ .prompt = p };
    p.ask("Name:", "draft", .bind(&a, Answers.on));
    try r.frame();
    try testing.expect(p.open);
    try testing.expect(r.ui.tree.focused.eql(p.field.node));
    r.ui.textInput("X"); // replaces the selected initial text
    r.ui.key(.enter, .{}, true, false);
    try testing.expectEqualStrings("X", a.got[0..a.len]);
    try testing.expect(!p.open);
    try testing.expect(r.ui.tree.focused.eql(other.node));
    try testing.expectEqual(@as(u32, 1), a.calls);
    // Escape cancels without calling the hook.
    p.ask("Again:", "", .bind(&a, Answers.on));
    r.ui.key(.escape, .{}, true, false);
    try testing.expect(!p.open);
    try testing.expectEqual(@as(u32, 1), a.calls);
    // A hook can keep the bar up for a confirming second Enter.
    a.again = true;
    p.ask("Confirm?", "yes", .bind(&a, Answers.on));
    r.ui.key(.enter, .{}, true, false);
    try testing.expect(p.open);
    try testing.expectEqualStrings("yes", p.text());
    a.again = false;
    r.ui.key(.enter, .{}, true, false);
    try testing.expect(!p.open);
    try testing.expectEqual(@as(u32, 3), a.calls);
}
