//! Event handlers for UI documents: find the functions in a project that can
//! handle an event, keep a manifest of which UI action name calls which
//! function, generate the file that registers them, and create or rename a
//! handler everywhere it appears. No UI here (see `ide/designer.zig`).
//!
//! A UI document binds an event to an *action name* (`on = .{ .click = "okClick" }`).
//! The program turns names into calls with `Actions.put(gpa, "okClick", .bind(&app, App.onOkClick))`.
//! This module owns that mapping for the IDE:
//!
//!   * `.zigide/actions.zon` (the manifest): action name -> container, function, file
//!   * `ui_actions.zig` (generated, do not edit): `register(actions, gpa, contexts)`
//!     with one `put` per manifest entry
//!   * handlers themselves are ordinary methods you write and keep wherever you like
//!
//! A *handler* is a function `fn (self: *T, ev: *Event) void` inside a struct,
//! or `fn (ev: *Event) void` anywhere (`Event` may be spelled `zigui.event.Event`,
//! `zigui.Event`, ...). Rename and creation work on source text with `std.zig.Ast`
//! and produce a list of edits; `Handlers` applies them (through an open editor
//! buffer when one exists, else on disk), updates the manifest and regenerates the
//! binding file. References are found by name (not by type), so renaming shows
//! what it will change before it does.

const std = @import("std");
const Ast = std.zig.Ast;
const Allocator = std.mem.Allocator;
const project_mod = @import("project.zig");
const Project = project_mod.Project;
const zon = @import("../uidoc/zon.zig");

pub const manifest_path = ".zigide/actions.zon";
pub const binding_file = "ui_actions.zig";
pub const fallback_file = "ui_handlers.zig";
pub const fallback_container = "Handlers";

// ---- discovery -------------------------------------------------------------

pub const Handler = struct {
    name: []const u8,
    /// The struct it is declared in; empty for a function at file level.
    container: []const u8,
    /// Project-relative path.
    file: []const u8,
    /// 1-based line of the name.
    line: u32,
    takes_self: bool,
    is_pub: bool,
    container_pub: bool,
    /// Byte offsets in the file: the name, and the start of the declaration (`pub`/`fn`).
    name_start: usize,
    name_end: usize,
    decl_start: usize,
    /// Start of the container's declaration (`pub const X = struct`); 0 for file level.
    container_decl_start: usize,
};

pub const Container = struct {
    name: []const u8,
    file: []const u8,
    is_pub: bool,
    /// Offset of the closing `}` of the body, and the indentation of its members.
    close: usize,
    indent: usize,
    handler_count: u32 = 0,
};

pub const Scan = struct {
    arena: std.heap.ArenaAllocator,
    handlers: []Handler = &.{},
    containers: []Container = &.{},

    pub fn deinit(self: *Scan) void {
        self.arena.deinit();
    }

    pub fn findHandler(self: *const Scan, container: []const u8, file: []const u8, name: []const u8) ?usize {
        for (self.handlers, 0..) |h, i| {
            if (std.mem.eql(u8, h.name, name) and std.mem.eql(u8, h.container, container) and std.mem.eql(u8, h.file, file)) return i;
        }
        return null;
    }

    pub fn findContainer(self: *const Scan, name: []const u8, file: []const u8) ?*const Container {
        for (self.containers) |*c| {
            if (std.mem.eql(u8, c.name, name) and std.mem.eql(u8, c.file, file)) return c;
        }
        return null;
    }
};

/// Project-relative paths of every `.zig` file (excluded folders skipped).
pub fn listZigFiles(gpa: Allocator, project: *const Project, out: *std.ArrayListUnmanaged([]u8)) !void {
    var walker = try project.dir.walkSelectively(gpa);
    defer walker.deinit();
    while (try walker.next(project.io)) |entry| {
        switch (entry.kind) {
            .directory => if (!project_mod.isExcludedName(entry.basename)) walker.enter(project.io, entry) catch {},
            .file => if (std.mem.endsWith(u8, entry.path, ".zig")) {
                const p = try gpa.dupe(u8, entry.path);
                errdefer gpa.free(p);
                try out.append(gpa, p);
            },
            else => {},
        }
    }
}

fn lineStartOf(source: []const u8, offset: usize) usize {
    var i = @min(offset, source.len);
    while (i > 0 and source[i - 1] != '\n') i -= 1;
    return i;
}

fn indentOfLine(source: []const u8, offset: usize) usize {
    const s = lineStartOf(source, offset);
    var n: usize = 0;
    while (s + n < source.len and source[s + n] == ' ') n += 1;
    return n;
}

/// Is `type_text` an `Event` pointer (`*Event`, `*zigui.event.Event`, `*const Event`)?
fn isEventPointer(type_text: []const u8) bool {
    var t = std.mem.trim(u8, type_text, " ");
    if (!std.mem.startsWith(u8, t, "*")) return false;
    t = std.mem.trim(u8, t[1..], " ");
    if (std.mem.startsWith(u8, t, "const ")) t = std.mem.trim(u8, t[6..], " ");
    return std.mem.eql(u8, t, "Event") or std.mem.endsWith(u8, t, ".Event");
}

const Found = struct { name: []const u8, takes_self: bool, is_pub: bool, name_tok: Ast.TokenIndex, first_tok: Ast.TokenIndex };

fn asHandler(ast: *const Ast, node: Ast.Node.Index) ?Found {
    if (ast.nodeTag(node) != .fn_decl) return null;
    var fb: [1]Ast.Node.Index = undefined;
    const proto = ast.nodeData(node).node_and_node[0];
    const fp = ast.fullFnProto(&fb, proto) orelse return null;
    const name_tok = fp.name_token orelse return null;
    const rt = fp.ast.return_type.unwrap() orelse return null;
    if (!std.mem.eql(u8, std.mem.trim(u8, ast.getNodeSource(rt), " "), "void")) return null;
    var types: [3]?[]const u8 = @splat(null);
    var n: usize = 0;
    var it = fp.iterate(ast);
    while (it.next()) |p| {
        if (n == types.len) return null;
        types[n] = if (p.type_expr) |t| ast.getNodeSource(t) else null;
        n += 1;
    }
    const first_tok = fp.visib_token orelse fp.extern_export_inline_token orelse fp.ast.fn_token;
    if (n == 1) {
        if (!isEventPointer(types[0] orelse return null)) return null;
        return .{ .name = ast.tokenSlice(name_tok), .takes_self = false, .is_pub = fp.visib_token != null, .name_tok = name_tok, .first_tok = first_tok };
    }
    if (n == 2) {
        const first = std.mem.trim(u8, types[0] orelse return null, " ");
        if (!std.mem.startsWith(u8, first, "*")) return null;
        if (!isEventPointer(types[1] orelse return null)) return null;
        return .{ .name = ast.tokenSlice(name_tok), .takes_self = true, .is_pub = fp.visib_token != null, .name_tok = name_tok, .first_tok = first_tok };
    }
    return null;
}

