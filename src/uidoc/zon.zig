//! A small ZON reader and writer for UI documents (design doc section 13).
//!
//! `std.zon` parses into a type known at compile time. UI documents are
//! open-ended (any widget, any prop), so this module reads ZON into a dynamic
//! `Value` tree instead, and writes one back. It handles the subset UI files
//! need: struct and tuple literals, strings, integers (decimal, hex, octal,
//! binary, underscores), floats, `true`/`false`/`null`, enum literals
//! (`.primary`), and character literals (read as integers). Comments are
//! skipped. Errors carry a line and column.
//!
//! Values are immutable and allocated from an arena you supply; "editing" makes a
//! modified copy (see `withField`), which is what undo history wants anyway.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Field = struct { name: []const u8, value: Value };

pub const Value = union(enum) {
    /// `null`
    none,
    bool: bool,
    int: i64,
    float: f64,
    string: []const u8,
    /// An enum literal such as `.primary`.
    tag: []const u8,
    /// `.{ .a = 1, .b = 2 }`; also what an empty `.{}` reads as.
    record: []const Field,
    /// `.{ 1, 2, 3 }`
    list: []const Value,

    pub fn field(self: Value, name: []const u8) ?Value {
        return switch (self) {
            .record => |fs| for (fs) |f| {
                if (std.mem.eql(u8, f.name, name)) break f.value;
            } else null,
            else => null,
        };
    }

    /// Elements of a list (an empty record counts as an empty list).
    pub fn items(self: Value) ?[]const Value {
        return switch (self) {
            .list => |l| l,
            .record => |r| if (r.len == 0) &.{} else null,
            else => null,
        };
    }

    pub fn fields(self: Value) ?[]const Field {
        return switch (self) {
            .record => |r| r,
            .list => |l| if (l.len == 0) &.{} else null,
            else => null,
        };
    }

    pub fn eql(a: Value, b: Value) bool {
        if (std.meta.activeTag(a) != std.meta.activeTag(b)) {
            // An empty record and an empty list are the same literal.
            const af = a.fields();
            const bf = b.fields();
            return af != null and bf != null and af.?.len == 0 and bf.?.len == 0;
        }
        return switch (a) {
            .none => true,
            .bool => |x| x == b.bool,
            .int => |x| x == b.int,
            .float => |x| x == b.float or (std.math.isNan(x) and std.math.isNan(b.float)),
            .string => |x| std.mem.eql(u8, x, b.string),
            .tag => |x| std.mem.eql(u8, x, b.tag),
            .record => |x| blk: {
                if (x.len != b.record.len) break :blk false;
                for (x, b.record) |l, r| {
                    if (!std.mem.eql(u8, l.name, r.name) or !l.value.eql(r.value)) break :blk false;
                }
                break :blk true;
            },
            .list => |x| blk: {
                if (x.len != b.list.len) break :blk false;
                for (x, b.list) |l, r| if (!l.eql(r)) break :blk false;
                break :blk true;
            },
        };
    }
};

/// A copy of `rec` (an empty record if `rec` is not a record) with `name` set
/// to `value`, replacing an existing field in place or appending.
pub fn withField(arena: Allocator, rec: Value, name: []const u8, value: Value) Allocator.Error!Value {
    const old: []const Field = rec.fields() orelse &.{};
    for (old, 0..) |f, i| {
        if (!std.mem.eql(u8, f.name, name)) continue;
        const out = try arena.dupe(Field, old);
        out[i] = .{ .name = f.name, .value = value };
        return .{ .record = out };
    }
    const out = try arena.alloc(Field, old.len + 1);
    @memcpy(out[0..old.len], old);
    out[old.len] = .{ .name = try arena.dupe(u8, name), .value = value };
    return .{ .record = out };
}

/// A copy of `rec` without `name` (unchanged if it was absent).
pub fn withoutField(arena: Allocator, rec: Value, name: []const u8) Allocator.Error!Value {
    const old: []const Field = rec.fields() orelse &.{};
    var keep: usize = 0;
    for (old) |f| {
        if (!std.mem.eql(u8, f.name, name)) keep += 1;
    }
    if (keep == old.len) return rec;
    const out = try arena.alloc(Field, keep);
    var i: usize = 0;
    for (old) |f| {
        if (std.mem.eql(u8, f.name, name)) continue;
        out[i] = f;
        i += 1;
    }
    return .{ .record = out };
}

