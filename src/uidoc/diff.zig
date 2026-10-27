//! Live values back to ZON: the inverse of `load`'s apply step.
//!
//! The builder's inspector edits live widget props and styles directly (so the
//! preview is always current). To keep the document in step, `diff` compares the
//! live value with its defaults and produces the sparse ZON record the document
//! stores: only what differs, in the same shapes `load` accepts. Applying that
//! record to a default value gives back the live value.

const std = @import("std");
const Allocator = std.mem.Allocator;
const schema = @import("../core/schema.zig");
const zon = @import("zon.zig");

/// A leaf as it is written in documents.
pub fn leafToZon(arena: Allocator, ty: *const schema.Type, v: schema.Value) Allocator.Error!zon.Value {
    switch (v) {
        .none => return .none,
        .bool => |b| return .{ .bool = b },
        .int => |i| return .{ .int = i },
        .float => |f| {
            if (ty.bits == 32) {
                // Print the shortest f32 text so 0.1 stays 0.1, not 0.10000000149011612.
                var buf: [48]u8 = undefined;
                const s = std.fmt.bufPrint(&buf, "{d}", .{@as(f32, @floatCast(f))}) catch return .{ .float = f };
                if (std.fmt.parseFloat(f64, s)) |shortest| return .{ .float = shortest } else |_| {}
            }
            return .{ .float = f };
        },
        .choice => |i| return .{ .tag = if (i < ty.enum_names.len) ty.enum_names[i] else "" },
        .text => |t| return .{ .string = try arena.dupe(u8, t) },
        .color => |c| {
            const s = if (c.a == 255)
                try std.fmt.allocPrint(arena, "#{x:0>2}{x:0>2}{x:0>2}", .{ c.r, c.g, c.b })
            else
                try std.fmt.allocPrint(arena, "#{x:0>2}{x:0>2}{x:0>2}{x:0>2}", .{ c.r, c.g, c.b, c.a });
            return .{ .string = s };
        },
        .length => |l| switch (l) {
            .pixels => |p| return if (p == @trunc(p) and @abs(p) < 1e9) .{ .int = @intFromFloat(p) } else .{ .float = p },
            .percent => |p| return .{ .string = try std.fmt.allocPrint(arena, "{d}%", .{p}) },
            .auto => return .{ .tag = "auto" },
            .fill => return .{ .tag = "fill" },
            .fit => return .{ .tag = "fit" },
        },
    }
}

fn at(p: *const anyopaque, off: usize) *const anyopaque {
    return @ptrFromInt(@intFromPtr(p) + off);
}

fn settable(f: *const schema.Field) bool {
    return f.type.kind != .callback and f.type.kind != .unsupported and !f.meta.readonly;
}

/// The ZON for the value at `ptr`, or null if it equals `base`. With a null
/// `base` the value is written in full.
pub fn diff(arena: Allocator, ty: *const schema.Type, ptr: *const anyopaque, base: ?*const anyopaque) Allocator.Error!?zon.Value {
    switch (ty.kind) {
        .@"struct" => {
            var out: std.ArrayListUnmanaged(zon.Field) = .empty;
            for (ty.fields) |*f| {
                if (!settable(f)) continue;
                const b: ?*const anyopaque = if (base) |x| at(x, f.offset) else null;
                if (try diff(arena, f.type, at(ptr, f.offset), b)) |v| {
                    try out.append(arena, .{ .name = f.name, .value = v });
                }
            }
            if (out.items.len == 0 and base != null) return null;
            return .{ .record = out.items };
        },
        .array => {
            var differs = base == null;
            var i: usize = 0;
            while (!differs and i < ty.len) : (i += 1) {
                const e = at(ptr, i * ty.elem_size);
                const b = at(base.?, i * ty.elem_size);
                differs = (try diff(arena, ty.child.?, e, b)) != null;
            }
            if (!differs) return null;
            const items = try arena.alloc(zon.Value, ty.len);
            for (items, 0..) |*slot, k| slot.* = (try diff(arena, ty.child.?, at(ptr, k * ty.elem_size), null)).?;
            return .{ .list = items };
        },
        .optional => {
            const mine = ty.payload.?(@constCast(ptr));
            const theirs: ?*anyopaque = if (base) |b| ty.payload.?(@constCast(b)) else null;
            if (mine == null) return if (base != null and theirs == null) null else .none;
            if (theirs != null) return diff(arena, ty.child.?, mine.?, theirs.?);
            // Present, where the default is absent (or a full write was asked
            // for): write enough to rebuild it from the payload default.
            if (base == null) return diff(arena, ty.child.?, mine.?, null);
            if (try diff(arena, ty.child.?, mine.?, ty.payload_default.?)) |v| return v;
            return if (ty.child.?.kind == .@"struct") .{ .record = &.{} } else try diff(arena, ty.child.?, mine.?, null);
        },
        .callback, .unsupported => return null,
        else => {
            const get = ty.get orelse return null;
            const mine = get(ptr);
            if (base) |b| {
                if (schema.valueEql(mine, get(b))) return null;
            }
            return try leafToZon(arena, ty, mine);
        },
    }
}

// ---- tests -----------------------------------------------------------------

const testing = std.testing;
const registry = @import("../widgets/registry.zig");
const Button = @import("../widgets/button.zig").Button;
const Style = @import("../core/style.zig").Style;
const Length = @import("../core/length.zig").Length;
const Color = @import("../core/geometry.zig").Color;
const Ui = @import("../core/ui.zig").Ui;

