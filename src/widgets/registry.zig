//! Widget registry: every widget type described at runtime by its reflected
//! schema (design doc sections 12-13).
//!
//! One declaration per widget (its `Props` and `Out` structs) feeds this, the
//! shadow checker, and later the inspector, forms, and ZON loader. Nothing here
//! is written per widget except the list in `widgets`.
//!
//! Property writes go through the schema, then mark the node with the dirty
//! categories the widget's `dirty_map` declares, so a data-driven edit is
//! exactly as cheap and as correct as calling the typed setter.

const std = @import("std");
const schema = @import("../core/schema.zig");
const ui_mod = @import("../core/ui.zig");
const Ui = ui_mod.Ui;
const event = @import("../core/event.zig");
const Handle = @import("../core/handle.zig").Handle;
const DirtyFlags = @import("../core/dirty.zig").DirtyFlags;
const Style = @import("../core/style.zig").Style;
const Text = @import("common.zig").Text;
const Button = @import("button.zig").Button;
const Label = @import("label.zig").Label;
const TextField = @import("text_field.zig").TextField;
const CodeEditor = @import("code_editor.zig").CodeEditor;
const Canvas = @import("canvas.zig").Canvas;
const ScrollView = @import("scroll_view.zig").ScrollView;
const SplitView = @import("split_view.zig").SplitView;
const Select = @import("select.zig").Select;

pub const Error = schema.Error || error{ UnknownWidget, NotAWidget, StaleHandle };

/// What the registry knows about one widget type.
pub const Info = struct {
    name: []const u8,
    /// Schema of the app-written state.
    props: *const schema.Type,
    /// A `Props` value with every field at its default, for "what differs" diffs.
    props_default: *const anyopaque,
    /// Schema of the toolkit-written state (read-only to callers).
    out: *const schema.Type,
    type_tag: *const anyopaque,
    /// Create a widget with default options under `parent`.
    create: *const fn (ui: *Ui, parent: Handle) anyerror!Handle,
    propsPtr: *const fn (w: *anyopaque) *anyopaque,
    outPtr: *const fn (w: *anyopaque) *anyopaque,
    /// Event names this widget can report (`on_click` is "click").
    events: []const []const u8,
    /// Attach `cb` to the named event; false if the widget has no such event.
    setEvent: *const fn (w: *anyopaque, name: []const u8, cb: event.Callback) bool,
    /// For widgets whose text is content rather than a prop (text fields, code
    /// editors): set it. Null for widgets with a `text` prop.
    set_text: ?*const fn (w: *anyopaque, text: []const u8) anyerror!void,
    /// Widgets that hold their children in an inner node (scroll views): that
    /// node, where document children belong. Null: children go on the widget's node.
    content: ?*const fn (w: *anyopaque) Handle,
    /// Widgets with several panes: the node for child `index`, or null if the
    /// widget has no such pane.
    content_at: ?*const fn (w: *anyopaque, index: usize) ?Handle,
};

/// Props fields named `on_*` that hold an optional callback.
fn eventFieldNames(comptime Props: type) []const []const u8 {
    const names = comptime blk: {
        const info = @typeInfo(Props).@"struct";
        var out: [info.field_names.len][]const u8 = undefined;
        var n: usize = 0;
        for (info.field_names, info.field_types) |fname, FT| {
            if (std.mem.startsWith(u8, fname, "on_") and FT == ?event.Callback) {
                out[n] = fname;
                n += 1;
            }
        }
        var exact: [n][]const u8 = undefined;
        for (out[0..n], 0..) |x, i| exact[i] = x;
        break :blk exact;
    };
    return &names;
}

