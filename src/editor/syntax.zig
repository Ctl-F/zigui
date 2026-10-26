//! Line-oriented syntax lexing: tokens for coloring, not for parsing.
//!
//! A `Language` is data (comment and string syntax, a word table, a few
//! flags). `lexLine(lang, state, line, spans)` turns one line into colored
//! spans and returns the state at the end of the line, which is the state the
//! next line starts in. State is a small integer (`u32`) that captures only
//! what crosses a line break: being inside a block comment (with nesting
//! depth) or a fenced code block. Everything else (strings, comments to end of
//! line) ends with the line, so most lines are lexed independently.
//!
//! This is deliberately approximate, like a TextMate grammar: it colors what
//! is lexically obvious (keywords, types, strings, numbers, comments) and
//! guesses the rest (a name followed by `(` is a function; a capitalized name
//! is a type where the language asks for that).

const std = @import("std");

pub const TokenKind = enum(u8) {
    plain = 0,
    keyword,
    type,
    function,
    builtin,
    constant,
    string,
    number,
    comment,
    doc_comment,
    operator,
    punctuation,
    preprocessor,
    heading,
    emphasis,
};

pub const token_kind_count = @typeInfo(TokenKind).@"enum".field_names.len;

/// A colored byte range within a line (`start` inclusive, `end` exclusive).
pub const Span = struct { start: u32, end: u32, kind: TokenKind };

pub const StringRule = struct {
    quote: u8,
    /// Escape character (0 for none); the character after it is skipped.
    escape: u8 = '\\',
};

pub const Kind = enum { generic, markdown, plain };

pub const Language = struct {
    name: []const u8,
    kind: Kind = .generic,
    extensions: []const []const u8 = &.{},
    /// Checked before `line_comments`, so "///" can differ from "//".
    doc_comments: []const []const u8 = &.{},
    line_comments: []const []const u8 = &.{},
    block_open: []const u8 = "",
    block_close: []const u8 = "",
    block_nested: bool = false,
    strings: []const StringRule = &.{},
    /// A line whose first token starts with this is a string to the end of the
    /// line (Zig's `\\` multiline strings).
    line_string_prefix: []const u8 = "",
    /// `@name` style builtins (0 for none).
    builtin_prefix: u8 = 0,
    /// A first-on-line `#` makes the whole line a preprocessor directive.
    preprocessor: bool = false,
    /// `u8`, `i32`, `u128`... are types.
    int_types: bool = false,
    /// Capitalized identifiers are types.
    capitalized_types: bool = false,
    /// `.name` where it cannot be a field access is a constant (enum literal).
    dot_literals: bool = false,
    words: std.StaticStringMap(TokenKind) = std.StaticStringMap(TokenKind).initComptime(.{}),
};

const WordSet = struct { kind: TokenKind, words: []const []const u8 };

fn makeWords(comptime sets: []const WordSet) std.StaticStringMap(TokenKind) {
    comptime {
        const KV = struct { []const u8, TokenKind };
        var total: usize = 0;
        for (sets) |s| total += s.words.len;
        var list: [total]KV = undefined;
        var i: usize = 0;
        for (sets) |s| {
            for (s.words) |w| {
                list[i] = .{ w, s.kind };
                i += 1;
            }
        }
        return std.StaticStringMap(TokenKind).initComptime(list);
    }
}

// ---- language definitions ----------------------------------------------------

pub const zig: Language = .{
    .name = "Zig",
    .extensions = &.{ "zig", "zon" },
    .doc_comments = &.{ "///", "//!" },
    .line_comments = &.{"//"},
    .strings = &.{ .{ .quote = '"' }, .{ .quote = '\'' } },
    .line_string_prefix = "\\\\",
    .builtin_prefix = '@',
    .int_types = true,
    .capitalized_types = true,
    .dot_literals = true,
    .words = makeWords(&.{
        .{ .kind = .keyword, .words = &.{
            "addrspace", "align",    "allowzero",   "and",      "anyframe", "asm",         "break",       "callconv",
            "catch",     "comptime", "const",       "continue", "defer",    "else",        "enum",        "errdefer",
            "error",     "export",   "extern",      "fn",       "for",      "if",          "inline",      "linksection",
            "noalias",   "noinline", "nosuspend",   "opaque",   "or",       "orelse",      "packed",      "pub",
            "resume",    "return",   "struct",      "suspend",  "switch",   "test",        "threadlocal", "try",
            "union",     "unreachable", "usingnamespace", "var", "volatile", "while",
        } },
        .{ .kind = .type, .words = &.{
            "bool",        "void",         "noreturn", "type",     "anyerror", "anyopaque", "anytype", "usize",
            "isize",       "comptime_int", "comptime_float", "c_int", "c_uint", "c_long", "c_ulong", "c_char",
            "c_short",     "c_ushort",     "c_longlong", "c_ulonglong", "f16", "f32", "f64", "f80", "f128",
        } },
        .{ .kind = .constant, .words = &.{ "true", "false", "null", "undefined" } },
    }),
};

