//! Language server support for the IDE's editors, on top of the offline
//! completion: it starts a server per language when a file of that language
//! opens, keeps it in step with the text, and turns its answers into the
//! things the editor already shows.
//!
//!     const lsp = try Assist.create(&ui, io, project_root);
//!     defer lsp.destroy();
//!     try lsp.addServer(&syntax.zig, "zig", &.{"zls"});
//!     lsp.completion = completion; lsp.hover = hover; lsp.signature = signature;
//!     try completion.addProvider(lsp.completionProvider());     // etc.
//!     try lsp.attach(editor, "/abs/path/main.zig");               // when a document opens
//!     // each loop iteration:
//!     lsp.poll();
//!
//! What the server adds: diagnostics (squiggles under errors and warnings,
//! with the message on hover), completions that arrive after the offline ones
//! and join the list, hover text, parameter hints, and go to definition. If the
//! server is not installed, or exits, everything keeps working offline and
//! `statusText` says what happened. Edits are sent as the whole text a moment
//! after typing stops, and always before a request that depends on them.

const std = @import("std");
const Ui = @import("../core/ui.zig").Ui;
const TimerId = @import("../core/ui.zig").TimerId;
const event = @import("../core/event.zig");
const process = @import("../platform/process.zig");
const CodeEditor = @import("../widgets/code_editor.zig").CodeEditor;
const completion_mod = @import("../widgets/completion.zig");
const hover_mod = @import("../widgets/hover.zig");
const syntax = @import("../editor/syntax.zig");
const output_panel = @import("output_panel.zig");
const client_mod = @import("lsp/client.zig");
const results = @import("lsp/results.zig");

const Client = client_mod.Client;

const sync_delay_ms = 120;

/// Called with an absolute path and a 1-based line and column (go to definition).
pub const OpenHook = output_panel.OpenHook;

const Config = struct {
    language: *const syntax.Language,
    language_id: []u8,
    argv: [][]u8,
};

const Server = struct {
    assist: *Assist,
    config: usize,
    client: *Client,
    runner: ?*process.Runner = null,
    /// The process could not start or has exited.
    dead: bool = false,
    batch: std.ArrayListUnmanaged(process.Event) = .empty,

    fn write(ctx: ?*anyopaque, bytes: []const u8) void {
        const self: *Server = @ptrCast(@alignCast(ctx.?));
        const r = self.runner orelse return;
        r.writeStdin(bytes) catch {
            self.dead = true;
        };
    }
};

/// A request in flight whose answer needs the editor and where it was asked.
const Ask = struct {
    assist: *Assist,
    doc: *Doc,
    word_start: usize,
    callee: []u8 = &.{},
    id: u32 = 0,
};

const Doc = struct {
    ed: *CodeEditor,
    server: *Server,
    uri: []u8,
    version: u32 = 1,
    dirty: bool = false,
    timer: ?TimerId = null,
    /// Latest diagnostics, messages owned.
    diags: std.ArrayListUnmanaged(Diag) = .empty,
    comp_ask: ?*Ask = null,
    hover_ask: ?*Ask = null,
    sig_ask: ?*Ask = null,
};

const Diag = struct { start: usize, end: usize, severity: results.Severity, message: []u8 };