fn describe(comptime name: []const u8, comptime W: type) Info {
    const G = struct {
        fn create(ui: *Ui, parent: Handle) anyerror!Handle {
            const w = try ui.add(W, parent, .{});
            return w.node;
        }
        fn propsPtr(w: *anyopaque) *anyopaque {
            const x: *W = @ptrCast(@alignCast(w));
            return @ptrCast(&x.props);
        }
        fn outPtr(w: *anyopaque) *anyopaque {
            const x: *W = @ptrCast(@alignCast(w));
            return @ptrCast(&x.out);
        }
        fn setText(w: *anyopaque, text: []const u8) anyerror!void {
            const x: *W = @ptrCast(@alignCast(w));
            if (comptime @hasDecl(W, "loadText")) {
                const copy = try x.ui.gpa.dupe(u8, text);
                errdefer x.ui.gpa.free(copy);
                try x.loadText(copy, true);
            } else try x.setText(text);
        }
        fn contentAt(w: *anyopaque, index: usize) ?Handle {
            const x: *W = @ptrCast(@alignCast(w));
            return x.contentNodeAt(index);
        }
        fn content(w: *anyopaque) Handle {
            const x: *W = @ptrCast(@alignCast(w));
            return x.contentNode();
        }
        const default_props: W.Props = schema.defaultOf(W.Props);
        const event_fields = eventFieldNames(W.Props);
        const event_names = blk: {
            var out: [event_fields.len][]const u8 = undefined;
            for (event_fields, 0..) |f, i| out[i] = f[3..];
            break :blk out;
        };
        fn setEvent(w: *anyopaque, ev_name: []const u8, cb: event.Callback) bool {
            const x: *W = @ptrCast(@alignCast(w));
            inline for (event_fields) |f| {
                if (std.mem.eql(u8, ev_name, f[3..])) {
                    @field(x.props, f) = cb;
                    return true;
                }
            }
            return false;
        }
    };
    return .{
        .name = name,
        .props = schema.typeOf(W.Props),
        .props_default = &G.default_props,
        .out = schema.typeOf(W.Out),
        .type_tag = ui_mod.typeTag(W),
        .create = G.create,
        .propsPtr = G.propsPtr,
        .outPtr = G.outPtr,
        .events = &G.event_names,
        .setEvent = G.setEvent,
        .content = if (@hasDecl(W, "contentNode")) G.content else null,
        .content_at = if (@hasDecl(W, "contentNodeAt")) G.contentAt else null,
        .set_text = if (!@hasField(W.Props, "text") and (@hasDecl(W, "loadText") or @hasDecl(W, "setText"))) G.setText else null,
    };
}

/// The built-in widgets. Add a line here when adding a widget type.
pub const widgets = [_]Info{
    describe("button", Button),
    describe("label", Label),
    describe("text_field", TextField),
    describe("code_editor", CodeEditor),
    describe("canvas", Canvas),
    describe("scroll_view", ScrollView),
    describe("split_view", SplitView),
    describe("select", Select),
};

pub fn find(name: []const u8) ?*const Info {
    for (&widgets) |*w| if (std.mem.eql(u8, w.name, name)) return w;
    return null;
}

/// The registry entry for the widget on `node`, if it has one.
pub fn infoOf(ui: *Ui, node: Handle) ?*const Info {
    const n = ui.tree.get(node) orelse return null;
    const tag = n.widget_type orelse return null;
    for (&widgets) |*w| if (w.type_tag == tag) return w;
    return null;
}

/// Create a widget by registered name with default options.
pub fn create(ui: *Ui, name: []const u8, parent: Handle) anyerror!Handle {
    const info = find(name) orelse return error.UnknownWidget;
    return info.create(ui, parent);
}

fn replaceText(ctx: ?*anyopaque, t: *anyopaque, bytes: []const u8) error{OutOfMemory}!void {
    const ui: *Ui = @ptrCast(@alignCast(ctx.?));
    try ui.replaceText(@ptrCast(@alignCast(t)), bytes);
}

fn envFor(ui: *Ui) schema.Env {
    return .{ .ctx = ui, .replace_text = replaceText };
}

const Bound = struct { info: *const Info, widget: *anyopaque };

fn bound(ui: *Ui, node: Handle) Error!Bound {
    const n = ui.tree.get(node) orelse return error.StaleHandle;
    const info = infoOf(ui, node) orelse return error.NotAWidget;
    return .{ .info = info, .widget = n.widget.? };
}

/// Read a prop by schema path (for example `"colors.normal.bg"`).
pub fn getProp(ui: *Ui, node: Handle, path: []const u8) Error!schema.Value {
    const b = try bound(ui, node);
    return schema.get(b.info.props, b.info.propsPtr(b.widget), path);
}

/// Read a toolkit-written output by path.
pub fn getOut(ui: *Ui, node: Handle, path: []const u8) Error!schema.Value {
    const b = try bound(ui, node);
    return schema.get(b.info.out, b.info.outPtr(b.widget), path);
}

/// Write a prop by path and mark the node with what that prop requires.
pub fn setProp(ui: *Ui, node: Handle, path: []const u8, v: schema.Value) Error!void {
    const b = try bound(ui, node);
    const env = envFor(ui);
    try schema.set(b.info.props, b.info.propsPtr(b.widget), path, v, &env);
    const top = try schema.topField(b.info.props, path);
    ui.tree.markDirty(node, top.dirty);
}