pub const c: Language = .{
    .name = "C/C++",
    .extensions = &.{ "c", "h", "cc", "cpp", "cxx", "hpp", "hh", "hxx", "inl" },
    .line_comments = &.{"//"},
    .block_open = "/*",
    .block_close = "*/",
    .strings = &.{ .{ .quote = '"' }, .{ .quote = '\'' } },
    .preprocessor = true,
    .words = makeWords(&.{
        .{ .kind = .keyword, .words = &.{
            "auto",     "break",     "case",      "class",    "const",     "constexpr", "continue", "default",
            "delete",   "do",        "else",      "enum",     "explicit",  "extern",    "for",      "friend",
            "goto",     "if",        "inline",    "namespace", "new",      "noexcept",  "operator", "override",
            "private",  "protected", "public",    "register", "return",    "sizeof",    "static",   "struct",
            "switch",   "template",  "this",      "throw",    "try",       "catch",     "typedef",  "typename",
            "union",    "using",     "virtual",   "volatile", "while",     "final",
        } },
        .{ .kind = .type, .words = &.{
            "bool",     "char",      "double",    "float",    "int",       "long",      "short",    "signed",
            "unsigned", "void",      "size_t",    "ssize_t",  "int8_t",    "int16_t",   "int32_t",  "int64_t",
            "uint8_t",  "uint16_t",  "uint32_t",  "uint64_t", "intptr_t",  "uintptr_t", "ptrdiff_t", "wchar_t",
        } },
        .{ .kind = .constant, .words = &.{ "true", "false", "NULL", "nullptr" } },
    }),
};

pub const json: Language = .{
    .name = "JSON",
    .extensions = &.{ "json", "jsonc" },
    .line_comments = &.{"//"},
    .strings = &.{.{ .quote = '"' }},
    .words = makeWords(&.{.{ .kind = .constant, .words = &.{ "true", "false", "null" } }}),
};

pub const markdown: Language = .{
    .name = "Markdown",
    .kind = .markdown,
    .extensions = &.{ "md", "markdown" },
};

pub const plain: Language = .{
    .name = "Plain text",
    .kind = .plain,
};

pub const all = [_]*const Language{ &zig, &c, &json, &markdown };

/// Pick a language from a file path's extension (case-insensitive); plain text
/// if unknown.
pub fn languageForPath(path: []const u8) *const Language {
    const dot = std.mem.lastIndexOfScalar(u8, path, '.') orelse return &plain;
    const ext = path[dot + 1 ..];
    for (all) |lang| {
        for (lang.extensions) |e| if (std.ascii.eqlIgnoreCase(e, ext)) return lang;
    }
    return &plain;
}

// ---- state --------------------------------------------------------------------

/// State at the start of a line. 0 is "normal".
pub const State = u32;

const mode_normal: State = 0;
const mode_block_comment: State = 1;
const mode_fence: State = 2;

fn mode(s: State) State {
    return s & 0xFF;
}

fn depthOf(s: State) State {
    return s >> 8;
}

fn blockState(depth: State) State {
    return mode_block_comment | (depth << 8);
}

// ---- lexing --------------------------------------------------------------------