// ---- reading -----------------------------------------------------------------

pub const Diag = struct {
    line: u32 = 0,
    col: u32 = 0,
    message: []const u8 = "",
};

pub const ParseError = error{ Syntax, OutOfMemory };

const Parser = struct {
    src: []const u8,
    pos: usize = 0,
    arena: Allocator,
    diag: ?*Diag,

    fn fail(self: *Parser, msg: []const u8) ParseError {
        if (self.diag) |d| {
            var line: u32 = 1;
            var col: u32 = 1;
            for (self.src[0..@min(self.pos, self.src.len)]) |c| {
                if (c == '\n') {
                    line += 1;
                    col = 1;
                } else col += 1;
            }
            d.* = .{ .line = line, .col = col, .message = msg };
        }
        return error.Syntax;
    }

    fn peek(self: *Parser) ?u8 {
        return if (self.pos < self.src.len) self.src[self.pos] else null;
    }

    fn skip(self: *Parser) void {
        while (self.pos < self.src.len) {
            const c = self.src[self.pos];
            if (c == ' ' or c == '\t' or c == '\n' or c == '\r') {
                self.pos += 1;
            } else if (c == '/' and self.pos + 1 < self.src.len and self.src[self.pos + 1] == '/') {
                while (self.pos < self.src.len and self.src[self.pos] != '\n') self.pos += 1;
            } else break;
        }
    }

    fn isIdentChar(c: u8) bool {
        return std.ascii.isAlphanumeric(c) or c == '_';
    }

    fn ident(self: *Parser) ParseError![]const u8 {
        if (self.peek() == '@') {
            // @"quoted name"
            self.pos += 1;
            if (self.peek() != '"') return self.fail("expected a quoted name after @");
            return self.string();
        }
        const start = self.pos;
        while (self.pos < self.src.len and isIdentChar(self.src[self.pos])) self.pos += 1;
        if (self.pos == start) return self.fail("expected a name");
        return self.src[start..self.pos];
    }

    fn string(self: *Parser) ParseError![]const u8 {
        const start = self.pos;
        self.pos += 1; // opening quote
        while (self.pos < self.src.len) : (self.pos += 1) {
            switch (self.src[self.pos]) {
                '\\' => self.pos += 1,
                '"' => {
                    self.pos += 1;
                    return std.zig.string_literal.parseAlloc(self.arena, self.src[start..self.pos]) catch |e| switch (e) {
                        error.OutOfMemory => error.OutOfMemory,
                        else => self.fail("bad string escape"),
                    };
                },
                '\n' => break,
                else => {},
            }
        }
        self.pos = start;
        return self.fail("unterminated string");
    }

    fn number(self: *Parser, negative: bool) ParseError!Value {
        const start = self.pos;
        while (self.pos < self.src.len) {
            const c = self.src[self.pos];
            const exp_sign = (c == '+' or c == '-') and self.pos > start and
                (self.src[self.pos - 1] == 'e' or self.src[self.pos - 1] == 'E') and
                !(self.pos > start + 1 and self.src[start] == '0' and (self.src[start + 1] == 'x' or self.src[start + 1] == 'X'));
            if (std.ascii.isAlphanumeric(c) or c == '_' or c == '.' or exp_sign) self.pos += 1 else break;
        }
        const raw = self.src[start..self.pos];
        const clean = try self.arena.alloc(u8, raw.len);
        var n: usize = 0;
        for (raw) |c| {
            if (c != '_') {
                clean[n] = c;
                n += 1;
            }
        }
        const text = clean[0..n];
        const is_float = std.mem.indexOfAny(u8, text, ".") != null or
            (!(text.len > 1 and text[0] == '0' and (text[1] == 'x' or text[1] == 'X')) and std.mem.indexOfAny(u8, text, "eE") != null);
        if (is_float) {
            const f = std.fmt.parseFloat(f64, text) catch {
                self.pos = start;
                return self.fail("bad number");
            };
            return .{ .float = if (negative) -f else f };
        }
        const mag = std.fmt.parseInt(i128, text, 0) catch {
            self.pos = start;
            return self.fail("bad number");
        };
        const v = if (negative) -mag else mag;
        const narrowed = std.math.cast(i64, v) orelse {
            self.pos = start;
            return self.fail("integer out of range");
        };
        return .{ .int = narrowed };
    }

    fn char(self: *Parser) ParseError!Value {
        const start = self.pos;
        self.pos += 1;
        while (self.pos < self.src.len and self.src[self.pos] != '\'') : (self.pos += 1) {
            if (self.src[self.pos] == '\\') self.pos += 1;
            if (self.pos < self.src.len and self.src[self.pos] == '\n') break;
        }
        if (self.peek() != '\'') {
            self.pos = start;
            return self.fail("unterminated character literal");
        }
        self.pos += 1;
        const body = self.src[start + 1 .. self.pos - 1];
        const lit = switch (std.zig.parseCharLiteral(self.src[start..self.pos])) {
            .success => |cp| cp,
            .failure => {
                self.pos = start;
                return self.fail("bad character literal");
            },
        };
        _ = body;
        return .{ .int = lit };
    }

    fn value(self: *Parser) ParseError!Value {
        self.skip();
        const c = self.peek() orelse return self.fail("expected a value");
        switch (c) {
            '.' => {
                self.pos += 1;
                if (self.peek() == '{') return self.container();
                return .{ .tag = try self.ident() };
            },
            '"' => return .{ .string = try self.string() },
            '\'' => return self.char(),
            '-' => {
                self.pos += 1;
                self.skip();
                if (self.peek()) |d| {
                    if (std.ascii.isDigit(d)) return self.number(true);
                }
                const word = try self.ident();
                if (std.mem.eql(u8, word, "inf")) return .{ .float = -std.math.inf(f64) };
                self.pos -= word.len;
                return self.fail("expected a number after -");
            },
            '0'...'9' => return self.number(false),
            else => {
                const start = self.pos;
                const word = try self.ident();
                if (std.mem.eql(u8, word, "true")) return .{ .bool = true };
                if (std.mem.eql(u8, word, "false")) return .{ .bool = false };
                if (std.mem.eql(u8, word, "null")) return .none;
                if (std.mem.eql(u8, word, "inf")) return .{ .float = std.math.inf(f64) };
                if (std.mem.eql(u8, word, "nan")) return .{ .float = std.math.nan(f64) };
                self.pos = start;
                return self.fail("unexpected name (enum values are written .like_this)");
            },
        }
    }

    fn container(self: *Parser) ParseError!Value {
        self.pos += 1; // '{'
        self.skip();
        if (self.peek() == '}') {
            self.pos += 1;
            return .{ .record = &.{} };
        }
        // `.name =` starts a record; anything else starts a list.
        const is_record = blk: {
            if (self.peek() != '.') break :blk false;
            var p = self.pos + 1;
            if (p < self.src.len and self.src[p] == '@') break :blk true;
            const s = p;
            while (p < self.src.len and isIdentChar(self.src[p])) p += 1;
            if (p == s) break :blk false;
            while (p < self.src.len and (self.src[p] == ' ' or self.src[p] == '\t' or self.src[p] == '\n' or self.src[p] == '\r')) p += 1;
            break :blk p < self.src.len and self.src[p] == '=';
        };
        if (is_record) {
            var list: std.ArrayListUnmanaged(Field) = .empty;
            while (true) {
                self.skip();
                if (self.peek() == '}') break;
                if (self.peek() != '.') return self.fail("expected .field = value");
                self.pos += 1;
                const name = try self.ident();
                self.skip();
                if (self.peek() != '=') return self.fail("expected = after field name");
                self.pos += 1;
                for (list.items) |f| if (std.mem.eql(u8, f.name, name)) return self.fail("duplicate field");
                const v = try self.value();
                try list.append(self.arena, .{ .name = name, .value = v });
                self.skip();
                if (self.peek() == ',') {
                    self.pos += 1;
                    continue;
                }
                if (self.peek() == '}') break;
                return self.fail("expected , or }");
            }
            self.pos += 1;
            return .{ .record = list.items };
        }
        var list: std.ArrayListUnmanaged(Value) = .empty;
        while (true) {
            self.skip();
            if (self.peek() == '}') break;
            const v = try self.value();
            try list.append(self.arena, v);
            self.skip();
            if (self.peek() == ',') {
                self.pos += 1;
                continue;
            }
            if (self.peek() == '}') break;
            return self.fail("expected , or }");
        }
        self.pos += 1;
        return .{ .list = list.items };
    }
};

