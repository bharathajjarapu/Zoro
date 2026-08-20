const std = @import("std");
const config = @import("config.zig");
const Db = @import("db.zig").Db;
const memory = @import("memory.zig");
const skills = @import("skills.zig");
const tools = @import("tools.zig");
const web = @import("web.zig");
const secrets = @import("secrets.zig");
const testing = std.testing;

const log = std.log.scoped(.agent);

pub const max_rounds: usize = 32;
pub const max_tool_result: usize = tools.max_result;
const max_history: usize = 40;
const max_memories: usize = 8;
const max_http_body: usize = 2 * 1024 * 1024;
pub const default_base_url = "https://api.openai.com/v1";

pub const system_prompt =
    \\You are Zoro, a personal assistant for one owner. Speak briefly in plain
    \\text like a helpful colleague. Prefer short answers. Use tools when they
    \\help; otherwise just answer.
;

/// Injected HTTP seam for the OpenAI-compatible chat call. Production uses
/// `stdHttp`; tests use a fake that returns canned JSON.
pub const Http = struct {
    ptr: *anyopaque,
    post_fn: *const fn (*anyopaque, std.mem.Allocator, Request) anyerror!Response,

    pub const Request = struct {
        url: []const u8,
        auth: []const u8,
        body: []const u8,
    };

    pub const Response = struct {
        status: u16,
        body: []u8,

        pub fn deinit(self: *Response, gpa: std.mem.Allocator) void {
            gpa.free(self.body);
            self.* = undefined;
        }
    };

    pub fn post(self: Http, gpa: std.mem.Allocator, req: Request) anyerror!Response {
        return self.post_fn(self.ptr, gpa, req);
    }
};

/// A tool the loop can call. Defined in `tools.zig`; this alias keeps call
/// sites in this file short.
pub const Tool = tools.Def;

pub const Agent = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    db: *Db,
    http: Http,
    api_key: config.Secret,
    base_url: []const u8,
    model: []const u8,
    tools: []const Tool = &.{},
    skills_dir: []const u8 = "skills",
    fetch: ?web.Get = null,
    limiter: web.Limiter = .{},

    /// Caller owns the returned reply.
    pub fn turn(self: *Agent, input: []const u8) ![]u8 {
        const now = std.Io.Timestamp.now(self.io, .real).toSeconds();
        try insertMsg(self.db, "user", input, now);

        var arena_inst = std.heap.ArenaAllocator.init(self.gpa);
        defer arena_inst.deinit();
        const arena = arena_inst.allocator();

        var messages: std.ArrayList(Msg) = .empty;
        try messages.append(arena, .{ .role = "system", .content = try withContext(arena, self, input, now) });
        try loadHistory(self.db, arena, &messages);
        // loadHistory already includes the user row we just wrote.

        const endpoint = try chatUrl(arena, self.base_url);
        const auth = try std.fmt.allocPrint(arena, "Bearer {s}", .{self.api_key.reveal()});

        var round: usize = 0;
        while (true) {
            // Cap before the next model call so we never spend a 33rd completion.
            if (round >= max_rounds) {
                const blocker = "I hit the tool-round limit (32) and stopped. Tell me how to continue.";
                const reply = try self.gpa.dupe(u8, blocker);
                errdefer self.gpa.free(reply);
                try insertMsg(self.db, "assistant", reply, now);
                return reply;
            }

            const body = try buildRequest(arena, self.model, messages.items, self.tools);
            var res = try self.http.post(self.gpa, .{
                .url = endpoint,
                .auth = auth,
                .body = body,
            });
            defer res.deinit(self.gpa);

            if (res.status != 200) {
                log.err("chat HTTP {d}", .{res.status});
                return error.ChatHttp;
            }

            var parsed = try parseAssistant(self.gpa, res.body);
            defer parsed.deinit(self.gpa);

            if (parsed.tool_calls.len == 0) {
                const reply = try self.gpa.dupe(u8, parsed.content orelse "");
                errdefer self.gpa.free(reply);
                try insertMsg(self.db, "assistant", reply, now);
                return reply;
            }

            const calls = try dupeCalls(arena, parsed.tool_calls);
            try messages.append(arena, .{
                .role = "assistant",
                .content = try arena.dupe(u8, parsed.content orelse ""),
                .tool_calls = calls,
            });

            for (calls) |call| {
                var ctx: tools.Ctx = .{
                    .gpa = self.gpa,
                    .io = self.io,
                    .db = self.db,
                    .skills_dir = self.skills_dir,
                    .fetch = self.fetch,
                    .limiter = &self.limiter,
                };
                const raw = try tools.call(&ctx, self.tools, call.name, call.arguments);
                defer self.gpa.free(raw);
                const owned = try arena.dupe(u8, raw);
                // Tool rows stay in-memory for this turn. Persisting them without
                // tool_call metadata would break history reload; diary ticket owns that.
                try messages.append(arena, .{
                    .role = "tool",
                    .content = owned,
                    .tool_call_id = try arena.dupe(u8, call.id),
                });
            }
            round += 1;
        }
    }
};

