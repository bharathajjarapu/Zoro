const std = @import("std");
const config = @import("../app/config.zig");
const Db = @import("../data/db.zig").Db;
const memory = @import("../data/memory.zig");
const skills = @import("../automation/skills.zig");
const tools = @import("../tools/root.zig");
const web = @import("../net/web.zig");
const secrets = @import("../data/secrets.zig");
const tasks = @import("../data/tasks.zig");
const worker = @import("worker.zig");
const testing = std.testing;
const testkit = @import("../testing/testkit.zig");
const FakeHttp = testkit.FakeHttp;

const log = std.log.scoped(.agent);

pub const max_rounds: usize = 32;
pub const max_tool_result: usize = tools.max_result;
const max_history: usize = 40;
const max_memories: usize = 8;
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
        /// Telegram wants multipart when a file rides along; everything else is JSON.
        content_type: []const u8 = "application/json",
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

/// A picture the owner sent, already downloaded and bounded by the channel.
/// `data` is raw bytes; this file base64s them into the request and never
/// stores them.
pub const Image = struct {
    mime: []const u8,
    data: []const u8,
};

/// One turn's input. `turn` takes plain text; the Telegram driver uses
/// `turnWith` when the owner sent a picture.
pub const Input = struct {
    text: []const u8,
    image: ?Image = null,
};

/// A tool the loop can call. Defined in `tools/root.zig`; this alias keeps call
/// sites in this file short.
pub const Tool = tools.Def;

/// Shared cancellation for delegated work. `worker.zig` owns the threads; the
/// agent only raises the flag and reads the count, which is why this file
/// still knows nothing about workers.
pub const Workers = struct {
    stop: std.atomic.Value(bool) = .init(false),
    live: std.atomic.Value(usize) = .init(0),
    /// One task's flag chains to the pool's, so "stop" halts everything while a
    /// single task can still be called off on its own.
    parent: ?*const Workers = null,

    pub fn cancelled(self: *const Workers) bool {
        if (self.stop.load(.acquire)) return true;
        return if (self.parent) |p| p.cancelled() else false;
    }

    pub fn count(self: *const Workers) usize {
        return self.live.load(.acquire);
    }
};

/// What one run of the loop is allowed to spend. The owner's turn takes the
/// defaults; a subagent is handed a smaller one.
pub const Budget = struct {
    tools: []const Tool,
    rounds: usize = max_rounds,
    system: []const u8 = system_prompt,
    cancel: ?*const Workers = null,
    /// Overrides the agent's model for this run — a picture needs the vision
    /// profile. Null keeps the default.
    model: ?[]const u8 = null,
};

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
    workspace: []const u8 = "workspace",
    diary_dir: []const u8 = "data/diary",
    /// Model profile used when the owner sends a picture. Falls back to `model`.
    vision_model: ?[]const u8 = null,
    fetch: ?web.Get = null,
    limiter: web.Limiter = .{},
    /// Null means nothing runs in the background.
    workers: ?*Workers = null,
    /// Set once delegation is wired up. `Workers` above is what this file
    /// actually touches; the pool is only carried through to the tools.
    pool: ?*worker.Pool = null,

    /// Caller owns the returned reply.
    pub fn turn(self: *Agent, input: []const u8) ![]u8 {
        return self.turnWith(.{ .text = input });
    }

    /// The one seam, widened by exactly one optional field. Caller owns the reply.
    pub fn turnWith(self: *Agent, in: Input) ![]u8 {
        const input = in.text;
        const now = std.Io.Timestamp.now(self.io, .real).toSeconds();
        // A bare yes/no is only a verdict when something is actually waiting.
        const verdict = tasks.decide(input);
        if (verdict != .other and try tasks.pendingCount(self.db) > 0) {
            return resolveApproval(self, input, now, verdict);
        }
        if (verdict == .deny and isStop(input)) {
            if (self.workers) |w| if (w.count() > 0) {
                try insertMsg(self.db, "user", input, now);
                w.stop.store(true, .release);
                return sayFmt(self, now, "Stopping {d} background task(s).", .{w.count()});
            };
        }
        try insertMsg(self.db, "user", input, now);

        var arena_inst = std.heap.ArenaAllocator.init(self.gpa);
        defer arena_inst.deinit();
        const arena = arena_inst.allocator();

        var messages: std.ArrayList(Msg) = .empty;
        try messages.append(arena, .{ .role = "system", .content = try withContext(arena, self, input, now) });
        try loadHistory(self.db, arena, &messages);
        // loadHistory already includes the user row we just wrote; the picture
        // rides along on it and is never persisted.
        if (in.image) |img| messages.items[messages.items.len - 1].image = img;

        const reply = try drive(self, arena, &messages, .{
            .tools = self.tools,
            .model = if (in.image != null) self.vision_model else null,
        });
        errdefer self.gpa.free(reply);
        try insertMsg(self.db, "assistant", reply, now);
        return reply;
    }

    /// One turn with no history: the system prompt and `input`, nothing else,
    /// and not a byte written to `messages`. That absence is exactly what
    /// "fresh context" means for a subagent. Caller owns the reply.
    pub fn isolated(self: *Agent, input: []const u8, b: Budget) ![]u8 {
        var arena_inst = std.heap.ArenaAllocator.init(self.gpa);
        defer arena_inst.deinit();
        const arena = arena_inst.allocator();

        var messages: std.ArrayList(Msg) = .empty;
        try messages.append(arena, .{ .role = "system", .content = b.system });
        try messages.append(arena, .{ .role = "user", .content = input });
        return drive(self, arena, &messages, b);
    }
};

