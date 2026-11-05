//! Finding the `comptime` block to debug, and the small root file that makes the compiler
//! evaluate it (see `dap/zigct.zig`). No UI here.
//!
//!     var b = try findBlock(gpa, source, caret_offset) orelse return;   // innermost comptime
//!     defer b.deinit();
//!     b.start_line; b.end_line;     // 1-based, the whole `comptime { ... }` (or expression)
//!     b.fn_path;                    // "run" or "Counter.step": what must be referenced; "" at container level
//!     b.problem;                    // why it cannot be run from another file ("" when it can)
//!     b.in_test;                    // inside a `test` declaration (run in test mode)
//!     const root = try rootSource(gpa, "src/lib.zig", b.fn_path);   // text of the synthetic root
//!
//! **What the compiler needs.** A container-level `comptime {}` runs when its file is analyzed,
//! so importing the file is enough. A block inside a function runs only when the function's
//! body is analyzed, so the root also takes the function's address (`_ = &m.f;`). That works for
//! a `pub` function with no `comptime`/`anytype` parameters (their arguments are unknown), and
//! for `pub` nested containers; otherwise `problem` says what to change.

const std = @import("std");
const Ast = std.zig.Ast;

pub const Block = struct {
    arena: std.heap.ArenaAllocator,
    /// 1-based lines of the first and last token.
    start_line: u32,
    end_line: u32,
    /// The path to the enclosing function from the file's root ("" for a container-level block).
    fn_path: []const u8,
    problem: []const u8,
    /// The block is inside a `test` declaration: the compiler must analyze like `zig test`.
    in_test: bool = false,

    pub fn deinit(self: *Block) void {
        self.arena.deinit();
    }
};

fn lineOf(src: []const u8, offset: usize) u32 {
    var n: u32 = 1;
    for (src[0..@min(offset, src.len)]) |c| {
        if (c == '\n') n += 1;
    }
    return n;
}

fn span(ast: *const Ast, n: Ast.Node.Index) [2]usize {
    return .{ ast.tokenStart(ast.firstToken(n)), ast.tokenStart(ast.lastToken(n)) + ast.tokenSlice(ast.lastToken(n)).len };
}

