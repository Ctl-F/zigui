//! Finding a project's Zig tests, and reading what a test run reports. No UI
//! here (`test_panel.zig` is the panel).
//!
//!     var idx = try scan(gpa, io, project.dir);        // every `test` declaration, by file and line
//!     defer idx.deinit();
//!     for (idx.tests) |t| { t.file; t.name; t.line; fullName(a, t) }
//!
//!     var p = Parser.init(gpa, .direct);               // `zig test FILE` output, as it arrives
//!     defer p.deinit();
//!     try p.feed(bytes);                               // call `finish` at the end
//!     for (p.outcomes.items) |o| { o.name; o.status; o.detail; }
//!
//! **Names.** The compiler names a test `<file>.test.<name>` (`<file>` is the file's
//! path inside its module with dots, for example `ide.proj_settings`), a
//! `test fnName {}` declaration test `<file>.decltest.fnName`, and an unnamed
//! `test {}` `<file>.test_<n>`. `fullName` rebuilds that with the file's base
//! name, which is what a test filter needs (filters match anywhere in the name),
//! and `matches` decides whether a name in a report belongs to a test.
//!
//! **Two kinds of report.** `zig test FILE` runs the test program directly and
//! prints a line per test as it runs (`3/8 main.test.skipped one...SKIP`), so the
//! status arrives live. `zig build test` runs it through the build system, which
//! shows only a summary and a block for each failing test; every other test is
//! taken to have passed when the run succeeded.

const std = @import("std");
const Ast = std.zig.Ast;
const project_mod = @import("project.zig");

pub const Kind = enum { named, decl, unnamed };

pub const Test = struct {
    /// Project-relative path ('/' separators).
    file: []const u8,
    /// The string or identifier after `test` ("" for an unnamed test).
    name: []const u8,
    kind: Kind,
    /// Which unnamed test of its file this is (0 for the first), for `kind == .unnamed`.
    index: u32 = 0,
    /// 1-based line of the `test` keyword.
    line: u32,
};

pub const Index = struct {
    arena: std.heap.ArenaAllocator,
    tests: []Test,

    pub fn deinit(self: *Index) void {
        self.arena.deinit();
    }

    /// The distinct files that have tests, in order of first appearance.
    pub fn files(self: *const Index, gpa: std.mem.Allocator) ![]const []const u8 {
        var out: std.ArrayListUnmanaged([]const u8) = .empty;
        errdefer out.deinit(gpa);
        for (self.tests) |t| {
            if (out.items.len > 0 and std.mem.eql(u8, out.items[out.items.len - 1], t.file)) continue;
            var seen = false;
            for (out.items) |f| {
                if (std.mem.eql(u8, f, t.file)) seen = true;
            }
            if (!seen) try out.append(gpa, t.file);
        }
        return out.toOwnedSlice(gpa);
    }
};

/// The file's base name without `.zig` (what test names are prefixed with).
pub fn stem(file: []const u8) []const u8 {
    return std.fs.path.stem(file);
}

/// `<stem>.test.<name>`, `<stem>.decltest.<name>` or `<stem>.test_<n>`.
pub fn fullName(a: std.mem.Allocator, t: Test) ![]u8 {
    return switch (t.kind) {
        .named => std.fmt.allocPrint(a, "{s}.test.{s}", .{ stem(t.file), t.name }),
        .decl => std.fmt.allocPrint(a, "{s}.decltest.{s}", .{ stem(t.file), t.name }),
        .unnamed => std.fmt.allocPrint(a, "{s}.test_{d}", .{ stem(t.file), t.index }),
    };
}

/// Does `reported` (a name from a test report) belong to `t`? The part from
/// `test`/`decltest` on must be the same; the part before it must name the file
/// (its base name, possibly after module path segments or before nested container names).
pub fn matches(t: Test, reported: []const u8) bool {
    var buf: [512]u8 = undefined;
    const tail = switch (t.kind) {
        .named => std.fmt.bufPrint(&buf, ".test.{s}", .{t.name}) catch return false,
        .decl => std.fmt.bufPrint(&buf, ".decltest.{s}", .{t.name}) catch return false,
        .unnamed => std.fmt.bufPrint(&buf, ".test_{d}", .{t.index}) catch return false,
    };
    if (!std.mem.endsWith(u8, reported, tail)) return false;
    const prefix = reported[0 .. reported.len - tail.len];
    const base = stem(t.file);
    // The prefix is the file's path in its module (`ide.proj_settings`), maybe with container names after.
    var it = std.mem.splitScalar(u8, prefix, '.');
    while (it.next()) |seg| {
        if (std.mem.eql(u8, seg, base)) return true;
    }
    return false;
}