const Msg = struct {
    role: []const u8,
    content: []const u8,
    tool_calls: []const ToolCall = &.{},
    tool_call_id: ?[]const u8 = null,
};

const ToolCall = struct {
    id: []const u8,
    name: []const u8,
    arguments: []const u8,
};

fn chatUrl(arena: std.mem.Allocator, base: []const u8) ![]const u8 {
    const trimmed = std.mem.trimEnd(u8, base, "/");
    if (std.mem.endsWith(u8, trimmed, "/chat/completions")) {
        return try arena.dupe(u8, trimmed);
    }
    return try std.fmt.allocPrint(arena, "{s}/chat/completions", .{trimmed});
}

fn insertMsg(db: *Db, role: []const u8, content: []const u8, created: i64) !void {
    var q = try db.prepare("INSERT INTO messages(role, content, created) VALUES (?, ?, ?)");
    defer q.finalize();
    try q.bind(1, role);
    try q.bind(2, content);
    try q.bind(3, created);
    _ = try q.step();
}

/// Top-N BM25 hits for this message, compacted onto the system prompt.
/// Empty search → the static prompt unchanged.
fn withContext(arena: std.mem.Allocator, self: *Agent, query: []const u8, now: i64) ![]const u8 {
    const hits = try memory.searchAny(self.db, arena, query, now, max_memories);
    const skill_index = skills.list(arena, self.io, self.skills_dir) catch &.{};
    const secret_names = secrets.names(self.db, arena) catch &.{};

    if (hits.len == 0 and skill_index.len == 0 and secret_names.len == 0) return system_prompt;

    var buf: std.Io.Writer.Allocating = .init(arena);
    var w = &buf.writer;
    try w.writeAll(system_prompt);
    if (hits.len != 0) {
        try w.writeAll("\n\n## memory\n");
        for (hits) |h| {
            try w.writeAll(h.ref);
            try w.writeAll(": ");
            try w.writeAll(h.text);
            try w.writeByte('\n');
        }
    }
    if (skill_index.len != 0) {
        try w.writeAll("\n\n## skills\n");
        for (skill_index) |s| {
            try w.print("- {s}: {s}\n", .{ s.name, s.description });
        }
    }
    if (secret_names.len != 0) {
        try w.writeAll("\n\n## secrets\n");
        for (secret_names) |n| {
            try w.print("- {s}\n", .{n});
        }
    }
    return try buf.toOwnedSlice();
}

