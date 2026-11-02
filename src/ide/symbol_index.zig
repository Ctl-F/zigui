//! A searchable list of every file and every Zig declaration (functions, types,
//! constants, variables) in a project and, optionally, in the Zig standard
//! library, built on a worker thread from `std.zig.Ast`. No UI here: the quick
//! open palette (`quick_open.zig`) shows it.
//!
//!     const idx = try SymbolIndex.start(gpa, &project, std_dir, sdl.wake);
//!     defer idx.destroy();
//!     // each loop iteration:
//!     if (idx.poll()) { ... idx.symbols() changed ... }
//!     for (idx.symbols()) |s| { s.name; s.kind; s.path; s.line; }
//!     idx.rescan();      // after files changed (ignored while a scan runs)
//!
//! Declarations are listed from the files on disk, so unsaved edits show after a
//! save and a `rescan`. Nested types give qualified names (`ArrayList.append`).
//! Only `pub` declarations of the standard library are listed. Paths of
//! project files are project-relative; standard library files have absolute
//! paths and `shown` starting with `std/`.

const std = @import("std");
const Ast = std.zig.Ast;
const Node = Ast.Node;
const worker = @import("../core/worker.zig");
const project_mod = @import("project.zig");
const Project = project_mod.Project;

pub const Kind = enum { file, function, type, constant, variable };

pub const Symbol = struct {
    /// What is matched against: a file's base name, a declaration's (qualified) name.
    name: []const u8,
    kind: Kind,
    /// To open it: project-relative, or absolute for the standard library.
    path: []const u8,
    /// To show it: the project-relative path, or `std/...`.
    shown: []const u8,
    /// 1-based position of the name (files: 1:1).
    line: u32,
    col: u32,
    in_std: bool,
};

const Snapshot = struct {
    arena: std.heap.ArenaAllocator,
    symbols: []Symbol,
};

const max_source = 2 * 1024 * 1024;
const max_depth = 4;
pub const max_symbols = 400_000;

