//! A language server client: the Language Server Protocol over any byte
//! transport. It does the handshake, keeps request ids and callbacks, answers
//! the requests servers make of clients, and turns notifications into hooks.
//! It knows nothing about processes or the UI (see `ide/lsp_assist.zig`).
//!
//!     const client = try Client.create(gpa, .{ .ctx = &conn, .call = Conn.write });  // write framed bytes
//!     try client.initialize(root_uri, "myproject");
//!     try client.didOpen(uri, "zig", 1, text);          // queued until the handshake is done
//!     _ = try client.request("textDocument/hover", params, .bind(&app, App.onHover));
//!     // whenever the server wrote bytes:
//!     client.receive(bytes);
//!
//! Everything runs on one thread (the UI thread feeds `receive`), so no locks.
//! Documents are synchronized in full (`didChange` carries the whole text).
//! Callbacks get parsed JSON valid only during the call.

const std = @import("std");
const jsonrpc = @import("jsonrpc.zig");
const results = @import("results.zig");

pub const Position = results.Position;
pub const Range = results.Range;

pub const Encoding = enum { utf8, utf16 };

/// Writes one framed message (header included) to the server.
pub const Send = struct {
    ctx: ?*anyopaque = null,
    call: *const fn (ctx: ?*anyopaque, bytes: []const u8) void,
};

/// A server's answer to a request.
pub const Response = struct {
    /// False when the server answered with an error (see `message`).
    ok: bool,
    /// `result` (`.null` for none).
    value: std.json.Value,
    message: []const u8 = "",
    /// For building lists while reading `value` (freed after the callback).
    arena: std.mem.Allocator,
};

pub const ResponseHook = struct {
    ctx: ?*anyopaque = null,
    call: *const fn (ctx: ?*anyopaque, res: *const Response) void,

    pub fn bind(ctx: anytype, comptime f: anytype) ResponseHook {
        const Ptr = @TypeOf(ctx);
        return .{
            .ctx = @ptrCast(ctx),
            .call = &struct {
                fn thunk(c: ?*anyopaque, res: *const Response) void {
                    f(@as(Ptr, @ptrCast(@alignCast(c.?))), res);
                }
            }.thunk,
        };
    }
};

pub const DiagnosticsHook = struct {
    ctx: ?*anyopaque = null,
    call: *const fn (ctx: ?*anyopaque, uri: []const u8, items: []const results.Diagnostic) void,

    pub fn bind(ctx: anytype, comptime f: anytype) DiagnosticsHook {
        const Ptr = @TypeOf(ctx);
        return .{
            .ctx = @ptrCast(ctx),
            .call = &struct {
                fn thunk(c: ?*anyopaque, uri: []const u8, items: []const results.Diagnostic) void {
                    f(@as(Ptr, @ptrCast(@alignCast(c.?))), uri, items);
                }
            }.thunk,
        };
    }
};

pub const State = enum { idle, initializing, ready, shutdown };

const Pending = struct { id: u32, hook: ?ResponseHook, internal: bool = false };

