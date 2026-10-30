//! Zig completion that works with no language server: a `Completion` provider
//! over the `std.zig.Ast` index in `zig_index.zig`.
//!
//!     const std_dir = zig_complete.locateStdDir(gpa, io);       // runs `zig env`; may be null
//!     const zc = try ZigCompleter.create(gpa, io, std_dir);
//!     try completion.addProvider(zc.provider());
//!     zc.setDir(editor, "/project/src");                          // where this file lives
//!
//! After `name.` it lists what `name` leads to (`std.mem.`, an imported file,
//! a struct declared in the file). Elsewhere it offers the file's own top-level
//! names, builtin functions after `@`, and keywords and primitive types. It only
//! answers for editors whose language is Zig. A language server (later) adds to
//! these answers rather than replacing them.

const std = @import("std");
const Completion = @import("../widgets/completion.zig");
const CodeEditor = @import("../widgets/code_editor.zig").CodeEditor;
const syntax = @import("../editor/syntax.zig");
const zig_index = @import("zig_index.zig");

const keywords = [_][]const u8{
    "const",   "var",      "fn",       "pub",    "return",   "if",      "else",       "while",       "for",      "switch",
    "break",   "continue", "defer",    "errdefer", "try",    "catch",   "orelse",     "struct",      "enum",     "union",
    "error",   "comptime", "inline",   "test",   "unreachable", "undefined", "null",   "true",        "false",    "and",
    "or",      "usingnamespace", "extern", "export", "packed", "align",  "anytype",    "noreturn",    "opaque",   "suspend",
};

const primitives = [_][]const u8{
    "u8", "u16", "u32", "u64", "u128", "usize", "i8", "i16", "i32", "i64", "i128", "isize", "f16", "f32", "f64", "f128",
    "bool", "void", "type", "anyerror", "anyopaque", "comptime_int", "comptime_float", "c_int", "c_uint", "c_char",
};

const Builtin = struct { name: []const u8, detail: []const u8 };