/// Make an optional prop (such as `colors`) present as a copy of `template`,
/// or absent again.
pub fn setPropPresent(ui: *Ui, node: Handle, path: []const u8, template: ?*const anyopaque) Error!void {
    const b = try bound(ui, node);
    const base = b.info.propsPtr(b.widget);
    if (template) |t| try schema.setPresentFrom(b.info.props, base, path, t) else try schema.setAbsent(b.info.props, base, path);
    const top = try schema.topField(b.info.props, path);
    ui.tree.markDirty(node, top.dirty);
}

// ---- layout style ----------------------------------------------------------

const style_type = schema.typeOf(Style);

/// The schema of `Style`, for inspectors that edit layout.
pub fn styleSchema() *const schema.Type {
    return style_type;
}

pub fn getStyle(ui: *Ui, node: Handle, path: []const u8) Error!schema.Value {
    const n = ui.tree.get(node) orelse return error.StaleHandle;
    return schema.get(style_type, &n.style, path);
}

/// Write a style field by path; style changes always need layout.
pub fn setStyle(ui: *Ui, node: Handle, path: []const u8, v: schema.Value) Error!void {
    const n = ui.tree.get(node) orelse return error.StaleHandle;
    const env = envFor(ui);
    try schema.set(style_type, &n.style, path, v, &env);
    ui.tree.markDirty(node, DirtyFlags.layout_and_paint);
}

// ---- tests -----------------------------------------------------------------

const testing = std.testing;
const Color = @import("../core/geometry.zig").Color;

test "every registered widget has props and out schemas, and unique names" {
    for (widgets, 0..) |w, i| {
        try testing.expect(w.props.kind == .@"struct");
        try testing.expect(w.out.kind == .@"struct");
        for (widgets[i + 1 ..]) |o| try testing.expect(!std.mem.eql(u8, w.name, o.name));
    }
    try testing.expect(find("button") != null);
    try testing.expect(find("nope") == null);
}

test "every props field is either understood or explicitly a callback or override" {
    for (widgets) |w| {
        for (w.props.fields) |f| {
            const ok = f.type.kind != .unsupported;
            if (!ok) std.debug.print("{s}.{s}: unsupported ({s})\n", .{ w.name, f.name, f.type.name });
            try testing.expect(ok);
        }
    }
}

test "create by name builds each widget and node lookup finds it again" {
    var ui = try Ui.init(testing.allocator);
    defer ui.deinit();
    for (widgets) |w| {
        const h = try create(&ui, w.name, ui.tree.root);
        try testing.expect(infoOf(&ui, h).? == &w or std.mem.eql(u8, infoOf(&ui, h).?.name, w.name));
    }
    try testing.expectError(error.UnknownWidget, create(&ui, "slider", ui.tree.root));
    try testing.expect(infoOf(&ui, ui.tree.root) == null);
    try testing.expectError(error.NotAWidget, getProp(&ui, ui.tree.root, "text"));
}

test "setProp writes the widget, copies text, and marks the node dirty by category" {
    var ui = try Ui.init(testing.allocator);
    defer ui.deinit();
    const b = try ui.add(Button, ui.tree.root, .{ .text = "a" });
    ui.tree.get(b.node).?.dirty = .{};

    try setProp(&ui, b.node, "text", .{ .text = "hello" });
    try testing.expectEqualStrings("hello", b.props.text.bytes);
    try testing.expect(ui.tree.get(b.node).?.dirty.layout);

    ui.tree.get(b.node).?.dirty = .{};
    try setProp(&ui, b.node, "enabled", .{ .bool = false });
    try testing.expect(!b.props.enabled);
    const d = ui.tree.get(b.node).?.dirty;
    try testing.expect(d.paint and !d.layout);

    try testing.expectEqualStrings("hello", (try getProp(&ui, b.node, "text")).text);
    try testing.expectEqual(schema.Value{ .bool = false }, try getProp(&ui, b.node, "enabled"));
    try testing.expectError(error.UnknownField, setProp(&ui, b.node, "bogus", .none));
    try testing.expectError(error.TypeMismatch, setProp(&ui, b.node, "enabled", .{ .int = 1 }));
    try testing.expectError(error.ReadOnly, setProp(&ui, b.node, "on_click", .none));
}