/// Loads the newest `max_history` user/assistant rows (oldest first). Tool
/// rows stay in the DB for the diary but are skipped here — reconstructing
/// tool_calls from plain content is not worth it until the diary needs them.
fn loadHistory(db: *Db, arena: std.mem.Allocator, out: *std.ArrayList(Msg)) !void {
    var q = try db.prepare(
        \\SELECT role, content FROM (
        \\  SELECT role, content, id FROM messages
        \\  WHERE role IN ('user', 'assistant')
        \\  ORDER BY id DESC LIMIT ?
        \\) ORDER BY id ASC
    );
    defer q.finalize();
    try q.bind(1, @as(i64, @intCast(max_history)));

    while (try q.step()) {
        try out.append(arena, .{
            .role = try arena.dupe(u8, q.text(0)),
            .content = try arena.dupe(u8, q.text(1)),
        });
    }
}

fn dupeCalls(arena: std.mem.Allocator, calls: []const ToolCall) ![]ToolCall {
    const out = try arena.alloc(ToolCall, calls.len);
    for (calls, out) |c, *o| {
        o.* = .{
            .id = try arena.dupe(u8, c.id),
            .name = try arena.dupe(u8, c.name),
            .arguments = try arena.dupe(u8, c.arguments),
        };
    }
    return out;
}

fn buildRequest(arena: std.mem.Allocator, model: []const u8, messages: []const Msg, tool_list: []const Tool) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    var w = &out.writer;

    try w.writeAll("{\"model\":");
    try writeJsonString(w, model);
    try w.writeAll(",\"messages\":[");
    for (messages, 0..) |m, i| {
        if (i != 0) try w.writeByte(',');
        try w.writeAll("{\"role\":");
        try writeJsonString(w, m.role);
        try w.writeAll(",\"content\":");
        try writeJsonString(w, m.content);
        if (m.tool_calls.len != 0) {
            try w.writeAll(",\"tool_calls\":[");
            for (m.tool_calls, 0..) |tc, j| {
                if (j != 0) try w.writeByte(',');
                try w.writeAll("{\"id\":");
                try writeJsonString(w, tc.id);
                try w.writeAll(",\"type\":\"function\",\"function\":{\"name\":");
                try writeJsonString(w, tc.name);
                try w.writeAll(",\"arguments\":");
                try writeJsonString(w, tc.arguments);
                try w.writeAll("}}");
            }
            try w.writeByte(']');
        }
        if (m.tool_call_id) |id| {
            try w.writeAll(",\"tool_call_id\":");
            try writeJsonString(w, id);
        }
        try w.writeByte('}');
    }
    try w.writeByte(']');

    if (tool_list.len != 0) {
        try w.writeAll(",\"tools\":[");
        for (tool_list, 0..) |t, i| {
            if (i != 0) try w.writeByte(',');
            try w.writeAll("{\"type\":\"function\",\"function\":{\"name\":");
            try writeJsonString(w, t.name);
            try w.writeAll(",\"description\":");
            try writeJsonString(w, t.description);
            try w.writeAll(",\"parameters\":");
            try tools.writeSchema(w, t);
            try w.writeAll("}}");
        }
        try w.writeAll("],\"tool_choice\":\"auto\"");
    }
    try w.writeByte('}');
    return try out.toOwnedSlice();
}

fn writeJsonString(w: *std.Io.Writer, s: []const u8) !void {
    try std.json.Stringify.encodeJsonString(s, .{}, w);
}

const Parsed = struct {
    content: ?[]u8,
    tool_calls: []ToolCall,

    fn deinit(self: *Parsed, gpa: std.mem.Allocator) void {
        if (self.content) |c| gpa.free(c);
        for (self.tool_calls) |tc| {
            gpa.free(tc.id);
            gpa.free(tc.name);
            gpa.free(tc.arguments);
        }
        gpa.free(self.tool_calls);
        self.* = undefined;
    }
};

