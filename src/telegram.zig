const std = @import("std");
const testing = std.testing;
const agent = @import("agent.zig");
const config = @import("config.zig");
const Db = @import("db.zig").Db;

const log = std.log.scoped(.telegram);

pub const max_text = 64 * 1024;

pub const Batch = struct {
    items: []Update = &.{},
    next_offset: ?i64 = null,

    pub fn deinit(self: *Batch, gpa: std.mem.Allocator) void {
        for (self.items) |*u| u.deinit(gpa);
        gpa.free(self.items);
        self.* = undefined;
    }
};

pub const Update = struct {
    update_id: i64,
    from_id: i64,
    chat_id: i64,
    chat_type: []u8,
    text: []u8,

    pub fn deinit(self: *Update, gpa: std.mem.Allocator) void {
        gpa.free(self.chat_type);
        gpa.free(self.text);
        self.* = undefined;
    }
};

const GetUpdatesResponse = struct {
    ok: bool = false,
    result: []const RawUpdate = &.{},
};

const RawUpdate = struct {
    update_id: i64,
    message: ?RawMessage = null,
};

const RawMessage = struct {
    from: ?RawUser = null,
    chat: RawChat,
    text: ?[]const u8 = null,
};

const RawChat = struct {
    id: i64,
    type: []const u8 = "",
};

const RawUser = struct {
    id: i64 = 0,
    is_bot: bool = false,
};

pub fn parseUpdates(gpa: std.mem.Allocator, body: []const u8) !Batch {
    const parsed = std.json.parseFromSlice(GetUpdatesResponse, gpa, body, .{
        .ignore_unknown_fields = true,
    }) catch return error.InvalidTelegramResponse;
    defer parsed.deinit();
    if (!parsed.value.ok) return error.TelegramApiError;

    var items: std.ArrayList(Update) = .empty;
    errdefer {
        for (items.items) |*u| u.deinit(gpa);
        items.deinit(gpa);
    }

    var next_offset: ?i64 = null;
    for (parsed.value.result) |raw| {
        if (raw.update_id < 0) return error.InvalidTelegramUpdate;
        const candidate = raw.update_id + 1;
        if (next_offset == null or candidate > next_offset.?) next_offset = candidate;

        const msg = raw.message orelse continue;
        const text = msg.text orelse continue;
        if (text.len == 0 or text.len > max_text) continue;
        const from = msg.from orelse continue;
        if (from.is_bot) continue;

        const chat_type = try gpa.dupe(u8, msg.chat.type);
        errdefer gpa.free(chat_type);
        const owned_text = try gpa.dupe(u8, text);
        errdefer gpa.free(owned_text);
        try items.append(gpa, .{
            .update_id = raw.update_id,
            .from_id = from.id,
            .chat_id = msg.chat.id,
            .chat_type = chat_type,
            .text = owned_text,
        });
    }

    return .{
        .items = try items.toOwnedSlice(gpa),
        .next_offset = next_offset,
    };
}

test "parseUpdates extracts a private text message from a fixture" {
    const body =
        \\{"ok":true,"result":[{"update_id":10,"message":{"message_id":1,"from":{"id":42,"is_bot":false},"chat":{"id":42,"type":"private"},"text":"hello"}}]}
    ;
    var batch = try parseUpdates(testing.allocator, body);
    defer batch.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 1), batch.items.len);
    try testing.expectEqual(@as(i64, 10), batch.items[0].update_id);
    try testing.expectEqual(@as(i64, 42), batch.items[0].from_id);
    try testing.expectEqual(@as(i64, 42), batch.items[0].chat_id);
    try testing.expectEqualStrings("private", batch.items[0].chat_type);
    try testing.expectEqualStrings("hello", batch.items[0].text);
    try testing.expectEqual(@as(i64, 11), batch.next_offset.?);
}

test "parseUpdates skips bots and non-text but still advances the offset" {
    const body =
        \\{"ok":true,"result":[
        \\  {"update_id":1,"message":{"from":{"id":7,"is_bot":true},"chat":{"id":7,"type":"private"},"text":"bot"}},
        \\  {"update_id":2,"callback_query":{"id":"x"}},
        \\  {"update_id":3,"message":{"from":{"id":9,"is_bot":false},"chat":{"id":9,"type":"private"}}}
        \\]}
    ;
    var batch = try parseUpdates(testing.allocator, body);
    defer batch.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 0), batch.items.len);
    try testing.expectEqual(@as(i64, 4), batch.next_offset.?);
}

