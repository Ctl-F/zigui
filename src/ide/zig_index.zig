//! Offline knowledge of Zig code, from `std.zig.Ast` alone (no compiler, no
//! language server): what names a file declares, and what `std.mem.`, `std.fs.`
//! or `some_module.` can be followed by.
//!
//!     var index = try Index.init(gpa, io, std_dir);        // e.g. "<zig lib>/std"
//!     defer index.deinit();
//!     var buf = try index.parseBuffer("const std = @import(\"std\");\n", "/project/src");
//!     defer index.freeBuffer(buf);
//!     var out: std.ArrayListUnmanaged(Member) = .empty;
//!     _ = index.membersOf(buf, &.{ "std", "mem" }, &out);   // pub decls of std/mem.zig
//!
//! Names resolve the way a reader would: `const std = @import("std");` makes
//! `std` the library root, `const x = @import("x.zig");` another file,
//! `const T = struct {...}` a container, and `const a = b.c;` follows the path.
//! Values (`list.`) are not resolved: that needs type inference, which is the
//! language server's job. Files are parsed when first needed and kept.

const std = @import("std");
const Ast = std.zig.Ast;
const Node = Ast.Node;

pub const Kind = enum {
    function,
    constant,
    variable,
    /// A file or `@import`ed namespace.
    namespace,
    /// A struct, enum, union or opaque declaration.
    type,
    field,
    enum_value,

    pub fn tag(self: Kind) []const u8 {
        return switch (self) {
            .function => "fn",
            .constant => "const",
            .variable => "var",
            .namespace => "mod",
            .type => "type",
            .field => "field",
            .enum_value => "enum",
        };
    }
};

/// A declared name. Strings point into the file's source (valid while the
/// `Index`, or the parsed buffer, lives).
pub const Member = struct {
    name: []const u8,
    kind: Kind,
    /// A signature or type, shortened to one line.
    detail: []const u8 = "",
    /// The `///` doc comment lines above the declaration, raw (with the slashes).
    doc: []const u8 = "",
};

pub const File = struct {
    path: []u8,
    source: [:0]u8,
    ast: Ast,
    /// Every top-level name is visible (the file being edited), not just `pub` ones.
    all_visible: bool,

    fn dir(self: *const File) []const u8 {
        return std.fs.path.dirname(self.path) orelse ".";
    }
};

const Ref = struct { file: *File, node: ?Node.Index = null };

const max_depth = 8;
const max_source = 8 * 1024 * 1024;