/// Find every handler (and the structs that hold handlers or could) in the project.
pub fn scan(gpa: Allocator, project: *const Project) !Scan {
    var result: Scan = .{ .arena = std.heap.ArenaAllocator.init(gpa) };
    errdefer result.arena.deinit();
    const a = result.arena.allocator();
    var files: std.ArrayListUnmanaged([]u8) = .empty;
    defer {
        for (files.items) |f| gpa.free(f);
        files.deinit(gpa);
    }
    try listZigFiles(gpa, project, &files);
    var handlers: std.ArrayListUnmanaged(Handler) = .empty;
    var containers: std.ArrayListUnmanaged(Container) = .empty;
    for (files.items) |rel| {
        const bytes = project.readFile(gpa, rel, 4 * 1024 * 1024) catch continue;
        defer gpa.free(bytes);
        const src = try gpa.dupeSentinel(u8, bytes, 0);
        defer gpa.free(src);
        var ast = Ast.parse(gpa, src, .{}) catch continue;
        defer ast.deinit(gpa);
        const rel_copy = try a.dupe(u8, rel);
        for (ast.rootDecls()) |decl| {
            if (asHandler(&ast, decl)) |f| try handlers.append(a, try makeHandler(a, &ast, src, rel_copy, "", false, 0, f));
            const vd = ast.fullVarDecl(decl) orelse continue;
            const init = vd.ast.init_node.unwrap() orelse continue;
            var cb: [2]Ast.Node.Index = undefined;
            const cd = ast.fullContainerDecl(&cb, init) orelse continue;
            if (ast.tokenTag(cd.ast.main_token) != .keyword_struct) continue;
            const cname = try a.dupe(u8, ast.tokenSlice(vd.ast.mut_token + 1));
            const cpub = vd.visib_token != null;
            const decl_start = ast.tokenStart(vd.firstToken());
            const last = ast.lastToken(init);
            var c: Container = .{ .name = cname, .file = rel_copy, .is_pub = cpub, .close = ast.tokenStart(last), .indent = indentOfLine(src, decl_start) + 4 };
            for (cd.ast.members) |m| {
                if (asHandler(&ast, m)) |f| {
                    try handlers.append(a, try makeHandler(a, &ast, src, rel_copy, cname, cpub, decl_start, f));
                    c.handler_count += 1;
                }
            }
            try containers.append(a, c);
        }
    }
    result.handlers = handlers.items;
    result.containers = containers.items;
    return result;
}

fn makeHandler(a: Allocator, ast: *const Ast, src: []const u8, file: []const u8, container: []const u8, container_pub: bool, container_decl_start: usize, f: Found) !Handler {
    const start = ast.tokenStart(f.name_tok);
    var line: u32 = 1;
    for (src[0..start]) |ch| {
        if (ch == '\n') line += 1;
    }
    return .{
        .name = try a.dupe(u8, f.name),
        .container = container,
        .file = file,
        .line = line,
        .takes_self = f.takes_self,
        .is_pub = f.is_pub,
        .container_pub = container_pub or container.len == 0,
        .name_start = start,
        .name_end = start + f.name.len,
        .decl_start = ast.tokenStart(f.first_tok),
        .container_decl_start = container_decl_start,
    };
}

// ---- the manifest ----------------------------------------------------------

pub const Binding = struct { action: []const u8, container: []const u8, function: []const u8, file: []const u8 };

/// action name -> function, plus where new handlers go by default.
pub const Manifest = struct {
    arena: std.heap.ArenaAllocator,
    gpa: Allocator,
    bindings: std.ArrayListUnmanaged(Binding) = .empty,
    default_container: []const u8 = "",
    default_file: []const u8 = "",

    pub fn init(gpa: Allocator) Manifest {
        return .{ .arena = std.heap.ArenaAllocator.init(gpa), .gpa = gpa };
    }

    pub fn deinit(self: *Manifest) void {
        self.bindings.deinit(self.gpa);
        self.arena.deinit();
    }

    /// Read `.zigide/actions.zon` (an absent or unreadable file is an empty manifest).
    pub fn load(gpa: Allocator, project: *const Project) !Manifest {
        var m = Manifest.init(gpa);
        errdefer m.deinit();
        const bytes = project.readFile(gpa, manifest_path, 1024 * 1024) catch return m;
        defer gpa.free(bytes);
        var tmp = std.heap.ArenaAllocator.init(gpa);
        defer tmp.deinit();
        const v = zon.parse(tmp.allocator(), bytes, null) catch return m;
        const a = m.arena.allocator();
        if (v.field("default_container")) |c| if (c == .string) {
            m.default_container = try a.dupe(u8, c.string);
        };
        if (v.field("default_file")) |c| if (c == .string) {
            m.default_file = try a.dupe(u8, c.string);
        };
        if (v.field("bindings")) |bs| for (bs.items() orelse &.{}) |b| {
            const action = strField(b, "action") orelse continue;
            const function = strField(b, "function") orelse continue;
            try m.bindings.append(gpa, .{
                .action = try a.dupe(u8, action),
                .container = try a.dupe(u8, strField(b, "container") orelse ""),
                .function = try a.dupe(u8, function),
                .file = try a.dupe(u8, strField(b, "file") orelse ""),
            });
        };
        return m;
    }

    fn strField(v: zon.Value, name: []const u8) ?[]const u8 {
        const f = v.field(name) orelse return null;
        return if (f == .string) f.string else null;
    }

    pub fn find(self: *const Manifest, action: []const u8) ?*const Binding {
        for (self.bindings.items) |*b| {
            if (std.mem.eql(u8, b.action, action)) return b;
        }
        return null;
    }

    /// The action bound to this function, if any.
    pub fn actionFor(self: *const Manifest, container: []const u8, file: []const u8, function: []const u8) ?[]const u8 {
        for (self.bindings.items) |b| {
            if (std.mem.eql(u8, b.function, function) and std.mem.eql(u8, b.container, container) and std.mem.eql(u8, b.file, file)) return b.action;
        }
        return null;
    }

    /// Point `action` at a function (replacing an earlier binding of that name).
    pub fn bind(self: *Manifest, action: []const u8, container: []const u8, function: []const u8, file: []const u8) !void {
        const a = self.arena.allocator();
        const nb: Binding = .{ .action = try a.dupe(u8, action), .container = try a.dupe(u8, container), .function = try a.dupe(u8, function), .file = try a.dupe(u8, file) };
        for (self.bindings.items) |*b| {
            if (std.mem.eql(u8, b.action, action)) {
                b.* = nb;
                return;
            }
        }
        try self.bindings.append(self.gpa, nb);
    }

    pub fn setDefault(self: *Manifest, container: []const u8, file: []const u8) !void {
        const a = self.arena.allocator();
        self.default_container = try a.dupe(u8, container);
        self.default_file = try a.dupe(u8, file);
    }

    pub fn unbind(self: *Manifest, action: []const u8) void {
        for (self.bindings.items, 0..) |b, i| {
            if (std.mem.eql(u8, b.action, action)) {
                _ = self.bindings.orderedRemove(i);
                return;
            }
        }
    }

    fn quote(out: *std.ArrayListUnmanaged(u8), gpa: Allocator, s: []const u8) !void {
        try out.append(gpa, '"');
        for (s) |c| {
            if (c == '"' or c == '\\') try out.append(gpa, '\\');
            try out.append(gpa, c);
        }
        try out.append(gpa, '"');
    }

    pub fn save(self: *const Manifest, project: *const Project) !void {
        var out: std.ArrayListUnmanaged(u8) = .empty;
        defer out.deinit(self.gpa);
        try out.appendSlice(self.gpa, "// UI action bindings, maintained by the zigui IDE. ui_actions.zig is generated from this.\n.{\n    .default_container = ");
        try quote(&out, self.gpa, self.default_container);
        try out.appendSlice(self.gpa, ",\n    .default_file = ");
        try quote(&out, self.gpa, self.default_file);
        try out.appendSlice(self.gpa, ",\n    .bindings = .{\n");
        for (self.bindings.items) |b| {
            try out.appendSlice(self.gpa, "        .{ .action = ");
            try quote(&out, self.gpa, b.action);
            try out.appendSlice(self.gpa, ", .container = ");
            try quote(&out, self.gpa, b.container);
            try out.appendSlice(self.gpa, ", .function = ");
            try quote(&out, self.gpa, b.function);
            try out.appendSlice(self.gpa, ", .file = ");
            try quote(&out, self.gpa, b.file);
            try out.appendSlice(self.gpa, " },\n");
        }
        try out.appendSlice(self.gpa, "    },\n}\n");
        try project.dir.createDirPath(project.io, ".zigide");
        try project.writeFile(manifest_path, out.items);
    }
};