pub const Client = struct {
    gpa: std.mem.Allocator,
    send: Send,
    reader: jsonrpc.Reader,
    state: State = .idle,
    next_id: u32 = 1,
    pending: std.ArrayListUnmanaged(Pending) = .empty,
    /// Framed messages waiting for the handshake.
    outbox: std.ArrayListUnmanaged([]u8) = .empty,
    /// How positions' `character` counts: bytes (utf-8) or UTF-16 units.
    encoding: Encoding = .utf16,
    server_name: []u8 = &.{},
    on_diagnostics: ?DiagnosticsHook = null,
    /// Called with `window/showMessage` and `window/logMessage` text.
    on_message: ?*const fn (ctx: ?*anyopaque, text: []const u8) void = null,
    message_ctx: ?*anyopaque = null,

    pub fn create(gpa: std.mem.Allocator, send: Send) !*Client {
        const self = try gpa.create(Client);
        self.* = .{ .gpa = gpa, .send = send, .reader = .{ .gpa = gpa } };
        return self;
    }

    pub fn destroy(self: *Client) void {
        for (self.outbox.items) |m| self.gpa.free(m);
        self.outbox.deinit(self.gpa);
        self.pending.deinit(self.gpa);
        self.reader.deinit();
        self.gpa.free(self.server_name);
        self.gpa.destroy(self);
    }

    pub fn isReady(self: *const Client) bool {
        return self.state == .ready;
    }

    // ---- sending ----

    fn write(self: *Client, body: []const u8) void {
        const framed = jsonrpc.frame(self.gpa, body) catch return;
        defer self.gpa.free(framed);
        self.send.call(self.send.ctx, framed);
    }

    /// Send now if the handshake is done, else keep for after it.
    fn writeOrQueue(self: *Client, body: []const u8) !void {
        if (self.state == .ready) return self.write(body);
        const copy = try self.gpa.dupe(u8, body);
        errdefer self.gpa.free(copy);
        try self.outbox.append(self.gpa, copy);
    }

    fn build(self: *Client, comptime fmt: []const u8, args: anytype, params: anytype) ![]u8 {
        const p = try std.json.Stringify.valueAlloc(self.gpa, params, .{ .emit_null_optional_fields = false });
        defer self.gpa.free(p);
        return std.fmt.allocPrint(self.gpa, fmt, args ++ .{p});
    }

    /// Send a request; `hook` (optional) gets the answer. Returns its id for `cancel`.
    pub fn request(self: *Client, method: []const u8, params: anytype, hook: ?ResponseHook) !u32 {
        const id = self.next_id;
        self.next_id += 1;
        const body = try self.build("{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":\"{s}\",\"params\":{s}}}", .{ id, method }, params);
        defer self.gpa.free(body);
        try self.pending.append(self.gpa, .{ .id = id, .hook = hook });
        errdefer _ = self.pending.pop();
        try self.writeOrQueue(body);
        return id;
    }

    /// Forget a request's callback (the answer is ignored when it arrives).
    pub fn cancel(self: *Client, id: u32) void {
        for (self.pending.items) |*p| {
            if (p.id == id) p.hook = null;
        }
    }

    pub fn notify(self: *Client, method: []const u8, params: anytype) !void {
        const body = try self.build("{{\"jsonrpc\":\"2.0\",\"method\":\"{s}\",\"params\":{s}}}", .{method}, params);
        defer self.gpa.free(body);
        try self.writeOrQueue(body);
    }

    // ---- the handshake ----

    /// Begin the handshake. `root_uri` is the project folder as a `file://` URI.
    pub fn initialize(self: *Client, root_uri: []const u8, root_name: []const u8) !void {
        if (self.state != .idle) return;
        self.state = .initializing;
        const params = .{
            .processId = @as(?i64, null),
            .clientInfo = .{ .name = "zigui", .version = "0.1" },
            .rootUri = root_uri,
            .workspaceFolders = &[_]struct { uri: []const u8, name: []const u8 }{.{ .uri = root_uri, .name = root_name }},
            .capabilities = .{
                .general = .{ .positionEncodings = &[_][]const u8{ "utf-8", "utf-16" } },
                .textDocument = .{
                    .synchronization = .{ .didSave = true },
                    .completion = .{ .completionItem = .{ .snippetSupport = false, .documentationFormat = &[_][]const u8{"plaintext"} } },
                    .hover = .{ .contentFormat = &[_][]const u8{"plaintext"} },
                    .signatureHelp = .{ .signatureInformation = .{ .documentationFormat = &[_][]const u8{"plaintext"}, .parameterInformation = .{ .labelOffsetSupport = true } } },
                    .definition = .{ .linkSupport = false },
                    .publishDiagnostics = .{ .relatedInformation = false },
                },
                .window = .{ .showMessage = .{ .messageActionItem = .{ .additionalPropertiesSupport = false } } },
            },
        };
        const id = self.next_id;
        self.next_id += 1;
        const body = try self.build("{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":\"initialize\",\"params\":{s}}}", .{id}, params);
        defer self.gpa.free(body);
        try self.pending.append(self.gpa, .{ .id = id, .hook = null, .internal = true });
        self.write(body);
    }

    fn handshakeDone(self: *Client, res: std.json.Value) void {
        if (res == .object) {
            if (res.object.get("capabilities")) |caps| if (caps == .object) {
                if (caps.object.get("positionEncoding")) |pe| if (pe == .string) {
                    self.encoding = if (std.mem.eql(u8, pe.string, "utf-8")) .utf8 else .utf16;
                };
            };
            if (res.object.get("serverInfo")) |si| if (si == .object) {
                if (si.object.get("name")) |n| if (n == .string) {
                    self.server_name = self.gpa.dupe(u8, n.string) catch &.{};
                };
            };
        }
        self.state = .ready;
        self.write("{\"jsonrpc\":\"2.0\",\"method\":\"initialized\",\"params\":{}}");
        for (self.outbox.items) |m| {
            self.write(m);
            self.gpa.free(m);
        }
        self.outbox.clearRetainingCapacity();
    }

    /// Ask the server to shut down (then it should exit).
    pub fn shutdown(self: *Client) void {
        if (self.state != .ready) return;
        self.state = .shutdown;
        const id = self.next_id;
        self.next_id += 1;
        var buf: [96]u8 = undefined;
        self.write(std.fmt.bufPrint(&buf, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":\"shutdown\"}}", .{id}) catch return);
        self.write("{\"jsonrpc\":\"2.0\",\"method\":\"exit\"}");
    }

    // ---- documents ----

    const DocId = struct { uri: []const u8 };

    pub fn didOpen(self: *Client, uri: []const u8, language_id: []const u8, version: u32, text: []const u8) !void {
        try self.notify("textDocument/didOpen", .{ .textDocument = .{ .uri = uri, .languageId = language_id, .version = version, .text = text } });
    }

    /// The whole new text (full synchronization).
    pub fn didChange(self: *Client, uri: []const u8, version: u32, text: []const u8) !void {
        try self.notify("textDocument/didChange", .{
            .textDocument = .{ .uri = uri, .version = version },
            .contentChanges = &[_]struct { text: []const u8 }{.{ .text = text }},
        });
    }

    pub fn didSave(self: *Client, uri: []const u8) !void {
        try self.notify("textDocument/didSave", .{ .textDocument = DocId{ .uri = uri } });
    }

    pub fn didClose(self: *Client, uri: []const u8) !void {
        try self.notify("textDocument/didClose", .{ .textDocument = DocId{ .uri = uri } });
    }

    /// A request about a position: `completion`, `hover`, `signatureHelp`,
    /// `definition` (pass the method name without `textDocument/`).
    pub fn positionRequest(self: *Client, method: []const u8, uri: []const u8, pos: Position, hook: ResponseHook) !u32 {
        var buf: [64]u8 = undefined;
        const full = try std.fmt.bufPrint(&buf, "textDocument/{s}", .{method});
        return self.request(full, .{ .textDocument = DocId{ .uri = uri }, .position = pos }, hook);
    }

    // ---- receiving ----

    /// Bytes the server wrote.
    pub fn receive(self: *Client, bytes: []const u8) void {
        self.reader.push(bytes) catch return;
        while (self.reader.next()) |body| self.handle(body);
    }

    fn handle(self: *Client, body: []const u8) void {
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        const msg = std.json.parseFromSliceLeaky(std.json.Value, a, body, .{}) catch return;
        if (msg != .object) return;
        const obj = msg.object;
        const method = if (obj.get("method")) |m| (if (m == .string) m.string else null) else null;
        const id = obj.get("id");
        if (method) |mth| {
            const params = obj.get("params") orelse .null;
            if (id) |i| self.serverRequest(a, i, mth) else self.notification(a, mth, params);
            return;
        }
        const idv = id orelse return;
        if (idv != .integer) return;
        self.response(a, @intCast(idv.integer), obj);
    }

    fn response(self: *Client, a: std.mem.Allocator, id: u32, obj: std.json.ObjectMap) void {
        var found: ?Pending = null;
        for (self.pending.items, 0..) |p, i| {
            if (p.id == id) {
                found = p;
                _ = self.pending.orderedRemove(i);
                break;
            }
        }
        const p = found orelse return;
        var message: []const u8 = "";
        const ok = obj.get("error") == null;
        if (obj.get("error")) |e| if (e == .object) {
            if (e.object.get("message")) |m| if (m == .string) {
                message = m.string;
            };
        };
        const value = obj.get("result") orelse .null;
        if (p.internal) {
            if (ok) self.handshakeDone(value);
            return;
        }
        if (p.hook) |h| h.call(h.ctx, &.{ .ok = ok, .value = value, .message = message, .arena = a });
    }

    /// A request from the server: answer the ones every client must.
    fn serverRequest(self: *Client, a: std.mem.Allocator, id: std.json.Value, method: []const u8) void {
        const id_json = std.json.Stringify.valueAlloc(a, id, .{}) catch return;
        const known = std.mem.eql(u8, method, "workspace/configuration") or
            std.mem.eql(u8, method, "client/registerCapability") or
            std.mem.eql(u8, method, "client/unregisterCapability") or
            std.mem.eql(u8, method, "window/workDoneProgress/create") or
            std.mem.eql(u8, method, "workspace/workspaceFolders");
        const out = if (known)
            std.fmt.allocPrint(a, "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":null}}", .{id_json}) catch return
        else
            std.fmt.allocPrint(a, "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"error\":{{\"code\":-32601,\"message\":\"not supported\"}}}}", .{id_json}) catch return;
        self.write(out);
    }

    fn notification(self: *Client, a: std.mem.Allocator, method: []const u8, params: std.json.Value) void {
        if (std.mem.eql(u8, method, "textDocument/publishDiagnostics")) {
            const h = self.on_diagnostics orelse return;
            if (params != .object) return;
            const uri_v = params.object.get("uri") orelse return;
            if (uri_v != .string) return;
            const list = results.diagnostics(a, params.object.get("diagnostics") orelse .null) catch return;
            h.call(h.ctx, uri_v.string, list);
        } else if (std.mem.eql(u8, method, "window/showMessage") or std.mem.eql(u8, method, "window/logMessage")) {
            const f = self.on_message orelse return;
            if (params == .object) if (params.object.get("message")) |m| if (m == .string) f(self.message_ctx, m.string);
        }
    }
};