const builtins = [_]Builtin{
    .{ .name = "@import", .detail = "(comptime path: []const u8) type" },
    .{ .name = "@cImport", .detail = "(expression) type" },
    .{ .name = "@as", .detail = "(comptime T: type, value) T" },
    .{ .name = "@intCast", .detail = "(int) anytype" },
    .{ .name = "@floatCast", .detail = "(float) anytype" },
    .{ .name = "@intFromFloat", .detail = "(float) anytype" },
    .{ .name = "@floatFromInt", .detail = "(int) anytype" },
    .{ .name = "@intFromEnum", .detail = "(enum_or_tagged_union) anytype" },
    .{ .name = "@enumFromInt", .detail = "(int) anytype" },
    .{ .name = "@intFromBool", .detail = "(bool) u1" },
    .{ .name = "@intFromPtr", .detail = "(ptr) usize" },
    .{ .name = "@ptrFromInt", .detail = "(address: usize) anytype" },
    .{ .name = "@ptrCast", .detail = "(ptr) anytype" },
    .{ .name = "@alignCast", .detail = "(ptr) anytype" },
    .{ .name = "@constCast", .detail = "(ptr) anytype" },
    .{ .name = "@bitCast", .detail = "(value) anytype" },
    .{ .name = "@truncate", .detail = "(int) anytype" },
    .{ .name = "@sizeOf", .detail = "(comptime T: type) comptime_int" },
    .{ .name = "@alignOf", .detail = "(comptime T: type) comptime_int" },
    .{ .name = "@bitSizeOf", .detail = "(comptime T: type) comptime_int" },
    .{ .name = "@offsetOf", .detail = "(comptime T: type, comptime field: []const u8) comptime_int" },
    .{ .name = "@typeInfo", .detail = "(comptime T: type) std.builtin.Type" },
    .{ .name = "@typeName", .detail = "(comptime T: type) *const [N:0]u8" },
    .{ .name = "@TypeOf", .detail = "(...) type" },
    .{ .name = "@This", .detail = "() type" },
    .{ .name = "@field", .detail = "(lhs, comptime name: []const u8) anytype" },
    .{ .name = "@hasField", .detail = "(comptime T: type, comptime name: []const u8) bool" },
    .{ .name = "@hasDecl", .detail = "(comptime Container: type, comptime name: []const u8) bool" },
    .{ .name = "@embedFile", .detail = "(comptime path: []const u8) *const [N:0]u8" },
    .{ .name = "@compileError", .detail = "(comptime msg: []const u8) noreturn" },
    .{ .name = "@compileLog", .detail = "(...) void" },
    .{ .name = "@panic", .detail = "(message: []const u8) noreturn" },
    .{ .name = "@min", .detail = "(...) anytype" },
    .{ .name = "@max", .detail = "(...) anytype" },
    .{ .name = "@abs", .detail = "(value) anytype" },
    .{ .name = "@memcpy", .detail = "(dest, source) void" },
    .{ .name = "@memset", .detail = "(dest, elem) void" },
    .{ .name = "@splat", .detail = "(scalar) anytype" },
    .{ .name = "@call", .detail = "(options, function, args) anytype" },
    .{ .name = "@src", .detail = "() std.builtin.SourceLocation" },
    .{ .name = "@tagName", .detail = "(enum_or_union) [:0]const u8" },
    .{ .name = "@errorName", .detail = "(err: anyerror) [:0]const u8" },
    .{ .name = "@errorCast", .detail = "(value) anytype" },
    .{ .name = "@setRuntimeSafety", .detail = "(comptime on: bool) void" },
    .{ .name = "@branchHint", .detail = "(hint: std.builtin.BranchHint) void" },
    .{ .name = "@mulAdd", .detail = "(comptime T: type, a: T, b: T, c: T) T" },
    .{ .name = "@sqrt", .detail = "(value) @TypeOf(value)" },
    .{ .name = "@shuffle", .detail = "(comptime E: type, a, b, comptime mask) anytype" },
    .{ .name = "@Vector", .detail = "(len: comptime_int, Element: type) type" },
    .{ .name = "@fieldParentPtr", .detail = "(comptime field_name: []const u8, field_ptr) anytype" },
    .{ .name = "@unionInit", .detail = "(comptime Union: type, comptime active_field_name: []const u8, init_expr) Union" },
    .{ .name = "@addWithOverflow", .detail = "(a, b) struct { T, u1 }" },
    .{ .name = "@mulWithOverflow", .detail = "(a, b) struct { T, u1 }" },
    .{ .name = "@subWithOverflow", .detail = "(a, b) struct { T, u1 }" },
    .{ .name = "@shlWithOverflow", .detail = "(a, shift_amt) struct { T, u1 }" },
    .{ .name = "@popCount", .detail = "(operand) anytype" },
    .{ .name = "@clz", .detail = "(operand) anytype" },
    .{ .name = "@ctz", .detail = "(operand) anytype" },
    .{ .name = "@byteSwap", .detail = "(operand) anytype" },
    .{ .name = "@trap", .detail = "() noreturn" },
    .{ .name = "@breakpoint", .detail = "() void" },
    .{ .name = "@returnAddress", .detail = "() usize" },
    .{ .name = "@export", .detail = "(comptime ptr, comptime options) void" },
    .{ .name = "@extern", .detail = "(comptime T: type, comptime options) T" },
    .{ .name = "@inComptime", .detail = "() bool" },
    .{ .name = "@reduce", .detail = "(comptime op: std.builtin.ReduceOp, value) anytype" },
    .{ .name = "@select", .detail = "(comptime T: type, pred, a, b) anytype" },
    .{ .name = "@divTrunc", .detail = "(numerator, denominator) anytype" },
    .{ .name = "@divFloor", .detail = "(numerator, denominator) anytype" },
    .{ .name = "@mod", .detail = "(numerator, denominator) anytype" },
    .{ .name = "@rem", .detail = "(numerator, denominator) anytype" },
};

/// The standard library directory, from `zig env` (null if `zig` cannot run).
/// Caller frees.
pub fn locateStdDir(gpa: std.mem.Allocator, io: std.Io) ?[]u8 {
    const res = std.process.run(gpa, io, .{ .argv = &.{ "zig", "env" } }) catch return null;
    defer gpa.free(res.stdout);
    defer gpa.free(res.stderr);
    return parseStdDir(gpa, res.stdout);
}

/// The `.std_dir = "..."` value of `zig env`'s output.
pub fn parseStdDir(gpa: std.mem.Allocator, env_text: []const u8) ?[]u8 {
    const key = ".std_dir = \"";
    const at = std.mem.indexOf(u8, env_text, key) orelse return null;
    const rest = env_text[at + key.len ..];
    const end = std.mem.indexOfScalar(u8, rest, '"') orelse return null;
    if (end == 0) return null;
    return gpa.dupe(u8, rest[0..end]) catch null;
}