/// The innermost `comptime` block or expression that contains `offset` (null when none does).
pub fn findBlock(gpa: std.mem.Allocator, source: [:0]const u8, offset: usize) !?Block {
    var ast = try Ast.parse(gpa, source, .{});
    defer ast.deinit(gpa);
    if (ast.errors.len > 0) return null;

    var best: ?Ast.Node.Index = null;
    var best_len: usize = std.math.maxInt(usize);
    var i: u32 = 0;
    while (i < ast.nodes.len) : (i += 1) {
        const n: Ast.Node.Index = @enumFromInt(i);
        if (ast.nodeTag(n) != .@"comptime") continue;
        const s = span(&ast, n);
        if (offset < s[0] or offset > s[1]) continue;
        if (s[1] - s[0] < best_len) {
            best = n;
            best_len = s[1] - s[0];
        }
    }
    const node = best orelse return null;
    const bs = span(&ast, node);

    var out: Block = .{ .arena = .init(gpa), .start_line = lineOf(source, bs[0]), .end_line = lineOf(source, bs[1] -| 1), .fn_path = "", .problem = "" };
    errdefer out.arena.deinit();
    const a = out.arena.allocator();

    // Inside a `test`? (Its body is analyzed when the compiler runs in test mode.)
    i = 0;
    while (i < ast.nodes.len) : (i += 1) {
        const n: Ast.Node.Index = @enumFromInt(i);
        if (ast.nodeTag(n) != .test_decl) continue;
        const s = span(&ast, n);
        if (s[0] <= bs[0] and s[1] >= bs[1]) out.in_test = true;
    }

    // Enclosing containers and the function, outermost first.
    const Item = struct { start: usize, len: usize, name: []const u8, is_fn: bool, ok: bool, why: []const u8 };
    var items: std.ArrayListUnmanaged(Item) = .empty;
    defer items.deinit(gpa);
    i = 0;
    while (i < ast.nodes.len) : (i += 1) {
        const n: Ast.Node.Index = @enumFromInt(i);
        const tag = ast.nodeTag(n);
        const s = span(&ast, n);
        if (s[0] > bs[0] or s[1] < bs[1] or n == node) continue;
        switch (tag) {
            .fn_decl => {
                var fb: [1]Ast.Node.Index = undefined;
                const fp = ast.fullFnProto(&fb, ast.nodeData(n).node_and_node[0]) orelse continue;
                const name_tok = fp.name_token orelse continue;
                var ok = fp.visib_token != null;
                var why: []const u8 = "";
                if (!ok) why = "the function is not `pub`: mark it `pub`, or move the block out of the function";
                var it = fp.iterate(&ast);
                while (it.next()) |p| {
                    if (p.comptime_noalias != null and ast.tokenTag(p.comptime_noalias.?) == .keyword_comptime) {
                        ok = false;
                        why = "the function has a `comptime` parameter, so its arguments are unknown";
                    }
                    if (p.type_expr) |te| if (ast.nodeTag(te) == .identifier and std.mem.eql(u8, ast.tokenSlice(ast.nodeMainToken(te)), "anytype")) {
                        ok = false;
                        why = "the function takes `anytype`, so its arguments are unknown";
                    };
                    if (p.anytype_ellipsis3 != null) {
                        ok = false;
                        why = "the function takes `anytype`, so its arguments are unknown";
                    }
                }
                try items.append(gpa, .{ .start = s[0], .len = s[1] - s[0], .name = ast.tokenSlice(name_tok), .is_fn = true, .ok = ok, .why = why });
            },
            .simple_var_decl, .global_var_decl, .aligned_var_decl, .local_var_decl => {
                const vd = ast.fullVarDecl(n) orelse continue;
                const init_node = vd.ast.init_node.unwrap() orelse continue;
                switch (ast.nodeTag(init_node)) {
                    .container_decl, .container_decl_trailing, .container_decl_two, .container_decl_two_trailing, .container_decl_arg, .container_decl_arg_trailing => {},
                    else => continue,
                }
                const ok = vd.visib_token != null;
                try items.append(gpa, .{ .start = s[0], .len = s[1] - s[0], .name = ast.tokenSlice(vd.ast.mut_token + 1), .is_fn = false, .ok = ok, .why = "an enclosing type is not `pub`" });
            },
            else => {},
        }
    }
    std.mem.sort(Item, items.items, {}, struct {
        fn less(_: void, x: Item, y: Item) bool {
            return x.len > y.len;
        }
    }.less);
    var has_fn = false;
    var path: std.ArrayListUnmanaged(u8) = .empty;
    for (items.items) |it| {
        if (path.items.len > 0) try path.append(a, '.');
        try path.appendSlice(a, it.name);
        if (it.is_fn) has_fn = true;
        if (!it.ok and out.problem.len == 0) out.problem = try a.dupe(u8, it.why);
    }
    if (has_fn) {
        out.fn_path = path.items;
    } else if (items.items.len > 0) {
        // Inside a type's declaration (not a function): a `comptime` field/decl block of that type
        // runs when the type is analyzed; referencing the type does that.
        out.fn_path = path.items;
    }
    return out;
}

/// The text of the synthetic root: it imports `rel_path` (relative to the project root, '/')
/// and references what the block needs.
pub fn rootSource(gpa: std.mem.Allocator, rel_path: []const u8, fn_path: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.print(gpa, "// Made by the zigui IDE for \"Debug comptime\"; deleted when the session ends.\nconst m = @import(\"{s}\");\ncomptime {{\n    _ = m;\n", .{rel_path});
    if (fn_path.len > 0) try out.print(gpa, "    _ = &m.{s};\n", .{fn_path});
    try out.appendSlice(gpa, "}\n");
    return out.toOwnedSlice(gpa);
}