test "an unchanged value diffs to nothing" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const s: Style = .{};
    try testing.expect((try diff(arena.allocator(), schema.typeOf(Style), &s, &Style{})) == null);
}

test "style diffs list only what changed, in document shapes" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var s: Style = .{};
    s.width = Length.px(120);
    s.height = Length.pct(50);
    s.grow = 1;
    s.direction = .column;
    s.padding.left = Length.px(7);
    s.align_self = .center;
    const v = (try diff(a, schema.typeOf(Style), &s, &Style{})).?;
    try testing.expectEqual(@as(usize, 6), v.record.len);
    try testing.expectEqual(@as(i64, 120), v.field("width").?.int);
    try testing.expectEqualStrings("50%", v.field("height").?.string);
    try testing.expectEqual(@as(f64, 1), v.field("grow").?.float);
    try testing.expectEqualStrings("column", v.field("direction").?.tag);
    try testing.expectEqual(@as(i64, 7), v.field("padding").?.field("left").?.int);
    try testing.expect(v.field("padding").?.field("top") == null);
    try testing.expectEqualStrings("center", v.field("align_self").?.tag);
}

test "optionals: cleared back to absent, and present with defaults still appear" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var s: Style = .{};
    s.align_self = .start; // the first enum value, which is also what defaultOf gives
    const v = (try diff(a, schema.typeOf(Style), &s, &Style{})).?;
    try testing.expectEqualStrings("start", v.field("align_self").?.tag);

    var base: Style = .{};
    base.align_self = .end;
    var live: Style = .{};
    const cleared = (try diff(a, schema.typeOf(Style), &live, &base)).?;
    try testing.expect(cleared.field("align_self").? == .none);
}

test "f32 values print as their short decimal" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var s: Style = .{};
    s.grow = 0.1;
    const v = (try diff(arena.allocator(), schema.typeOf(Style), &s, &Style{})).?;
    try testing.expectEqual(@as(f64, 0.1), v.field("grow").?.float);
}

test "colors write as hex, with alpha only when needed" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const ty = schema.typeOf(Color);
    try testing.expectEqualStrings("#ff8000", (try leafToZon(a, ty, .{ .color = Color.rgb(255, 128, 0) })).string);
    try testing.expectEqualStrings("#ff800040", (try leafToZon(a, ty, .{ .color = Color.rgba(255, 128, 0, 0x40) })).string);
}

test "widget props: edits made through the registry diff to the document form and load back identically" {
    const doc_mod = @import("doc.zig");
    const load = @import("load.zig");
    var ui = try Ui.init(testing.allocator);
    defer ui.deinit();
    const b = try ui.add(Button, ui.tree.root, .{});
    try registry.setProp(&ui, b.node, "text", .{ .text = "Save \"all\"" });
    try registry.setProp(&ui, b.node, "variant", .{ .choice = 1 });
    try registry.setProp(&ui, b.node, "enabled", .{ .bool = false });
    const info = registry.find("button").?;
    try registry.setPropPresent(&ui, b.node, "colors", null);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const rec = (try diff(arena.allocator(), info.props, info.propsPtr(b), info.props_default)).?;
    try testing.expectEqualStrings("Save \"all\"", rec.field("text").?.string);
    try testing.expectEqualStrings("primary", rec.field("variant").?.tag);
    try testing.expect(!rec.field("enabled").?.bool);
    try testing.expectEqual(@as(usize, 3), rec.record.len);

    var doc = try doc_mod.Doc.init(testing.allocator);
    defer doc.deinit();
    const n = try doc.newNode("button");
    n.props = try doc.copyValue(rec);
    try doc.setId(n, "b");
    try doc.insert(doc.root, 0, n);
    var inst = try load.instantiate(&ui, ui.tree.root, &doc, .{});
    defer inst.destroy();
    try testing.expectEqual(@as(usize, 0), inst.problems.items.len);
    const loaded = inst.widget(Button, "b").?;
    try testing.expectEqualStrings("Save \"all\"", loaded.props.text.bytes);
    try testing.expect(loaded.props.variant == b.props.variant and !loaded.props.enabled);
    const again = (try diff(arena.allocator(), info.props, info.propsPtr(loaded), info.props_default)).?;
    try testing.expect(rec.eql(again));
}

test "arrays write whole when any element differs; optional structs diff against their payload default" {
    const T = struct {
        sizes: [3]u8 = .{ 1, 2, 3 },
        box: ?struct { a: u8 = 5, b: bool = false } = null,
    };
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const ty = schema.typeOf(T);
    var base: T = .{};
    var live: T = .{};
    try testing.expect((try diff(a, ty, &live, &base)) == null);
    live.sizes[1] = 9;
    live.box = .{ .a = 5, .b = true };
    const v = (try diff(a, ty, &live, &base)).?;
    try testing.expectEqual(@as(usize, 3), v.field("sizes").?.list.len);
    try testing.expectEqual(@as(i64, 9), v.field("sizes").?.list[1].int);
    try testing.expect(v.field("box").?.field("b").?.bool);
    try testing.expect(v.field("box").?.field("a") == null);
    live.box = .{};
    const present = (try diff(a, ty, &live, &base)).?;
    try testing.expectEqual(@as(usize, 0), present.field("box").?.fields().?.len); // present, all defaults
}