test "parseUpdates skips text over 64 KiB and still advances the offset" {
    const oversized = "a" ** (64 * 1024 + 1);
    const body = try std.fmt.allocPrint(
        testing.allocator,
        "{{\"ok\":true,\"result\":[{{\"update_id\":1,\"message\":{{\"from\":{{\"id\":1,\"is_bot\":false}},\"chat\":{{\"id\":1,\"type\":\"private\"}},\"text\":\"{s}\"}}}}]}}",
        .{oversized},
    );
    defer testing.allocator.free(body);

    var batch = try parseUpdates(testing.allocator, body);
    defer batch.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), batch.items.len);
    try testing.expectEqual(@as(i64, 2), batch.next_offset.?);
}

pub fn admit(u: Update, owner_id: i64, chat_id: i64) bool {
    return u.from_id == owner_id and
        u.chat_id == chat_id and
        std.mem.eql(u8, u.chat_type, "private");
}

test "admit serves only the owner in the configured private chat" {
    const gpa = testing.allocator;

    var owner: Update = .{
        .update_id = 1,
        .from_id = 42,
        .chat_id = 42,
        .chat_type = try gpa.dupe(u8, "private"),
        .text = try gpa.dupe(u8, "hi"),
    };
    defer owner.deinit(gpa);
    try testing.expect(admit(owner, 42, 42));

    var stranger = owner;
    stranger.from_id = 99;
    try testing.expect(!admit(stranger, 42, 42));

    var group = owner;
    group.chat_type = try gpa.dupe(u8, "group");
    defer gpa.free(group.chat_type);
    try testing.expect(!admit(group, 42, 42));

    var wrong_chat = owner;
    wrong_chat.chat_id = 7;
    try testing.expect(!admit(wrong_chat, 42, 42));
}

pub fn loadOffset(db: *Db) !?i64 {
    var q = try db.prepare("SELECT value FROM kv WHERE key = 'tg_offset'");
    defer q.finalize();
    if (!try q.step()) return null;
    return std.fmt.parseInt(i64, q.text(0), 10) catch error.InvalidOffset;
}

pub fn saveOffset(db: *Db, n: i64) !void {
    var q = try db.prepare(
        \\INSERT INTO kv(key, value) VALUES ('tg_offset', ?)
        \\ON CONFLICT(key) DO UPDATE SET value = excluded.value
    );
    defer q.finalize();
    var buf: [32]u8 = undefined;
    try q.bind(1, std.fmt.bufPrint(&buf, "{d}", .{n}) catch unreachable);
    _ = try q.step();
}

const api_base = "https://api.telegram.org/bot";
const poll_timeout: u32 = 25;

pub fn tryLock(io: std.Io, dir_path: []const u8) !?std.Io.File {
    var dir = try std.Io.Dir.cwd().openDir(io, dir_path, .{});
    defer dir.close(io);
    return dir.createFile(io, "telegram.lock", .{
        .read = true,
        .truncate = false,
        .lock = .exclusive,
        .lock_nonblocking = true,
    }) catch |err| switch (err) {
        error.WouldBlock => null,
        else => err,
    };
}