// ---- the generated binding file ---------------------------------------------

/// `MainWindow` -> `main_window`.
pub fn snakeCase(a: Allocator, name: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    for (name, 0..) |c, i| {
        if (std.ascii.isUpper(c)) {
            if (i > 0 and !std.ascii.isUpper(name[i - 1])) try out.append(a, '_');
            try out.append(a, std.ascii.toLower(c));
        } else try out.append(a, c);
    }
    return out.items;
}

/// The text of `ui_actions.zig` for `manifest`.
pub fn generateBindings(gpa: Allocator, manifest: *const Manifest) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa,
        \\//! Generated by the zigui IDE from .zigide/actions.zon. Do not edit this file:
        \\//! change the bindings in the IDE's UI designer (Events tab) instead.
        \\//!
        \\//! Register every UI action with the program's `Actions` (see `uiload.Actions`):
        \\//!
        \\//!     var actions: zigui.uiload.Actions = .{};
        \\//!     try ui_actions.register(&actions, gpa, .{ .app = &app });
        \\
        \\const std = @import("std");
        \\const zigui = @import("zigui");
        \\
        \\
    );
    // One import per file, one context per struct that has bound methods.
    var files: std.ArrayListUnmanaged([]const u8) = .empty;
    for (manifest.bindings.items) |b| {
        if (b.file.len == 0) continue;
        var seen = false;
        for (files.items) |f| if (std.mem.eql(u8, f, b.file)) {
            seen = true;
        };
        if (!seen) try files.append(a, b.file);
    }
    for (files.items, 0..) |f, i| try out.print(gpa, "const f{d} = @import(\"{s}\");\n", .{ i, f });
    if (files.items.len > 0) try out.append(gpa, '\n');

    const Ctx = struct { container: []const u8, file: usize };
    var ctxs: std.ArrayListUnmanaged(Ctx) = .empty;
    for (manifest.bindings.items) |b| {
        if (b.container.len == 0) continue;
        const fi = indexOf(files.items, b.file) orelse continue;
        var seen = false;
        for (ctxs.items) |c| if (c.file == fi and std.mem.eql(u8, c.container, b.container)) {
            seen = true;
        };
        if (!seen) try ctxs.append(a, .{ .container = b.container, .file = fi });
    }
    try out.appendSlice(gpa, "/// The objects whose methods handle events (one per struct).\npub const Contexts = struct {\n");
    for (ctxs.items) |c| try out.print(gpa, "    {s}: *f{d}.{s},\n", .{ try snakeCase(a, c.container), c.file, c.container });
    try out.appendSlice(gpa, "};\n\npub fn register(actions: *zigui.uiload.Actions, gpa: std.mem.Allocator, ctx: Contexts) !void {\n");
    if (ctxs.items.len == 0) try out.appendSlice(gpa, "    _ = ctx;\n");
    if (manifest.bindings.items.len == 0) try out.appendSlice(gpa, "    _ = actions;\n    _ = gpa;\n");
    for (manifest.bindings.items) |b| {
        const fi = indexOf(files.items, b.file) orelse continue;
        if (b.container.len > 0) {
            try out.print(gpa, "    try actions.put(gpa, \"{s}\", zigui.event.Callback.bind(ctx.{s}, f{d}.{s}.{s}));\n", .{ try zigEscape(a, b.action), try snakeCase(a, b.container), fi, b.container, b.function });
        } else {
            try out.print(gpa, "    try actions.put(gpa, \"{s}\", zigui.event.Callback.fromFn(f{d}.{s}));\n", .{ try zigEscape(a, b.action), fi, b.function });
        }
    }
    try out.appendSlice(gpa, "}\n");
    return out.toOwnedSlice(gpa);
}

/// `s` as the inside of a Zig string literal.
fn zigEscape(a: Allocator, s: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    for (s) |c| {
        switch (c) {
            '"', '\\' => {
                try out.append(a, '\\');
                try out.append(a, c);
            },
            '\n' => try out.appendSlice(a, "\\n"),
            else => try out.append(a, c),
        }
    }
    return out.items;
}

fn indexOf(list: []const []const u8, s: []const u8) ?usize {
    for (list, 0..) |x, i| if (std.mem.eql(u8, x, s)) return i;
    return null;
}

// ---- names -----------------------------------------------------------------

pub fn isIdentifier(s: []const u8) bool {
    return std.zig.isValidId(s);
}

fn capitalized(a: Allocator, s: []const u8, out: *std.ArrayListUnmanaged(u8)) !void {
    var up = true;
    for (s) |c| {
        if (!std.ascii.isAlphanumeric(c)) {
            up = true;
            continue;
        }
        try out.append(a, if (up) std.ascii.toUpper(c) else c);
        up = false;
    }
}

/// The action name for event `event_name` of the node called `base`: `okButton`, `click` -> `okButtonClick`.
pub fn suggestAction(a: Allocator, base: []const u8, event_name: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    try capitalized(a, base, &out);
    try capitalized(a, event_name, &out);
    if (out.items.len > 0) out.items[0] = std.ascii.toLower(out.items[0]);
    if (out.items.len == 0 or std.ascii.isDigit(out.items[0])) try out.insert(a, 0, 'x');
    return out.items;
}

/// The function name for an action: `okButtonClick` -> `onOkButtonClick`.
pub fn functionNameFor(a: Allocator, action: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    try out.appendSlice(a, "on");
    try capitalized(a, action, &out);
    return out.items;
}

// ---- edits -----------------------------------------------------------------

pub const FileEdit = struct { file: []const u8, start: usize, end: usize, text: []const u8 };