pub const SymbolIndex = struct {
    gpa: std.mem.Allocator,
    project: *const Project,
    std_dir: ?[]u8,
    /// Scan only `std_dir` (the project is covered by another index).
    skip_project: bool = false,
    queue: worker.Queue(*Snapshot),
    thread: ?std.Thread = null,
    running_flag: std.atomic.Value(bool) = .init(false),
    stop: std.atomic.Value(bool) = .init(false),
    current: ?*Snapshot = null,
    batch: std.ArrayListUnmanaged(*Snapshot) = .empty,

    pub fn start(gpa: std.mem.Allocator, project: *const Project, std_dir: ?[]const u8, wake: ?*const fn () void) !*SymbolIndex {
        return create(gpa, project, std_dir, false, wake);
    }

    /// An index of only the library at `lib_dir` (it does not change while the IDE runs).
    pub fn startLibrary(gpa: std.mem.Allocator, project: *const Project, lib_dir: []const u8, wake: ?*const fn () void) !*SymbolIndex {
        return create(gpa, project, lib_dir, true, wake);
    }

    fn create(gpa: std.mem.Allocator, project: *const Project, std_dir: ?[]const u8, skip_project: bool, wake: ?*const fn () void) !*SymbolIndex {
        const self = try gpa.create(SymbolIndex);
        errdefer gpa.destroy(self);
        const sd: ?[]u8 = if (std_dir) |d| try gpa.dupe(u8, d) else null;
        self.* = .{ .gpa = gpa, .project = project, .std_dir = sd, .skip_project = skip_project, .queue = .{ .gpa = gpa, .wake = wake } };
        try self.launch();
        return self;
    }

    fn launch(self: *SymbolIndex) !void {
        if (self.thread) |t| t.join();
        self.thread = null;
        self.running_flag.store(true, .release);
        errdefer self.running_flag.store(false, .release);
        self.thread = try std.Thread.spawn(.{}, run, .{self});
    }

    /// Scan again (when nothing is running).
    pub fn rescan(self: *SymbolIndex) void {
        if (self.running()) return;
        self.launch() catch {};
    }

    pub fn running(self: *const SymbolIndex) bool {
        return self.running_flag.load(.acquire);
    }

    /// Everything found by the latest finished scan (empty before the first).
    pub fn symbols(self: *const SymbolIndex) []const Symbol {
        return if (self.current) |c| c.symbols else &.{};
    }

    /// Take a finished scan, if one arrived. True when `symbols()` changed.
    pub fn poll(self: *SymbolIndex) bool {
        self.queue.drain(&self.batch);
        defer self.batch.clearRetainingCapacity();
        var changed = false;
        for (self.batch.items) |snap| {
            self.freeSnapshot(self.current);
            self.current = snap;
            changed = true;
        }
        return changed;
    }

    fn freeSnapshot(self: *SymbolIndex, snap: ?*Snapshot) void {
        const s = snap orelse return;
        s.arena.deinit();
        self.gpa.destroy(s);
    }

    pub fn destroy(self: *SymbolIndex) void {
        self.stop.store(true, .release);
        if (self.thread) |t| t.join();
        _ = self.poll();
        self.freeSnapshot(self.current);
        self.batch.deinit(self.gpa);
        self.queue.deinit();
        if (self.std_dir) |d| self.gpa.free(d);
        self.gpa.destroy(self);
    }

    fn run(self: *SymbolIndex) void {
        defer self.running_flag.store(false, .release);
        const snap = self.gpa.create(Snapshot) catch return;
        snap.* = .{ .arena = .init(self.gpa), .symbols = &.{} };
        var list: std.ArrayListUnmanaged(Symbol) = .empty;
        var b: Builder = .{ .gpa = self.gpa, .a = snap.arena.allocator(), .list = &list, .stop = &self.stop };
        if (!self.skip_project) self.scanProject(&b);
        if (self.std_dir) |d| self.scanStd(&b, d);
        if (self.stop.load(.acquire)) {
            snap.arena.deinit();
            self.gpa.destroy(snap);
            return;
        }
        snap.symbols = list.items;
        self.queue.push(snap) catch {
            snap.arena.deinit();
            self.gpa.destroy(snap);
        };
    }

    fn scanProject(self: *SymbolIndex, b: *Builder) void {
        const io = self.project.io;
        var walker = self.project.dir.walkSelectively(self.gpa) catch return;
        defer walker.deinit();
        while (walker.next(io) catch null) |entry| {
            if (self.stop.load(.acquire) or b.list.items.len >= max_symbols) return;
            switch (entry.kind) {
                .directory => if (!project_mod.isExcludedName(entry.basename)) walker.enter(io, entry) catch {},
                .file => {
                    const rel = b.a.dupe(u8, entry.path) catch return;
                    for (rel) |*c| {
                        if (c.* == '\\') c.* = '/';
                    }
                    b.addFile(entry.basename, rel, rel, false);
                    if (std.mem.endsWith(u8, entry.basename, ".zig")) {
                        const src = self.project.dir.readFileAllocOptions(io, entry.path, self.gpa, .limited(max_source), .of(u8), 0) catch continue;
                        defer self.gpa.free(src);
                        b.addDecls(src, rel, rel, false);
                    }
                },
                else => {},
            }
        }
    }

    fn scanStd(self: *SymbolIndex, b: *Builder, root: []const u8) void {
        const io = self.project.io;
        var dir = std.Io.Dir.cwd().openDir(io, root, .{ .iterate = true }) catch return;
        defer dir.close(io);
        var walker = dir.walkSelectively(self.gpa) catch return;
        defer walker.deinit();
        while (walker.next(io) catch null) |entry| {
            if (self.stop.load(.acquire) or b.list.items.len >= max_symbols) return;
            switch (entry.kind) {
                .directory => if (!std.mem.eql(u8, entry.basename, "testdata")) walker.enter(io, entry) catch {},
                .file => {
                    if (!std.mem.endsWith(u8, entry.basename, ".zig")) continue;
                    const abs = std.fs.path.join(b.a, &.{ root, entry.path }) catch return;
                    const shown = std.fmt.allocPrint(b.a, "std/{s}", .{entry.path}) catch return;
                    b.addFile(entry.basename, abs, shown, true);
                    const src = dir.readFileAllocOptions(io, entry.path, self.gpa, .limited(max_source), .of(u8), 0) catch continue;
                    defer self.gpa.free(src);
                    b.addDecls(src, abs, shown, true);
                },
                else => {},
            }
        }
    }
};