/// Collects spans, merging neighbors of the same kind.
const Emit = struct {
    out: ?*std.ArrayListUnmanaged(Span),
    gpa: std.mem.Allocator,

    fn add(self: *Emit, start: usize, end: usize, kind: TokenKind) std.mem.Allocator.Error!void {
        if (end <= start or kind == .plain) return;
        const out = self.out orelse return;
        if (out.items.len > 0) {
            const last = &out.items[out.items.len - 1];
            if (last.kind == kind and last.end == start) {
                last.end = @intCast(end);
                return;
            }
        }
        try out.append(self.gpa, .{ .start = @intCast(start), .end = @intCast(end), .kind = kind });
    }
};

fn isIdentStart(ch: u8) bool {
    return std.ascii.isAlphabetic(ch) or ch == '_' or ch >= 0x80;
}

fn isIdentPart(ch: u8) bool {
    return std.ascii.isAlphanumeric(ch) or ch == '_' or ch >= 0x80;
}

fn startsWithAt(line: []const u8, i: usize, prefix: []const u8) bool {
    return prefix.len > 0 and line.len >= i + prefix.len and std.mem.eql(u8, line[i .. i + prefix.len], prefix);
}

fn isIntType(word: []const u8) bool {
    if (word.len < 2 or (word[0] != 'u' and word[0] != 'i')) return false;
    for (word[1..]) |ch| if (!std.ascii.isDigit(ch)) return false;
    return true;
}

fn nextNonSpace(line: []const u8, from: usize) ?u8 {
    var i = from;
    while (i < line.len and (line[i] == ' ' or line[i] == '\t')) i += 1;
    return if (i < line.len) line[i] else null;
}

/// Lex one line. `spans` may be null to only compute the end state. Returns the
/// state the next line starts in.
pub fn lexLine(
    lang: *const Language,
    start_state: State,
    line: []const u8,
    spans: ?*std.ArrayListUnmanaged(Span),
    gpa: std.mem.Allocator,
) std.mem.Allocator.Error!State {
    var emit: Emit = .{ .out = spans, .gpa = gpa };
    return switch (lang.kind) {
        .plain => mode_normal,
        .generic => lexGeneric(lang, start_state, line, &emit),
        .markdown => lexMarkdown(start_state, line, &emit),
    };
}

/// Scan a block comment body from `from`. Returns the index after the close (or
/// `line.len`), and the depth still open at the end of the line.
fn scanBlock(lang: *const Language, line: []const u8, from: usize, depth_in: State) struct { end: usize, depth: State } {
    var i = from;
    var depth = depth_in;
    while (i < line.len) {
        if (lang.block_nested and startsWithAt(line, i, lang.block_open)) {
            depth += 1;
            i += lang.block_open.len;
        } else if (startsWithAt(line, i, lang.block_close)) {
            depth -= 1;
            i += lang.block_close.len;
            if (depth == 0) return .{ .end = i, .depth = 0 };
        } else i += 1;
    }
    return .{ .end = line.len, .depth = depth };
}