// ---- positions and URIs -----------------------------------------------------

/// The LSP `character` for byte column `byte_col` of `line`.
pub fn characterOf(line: []const u8, byte_col: usize, enc: Encoding) u32 {
    const end = @min(byte_col, line.len);
    if (enc == .utf8) return @intCast(end);
    var units: u32 = 0;
    var it = std.unicode.Utf8View.initUnchecked(line[0..end]).iterator();
    while (it.nextCodepoint()) |cp| units += if (cp >= 0x10000) 2 else 1;
    return units;
}

/// The byte column in `line` for an LSP `character` (clamped to the line).
pub fn byteColOf(line: []const u8, character: u32, enc: Encoding) usize {
    if (enc == .utf8) return @min(character, line.len);
    var units: u32 = 0;
    var i: usize = 0;
    while (i < line.len and units < character) {
        const len = std.unicode.utf8ByteSequenceLength(line[i]) catch 1;
        const n = @min(len, line.len - i);
        const cp = std.unicode.utf8Decode(line[i .. i + n]) catch 0xFFFD;
        units += if (cp >= 0x10000) 2 else 1;
        i += n;
    }
    return i;
}

/// `file://` URI for an absolute path (caller frees).
pub fn fileUri(gpa: std.mem.Allocator, path: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, "file://");
    if (path.len == 0 or path[0] != '/') try out.append(gpa, '/'); // Windows drive paths
    for (path) |c| {
        if (std.ascii.isAlphanumeric(c) or std.mem.indexOfScalar(u8, "/-._~:", c) != null) {
            try out.append(gpa, if (c == '\\') '/' else c);
        } else if (c == '\\') {
            try out.append(gpa, '/');
        } else {
            var enc: [3]u8 = undefined;
            try out.appendSlice(gpa, std.fmt.bufPrint(&enc, "%{X:0>2}", .{c}) catch unreachable);
        }
    }
    return out.toOwnedSlice(gpa);
}