pub const Assist = struct {
    gpa: std.mem.Allocator,
    ui: *Ui,
    io: std.Io,
    root_uri: []u8,
    root_name: []u8,
    configs: std.ArrayListUnmanaged(Config) = .empty,
    servers: std.ArrayListUnmanaged(*Server) = .empty,
    docs: std.ArrayListUnmanaged(*Doc) = .empty,
    completion: ?*completion_mod.Completion = null,
    hover: ?*hover_mod.Hover = null,
    signature: ?*hover_mod.SignatureHelp = null,
    on_open: ?OpenHook = null,
    wake: ?*const fn () void = null,
    message: [160]u8 = undefined,
    message_len: usize = 0,

    pub fn create(ui: *Ui, io: std.Io, root_path: []const u8) !*Assist {
        const self = try ui.gpa.create(Assist);
        errdefer ui.gpa.destroy(self);
        const uri = try client_mod.fileUri(ui.gpa, root_path);
        errdefer ui.gpa.free(uri);
        const name = try ui.gpa.dupe(u8, std.fs.path.basename(root_path));
        self.* = .{ .gpa = ui.gpa, .ui = ui, .io = io, .root_uri = uri, .root_name = name };
        return self;
    }

    pub fn destroy(self: *Assist) void {
        while (self.docs.items.len > 0) self.detach(self.docs.items[0].ed);
        for (self.servers.items) |s| {
            s.client.shutdown();
            if (s.runner) |r| r.destroy();
            s.client.destroy();
            for (s.batch.items) |*e| e.deinit(self.gpa);
            s.batch.deinit(self.gpa);
            self.gpa.destroy(s);
        }
        self.servers.deinit(self.gpa);
        for (self.configs.items) |c| {
            self.gpa.free(c.language_id);
            for (c.argv) |a| self.gpa.free(a);
            self.gpa.free(c.argv);
        }
        self.configs.deinit(self.gpa);
        self.docs.deinit(self.gpa);
        self.gpa.free(self.root_uri);
        self.gpa.free(self.root_name);
        self.gpa.destroy(self);
    }

    /// Use `argv` (a command line, e.g. `{"zls"}`) as the server for files in `language`.
    pub fn addServer(self: *Assist, language: *const syntax.Language, language_id: []const u8, argv: []const []const u8) !void {
        const id = try self.gpa.dupe(u8, language_id);
        errdefer self.gpa.free(id);
        const copy = try self.gpa.alloc([]u8, argv.len);
        var n: usize = 0;
        errdefer {
            for (copy[0..n]) |a| self.gpa.free(a);
            self.gpa.free(copy);
        }
        for (argv) |a| {
            copy[n] = try self.gpa.dupe(u8, a);
            n += 1;
        }
        try self.configs.append(self.gpa, .{ .language = language, .language_id = id, .argv = copy });
    }

    /// What is going on, for a status line ("" when there is nothing to say).
    pub fn statusText(self: *const Assist) []const u8 {
        return self.message[0..self.message_len];
    }

    fn say(self: *Assist, comptime fmt: []const u8, args: anytype) void {
        const s = std.fmt.bufPrint(&self.message, fmt, args) catch self.message[0..0];
        self.message_len = s.len;
    }

    // ---- servers ----

    fn configFor(self: *Assist, language: *const syntax.Language) ?usize {
        for (self.configs.items, 0..) |c, i| {
            if (c.language == language) return i;
        }
        return null;
    }

    fn serverFor(self: *Assist, config: usize) ?*Server {
        for (self.servers.items) |s| {
            if (s.config == config) return if (s.dead) null else s;
        }
        // Start one.
        const cfg = self.configs.items[config];
        const s = self.gpa.create(Server) catch return null;
        const client = Client.create(self.gpa, .{ .ctx = s, .call = Server.write }) catch {
            self.gpa.destroy(s);
            return null;
        };
        s.* = .{ .assist = self, .config = config, .client = client };
        client.on_diagnostics = .bind(self, onDiagnostics);
        const argv: []const []const u8 = @ptrCast(cfg.argv);
        s.runner = process.Runner.start(self.gpa, self.io, .{ .argv = argv, .stdin = true, .wake = self.wake, .cwd = null }) catch |err| {
            self.say("{s} could not start ({s}); using offline completion", .{ cfg.argv[0], @errorName(err) });
            s.dead = true;
            self.servers.append(self.gpa, s) catch {};
            return null;
        };
        self.servers.append(self.gpa, s) catch return null;
        client.initialize(self.root_uri, self.root_name) catch {};
        self.say("starting {s}...", .{cfg.argv[0]});
        return s;
    }

    /// Register an already connected client for `language` (tests, or a server
    /// reached some other way than a child process). The assist owns it.
    pub fn addClient(self: *Assist, language: *const syntax.Language, language_id: []const u8, client: *Client) !void {
        try self.addServer(language, language_id, &.{"(external)"});
        const s = try self.gpa.create(Server);
        s.* = .{ .assist = self, .config = self.configs.items.len - 1, .client = client };
        client.on_diagnostics = .bind(self, onDiagnostics);
        try self.servers.append(self.gpa, s);
    }

    /// Take in whatever the servers wrote (call every loop iteration).
    pub fn poll(self: *Assist) void {
        for (self.servers.items) |s| {
            const r = s.runner orelse continue;
            r.drain(&s.batch);
            for (s.batch.items) |*e| {
                switch (e.*) {
                    .chunk => |c| switch (c.stream) {
                        .stdout => s.client.receive(c.bytes),
                        .stderr => std.log.debug("lsp: {s}", .{std.mem.trimEnd(u8, c.bytes, "\n")}),
                    },
                    .exited => |term| {
                        std.log.debug("lsp: exited {any}", .{term});
                        s.dead = true;
                        self.say("{s} exited; using offline completion", .{self.configs.items[s.config].argv[0]});
                        self.clearAllDiagnostics(s);
                    },
                }
                e.deinit(self.gpa);
            }
            s.batch.clearRetainingCapacity();
            if (!s.dead and s.client.isReady() and self.message_len > 0 and std.mem.startsWith(u8, self.statusText(), "starting")) {
                self.say("{s}: ready", .{if (s.client.server_name.len > 0) s.client.server_name else self.configs.items[s.config].argv[0]});
            }
        }
    }

    // ---- documents ----

    fn docOf(self: *Assist, ed: *CodeEditor) ?*Doc {
        for (self.docs.items) |d| if (d.ed == ed) return d;
        return null;
    }

    /// `ed` shows the file at absolute `path`: tell its language's server.
    pub fn attach(self: *Assist, ed: *CodeEditor, path: []const u8) !void {
        const lang = ed.language() orelse return;
        const cfg = self.configFor(lang) orelse return;
        const server = self.serverFor(cfg) orelse return;
        const uri = try client_mod.fileUri(self.gpa, path);
        errdefer self.gpa.free(uri);
        const d = try self.gpa.create(Doc);
        errdefer self.gpa.destroy(d);
        d.* = .{ .ed = ed, .server = server, .uri = uri };
        try self.docs.append(self.gpa, d);
        errdefer _ = self.docs.pop();
        try ed.addEditHook(event.Callback.bind(self, onEdit));
        const text = try ed.textAlloc(self.gpa);
        defer self.gpa.free(text);
        try server.client.didOpen(uri, self.configs.items[cfg].language_id, d.version, text);
    }

    /// `ed` is going away (or its file closed).
    pub fn detach(self: *Assist, ed: *CodeEditor) void {
        const i = for (self.docs.items, 0..) |d, k| {
            if (d.ed == ed) break k;
        } else return;
        const d = self.docs.swapRemove(i);
        if (d.timer) |t| self.ui.cancelTimer(t);
        for ([_]*?*Ask{ &d.comp_ask, &d.hover_ask, &d.sig_ask }) |slot| self.dropAsk(d, slot);
        if (!d.server.dead) d.server.client.didClose(d.uri) catch {};
        ed.clearDecorations(diag_owner);
        for (d.diags.items) |x| self.gpa.free(x.message);
        d.diags.deinit(self.gpa);
        ed.removeHooks(self);
        self.gpa.free(d.uri);
        self.gpa.destroy(d);
    }

    /// The file was saved.
    pub fn saved(self: *Assist, ed: *CodeEditor) void {
        const d = self.docOf(ed) orelse return;
        flushDoc(d);
        if (!d.server.dead) d.server.client.didSave(d.uri) catch {};
    }

    fn onEdit(self: *Assist, ev: *event.Event) void {
        for (self.docs.items) |d| {
            if (!d.ed.node.eql(ev.current) and !d.ed.node.eql(ev.target)) continue;
            d.dirty = true;
            if (d.timer) |t| self.ui.cancelTimer(t);
            d.timer = self.ui.setTimer(sync_delay_ms, event.Callback.bind(d, onSyncTimer)) catch null;
            return;
        }
    }

    fn onSyncTimer(d: *Doc, _: *event.Event) void {
        d.timer = null;
        flushDoc(d);
    }

    fn flushDoc(d: *Doc) void {
        if (!d.dirty or d.server.dead) return;
        const self = d.server.assist;
        d.dirty = false;
        if (d.timer) |t| {
            self.ui.cancelTimer(t);
            d.timer = null;
        }
        d.version += 1;
        const text = d.ed.textAlloc(self.gpa) catch return;
        defer self.gpa.free(text);
        d.server.client.didChange(d.uri, d.version, text) catch {};
    }

    // ---- positions ----

    fn positionOf(self: *Assist, d: *Doc, offset: usize) results.Position {
        const doc = &d.ed.core().doc;
        const line = doc.lineOfOffset(offset);
        const ls = doc.lineStart(line);
        const text = doc.range(ls, doc.lineEnd(line)) catch "";
        _ = self;
        return .{ .line = @intCast(line), .character = client_mod.characterOf(text, offset - ls, d.server.client.encoding) };
    }

    fn offsetOf(d: *Doc, pos: results.Position) usize {
        const doc = &d.ed.core().doc;
        const line = @min(pos.line, doc.lineCount() -| 1);
        const ls = doc.lineStart(line);
        const text = doc.range(ls, doc.lineEnd(line)) catch "";
        return ls + client_mod.byteColOf(text, pos.character, d.server.client.encoding);
    }

    // ---- diagnostics ----

    pub const diag_owner = 1;

    fn onDiagnostics(self: *Assist, uri: []const u8, items: []const results.Diagnostic) void {
        for (self.docs.items) |d| {
            if (!std.mem.eql(u8, d.uri, uri)) continue;
            for (d.diags.items) |x| self.gpa.free(x.message);
            d.diags.clearRetainingCapacity();
            for (items) |it| {
                const start = offsetOf(d, it.range.start);
                var end = offsetOf(d, it.range.end);
                if (end <= start) end = @min(start + 1, d.ed.core().doc.len());
                const msg = self.gpa.dupe(u8, it.message) catch continue;
                d.diags.append(self.gpa, .{ .start = start, .end = end, .severity = it.severity, .message = msg }) catch self.gpa.free(msg);
            }
            self.paintDiagnostics(d);
            return;
        }
    }

    fn paintDiagnostics(self: *Assist, d: *Doc) void {
        var decos: std.ArrayListUnmanaged(@import("../widgets/code_editor.zig").Decoration) = .empty;
        defer decos.deinit(self.gpa);
        for (d.diags.items) |x| {
            decos.append(self.gpa, .{ .start = x.start, .end = x.end, .kind = switch (x.severity) {
                .err => .error_squiggle,
                .warning => .warning_squiggle,
                else => .info_squiggle,
            } }) catch {};
        }
        std.mem.sort(@TypeOf(decos.items[0]), decos.items, {}, struct {
            fn less(_: void, a: @TypeOf(decos.items[0]), b: @TypeOf(decos.items[0])) bool {
                return a.start < b.start;
            }
        }.less);
        d.ed.setDecorations(diag_owner, decos.items) catch {};
    }

    fn clearAllDiagnostics(self: *Assist, s: *Server) void {
        for (self.docs.items) |d| {
            if (d.server != s) continue;
            for (d.diags.items) |x| self.gpa.free(x.message);
            d.diags.clearRetainingCapacity();
            d.ed.clearDecorations(diag_owner);
        }
    }

    /// Counts of errors and warnings the server reported for `ed`.
    pub fn diagnosticCounts(self: *Assist, ed: *CodeEditor) struct { errors: usize, warnings: usize } {
        var r: @TypeOf(self.diagnosticCounts(ed)) = .{ .errors = 0, .warnings = 0 };
        const d = self.docOf(ed) orelse return r;
        for (d.diags.items) |x| {
            if (x.severity == .err) r.errors += 1 else if (x.severity == .warning) r.warnings += 1;
        }
        return r;
    }

    // ---- requests ----

    fn newAsk(self: *Assist, d: *Doc, word_start: usize, callee: []const u8) ?*Ask {
        const a = self.gpa.create(Ask) catch return null;
        a.* = .{ .assist = self, .doc = d, .word_start = word_start, .callee = self.gpa.dupe(u8, callee) catch &.{} };
        return a;
    }

    fn freeAsk(self: *Assist, a: *Ask) void {
        self.gpa.free(a.callee);
        self.gpa.destroy(a);
    }

    /// Forget an unanswered request.
    fn dropAsk(self: *Assist, d: *Doc, slot: *?*Ask) void {
        const a = slot.* orelse return;
        d.server.client.cancel(a.id);
        slot.* = null;
        self.freeAsk(a);
    }

    fn ready(d: *Doc) bool {
        return !d.server.dead and d.server.client.isReady();
    }

    fn begin(self: *Assist, d: *Doc, slot: *?*Ask, method: []const u8, offset: usize, word_start: usize, callee: []const u8, comptime handler: anytype) void {
        if (d.server.dead) return;
        self.dropAsk(d, slot);
        flushDoc(d);
        const ask = self.newAsk(d, word_start, callee) orelse return;
        const id = d.server.client.positionRequest(method, d.uri, self.positionOf(d, offset), client_mod.ResponseHook.bind(ask, handler)) catch {
            self.freeAsk(ask);
            return;
        };
        ask.id = id;
        slot.* = ask;
    }

    /// Detach `ask` from its slot and return its owner doc, or null if it was superseded.
    fn finishAsk(ask: *Ask, slot: *?*Ask) bool {
        if (slot.* != ask) return false;
        slot.* = null;
        return true;
    }

    // ---- completion ----

    pub fn completionProvider(self: *Assist) completion_mod.Provider {
        return completion_mod.Provider.bind(self, complete);
    }

    fn complete(self: *Assist, req: *const completion_mod.Request, _: *completion_mod.Sink) void {
        const d = self.docOf(req.editor) orelse return;
        if (!req.explicit and req.prefix.len == 0 and !req.afterDot()) return;
        self.begin(d, &d.comp_ask, "completion", req.editor.core().primaryHead(), req.word_start, "", onCompletion);
    }

    fn onCompletion(ask: *Ask, res: *const client_mod.Response) void {
        const self = ask.assist;
        const d = ask.doc;
        const word_start = ask.word_start;
        const current = finishAsk(ask, &d.comp_ask);
        self.freeAsk(ask);
        if (!current or !res.ok) return;
        const comp = self.completion orelse return;
        const items = results.completion(res.arena, res.value) catch return;
        if (items.len == 0) return;
        const list = res.arena.alloc(completion_mod.Item, @min(items.len, 300)) catch return;
        for (list, items[0..list.len]) |*dst, it| {
            dst.* = .{ .label = it.label, .insert = it.insert, .detail = it.detail, .tag = results.kindTag(it.kind) };
        }
        comp.offer(d.ed, word_start, list);
    }

    // ---- hover ----

    pub fn hoverProvider(self: *Assist) hover_mod.HoverProvider {
        return hover_mod.HoverProvider.bind(self, hoverAt);
    }

    fn hoverAt(self: *Assist, req: *const hover_mod.HoverRequest, out: *hover_mod.Lines) void {
        const d = self.docOf(req.editor) orelse return;
        // What the server already said is wrong at this spot comes first.
        const at = req.word_start;
        for (d.diags.items) |x| {
            if (at >= x.start and at < x.end) out.add(x.message);
        }
        self.begin(d, &d.hover_ask, "hover", at, at, "", onHover);
    }

    fn onHover(ask: *Ask, res: *const client_mod.Response) void {
        const self = ask.assist;
        const d = ask.doc;
        const word_start = ask.word_start;
        const current = finishAsk(ask, &d.hover_ask);
        self.freeAsk(ask);
        if (!current or !res.ok) return;
        const h = self.hover orelse return;
        const text = (results.hover(res.arena, res.value) catch return) orelse return;
        h.offer(d.ed, word_start, text);
    }

    // ---- signature help ----

    pub fn signatureProvider(self: *Assist) hover_mod.SigProvider {
        return hover_mod.SigProvider.bind(self, signatureAt);
    }

    fn signatureAt(self: *Assist, req: *const hover_mod.SigRequest, out: *hover_mod.SigSink) void {
        const d = self.docOf(req.editor) orelse return;
        if (d.server.dead) return;
        self.begin(d, &d.sig_ask, "signatureHelp", req.editor.core().primaryHead(), 0, req.callee, onSignature);
        out.deferToOffer();
    }

    fn onSignature(ask: *Ask, res: *const client_mod.Response) void {
        const self = ask.assist;
        const d = ask.doc;
        const callee = res.arena.dupe(u8, ask.callee) catch return;
        const current = finishAsk(ask, &d.sig_ask);
        self.freeAsk(ask);
        if (!current or !res.ok) return;
        const sh = self.signature orelse return;
        const info = (results.signature(res.arena, res.value) catch return) orelse return;
        sh.offer(d.ed, callee, info.label, info.params, info.active);
    }

    // ---- go to definition ----

    /// Ask where the name at `ed`'s caret is defined and open it through `on_open`.
    pub fn gotoDefinition(self: *Assist, ed: *CodeEditor) void {
        const d = self.docOf(ed) orelse return;
        if (!ready(d)) return;
        flushDoc(d);
        const ask = self.newAsk(d, 0, "") orelse return;
        _ = d.server.client.positionRequest("definition", d.uri, self.positionOf(d, ed.core().primaryHead()), client_mod.ResponseHook.bind(ask, onDefinition)) catch {
            self.freeAsk(ask);
        };
    }

    fn onDefinition(ask: *Ask, res: *const client_mod.Response) void {
        const self = ask.assist;
        self.freeAsk(ask);
        if (!res.ok) return;
        const locs = results.locations(res.arena, res.value) catch return;
        if (locs.len == 0) return self.say("no definition found", .{});
        const path = (client_mod.pathFromUri(res.arena, locs[0].uri) catch return) orelse return;
        const hook = self.on_open orelse return;
        // Columns in the answer count in the server's units; the editor wants bytes.
        var col: u32 = locs[0].range.start.character + 1;
        for (self.docs.items) |o| {
            if (std.mem.eql(u8, o.uri, locs[0].uri)) col = @intCast(offsetOf(o, locs[0].range.start) - o.ed.core().doc.lineStart(locs[0].range.start.line) + 1);
        }
        hook.call(hook.ctx, path, locs[0].range.start.line + 1, col);
    }
};