fn lexGeneric(lang: *const Language, start_state: State, line: []const u8, emit: *Emit) std.mem.Allocator.Error!State {
    var i: usize = 0;
    var first_token = true;

    if (mode(start_state) == mode_block_comment) {
        const r = scanBlock(lang, line, 0, @max(depthOf(start_state), 1));
        try emit.add(0, r.end, .comment);
        if (r.depth > 0) return blockState(r.depth);
        i = r.end;
    }

    while (i < line.len) {
        const ch = line[i];
        if (ch == ' ' or ch == '\t' or ch == '\r') {
            i += 1;
            continue;
        }
        const at_first = first_token;
        first_token = false;

        if (at_first and lang.preprocessor and ch == '#') {
            try emit.add(i, line.len, .preprocessor);
            return mode_normal;
        }
        if (at_first and startsWithAt(line, i, lang.line_string_prefix)) {
            try emit.add(i, line.len, .string);
            return mode_normal;
        }
        var matched = false;
        for (lang.doc_comments) |p| {
            if (startsWithAt(line, i, p)) {
                // "////" is an ordinary comment in Zig, not a doc comment.
                const ordinary = p.len == 3 and p[0] == '/' and startsWithAt(line, i, "////");
                try emit.add(i, line.len, if (ordinary) .comment else .doc_comment);
                return mode_normal;
            }
        }
        for (lang.line_comments) |p| {
            if (startsWithAt(line, i, p)) {
                try emit.add(i, line.len, .comment);
                return mode_normal;
            }
        }
        if (lang.block_open.len > 0 and startsWithAt(line, i, lang.block_open)) {
            const r = scanBlock(lang, line, i + lang.block_open.len, 1);
            try emit.add(i, r.end, .comment);
            if (r.depth > 0) return blockState(r.depth);
            i = r.end;
            continue;
        }
        for (lang.strings) |rule| {
            if (ch != rule.quote) continue;
            var j = i + 1;
            while (j < line.len) {
                if (rule.escape != 0 and line[j] == rule.escape) {
                    j += 2;
                    continue;
                }
                if (line[j] == rule.quote) {
                    j += 1;
                    break;
                }
                j += 1;
            }
            const end = @min(j, line.len);
            try emit.add(i, end, .string);
            i = end;
            matched = true;
            break;
        }
        if (matched) continue;

        if (lang.builtin_prefix != 0 and ch == lang.builtin_prefix and i + 1 < line.len and isIdentStart(line[i + 1])) {
            var j = i + 1;
            while (j < line.len and isIdentPart(line[j])) j += 1;
            try emit.add(i, j, .builtin);
            i = j;
            continue;
        }

        const next_digit = i + 1 < line.len and std.ascii.isDigit(line[i + 1]);
        // A '.' directly after a value or another '.' (no space) is member access or a
        // range ("a.b", "0..n"), not the start of a literal.
        const after_value = i > 0 and (isIdentPart(line[i - 1]) or line[i - 1] == ')' or line[i - 1] == ']' or line[i - 1] == '.');
        if (std.ascii.isDigit(ch) or (ch == '.' and next_digit and !after_value)) {
            var j = i + 1;
            const hex = ch == '0' and j < line.len and (line[j] == 'x' or line[j] == 'X');
            while (j < line.len) {
                const d = line[j];
                if (std.ascii.isAlphanumeric(d) or d == '_') {
                    j += 1;
                } else if (d == '.' and j + 1 < line.len and std.ascii.isDigit(line[j + 1])) {
                    j += 1;
                } else if ((d == '+' or d == '-') and !hex and (line[j - 1] == 'e' or line[j - 1] == 'E')) {
                    j += 1;
                } else break;
            }
            try emit.add(i, j, .number);
            i = j;
            continue;
        }

        if (lang.dot_literals and ch == '.' and i + 1 < line.len and isIdentStart(line[i + 1]) and !after_value) {
            var j = i + 1;
            while (j < line.len and isIdentPart(line[j])) j += 1;
            try emit.add(i, j, .constant);
            i = j;
            continue;
        }

        if (isIdentStart(ch)) {
            var j = i + 1;
            while (j < line.len and isIdentPart(line[j])) j += 1;
            const word = line[i..j];
            var kind: TokenKind = .plain;
            if (lang.words.get(word)) |k| {
                kind = k;
            } else if (lang.int_types and isIntType(word)) {
                kind = .type;
            } else if (nextNonSpace(line, j)) |nc| {
                if (nc == '(') kind = .function;
            }
            if (kind == .plain and lang.capitalized_types and std.ascii.isUpper(word[0])) kind = .type;
            try emit.add(i, j, kind);
            i = j;
            continue;
        }

        switch (ch) {
            '(', ')', '[', ']', '{', '}' => try emit.add(i, i + 1, .punctuation),
            '+', '-', '*', '/', '%', '=', '<', '>', '!', '&', '|', '^', '~', '?', ':', '.', ',', ';' => try emit.add(i, i + 1, .operator),
            else => {},
        }
        i += 1;
    }
    return mode_normal;
}