fn parseAssistant(gpa: std.mem.Allocator, body: []const u8) !Parsed {
    const Response = struct {
        choices: []const struct {
            message: struct {
                content: ?[]const u8 = null,
                tool_calls: ?[]const struct {
                    id: []const u8 = "",
                    type: []const u8 = "",
                    function: ?struct {
                        name: []const u8 = "",
                        arguments: ?[]const u8 = null,
                    } = null,
                } = null,
            } = .{},
        } = &.{},
    };

    const tree = std.json.parseFromSlice(Response, gpa, body, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch return error.BadResponse;
    defer tree.deinit();

    if (tree.value.choices.len == 0) return error.BadResponse;
    const msg = tree.value.choices[0].message;

    var content: ?[]u8 = null;
    errdefer if (content) |c| gpa.free(c);
    if (msg.content) |c| content = try gpa.dupe(u8, c);

    var calls: std.ArrayList(ToolCall) = .empty;
    errdefer {
        for (calls.items) |tc| {
            gpa.free(tc.id);
            gpa.free(tc.name);
            gpa.free(tc.arguments);
        }
        calls.deinit(gpa);
    }

    if (msg.tool_calls) |arr| {
        for (arr) |tc| {
            if (!std.mem.eql(u8, tc.type, "function")) continue;
            const fn_obj = tc.function orelse continue;
            if (tc.id.len == 0 or fn_obj.name.len == 0) continue;
            const args = fn_obj.arguments orelse continue;
            if (args.len == 0) continue;
            try calls.append(gpa, .{
                .id = try gpa.dupe(u8, tc.id),
                .name = try gpa.dupe(u8, fn_obj.name),
                .arguments = try gpa.dupe(u8, args),
            });
        }
    }

    return .{
        .content = content,
        .tool_calls = try calls.toOwnedSlice(gpa),
    };
}

/// Production HTTP client over `std.http.Client`.
pub const StdHttp = struct {
    client: std.http.Client,

    pub fn init(gpa: std.mem.Allocator, io: std.Io) StdHttp {
        return .{ .client = .{ .allocator = gpa, .io = io } };
    }

    pub fn deinit(self: *StdHttp) void {
        self.client.deinit();
        self.* = undefined;
    }

    pub fn http(self: *StdHttp) Http {
        return .{ .ptr = self, .post_fn = post };
    }

    pub fn getter(self: *StdHttp) web.Get {
        return web.fromClient(&self.client);
    }

    fn post(ptr: *anyopaque, gpa: std.mem.Allocator, req: Http.Request) anyerror!Http.Response {
        const self: *StdHttp = @ptrCast(@alignCast(ptr));
        var cap = CappedBody.init(gpa, max_http_body);
        defer cap.deinit();

        const result = self.client.fetch(.{
            .location = .{ .url = req.url },
            .method = .POST,
            .payload = req.body,
            .headers = .{
                .authorization = .{ .override = req.auth },
                .content_type = .{ .override = "application/json" },
            },
            .response_writer = &cap.writer,
        }) catch |err| {
            if (cap.overflow) return error.ResponseTooLarge;
            return err;
        };

        return .{
            .status = @intFromEnum(result.status),
            .body = try cap.take(),
        };
    }
};

/// Stops the fetch once the response exceeds `max_http_body`.
const CappedBody = struct {
    body: std.Io.Writer.Allocating,
    writer: std.Io.Writer,
    max: usize,
    overflow: bool = false,
    taken: bool = false,

    fn init(gpa: std.mem.Allocator, max: usize) CappedBody {
        return .{
            .body = .init(gpa),
            .writer = .{ .buffer = &.{}, .vtable = &.{ .drain = drain } },
            .max = max,
        };
    }

    fn deinit(self: *CappedBody) void {
        if (!self.taken) self.body.deinit();
        self.* = undefined;
    }

    fn take(self: *CappedBody) ![]u8 {
        const bytes = try self.body.toOwnedSlice();
        self.taken = true;
        return bytes;
    }

    fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const self: *CappedBody = @alignCast(@fieldParentPtr("writer", w));
        if (w.end != 0) {
            self.append(w.buffered()) catch {
                self.overflow = true;
                return error.WriteFailed;
            };
            w.end = 0;
        }
        if (data.len == 0) return 0;
        var n: usize = 0;
        for (data[0 .. data.len - 1]) |bytes| {
            self.append(bytes) catch {
                self.overflow = true;
                return error.WriteFailed;
            };
            n += bytes.len;
        }
        const last = data[data.len - 1];
        for (0..splat) |_| {
            self.append(last) catch {
                self.overflow = true;
                return error.WriteFailed;
            };
            n += last.len;
        }
        return n;
    }

    fn append(self: *CappedBody, bytes: []const u8) error{Overflow}!void {
        if (bytes.len == 0) return;
        const next = std.math.add(usize, self.body.written().len, bytes.len) catch return error.Overflow;
        if (next > self.max) return error.Overflow;
        self.body.writer.writeAll(bytes) catch return error.Overflow;
    }
};