/// The model/tool loop, shared by the owner's turn and by every subagent.
/// Persisting the conversation is the caller's job, which is what keeps a
/// subagent out of the transcript.
fn drive(self: *Agent, arena: std.mem.Allocator, messages: *std.ArrayList(Msg), b: Budget) ![]u8 {
    const endpoint = try chatUrl(arena, self.base_url);
    const auth = try std.fmt.allocPrint(arena, "Bearer {s}", .{self.api_key.reveal()});

    var round: usize = 0;
    while (true) {
        if (b.cancel) |w| if (w.cancelled()) return error.Cancelled;
        // Cap before the next model call so we never spend one round too many.
        if (round >= b.rounds) {
            return std.fmt.allocPrint(
                self.gpa,
                "I hit the tool-round limit ({d}) and stopped. Tell me how to continue.",
                .{b.rounds},
            );
        }

        const body = try buildRequest(arena, b.model orelse self.model, messages.items, b.tools);
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

        if (parsed.tool_calls.len == 0) return self.gpa.dupe(u8, parsed.content orelse "");

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
                .workspace = self.workspace,
                .fetch = self.fetch,
                .limiter = &self.limiter,
                .pool = self.pool,
            };
            const raw = try tools.call(&ctx, b.tools, call.name, call.arguments);
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

/// Only the bare word cancels background work; "cancel" and "no" stay verdicts
/// on a pending approval.
fn isStop(input: []const u8) bool {
    return std.ascii.eqlIgnoreCase(std.mem.trim(u8, input, &std.ascii.whitespace), "stop");
}

const Msg = struct {
    role: []const u8,
    content: []const u8,
    tool_calls: []const ToolCall = &.{},
    tool_call_id: ?[]const u8 = null,
    image: ?Image = null,
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

fn resolveApproval(self: *Agent, input: []const u8, now: i64, verdict: tasks.Decision) ![]u8 {
    try insertMsg(self.db, "user", input, now);
    var pending = (try tasks.latestPending(self.db, self.gpa)) orelse
        return sayFmt(self, now, "{s}", .{"I have more than one pending action. Which one do you mean?"});
    defer pending.deinit(self.gpa);

    if (verdict == .deny) {
        try tasks.setApproval(self.db, pending.id, "denied");
        return sayFmt(self, now, "Cancelled {s}.", .{pending.tool});
    }
    if (pending.expires <= now) {
        try tasks.setApproval(self.db, pending.id, "expired");
        return sayFmt(self, now, "That approval expired {d} minutes ago. Ask me again if you still want it.", .{@divFloor(now - pending.expires, 60)});
    }
    try tasks.authorize(self.db, pending.id, pending.tool, pending.args, now);
    try tasks.setApproval(self.db, pending.id, "approved");

    var ctx: tools.Ctx = .{
        .gpa = self.gpa,
        .io = self.io,
        .db = self.db,
        .skills_dir = self.skills_dir,
        .workspace = self.workspace,
        .fetch = self.fetch,
        .limiter = &self.limiter,
        .pool = self.pool,
    };
    const raw = try tools.callApproved(&ctx, self.tools, pending.tool, pending.args);
    defer self.gpa.free(raw);
    return sayFmt(self, now, "{s}: {s}", .{ pending.tool, raw });
}

fn sayFmt(self: *Agent, now: i64, comptime fmt: []const u8, args: anytype) ![]u8 {
    const reply = try std.fmt.allocPrint(self.gpa, fmt, args);
    errdefer self.gpa.free(reply);
    try insertMsg(self.db, "assistant", reply, now);
    return reply;
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
    const pending = tasks.pendingLines(self.db, arena) catch "";

    if (hits.len == 0 and skill_index.len == 0 and secret_names.len == 0 and pending.len == 0) return system_prompt;

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
    if (pending.len != 0) {
        try w.writeAll("\n\n## waiting for the owner's yes or no\n");
        try w.writeAll(pending);
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
        if (m.image) |img| try writeParts(arena, w, m.content, img) else try writeJsonString(w, m.content);
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

/// The OpenAI content-parts form: the caption stays with the picture, so the
/// model reads both together.
fn writeParts(arena: std.mem.Allocator, w: *std.Io.Writer, text: []const u8, img: Image) !void {
    const enc = std.base64.standard.Encoder;
    const b64 = try arena.alloc(u8, enc.calcSize(img.data.len));
    defer arena.free(b64);
    _ = enc.encode(b64, img.data);

    const url = try std.fmt.allocPrint(arena, "data:{s};base64,{s}", .{ img.mime, b64 });
    defer arena.free(url);

    try w.writeAll("[{\"type\":\"text\",\"text\":");
    try writeJsonString(w, text);
    try w.writeAll("},{\"type\":\"image_url\",\"image_url\":{\"url\":");
    try writeJsonString(w, url);
    try w.writeAll("}}]");
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

// ── test helpers ──────────────────────────────────────────────────────────

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
    };

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
    };

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

    var fake: FakeHttp = .{ .bodies = &bodies };

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
    };

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

    const sent = fake.sent();
    try testing.expect(std.mem.indexOf(u8, sent, "[truncated]") != null);
}

test "agent module stays free of channel imports" {
    const src = @embedFile("root.zig");
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
    };

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

    const sent = fake.sent();
    try testing.expect(std.mem.indexOf(u8, sent, "a black cat named mittens") != null);
}

