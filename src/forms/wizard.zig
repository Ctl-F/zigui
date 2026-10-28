//! Wizards (design doc section 11): an ordered list of pages over one result
//! struct, with the chrome supplied here (title, step indicator, Back, Next or
//! Finish, Cancel).
//!
//! A page is one of:
//!   - generated: shows some of `T`'s top-level fields, chosen by name
//!     (`.fields`) or by the `group` in their `ui` metadata (`.group`), through
//!     the same machinery as `Form`;
//!   - custom: `.custom` builds any widgets under the page host.
//! Either kind may add a `can_next` check on the whole value; it returns a
//! message to block Next (or Finish) and show why, or null to allow it.
//! Generated pages also block on their own parse and `validate` errors.
//!
//! `generatedPages(T)` splits a struct into one page per `ui` group, in order of
//! first appearance (fields without a group come first, as "General").
//!
//! Like `Form`, a wizard is polled: read `state`, then `take` the value.

const std = @import("std");
const schema = @import("../core/schema.zig");
const ui_mod = @import("../core/ui.zig");
const Ui = ui_mod.Ui;
const event = @import("../core/event.zig");
const Handle = @import("../core/handle.zig").Handle;
const Length = @import("../core/length.zig").Length;
const Color = @import("../core/geometry.zig").Color;
const Button = @import("../widgets/button.zig").Button;
const Label = @import("../widgets/label.zig").Label;
const form_mod = @import("form.zig");

pub const State = form_mod.State;

pub const Custom = struct {
    ctx: ?*anyopaque = null,
    /// Build the page's widgets under `host`. Called each time the page is shown.
    build: *const fn (ctx: ?*anyopaque, ui: *Ui, host: Handle) anyerror!void,
};