const Builder = struct {
    gpa: std.mem.Allocator,
    a: std.mem.Allocator,
    list: *std.ArrayListUnmanaged(Symbol),
    stop: *const std.atomic.Value(bool),
    // Incremental line counting (declarations are visited in source order).
    line_off: usize = 0,
    line_no: u32 = 1,
    line_start: usize = 0,

    fn addFile(self: *Builder, base: []const u8, path: []const u8, shown: []const u8, in_std: bool) void {
        const name = self.a.dupe(u8, base) catch return;
        self.list.append(self.a, .{ .name = name, .kind = .file, .path = path, .shown = shown, .line = 1, .col = 1, .in_std = in_std }) catch {};
    }

    fn addDecls(self: *Builder, src: [:0]const u8, path: []const u8, shown: []const u8, in_std: bool) void {
        var ast = Ast.parse(self.gpa, src, .{}) catch return;
        defer ast.deinit(self.gpa);
        self.line_off = 0;
        self.line_no = 1;
        self.line_start = 0;
        self.members(&ast, ast.rootDecls(), "", 0, in_std, path, shown);
    }

    fn lineCol(self: *Builder, ast: *const Ast, tok: Ast.TokenIndex) struct { u32, u32 } {
        const off = ast.tokenStart(tok);
        if (off < self.line_off) {
            self.line_off = 0;
            self.line_no = 1;
            self.line_start = 0;
        }
        var i = self.line_off;
        while (i < off) : (i += 1) {
            if (ast.source[i] == '\n') {
                self.line_no += 1;
                self.line_start = i + 1;
            }
        }
        self.line_off = off;
        return .{ self.line_no, @intCast(off - self.line_start + 1) };
    }

    fn members(self: *Builder, ast: *const Ast, nodes: []const Node.Index, prefix: []const u8, depth: u32, in_std: bool, path: []const u8, shown: []const u8) void {
        for (nodes) |n| {
            if (self.stop.load(.acquire)) return;
            var fb: [1]Node.Index = undefined;
            var name_tok: ?Ast.TokenIndex = null;
            var kind: Kind = .constant;
            var is_pub = false;
            var container: ?Node.Index = null;
            if (ast.fullVarDecl(n)) |vd| {
                name_tok = vd.ast.mut_token + 1;
                is_pub = vd.visib_token != null;
                kind = if (ast.tokenTag(vd.ast.mut_token) == .keyword_const) .constant else .variable;
                if (vd.ast.init_node.unwrap()) |i| {
                    var cb: [2]Node.Index = undefined;
                    if (ast.fullContainerDecl(&cb, i) != null) {
                        kind = .type;
                        container = i;
                    } else switch (ast.nodeTag(i)) {
                        .builtin_call_two, .builtin_call_two_comma => if (std.mem.eql(u8, ast.tokenSlice(ast.nodeMainToken(i)), "@import")) continue,
                        else => {},
                    }
                }
            } else switch (ast.nodeTag(n)) {
                .fn_decl, .fn_proto, .fn_proto_multi, .fn_proto_one, .fn_proto_simple => {
                    const proto = if (ast.nodeTag(n) == .fn_decl) ast.nodeData(n).node_and_node[0] else n;
                    const fp = ast.fullFnProto(&fb, proto) orelse continue;
                    name_tok = fp.name_token orelse continue;
                    is_pub = fp.visib_token != null;
                    kind = .function;
                },
                else => continue,
            }
            if (in_std and !is_pub) continue;
            const tok = name_tok orelse continue;
            const base = ast.tokenSlice(tok);
            if (base.len == 0 or base[0] == '@' or base[0] == '"') continue; // @"quoted" names
            const name = if (prefix.len == 0) (self.a.dupe(u8, base) catch return) else (std.fmt.allocPrint(self.a, "{s}.{s}", .{ prefix, base }) catch return);
            const lc = self.lineCol(ast, tok);
            self.list.append(self.a, .{ .name = name, .kind = kind, .path = path, .shown = shown, .line = lc[0], .col = lc[1], .in_std = in_std }) catch return;
            if (container) |c| {
                if (depth + 1 < max_depth) {
                    var cb: [2]Node.Index = undefined;
                    if (ast.fullContainerDecl(&cb, c)) |cd| self.members(ast, cd.ast.members, name, depth + 1, in_std, path, shown);
                }
            }
        }
    }
};

