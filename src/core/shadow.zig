//! Shadow-copy dirty checker.
//!
//! A widget's `props` struct is what the app writes. In builds with
//! `ui_checks` on (Debug and ReleaseSafe by default), the toolkit keeps a copy
//! of the props from the previous frame. At the start of each frame's layout
//! pass, `verify` compares the two. If a field changed but the widget's dirty
//! flags do not cover the category that field requires, it logs a warning
//! (or panics with `-Dui_strict=true`), then sets the missing flags so the UI
//! still renders correctly.
//!
//! With checks off (ReleaseFast), the shadow type is `void`, so there is no
//! memory cost and every call compiles to nothing.
//!
//! Callback fields (function pointers) are skipped: changing a handler needs
//! no layout or paint.
//!
//! A Props struct may declare which category each field needs:
//!
//!     pub const dirty_map = .{ .text = Category.layout, .color = Category.paint };
//!
//! Fields not listed default to layout + paint, the always-safe choice.

const std = @import("std");
const build_options = @import("build_options");
const DirtyFlags = @import("dirty.zig").DirtyFlags;

pub const enabled: bool = build_options.ui_checks;
pub const strict: bool = build_options.ui_strict;

pub const Category = enum { none, layout, paint, layout_and_paint };

fn categoryFlags(c: Category) DirtyFlags {
    return switch (c) {
        .none => DirtyFlags.none,
        .layout => DirtyFlags.layout_only,
        .paint => DirtyFlags.paint_only,
        .layout_and_paint => DirtyFlags.layout_and_paint,
    };
}

/// The shadow storage type: a copy of Props when checks are on, else void.
pub fn Shadow(comptime Props: type) type {
    return if (enabled) Props else void;
}

fn isCallback(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .pointer => |p| @typeInfo(p.child) == .@"fn",
        .optional => |o| isCallback(o.child),
        // `event.Callback` (and anything else marked the same way).
        .@"struct" => @hasDecl(T, "is_callback"),
        else => false,
    };
}

/// Dirty categories required when `field` of `Props` changes.
pub fn requiredFor(comptime Props: type, comptime field: []const u8) DirtyFlags {
    if (@hasDecl(Props, "dirty_map")) {
        const map = Props.dirty_map;
        if (@hasField(@TypeOf(map), field)) {
            const c: Category = @field(map, field);
            return categoryFlags(c);
        }
    }
    return DirtyFlags.layout_and_paint;
}

fn fieldEql(comptime T: type, a: T, b: T) bool {
    return switch (@typeInfo(T)) {
        .pointer => |p| if (p.size == .slice)
            (a.len == b.len and (a.ptr == b.ptr or std.mem.eql(p.child, a, b)))
        else
            a == b,
        .optional => |o| if (a == null or b == null)
            (a == null and b == null)
        else
            fieldEql(o.child, a.?, b.?),
        .@"struct" => structEql(T, a, b),
        .int, .float, .bool, .@"enum" => a == b,
        else => std.meta.eql(a, b),
    };
}

fn structEql(comptime T: type, a: T, b: T) bool {
    const info = @typeInfo(T).@"struct";
    inline for (info.field_names, info.field_types) |name, FieldType| {
        if (comptime isCallback(FieldType)) continue;
        if (!fieldEql(FieldType, @field(a, name), @field(b, name))) return false;
    }
    return true;
}

fn report(widget: []const u8, field: []const u8, missing: DirtyFlags) void {
    if (strict) {
        std.debug.panic(
            "ui_check: widget '{s}' changed field '{s}' without marking dirty (missing layout={}, paint={})",
            .{ widget, field, missing.layout, missing.paint },
        );
    } else {
        std.log.warn(
            "ui_check: widget '{s}' changed field '{s}' without marking dirty (missing layout={}, paint={}); corrected",
            .{ widget, field, missing.layout, missing.paint },
        );
    }
}

pub fn Checker(comptime Props: type) type {
    return struct {
        const Self = @This();

        shadow: Shadow(Props),

        pub fn init(props: *const Props) Self {
            if (enabled) {
                return .{ .shadow = props.* };
            } else {
                return .{ .shadow = {} };
            }
        }

        /// Record the current props as the baseline (e.g. after a deliberate reset).
        pub fn sync(self: *Self, props: *const Props) void {
            if (enabled) self.shadow = props.*;
        }

        /// Compare props to the shadow. For each changed field whose required
        /// dirty category is not already set, warn and set it. Then update the
        /// shadow. `widget_name` only appears in the warning text.
        pub fn verify(
            self: *Self,
            props: *const Props,
            dirty: *DirtyFlags,
            widget_name: []const u8,
        ) void {
            if (!enabled) return;

            var added = DirtyFlags.none;
            const info = @typeInfo(Props).@"struct";
            inline for (info.field_names, info.field_types) |name, FieldType| {
                if (comptime isCallback(FieldType)) continue;
                const now = @field(props.*, name);
                const before = @field(self.shadow, name);
                if (!fieldEql(FieldType, now, before)) {
                    const required = comptime requiredFor(Props, name);
                    const missing = dirty.missing(required);
                    if (!missing.isClean()) {
                        report(widget_name, name, missing);
                        added = added.merge(missing);
                    }
                }
            }
            dirty.* = dirty.merge(added);
            self.shadow = props.*;
        }
    };
}