// ---- tests -----------------------------------------------------------------

const testing = std.testing;
const Rig = @import("../core/test_rig.zig").Rig;
const jsonrpc = @import("lsp/jsonrpc.zig");

const Wire = struct {
    gpa: std.mem.Allocator,
    sent: std.ArrayListUnmanaged([]u8) = .empty,

    fn write(ctx: ?*anyopaque, bytes: []const u8) void {
        const self: *Wire = @ptrCast(@alignCast(ctx.?));
        var r: jsonrpc.Reader = .{ .gpa = self.gpa };
        defer r.deinit();
        r.push(bytes) catch return;
        while (r.next()) |body| self.sent.append(self.gpa, self.gpa.dupe(u8, body) catch return) catch {};
    }

    fn deinit(self: *Wire) void {
        for (self.sent.items) |m| self.gpa.free(m);
        self.sent.deinit(self.gpa);
    }

    /// The id of the last request whose method is `method`.
    fn idOf(self: *const Wire, method: []const u8) ?u32 {
        var i = self.sent.items.len;
        while (i > 0) {
            i -= 1;
            const m = self.sent.items[i];
            if (std.mem.indexOf(u8, m, method) == null) continue;
            const at = std.mem.indexOf(u8, m, "\"id\":") orelse continue;
            const rest = m[at + 5 ..];
            const end = std.mem.indexOfAny(u8, rest, ",}") orelse continue;
            return std.fmt.parseInt(u32, rest[0..end], 10) catch null;
        }
        return null;
    }

    fn count(self: *const Wire, needle: []const u8) usize {
        var n: usize = 0;
        for (self.sent.items) |m| if (std.mem.indexOf(u8, m, needle) != null) {
            n += 1;
        };
        return n;
    }
};