/// Parse one ZON value. Everything is allocated from `arena`.
pub fn parse(arena: Allocator, source: []const u8, diag: ?*Diag) ParseError!Value {
    var p: Parser = .{ .src = source, .arena = arena, .diag = diag };
    const v = try p.value();
    p.skip();
    if (p.pos != source.len) return p.fail("unexpected text after the value");
    return v;
}

// ---- writing -----------------------------------------------------------------

fn isContainer(v: Value) bool {
    return switch (v) {
        .record, .list => true,
        else => false,
    };
}

fn needsQuote(name: []const u8) bool {
    return !std.zig.isValidId(name);
}

fn writeName(out: *std.ArrayListUnmanaged(u8), gpa: Allocator, name: []const u8) Allocator.Error!void {
    if (needsQuote(name)) {
        try out.appendSlice(gpa, "@");
        try writeString(out, gpa, name);
    } else try out.appendSlice(gpa, name);
}

fn writeString(out: *std.ArrayListUnmanaged(u8), gpa: Allocator, s: []const u8) Allocator.Error!void {
    try out.append(gpa, '"');
    for (s) |c| switch (c) {
        '"' => try out.appendSlice(gpa, "\\\""),
        '\\' => try out.appendSlice(gpa, "\\\\"),
        '\n' => try out.appendSlice(gpa, "\\n"),
        '\r' => try out.appendSlice(gpa, "\\r"),
        '\t' => try out.appendSlice(gpa, "\\t"),
        0...8, 11, 12, 14...31, 127 => {
            var b: [4]u8 = undefined;
            try out.appendSlice(gpa, std.fmt.bufPrint(&b, "\\x{x:0>2}", .{c}) catch unreachable);
        },
        else => try out.append(gpa, c),
    };
    try out.append(gpa, '"');
}