pub const Plan = struct {
    arena: std.heap.ArenaAllocator,
    edits: []FileEdit = &.{},
    /// For a creation: the new function.
    action: []const u8 = "",
    container: []const u8 = "",
    function: []const u8 = "",
    file: []const u8 = "",
    /// Create the fallback file with this text first (it did not exist).
    new_file: ?[]const u8 = null,

    pub fn deinit(self: *Plan) void {
        self.arena.deinit();
    }
};

fn lessEdit(_: void, a: FileEdit, b: FileEdit) bool {
    const c = std.mem.order(u8, a.file, b.file);
    if (c != .eq) return c == .lt;
    return a.start > b.start; // later offsets first, so earlier ones stay valid
}

/// Apply `edits` to `bytes` of a single file (any order; they must not overlap).
pub fn applyToText(gpa: Allocator, bytes: []const u8, edits: []const FileEdit) ![]u8 {
    const sorted = try gpa.dupe(FileEdit, edits);
    defer gpa.free(sorted);
    std.mem.sort(FileEdit, sorted, {}, lessEdit);
    var out = try gpa.dupe(u8, bytes);
    errdefer gpa.free(out);
    for (sorted) |e| {
        const head = out[0..e.start];
        const tail = out[e.end..];
        const joined = try std.mem.concat(gpa, u8, &.{ head, e.text, tail });
        gpa.free(out);
        out = joined;
    }
    return out;
}

/// Edits that put `pub` in front of a handler's declaration and its struct's, so another file can name them.
fn pubEdits(a: Allocator, h: Handler, out: *std.ArrayListUnmanaged(FileEdit)) !void {
    if (!h.is_pub) try out.append(a, .{ .file = h.file, .start = h.decl_start, .end = h.decl_start, .text = "pub " });
    if (h.container.len > 0 and !h.container_pub) try out.append(a, .{ .file = h.file, .start = h.container_decl_start, .end = h.container_decl_start, .text = "pub " });
}

/// What it takes to call handler `h` from the binding file: making it `pub`.
pub fn planBind(gpa: Allocator, h: Handler) !Plan {
    var p: Plan = .{ .arena = std.heap.ArenaAllocator.init(gpa) };
    errdefer p.arena.deinit();
    const a = p.arena.allocator();
    var edits: std.ArrayListUnmanaged(FileEdit) = .empty;
    try pubEdits(a, h, &edits);
    p.edits = edits.items;
    p.container = try a.dupe(u8, h.container);
    p.function = try a.dupe(u8, h.name);
    p.file = try a.dupe(u8, h.file);
    return p;
}

fn zigAlias(ast: *const Ast) ?[]const u8 {
    for (ast.rootDecls()) |d| {
        const vd = ast.fullVarDecl(d) orelse continue;
        const init = vd.ast.init_node.unwrap() orelse continue;
        const src = ast.getNodeSource(init);
        if (std.mem.indexOf(u8, src, "@import(\"zigui\")") != null) return ast.tokenSlice(vd.ast.mut_token + 1);
    }
    return null;
}

fn nameTaken(scan_result: *const Scan, manifest: *const Manifest, container: []const u8, file: []const u8, action: []const u8, function: []const u8) bool {
    if (manifest.find(action) != null) return true;
    return scan_result.findHandler(container, file, function) != null;
}

/// Where a new handler goes: the manifest's default struct if it still exists,
/// else the struct with the most handlers, else a new `ui_handlers.zig`.
pub fn chooseTarget(scan_result: *const Scan, manifest: *const Manifest) ?*const Container {
    if (manifest.default_container.len > 0) {
        if (scan_result.findContainer(manifest.default_container, manifest.default_file)) |c| return c;
    }
    var best: ?*const Container = null;
    for (scan_result.containers) |*c| {
        if (c.handler_count > 0 and (best == null or c.handler_count > best.?.handler_count)) best = c;
    }
    return best;
}

/// Where a new handler goes: a struct in a file (either may not exist yet).
pub const Target = struct {
    file: []const u8,
    container: []const u8,
    /// The UI document it is for, named in a new file's header comment.
    doc: []const u8 = "",
};

/// `main_window` -> `MainWindow`, `untitled-1` -> `Untitled1` (a valid type name).
pub fn pascalCase(a: Allocator, s: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    try capitalized(a, s, &out);
    if (out.items.len == 0 or std.ascii.isDigit(out.items[0])) try out.insert(a, 0, 'U');
    return out.items;
}

/// The Zig file that goes with a UI document: `ui/main.ui.zon` -> `ui/main.zig`
/// holding `Main`.
pub fn companionFor(a: Allocator, ui_path: []const u8) !Target {
    const base_name = std.fs.path.basename(ui_path);
    const stem = if (std.mem.endsWith(u8, base_name, ".ui.zon")) base_name[0 .. base_name.len - ".ui.zon".len] else if (std.mem.endsWith(u8, base_name, ".zon")) base_name[0 .. base_name.len - ".zon".len] else base_name;
    const dir = std.fs.path.dirname(ui_path) orelse "";
    const file = if (dir.len > 0) try std.fmt.allocPrint(a, "{s}/{s}.zig", .{ dir, stem }) else try std.fmt.allocPrint(a, "{s}.zig", .{stem});
    return .{ .file = file, .container = try pascalCase(a, stem), .doc = try a.dupe(u8, base_name) };
}

/// The text of a new handlers file (with `body` inside the struct).
pub fn newFileText(a: Allocator, t: Target, body: []const u8) ![]u8 {
    const subject = if (t.doc.len > 0) t.doc else "this project's UI documents";
    return std.fmt.allocPrint(a,
        \\//! Event handlers for {s}. The IDE adds a method to `{s}` for each "New handler"
        \\//! you create in the designer (Events tab); edit them, or move them where you like.
        \\const zigui = @import("zigui");
        \\
        \\pub const {s} = struct {{
        \\{s}}};
        \\
    , .{ subject, t.container, t.container, body });
}