test "turn does not inject an irrelevant memory" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [128]u8 = undefined;

    var fake: FakeHttp = .{
        .bodies = &.{"{\"choices\":[{\"message\":{\"content\":\"ok\"}}]}"},
    };

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

    const sent = fake.sent();
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
    };

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

    const sent = fake.sent();
    try testing.expect(std.mem.indexOf(u8, sent, "a black cat named mittens") != null);
}

test "turn keeps injected memory and history bounded as history grows" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [128]u8 = undefined;

    var fake: FakeHttp = .{
        .bodies = &.{"{\"choices\":[{\"message\":{\"content\":\"ok\"}}]}"},
    };

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

    const sent = fake.sent();
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
    };

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
    const sent = fake.sent();
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
    };

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
    const sent = fake.sent();
    try testing.expect(std.mem.indexOf(u8, sent, "weather_api_key") != null);
    try testing.expect(std.mem.indexOf(u8, sent, "sk-secret-value") == null);
}

fn pingRun(ctx: *tools.Ctx, args: []const u8) anyerror![]u8 {
    return try std.fmt.allocPrint(ctx.gpa, "pong {s}", .{args});
}

const ping_tool: tools.Def = .{
    .name = "ping",
    .description = "test ping",
    .params = &.{},
    .run = pingRun,
};

test "yes runs the bound pending action and skips the model" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [128]u8 = undefined;

    var fake: FakeHttp = .{
        .bodies = &.{"{\"choices\":[{\"message\":{\"content\":\"should not run\"}}]}"},
    };

    var db = try openTmpDb(&tmp, &buf);
    defer db.close();
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const now = std.Io.Timestamp.now(io, .real).toSeconds();
    _ = try tasks.ask(&db, "ping", "{\"n\":\"1\"}", null, "probe", null, now);

    var a: Agent = .{
        .gpa = testing.allocator,
        .io = io,
        .db = &db,
        .http = fake.http(),
        .api_key = .init("k"),
        .base_url = default_base_url,
        .model = "m",
        .tools = &.{ping_tool},
    };
    const reply = try a.turn("yes");
    defer testing.allocator.free(reply);
    try testing.expect(std.mem.indexOf(u8, reply, "pong") != null);
    try testing.expectEqual(@as(usize, 0), fake.i);
}