const TestProps = struct {
    text: []const u8 = "",
    color: u32 = 0,
    enabled: bool = true,
    on_click: ?*const fn () void = null,

    pub const dirty_map = .{
        .text = Category.layout,
        .color = Category.paint,
    };
};

fn noop() void {}

test "no change leaves dirty flags alone" {
    if (!enabled or strict) return error.SkipZigTest;
    var props: TestProps = .{};
    var checker = Checker(TestProps).init(&props);
    var dirty = DirtyFlags.none;
    checker.verify(&props, &dirty, "test");
    try std.testing.expect(dirty.isClean());
}

test "forgotten paint flag is detected and corrected" {
    if (!enabled or strict) return error.SkipZigTest;
    var props: TestProps = .{};
    var checker = Checker(TestProps).init(&props);
    var dirty = DirtyFlags.none;

    props.color = 0xff0000;
    checker.verify(&props, &dirty, "test");
    try std.testing.expect(dirty.paint);
    try std.testing.expect(!dirty.layout);

    // The shadow was updated, so the same value is not reported twice.
    dirty = DirtyFlags.none;
    checker.verify(&props, &dirty, "test");
    try std.testing.expect(dirty.isClean());
}

test "text change requires layout" {
    if (!enabled or strict) return error.SkipZigTest;
    var props: TestProps = .{};
    var checker = Checker(TestProps).init(&props);
    var dirty = DirtyFlags.none;

    props.text = "hello";
    checker.verify(&props, &dirty, "test");
    try std.testing.expect(dirty.layout);
}

test "correctly marked changes are not touched" {
    if (!enabled or strict) return error.SkipZigTest;
    var props: TestProps = .{};
    var checker = Checker(TestProps).init(&props);
    var dirty = DirtyFlags.none;

    props.color = 1;
    dirty = dirty.merge(DirtyFlags.paint_only); // the app marked it
    checker.verify(&props, &dirty, "test");
    try std.testing.expect(dirty.paint);
    try std.testing.expect(!dirty.layout); // nothing extra was added
}

test "unlisted field defaults to layout and paint" {
    if (!enabled or strict) return error.SkipZigTest;
    var props: TestProps = .{};
    var checker = Checker(TestProps).init(&props);
    var dirty = DirtyFlags.none;

    props.enabled = false;
    checker.verify(&props, &dirty, "test");
    try std.testing.expect(dirty.layout and dirty.paint);
}

test "strings compare by content and callbacks are ignored" {
    if (!enabled or strict) return error.SkipZigTest;
    var buf_a = "same".*;
    var buf_b = "same".*;
    var props: TestProps = .{ .text = &buf_a };
    var checker = Checker(TestProps).init(&props);
    var dirty = DirtyFlags.none;

    props.text = &buf_b; // different pointer, same contents
    props.on_click = noop; // callbacks never need a dirty flag
    checker.verify(&props, &dirty, "test");
    try std.testing.expect(dirty.isClean());
}

test "required categories come from dirty_map" {
    const text_req = comptime requiredFor(TestProps, "text");
    try std.testing.expect(text_req.layout and !text_req.paint);
    const color_req = comptime requiredFor(TestProps, "color");
    try std.testing.expect(color_req.paint and !color_req.layout);
}

const CallbackProps = struct {
    enabled: bool = true,
    on_click: ?@import("event.zig").Callback = null,
};

fn cbA(_: ?*anyopaque, _: *@import("event.zig").Event) void {}
fn cbB(_: ?*anyopaque, _: *@import("event.zig").Event) void {}

test "changing a Callback prop needs no dirty flag" {
    if (!enabled or strict) return error.SkipZigTest;
    var props: CallbackProps = .{};
    var checker = Checker(CallbackProps).init(&props);
    var dirty = DirtyFlags.none;

    props.on_click = .{ .call = cbA };
    checker.verify(&props, &dirty, "test");
    try std.testing.expect(dirty.isClean());
    var token: u32 = 0;
    props.on_click = .{ .ctx = &token, .call = cbB }; // a different function and context
    checker.verify(&props, &dirty, "test");
    try std.testing.expect(dirty.isClean());

    props.enabled = false; // ordinary props are still checked
    checker.verify(&props, &dirty, "test");
    try std.testing.expect(!dirty.isClean());
}