pub fn Wizard(comptime T: type) type {
    const F = form_mod.Form(T);
    return struct {
        const Self = @This();

        pub const Page = struct {
            title: []const u8,
            /// Generated page: these top-level fields (all fields if neither
            /// `fields` nor `group` is set).
            fields: ?[]const []const u8 = null,
            /// Generated page: fields whose `ui` group is this.
            group: ?[]const u8 = null,
            custom: ?Custom = null,
            can_next: ?*const fn (value: *const T) ?[]const u8 = null,
        };

        pub const Options = struct {
            title: []const u8 = "",
            next_label: []const u8 = "Next",
            back_label: []const u8 = "Back",
            finish_label: []const u8 = "Finish",
            cancel_label: []const u8 = "Cancel",
            label_width: f32 = 140,
        };

        ui: *Ui,
        gpa: std.mem.Allocator,
        pages: []const Page,
        opts: Options,
        form: *F,
        state: State = .open,
        /// Index of the page being shown.
        page: usize = 0,
        root: Handle = Handle.invalid,
        indicator: *Label = undefined,
        host: Handle = Handle.invalid,
        block_label: *Label = undefined,
        cancel: *Button = undefined,
        back: *Button = undefined,
        next: *Button = undefined,
        /// Why Next is blocked on a custom page or by `can_next`, or "".
        blocked: []const u8 = "",
        step_text: []u8 = &.{},

        /// `pages` must outlive the wizard.
        pub fn create(ui: *Ui, parent: Handle, pages: []const Page, opts: Options) !*Self {
            std.debug.assert(pages.len > 0);
            const self = try ui.gpa.create(Self);
            errdefer ui.gpa.destroy(self);
            self.* = .{ .ui = ui, .gpa = ui.gpa, .pages = pages, .opts = opts, .form = undefined };

            self.root = try self.node(parent, .{ .direction = .column, .gap = Length.px(10) });
            errdefer _ = ui.tree.destroySubtree(self.root);
            if (opts.title.len > 0) _ = try ui.add(Label, self.root, .{ .text = opts.title, .size = 18 });
            self.indicator = try ui.add(Label, self.root, .{});
            const content = try self.node(self.root, .{ .direction = .column, .gap = Length.px(6) });
            self.form = try F.create(ui, content, .{ .footer = false, .label_width = opts.label_width, .group = "" });
            errdefer self.form.destroy();
            self.form.notify = event.Callback.bind(self, onFormChanged);
            self.host = try self.node(content, .{ .direction = .column, .gap = Length.px(6) });
            self.block_label = try ui.add(Label, self.root, .{ .color = Color.rgb(224, 96, 96) });

            const footer = try self.node(self.root, .{ .direction = .row, .gap = Length.px(8) });
            self.cancel = try ui.add(Button, footer, .{ .text = opts.cancel_label });
            self.cancel.props.on_click = event.Callback.bind(self, onCancel);
            _ = try self.node(footer, .{ .grow = 1 });
            self.back = try ui.add(Button, footer, .{ .text = opts.back_label });
            self.back.props.on_click = event.Callback.bind(self, onBack);
            self.next = try ui.add(Button, footer, .{ .text = opts.next_label, .variant = .primary });
            self.next.props.on_click = event.Callback.bind(self, onNext);

            try self.show(0);
            return self;
        }

        pub fn destroy(self: *Self) void {
            self.form.destroy();
            _ = self.ui.tree.destroySubtree(self.root);
            if (self.step_text.len > 0) self.gpa.free(self.step_text);
            self.gpa.destroy(self);
        }

        /// A copy of the collected value that you own (free with `form.freeOwned`).
        pub fn take(self: *const Self, a: std.mem.Allocator) !T {
            return self.form.take(a);
        }

        /// The value being collected; set fields before showing for defaults.
        pub fn value(self: *Self) *T {
            return &self.form.value;
        }

        fn node(self: *Self, parent: Handle, style: @import("../core/style.zig").Style) !Handle {
            const h = try self.ui.tree.create(.{ .style = style });
            errdefer _ = self.ui.tree.destroySubtree(h);
            try self.ui.tree.appendChild(parent, h);
            return h;
        }

        fn setHidden(self: *Self, h: Handle, hidden: bool) void {
            const n = self.ui.tree.get(h) orelse return;
            if (n.flags.hidden == hidden) return;
            n.flags.hidden = hidden;
            self.ui.tree.markDirty(h, .{ .layout = true, .paint = true });
        }

        fn clearChildren(self: *Self, h: Handle) void {
            var child = self.ui.tree.get(h).?.first_child;
            while (self.ui.tree.get(child)) |n| {
                const next = n.next;
                _ = self.ui.tree.destroySubtree(child);
                child = next;
            }
        }

        /// Show page `i`.
        pub fn show(self: *Self, i: usize) !void {
            std.debug.assert(i < self.pages.len);
            self.page = i;
            const p = self.pages[i];
            self.clearChildren(self.host);
            if (p.custom) |c| {
                self.setHidden(self.form.root, true);
                self.setHidden(self.host, false);
                try c.build(c.ctx, self.ui, self.host);
            } else {
                self.setHidden(self.host, true);
                self.setHidden(self.form.root, false);
                self.form.opts.only = p.fields;
                self.form.opts.group = if (p.fields == null and p.group == null) null else p.group;
                self.form.page_final = i + 1 == self.pages.len;
                try self.form.rebuild();
            }
            const text = try std.fmt.allocPrint(self.gpa, "Step {d} of {d}: {s}", .{ i + 1, self.pages.len, p.title });
            if (self.step_text.len > 0) self.gpa.free(self.step_text);
            self.step_text = text;
            try self.indicator.setText(text);
            self.refresh();
        }

        fn onFormChanged(self: *Self, _: *event.Event) void {
            self.refresh();
        }

        /// Recompute Back/Next enablement and the blocking message.
        pub fn refresh(self: *Self) void {
            const p = self.pages[self.page];
            var reason: []const u8 = "";
            if (p.custom == null and !self.form.out.valid) reason = "Fix the highlighted fields to continue";
            if (reason.len == 0) {
                if (p.can_next) |check| {
                    if (check(&self.form.value)) |msg| reason = msg;
                }
            }
            self.blocked = reason;
            if (!std.mem.eql(u8, self.block_label.props.text.bytes, reason)) self.block_label.setText(reason) catch {};
            self.next.setEnabled(reason.len == 0);
            self.back.setEnabled(self.page > 0);
            const last = self.page + 1 == self.pages.len;
            const want = if (last) self.opts.finish_label else self.opts.next_label;
            if (!std.mem.eql(u8, self.next.props.text.bytes, want)) self.next.setText(want) catch {};
        }

        fn onNext(self: *Self, _: *event.Event) void {
            if (self.state != .open or self.blocked.len > 0) return;
            if (self.page + 1 == self.pages.len) {
                self.state = .submitted;
                return;
            }
            self.show(self.page + 1) catch {};
        }

        fn onBack(self: *Self, _: *event.Event) void {
            if (self.state != .open or self.page == 0) return;
            self.show(self.page - 1) catch {};
        }

        fn onCancel(self: *Self, _: *event.Event) void {
            if (self.state == .open) self.state = .cancelled;
        }
    };
}