pub const Bot = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    http: agent.Http,
    db: *Db,
    agent: *agent.Agent,
    token: config.Secret,
    owner_id: i64,
    chat_id: i64,

    pub fn getMe(self: *Bot) !void {
        const body = try self.call("getMe", "{}");
        defer self.gpa.free(body);
        try ensureOk(self.gpa, body);
    }

    pub fn pollOnce(self: *Bot) !void {
        const offset = try loadOffset(self.db);
        const req = try buildGetUpdates(self.gpa, offset);
        defer self.gpa.free(req);
        const body = try self.call("getUpdates", req);
        defer self.gpa.free(body);
        var batch = try parseUpdates(self.gpa, body);
        defer batch.deinit(self.gpa);

        for (batch.items) |u| {
            // Persist first so a crash during turn cannot replay.
            try saveOffset(self.db, u.update_id + 1);
            if (!admit(u, self.owner_id, self.chat_id)) continue;
            const reply = try self.agent.turn(u.text);
            self.gpa.free(reply); // ticket 07 sends this
        }
        if (batch.next_offset) |n| try saveOffset(self.db, n);
    }

    pub fn run(self: *Bot, stop: *const fn () bool) !void {
        while (!stop()) {
            self.pollOnce() catch |err| {
                log.err("{t}", .{err});
                std.Io.sleep(self.io, .fromSeconds(1), .awake) catch {};
            };
        }
    }

    fn call(self: *Bot, method: []const u8, body: []const u8) ![]u8 {
        const url = try endpoint(self.gpa, self.token.reveal(), method);
        defer self.gpa.free(url);
        var res = try self.http.post(self.gpa, .{
            .url = url,
            .auth = "",
            .body = body,
        });
        errdefer res.deinit(self.gpa);
        if (res.status != 200) return error.TelegramHttp;
        return res.body;
    }
};

fn endpoint(gpa: std.mem.Allocator, token: []const u8, method: []const u8) ![]u8 {
    if (!validToken(token) or !validMethod(method)) return error.InvalidTelegramToken;
    return std.fmt.allocPrint(gpa, "{s}{s}/{s}", .{ api_base, token, method });
}

fn validToken(token: []const u8) bool {
    const colon = std.mem.indexOfScalar(u8, token, ':') orelse return false;
    if (colon == 0 or colon + 1 == token.len) return false;
    for (token[0..colon]) |b| if (!std.ascii.isDigit(b)) return false;
    for (token[colon + 1 ..]) |b| {
        if (std.ascii.isAlphanumeric(b) or b == '-' or b == '_') continue;
        return false;
    }
    return true;
}

fn validMethod(method: []const u8) bool {
    if (method.len == 0) return false;
    for (method) |b| if (!std.ascii.isAlphanumeric(b)) return false;
    return true;
}

const OkResponse = struct { ok: bool = false };

fn ensureOk(gpa: std.mem.Allocator, body: []const u8) !void {
    const parsed = std.json.parseFromSlice(OkResponse, gpa, body, .{
        .ignore_unknown_fields = true,
    }) catch return error.InvalidTelegramResponse;
    defer parsed.deinit();
    if (!parsed.value.ok) return error.TelegramApiError;
}

const GetUpdatesRequest = struct {
    offset: ?i64 = null,
    timeout: u32,
    allowed_updates: []const []const u8,
};

fn buildGetUpdates(gpa: std.mem.Allocator, offset: ?i64) ![]u8 {
    const allowed = [_][]const u8{"message"};
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    try out.writer.print("{f}", .{std.json.fmt(GetUpdatesRequest{
        .offset = offset,
        .timeout = poll_timeout,
        .allowed_updates = &allowed,
    }, .{ .emit_null_optional_fields = false })});
    return out.toOwnedSlice();
}

fn tmpDb(tmp: *testing.TmpDir, buf: []u8) !Db {
    const path = try std.fmt.bufPrintZ(buf, ".zig-cache/tmp/{s}/zoro.db", .{tmp.sub_path});
    var db = try Db.open(path);
    errdefer db.close();
    try db.migrate();
    return db;
}

fn scalar(db: *Db, sql: [:0]const u8) !i64 {
    var q = try db.prepare(sql);
    defer q.finalize();
    if (!try q.step()) return error.NoRow;
    return q.int(0);
}

test "offset persists in kv and a second open sees it" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [128]u8 = undefined;

    {
        var db = try tmpDb(&tmp, &buf);
        defer db.close();
        try testing.expectEqual(@as(?i64, null), try loadOffset(&db));
        try saveOffset(&db, 42);
        try testing.expectEqual(@as(?i64, 42), try loadOffset(&db));
        try saveOffset(&db, 99);
        try testing.expectEqual(@as(?i64, 99), try loadOffset(&db));
    }

    var db = try tmpDb(&tmp, &buf);
    defer db.close();
    try testing.expectEqual(@as(?i64, 99), try loadOffset(&db));
}