/// The path in a `file://` URI (caller frees); null for other schemes.
pub fn pathFromUri(gpa: std.mem.Allocator, uri: []const u8) !?[]u8 {
    const prefix = "file://";
    if (!std.mem.startsWith(u8, uri, prefix)) return null;
    var rest = uri[prefix.len..];
    // `file:///C:/x` on Windows: drop the slash before the drive letter.
    if (rest.len >= 3 and rest[0] == '/' and rest[2] == ':') rest = rest[1..];
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(gpa);
    var i: usize = 0;
    while (i < rest.len) : (i += 1) {
        if (rest[i] == '%' and i + 2 < rest.len) {
            if (std.fmt.parseInt(u8, rest[i + 1 .. i + 3], 16)) |b| {
                try out.append(gpa, b);
                i += 2;
                continue;
            } else |_| {}
        }
        try out.append(gpa, rest[i]);
    }
    return try out.toOwnedSlice(gpa);
}

// ---- tests -----------------------------------------------------------------

const testing = std.testing;

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

    fn has(self: *const Wire, needle: []const u8) bool {
        for (self.sent.items) |m| if (std.mem.indexOf(u8, m, needle) != null) return true;
        return false;
    }

    fn send(self: *Wire) Send {
        return .{ .ctx = self, .call = write };
    }
};