// ---- discovery -------------------------------------------------------------

fn tokenName(ast: *const Ast, tok: Ast.TokenIndex) []const u8 {
    const raw = ast.tokenSlice(tok);
    if (raw.len >= 2 and raw[0] == '"') return raw[1 .. raw.len - 1];
    if (raw.len >= 3 and raw[0] == '@' and raw[1] == '"') return raw[2 .. raw.len - 1];
    return raw;
}

fn lineOf(ast: *const Ast, tok: Ast.TokenIndex) u32 {
    return @intCast(ast.tokenLocation(0, tok).line + 1);
}

fn collect(a: std.mem.Allocator, ast: *const Ast, nodes: []const Ast.Node.Index, file: []const u8, unnamed: *u32, out: *std.ArrayListUnmanaged(Test), depth: u32) !void {
    for (nodes) |n| {
        if (ast.nodeTag(n) == .test_decl) {
            const name_tok = ast.nodeData(n).opt_token_and_node[0].unwrap();
            const line = lineOf(ast, ast.nodeMainToken(n));
            if (name_tok) |nt| {
                const is_string = ast.tokenSlice(nt).len > 0 and (ast.tokenSlice(nt)[0] == '"' or ast.tokenSlice(nt)[0] == '@');
                try out.append(a, .{ .file = file, .name = try a.dupe(u8, tokenName(ast, nt)), .kind = if (is_string) .named else .decl, .line = line });
            } else {
                try out.append(a, .{ .file = file, .name = "", .kind = .unnamed, .index = unnamed.*, .line = line });
                unnamed.* += 1;
            }
            continue;
        }
        // Tests inside `const X = struct { ... }`.
        if (depth < 4) {
            if (ast.fullVarDecl(n)) |vd| {
                if (vd.ast.init_node.unwrap()) |init| {
                    var buf: [2]Ast.Node.Index = undefined;
                    if (ast.fullContainerDecl(&buf, init)) |cd| try collect(a, ast, cd.ast.members, file, unnamed, out, depth + 1);
                }
            }
        }
    }
}

/// The tests declared in `src` (a file at project-relative path `file`).
pub fn scanSource(a: std.mem.Allocator, gpa: std.mem.Allocator, file: []const u8, src: [:0]const u8, out: *std.ArrayListUnmanaged(Test)) !void {
    var ast = try Ast.parse(gpa, src, .{});
    defer ast.deinit(gpa);
    var unnamed: u32 = 0;
    try collect(a, &ast, ast.rootDecls(), file, &unnamed, out, 0);
}

/// Every test in the project's `.zig` files (excluded folders, files over 2 MiB and files
/// without the word `test` are skipped), by file in path order. Blocking: run it on a worker thread.
pub fn scan(gpa: std.mem.Allocator, io: std.Io, dir: std.Io.Dir) !Index {
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();
    var tests: std.ArrayListUnmanaged(Test) = .empty;
    var paths: std.ArrayListUnmanaged([]const u8) = .empty;
    defer paths.deinit(gpa);
    var walker = try dir.walkSelectively(gpa);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        switch (entry.kind) {
            .directory => if (!project_mod.isExcludedName(entry.basename)) walker.enter(io, entry) catch {},
            .file => if (std.mem.endsWith(u8, entry.basename, ".zig")) {
                const p = try a.dupe(u8, entry.path);
                for (p) |*c| {
                    if (c.* == '\\') c.* = '/';
                }
                try paths.append(gpa, p);
            },
            else => {},
        }
    }
    std.mem.sort([]const u8, paths.items, {}, struct {
        fn less(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.lessThan(u8, x, y);
        }
    }.less);
    for (paths.items) |rel| {
        const src = dir.readFileAllocOptions(io, rel, gpa, .limited(2 * 1024 * 1024), .of(u8), 0) catch continue;
        defer gpa.free(src);
        if (std.mem.indexOf(u8, src, "test") == null) continue;
        scanSource(a, gpa, rel, src, &tests) catch continue;
    }
    return .{ .arena = arena, .tests = tests.items };
}