// ── test helpers ──────────────────────────────────────────────────────────

const FakeHttp = struct {
    bodies: []const []const u8,
    i: usize = 0,
    last_body: ?[]u8 = null,
    gpa: std.mem.Allocator,

    fn http(self: *FakeHttp) Http {
        return .{ .ptr = self, .post_fn = post };
    }

    fn post(ptr: *anyopaque, gpa: std.mem.Allocator, req: Http.Request) anyerror!Http.Response {
        const self: *FakeHttp = @ptrCast(@alignCast(ptr));
        if (self.last_body) |b| gpa.free(b);
        self.last_body = try gpa.dupe(u8, req.body);
        if (self.i >= self.bodies.len) return error.TooManyCalls;
        const body = try gpa.dupe(u8, self.bodies[self.i]);
        self.i += 1;
        return .{ .status = 200, .body = body };
    }

    fn deinit(self: *FakeHttp) void {
        if (self.last_body) |b| self.gpa.free(b);
        self.* = undefined;
    }
};

fn openTmpDb(tmp: *testing.TmpDir, buf: []u8) !Db {
    const path = try std.fmt.bufPrintZ(buf, ".zig-cache/tmp/{s}/zoro.db", .{tmp.sub_path});
    var db = try Db.open(path);
    errdefer db.close();
    try db.migrate();
    return db;
}

test "turn returns the stubbed assistant reply" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [128]u8 = undefined;

    var fake: FakeHttp = .{
        .bodies = &.{"{\"choices\":[{\"message\":{\"role\":\"assistant\",\"content\":\"hello back\"}}]}"},
        .gpa = testing.allocator,
    };
    defer fake.deinit();

    var db = try openTmpDb(&tmp, &buf);
    defer db.close();

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();

    var agent: Agent = .{
        .gpa = testing.allocator,
        .io = threaded.io(),
        .db = &db,
        .http = fake.http(),
        .api_key = .init("test-key"),
        .base_url = default_base_url,
        .model = "test-model",
    };

    const reply = try agent.turn("hello");
    defer testing.allocator.free(reply);
    try testing.expectEqualStrings("hello back", reply);
}

test "turn persists user and assistant messages" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [128]u8 = undefined;

    var fake: FakeHttp = .{
        .bodies = &.{"{\"choices\":[{\"message\":{\"content\":\"hi\"}}]}"},
        .gpa = testing.allocator,
    };
    defer fake.deinit();

    var db = try openTmpDb(&tmp, &buf);
    defer db.close();

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();

    var agent: Agent = .{
        .gpa = testing.allocator,
        .io = threaded.io(),
        .db = &db,
        .http = fake.http(),
        .api_key = .init("k"),
        .base_url = default_base_url,
        .model = "m",
    };

    const reply = try agent.turn("ping");
    defer testing.allocator.free(reply);

    var q = try db.prepare("SELECT role, content FROM messages ORDER BY id");
    defer q.finalize();
    try testing.expect(try q.step());
    try testing.expectEqualStrings("user", q.text(0));
    try testing.expectEqualStrings("ping", q.text(1));
    try testing.expect(try q.step());
    try testing.expectEqualStrings("assistant", q.text(0));
    try testing.expectEqualStrings("hi", q.text(1));
    try testing.expect(!try q.step());
}