pub const Index = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    std_dir: ?[]u8,
    files: std.StringHashMapUnmanaged(*File) = .empty,

    pub fn init(gpa: std.mem.Allocator, io: std.Io, std_dir: ?[]const u8) !Index {
        return .{ .gpa = gpa, .io = io, .std_dir = if (std_dir) |d| try gpa.dupe(u8, d) else null };
    }

    pub fn deinit(self: *Index) void {
        var it = self.files.valueIterator();
        while (it.next()) |f| self.freeFile(f.*);
        self.files.deinit(self.gpa);
        if (self.std_dir) |d| self.gpa.free(d);
    }

    fn freeFile(self: *Index, f: *File) void {
        f.ast.deinit(self.gpa);
        self.gpa.free(f.source);
        self.gpa.free(f.path);
        self.gpa.destroy(f);
    }

    /// Parse `text` as the file being edited, living in directory `dir` (for
    /// relative imports). Not cached; give it back with `freeBuffer`.
    pub fn parseBuffer(self: *Index, text: []const u8, dir: []const u8) !*File {
        const f = try self.gpa.create(File);
        errdefer self.gpa.destroy(f);
        const path = try std.fs.path.join(self.gpa, &.{ dir, "(buffer).zig" });
        errdefer self.gpa.free(path);
        const src = try self.gpa.dupeSentinel(u8, text, 0);
        errdefer self.gpa.free(src);
        f.* = .{ .path = path, .source = src, .ast = try Ast.parse(self.gpa, src, .{}), .all_visible = true };
        return f;
    }

    pub fn freeBuffer(self: *Index, f: *File) void {
        self.freeFile(f);
    }

    /// Load (or fetch the cached) file at `abs_path`.
    fn load(self: *Index, abs_path: []const u8) ?*File {
        if (self.files.get(abs_path)) |f| return f;
        const src = std.Io.Dir.cwd().readFileAllocOptions(self.io, abs_path, self.gpa, .limited(max_source), .of(u8), 0) catch return null;
        const f = self.gpa.create(File) catch {
            self.gpa.free(src);
            return null;
        };
        const path = self.gpa.dupe(u8, abs_path) catch {
            self.gpa.free(src);
            self.gpa.destroy(f);
            return null;
        };
        f.* = .{ .path = path, .source = src, .ast = Ast.parse(self.gpa, src, .{}) catch {
            self.gpa.free(src);
            self.gpa.free(path);
            self.gpa.destroy(f);
            return null;
        }, .all_visible = false };
        self.files.put(self.gpa, path, f) catch {
            self.freeFile(f);
            return null;
        };
        return f;
    }

    fn importTarget(self: *Index, from: *File, name: []const u8) ?*File {
        if (std.mem.eql(u8, name, "std")) {
            const d = self.std_dir orelse return null;
            var buf: [std.fs.max_path_bytes]u8 = undefined;
            const p = std.fmt.bufPrint(&buf, "{s}/std.zig", .{d}) catch return null;
            return self.load(p);
        }
        if (!std.mem.endsWith(u8, name, ".zig")) return null;
        const joined = std.fs.path.resolve(self.gpa, &.{ from.dir(), name }) catch return null;
        defer self.gpa.free(joined);
        return self.load(joined);
    }

    // ---- walking declarations ----

    fn memberNodes(ref: Ref, buf: *[2]Node.Index) []const Node.Index {
        const ast = &ref.file.ast;
        if (ref.node) |n| {
            const cd = ast.fullContainerDecl(buf, n) orelse return &.{};
            return cd.ast.members;
        }
        return ast.rootDecls();
    }

    fn declName(ast: *const Ast, node: Node.Index) ?[]const u8 {
        if (ast.fullVarDecl(node)) |vd| return ast.tokenSlice(vd.ast.mut_token + 1);
        var fb: [1]Node.Index = undefined;
        switch (ast.nodeTag(node)) {
            .fn_decl => {
                const proto = ast.nodeData(node).node_and_node[0];
                if (ast.fullFnProto(&fb, proto)) |fp| if (fp.name_token) |t| return ast.tokenSlice(t);
            },
            .fn_proto, .fn_proto_multi, .fn_proto_one, .fn_proto_simple => {
                if (ast.fullFnProto(&fb, node)) |fp| if (fp.name_token) |t| return ast.tokenSlice(t);
            },
            .container_field_init, .container_field_align, .container_field => {
                if (ast.fullContainerField(node)) |cf| return ast.tokenSlice(cf.ast.main_token);
            },
            else => {},
        }
        return null;
    }

    fn isPub(ast: *const Ast, node: Node.Index) bool {
        if (ast.fullVarDecl(node)) |vd| return vd.visib_token != null;
        var fb: [1]Node.Index = undefined;
        const proto = if (ast.nodeTag(node) == .fn_decl) ast.nodeData(node).node_and_node[0] else node;
        if (ast.fullFnProto(&fb, proto)) |fp| return fp.visib_token != null;
        return ast.fullContainerField(node) != null;
    }

    fn findDecl(ref: Ref, name: []const u8) ?Node.Index {
        var cb: [2]Node.Index = undefined;
        for (memberNodes(ref, &cb)) |m| {
            const n = declName(&ref.file.ast, m) orelse continue;
            if (!std.mem.eql(u8, n, name)) continue;
            if (!ref.file.all_visible and !isPub(&ref.file.ast, m)) continue;
            return m;
        }
        return null;
    }

    fn isContainer(ast: *const Ast, node: Node.Index) bool {
        var b: [2]Node.Index = undefined;
        return ast.fullContainerDecl(&b, node) != null;
    }

    /// What expression `node` of `file` stands for, if it is a namespace or type.
    fn eval(self: *Index, file: *File, node: Node.Index, depth: u32) ?Ref {
        if (depth > max_depth) return null;
        const ast = &file.ast;
        switch (ast.nodeTag(node)) {
            .identifier => {
                const name = ast.tokenSlice(ast.nodeMainToken(node));
                const here: Ref = .{ .file = file };
                if (findDeclAny(here, name)) |d| return self.declRef(file, d, depth + 1);
                if (std.mem.eql(u8, name, "std")) {
                    const f = self.importTarget(file, "std") orelse return null;
                    return .{ .file = f };
                }
                return null;
            },
            .field_access => {
                const lhs, const name_tok = ast.nodeData(node).node_and_token;
                const base = self.eval(file, lhs, depth + 1) orelse return null;
                const d = findDecl(base, ast.tokenSlice(name_tok)) orelse return null;
                return self.declRef(base.file, d, depth + 1);
            },
            .builtin_call_two, .builtin_call_two_comma => {
                if (!std.mem.eql(u8, ast.tokenSlice(ast.nodeMainToken(node)), "@import")) return null;
                const arg = ast.nodeData(node).opt_node_and_opt_node[0].unwrap() orelse return null;
                if (ast.nodeTag(arg) != .string_literal) return null;
                const lit = ast.tokenSlice(ast.nodeMainToken(arg));
                if (lit.len < 2) return null;
                const target = self.importTarget(file, lit[1 .. lit.len - 1]) orelse return null;
                return .{ .file = target };
            },
            else => if (isContainer(ast, node)) return .{ .file = file, .node = node },
        }
        return null;
    }

    /// Like `findDecl` but ignoring `pub` (a name in scope inside its own file).
    fn findDeclAny(ref: Ref, name: []const u8) ?Node.Index {
        var cb: [2]Node.Index = undefined;
        for (memberNodes(ref, &cb)) |m| {
            const n = declName(&ref.file.ast, m) orelse continue;
            if (std.mem.eql(u8, n, name)) return m;
        }
        return null;
    }

    /// Where declaration `node` leads: a file, a container, or whatever an alias names.
    fn declRef(self: *Index, file: *File, node: Node.Index, depth: u32) ?Ref {
        const ast = &file.ast;
        const vd = ast.fullVarDecl(node) orelse return null;
        const rhs = vd.ast.init_node.unwrap() orelse return null;
        return self.eval(file, rhs, depth);
    }

    // ---- queries ----

    /// Append the names `path` (`{"std", "mem"}`) is followed by in `scope`.
    /// False if the path does not resolve to a namespace or type.
    pub fn membersOf(self: *Index, scope: *File, path: []const []const u8, out: *std.ArrayListUnmanaged(Member)) bool {
        if (path.len == 0) return false;
        var cur: Ref = blk: {
            const here: Ref = .{ .file = scope };
            if (findDeclAny(here, path[0])) |d| break :blk self.declRef(scope, d, 0) orelse return false;
            if (std.mem.eql(u8, path[0], "std")) {
                break :blk .{ .file = self.importTarget(scope, "std") orelse return false };
            }
            return false;
        };
        for (path[1..]) |seg| {
            const d = findDecl(cur, seg) orelse return false;
            cur = self.declRef(cur.file, d, 0) orelse return false;
        }
        self.collect(cur, out);
        return true;
    }

    /// The declaration `path` names (`{"std","mem","eql"}`), or null. A single
    /// name is looked up among `scope`'s own top-level names.
    pub fn lookup(self: *Index, scope: *File, path: []const []const u8) ?Member {
        if (path.len == 0) return null;
        var parent: Ref = .{ .file = scope };
        if (path.len > 1) {
            parent = blk: {
                const here: Ref = .{ .file = scope };
                if (findDeclAny(here, path[0])) |d| break :blk self.declRef(scope, d, 0) orelse return null;
                if (std.mem.eql(u8, path[0], "std")) break :blk .{ .file = self.importTarget(scope, "std") orelse return null };
                return null;
            };
            for (path[1 .. path.len - 1]) |seg| {
                const d = findDecl(parent, seg) orelse return null;
                parent = self.declRef(parent.file, d, 0) orelse return null;
            }
        }
        const name = path[path.len - 1];
        const d = if (path.len == 1) findDeclAny(parent, name) else findDecl(parent, name);
        const node = d orelse return null;
        return self.describe(parent.file, node, name, false);
    }

    /// Append every top-level name of `scope` (what an unqualified name can be).
    pub fn topLevel(self: *Index, scope: *File, out: *std.ArrayListUnmanaged(Member)) void {
        self.collect(.{ .file = scope }, out);
    }

    fn collect(self: *Index, ref: Ref, out: *std.ArrayListUnmanaged(Member)) void {
        const ast = &ref.file.ast;
        var cb: [2]Node.Index = undefined;
        const is_enum = if (ref.node) |n| blk: {
            var b2: [2]Node.Index = undefined;
            const cd = ast.fullContainerDecl(&b2, n) orelse break :blk false;
            break :blk ast.tokenTag(cd.ast.main_token) == .keyword_enum;
        } else false;
        for (memberNodes(ref, &cb)) |m| {
            const name = declName(ast, m) orelse continue;
            if (!ref.file.all_visible and !isPub(ast, m)) continue;
            out.append(self.gpa, self.describe(ref.file, m, name, is_enum)) catch return;
        }
    }

    fn describe(self: *Index, file: *File, node: Node.Index, name: []const u8, in_enum: bool) Member {
        var m = self.describeBare(file, node, name, in_enum);
        m.doc = docComment(&file.ast, file.source, node);
        return m;
    }

    fn describeBare(self: *Index, file: *File, node: Node.Index, name: []const u8, in_enum: bool) Member {
        _ = self;
        const ast = &file.ast;
        if (ast.fullVarDecl(node)) |vd| {
            const rhs = vd.ast.init_node.unwrap();
            var kind: Kind = if (ast.tokenTag(vd.ast.mut_token) == .keyword_const) .constant else .variable;
            var detail: []const u8 = "";
            if (rhs) |i| {
                if (isContainer(ast, i)) {
                    kind = .type;
                } else if (ast.nodeTag(i) == .builtin_call_two or ast.nodeTag(i) == .builtin_call_two_comma) {
                    if (std.mem.eql(u8, ast.tokenSlice(ast.nodeMainToken(i)), "@import")) kind = .namespace;
                }
            }
            if (vd.ast.type_node.unwrap()) |t| detail = oneLine(ast.getNodeSource(t));
            return .{ .name = name, .kind = kind, .detail = detail };
        }
        var fb: [1]Node.Index = undefined;
        const proto = if (ast.nodeTag(node) == .fn_decl) ast.nodeData(node).node_and_node[0] else node;
        if (ast.fullFnProto(&fb, proto)) |fp| {
            const start = ast.tokenStart(fp.lparen);
            const end_tok = if (fp.ast.return_type.unwrap()) |r| ast.lastToken(r) else fp.lparen;
            const end = ast.tokenStart(end_tok) + ast.tokenSlice(end_tok).len;
            return .{ .name = name, .kind = .function, .detail = oneLine(file.source[start..end]) };
        }
        var detail: []const u8 = "";
        if (ast.fullContainerField(node)) |cf| {
            if (cf.ast.type_expr.unwrap()) |t| detail = oneLine(ast.getNodeSource(t));
        }
        return .{ .name = name, .kind = if (in_enum) .enum_value else .field, .detail = detail };
    }
};