// ---- reading a run ---------------------------------------------------------

pub const Status = enum { unknown, running, passed, failed, skipped };

pub const Outcome = struct {
    /// The name as the report gives it.
    name: []u8,
    status: Status,
    /// What the test printed and why it failed (the stack trace, the leak report).
    detail: std.ArrayListUnmanaged(u8) = .empty,
};

pub const Summary = struct { pass: u32 = 0, skip: u32 = 0, fail: u32 = 0, total: u32 = 0 };

pub const Mode = enum {
    /// `zig test FILE`: a line per test, live.
    direct,
    /// `zig build test`: a summary and a block per failing test.
    build,
};

pub const Parser = struct {
    gpa: std.mem.Allocator,
    mode: Mode,
    outcomes: std.ArrayListUnmanaged(Outcome) = .empty,
    summary: ?Summary = null,
    /// The outcome the following lines describe.
    cur: ?usize = null,
    partial: std.ArrayListUnmanaged(u8) = .empty,

    pub fn init(gpa: std.mem.Allocator, mode: Mode) Parser {
        return .{ .gpa = gpa, .mode = mode };
    }

    pub fn deinit(self: *Parser) void {
        for (self.outcomes.items) |*o| {
            self.gpa.free(o.name);
            o.detail.deinit(self.gpa);
        }
        self.outcomes.deinit(self.gpa);
        self.partial.deinit(self.gpa);
    }

    /// Bytes of the report as they arrive (any chunking).
    pub fn feed(self: *Parser, bytes: []const u8) !void {
        try self.partial.appendSlice(self.gpa, bytes);
        while (std.mem.indexOfScalar(u8, self.partial.items, '\n')) |nl| {
            const text = try self.gpa.dupe(u8, std.mem.trimEnd(u8, self.partial.items[0..nl], "\r"));
            defer self.gpa.free(text);
            const rest = self.partial.items[nl + 1 ..];
            std.mem.copyForwards(u8, self.partial.items[0..rest.len], rest);
            self.partial.shrinkRetainingCapacity(rest.len);
            try self.line(text);
        }
    }

    /// The report ended: handle a last line without a newline; a test still running did not finish.
    pub fn finish(self: *Parser) !void {
        if (self.partial.items.len > 0) {
            const l = try self.gpa.dupe(u8, self.partial.items);
            defer self.gpa.free(l);
            self.partial.clearRetainingCapacity();
            try self.line(l);
        }
        for (self.outcomes.items) |*o| {
            if (o.status == .running) o.status = .failed;
        }
    }

    fn add(self: *Parser, name: []const u8, status: Status) !usize {
        const copy = try self.gpa.dupe(u8, name);
        errdefer self.gpa.free(copy);
        try self.outcomes.append(self.gpa, .{ .name = copy, .status = status });
        return self.outcomes.items.len - 1;
    }

    fn note(self: *Parser, text: []const u8) !void {
        const i = self.cur orelse return;
        const d = &self.outcomes.items[i].detail;
        if (d.items.len > 0) try d.append(self.gpa, '\n');
        try d.appendSlice(self.gpa, text);
    }

    fn line(self: *Parser, l: []const u8) !void {
        switch (self.mode) {
            .direct => try self.directLine(l),
            .build => try self.buildLine(l),
        }
    }

    /// `N/M name...status`: the position of "name" and the text after the `...`.
    fn header(l: []const u8) ?struct { name: []const u8, rest: []const u8 } {
        var i: usize = 0;
        while (i < l.len and std.ascii.isDigit(l[i])) i += 1;
        if (i == 0 or i >= l.len or l[i] != '/') return null;
        i += 1;
        const d2 = i;
        while (i < l.len and std.ascii.isDigit(l[i])) i += 1;
        if (i == d2 or i >= l.len or l[i] != ' ') return null;
        const body = l[i + 1 ..];
        const dots = std.mem.indexOf(u8, body, "...") orelse return null;
        return .{ .name = body[0..dots], .rest = body[dots + 3 ..] };
    }

    fn statusOf(text: []const u8) ?Status {
        if (std.mem.eql(u8, text, "OK")) return .passed;
        if (std.mem.eql(u8, text, "SKIP")) return .skipped;
        if (std.mem.startsWith(u8, text, "FAIL")) return .failed;
        return null;
    }

    fn directLine(self: *Parser, l: []const u8) !void {
        if (header(l)) |h| {
            const status = statusOf(h.rest) orelse Status.running;
            const i = try self.add(h.name, status);
            self.cur = i;
            if (status == .failed) try self.note(h.rest);
            if (status == .running and h.rest.len > 0) try self.note(h.rest);
            return;
        }
        if (parseSummaryDirect(l)) |s| {
            self.summary = s;
            self.cur = null;
            return;
        }
        const i = self.cur orelse return;
        const o = &self.outcomes.items[i];
        if (o.status == .running) {
            if (statusOf(l)) |s| {
                o.status = s;
                if (s == .failed) try self.note(l);
                return;
            }
            try self.note(l);
            return;
        }
        // After a pass: a leak report follows the "OK" of the test that leaked.
        if (std.mem.indexOf(u8, l, "leaked") != null and std.mem.indexOf(u8, l, "(err)") != null) {
            if (o.status == .passed) o.status = .failed;
            try self.note(l);
            return;
        }
        if (o.status == .failed) {
            if (std.mem.startsWith(u8, l, "error: the following test command failed")) {
                self.cur = null;
                return;
            }
            if (l.len > 0) try self.note(l);
        }
    }

    /// `6 passed; 1 skipped; 1 failed.`
    fn parseSummaryDirect(l: []const u8) ?Summary {
        if (std.mem.indexOf(u8, l, " passed; ") == null or !std.mem.endsWith(u8, l, "failed.")) return null;
        var s: Summary = .{};
        var it = std.mem.splitSequence(u8, std.mem.trimEnd(u8, l, "."), "; ");
        while (it.next()) |part| {
            const sp = std.mem.indexOfScalar(u8, part, ' ') orelse continue;
            const n = std.fmt.parseInt(u32, part[0..sp], 10) catch continue;
            if (std.mem.endsWith(u8, part, "passed")) s.pass = n;
            if (std.mem.endsWith(u8, part, "skipped")) s.skip = n;
            if (std.mem.endsWith(u8, part, "failed")) s.fail = n;
        }
        s.total = s.pass + s.skip + s.fail;
        return s;
    }

    /// `run test 6 pass, 1 skip, 1 fail (8 total)` (also `crash`, `leaks`).
    pub fn parseSummaryBuild(l: []const u8) ?Summary {
        const at = std.mem.indexOf(u8, l, "run test ") orelse return null;
        var s: Summary = .{};
        var any = false;
        var it = std.mem.tokenizeAny(u8, l[at + 9 ..], ",;()");
        while (it.next()) |part0| {
            const part = std.mem.trim(u8, part0, " ");
            const sp = std.mem.indexOfScalar(u8, part, ' ') orelse continue;
            const n = std.fmt.parseInt(u32, part[0..sp], 10) catch continue;
            const word = std.mem.trim(u8, part[sp + 1 ..], " ");
            if (std.mem.startsWith(u8, word, "pass")) s.pass = n else if (std.mem.startsWith(u8, word, "skip")) s.skip = n else if (std.mem.startsWith(u8, word, "fail") or std.mem.startsWith(u8, word, "crash")) s.fail += n else if (std.mem.startsWith(u8, word, "total")) s.total = n else continue;
            any = true;
        }
        return if (any) s else null;
    }

    /// `error: 'main.test.this one fails' failed:` (also `leaked`, `terminated`, ...) and the lines under it.
    fn buildLine(self: *Parser, l: []const u8) !void {
        if (parseSummaryBuild(l)) |s| {
            self.summary = s;
            return;
        }
        if (std.mem.startsWith(u8, l, "error: '")) {
            const close = std.mem.lastIndexOf(u8, l, "' ") orelse {
                self.cur = null;
                return;
            };
            if (close > 8) {
                const name = l[8..close];
                const why = std.mem.trim(u8, l[close + 2 ..], " :");
                // The same test may be reported twice (failed and leaked): one outcome.
                for (self.outcomes.items, 0..) |o, i| {
                    if (std.mem.eql(u8, o.name, name)) {
                        self.cur = i;
                        try self.note(why);
                        return;
                    }
                }
                const i = try self.add(name, .failed);
                self.cur = i;
                try self.note(why);
                return;
            }
        }
        const i = self.cur orelse return;
        _ = i;
        if (std.mem.startsWith(u8, l, "       ")) {
            try self.note(l[7..]);
        } else {
            self.cur = null; // the block ended
        }
    }
};