fn echoTool(ctx: *tools.Ctx, args: []const u8) anyerror![]u8 {
    return try ctx.gpa.dupe(u8, args);
}

fn bigTool(ctx: *tools.Ctx, _: []const u8) anyerror![]u8 {
    const n = max_tool_result + 100;
    const out = try ctx.gpa.alloc(u8, n);
    @memset(out, 'x');
    return out;
}

const tool_call_body =
    \\{"choices":[{"message":{"tool_calls":[{"id":"c1","type":"function","function":{"name":"echo","arguments":"{}"}}]}}]}
;

test "tool loop stops at 32 rounds and reports the blocker" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [128]u8 = undefined;

    // 32 model responses that keep asking for tools: each runs one tool round,
    // then the loop hits the cap before a 33rd completion.
    var bodies: [32][]const u8 = undefined;
    for (&bodies) |*b| b.* = tool_call_body;

    var fake: FakeHttp = .{ .bodies = &bodies, .gpa = testing.allocator };
    defer fake.deinit();

    var db = try openTmpDb(&tmp, &buf);
    defer db.close();

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();

    const tools_echo = [_]Tool{.{ .name = "echo", .description = "echo", .params = &.{}, .run = echoTool }};
    var agent: Agent = .{
        .gpa = testing.allocator,
        .io = threaded.io(),
        .db = &db,
        .http = fake.http(),
        .api_key = .init("k"),
        .base_url = default_base_url,
        .model = "m",
        .tools = &tools_echo,
    };

    const reply = try agent.turn("loop");
    defer testing.allocator.free(reply);
    try testing.expect(std.mem.indexOf(u8, reply, "tool-round limit") != null);
    try testing.expectEqual(@as(usize, 32), fake.i);
}

test "tool results truncate at 64 KiB" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [128]u8 = undefined;

    const big_call =
        \\{"choices":[{"message":{"tool_calls":[{"id":"c1","type":"function","function":{"name":"big","arguments":"{}"}}]}}]}
    ;
    const final =
        \\{"choices":[{"message":{"content":"done"}}]}
    ;
    var fake: FakeHttp = .{
        .bodies = &.{ big_call, final },
        .gpa = testing.allocator,
    };
    defer fake.deinit();

    var db = try openTmpDb(&tmp, &buf);
    defer db.close();

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();

    const tools_big = [_]Tool{.{ .name = "big", .description = "big", .params = &.{}, .run = bigTool }};
    var agent: Agent = .{
        .gpa = testing.allocator,
        .io = threaded.io(),
        .db = &db,
        .http = fake.http(),
        .api_key = .init("k"),
        .base_url = default_base_url,
        .model = "m",
        .tools = &tools_big,
    };

    const reply = try agent.turn("big");
    defer testing.allocator.free(reply);
    try testing.expectEqualStrings("done", reply);

    const sent = fake.last_body orelse return error.TestUnexpectedResult;
    try testing.expect(std.mem.indexOf(u8, sent, "[truncated]") != null);
}

test "agent module stays free of channel imports" {
    const src = @embedFile("agent.zig");
    // Char arrays so the forbidden tokens are not present as literals in this file.
    const a = [_]u8{ 't', 'e', 'l', 'e', 'g', 'r', 'a', 'm', '.', 'z', 'i', 'g' };
    const b = [_]u8{ '@', 'i', 'm', 'p', 'o', 'r', 't', '(', '"', 't', 'e', 'l', 'e', 'g', 'r', 'a', 'm' };
    try testing.expect(std.mem.indexOf(u8, src, &a) == null);
    try testing.expect(std.mem.indexOf(u8, src, &b) == null);
}