fn lexMarkdown(start_state: State, line: []const u8, emit: *Emit) std.mem.Allocator.Error!State {
    var lead: usize = 0;
    while (lead < line.len and lead < 3 and line[lead] == ' ') lead += 1;
    const is_fence = startsWithAt(line, lead, "```") or startsWithAt(line, lead, "~~~");

    if (mode(start_state) == mode_fence) {
        if (is_fence) {
            try emit.add(0, line.len, .comment);
            return mode_normal;
        }
        try emit.add(0, line.len, .string);
        return mode_fence;
    }
    if (is_fence) {
        try emit.add(0, line.len, .comment);
        return mode_fence;
    }

    // Headings: 1-6 '#' then a space.
    var hashes: usize = 0;
    while (lead + hashes < line.len and line[lead + hashes] == '#') hashes += 1;
    if (hashes >= 1 and hashes <= 6 and (lead + hashes == line.len or line[lead + hashes] == ' ')) {
        try emit.add(0, line.len, .heading);
        return mode_normal;
    }
    if (startsWithAt(line, lead, ">")) {
        try emit.add(0, line.len, .comment);
        return mode_normal;
    }
    // Horizontal rule.
    const trimmed = std.mem.trim(u8, line, " ");
    if (trimmed.len >= 3 and (std.mem.allEqual(u8, trimmed, '-') or std.mem.allEqual(u8, trimmed, '*') or std.mem.allEqual(u8, trimmed, '_'))) {
        try emit.add(0, line.len, .comment);
        return mode_normal;
    }

    var i: usize = 0;
    // List markers.
    var j = lead;
    if (j < line.len and (line[j] == '-' or line[j] == '*' or line[j] == '+') and j + 1 < line.len and line[j + 1] == ' ') {
        try emit.add(j, j + 1, .operator);
        i = j + 1;
    } else {
        while (j < line.len and std.ascii.isDigit(line[j])) j += 1;
        if (j > lead and j + 1 < line.len and (line[j] == '.' or line[j] == ')') and line[j + 1] == ' ') {
            try emit.add(lead, j + 1, .operator);
            i = j + 1;
        }
    }

    while (i < line.len) {
        const ch = line[i];
        if (ch == '`') {
            var run: usize = 0;
            while (i + run < line.len and line[i + run] == '`') run += 1;
            // Closing run of the same length.
            var k = i + run;
            var end: usize = line.len;
            while (k < line.len) : (k += 1) {
                if (line[k] != '`') continue;
                var r2: usize = 0;
                while (k + r2 < line.len and line[k + r2] == '`') r2 += 1;
                if (r2 == run) {
                    end = k + r2;
                    break;
                }
                k += r2 - 1;
            }
            try emit.add(i, end, .string);
            i = end;
        } else if ((ch == '*' or ch == '_') and i + 1 < line.len and line[i + 1] != ' ') {
            var run: usize = 1;
            if (line[i + 1] == ch) run = 2;
            const marker = line[i .. i + run];
            const close = std.mem.indexOfPos(u8, line, i + run, marker);
            if (close != null and close.? > i + run) {
                try emit.add(i, close.? + run, .emphasis);
                i = close.? + run;
            } else i += run;
        } else if (ch == '[') {
            const close = std.mem.indexOfScalarPos(u8, line, i + 1, ']');
            if (close != null and close.? + 1 < line.len and line[close.? + 1] == '(') {
                const paren = std.mem.indexOfScalarPos(u8, line, close.? + 2, ')');
                if (paren) |p| {
                    try emit.add(i, close.? + 1, .function);
                    try emit.add(close.? + 1, p + 1, .string);
                    i = p + 1;
                    continue;
                }
            }
            i += 1;
        } else i += 1;
    }
    return mode_normal;
}

// ---- tests -----------------------------------------------------------------

const testing = std.testing;

/// Render spans as "kind:text" pairs joined by '|' for readable assertions.
fn show(lang: *const Language, state: State, line: []const u8, out_state: ?*State) ![]u8 {
    var spans: std.ArrayListUnmanaged(Span) = .empty;
    defer spans.deinit(testing.allocator);
    const new = try lexLine(lang, state, line, &spans, testing.allocator);
    if (out_state) |p| p.* = new;
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(testing.allocator);
    for (spans.items, 0..) |s, i| {
        if (i > 0) try buf.append(testing.allocator, '|');
        try buf.appendSlice(testing.allocator, @tagName(s.kind));
        try buf.append(testing.allocator, ':');
        try buf.appendSlice(testing.allocator, line[s.start..s.end]);
    }
    return buf.toOwnedSlice(testing.allocator);
}

fn expectLex(lang: *const Language, line: []const u8, expected: []const u8) !void {
    const got = try show(lang, 0, line, null);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(expected, got);
}