/// Plan a new handler for event `event_name` of the node called `base`, in
/// `want` (if that struct or file is missing it is created) or else the default struct.
pub fn planCreate(gpa: Allocator, project: *const Project, scan_result: *const Scan, manifest: *const Manifest, base: []const u8, event_name: []const u8, want: ?Target) !Plan {
    var p: Plan = .{ .arena = std.heap.ArenaAllocator.init(gpa) };
    errdefer p.arena.deinit();
    const a = p.arena.allocator();
    const existing: ?*const Container = if (want) |w| scan_result.findContainer(w.container, w.file) else chooseTarget(scan_result, manifest);
    const goal: Target = if (want) |w| w else if (existing) |t| .{ .file = t.file, .container = t.name } else .{ .file = fallback_file, .container = fallback_container };
    const file = try a.dupe(u8, goal.file);
    const container = try a.dupe(u8, goal.container);

    // A free action name and function name.
    const action0 = try suggestAction(a, base, event_name);
    var action = action0;
    var function = try functionNameFor(a, action);
    var n: u32 = 2;
    while (nameTaken(scan_result, manifest, container, file, action, function)) : (n += 1) {
        action = try std.fmt.allocPrint(a, "{s}{d}", .{ action0, n });
        function = try functionNameFor(a, action);
    }

    var edits: std.ArrayListUnmanaged(FileEdit) = .empty;
    const bytes: ?[]u8 = project.readFile(gpa, file, 4 * 1024 * 1024) catch null;
    defer if (bytes) |b| gpa.free(b);
    if (bytes) |b| {
        const src = try gpa.dupeSentinel(u8, b, 0);
        defer gpa.free(src);
        var ast = try Ast.parse(gpa, src, .{});
        defer ast.deinit(gpa);
        const alias = zigAlias(&ast) orelse "zigui";
        if (existing) |t| {
            const body_empty = blk: {
                var i = t.close;
                while (i > 0 and (src[i - 1] == ' ' or src[i - 1] == '\n' or src[i - 1] == '\r' or src[i - 1] == '\t')) i -= 1;
                break :blk i > 0 and src[i - 1] == '{';
            };
            const stub = try stubText(a, t.indent, container, function, alias, !body_empty);
            // Before the closing brace's line when it stands alone on it.
            const ls = lineStartOf(src, t.close);
            const alone = std.mem.trim(u8, src[ls..t.close], " \t").len == 0;
            const at = if (alone) ls else t.close;
            try edits.append(a, .{ .file = file, .start = at, .end = at, .text = stub });
            if (!t.is_pub) {
                // The binding file names the struct from another file.
                const decl = declStart(&ast, container) orelse 0;
                try edits.append(a, .{ .file = file, .start = decl, .end = decl, .text = "pub " });
            }
        } else {
            // The file exists but has no such struct: add it at the end.
            const lead: []const u8 = if (src.len > 0 and src[src.len - 1] != '\n') "\n\n" else "\n";
            const text = try std.fmt.allocPrint(a, "{s}pub const {s} = struct {{\n{s}}};\n", .{ lead, container, try stubText(a, 4, container, function, alias, false) });
            try edits.append(a, .{ .file = file, .start = src.len, .end = src.len, .text = text });
        }
        if (zigAlias(&ast) == null) {
            try edits.append(a, .{ .file = file, .start = importOffset(src), .end = importOffset(src), .text = "const zigui = @import(\"zigui\");\n" });
        }
    } else {
        p.new_file = try newFileText(a, goal, try stubText(a, 4, container, function, "zigui", false));
    }
    p.edits = edits.items;
    p.action = action;
    p.container = container;
    p.function = function;
    p.file = file;
    return p;
}

/// The `pub fn` source of an empty handler.
pub fn stubText(a: Allocator, indent: usize, container: []const u8, function: []const u8, alias: []const u8, blank_before: bool) ![]u8 {
    const pad = try a.alloc(u8, indent);
    @memset(pad, ' ');
    const lead: []const u8 = if (blank_before) "\n" else "";
    return std.fmt.allocPrint(a, "{s}{s}pub fn {s}(self: *{s}, ev: *{s}.event.Event) void {{\n{s}    _ = self;\n{s}    _ = ev;\n{s}}}\n", .{ lead, pad, function, container, alias, pad, pad, pad });
}

/// Where a new `const zigui = ...` line goes: after the leading `//!` lines.
fn importOffset(src: []const u8) usize {
    var pos: usize = 0;
    while (pos < src.len) {
        const end = std.mem.indexOfScalarPos(u8, src, pos, '\n') orelse src.len;
        const line = std.mem.trim(u8, src[pos..end], " \t\r");
        if (!std.mem.startsWith(u8, line, "//!")) break;
        pos = @min(end + 1, src.len);
    }
    return pos;
}

fn declStart(ast: *const Ast, container: []const u8) ?usize {
    for (ast.rootDecls()) |d| {
        const vd = ast.fullVarDecl(d) orelse continue;
        if (std.mem.eql(u8, ast.tokenSlice(vd.ast.mut_token + 1), container)) return ast.tokenStart(vd.firstToken());
    }
    return null;
}

// ---- rename ----------------------------------------------------------------

pub const Reference = struct { file: []const u8, line: u32, text: []const u8, is_decl: bool };

/// Plan renaming handler `h` to `new_name` everywhere it is named: the
/// declaration, member accesses in its own file, and `Container.name` in files
/// that mention the container. `refs` (optional) lists what will change.
pub fn planRename(gpa: Allocator, project: *const Project, h: Handler, new_name: []const u8, refs: ?*std.ArrayListUnmanaged(Reference)) !Plan {
    if (!isIdentifier(new_name)) return error.InvalidName;
    var p: Plan = .{ .arena = std.heap.ArenaAllocator.init(gpa) };
    errdefer p.arena.deinit();
    const a = p.arena.allocator();
    var edits: std.ArrayListUnmanaged(FileEdit) = .empty;
    var files: std.ArrayListUnmanaged([]u8) = .empty;
    defer {
        for (files.items) |f| gpa.free(f);
        files.deinit(gpa);
    }
    try listZigFiles(gpa, project, &files);
    for (files.items) |rel| {
        if (std.mem.eql(u8, rel, binding_file)) continue; // regenerated, not edited
        const own = std.mem.eql(u8, rel, h.file);
        const bytes = project.readFile(gpa, rel, 4 * 1024 * 1024) catch continue;
        defer gpa.free(bytes);
        if (!own and (h.container.len == 0 or std.mem.indexOf(u8, bytes, h.container) == null)) continue;
        if (std.mem.indexOf(u8, bytes, h.name) == null) continue;
        const src = try gpa.dupeSentinel(u8, bytes, 0);
        defer gpa.free(src);
        var ast = Ast.parse(gpa, src, .{}) catch continue;
        defer ast.deinit(gpa);
        const n_tokens: u32 = @intCast(ast.tokens.len);
        var i: u32 = 0;
        while (i < n_tokens) : (i += 1) {
            if (ast.tokenTag(i) != .identifier or !std.mem.eql(u8, ast.tokenSlice(i), h.name)) continue;
            const start = ast.tokenStart(i);
            const is_decl = own and start == h.name_start;
            const after_dot = i > 0 and ast.tokenTag(i - 1) == .period;
            var qualified = false;
            if (after_dot and i > 1 and ast.tokenTag(i - 2) == .identifier) qualified = std.mem.eql(u8, ast.tokenSlice(i - 2), h.container);
            // In its own file any member access counts; elsewhere only `Container.name`.
            if (!(is_decl or (own and after_dot) or (!own and qualified))) continue;
            try edits.append(a, .{ .file = try a.dupe(u8, rel), .start = start, .end = start + h.name.len, .text = try a.dupe(u8, new_name) });
            if (refs) |r| {
                var line: u32 = 1;
                for (src[0..start]) |ch| {
                    if (ch == '\n') line += 1;
                }
                const ls = lineStartOf(src, start);
                const le = std.mem.indexOfScalarPos(u8, src, start, '\n') orelse src.len;
                try r.append(gpa, .{ .file = try gpa.dupe(u8, rel), .line = line, .text = try gpa.dupe(u8, std.mem.trim(u8, src[ls..le], " \t\r")), .is_decl = is_decl });
            }
        }
    }
    p.edits = edits.items;
    p.container = try a.dupe(u8, h.container);
    p.function = try a.dupe(u8, new_name);
    p.file = try a.dupe(u8, h.file);
    return p;
}