test "turn injects a retrieved fact relevant to the message" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [128]u8 = undefined;

    var fake: FakeHttp = .{
        .bodies = &.{"{\"choices\":[{\"message\":{\"content\":\"ok\"}}]}"},
        .gpa = testing.allocator,
    };
    defer fake.deinit();

    var db = try openTmpDb(&tmp, &buf);
    defer db.close();

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();

    try memory.put(&db, "pet", "a black cat named mittens", .owner, 1000, null);

    var agent: Agent = .{
        .gpa = testing.allocator,
        .io = threaded.io(),
        .db = &db,
        .http = fake.http(),
        .api_key = .init("k"),
        .base_url = default_base_url,
        .model = "m",
    };

    const reply = try agent.turn("tell me about mittens");
    defer testing.allocator.free(reply);

    const sent = fake.last_body orelse return error.TestUnexpectedResult;
    try testing.expect(std.mem.indexOf(u8, sent, "a black cat named mittens") != null);
}

test "turn does not inject an irrelevant memory" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [128]u8 = undefined;

    var fake: FakeHttp = .{
        .bodies = &.{"{\"choices\":[{\"message\":{\"content\":\"ok\"}}]}"},
        .gpa = testing.allocator,
    };
    defer fake.deinit();

    var db = try openTmpDb(&tmp, &buf);
    defer db.close();

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();

    try memory.put(&db, "pet", "a black cat named mittens", .owner, 1000, null);
    try memory.put(&db, "dentist", "root canal on tuesday", .owner, 1000, null);

    var agent: Agent = .{
        .gpa = testing.allocator,
        .io = threaded.io(),
        .db = &db,
        .http = fake.http(),
        .api_key = .init("k"),
        .base_url = default_base_url,
        .model = "m",
    };

    const reply = try agent.turn("tell me about mittens");
    defer testing.allocator.free(reply);

    const sent = fake.last_body orelse return error.TestUnexpectedResult;
    try testing.expect(std.mem.indexOf(u8, sent, "a black cat named mittens") != null);
    try testing.expect(std.mem.indexOf(u8, sent, "root canal on tuesday") == null);
}

test "turn uses a fact from three turns ago without restating it" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [128]u8 = undefined;

    const ok = "{\"choices\":[{\"message\":{\"content\":\"ok\"}}]}";
    var fake: FakeHttp = .{
        .bodies = &.{ ok, ok, ok, ok },
        .gpa = testing.allocator,
    };
    defer fake.deinit();

    var db = try openTmpDb(&tmp, &buf);
    defer db.close();

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();

    try memory.put(&db, "pet", "a black cat named mittens", .owner, 1000, null);

    var agent: Agent = .{
        .gpa = testing.allocator,
        .io = threaded.io(),
        .db = &db,
        .http = fake.http(),
        .api_key = .init("k"),
        .base_url = default_base_url,
        .model = "m",
    };

    for (0..3) |_| {
        const skip = try agent.turn("thanks");
        testing.allocator.free(skip);
    }

    const reply = try agent.turn("how is mittens");
    defer testing.allocator.free(reply);

    const sent = fake.last_body orelse return error.TestUnexpectedResult;
    try testing.expect(std.mem.indexOf(u8, sent, "a black cat named mittens") != null);
}