const testing = std.testing;

test "the innermost comptime block is found, with the function it needs" {
    const src =
        \\const util = @import("util.zig");
        \\
        \\pub fn run(n: u32) u32 {
        \\    comptime {
        \\        var k: u32 = 5;
        \\        k += 1;
        \\    }
        \\    return n;
        \\}
        \\
        \\comptime {
        \\    var t: u32 = 0;
        \\    _ = &t;
        \\}
        \\
    ;
    const caret_in_fn = std.mem.indexOf(u8, src, "k += 1").?;
    var b = (try findBlock(testing.allocator, src, caret_in_fn)).?;
    defer b.deinit();
    try testing.expectEqual(@as(u32, 4), b.start_line);
    try testing.expectEqual(@as(u32, 7), b.end_line);
    try testing.expectEqualStrings("run", b.fn_path);
    try testing.expectEqualStrings("", b.problem);

    const caret_top = std.mem.indexOf(u8, src, "var t").?;
    var c = (try findBlock(testing.allocator, src, caret_top)).?;
    defer c.deinit();
    try testing.expectEqual(@as(u32, 11), c.start_line);
    try testing.expectEqual(@as(u32, 14), c.end_line);
    try testing.expectEqualStrings("", c.fn_path);

    const caret_none = std.mem.indexOf(u8, src, "return n").?;
    try testing.expect((try findBlock(testing.allocator, src, caret_none)) == null);

    const root = try rootSource(testing.allocator, "src/lib.zig", b.fn_path);
    defer testing.allocator.free(root);
    try testing.expect(std.mem.indexOf(u8, root, "@import(\"src/lib.zig\")") != null);
    try testing.expect(std.mem.indexOf(u8, root, "_ = &m.run;") != null);
}

test "a block inside a test declaration is recognised" {
    const src =
        \\test "x" {
        \\    comptime {
        \\        _ = 1;
        \\    }
        \\}
        \\comptime {
        \\    _ = 2;
        \\}
        \\
    ;
    var t = (try findBlock(testing.allocator, src, std.mem.indexOf(u8, src, "_ = 1").?)).?;
    defer t.deinit();
    try testing.expect(t.in_test);
    try testing.expectEqualStrings("", t.fn_path);
    var c = (try findBlock(testing.allocator, src, std.mem.indexOf(u8, src, "_ = 2").?)).?;
    defer c.deinit();
    try testing.expect(!c.in_test);
}

test "methods of types are reached by their path; private and generic functions are explained" {
    const src =
        \\pub const Counter = struct {
        \\    pub fn step(self: *Counter) void {
        \\        comptime {
        \\            _ = 1;
        \\        }
        \\        _ = self;
        \\    }
        \\};
        \\fn hidden() void {
        \\    comptime { _ = 2; }
        \\}
        \\pub fn gen(comptime T: type, x: T) T {
        \\    comptime { _ = 3; }
        \\    return x;
        \\}
        \\
    ;
    var m = (try findBlock(testing.allocator, src, std.mem.indexOf(u8, src, "_ = 1").?)).?;
    defer m.deinit();
    try testing.expectEqualStrings("Counter.step", m.fn_path);
    try testing.expectEqualStrings("", m.problem);

    var h = (try findBlock(testing.allocator, src, std.mem.indexOf(u8, src, "_ = 2").?)).?;
    defer h.deinit();
    try testing.expect(std.mem.indexOf(u8, h.problem, "pub") != null);

    var g = (try findBlock(testing.allocator, src, std.mem.indexOf(u8, src, "_ = 3").?)).?;
    defer g.deinit();
    try testing.expect(std.mem.indexOf(u8, g.problem, "comptime") != null);
}