test "zig: keywords, types, strings, numbers, calls, builtins" {
    try expectLex(&zig, "const x: u32 = 42;", "keyword:const|operator::|type:u32|operator:=|number:42|operator:;");
    try expectLex(&zig, "pub fn main(init: std.process.Init) !void {", "keyword:pub|keyword:fn|function:main|punctuation:(|operator::|operator:.|operator:.|type:Init|punctuation:)|operator:!|type:void|punctuation:{");
}

test "zig: identifiers around member access and calls" {
    try expectLex(&zig, "std.debug.print(\"hi\\n\", .{});", "operator:.|operator:.|function:print|punctuation:(|string:\"hi\\n\"|operator:,|operator:.|punctuation:{})|operator:;");
}

test "zig: types by capitalization, integer types, builtins, constants" {
    try expectLex(&zig, "var t: ArrayList = undefined;", "keyword:var|operator::|type:ArrayList|operator:=|constant:undefined|operator:;");
    try expectLex(&zig, "x: i128, y: u8, z: iX", "operator::|type:i128|operator:,|operator::|type:u8|operator:,|operator::");
    try expectLex(&zig, "@import(\"std\")", "builtin:@import|punctuation:(|string:\"std\"|punctuation:)");
    try expectLex(&zig, "if (a == null) return true;", "keyword:if|punctuation:(|operator:==|constant:null|punctuation:)|keyword:return|constant:true|operator:;");
}

test "zig: comments, doc comments, and the //// exception" {
    try expectLex(&zig, "x = 1; // trailing", "operator:=|number:1|operator:;|comment:// trailing");
    try expectLex(&zig, "/// docs here", "doc_comment:/// docs here");
    try expectLex(&zig, "//! module docs", "doc_comment://! module docs");
    try expectLex(&zig, "//// just a comment", "comment://// just a comment");
    try expectLex(&zig, "    // indented", "comment:// indented");
}

test "zig: strings with escapes, unterminated strings, char literals, multiline string lines" {
    try expectLex(&zig, "\"a\\\"b\" x", "string:\"a\\\"b\"");
    try expectLex(&zig, "const s = \"unterminated", "keyword:const|operator:=|string:\"unterminated");
    try expectLex(&zig, "'\\n' + 'x'", "string:'\\n'|operator:+|string:'x'");
    try expectLex(&zig, "    \\\\line of a multiline string // not a comment", "string:\\\\line of a multiline string // not a comment");
}

test "zig: numbers" {
    try expectLex(&zig, "0xFF_AA 1_000 3.14 1e-5 2E+10 0b101 .5", "number:0xFF_AA|number:1_000|number:3.14|number:1e-5|number:2E+10|number:0b101|number:.5");
    try expectLex(&zig, "a[0..3]", "punctuation:[|number:0|operator:..|number:3|punctuation:]");
    try expectLex(&zig, "x.y.z", "operator:.|operator:.");
    try expectLex(&zig, "s[a..n]", "punctuation:[|operator:..|punctuation:]"); // not a ".n" enum literal
}

test "c: preprocessor, block comments across lines, types, strings" {
    try expectLex(&c, "#include <stdio.h>", "preprocessor:#include <stdio.h>");
    try expectLex(&c, "  #define X 1", "preprocessor:#define X 1");
    try expectLex(&c, "int main(void) { return 0; }", "type:int|function:main|punctuation:(|type:void|punctuation:)|punctuation:{|keyword:return|number:0|operator:;|punctuation:}");
    try expectLex(&c, "char *s = \"a\"; // hi", "type:char|operator:*|operator:=|string:\"a\"|operator:;|comment:// hi");

    var st: State = 0;
    {
        const got = try show(&c, 0, "int a; /* start of", &st);
        defer testing.allocator.free(got);
        try testing.expectEqualStrings("type:int|operator:;|comment:/* start of", got);
        try testing.expect(st != 0);
    }
    {
        const got = try show(&c, st, "still inside */ int b;", &st);
        defer testing.allocator.free(got);
        try testing.expectEqualStrings("comment:still inside */|type:int|operator:;", got);
        try testing.expectEqual(@as(State, 0), st);
    }
    {
        const got = try show(&c, 0, "/* one line */ x", &st);
        defer testing.allocator.free(got);
        try testing.expectEqualStrings("comment:/* one line */", got);
        try testing.expectEqual(@as(State, 0), st);
    }
}