test "turn keeps injected memory and history bounded as history grows" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [128]u8 = undefined;

    var fake: FakeHttp = .{
        .bodies = &.{"{\"choices\":[{\"message\":{\"content\":\"ok\"}}]}"},
        .gpa = testing.allocator,
    };
    defer fake.deinit();

    var db = try openTmpDb(&tmp, &buf);
    defer db.close();

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();

    var i: usize = 0;
    while (i < 20) : (i += 1) {
        var key_buf: [8]u8 = undefined;
        var val_buf: [24]u8 = undefined;
        const key = try std.fmt.bufPrint(&key_buf, "k{d:0>2}", .{i});
        const val = try std.fmt.bufPrint(&val_buf, "widget spare alpha{d:0>2}", .{i});
        try memory.put(&db, key, val, .owner, 1000, null);
    }

    {
        var q = try db.prepare("INSERT INTO messages(role, content, created) VALUES ('user', 'UNIQUE_OLD_HISTORY', 1)");
        defer q.finalize();
        _ = try q.step();
    }
    i = 0;
    while (i < 50) : (i += 1) {
        var q = try db.prepare("INSERT INTO messages(role, content, created) VALUES ('user', 'filler', ?)");
        defer q.finalize();
        try q.bind(1, @as(i64, @intCast(i + 2)));
        _ = try q.step();
    }

    var agent: Agent = .{
        .gpa = testing.allocator,
        .io = threaded.io(),
        .db = &db,
        .http = fake.http(),
        .api_key = .init("k"),
        .base_url = default_base_url,
        .model = "m",
    };

    const reply = try agent.turn("widget");
    defer testing.allocator.free(reply);

    const sent = fake.last_body orelse return error.TestUnexpectedResult;
    try testing.expect(std.mem.indexOf(u8, sent, "UNIQUE_OLD_HISTORY") == null);

    var n: usize = 0;
    i = 0;
    while (i < 20) : (i += 1) {
        var needle: [10]u8 = undefined;
        const s = try std.fmt.bufPrint(&needle, "alpha{d:0>2}", .{i});
        if (std.mem.indexOf(u8, sent, s) != null) n += 1;
    }
    try testing.expect(n > 0);
    try testing.expect(n <= max_memories);
    try testing.expect(n < 20);
}

test "turn injects the skill index without the skill body" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [128]u8 = undefined;

    var fake: FakeHttp = .{
        .bodies = &.{"{\"choices\":[{\"message\":{\"content\":\"ok\"}}]}"},
        .gpa = testing.allocator,
    };
    defer fake.deinit();

    var db = try openTmpDb(&tmp, &buf);
    defer db.close();

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const dir = try std.fmt.bufPrint(&buf, ".zig-cache/tmp/{s}/skills", .{tmp.sub_path});
    _ = try skills.save(testing.allocator, io, dir,
        \\---
        \\name: weather
        \\description: Look up the forecast
        \\---
        \\
        \\SECRET_BODY_SHOULD_STAY_OFF_THE_PROMPT
    );

    var agent: Agent = .{
        .gpa = testing.allocator,
        .io = io,
        .db = &db,
        .http = fake.http(),
        .api_key = .init("k"),
        .base_url = default_base_url,
        .model = "m",
        .skills_dir = dir,
    };

    const reply = try agent.turn("hi");
    defer testing.allocator.free(reply);
    const sent = fake.last_body orelse return error.TestUnexpectedResult;
    try testing.expect(std.mem.indexOf(u8, sent, "weather") != null);
    try testing.expect(std.mem.indexOf(u8, sent, "Look up the forecast") != null);
    try testing.expect(std.mem.indexOf(u8, sent, "SECRET_BODY_SHOULD_STAY_OFF_THE_PROMPT") == null);
}

test "turn lists secret names but never their values" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [128]u8 = undefined;

    var fake: FakeHttp = .{
        .bodies = &.{"{\"choices\":[{\"message\":{\"content\":\"ok\"}}]}"},
        .gpa = testing.allocator,
    };
    defer fake.deinit();

    var db = try openTmpDb(&tmp, &buf);
    defer db.close();

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();

    try secrets.put(&db, "weather_api_key", "sk-secret-value", "api.weather.com", 1000);

    var agent: Agent = .{
        .gpa = testing.allocator,
        .io = threaded.io(),
        .db = &db,
        .http = fake.http(),
        .api_key = .init("k"),
        .base_url = default_base_url,
        .model = "m",
    };

    const reply = try agent.turn("hi");
    defer testing.allocator.free(reply);
    const sent = fake.last_body orelse return error.TestUnexpectedResult;
    try testing.expect(std.mem.indexOf(u8, sent, "weather_api_key") != null);
    try testing.expect(std.mem.indexOf(u8, sent, "sk-secret-value") == null);
}