fn reply(c: *Client, comptime fmt: []const u8, args: anytype) !void {
    const body = try std.fmt.allocPrint(testing.allocator, fmt, args);
    defer testing.allocator.free(body);
    const framed = try jsonrpc.frame(testing.allocator, body);
    defer testing.allocator.free(framed);
    c.receive(framed);
}

const Got = struct {
    n: u32 = 0,
    ok: bool = false,
    label: [32]u8 = undefined,
    label_len: usize = 0,
    fn onCompletion(self: *Got, res: *const Response) void {
        self.n += 1;
        self.ok = res.ok;
        const items = results.completion(res.arena, res.value) catch return;
        if (items.len > 0) {
            @memcpy(self.label[0..items[0].label.len], items[0].label);
            self.label_len = items[0].label.len;
        }
    }
};

test "handshake: initialize, then queued documents flow, answers reach hooks" {
    var wire: Wire = .{ .gpa = testing.allocator };
    defer wire.deinit();
    const c = try Client.create(testing.allocator, wire.send());
    defer c.destroy();
    try c.initialize("file:///proj", "proj");
    try testing.expect(wire.has("\"method\":\"initialize\""));
    try testing.expect(wire.has("\"positionEncodings\":[\"utf-8\",\"utf-16\"]"));
    // Opened before the server answered: held back.
    try c.didOpen("file:///proj/a.zig", "zig", 1, "const x = 1;\n");
    try testing.expect(!wire.has("didOpen"));
    try testing.expect(!c.isReady());
    try reply(c, "{{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{{\"capabilities\":{{\"positionEncoding\":\"utf-8\"}},\"serverInfo\":{{\"name\":\"fakels\"}}}}}}", .{});
    try testing.expect(c.isReady());
    try testing.expect(c.encoding == .utf8);
    try testing.expectEqualStrings("fakels", c.server_name);
    try testing.expect(wire.has("\"method\":\"initialized\""));
    try testing.expect(wire.has("\"method\":\"textDocument/didOpen\""));
    try testing.expect(wire.has("\"languageId\":\"zig\""));

    // A request and its answer.
    var got: Got = .{};
    const id = try c.positionRequest("completion", "file:///proj/a.zig", .{ .line = 0, .character = 5 }, .bind(&got, Got.onCompletion));
    try testing.expect(wire.has("\"method\":\"textDocument/completion\""));
    try testing.expect(wire.has("\"position\":{\"line\":0,\"character\":5}"));
    try reply(c, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":[{{\"label\":\"hello\"}}]}}", .{id});
    try testing.expectEqual(@as(u32, 1), got.n);
    try testing.expectEqualStrings("hello", got.label[0..got.label_len]);

    // A cancelled request is ignored; an error answer reports not-ok.
    const id2 = try c.positionRequest("completion", "file:///proj/a.zig", .{ .line = 0, .character = 5 }, .bind(&got, Got.onCompletion));
    c.cancel(id2);
    try reply(c, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":[]}}", .{id2});
    try testing.expectEqual(@as(u32, 1), got.n);
    const id3 = try c.positionRequest("completion", "file:///proj/a.zig", .{ .line = 0, .character = 0 }, .bind(&got, Got.onCompletion));
    try reply(c, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"error\":{{\"code\":-1,\"message\":\"nope\"}}}}", .{id3});
    try testing.expectEqual(@as(u32, 2), got.n);
    try testing.expect(!got.ok);

    // Document changes carry the whole text.
    try c.didChange("file:///proj/a.zig", 2, "const y = 2;\n");
    try testing.expect(wire.has("\"contentChanges\":[{\"text\":\"const y = 2;\\n\"}]"));
    try testing.expect(wire.has("\"version\":2"));
}