// ---- the service -----------------------------------------------------------

/// Called to apply edits to a file that is open in an editor. Return true if it
/// did (the editor owns the text then and should save it); false to have the
/// edits written to disk.
pub const ApplyHook = struct {
    ctx: ?*anyopaque = null,
    call: *const fn (ctx: ?*anyopaque, file: []const u8, edits: []const FileEdit) bool,
};

pub const Handlers = struct {
    gpa: Allocator,
    project: *const Project,
    manifest: Manifest,
    on_apply: ?ApplyHook = null,

    pub fn init(gpa: Allocator, project: *const Project) !Handlers {
        return .{ .gpa = gpa, .project = project, .manifest = try Manifest.load(gpa, project) };
    }

    pub fn deinit(self: *Handlers) void {
        self.manifest.deinit();
    }

    /// Apply a plan's edits (open buffers through the hook, other files on disk).
    pub fn apply(self: *Handlers, plan: *const Plan) !void {
        if (plan.new_file) |text| {
            if (std.fs.path.dirname(plan.file)) |dir| try self.project.dir.createDirPath(self.project.io, dir);
            try self.project.writeFile(plan.file, text);
        }
        var i: usize = 0;
        while (i < plan.edits.len) {
            var j = i;
            while (j < plan.edits.len and std.mem.eql(u8, plan.edits[j].file, plan.edits[i].file)) j += 1;
            const group = plan.edits[i..j];
            const file = plan.edits[i].file;
            const handled = if (self.on_apply) |h| h.call(h.ctx, file, group) else false;
            if (!handled) {
                const bytes = try self.project.readFile(self.gpa, file, 8 * 1024 * 1024);
                defer self.gpa.free(bytes);
                const out = try applyToText(self.gpa, bytes, group);
                defer self.gpa.free(out);
                try self.project.writeFile(file, out);
            }
            i = j;
        }
    }

    /// Write the manifest and regenerate `ui_actions.zig`.
    pub fn commit(self: *Handlers) !void {
        try self.manifest.save(self.project);
        const text = try generateBindings(self.gpa, &self.manifest);
        defer self.gpa.free(text);
        try self.project.writeFile(binding_file, text);
    }

    /// Make an existing handler available as an action (named after the function
    /// unless it is already bound). Returns the action name (borrowed from the manifest).
    pub fn bindExisting(self: *Handlers, h: Handler) ![]const u8 {
        if (self.manifest.actionFor(h.container, h.file, h.name)) |a| return a;
        var plan = try planBind(self.gpa, h);
        defer plan.deinit();
        try self.apply(&plan);
        var action: []const u8 = h.name;
        var buf: [128]u8 = undefined;
        var n: u32 = 2;
        while (self.manifest.find(action) != null) : (n += 1) action = std.fmt.bufPrint(&buf, "{s}{d}", .{ h.name, n }) catch return error.NameTooLong;
        try self.manifest.bind(action, h.container, h.name, h.file);
        try self.commit();
        return self.manifest.find(action).?.action;
    }

    /// Create a handler for `event_name` of the node `base` in `want` (null: the
    /// project's default struct) and bind it; returns the action name.
    pub fn create(self: *Handlers, base: []const u8, event_name: []const u8, want: ?Target) ![]const u8 {
        var sc = try scan(self.gpa, self.project);
        defer sc.deinit();
        var plan = try planCreate(self.gpa, self.project, &sc, &self.manifest, base, event_name, want);
        defer plan.deinit();
        try self.apply(&plan);
        try self.manifest.bind(plan.action, plan.container, plan.function, plan.file);
        if (want == null and self.manifest.default_container.len == 0) try self.manifest.setDefault(plan.container, plan.file);
        try self.commit();
        return self.manifest.find(plan.action).?.action;
    }

    /// Rename a handler's function (the action name stays; documents are unaffected).
    pub fn rename(self: *Handlers, h: Handler, new_name: []const u8) !void {
        var plan = try planRename(self.gpa, self.project, h, new_name, null);
        defer plan.deinit();
        try self.apply(&plan);
        for (self.manifest.bindings.items) |*b| {
            if (std.mem.eql(u8, b.function, h.name) and std.mem.eql(u8, b.container, h.container) and std.mem.eql(u8, b.file, h.file)) {
                b.function = try self.manifest.arena.allocator().dupe(u8, new_name);
            }
        }
        try self.commit();
    }
};

// ---- tests -----------------------------------------------------------------

const testing = std.testing;

fn demoProject(tmp: *testing.TmpDir) !Project {
    const io = testing.io;
    try tmp.dir.createDirPath(io, "src");
    try tmp.dir.writeFile(io, .{ .sub_path = "src/main.zig", .data =
        \\//! The app.
        \\const std = @import("std");
        \\const zigui = @import("zigui");
        \\
        \\pub const App = struct {
        \\    count: u32 = 0,
        \\
        \\    pub fn onSave(self: *App, ev: *zigui.event.Event) void {
        \\        _ = ev;
        \\        self.count += 1;
        \\    }
        \\
        \\    fn onHidden(self: *App, ev: *zigui.Event) void {
        \\        _ = self;
        \\        _ = ev;
        \\    }
        \\
        \\    pub fn notAHandler(self: *App, x: u32) void {
        \\        _ = self;
        \\        _ = x;
        \\    }
        \\
        \\    pub fn run(self: *App) void {
        \\        self.onSave(undefined);
        \\    }
        \\};
        \\
        \\pub fn onFree(ev: *zigui.event.Event) void {
        \\    _ = ev;
        \\}
        \\
        \\const Private = struct {
        \\    fn onP(self: *Private, ev: *zigui.event.Event) void {
        \\        _ = self;
        \\        _ = ev;
        \\    }
        \\};
    });
    try tmp.dir.writeFile(io, .{ .sub_path = "src/other.zig", .data =
        \\const main = @import("main.zig");
        \\const App = main.App;
        \\fn go(app: *App) void {
        \\    app.onSave(undefined);
        \\    App.onSave(app, undefined);
        \\    const unrelated = .{ .onSave = 1 };
        \\    _ = unrelated;
        \\}
    });
    const dir = try tmp.dir.openDir(io, ".", .{ .iterate = true });
    return Project.fromDir(testing.allocator, io, dir);
}

test "discovery finds handler-shaped functions with their containers" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var p = try demoProject(&tmp);
    defer p.close();
    var sc = try scan(testing.allocator, &p);
    defer sc.deinit();
    try testing.expectEqual(@as(usize, 4), sc.handlers.len); // onSave, onHidden, onFree, onP
    const i = sc.findHandler("App", "src/main.zig", "onSave").?;
    try testing.expect(sc.handlers[i].is_pub and sc.handlers[i].takes_self and sc.handlers[i].container_pub);
    try testing.expectEqual(@as(u32, 8), sc.handlers[i].line);
    const hid = sc.handlers[sc.findHandler("App", "src/main.zig", "onHidden").?];
    try testing.expect(!hid.is_pub); // `*zigui.Event` is accepted too
    const free = sc.handlers[sc.findHandler("", "src/main.zig", "onFree").?];
    try testing.expect(!free.takes_self);
    try testing.expect(sc.findHandler("App", "src/main.zig", "notAHandler") == null);
    try testing.expect(sc.findHandler("App", "src/main.zig", "run") == null);
    const private = sc.handlers[sc.findHandler("Private", "src/main.zig", "onP").?];
    try testing.expect(!private.container_pub);
    try testing.expectEqual(@as(u32, 2), sc.findContainer("App", "src/main.zig").?.handler_count);
}