// ---- tests -----------------------------------------------------------------

const testing = std.testing;

test "tests are found with their names, kinds, lines and unnamed numbering, including in containers" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var list: std.ArrayListUnmanaged(Test) = .empty;
    try scanSource(arena.allocator(), testing.allocator, "src/main.zig",
        \\const std = @import("std");
        \\test "adds numbers" {}
        \\test { _ = std; }
        \\fn helper() void {}
        \\test helper {}
        \\const Group = struct {
        \\    test "inside a struct" {}
        \\};
        \\test {}
        \\test "with \"quotes\"" {}
    , &list);
    try testing.expectEqual(@as(usize, 6), list.items.len);
    try testing.expectEqualStrings("adds numbers", list.items[0].name);
    try testing.expect(list.items[0].kind == .named and list.items[0].line == 2);
    try testing.expect(list.items[1].kind == .unnamed and list.items[1].index == 0);
    try testing.expect(list.items[2].kind == .decl and std.mem.eql(u8, list.items[2].name, "helper"));
    try testing.expectEqualStrings("inside a struct", list.items[3].name);
    try testing.expect(list.items[4].kind == .unnamed and list.items[4].index == 1);

    const a = testing.allocator;
    const n0 = try fullName(a, list.items[0]);
    defer a.free(n0);
    try testing.expectEqualStrings("main.test.adds numbers", n0);
    const n2 = try fullName(a, list.items[2]);
    defer a.free(n2);
    try testing.expectEqualStrings("main.decltest.helper", n2);
}