pub const ZigCompleter = struct {
    gpa: std.mem.Allocator,
    index: zig_index.Index,
    /// The directory each editor's file lives in (for relative imports).
    dirs: std.AutoHashMapUnmanaged(*CodeEditor, []u8) = .empty,
    /// The parse of the editor's text from the last request.
    cached: ?*zig_index.File = null,
    cached_editor: ?*CodeEditor = null,
    cached_hash: u64 = 0,

    pub fn create(gpa: std.mem.Allocator, io: std.Io, std_dir: ?[]const u8) !*ZigCompleter {
        const self = try gpa.create(ZigCompleter);
        errdefer gpa.destroy(self);
        self.* = .{ .gpa = gpa, .index = try zig_index.Index.init(gpa, io, std_dir) };
        return self;
    }

    pub fn destroy(self: *ZigCompleter) void {
        self.dropCache();
        var it = self.dirs.valueIterator();
        while (it.next()) |v| self.gpa.free(v.*);
        self.dirs.deinit(self.gpa);
        self.index.deinit();
        self.gpa.destroy(self);
    }

    pub fn provider(self: *ZigCompleter) Completion.Provider {
        return Completion.Provider.bind(self, complete);
    }

    /// Tell the completer where `ed`'s file lives (an absolute directory).
    pub fn setDir(self: *ZigCompleter, ed: *CodeEditor, dir: []const u8) !void {
        const copy = try self.gpa.dupe(u8, dir);
        errdefer self.gpa.free(copy);
        const old = try self.dirs.fetchPut(self.gpa, ed, copy);
        if (old) |o| self.gpa.free(o.value);
    }

    /// Forget `ed` (do this when it is destroyed).
    pub fn forget(self: *ZigCompleter, ed: *CodeEditor) void {
        if (self.dirs.fetchRemove(ed)) |kv| self.gpa.free(kv.value);
        if (self.cached_editor == ed) self.dropCache();
    }

    fn dropCache(self: *ZigCompleter) void {
        if (self.cached) |f| self.index.freeBuffer(f);
        self.cached = null;
        self.cached_editor = null;
    }

    fn bufferFor(self: *ZigCompleter, ed: *CodeEditor) ?*zig_index.File {
        const doc = &ed.core().doc;
        const text = doc.textAlloc(self.gpa, 0, doc.len()) catch return null;
        defer self.gpa.free(text);
        const hash = std.hash.Wyhash.hash(0, text);
        if (self.cached != null and self.cached_editor == ed and self.cached_hash == hash) return self.cached;
        self.dropCache();
        const dir = self.dirs.get(ed) orelse "/";
        self.cached = self.index.parseBuffer(text, dir) catch return null;
        self.cached_editor = ed;
        self.cached_hash = hash;
        return self.cached;
    }

    pub fn complete(self: *ZigCompleter, req: *const Completion.Request, sink: *Completion.Sink) void {
        const lang = req.editor.language() orelse return;
        if (lang != &syntax.zig) return;
        const file = self.bufferFor(req.editor) orelse return;
        var members: std.ArrayListUnmanaged(zig_index.Member) = .empty;
        defer members.deinit(self.gpa);

        if (req.afterDot()) {
            var segs: [8][]const u8 = undefined;
            const path = dottedPath(req.line_before, &segs) orelse return;
            if (!self.index.membersOf(file, path, &members)) return;
            for (members.items) |m| sink.add(.{ .label = m.name, .detail = m.detail, .tag = m.kind.tag() });
            return;
        }
        if (req.prefix.len > 0 and req.prefix[0] == '@') {
            for (builtins) |b| sink.add(.{ .label = b.name, .detail = b.detail, .tag = "fn" });
            return;
        }
        if (req.prefix.len == 0 and !req.explicit) return;
        self.index.topLevel(file, &members);
        for (members.items) |m| sink.add(.{ .label = m.name, .detail = m.detail, .tag = m.kind.tag() });
        for (keywords) |k| sink.add(.{ .label = k, .tag = "kw" });
        for (primitives) |p| sink.add(.{ .label = p, .tag = "type" });
    }
};

/// The names in `a.b.c.` (the text before the last dot, already stripped of the
/// word being typed): `{"a","b","c"}`; null if it is not a plain dotted path.
/// `@import("std").` counts as `std`.
fn dottedPath(before: []const u8, out: *[8][]const u8) ?[]const []const u8 {
    var end = before.len;
    if (end == 0 or before[end - 1] != '.') return null;
    end -= 1;
    var start = end;
    while (start > 0 and (std.ascii.isAlphanumeric(before[start - 1]) or before[start - 1] == '_' or before[start - 1] == '.')) start -= 1;
    var n: usize = 0;
    // `@import("std").mem.`: the chain starts right after the `)`.
    if (start > 0 and before[start - 1] == ')') {
        const close = start - 1;
        const open_at = std.mem.lastIndexOf(u8, before[0..close], "@import(\"") orelse return null;
        const name = before[open_at + "@import(\"".len .. close];
        if (name.len < 1 or name[name.len - 1] != '"') return null;
        out[0] = name[0 .. name.len - 1];
        n = 1;
        // The dot after `)` is the first character of the chain.
        if (start < end and before[start] == '.') start += 1;
    }
    var it = std.mem.splitScalar(u8, before[start..end], '.');
    while (it.next()) |seg| {
        if (seg.len == 0) {
            if (n > 0 and start == end) break;
            return null;
        }
        if (n == out.len) return null;
        out[n] = seg;
        n += 1;
    }
    return if (n == 0) null else out[0..n];
}