// ---- tests -----------------------------------------------------------------

const testing = std.testing;

fn waitDone(idx: *SymbolIndex) !void {
    var tries: usize = 0;
    while (tries < 5000) : (tries += 1) {
        if (idx.poll()) return;
        var ts: std.os.linux.timespec = .{ .sec = 0, .nsec = 1_000_000 };
        _ = std.os.linux.nanosleep(&ts, null);
    }
    return error.Timeout;
}

fn find(syms: []const Symbol, name: []const u8) ?Symbol {
    for (syms) |s| {
        if (std.mem.eql(u8, s.name, name)) return s;
    }
    return null;
}

test "lists files and declarations with positions, qualifying nested ones" {
    if (@import("builtin").os.tag != .linux) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var p = try project_mod.testProject(&tmp);
    defer p.close();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "src/shapes.zig", .data =
        \\const std = @import("std");
        \\
        \\pub const Circle = struct {
        \\    r: f32,
        \\    pub fn area(self: Circle) f32 {
        \\        return self.r;
        \\    }
        \\};
        \\fn helper() void {}
        \\var counter: u32 = 0;
        \\
    });
    const idx = try SymbolIndex.start(testing.allocator, &p, null, null);
    defer idx.destroy();
    try waitDone(idx);
    const syms = idx.symbols();
    try testing.expect(find(syms, "shapes.zig") != null);
    try testing.expect(find(syms, "shapes.zig").?.kind == .file);
    const circle = find(syms, "Circle").?;
    try testing.expect(circle.kind == .type);
    try testing.expectEqual(@as(u32, 3), circle.line);
    try testing.expectEqual(@as(u32, 11), circle.col);
    try testing.expectEqualStrings("src/shapes.zig", circle.path);
    const area = find(syms, "Circle.area").?;
    try testing.expect(area.kind == .function);
    try testing.expectEqual(@as(u32, 5), area.line);
    try testing.expectEqual(@as(u32, 12), area.col);
    try testing.expect(find(syms, "helper").?.kind == .function); // private is listed for the project
    try testing.expect(find(syms, "counter").?.kind == .variable);
    try testing.expect(find(syms, "std") == null); // an @import is not a declaration worth jumping to
    try testing.expect(find(syms, "r") == null); // fields are left out
}

test "a second root lists only pub declarations of .zig files, with absolute paths" {
    if (@import("builtin").os.tag != .linux) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var p = try project_mod.testProject(&tmp);
    defer p.close();
    var other = testing.tmpDir(.{ .iterate = true });
    defer other.cleanup();
    try other.dir.writeFile(testing.io, .{ .sub_path = "mem.zig", .data = "pub fn eql() bool { return true; }\nfn hidden() void {}\n" });
    try other.dir.writeFile(testing.io, .{ .sub_path = "notes.txt", .data = "x" });
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try other.dir.realPath(testing.io, &buf);
    const idx = try SymbolIndex.start(testing.allocator, &p, buf[0..n], null);
    defer idx.destroy();
    try waitDone(idx);
    const eql = find(idx.symbols(), "eql").?;
    try testing.expect(eql.in_std and std.fs.path.isAbsolute(eql.path));
    try testing.expectEqualStrings("std/mem.zig", eql.shown);
    try testing.expect(find(idx.symbols(), "hidden") == null);
    try testing.expect(find(idx.symbols(), "notes.txt") == null);
}