test "yes on an expired approval is refused and reported" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [128]u8 = undefined;

    var fake: FakeHttp = .{
        .bodies = &.{"{\"choices\":[{\"message\":{\"content\":\"no\"}}]}"},
    };

    var db = try openTmpDb(&tmp, &buf);
    defer db.close();
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    _ = try tasks.ask(&db, "ping", "{}", null, "old", null, 0);

    var a: Agent = .{
        .gpa = testing.allocator,
        .io = threaded.io(),
        .db = &db,
        .http = fake.http(),
        .api_key = .init("k"),
        .base_url = default_base_url,
        .model = "m",
        .tools = &.{ping_tool},
    };
    const reply = try a.turn("yes");
    defer testing.allocator.free(reply);
    try testing.expect(std.mem.indexOf(u8, reply, "expired") != null);
    try testing.expectEqual(@as(usize, 0), fake.i);
}

test "yes with two pending actions asks which" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [128]u8 = undefined;

    var fake: FakeHttp = .{
        .bodies = &.{"{\"choices\":[{\"message\":{\"content\":\"no\"}}]}"},
    };

    var db = try openTmpDb(&tmp, &buf);
    defer db.close();
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const now = std.Io.Timestamp.now(threaded.io(), .real).toSeconds();
    _ = try tasks.ask(&db, "ping", "{\"a\":1}", null, "one", null, now);
    _ = try tasks.ask(&db, "ping", "{\"a\":2}", null, "two", null, now);

    var a: Agent = .{
        .gpa = testing.allocator,
        .io = threaded.io(),
        .db = &db,
        .http = fake.http(),
        .api_key = .init("k"),
        .base_url = default_base_url,
        .model = "m",
        .tools = &.{ping_tool},
    };
    const reply = try a.turn("yes");
    defer testing.allocator.free(reply);
    try testing.expect(std.mem.indexOf(u8, reply, "more than one") != null);
    try testing.expectEqual(@as(usize, 0), fake.i);
}

test "a bare yes with nothing pending is an ordinary message" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [128]u8 = undefined;

    var fake: FakeHttp = .{
        .bodies = &.{"{\"choices\":[{\"message\":{\"content\":\"sure thing\"}}]}"},
    };

    var db = try openTmpDb(&tmp, &buf);
    defer db.close();
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();

    var a: Agent = .{
        .gpa = testing.allocator,
        .io = threaded.io(),
        .db = &db,
        .http = fake.http(),
        .api_key = .init("k"),
        .base_url = default_base_url,
        .model = "m",
        .tools = &.{ping_tool},
    };
    const reply = try a.turn("yes");
    defer testing.allocator.free(reply);
    try testing.expectEqualStrings("sure thing", reply);
    try testing.expectEqual(@as(usize, 1), fake.i);
}

test "a picture reaches the vision profile with its caption, and is not persisted" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [128]u8 = undefined;
    var db = try Db.open(try std.fmt.bufPrintZ(&buf, ".zig-cache/tmp/{s}/zoro.db", .{tmp.sub_path}));
    defer db.close();
    try db.migrate();
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();

    var fake: FakeHttp = .{
        .bodies = &.{"{\"choices\":[{\"message\":{\"content\":\"a cat\"}}]}"},
    };
    var a: Agent = .{
        .gpa = testing.allocator,
        .io = threaded.io(),
        .db = &db,
        .http = fake.http(),
        .api_key = .init("k"),
        .base_url = "https://api.openai.com/v1",
        .model = "text-only",
        .vision_model = "sees-things",
    };

    const reply = try a.turnWith(.{
        .text = "what is this",
        .image = .{ .mime = "image/jpeg", .data = "\xff\xd8\xff" },
    });
    defer testing.allocator.free(reply);
    try testing.expectEqualStrings("a cat", reply);

    const sent = fake.sent();
    try testing.expect(std.mem.indexOf(u8, sent, "\"sees-things\"") != null);
    try testing.expect(std.mem.indexOf(u8, sent, "data:image/jpeg;base64,/9j/") != null);
    try testing.expect(std.mem.indexOf(u8, sent, "\"what is this\"") != null);

    // The transcript keeps the caption; the bytes are never written to the database.
    var q = try db.prepare("SELECT content FROM messages WHERE role = 'user'");
    defer q.finalize();
    try testing.expect(try q.step());
    try testing.expectEqualStrings("what is this", q.text(0));
}