test "enums set by index and read back by name" {
    var ui = try Ui.init(testing.allocator);
    defer ui.deinit();
    const b = try ui.add(Button, ui.tree.root, .{});
    const variant = find("button").?.props.field("variant").?.type;
    var idx: u32 = 0;
    for (variant.enum_names, 0..) |n, i| if (std.mem.eql(u8, n, "primary")) {
        idx = @intCast(i);
    };
    try setProp(&ui, b.node, "variant", .{ .choice = idx });
    try testing.expectEqual(@TypeOf(b.props.variant).primary, b.props.variant);
}

test "events are the on_* callbacks of Props, by short name" {
    const b = find("button").?;
    try testing.expectEqual(@as(usize, 1), b.events.len);
    try testing.expectEqualStrings("click", b.events[0]);
    const tf = find("text_field").?;
    try testing.expectEqual(@as(usize, 2), tf.events.len);
    try testing.expectEqual(@as(usize, 0), find("label").?.events.len);

    var ui = try Ui.init(testing.allocator);
    defer ui.deinit();
    const btn = try ui.add(Button, ui.tree.root, .{});
    const cb = event.Callback.fromFn(struct {
        fn noop(_: *event.Event) void {}
    }.noop);
    try testing.expect(b.setEvent(btn, "click", cb));
    try testing.expect(btn.props.on_click != null);
    try testing.expect(!b.setEvent(btn, "bogus", cb));
}

test "content widgets expose set_text; widgets with a text prop do not" {
    try testing.expect(find("button").?.set_text == null);
    try testing.expect(find("label").?.set_text == null);
    try testing.expect(find("text_field").?.set_text != null);
    try testing.expect(find("code_editor").?.set_text != null);
    var ui = try Ui.init(testing.allocator);
    defer ui.deinit();
    const f = try ui.add(TextField, ui.tree.root, .{});
    try find("text_field").?.set_text.?(f, "hello");
    try testing.expectEqualStrings("hello", f.text());
    const e = try ui.add(CodeEditor, ui.tree.root, .{});
    try find("code_editor").?.set_text.?(e, "fn main() {}");
    const got = try e.textAlloc(testing.allocator);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("fn main() {}", got);
}

test "outputs read through the registry; they have no setter" {
    var ui = try Ui.init(testing.allocator);
    defer ui.deinit();
    const b = try ui.add(Button, ui.tree.root, .{});
    b.out.hovered = true;
    try testing.expectEqual(schema.Value{ .bool = true }, try getOut(&ui, b.node, "hovered"));
}

test "optional override: present from template, edit by path, absent again" {
    var ui = try Ui.init(testing.allocator);
    defer ui.deinit();
    const b = try ui.add(Button, ui.tree.root, .{});
    try testing.expect(b.props.colors == null);
    const tmpl = b.colors();
    try setPropPresent(&ui, b.node, "colors", &tmpl);
    try testing.expect(b.props.colors != null);
    try setProp(&ui, b.node, "colors.text", .{ .color = Color.rgb(1, 2, 3) });
    try testing.expectEqual(Color.rgb(1, 2, 3), b.props.colors.?.text);
    try setPropPresent(&ui, b.node, "colors", null);
    try testing.expect(b.props.colors == null);
}

test "style is editable by path and always relayouts" {
    var ui = try Ui.init(testing.allocator);
    defer ui.deinit();
    const l = try ui.add(Label, ui.tree.root, .{});
    ui.tree.get(l.node).?.dirty = .{};
    try setStyle(&ui, l.node, "padding.left", .{ .length = .px(7) });
    try setStyle(&ui, l.node, "grow", .{ .float = 2 });
    try setStyle(&ui, l.node, "align_self", .{ .choice = 1 });
    const s = ui.tree.get(l.node).?.style;
    try testing.expectEqual(@as(f32, 7), s.padding.left.pixels);
    try testing.expectEqual(@as(f32, 2), s.grow);
    try testing.expect(s.align_self.? == .center);
    try testing.expect(ui.tree.get(l.node).?.dirty.layout);
    try testing.expectEqual(schema.Value{ .float = 2 }, try getStyle(&ui, l.node, "grow"));
    try setStyle(&ui, l.node, "align_self", .none);
    try testing.expect(ui.tree.get(l.node).?.style.align_self == null);
}

test "schema-driven edits do not leak under allocation failure" {
    var i: usize = 0;
    while (i < 40) : (i += 1) {
        var fa = std.testing.FailingAllocator.init(testing.allocator, .{ .fail_index = i });
        var ui = Ui.init(fa.allocator()) catch continue;
        defer ui.deinit();
        const b = ui.add(Button, ui.tree.root, .{ .text = "x" }) catch continue;
        setProp(&ui, b.node, "text", .{ .text = "a longer string" }) catch {};
    }
}