const Diags = struct {
    n: usize = 0,
    uri_len: usize = 0,
    first_line: u32 = 99,
    fn on(self: *Diags, uri: []const u8, items: []const results.Diagnostic) void {
        self.n = items.len;
        self.uri_len = uri.len;
        if (items.len > 0) self.first_line = items[0].range.start.line;
    }
};

test "server requests are answered and diagnostics reach the hook" {
    var wire: Wire = .{ .gpa = testing.allocator };
    defer wire.deinit();
    const c = try Client.create(testing.allocator, wire.send());
    defer c.destroy();
    var diags: Diags = .{};
    c.on_diagnostics = .bind(&diags, Diags.on);
    try c.initialize("file:///p", "p");
    try reply(c, "{{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{{}}}}", .{});
    try testing.expect(c.encoding == .utf16); // no positionEncoding: the default

    try reply(c, "{{\"jsonrpc\":\"2.0\",\"id\":7,\"method\":\"workspace/configuration\",\"params\":{{\"items\":[]}}}}", .{});
    try testing.expect(wire.has("\"id\":7,\"result\":null"));
    try reply(c, "{{\"jsonrpc\":\"2.0\",\"id\":\"abc\",\"method\":\"some/unknown\"}}", .{});
    try testing.expect(wire.has("\"id\":\"abc\",\"error\""));

    try reply(c, "{{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/publishDiagnostics\",\"params\":{{\"uri\":\"file:///p/a.zig\",\"diagnostics\":[{{\"range\":{{\"start\":{{\"line\":4,\"character\":1}},\"end\":{{\"line\":4,\"character\":3}}}},\"severity\":1,\"message\":\"bad\"}}]}}}}", .{});
    try testing.expectEqual(@as(usize, 1), diags.n);
    try testing.expectEqual(@as(u32, 4), diags.first_line);

    c.shutdown();
    try testing.expect(wire.has("\"method\":\"shutdown\""));
    try testing.expect(wire.has("\"method\":\"exit\""));
}

test "UTF-16 and UTF-8 columns convert both ways" {
    const line = "a\u{e9}\u{1F600}z"; // a, é (2 bytes, 1 unit), 😀 (4 bytes, 2 units), z
    try testing.expectEqual(@as(u32, 4), characterOf(line, line.len - 1, .utf16));
    try testing.expectEqual(@as(u32, line.len - 1), characterOf(line, line.len - 1, .utf8));
    try testing.expectEqual(@as(usize, 7), byteColOf(line, 4, .utf16)); // after the emoji
    try testing.expectEqual(@as(usize, line.len), byteColOf(line, 99, .utf16));
    try testing.expectEqual(@as(usize, 3), byteColOf(line, 3, .utf8));
    try testing.expectEqual(@as(u32, 1), characterOf(line, 1, .utf16));
}

test "file URIs encode and decode" {
    const uri = try fileUri(testing.allocator, "/home/me/my proj/a#b.zig");
    defer testing.allocator.free(uri);
    try testing.expectEqualStrings("file:///home/me/my%20proj/a%23b.zig", uri);
    const back = (try pathFromUri(testing.allocator, uri)).?;
    defer testing.allocator.free(back);
    try testing.expectEqualStrings("/home/me/my proj/a#b.zig", back);
    try testing.expect((try pathFromUri(testing.allocator, "https://x/y")) == null);
}