test "json: keys, values, constants, numbers" {
    try expectLex(&json, "{\"a\": [1, -2.5, true, null], \"b\": \"x\"}", "punctuation:{|string:\"a\"|operator::|punctuation:[|number:1|operator:,|operator:-|number:2.5|operator:,|constant:true|operator:,|constant:null|punctuation:]|operator:,|string:\"b\"|operator::|string:\"x\"|punctuation:}");
}

test "markdown: headings, lists, inline code, emphasis, links, fences, quotes, rules" {
    try expectLex(&markdown, "## A heading", "heading:## A heading");
    try expectLex(&markdown, "#notaheading", "");
    try expectLex(&markdown, "- item with `code` and **bold**", "operator:-|string:`code`|emphasis:**bold**");
    try expectLex(&markdown, "1. first", "operator:1.");
    try expectLex(&markdown, "see [the docs](http://x.y) now", "function:[the docs]|string:(http://x.y)");
    try expectLex(&markdown, "> quoted", "comment:> quoted");
    try expectLex(&markdown, "---", "comment:---");
    try expectLex(&markdown, "a *b* and _c_", "emphasis:*b*|emphasis:_c_");

    var st: State = 0;
    {
        const got = try show(&markdown, 0, "```zig", &st);
        defer testing.allocator.free(got);
        try testing.expectEqualStrings("comment:```zig", got);
        try testing.expect(st != 0);
    }
    {
        const got = try show(&markdown, st, "# not a heading inside a fence", &st);
        defer testing.allocator.free(got);
        try testing.expectEqualStrings("string:# not a heading inside a fence", got);
        try testing.expect(st != 0);
    }
    {
        const got = try show(&markdown, st, "```", &st);
        defer testing.allocator.free(got);
        try testing.expectEqualStrings("comment:```", got);
        try testing.expectEqual(@as(State, 0), st);
    }
}

test "plain text has no tokens and no state" {
    try expectLex(&plain, "const x = \"y\"; // z", "");
}

test "unicode and odd bytes pass through without breaking tokens" {
    try expectLex(&zig, "const caf\u{e9} = \"na\u{ef}ve\";", "keyword:const|operator:=|string:\"na\u{ef}ve\"|operator:;");
    try expectLex(&zig, "x = \x01\x02 y", "operator:=");
}

test "adjacent same-kind spans merge" {
    var spans: std.ArrayListUnmanaged(Span) = .empty;
    defer spans.deinit(testing.allocator);
    _ = try lexLine(&zig, 0, "((()))", &spans, testing.allocator);
    try testing.expectEqual(@as(usize, 1), spans.items.len);
    try testing.expectEqual(@as(u32, 6), spans.items[0].end);
}

test "language by file extension" {
    try testing.expectEqualStrings("Zig", languageForPath("src/main.zig").name);
    try testing.expectEqualStrings("C/C++", languageForPath("a/b.CPP").name);
    try testing.expectEqualStrings("Markdown", languageForPath("README.md").name);
    try testing.expectEqualStrings("JSON", languageForPath("x.json").name);
    try testing.expectEqualStrings("Plain text", languageForPath("Makefile").name);
    try testing.expectEqualStrings("Plain text", languageForPath("notes.unknown").name);
}

test "lexing without collecting spans still returns the state" {
    const st = try lexLine(&c, 0, "/* open", null, testing.allocator);
    try testing.expect(st != 0);
    const st2 = try lexLine(&c, st, "close */", null, testing.allocator);
    try testing.expectEqual(@as(State, 0), st2);
}

test "nested block comments track depth" {
    const nested: Language = .{ .name = "nested", .block_open = "/*", .block_close = "*/", .block_nested = true };
    var st = try lexLine(&nested, 0, "a /* b /* c", null, testing.allocator);
    st = try lexLine(&nested, st, "d */ e", null, testing.allocator);
    try testing.expect(st != 0); // one level still open
    st = try lexLine(&nested, st, "*/ done", null, testing.allocator);
    try testing.expectEqual(@as(State, 0), st);
}