fn serve(c: *Client, comptime fmt: []const u8, args: anytype) !void {
    const body = try std.fmt.allocPrint(testing.allocator, fmt, args);
    defer testing.allocator.free(body);
    const framed = try jsonrpc.frame(testing.allocator, body);
    defer testing.allocator.free(framed);
    c.receive(framed);
}

const Opened = struct {
    path: [128]u8 = undefined,
    len: usize = 0,
    line: u32 = 0,
    col: u32 = 0,
    fn open(self: *Opened, path: []const u8, line: u32, col: u32) void {
        @memcpy(self.path[0..path.len], path);
        self.len = path.len;
        self.line = line;
        self.col = col;
    }
};

test "a server's answers become squiggles, late completions, hover text, hints and a jump" {
    const r = try Rig.init();
    defer r.deinit();
    var wire: Wire = .{ .gpa = testing.allocator };
    defer wire.deinit();
    const client = try Client.create(testing.allocator, .{ .ctx = &wire, .call = Wire.write });
    const lsp = try Assist.create(&r.ui, testing.io, "/proj");
    defer lsp.destroy();
    try lsp.addClient(&syntax.zig, "zig", client); // the assist owns it from here

    const ed = try r.ui.add(CodeEditor, r.ui.tree.root, .{ .style = .{ .grow = 1 }, .label = "t", .language = &syntax.zig });
    try ed.loadText(try r.ui.gpa.dupe(u8, "const std = @import(\"std\");\nconst x = std.mem.\nfn f() void {}\n"), true);
    r.ui.setFocus(ed.node);
    try r.frame();
    const comp = try completion_mod.Completion.create(&r.ui);
    defer comp.destroy();
    try comp.attach(ed);
    defer comp.detach(ed);
    const hv = try hover_mod.Hover.create(&r.ui);
    defer hv.destroy();
    try hv.attach(ed);
    defer hv.detach(ed);
    const sig = try hover_mod.SignatureHelp.create(&r.ui);
    defer sig.destroy();
    try sig.attach(ed);
    defer sig.detach(ed);
    lsp.completion = comp;
    lsp.hover = hv;
    lsp.signature = sig;
    try comp.addProvider(lsp.completionProvider());
    try hv.addProvider(lsp.hoverProvider());
    try sig.addProvider(lsp.signatureProvider());
    var opened: Opened = .{};
    lsp.on_open = .bind(&opened, Opened.open);

    // Handshake, then the document is announced.
    try client.initialize("file:///proj", "proj");
    try lsp.attach(ed, "/proj/src/a.zig");
    defer lsp.detach(ed);
    try serve(client, "{{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{{\"capabilities\":{{\"positionEncoding\":\"utf-8\"}}}}}}", .{});
    try testing.expectEqual(@as(usize, 1), wire.count("textDocument/didOpen"));
    try testing.expectEqual(@as(usize, 1), wire.count("\"uri\":\"file:///proj/src/a.zig\""));

    // Diagnostics: a squiggle over line 2, with its message on hover.
    try serve(client, "{{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/publishDiagnostics\",\"params\":{{\"uri\":\"file:///proj/src/a.zig\",\"diagnostics\":[{{\"range\":{{\"start\":{{\"line\":1,\"character\":10}},\"end\":{{\"line\":1,\"character\":13}}}},\"severity\":1,\"message\":\"no member named mem\"}}]}}}}", .{});
    try testing.expectEqual(@as(usize, 1), ed.decos[Assist.diag_owner].items.len);
    const sq = ed.decos[Assist.diag_owner].items[0];
    try testing.expectEqual(ed.core().doc.lineStart(1) + 10, sq.start);
    try testing.expect(sq.kind == .error_squiggle);
    try testing.expectEqual(@as(usize, 1), lsp.diagnosticCounts(ed).errors);

    // Typing sends the new text after a pause (and not before).
    ed.core().setCaret(ed.core().doc.lineEnd(1), false);
    _ = r.ui.tick(1000);
    r.ui.textInput("al");
    try testing.expectEqual(@as(usize, 0), wire.count("textDocument/didChange"));
    _ = r.ui.tick(1200);
    try testing.expectEqual(@as(usize, 1), wire.count("textDocument/didChange"));
    try testing.expect(wire.count("std.mem.al") >= 1);
    try r.frame();

    // The typing also asked for completions (after `.`-less prefix `al`); the answer joins the list.
    const cid = wire.idOf("textDocument/completion").?;
    try serve(client, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"items\":[{{\"label\":\"alignForward\",\"kind\":3,\"detail\":\"fn\"}}]}}}}", .{cid});
    try r.frame();
    try testing.expect(comp.isOpen());
    try testing.expectEqualStrings("alignForward", r.ui.popup.?.entries[0].row.label);
    r.ui.key(.escape, .{}, true, false);

    // Hover: the pointer rests on `std`; the diagnostic text is not at that spot, the server's text arrives later.
    const rect = ed.rectOfOffset(6).?;
    _ = r.ui.tick(2000);
    r.ui.pointerMove(rect.x + 2, rect.y + 5);
    _ = r.ui.tick(2500);
    const hid = wire.idOf("textDocument/hover").?;
    try serve(client, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"contents\":{{\"kind\":\"plaintext\",\"value\":\"const std: type\"}}}}}}", .{hid});
    try r.frame();
    try testing.expect(r.ui.tipOpen());
    try testing.expectEqualStrings("const std: type", r.ui.tip.?.entries[0].row.label);
    hv.hide();

    // Signature help for a call on a new line.
    ed.core().setCaret(ed.core().doc.len(), false);
    r.ui.textInput("foo(1, ");
    try r.frame();
    const sid = wire.idOf("textDocument/signatureHelp").?;
    try serve(client, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"signatures\":[{{\"label\":\"foo(a: u8, b: u8) void\",\"parameters\":[{{\"label\":[4,9]}},{{\"label\":[11,16]}}]}}],\"activeParameter\":1}}}}", .{sid});
    try r.frame();
    try testing.expect(r.ui.tipOpen());
    try testing.expectEqualStrings("foo(a: u8, b: u8) void", r.ui.tip.?.entries[0].row.label);

    // Go to definition opens the file at the answer.
    lsp.gotoDefinition(ed);
    const did = wire.idOf("textDocument/definition").?;
    try serve(client, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":[{{\"uri\":\"file:///proj/src/b.zig\",\"range\":{{\"start\":{{\"line\":9,\"character\":3}},\"end\":{{\"line\":9,\"character\":6}}}}}}]}}", .{did});
    try testing.expectEqualStrings("/proj/src/b.zig", opened.path[0..opened.len]);
    try testing.expectEqual(@as(u32, 10), opened.line);
    try testing.expectEqual(@as(u32, 4), opened.col);
}