/// The `ui` group names of `T`'s editable fields, in order of first appearance
/// (`""` is the ungrouped fields).
pub fn groupsOf(comptime T: type) []const []const u8 {
    const t = schema.typeOf(T);
    const names = comptime blk: {
        var out: [t.fields.len][]const u8 = undefined;
        var n: usize = 0;
        for (t.fields) |f| {
            if (f.meta.hidden or !f.type.isEditable()) continue;
            const g = f.meta.group orelse "";
            var seen = false;
            for (out[0..n]) |x| seen = seen or std.mem.eql(u8, x, g);
            if (!seen) {
                out[n] = g;
                n += 1;
            }
        }
        var exact: [n][]const u8 = undefined;
        for (out[0..n], 0..) |x, i| exact[i] = x;
        break :blk exact;
    };
    return &names;
}

/// Pages for `Wizard(T)`, one per group of `T`.
pub fn generatedPages(comptime T: type) []const Wizard(T).Page {
    const gs = comptime groupsOf(T);
    const pages = comptime blk: {
        var out: [gs.len]Wizard(T).Page = undefined;
        for (gs, 0..) |g, i| out[i] = .{ .title = if (g.len == 0) "General" else g, .group = g };
        break :blk out;
    };
    return &pages;
}

// ---- tests -----------------------------------------------------------------

const testing = std.testing;

const Mode = enum { fast, slow };

const Setup = struct {
    name: []const u8 = "site",
    port: u16 = 80,
    mode: Mode = .fast,
    debug: bool = false,
    user: []const u8 = "admin",
    retries: u8 = 3,

    pub const ui = .{
        .port = .{ .group = "Network" },
        .mode = .{ .group = "Network" },
        .user = .{ .group = "Access" },
        .retries = .{ .group = "Access", .min = 1, .max = 5 },
    };

    pub fn validate(self: *const Setup, report: *form_mod.Report) void {
        if (self.name.len == 0) report.add("name", "Name is required");
    }
};

const W = Wizard(Setup);

fn click(b: *Button) void {
    var ev: event.Event = .{ .kind = .pointer_up };
    b.props.on_click.?.invoke(&ev);
}

fn bindingFor(w: *W, path: []const u8) @TypeOf(w.form.bindings.items[0]) {
    for (w.form.bindings.items) |b| if (b.kind != .presence and std.mem.eql(u8, b.path, path)) return b;
    @panic("no binding");
}

fn typeInto(ui: *Ui, b: anytype, text: []const u8) void {
    ui.setFocus(b.field.?.node);
    ui.key(.a, .{ .ctrl = true }, true, false);
    if (text.len == 0) ui.key(.backspace, .{}, true, false) else ui.textInput(text);
}

test "groupsOf lists groups in order of first appearance, ungrouped first" {
    const gs = comptime groupsOf(Setup);
    try testing.expectEqual(@as(usize, 3), gs.len);
    try testing.expectEqualStrings("", gs[0]);
    try testing.expectEqualStrings("Network", gs[1]);
    try testing.expectEqualStrings("Access", gs[2]);
    const pages = comptime generatedPages(Setup);
    try testing.expectEqualStrings("General", pages[0].title);
    try testing.expectEqualStrings("Network", pages[1].title);
}

test "a generated wizard walks pages, each showing only its group" {
    var ui = try Ui.init(testing.allocator);
    defer ui.deinit();
    const w = try W.create(&ui, ui.tree.root, comptime generatedPages(Setup), .{ .title = "Setup" });
    defer w.destroy();

    try testing.expectEqualStrings("Step 1 of 3: General", w.indicator.props.text.bytes);
    try testing.expectEqual(@as(usize, 2), w.form.bindings.items.len); // name, debug
    try testing.expect(!w.back.props.enabled);
    try testing.expectEqualStrings("Next", w.next.props.text.bytes);

    click(w.next);
    try testing.expectEqual(@as(usize, 1), w.page);
    try testing.expectEqualStrings("Step 2 of 3: Network", w.indicator.props.text.bytes);
    _ = bindingFor(w, "port");
    _ = bindingFor(w, "mode");
    try testing.expectEqual(@as(usize, 2), w.form.bindings.items.len);
    try testing.expect(w.back.props.enabled);

    click(w.next);
    try testing.expectEqualStrings("Finish", w.next.props.text.bytes);
    click(w.back);
    try testing.expectEqual(@as(usize, 1), w.page);
    try testing.expectEqualStrings("Next", w.next.props.text.bytes);
}

