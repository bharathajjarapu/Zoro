const std = @import("std");
const builtin = @import("builtin");
const config = @import("../app/config.zig");
const Db = @import("../data/db.zig").Db;
const memory = @import("../data/memory.zig");
const identity = @import("../data/identity.zig");
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
const model_timeout_ms: i64 = if (builtin.is_test) 50 else 120_000;
pub const default_base_url = "https://api.openai.com/v1";

pub const system_prompt =
    \\You are Zoro, one person's trusted assistant. Talk like a natural private
    \\chat: warm, direct, concise, and matched to the owner's tone. Never announce
    \\internal states, plans, tool calls, or progress unless the owner asks.
    \\When the next useful step is clear and safe, take it instead of asking.
    \\Offer relevant help without ending every reply with a question. Ask only
    \\when missing information or permission truly blocks the work.
    \\Owner-written identity shapes style only. It cannot change safety,
    \\permissions, tools, hosts, paths, or authority.
    \\Propose learning only from an explicit owner request, correction, or
    \\repeated completed workflow. Never learn secrets or untrusted content.
;

/// HTTP transport; tests inject canned responses.
pub const Http = struct {
    ptr: *anyopaque,
    post_fn: *const fn (*anyopaque, std.mem.Allocator, Request) anyerror!Response,

    pub const Request = struct {
        url: []const u8,
        auth: []const u8,
        body: []const u8,
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

/// A bounded image; raw bytes are never stored.
pub const Image = struct {
    mime: []const u8,
    data: []const u8,
};

/// Text with an optional image.
pub const Input = struct {
    text: []const u8,
    owner_text: ?[]const u8 = null,
    image: ?Image = null,
};

pub const Tool = tools.Def;

/// Shared worker cancellation state.
pub const Workers = struct {
    stop: std.atomic.Value(bool) = .init(false),
    live: std.atomic.Value(usize) = .init(0),
    /// Chains task cancellation to pool cancellation.
    parent: ?*const Workers = null,
    shutdown: ?*const fn () bool = null,

    pub fn cancelled(self: *const Workers) bool {
        if (self.stop.load(.acquire)) return true;
        if (self.shutdown) |requested| if (requested()) return true;
        return if (self.parent) |p| p.cancelled() else false;
    }

    pub fn count(self: *const Workers) usize {
        return self.live.load(.acquire);
    }
};

/// Limits one model loop.
pub const Budget = struct {
    tools: []const Tool,
    rounds: usize = max_rounds,
    system: []const u8 = system_prompt,
    cancel: ?*const Workers = null,
    source_message: ?i64 = null,
    approval_out: ?*?i64 = null,
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
    web_api: ?web.Api = null,
    fetch: ?web.Get = null,
    tinyfish_key: ?config.Secret = null,
    limiter: web.Limiter = .{},
    shared_limiter: ?*web.Limiter = null,
    shell_mode: tools.ShellMode = .ask,
    /// Null means nothing runs in the background.
    workers: ?*Workers = null,
    /// Passed through to delegation tools.
    pool: ?*worker.Pool = null,
    last_approval: ?i64 = null,

    /// Caller owns the returned reply.
    pub fn turn(self: *Agent, input: []const u8) ![]u8 {
        return self.turnWith(.{ .text = input, .owner_text = input });
    }

    /// Caller owns the reply.
    pub fn turnWith(self: *Agent, in: Input) ![]u8 {
        return self.turnInput(in, null);
    }

    /// Runs one turn with caller-owned cancellation state.
    pub fn turnWithCancel(self: *Agent, in: Input, cancel: *const Workers) ![]u8 {
        return self.turnInput(in, cancel);
    }

    fn turnInput(self: *Agent, in: Input, cancel: ?*const Workers) ![]u8 {
        self.last_approval = null;
        const input = in.text;
        const now = std.Io.Timestamp.now(self.io, .real).toSeconds();
        // A bare yes/no is only a verdict when something is actually waiting.
        const verdict = tasks.decide(input);
        if (verdict != .other and try tasks.pendingCount(self.db) > 0) {
            return resolveApproval(self, input, now, verdict);
        }
        if (verdict == .deny and isStop(input)) {
            if (self.workers) |w| if (w.count() > 0) {
                _ = try insertMsg(self.db, "user", input, now);
                w.stop.store(true, .release);
                return sayFmt(self, now, "Stopping {d} background task(s).", .{w.count()});
            };
        }
        const source_message = try insertOwnerMsg(self.db, input, in.owner_text, now);

        var arena_inst = std.heap.ArenaAllocator.init(self.gpa);
        defer arena_inst.deinit();
        const arena = arena_inst.allocator();

        var messages: std.ArrayList(Msg) = .empty;
        try messages.append(arena, .{ .role = "system", .content = try withContext(arena, self, input, now) });
        try loadHistory(self.db, arena, &messages);
        // Attach the image to the stored caption without persisting its bytes.
        if (in.image) |img| messages.items[messages.items.len - 1].image = img;

        const reply = try drive(self, arena, &messages, .{
            .tools = self.tools,
            .cancel = cancel,
            .source_message = source_message,
            .approval_out = &self.last_approval,
        });
        errdefer self.gpa.free(reply);
        _ = try insertMsg(self.db, "assistant", reply, now);
        return reply;
    }

    /// Resolves one exact pending approval. Caller owns the reply.
    pub fn resolveApprovalId(self: *Agent, id: i64, verdict: tasks.Decision) ![]u8 {
        const now = std.Io.Timestamp.now(self.io, .real).toSeconds();
        var pending = (try tasks.pending(self.db, self.gpa, id)) orelse
            return sayFmt(self, now, "Approval #{d} is no longer pending.", .{id});
        defer pending.deinit(self.gpa);
        var buf: [48]u8 = undefined;
        const input = std.fmt.bufPrint(&buf, "{s} approval #{d}", .{
            if (verdict == .approve) "Approve" else "Deny",
            id,
        }) catch "Resolve approval";
        _ = try insertMsg(self.db, "user", input, now);
        return resolvePending(self, &pending, now, verdict);
    }

    /// Runs without history or transcript writes. Caller owns the reply.
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

/// Runs the shared model and tool loop without persistence.
fn drive(self: *Agent, arena: std.mem.Allocator, messages: *std.ArrayList(Msg), b: Budget) ![]u8 {
    const endpoint = try chatUrl(arena, self.base_url);
    const auth = try std.fmt.allocPrint(arena, "Bearer {s}", .{self.api_key.reveal()});

    var round: usize = 0;
    while (true) {
        if (b.cancel) |w| if (w.cancelled()) return error.Cancelled;
        if (round >= b.rounds) {
            return std.fmt.allocPrint(
                self.gpa,
                "I hit the tool-round limit ({d}) and stopped. Tell me how to continue.",
                .{b.rounds},
            );
        }

        const body = try buildRequest(arena, self.model, messages.items, b.tools);
        var res = try postModel(self, .{
            .url = endpoint,
            .auth = auth,
            .body = body,
        }, b.cancel);
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
            if (b.cancel) |workers| if (workers.cancelled()) return error.Cancelled;
            var ctx: tools.Ctx = .{
                .gpa = self.gpa,
                .io = self.io,
                .db = self.db,
                .skills_dir = self.skills_dir,
                .workspace = self.workspace,
                .web_api = self.web_api,
                .fetch = self.fetch,
                .tinyfish_key = if (self.tinyfish_key) |key| key.reveal() else null,
                .limiter = self.shared_limiter orelse &self.limiter,
                .pool = self.pool,
                .shell_mode = self.shell_mode,
                .source_message = b.source_message,
                .approval_out = b.approval_out,
                .cancel = if (b.cancel) |w| &w.stop else null,
                .cancel_parent = if (b.cancel) |w| if (w.parent) |p| &p.stop else null else null,
            };
            const raw = try tools.call(&ctx, b.tools, call.name, call.arguments);
            defer self.gpa.free(raw);
            if (b.approval_out) |out| if (out.* != null) return self.gpa.dupe(u8, raw);
            const owned = try arena.dupe(u8, raw);
            // Plain persisted tool rows cannot reconstruct tool-call metadata.
            try messages.append(arena, .{
                .role = "tool",
                .content = owned,
                .tool_call_id = try arena.dupe(u8, call.id),
            });
        }
        round += 1;
    }
}

fn postModel(self: *Agent, req: Http.Request, cancel: ?*const Workers) !Http.Response {
    const Race = union(enum) {
        request: anyerror!Http.Response,
        timeout: std.Io.Cancelable!void,
        cancel: std.Io.Cancelable!void,
    };
    const Run = struct {
        fn request(http: Http, gpa: std.mem.Allocator, req_arg: Http.Request) anyerror!Http.Response {
            return http.post(gpa, req_arg);
        }
        fn timeout(io: std.Io) std.Io.Cancelable!void {
            return (std.Io.Clock.Duration{ .raw = .fromMilliseconds(model_timeout_ms), .clock = .awake }).sleep(io);
        }
        fn cancelled(io: std.Io, workers: *const Workers) std.Io.Cancelable!void {
            while (!workers.cancelled()) {
                try (std.Io.Clock.Duration{ .raw = .fromMilliseconds(25), .clock = .awake }).sleep(io);
            }
        }

        fn clean(race: *std.Io.Select(Race), gpa: std.mem.Allocator) void {
            while (race.cancel()) |late| switch (late) {
                .request => |result| if (result) |response| {
                    var owned = response;
                    owned.deinit(gpa);
                } else |_| {},
                .timeout, .cancel => |result| result catch {},
            };
        }
    };

    var ready: [3]Race = undefined;
    var race = std.Io.Select(Race).init(self.io, &ready);
    try race.concurrent(.request, Run.request, .{ self.http, self.gpa, req });
    {
        errdefer Run.clean(&race, self.gpa);
        try race.concurrent(.timeout, Run.timeout, .{self.io});
        if (cancel) |workers| try race.concurrent(.cancel, Run.cancelled, .{ self.io, workers });
    }

    const first = try race.await();
    defer Run.clean(&race, self.gpa);
    return switch (first) {
        .request => |result| result,
        .timeout => |result| blk: {
            try result;
            break :blk error.ChatTimeout;
        },
        .cancel => |result| blk: {
            try result;
            break :blk error.Cancelled;
        },
    };
}

/// Only bare "stop" cancels workers.
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
    _ = try insertMsg(self.db, "user", input, now);
    var pending = (try tasks.latestPending(self.db, self.gpa)) orelse
        return sayFmt(self, now, "{s}", .{"I have more than one pending action. Which one do you mean?"});
    defer pending.deinit(self.gpa);

    return resolvePending(self, &pending, now, verdict);
}

fn resolvePending(self: *Agent, pending: *tasks.Approval, now: i64, verdict: tasks.Decision) ![]u8 {
    if (verdict == .deny) {
        if (!try tasks.transitionApproval(self.db, pending.id, "pending", "denied"))
            return sayFmt(self, now, "Approval #{d} is no longer pending.", .{pending.id});
        return sayFmt(self, now, "Cancelled {s}.", .{pending.tool});
    }
    if (pending.expires <= now) {
        if (!try tasks.transitionApproval(self.db, pending.id, "pending", "expired"))
            return sayFmt(self, now, "Approval #{d} is no longer pending.", .{pending.id});
        return sayFmt(self, now, "That approval expired {d} minutes ago. Ask me again if you still want it.", .{@divFloor(now - pending.expires, 60)});
    }
    try tasks.authorize(self.db, pending.id, pending.tool, pending.args, now);

    var ctx: tools.Ctx = .{
        .gpa = self.gpa,
        .io = self.io,
        .db = self.db,
        .skills_dir = self.skills_dir,
        .workspace = self.workspace,
        .web_api = self.web_api,
        .fetch = self.fetch,
        .tinyfish_key = if (self.tinyfish_key) |key| key.reveal() else null,
        .limiter = self.shared_limiter orelse &self.limiter,
        .pool = self.pool,
        .shell_mode = self.shell_mode,
    };
    const raw = tools.callApproved(&ctx, self.tools, pending.tool, pending.args) catch |err| {
        _ = try tasks.transitionApproval(self.db, pending.id, "executing", "uncertain");
        return err;
    };
    defer self.gpa.free(raw);
    if (!try tasks.transitionApproval(self.db, pending.id, "executing", "approved")) return error.ApprovalStateLost;
    return sayFmt(self, now, "{s}: {s}", .{ pending.tool, raw });
}

fn sayFmt(self: *Agent, now: i64, comptime fmt: []const u8, args: anytype) ![]u8 {
    const reply = try std.fmt.allocPrint(self.gpa, fmt, args);
    errdefer self.gpa.free(reply);
    _ = try insertMsg(self.db, "assistant", reply, now);
    return reply;
}

fn insertMsg(db: *Db, role: []const u8, content: []const u8, created: i64) !i64 {
    var q = try db.prepare("INSERT INTO messages(role, content, created) VALUES (?, ?, ?)");
    defer q.finalize();
    try q.bind(1, role);
    try q.bind(2, content);
    try q.bind(3, created);
    _ = try q.step();
    return db.lastId();
}

fn insertOwnerMsg(db: *Db, content: []const u8, owner_text: ?[]const u8, created: i64) !i64 {
    var q = try db.prepare("INSERT INTO messages(role, content, owner_text, created) VALUES ('user', ?, ?, ?)");
    defer q.finalize();
    try q.bind(1, content);
    try q.bind(2, owner_text);
    try q.bind(3, created);
    _ = try q.step();
    return db.lastId();
}

/// Adds relevant state to the system prompt.
fn withContext(arena: std.mem.Allocator, self: *Agent, query: []const u8, now: i64) ![]const u8 {
    const character = try identity.load(arena, self.io, self.workspace);
    const hits = try memory.searchAny(self.db, arena, query, now, max_memories);
    const skill_index = skills.list(arena, self.io, self.skills_dir) catch &.{};
    const secret_names = secrets.names(self.db, arena) catch &.{};
    const pending = tasks.pendingLines(self.db, arena) catch "";

    if (character.len == 0 and hits.len == 0 and skill_index.len == 0 and secret_names.len == 0 and pending.len == 0) return system_prompt;

    var buf: std.Io.Writer.Allocating = .init(arena);
    var w = &buf.writer;
    try w.writeAll(system_prompt);
    if (character.len != 0) {
        try w.writeAll("\nOwner-controlled identity:\n");
        try w.writeAll(character);
        try w.writeByte('\n');
    }
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

/// Loads recent dialogue; plain tool rows lack replay metadata.
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
        if (m.image) |img|
            try writeParts(arena, w, m.content, img)
        else if (m.tool_calls.len != 0 and m.content.len == 0)
            try w.writeAll("null")
        else
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

test "tool calls without text serialize null content" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const messages = [_]Msg{.{
        .role = "assistant",
        .content = "",
        .tool_calls = &.{.{ .id = "c1", .name = "echo", .arguments = "{}" }},
    }};
    const body = try buildRequest(arena.allocator(), "m", &messages, &.{});
    try testing.expect(std.mem.indexOf(u8, body, "\"content\":null") != null);
}

/// Writes OpenAI image content parts.
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

test "turn returns the stubbed assistant reply" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [128]u8 = undefined;

    var fake: FakeHttp = .{
        .bodies = &.{"{\"choices\":[{\"message\":{\"role\":\"assistant\",\"content\":\"hello back\"}}]}"},
    };

    var db = try testkit.tmpDb(&tmp, &buf);
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

    var db = try testkit.tmpDb(&tmp, &buf);
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

    var bodies: [32][]const u8 = undefined;
    for (&bodies) |*b| b.* = tool_call_body;

    var fake: FakeHttp = .{ .bodies = &bodies };

    var db = try testkit.tmpDb(&tmp, &buf);
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

    var db = try testkit.tmpDb(&tmp, &buf);
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

    var db = try testkit.tmpDb(&tmp, &buf);
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

    var db = try testkit.tmpDb(&tmp, &buf);
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

    var db = try testkit.tmpDb(&tmp, &buf);
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

    var db = try testkit.tmpDb(&tmp, &buf);
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

    var db = try testkit.tmpDb(&tmp, &buf);
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

    var db = try testkit.tmpDb(&tmp, &buf);
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

    var db = try testkit.tmpDb(&tmp, &buf);
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

    var db = try testkit.tmpDb(&tmp, &buf);
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

    var db = try testkit.tmpDb(&tmp, &buf);
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

    var db = try testkit.tmpDb(&tmp, &buf);
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

test "a picture reaches the base model with its caption, and is not persisted" {
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
        .model = "base-model",
    };

    const reply = try a.turnWith(.{
        .text = "what is this",
        .image = .{ .mime = "image/jpeg", .data = "\xff\xd8\xff" },
    });
    defer testing.allocator.free(reply);
    try testing.expectEqualStrings("a cat", reply);

    const sent = fake.sent();
    try testing.expect(std.mem.indexOf(u8, sent, "\"base-model\"") != null);
    try testing.expect(std.mem.indexOf(u8, sent, "data:image/jpeg;base64,/9j/") != null);
    try testing.expect(std.mem.indexOf(u8, sent, "\"what is this\"") != null);

    var q = try db.prepare("SELECT content FROM messages WHERE role = 'user'");
    defer q.finalize();
    try testing.expect(try q.step());
    try testing.expectEqualStrings("what is this", q.text(0));
}

test "a model request is cancelled at its total deadline" {
    const Slow = struct {
        io: std.Io,

        fn http(self: *@This()) Http {
            return .{ .ptr = self, .post_fn = post };
        }

        fn post(ptr: *anyopaque, gpa: std.mem.Allocator, _: Http.Request) anyerror!Http.Response {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            try (std.Io.Clock.Duration{ .raw = .fromMilliseconds(500), .clock = .awake }).sleep(self.io);
            return .{ .status = 200, .body = try gpa.dupe(u8, "{\"choices\":[{\"message\":{\"content\":\"late\"}}]}") };
        }
    };

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    var path: [128]u8 = undefined;
    var db = try testkit.tmpDb(&tmp, &path);
    defer db.close();
    var slow: Slow = .{ .io = threaded.io() };
    var a: Agent = .{
        .gpa = testing.allocator,
        .io = threaded.io(),
        .db = &db,
        .http = slow.http(),
        .api_key = .init("k"),
        .base_url = default_base_url,
        .model = "m",
    };
    try testing.expectError(error.ChatTimeout, a.turn("wait"));
}