test "a reported name matches its test by file name, with module prefixes and nested containers" {
    const t: Test = .{ .file = "src/ide/proj_settings.zig", .name = "loads it", .kind = .named, .line = 1 };
    try testing.expect(matches(t, "ide.proj_settings.test.loads it"));
    try testing.expect(matches(t, "proj_settings.test.loads it"));
    try testing.expect(matches(t, "ide.proj_settings.Doc.test.loads it"));
    try testing.expect(!matches(t, "ide.other.test.loads it"));
    try testing.expect(!matches(t, "ide.proj_settings.test.loads that"));
    const u: Test = .{ .file = "src/main.zig", .name = "", .kind = .unnamed, .index = 0, .line = 1 };
    try testing.expect(matches(u, "main.test_0"));
    try testing.expect(!matches(u, "main.test_1"));
}

const direct_report =
    "1/8 main.test.adds numbers...OK\n" ++
    "2/8 main.test.this one fails...expected 4, found 3\n" ++
    "FAIL (TestExpectedEqual)\n" ++
    "/tmp/tproj/src/main.zig:4:25: 0x1251ca2 in test.this one fails (main.zig)\n" ++
    "3/8 main.test.skipped one...SKIP\n" ++
    "4/8 main.test.leaks memory...OK\n" ++
    "[SafeAllocator] (err): leaked [addr: 7f686f8ea010, len: 10 (0xa) align: 1] allocated at: \n" ++
    "/tmp/tproj/src/main.zig:6:58: 0x1250d36 in test.leaks memory (main.zig)\n" ++
    "\n" ++
    "5/8 main.test_0...OK\n" ++
    "6/8 main.decltest.helper...OK\n" ++
    "7/8 util.test.util add...OK\n" ++
    "8/8 util.test.prints something...hello from test\n" ++
    "OK\n" ++
    "6 passed; 1 skipped; 1 failed.\n" ++
    "1 errors were logged.\n";