fn writeIndent(out: *std.ArrayListUnmanaged(u8), gpa: Allocator, depth: usize) Allocator.Error!void {
    try out.appendNTimes(gpa, ' ', depth * 4);
}

fn writeValue(out: *std.ArrayListUnmanaged(u8), gpa: Allocator, v: Value, depth: usize) Allocator.Error!void {
    var buf: [64]u8 = undefined;
    switch (v) {
        .none => try out.appendSlice(gpa, "null"),
        .bool => |b| try out.appendSlice(gpa, if (b) "true" else "false"),
        .int => |i| try out.appendSlice(gpa, std.fmt.bufPrint(&buf, "{d}", .{i}) catch unreachable),
        .float => |f| {
            if (std.math.isNan(f)) return out.appendSlice(gpa, "nan");
            if (std.math.isInf(f)) return out.appendSlice(gpa, if (f < 0) "-inf" else "inf");
            const s = std.fmt.bufPrint(&buf, "{d}", .{f}) catch unreachable;
            try out.appendSlice(gpa, s);
            // Keep it a float when read back.
            if (std.mem.indexOfAny(u8, s, ".eE") == null) try out.appendSlice(gpa, ".0");
        },
        .string => |s| try writeString(out, gpa, s),
        .tag => |t| {
            try out.append(gpa, '.');
            try writeName(out, gpa, t);
        },
        .record => |fs| {
            if (fs.len == 0) return out.appendSlice(gpa, ".{}");
            var inline_ok = fs.len <= 3;
            for (fs) |f| inline_ok = inline_ok and !isContainer(f.value);
            if (inline_ok) {
                try out.appendSlice(gpa, ".{ ");
                for (fs, 0..) |f, i| {
                    if (i > 0) try out.appendSlice(gpa, ", ");
                    try out.append(gpa, '.');
                    try writeName(out, gpa, f.name);
                    try out.appendSlice(gpa, " = ");
                    try writeValue(out, gpa, f.value, depth + 1);
                }
                try out.appendSlice(gpa, " }");
                return;
            }
            try out.appendSlice(gpa, ".{\n");
            for (fs) |f| {
                try writeIndent(out, gpa, depth + 1);
                try out.append(gpa, '.');
                try writeName(out, gpa, f.name);
                try out.appendSlice(gpa, " = ");
                try writeValue(out, gpa, f.value, depth + 1);
                try out.appendSlice(gpa, ",\n");
            }
            try writeIndent(out, gpa, depth);
            try out.append(gpa, '}');
        },
        .list => |items| {
            if (items.len == 0) return out.appendSlice(gpa, ".{}");
            var inline_ok = items.len <= 4;
            for (items) |x| inline_ok = inline_ok and !isContainer(x);
            if (inline_ok) {
                try out.appendSlice(gpa, ".{ ");
                for (items, 0..) |x, i| {
                    if (i > 0) try out.appendSlice(gpa, ", ");
                    try writeValue(out, gpa, x, depth + 1);
                }
                try out.appendSlice(gpa, " }");
                return;
            }
            try out.appendSlice(gpa, ".{\n");
            for (items) |x| {
                try writeIndent(out, gpa, depth + 1);
                try writeValue(out, gpa, x, depth + 1);
                try out.appendSlice(gpa, ",\n");
            }
            try writeIndent(out, gpa, depth);
            try out.append(gpa, '}');
        },
    }
}