test "files of other languages are left alone, and a server that cannot start is reported" {
    const r = try Rig.init();
    defer r.deinit();
    const lsp = try Assist.create(&r.ui, testing.io, "/proj");
    defer lsp.destroy();
    try lsp.addServer(&syntax.zig, "zig", &.{"/nonexistent/definitely-not-a-language-server"});
    const ed = try r.ui.add(CodeEditor, r.ui.tree.root, .{ .style = .{ .grow = 1 }, .label = "t", .language = &syntax.plain });
    try r.frame();
    try lsp.attach(ed, "/proj/a.txt");
    try testing.expectEqual(@as(usize, 0), lsp.docs.items.len);
    try testing.expectEqual(@as(usize, 0), lsp.servers.items.len);
    const zed = try r.ui.add(CodeEditor, r.ui.tree.root, .{ .style = .{ .grow = 1 }, .label = "z", .language = &syntax.zig });
    try r.frame();
    try lsp.attach(zed, "/proj/a.zig");
    try testing.expectEqual(@as(usize, 0), lsp.docs.items.len);
    try testing.expect(std.mem.indexOf(u8, lsp.statusText(), "could not start") != null);
    // Asking again does not retry on every file.
    try lsp.attach(zed, "/proj/b.zig");
    try testing.expectEqual(@as(usize, 1), lsp.servers.items.len);
}