/// The `///` lines directly above `node`, raw.
fn docComment(ast: *const Ast, source: []const u8, node: Node.Index) []const u8 {
    const first = ast.firstToken(node);
    var t = first;
    while (t > 0 and ast.tokenTag(t - 1) == .doc_comment) t -= 1;
    if (t == first) return "";
    return std.mem.trimEnd(u8, source[ast.tokenStart(t)..ast.tokenStart(first)], " \t\r\n");
}

/// The first line of `s`, at most 100 bytes (a signature for a list row).
fn oneLine(s: []const u8) []const u8 {
    const nl = std.mem.indexOfScalar(u8, s, '\n') orelse s.len;
    return s[0..@min(nl, 100)];
}

// ---- tests -----------------------------------------------------------------

const testing = std.testing;

fn find(list: []const Member, name: []const u8) ?Member {
    for (list) |m| if (std.mem.eql(u8, m.name, name)) return m;
    return null;
}

fn fakeStd(tmp: *testing.TmpDir) !void {
    const io = testing.io;
    try tmp.dir.createDirPath(io, "lib/std/fs");
    try tmp.dir.writeFile(io, .{ .sub_path = "lib/std/std.zig", .data =
        \\pub const mem = @import("mem.zig");
        \\pub const fs = @import("fs.zig");
        \\pub const Alloc = mem.Allocator;
        \\pub const List = struct {
        \\    items: []u8,
        \\    pub fn append(self: *List, x: u8) !void { _ = self; _ = x; }
        \\    fn hidden() void {}
        \\};
        \\fn private() void {}
    });
    try tmp.dir.writeFile(io, .{ .sub_path = "lib/std/mem.zig", .data =
        \\pub const Allocator = struct {
        \\    ptr: *anyopaque,
        \\    pub fn alloc(self: Allocator, comptime T: type, n: usize) ![]T { _ = self; _ = n; }
        \\    pub const Error = error{OutOfMemory};
        \\};
        \\pub fn eql(comptime T: type, a: []const T, b: []const T) bool { _ = a; _ = b; return true; }
        \\pub const Mode = enum { read, write };
    });
    try tmp.dir.writeFile(io, .{ .sub_path = "lib/std/fs.zig", .data = "pub const path = @import(\"fs/path.zig\");\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "lib/std/fs/path.zig", .data = "pub fn join(parts: []const []const u8) []u8 { _ = parts; }\n" });
}

fn stdPath(tmp: *testing.TmpDir, buf: []u8) ![]const u8 {
    const n = try tmp.dir.realPathFile(testing.io, "lib/std", buf);
    return buf[0..n];
}

test "member lookup follows imports, aliases, containers and visibility" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try fakeStd(&tmp);
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    var index = try Index.init(testing.allocator, testing.io, try stdPath(&tmp, &pbuf));
    defer index.deinit();
    const buf = try index.parseBuffer("const std = @import(\"std\");\nconst m = std.mem;\nconst A = std.mem.Allocator;\nconst Local = struct { a: u32, b: bool };\npub fn run(x: u32) void { _ = x; }\n", "/proj/src");
    defer index.freeBuffer(buf);

    var out: std.ArrayListUnmanaged(Member) = .empty;
    defer out.deinit(testing.allocator);
    // std.: its pub names, with kinds; not the private ones.
    try testing.expect(index.membersOf(buf, &.{"std"}, &out));
    try testing.expectEqual(Kind.namespace, find(out.items, "mem").?.kind);
    try testing.expectEqual(Kind.type, find(out.items, "List").?.kind);
    try testing.expect(find(out.items, "private") == null);

    // std.mem. -> functions with signatures, types, and an enum.
    out.clearRetainingCapacity();
    try testing.expect(index.membersOf(buf, &.{ "std", "mem" }, &out));
    const eql = find(out.items, "eql").?;
    try testing.expectEqual(Kind.function, eql.kind);
    try testing.expectEqualStrings("(comptime T: type, a: []const T, b: []const T) bool", eql.detail);
    try testing.expectEqual(Kind.type, find(out.items, "Mode").?.kind);

    // An alias (`m`), a type via a path (`A`), and a nested file (std.fs.path).
    for ([_][]const []const u8{ &.{"m"}, &.{"A"} }) |p| {
        out.clearRetainingCapacity();
        try testing.expect(index.membersOf(buf, p, &out));
    }
    out.clearRetainingCapacity();
    try testing.expect(index.membersOf(buf, &.{"A"}, &out));
    try testing.expect(find(out.items, "alloc") != null);
    try testing.expectEqual(Kind.field, find(out.items, "ptr").?.kind);
    out.clearRetainingCapacity();
    try testing.expect(index.membersOf(buf, &.{ "std", "fs", "path" }, &out));
    try testing.expect(find(out.items, "join") != null);

    // `std.List.` hides the private function; the alias in std.zig resolves too.
    out.clearRetainingCapacity();
    try testing.expect(index.membersOf(buf, &.{ "std", "List" }, &out));
    try testing.expect(find(out.items, "append") != null and find(out.items, "hidden") == null);
    out.clearRetainingCapacity();
    try testing.expect(index.membersOf(buf, &.{ "std", "Alloc" }, &out));
    try testing.expect(find(out.items, "alloc") != null);

    // Enum values are tagged as such; unknown paths fail.
    out.clearRetainingCapacity();
    try testing.expect(index.membersOf(buf, &.{ "std", "mem", "Mode" }, &out));
    try testing.expectEqual(Kind.enum_value, find(out.items, "read").?.kind);
    try testing.expect(!index.membersOf(buf, &.{ "std", "nope" }, &out));
    try testing.expect(!index.membersOf(buf, &.{"unknown"}, &out));

    // Top level of the buffer: everything, `pub` or not.
    out.clearRetainingCapacity();
    index.topLevel(buf, &out);
    try testing.expect(find(out.items, "run") != null and find(out.items, "Local") != null);
    try testing.expectEqual(Kind.namespace, find(out.items, "std").?.kind);
}

test "lookup finds one declaration with its signature and doc comment" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try fakeStd(&tmp);
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "lib/std/mem.zig", .data =
        \\/// Compare two slices.
        \\/// Returns true if equal.
        \\pub fn eql(comptime T: type, a: []const T, b: []const T) bool { _ = a; _ = b; return true; }
    });
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    var index = try Index.init(testing.allocator, testing.io, try stdPath(&tmp, &pbuf));
    defer index.deinit();
    const buf = try index.parseBuffer("const std = @import(\"std\");\n/// Mine.\nfn local(x: u8) u8 { return x; }\n", "/p");
    defer index.freeBuffer(buf);
    const m = index.lookup(buf, &.{ "std", "mem", "eql" }).?;
    try testing.expectEqual(Kind.function, m.kind);
    try testing.expectEqualStrings("(comptime T: type, a: []const T, b: []const T) bool", m.detail);
    try testing.expectEqualStrings("/// Compare two slices.\n/// Returns true if equal.", m.doc);
    const l = index.lookup(buf, &.{"local"}).?;
    try testing.expectEqualStrings("/// Mine.", l.doc);
    try testing.expect(index.lookup(buf, &.{ "std", "mem", "nothing" }) == null);
    try testing.expect(index.lookup(buf, &.{"nothing"}) == null);
}

test "no std dir means std does not resolve, and a broken buffer still indexes what parses" {
    var index = try Index.init(testing.allocator, testing.io, null);
    defer index.deinit();
    const buf = try index.parseBuffer("const std = @import(\"std\");\npub fn ok() void {}\nfn broken( {\n", "/p");
    defer index.freeBuffer(buf);
    var out: std.ArrayListUnmanaged(Member) = .empty;
    defer out.deinit(testing.allocator);
    try testing.expect(!index.membersOf(buf, &.{"std"}, &out));
    index.topLevel(buf, &out);
    try testing.expect(find(out.items, "ok") != null);
}