/// ZON text for `v`, owned by the caller (free with `gpa`).
pub fn render(gpa: Allocator, v: Value) Allocator.Error![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(gpa);
    try writeValue(&out, gpa, v, 0);
    return out.toOwnedSlice(gpa);
}

// ---- tests -----------------------------------------------------------------

const testing = std.testing;

fn parseTest(arena: Allocator, src: []const u8) !Value {
    return parse(arena, src, null);
}

test "scalars" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqual(@as(i64, 42), (try parseTest(a, "42")).int);
    try testing.expectEqual(@as(i64, -7), (try parseTest(a, "-7")).int);
    try testing.expectEqual(@as(i64, 255), (try parseTest(a, "0xFF")).int);
    try testing.expectEqual(@as(i64, 5), (try parseTest(a, "0b101")).int);
    try testing.expectEqual(@as(i64, 1_000_000), (try parseTest(a, "1_000_000")).int);
    try testing.expectEqual(@as(f64, 1.5), (try parseTest(a, "1.5")).float);
    try testing.expectEqual(@as(f64, -2000), (try parseTest(a, "-2e3")).float);
    try testing.expectEqual(@as(f64, 0.025), (try parseTest(a, "2.5e-2")).float);
    try testing.expectEqual(@as(i64, 'a'), (try parseTest(a, "'a'")).int);
    try testing.expect((try parseTest(a, "true")).bool);
    try testing.expect(!(try parseTest(a, "false")).bool);
    try testing.expect((try parseTest(a, "null")) == .none);
    try testing.expectEqualStrings("primary", (try parseTest(a, ".primary")).tag);
    try testing.expectEqualStrings("a\"b\\c\nd", (try parseTest(a, "\"a\\\"b\\\\c\\nd\"")).string);
    try testing.expectEqualStrings("é", (try parseTest(a, "\"\\u{e9}\"")).string);
    try testing.expect(std.math.isInf((try parseTest(a, "inf")).float));
    try testing.expect(std.math.isNan((try parseTest(a, "nan")).float));
}

test "records, lists, comments, and trailing commas" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const v = try parseTest(a,
        \\// a document
        \\.{
        \\    .name = "x", // trailing comment
        \\    .size = .{ 1, 2, 3, },
        \\    .nested = .{ .on = true, .@"odd name" = null },
        \\    .empty = .{},
        \\}
    );
    try testing.expectEqualStrings("x", v.field("name").?.string);
    try testing.expectEqual(@as(usize, 3), v.field("size").?.items().?.len);
    try testing.expect(v.field("nested").?.field("on").?.bool);
    try testing.expect(v.field("nested").?.field("odd name").? == .none);
    try testing.expectEqual(@as(usize, 0), v.field("empty").?.items().?.len);
    try testing.expect(v.field("missing") == null);
    try testing.expect(v.field("name").?.field("x") == null);
}