// ---- tests -----------------------------------------------------------------

const testing = std.testing;
const Rig = @import("../core/test_rig.zig").Rig;

test "dotted paths are read from the text before the cursor" {
    var segs: [8][]const u8 = undefined;
    const a = dottedPath("const x = std.mem.", &segs).?;
    try testing.expectEqual(@as(usize, 2), a.len);
    try testing.expectEqualStrings("std", a[0]);
    try testing.expectEqualStrings("mem", a[1]);
    const b = dottedPath("    foo.", &segs).?;
    try testing.expectEqualStrings("foo", b[0]);
    const c = dottedPath("@import(\"std\").", &segs).?;
    try testing.expectEqualStrings("std", c[0]);
    try testing.expectEqual(@as(usize, 1), c.len);
    const d = dottedPath("x = @import(\"std\").fs.", &segs).?;
    try testing.expectEqual(@as(usize, 2), d.len);
    try testing.expectEqualStrings("fs", d[1]);
    try testing.expect(dottedPath("foo(bar).", &segs) == null);
    try testing.expect(dottedPath("a.", &segs) != null);
}

test "parseStdDir reads zig env output" {
    const dir = parseStdDir(testing.allocator, ".{\n    .lib_dir = \"/z/lib\",\n    .std_dir = \"/z/lib/std\",\n}\n").?;
    defer testing.allocator.free(dir);
    try testing.expectEqualStrings("/z/lib/std", dir);
    try testing.expect(parseStdDir(testing.allocator, "nothing here") == null);
}

fn labelsHave(r: *Rig, label: []const u8) bool {
    const p = r.ui.popup orelse return false;
    for (p.entries) |e| if (std.mem.eql(u8, e.row.label, label)) return true;
    return false;
}

test "typing std.mem. in a Zig file lists the library's names; other files are left alone" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const io = testing.io;
    try tmp.dir.createDirPath(io, "lib/std");
    try tmp.dir.writeFile(io, .{ .sub_path = "lib/std/std.zig", .data = "pub const mem = @import(\"mem.zig\");\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "lib/std/mem.zig", .data = "pub fn eql(a: u8, b: u8) bool { _ = a; _ = b; return true; }\npub const Allocator = struct {};\n" });
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPathFile(io, "lib/std", &pbuf);

    const r = try Rig.init();
    defer r.deinit();
    const ed = try r.ui.add(CodeEditor, r.ui.tree.root, .{ .style = .{ .grow = 1 }, .label = "t", .language = &syntax.zig });
    try ed.loadText(try r.ui.gpa.dupe(u8, "const std = @import(\"std\");\nconst Thing = struct {};\n"), true);
    r.ui.setFocus(ed.node);
    try r.frame();
    const zc = try ZigCompleter.create(testing.allocator, io, pbuf[0..n]);
    defer zc.destroy();
    const comp = try Completion.Completion.create(&r.ui);
    defer comp.destroy();
    try comp.addProvider(zc.provider());
    try comp.attach(ed);
    defer comp.detach(ed);
    defer zc.forget(ed);
    try zc.setDir(ed, "/proj");

    ed.core().setCaret(ed.core().doc.len(), false);
    r.ui.textInput("std.mem.");
    try r.frame();
    try testing.expect(comp.isOpen());
    try testing.expect(labelsHave(r, "eql"));
    try testing.expect(labelsHave(r, "Allocator"));
    r.ui.textInput("al");
    try r.frame();
    try testing.expect(labelsHave(r, "Allocator"));
    try testing.expect(!labelsHave(r, "eql"));
    r.ui.key(.escape, .{}, true, false);

    // Own top-level names and builtins.
    r.ui.textInput("\nconst x = Th");
    try r.frame();
    try testing.expect(labelsHave(r, "Thing"));
    r.ui.key(.escape, .{}, true, false);
    r.ui.textInput("\nconst y = @imp");
    try r.frame();
    try testing.expect(labelsHave(r, "@import"));
    r.ui.key(.escape, .{}, true, false);

    // Not Zig: the provider stays quiet.
    try ed.setLanguage(&syntax.plain);
    r.ui.textInput("\nstd.mem.");
    try r.frame();
    try testing.expect(!labelsHave(r, "eql"));
}