test "the manifest round-trips and the binding file registers each action" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var p = try demoProject(&tmp);
    defer p.close();
    var m = Manifest.init(testing.allocator);
    defer m.deinit();
    try m.bind("save", "App", "onSave", "src/main.zig");
    try m.bind("free", "", "onFree", "src/main.zig");
    try m.bind("quote\"d", "MainWindow", "onX", "src/win.zig");
    try m.setDefault("App", "src/main.zig");
    try m.save(&p);
    var back = try Manifest.load(testing.allocator, &p);
    defer back.deinit();
    try testing.expectEqual(@as(usize, 3), back.bindings.items.len);
    try testing.expectEqualStrings("onSave", back.find("save").?.function);
    try testing.expectEqualStrings("App", back.default_container);
    try testing.expectEqualStrings("onX", back.find("quote\"d").?.function);
    try testing.expectEqualStrings("save", back.actionFor("App", "src/main.zig", "onSave").?);

    const text = try generateBindings(testing.allocator, &m);
    defer testing.allocator.free(text);
    try testing.expect(std.mem.indexOf(u8, text, "Generated by the zigui IDE") != null);
    try testing.expect(std.mem.indexOf(u8, text, "const f0 = @import(\"src/main.zig\");") != null);
    try testing.expect(std.mem.indexOf(u8, text, "app: *f0.App,") != null);
    try testing.expect(std.mem.indexOf(u8, text, "main_window: *f1.MainWindow,") != null);
    try testing.expect(std.mem.indexOf(u8, text, "try actions.put(gpa, \"save\", zigui.event.Callback.bind(ctx.app, f0.App.onSave));") != null);
    try testing.expect(std.mem.indexOf(u8, text, "zigui.event.Callback.fromFn(f0.onFree)") != null);
    // The generated text is itself valid Zig.
    const src = try testing.allocator.dupeSentinel(u8, text, 0);
    defer testing.allocator.free(src);
    var ast = try Ast.parse(testing.allocator, src, .{});
    defer ast.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), ast.errors.len);
    // An empty manifest still produces valid Zig.
    var empty = Manifest.init(testing.allocator);
    defer empty.deinit();
    const e = try generateBindings(testing.allocator, &empty);
    defer testing.allocator.free(e);
    const esrc = try testing.allocator.dupeSentinel(u8, e, 0);
    defer testing.allocator.free(esrc);
    var east = try Ast.parse(testing.allocator, esrc, .{});
    defer east.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), east.errors.len);
}

test "names: actions, functions and identifiers" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("okButtonClick", try suggestAction(a, "ok_button", "click"));
    try testing.expectEqualStrings("saveClick", try suggestAction(a, "Save", "click"));
    try testing.expectEqualStrings("x1Change", try suggestAction(a, "1", "change"));
    try testing.expectEqualStrings("buttonClick", try suggestAction(a, "", "button_click"));
    try testing.expectEqualStrings("onOkButtonClick", try functionNameFor(a, "okButtonClick"));
    try testing.expect(isIdentifier("onSave") and isIdentifier("_x1"));
    try testing.expect(!isIdentifier("") and !isIdentifier("1x") and !isIdentifier("a-b") and !isIdentifier("fn") and !isIdentifier("with space"));
    try testing.expectEqualStrings("main_window", try snakeCase(a, "MainWindow"));
    try testing.expectEqualStrings("app", try snakeCase(a, "App"));
}

test "creating a handler adds a stub to the busiest struct, binds it and regenerates the binding file" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var p = try demoProject(&tmp);
    defer p.close();
    var h = try Handlers.init(testing.allocator, &p);
    defer h.deinit();
    const action = try h.create("ok_button", "click", null);
    try testing.expectEqualStrings("okButtonClick", action);
    const main = try p.readFile(testing.allocator, "src/main.zig", 1 << 20);
    defer testing.allocator.free(main);
    try testing.expect(std.mem.indexOf(u8, main, "    pub fn onOkButtonClick(self: *App, ev: *zigui.event.Event) void {\n        _ = self;\n        _ = ev;\n    }\n};") != null);
    // The file still parses and the new function is found.
    var sc = try scan(testing.allocator, &p);
    defer sc.deinit();
    try testing.expect(sc.findHandler("App", "src/main.zig", "onOkButtonClick") != null);
    // Manifest and binding file are on disk.
    var m = try Manifest.load(testing.allocator, &p);
    defer m.deinit();
    try testing.expectEqualStrings("onOkButtonClick", m.find("okButtonClick").?.function);
    try testing.expectEqualStrings("App", m.default_container);
    const gen = try p.readFile(testing.allocator, binding_file, 1 << 20);
    defer testing.allocator.free(gen);
    try testing.expect(std.mem.indexOf(u8, gen, "f0.App.onOkButtonClick") != null);
    // A second request for the same widget and event gets a fresh name.
    const again = try h.create("ok_button", "click", null);
    try testing.expectEqualStrings("okButtonClick2", again);
    const main2 = try p.readFile(testing.allocator, "src/main.zig", 1 << 20);
    defer testing.allocator.free(main2);
    try testing.expect(std.mem.indexOf(u8, main2, "onOkButtonClick2(") != null);
}

test "with no struct to put it in, a handlers file is created" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "main.zig", .data = "pub fn main() void {}\n" });
    const dir = try tmp.dir.openDir(testing.io, ".", .{ .iterate = true });
    var p = try Project.fromDir(testing.allocator, testing.io, dir);
    defer p.close();
    var h = try Handlers.init(testing.allocator, &p);
    defer h.deinit();
    const action = try h.create("go", "click", null);
    try testing.expectEqualStrings("goClick", action);
    const text = try p.readFile(testing.allocator, fallback_file, 1 << 20);
    defer testing.allocator.free(text);
    try testing.expect(std.mem.indexOf(u8, text, "pub const Handlers = struct {") != null);
    try testing.expect(std.mem.indexOf(u8, text, "pub fn onGoClick(self: *Handlers, ev: *zigui.event.Event) void {") != null);
    var sc = try scan(testing.allocator, &p);
    defer sc.deinit();
    try testing.expect(sc.findHandler("Handlers", fallback_file, "onGoClick") != null);
    // Creating another one now lands in the same file.
    _ = try h.create("stop", "click", null);
    var sc2 = try scan(testing.allocator, &p);
    defer sc2.deinit();
    try testing.expectEqual(@as(u32, 2), sc2.findContainer("Handlers", fallback_file).?.handler_count);
}