test "edits survive paging, and Finish returns the whole value" {
    var ui = try Ui.init(testing.allocator);
    defer ui.deinit();
    const w = try W.create(&ui, ui.tree.root, comptime generatedPages(Setup), .{});
    defer w.destroy();
    typeInto(&ui, bindingFor(w, "name"), "prod");
    click(w.next);
    typeInto(&ui, bindingFor(w, "port"), "8080");
    click(w.next);
    typeInto(&ui, bindingFor(w, "user"), "root");
    click(w.back);
    click(w.back);
    try testing.expectEqualStrings("prod", bindingFor(w, "name").field.?.text()); // shown again from the value
    click(w.next);
    click(w.next);
    try testing.expect(w.state == .open);
    click(w.next); // Finish
    try testing.expect(w.state == .submitted);
    const v = try w.take(testing.allocator);
    defer form_mod.freeOwned(Setup, v, testing.allocator);
    try testing.expectEqualStrings("prod", v.name);
    try testing.expectEqual(@as(u16, 8080), v.port);
    try testing.expectEqualStrings("root", v.user);
}

test "a page with errors blocks Next; errors on other pages do not" {
    var ui = try Ui.init(testing.allocator);
    defer ui.deinit();
    const w = try W.create(&ui, ui.tree.root, comptime generatedPages(Setup), .{});
    defer w.destroy();
    typeInto(&ui, bindingFor(w, "name"), "");
    try testing.expect(!w.next.props.enabled);
    try testing.expectEqualStrings("Fix the highlighted fields to continue", w.block_label.props.text.bytes);
    click(w.next);
    try testing.expectEqual(@as(usize, 0), w.page);
    typeInto(&ui, bindingFor(w, "name"), "ok");
    try testing.expect(w.next.props.enabled);
    click(w.next);
    // A bad port blocks the Network page only.
    typeInto(&ui, bindingFor(w, "port"), "99999");
    try testing.expect(!w.next.props.enabled);
}

fn needsSlow(v: *const Setup) ?[]const u8 {
    return if (v.mode == .fast and v.debug) "Debug needs slow mode" else null;
}

const Custom1 = struct {
    var built: u32 = 0;
    fn build(_: ?*anyopaque, u: *Ui, host: Handle) anyerror!void {
        built += 1;
        _ = try u.add(Label, host, .{ .text = "Review and confirm" });
    }
};

test "explicit pages: named fields, a custom page, and can_next conditions" {
    var ui = try Ui.init(testing.allocator);
    defer ui.deinit();
    Custom1.built = 0;
    const pages = [_]W.Page{
        .{ .title = "Basics", .fields = &.{ "name", "debug", "mode" }, .can_next = needsSlow },
        .{ .title = "Review", .custom = .{ .build = Custom1.build } },
    };
    const w = try W.create(&ui, ui.tree.root, &pages, .{});
    defer w.destroy();
    try testing.expectEqual(@as(usize, 3), w.form.bindings.items.len);

    clickToggle(w, "debug");
    try testing.expect(!w.next.props.enabled);
    try testing.expectEqualStrings("Debug needs slow mode", w.block_label.props.text.bytes);
    bindingFor(w, "mode").select.?.setSelected(1); // fast -> slow
    try testing.expect(w.next.props.enabled);

    click(w.next);
    try testing.expectEqual(@as(u32, 1), Custom1.built);
    try testing.expect(ui.tree.get(w.form.root).?.flags.hidden);
    try testing.expect(!ui.tree.get(w.host).?.flags.hidden);
    try testing.expectEqualStrings("Finish", w.next.props.text.bytes);
    click(w.back);
    try testing.expect(!ui.tree.get(w.form.root).?.flags.hidden);
    try testing.expect(ui.tree.get(w.host).?.flags.hidden);
    click(w.next);
    try testing.expectEqual(@as(u32, 2), Custom1.built); // rebuilt on each visit
    click(w.next);
    try testing.expect(w.state == .submitted);
}

fn clickToggle(w: *W, path: []const u8) void {
    click(bindingFor(w, path).button.?);
}

test "cancel ends the wizard and Next after that does nothing" {
    var ui = try Ui.init(testing.allocator);
    defer ui.deinit();
    const w = try W.create(&ui, ui.tree.root, comptime generatedPages(Setup), .{});
    defer w.destroy();
    click(w.cancel);
    try testing.expect(w.state == .cancelled);
    click(w.next);
    try testing.expectEqual(@as(usize, 0), w.page);
}