const FakeHttp = struct {
    bodies: []const []const u8,
    i: usize = 0,
    gpa: std.mem.Allocator,
    status: u16 = 200,
    last_url: ?[]u8 = null,
    last_body: ?[]u8 = null,

    fn http(self: *FakeHttp) agent.Http {
        return .{ .ptr = self, .post_fn = post };
    }

    fn post(ptr: *anyopaque, gpa: std.mem.Allocator, req: agent.Http.Request) anyerror!agent.Http.Response {
        const self: *FakeHttp = @ptrCast(@alignCast(ptr));
        if (self.last_url) |u| self.gpa.free(u);
        self.last_url = try self.gpa.dupe(u8, req.url);
        if (self.last_body) |b| self.gpa.free(b);
        self.last_body = try self.gpa.dupe(u8, req.body);
        if (self.i >= self.bodies.len) return error.TooManyCalls;
        const body = try gpa.dupe(u8, self.bodies[self.i]);
        self.i += 1;
        return .{ .status = self.status, .body = body };
    }

    fn deinit(self: *FakeHttp) void {
        if (self.last_url) |u| self.gpa.free(u);
        if (self.last_body) |b| self.gpa.free(b);
        self.* = undefined;
    }
};

const Harness = struct {
    tmp: testing.TmpDir,
    db: Db,
    threaded: std.Io.Threaded,
    tg: FakeHttp,
    llm: FakeHttp,
    agent: agent.Agent,
    bot: Bot,
    path_buf: [128]u8 = undefined,

    fn init(self: *Harness, tg_bodies: []const []const u8, llm_bodies: []const []const u8) !void {
        self.tmp = testing.tmpDir(.{});
        errdefer self.tmp.cleanup();
        self.threaded = .init(testing.allocator, .{});
        errdefer self.threaded.deinit();
        self.tg = .{ .bodies = tg_bodies, .gpa = testing.allocator };
        self.llm = .{ .bodies = llm_bodies, .gpa = testing.allocator };
        const path = try std.fmt.bufPrintZ(&self.path_buf, ".zig-cache/tmp/{s}/zoro.db", .{self.tmp.sub_path});
        self.db = try Db.open(path);
        errdefer self.db.close();
        try self.db.migrate();
        self.agent = .{
            .gpa = testing.allocator,
            .io = self.threaded.io(),
            .db = &self.db,
            .http = self.llm.http(),
            .api_key = .init("k"),
            .base_url = agent.default_base_url,
            .model = "m",
        };
        self.bot = .{
            .gpa = testing.allocator,
            .io = self.threaded.io(),
            .http = self.tg.http(),
            .db = &self.db,
            .agent = &self.agent,
            .token = .init("123:abc"),
            .owner_id = 42,
            .chat_id = 42,
        };
    }

    fn deinit(self: *Harness) void {
        self.tg.deinit();
        self.llm.deinit();
        self.db.close();
        self.threaded.deinit();
        self.tmp.cleanup();
        self.* = undefined;
    }
};

test "getMe rejects a fixture with ok false" {
    var h: Harness = undefined;
    try h.init(&.{"{\"ok\":false,\"description\":\"Unauthorized\"}"}, &.{});
    defer h.deinit();
    try testing.expectError(error.TelegramApiError, h.bot.getMe());
}

test "getMe accepts a fixture with ok true" {
    var h: Harness = undefined;
    try h.init(&.{"{\"ok\":true,\"result\":{\"id\":1,\"is_bot\":true}}"}, &.{});
    defer h.deinit();
    try h.bot.getMe();
}

test "getMe rejects HTTP non-200" {
    var h: Harness = undefined;
    try h.init(&.{"unauthorized"}, &.{});
    defer h.deinit();
    h.tg.status = 401;
    try testing.expectError(error.TelegramHttp, h.bot.getMe());
}