fn errAt(src: []const u8) !Diag {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var d: Diag = .{};
    try testing.expectError(error.Syntax, parse(arena.allocator(), src, &d));
    return d;
}

test "errors report a line and column" {
    var d = try errAt(".{\n    .a = 1,\n    .b = ,\n}");
    try testing.expectEqual(@as(u32, 3), d.line);
    try testing.expectEqual(@as(u32, 10), d.col);
    d = try errAt(".{ .a = 1 .b = 2 }");
    try testing.expectEqualStrings("expected , or }", d.message);
    d = try errAt(".{ .a = 1, .a = 2 }");
    try testing.expectEqualStrings("duplicate field", d.message);
    d = try errAt("\"open");
    try testing.expectEqualStrings("unterminated string", d.message);
    d = try errAt("hello");
    try testing.expect(std.mem.indexOf(u8, d.message, "enum") != null);
    d = try errAt("1 2");
    try testing.expectEqualStrings("unexpected text after the value", d.message);
    d = try errAt("99999999999999999999");
    try testing.expectEqualStrings("integer out of range", d.message);
    d = try errAt(".{ .a = 1");
    try testing.expect(d.message.len > 0);
}

test "render then parse gives back the same value" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const src =
        \\.{
        \\    .version = 1,
        \\    .scale = 2.0,
        \\    .name = "line\none \"quoted\" \\ tab\t",
        \\    .kind = .primary,
        \\    .off = null,
        \\    .style = .{ .grow = 1, .direction = .column },
        \\    .children = .{
        \\        .{ .type = "label", .props = .{ .text = "hi" } },
        \\        .{ .type = "button", .props = .{ .text = "ok" }, .tags = .{ 1, 2, 3 } },
        \\    },
        \\    .@"odd name" = true,
        \\    .ctl = "\x01",
        \\}
    ;
    const v = try parseTest(a, src);
    const text = try render(testing.allocator, v);
    defer testing.allocator.free(text);
    const again = try parseTest(a, text);
    try testing.expect(v.eql(again));
    // A float stays a float, an int stays an int.
    try testing.expect(again.field("scale").? == .float);
    try testing.expect(again.field("version").? == .int);
    // Rendering is stable.
    const text2 = try render(testing.allocator, again);
    defer testing.allocator.free(text2);
    try testing.expectEqualStrings(text, text2);
}

test "small records render on one line, nested ones are indented" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const small = try render(testing.allocator, try parseTest(a, ".{ .a = 1, .b = .x }"));
    defer testing.allocator.free(small);
    try testing.expectEqualStrings(".{ .a = 1, .b = .x }", small);
    const big = try render(testing.allocator, try parseTest(a, ".{ .a = .{ .b = 1 } }"));
    defer testing.allocator.free(big);
    try testing.expectEqualStrings(".{\n    .a = .{ .b = 1 },\n}", big);
}

test "withField replaces in place or appends; withoutField removes" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const base = try parseTest(a, ".{ .a = 1, .b = 2 }");
    const r1 = try withField(a, base, "a", .{ .int = 9 });
    try testing.expectEqual(@as(i64, 9), r1.field("a").?.int);
    try testing.expectEqual(@as(i64, 1), base.field("a").?.int); // the original is untouched
    const r2 = try withField(a, base, "c", .{ .bool = true });
    try testing.expectEqual(@as(usize, 3), r2.record.len);
    const r3 = try withoutField(a, r2, "b");
    try testing.expect(r3.field("b") == null and r3.field("c") != null);
    const r4 = try withField(a, .none, "x", .{ .int = 1 });
    try testing.expectEqual(@as(i64, 1), r4.field("x").?.int);
    try testing.expect((try parseTest(a, ".{}")).eql(.{ .list = &.{} }));
}