test "a direct `zig test` report gives live statuses, failure and leak details, and the summary" {
    var p = Parser.init(testing.allocator, .direct);
    defer p.deinit();
    // Arrives in odd pieces.
    var i: usize = 0;
    while (i < direct_report.len) : (i += 13) try p.feed(direct_report[i..@min(i + 13, direct_report.len)]);
    try p.finish();
    try testing.expectEqual(@as(usize, 8), p.outcomes.items.len);
    const o = p.outcomes.items;
    try testing.expect(o[0].status == .passed);
    try testing.expect(o[1].status == .failed);
    try testing.expect(std.mem.indexOf(u8, o[1].detail.items, "expected 4, found 3") != null);
    try testing.expect(std.mem.indexOf(u8, o[1].detail.items, "FAIL (TestExpectedEqual)") != null);
    try testing.expect(o[2].status == .skipped);
    try testing.expect(o[3].status == .failed); // printed OK, then reported a leak
    try testing.expect(std.mem.indexOf(u8, o[3].detail.items, "leaked") != null);
    try testing.expect(o[4].status == .passed and std.mem.eql(u8, o[4].name, "main.test_0"));
    try testing.expect(o[7].status == .passed); // its output came before the OK
    try testing.expect(std.mem.indexOf(u8, o[7].detail.items, "hello from test") != null);
    try testing.expectEqual(@as(u32, 6), p.summary.?.pass);
    try testing.expectEqual(@as(u32, 1), p.summary.?.skip);
    try testing.expectEqual(@as(u32, 1), p.summary.?.fail);
}

test "a test that never finished (the program crashed) counts as failed" {
    var p = Parser.init(testing.allocator, .direct);
    defer p.deinit();
    try p.feed("1/2 a.test.fine...OK\n2/2 a.test.crashes...thread 1 panic: boom\n");
    try p.finish();
    try testing.expect(p.outcomes.items[0].status == .passed);
    try testing.expect(p.outcomes.items[1].status == .failed);
}

const build_report =
    "test\n" ++
    "+- run test 6 pass, 1 skip, 1 fail (8 total); 1 leaks\n" ++
    "hello from test\n" ++
    "error: 'main.test.this one fails' failed:\n" ++
    "       expected 4, found 3\n" ++
    "       /tmp/tproj/src/main.zig:4:25: 0x1251ca2 in test.this one fails (main.zig)\n" ++
    "error: 'main.test.leaks memory' leaked 1 allocations:\n" ++
    "       [SafeAllocator] (err): leaked [addr: 7fe2a0e0e010, len: 10 (0xa) align: 1] allocated at: \n" ++
    "failed command: ./.zig-cache/o/2077/test --listen=-\n" ++
    "\n" ++
    "Build Summary: 1/3 steps succeeded (1 failed); 6/8 tests passed (1 skipped, 1 failed)\n";

test "a `zig build test` report gives the failing tests with their blocks and the summary" {
    var p = Parser.init(testing.allocator, .build);
    defer p.deinit();
    try p.feed(build_report);
    try p.finish();
    try testing.expectEqual(@as(usize, 2), p.outcomes.items.len);
    try testing.expectEqualStrings("main.test.this one fails", p.outcomes.items[0].name);
    try testing.expect(p.outcomes.items[0].status == .failed);
    try testing.expect(std.mem.indexOf(u8, p.outcomes.items[0].detail.items, "expected 4, found 3") != null);
    try testing.expectEqualStrings("main.test.leaks memory", p.outcomes.items[1].name);
    try testing.expect(std.mem.indexOf(u8, p.outcomes.items[1].detail.items, "leaked") != null);
    try testing.expectEqual(@as(u32, 6), p.summary.?.pass);
    try testing.expectEqual(@as(u32, 8), p.summary.?.total);
    try testing.expectEqual(@as(u32, 1), p.summary.?.fail);
}

test "build summary lines: crashes count as failures, no summary means the build did not get to run tests" {
    try testing.expectEqual(@as(u32, 1), Parser.parseSummaryBuild("+- run test 731 pass, 1 skip, 1 crash (733 total)").?.fail);
    try testing.expect(Parser.parseSummaryBuild("+- compile test debug native 1 errors") == null);
}

test "scan finds tests in a project's files and skips excluded folders" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDirPath(testing.io, "src");
    try tmp.dir.createDirPath(testing.io, "zig-out");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "src/a.zig", .data = "test \"one\" {}\ntest \"two\" {}\n" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "src/none.zig", .data = "pub fn f() void {}\n" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "zig-out/b.zig", .data = "test \"hidden\" {}\n" });
    var idx = try scan(testing.allocator, testing.io, tmp.dir);
    defer idx.deinit();
    try testing.expectEqual(@as(usize, 2), idx.tests.len);
    try testing.expectEqualStrings("src/a.zig", idx.tests[0].file);
    const files = try idx.files(testing.allocator);
    defer testing.allocator.free(files);
    try testing.expectEqual(@as(usize, 1), files.len);
}