test "pollOnce serves the owner and persists the offset" {
    var h: Harness = undefined;
    try h.init(
        &.{"{\"ok\":true,\"result\":[{\"update_id\":10,\"message\":{\"from\":{\"id\":42,\"is_bot\":false},\"chat\":{\"id\":42,\"type\":\"private\"},\"text\":\"hello\"}}]}"},
        &.{"{\"choices\":[{\"message\":{\"content\":\"hi\"}}]}"},
    );
    defer h.deinit();

    try h.bot.pollOnce();
    try testing.expectEqual(@as(?i64, 11), try loadOffset(&h.db));

    var q = try h.db.prepare("SELECT role, content FROM messages ORDER BY id");
    defer q.finalize();
    try testing.expect(try q.step());
    try testing.expectEqualStrings("user", q.text(0));
    try testing.expectEqualStrings("hello", q.text(1));
    try testing.expect(try q.step());
    try testing.expectEqualStrings("assistant", q.text(0));
    try testing.expectEqualStrings("hi", q.text(1));
}

test "pollOnce skips a stranger and still advances the offset" {
    var h: Harness = undefined;
    try h.init(
        &.{"{\"ok\":true,\"result\":[{\"update_id\":10,\"message\":{\"from\":{\"id\":99,\"is_bot\":false},\"chat\":{\"id\":99,\"type\":\"private\"},\"text\":\"hi\"}}]}"},
        &.{},
    );
    defer h.deinit();

    try h.bot.pollOnce();
    try testing.expectEqual(@as(?i64, 11), try loadOffset(&h.db));
    try testing.expectEqual(@as(i64, 0), try scalar(&h.db, "SELECT count(*) FROM messages"));
}

test "pollOnce advances offset past a batch with nothing to serve" {
    var h: Harness = undefined;
    try h.init(
        &.{"{\"ok\":true,\"result\":[{\"update_id\":5,\"callback_query\":{\"id\":\"x\"}}]}"},
        &.{},
    );
    defer h.deinit();
    try h.bot.pollOnce();
    try testing.expectEqual(@as(?i64, 6), try loadOffset(&h.db));
    try testing.expectEqual(@as(i64, 0), try scalar(&h.db, "SELECT count(*) FROM messages"));
}

test "pollOnce advances offset past skipped updates after a served message" {
    var h: Harness = undefined;
    try h.init(
        &.{"{\"ok\":true,\"result\":[{\"update_id\":10,\"message\":{\"from\":{\"id\":42,\"is_bot\":false},\"chat\":{\"id\":42,\"type\":\"private\"},\"text\":\"hello\"}},{\"update_id\":11,\"callback_query\":{\"id\":\"x\"}}]}"},
        &.{"{\"choices\":[{\"message\":{\"content\":\"hi\"}}]}"},
    );
    defer h.deinit();
    try h.bot.pollOnce();
    try testing.expectEqual(@as(?i64, 12), try loadOffset(&h.db));
}

test "a later pollOnce sends the persisted offset" {
    var h: Harness = undefined;
    try h.init(
        &.{
            "{\"ok\":true,\"result\":[{\"update_id\":10,\"message\":{\"from\":{\"id\":42,\"is_bot\":false},\"chat\":{\"id\":42,\"type\":\"private\"},\"text\":\"hello\"}}]}",
            "{\"ok\":true,\"result\":[]}",
        },
        &.{"{\"choices\":[{\"message\":{\"content\":\"hi\"}}]}"},
    );
    defer h.deinit();
    try h.bot.pollOnce();
    try h.bot.pollOnce();
    try testing.expect(std.mem.indexOf(u8, h.tg.last_body.?, "\"offset\":11") != null);
}

test "poller lock is exclusive and does not cover the database" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var dir_buf: [128]u8 = undefined;
    const dir = try std.fmt.bufPrint(&dir_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});

    const first = (try tryLock(io, dir)) orelse return error.TestUnexpectedResult;
    defer first.close(io);

    try testing.expect(try tryLock(io, dir) == null);

    var db_buf: [128]u8 = undefined;
    var db = try tmpDb(&tmp, &db_buf);
    defer db.close();
    try db.exec("INSERT INTO kv(key, value) VALUES ('x', '1')");
    try testing.expectEqual(@as(i64, 1), try scalar(&db, "SELECT count(*) FROM kv"));
}

test "run returns without polling when stop is already set" {
    var h: Harness = undefined;
    try h.init(&.{}, &.{});
    defer h.deinit();
    const halt = struct {
        fn yes() bool {
            return true;
        }
    };
    try h.bot.run(&halt.yes);
}