test "binding an existing handler makes it and its struct public and names the action after it" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var p = try demoProject(&tmp);
    defer p.close();
    var h = try Handlers.init(testing.allocator, &p);
    defer h.deinit();
    var sc = try scan(testing.allocator, &p);
    defer sc.deinit();
    const hid = sc.handlers[sc.findHandler("App", "src/main.zig", "onHidden").?];
    const action = try h.bindExisting(hid);
    try testing.expectEqualStrings("onHidden", action);
    const main = try p.readFile(testing.allocator, "src/main.zig", 1 << 20);
    defer testing.allocator.free(main);
    try testing.expect(std.mem.indexOf(u8, main, "    pub fn onHidden(self: *App") != null);
    // Binding again returns the same action and changes nothing.
    var sc2 = try scan(testing.allocator, &p);
    defer sc2.deinit();
    const again = try h.bindExisting(sc2.handlers[sc2.findHandler("App", "src/main.zig", "onHidden").?]);
    try testing.expectEqualStrings("onHidden", again);
    // A private struct becomes public.
    const priv = sc2.handlers[sc2.findHandler("Private", "src/main.zig", "onP").?];
    _ = try h.bindExisting(priv);
    const main2 = try p.readFile(testing.allocator, "src/main.zig", 1 << 20);
    defer testing.allocator.free(main2);
    try testing.expect(std.mem.indexOf(u8, main2, "pub const Private = struct {") != null);
}

test "renaming changes the declaration and its references, in its file and as Container.name elsewhere" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var p = try demoProject(&tmp);
    defer p.close();
    var h = try Handlers.init(testing.allocator, &p);
    defer h.deinit();
    var sc = try scan(testing.allocator, &p);
    defer sc.deinit();
    const target = sc.handlers[sc.findHandler("App", "src/main.zig", "onSave").?];
    _ = try h.bindExisting(target);

    // What it would change, before doing it.
    var refs: std.ArrayListUnmanaged(Reference) = .empty;
    defer {
        for (refs.items) |r| {
            testing.allocator.free(r.file);
            testing.allocator.free(r.text);
        }
        refs.deinit(testing.allocator);
    }
    var preview = try planRename(testing.allocator, &p, target, "onStore", &refs);
    preview.deinit();
    // main.zig: the declaration and `self.onSave(...)`; other.zig: `App.onSave(...)` only
    // (`app.onSave` is a lowercase variable of unknown type, `.onSave = 1` a field of another thing).
    try testing.expectEqual(@as(usize, 3), refs.items.len);

    try h.rename(target, "onStore");
    const main = try p.readFile(testing.allocator, "src/main.zig", 1 << 20);
    defer testing.allocator.free(main);
    try testing.expect(std.mem.indexOf(u8, main, "pub fn onStore(self: *App") != null);
    try testing.expect(std.mem.indexOf(u8, main, "self.onStore(undefined)") != null);
    try testing.expect(std.mem.indexOf(u8, main, "onSave") == null);
    const other = try p.readFile(testing.allocator, "src/other.zig", 1 << 20);
    defer testing.allocator.free(other);
    try testing.expect(std.mem.indexOf(u8, other, "App.onStore(app, undefined)") != null);
    try testing.expect(std.mem.indexOf(u8, other, "app.onSave(undefined)") != null); // untouched: type unknown
    // The manifest and binding file follow; the action name stays.
    const gen = try p.readFile(testing.allocator, binding_file, 1 << 20);
    defer testing.allocator.free(gen);
    try testing.expect(std.mem.indexOf(u8, gen, "\"onSave\", zigui.event.Callback.bind(ctx.app, f0.App.onStore)") != null);
    try testing.expectError(error.InvalidName, h.rename(sc.handlers[0], "not valid"));
}

test "an open editor buffer takes the edits instead of the disk" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var p = try demoProject(&tmp);
    defer p.close();
    var h = try Handlers.init(testing.allocator, &p);
    defer h.deinit();
    const Hook = struct {
        files: usize = 0,
        edits: usize = 0,
        fn apply(ctx: ?*anyopaque, file: []const u8, edits: []const FileEdit) bool {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            if (!std.mem.eql(u8, file, "src/main.zig")) return false;
            self.files += 1;
            self.edits += edits.len;
            return true;
        }
    };
    var hook: Hook = .{};
    h.on_apply = .{ .ctx = &hook, .call = Hook.apply };
    const before = try p.readFile(testing.allocator, "src/main.zig", 1 << 20);
    defer testing.allocator.free(before);
    _ = try h.create("x", "click", null);
    try testing.expectEqual(@as(usize, 1), hook.files);
    try testing.expect(hook.edits >= 1);
    const after = try p.readFile(testing.allocator, "src/main.zig", 1 << 20);
    defer testing.allocator.free(after);
    try testing.expectEqualStrings(before, after); // the hook owns the text, so the disk is unchanged
}

test "a companion file goes with a UI document: names, creation in an existing file, and a missing struct" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const t = try companionFor(a, "ui/main_window.ui.zon");
    try testing.expectEqualStrings("ui/main_window.zig", t.file);
    try testing.expectEqualStrings("MainWindow", t.container);
    try testing.expectEqualStrings("main_window.ui.zon", t.doc);
    const root_t = try companionFor(a, "untitled-1.ui.zon");
    try testing.expectEqualStrings("untitled-1.zig", root_t.file);
    try testing.expectEqualStrings("Untitled1", root_t.container);
    try testing.expectEqualStrings("U9lives", try pascalCase(a, "9lives"));

    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var p = try demoProject(&tmp);
    defer p.close();
    var h = try Handlers.init(testing.allocator, &p);
    defer h.deinit();
    // The file does not exist: it is created, with its directory, header and struct.
    const action = try h.create("ok", "click", t);
    try testing.expectEqualStrings("okClick", action);
    const text = try p.readFile(testing.allocator, "ui/main_window.zig", 1 << 20);
    defer testing.allocator.free(text);
    try testing.expect(std.mem.indexOf(u8, text, "//! Event handlers for main_window.ui.zon.") != null);
    try testing.expect(std.mem.indexOf(u8, text, "pub const MainWindow = struct {") != null);
    try testing.expect(std.mem.indexOf(u8, text, "pub fn onOkClick(self: *MainWindow, ev: *zigui.event.Event) void {") != null);
    // A second handler for the same document goes into the same struct.
    _ = try h.create("cancel", "click", t);
    var sc = try scan(testing.allocator, &p);
    defer sc.deinit();
    try testing.expectEqual(@as(u32, 2), sc.findContainer("MainWindow", "ui/main_window.zig").?.handler_count);
    // The project's default struct is left alone (the manifest has none from this).
    try testing.expectEqualStrings("", h.manifest.default_container);
    // A file that exists without the struct gets it appended.
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "ui/other.zig", .data = "const x = 1;" });
    const t2 = try companionFor(a, "ui/other.ui.zon");
    _ = try h.create("go", "click", t2);
    const other = try p.readFile(testing.allocator, "ui/other.zig", 1 << 20);
    defer testing.allocator.free(other);
    try testing.expect(std.mem.indexOf(u8, other, "const x = 1;\n\npub const Other = struct {\n    pub fn onGoClick(self: *Other") != null);
    try testing.expect(std.mem.indexOf(u8, other, "const zigui = @import(\"zigui\");") != null);
}
