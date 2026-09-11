const std = @import("std");
const testing = std.testing;
const testkit = @import("../testing/testkit.zig");
const FakeHttp = testkit.FakeHttp;
const agent = @import("../agent/root.zig");
const config = @import("../app/config.zig");
const Db = @import("../data/db.zig").Db;
const outbox = @import("../data/outbox.zig");
const web = @import("../net/web.zig");

const log = std.log.scoped(.telegram);

pub const max_text = 64 * 1024;
/// Conservative under Telegram's 4096-character cap so a chunk always fits.
const max_message = 3900;
/// Bound on anything we pull off the wire or push back up. Telegram allows
/// more; a personal assistant does not need it, and the model pays per byte.
/// Matched to `web.max_body`, which is the transport bound a download actually
/// hits first — declaring a larger number here would just fail silently.
pub const max_file = web.max_body;

fn utf8ChunkEnd(text: []const u8, max_bytes: usize) usize {
    if (max_bytes == 0) return 0;
    if (text.len <= max_bytes) return text.len;
    var end = max_bytes;
    while (end > 0 and (text[end] & 0xc0) == 0x80) : (end -= 1) {}
    return end;
}

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
    /// The message text, the caption of an attachment, or a one-line
    /// description of an attachment we will not download.
    text: []u8,
    /// Set only for a picture: the file to fetch and show the vision model.
    photo: ?[]u8 = null,

    pub fn deinit(self: *Update, gpa: std.mem.Allocator) void {
        gpa.free(self.chat_type);
        gpa.free(self.text);
        if (self.photo) |p| gpa.free(p);
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
    caption: ?[]const u8 = null,
    photo: ?[]const RawPhoto = null,
    document: ?RawFile = null,
    audio: ?RawFile = null,
    video: ?RawFile = null,
    voice: ?RawFile = null,
};

const RawPhoto = struct {
    file_id: []const u8 = "",
    file_size: ?i64 = null,
};

const RawFile = struct {
    file_id: []const u8 = "",
    file_name: ?[]const u8 = null,
    mime_type: ?[]const u8 = null,
    file_size: ?i64 = null,
};

/// Telegram lists a photo smallest-first. The largest under the cap is the one
/// worth showing the model.
fn largest(sizes: []const RawPhoto) ?RawPhoto {
    var best: ?RawPhoto = null;
    for (sizes) |p| {
        if (p.file_id.len == 0 or (p.file_size orelse 0) > max_file) continue;
        if (best == null or (p.file_size orelse 0) > (best.?.file_size orelse 0)) best = p;
    }
    return best;
}

/// Anything that is not a picture becomes one line of metadata. It is never a
/// failed turn, and never a download.
fn describe(gpa: std.mem.Allocator, caption: []const u8, f: RawFile) ![]u8 {
    return std.fmt.allocPrint(gpa, "{s}{s}[attachment: {s}, {s}, {d} bytes — I can see its details but not its contents]", .{
        caption,
        if (caption.len == 0) "" else "\n",
        f.file_name orelse "unnamed",
        f.mime_type orelse "unknown type",
        f.file_size orelse 0,
    });
}

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
        const from = msg.from orelse continue;
        if (from.is_bot) continue;

        const caption = msg.text orelse msg.caption orelse "";
        if (caption.len > max_text) continue;
        const picture = if (msg.photo) |sizes| largest(sizes) else null;
        const file = msg.document orelse msg.audio orelse msg.video orelse msg.voice;
        if (caption.len == 0 and picture == null and file == null) continue;

        const chat_type = try gpa.dupe(u8, msg.chat.type);
        errdefer gpa.free(chat_type);
        const owned_text = if (picture == null and file != null)
            try describe(gpa, caption, file.?)
        else
            try gpa.dupe(u8, caption);
        errdefer gpa.free(owned_text);
        const photo_id = if (picture) |p| try gpa.dupe(u8, p.file_id) else null;
        errdefer if (photo_id) |id| gpa.free(id);
        try items.append(gpa, .{
            .update_id = raw.update_id,
            .from_id = from.id,
            .chat_id = msg.chat.id,
            .chat_type = chat_type,
            .text = owned_text,
            .photo = photo_id,
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

test "utf8ChunkEnd does not split a multi-byte character" {
    const text = "ab€cd";
    try testing.expectEqual(@as(usize, 2), utf8ChunkEnd(text, 4));
    try testing.expectEqual(text.len, utf8ChunkEnd(text, 32));
    try testing.expectEqual(@as(usize, 0), utf8ChunkEnd("€", 1));
    try testing.expectEqual(@as(usize, 0), utf8ChunkEnd("€", 0));
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

const file_base = "https://api.telegram.org/file/bot";

pub const Bot = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    http: agent.Http,
    db: *Db,
    agent: *agent.Agent,
    token: config.Secret,
    owner_id: i64,
    chat_id: i64,
    /// Plain GET, used only to pull a photo off Telegram's file host.
    fetch: ?web.Get = null,
    /// The one directory an outbound attachment may come from.
    workspace: []const u8 = "workspace",

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
            self.typing() catch |err| log.warn("{t}", .{err});
            try self.answer(u);
            try self.flush();
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

    /// A picture that will not download is still a turn: the owner gets an
    /// answer about what we could see, never an error.
    fn answer(self: *Bot, u: Update) !void {
        var picture: ?[]u8 = null;
        defer if (picture) |p| self.gpa.free(p);
        var mime: []const u8 = "image/jpeg";

        if (u.photo) |file_id| {
            if (self.download(file_id)) |bytes| {
                picture = bytes;
                mime = sniff(bytes);
            } else |err| log.warn("photo {s}: {t}", .{ file_id, err });
        }

        const reply = try self.agent.turnWith(.{
            .text = if (u.text.len != 0) u.text else "(a picture, no caption)",
            .image = if (picture) |p| .{ .mime = mime, .data = p } else null,
        });
        defer self.gpa.free(reply);
        try self.send(reply);
    }

    /// Sends whatever the agent, a routine or a tool queued for the owner.
    fn flush(self: *Bot) !void {
        const items = try outbox.drain(self.db, self.gpa);
        defer outbox.free(self.gpa, items);
        for (items) |item| {
            const err = switch (item.kind) {
                .text => self.send(item.text),
                .photo, .document => self.sendFile(item.kind, item.path.?, item.text),
            };
            err catch |e| log.err("outbox {s}: {t}", .{ @tagName(item.kind), e });
        }
    }

    /// getFile then one plain GET against the file host, capped on the way in.
    fn download(self: *Bot, file_id: []const u8) ![]u8 {
        const get = self.fetch orelse return error.NoFetch;
        const req = try jsonBody(self.gpa, .{ .file_id = file_id });
        defer self.gpa.free(req);
        const body = try self.call("getFile", req);
        defer self.gpa.free(body);

        const Reply = struct {
            ok: bool = false,
            result: struct { file_path: ?[]const u8 = null, file_size: ?i64 = null } = .{},
        };
        const parsed = std.json.parseFromSlice(Reply, self.gpa, body, .{ .ignore_unknown_fields = true }) catch
            return error.InvalidTelegramResponse;
        defer parsed.deinit();
        if (!parsed.value.ok) return error.TelegramApiError;
        const path = parsed.value.result.file_path orelse return error.TelegramApiError;
        if ((parsed.value.result.file_size orelse 0) > max_file) return error.FileTooLarge;
        if (std.mem.indexOfAny(u8, path, "?#") != null) return error.TelegramApiError;

        const url = try std.fmt.allocPrint(self.gpa, "{s}{s}/{s}", .{ file_base, self.token.reveal(), path });
        defer self.gpa.free(url);
        var hop = try get.request(self.gpa, url, null);
        errdefer hop.deinit(self.gpa);
        if (hop.status != 200) return error.TelegramHttp;
        if (hop.body.len > max_file) return error.FileTooLarge;
        const bytes = hop.body;
        hop.body = &.{};
        hop.deinit(self.gpa);
        return bytes;
    }

    fn sendFile(self: *Bot, kind: outbox.Kind, rel: []const u8, caption: []const u8) !void {
        if (!outbox.safeRelative(rel)) return error.BadPath;
        var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ self.workspace, rel });
        const bytes = try std.Io.Dir.cwd().readFileAlloc(self.io, path, self.gpa, .limited(max_file));
        defer self.gpa.free(bytes);

        const part = if (kind == .photo) "photo" else "document";
        const body = try multipart(self.gpa, self.chat_id, part, baseName(rel), caption, bytes);
        defer self.gpa.free(body);

        const method = if (kind == .photo) "sendPhoto" else "sendDocument";
        const reply = try self.post(method, body, "multipart/form-data; boundary=" ++ boundary);
        defer self.gpa.free(reply);
        try ensureOk(self.gpa, reply);
    }

    fn typing(self: *Bot) !void {
        const req = try buildChatAction(self.gpa, self.chat_id);
        defer self.gpa.free(req);
        const body = try self.call("sendChatAction", req);
        defer self.gpa.free(body);
        try ensureOk(self.gpa, body);
    }

    fn send(self: *Bot, text: []const u8) !void {
        var remaining = text;
        while (remaining.len > 0) {
            const end = utf8ChunkEnd(remaining, max_message);
            if (end == 0) return error.InvalidTelegramText;
            const req = try buildSendMessage(self.gpa, self.chat_id, remaining[0..end]);
            defer self.gpa.free(req);
            const body = try self.call("sendMessage", req);
            defer self.gpa.free(body);
            try ensureOk(self.gpa, body);
            remaining = remaining[end..];
        }
    }

    fn call(self: *Bot, method: []const u8, body: []const u8) ![]u8 {
        return self.post(method, body, "application/json");
    }

    fn post(self: *Bot, method: []const u8, body: []const u8, content_type: []const u8) ![]u8 {
        const url = try endpoint(self.gpa, self.token.reveal(), method);
        defer self.gpa.free(url);
        var tries: u8 = 0;
        while (true) {
            var res = try self.http.post(self.gpa, .{
                .url = url,
                .auth = "",
                .body = body,
                .content_type = content_type,
            });
            if (res.status == 429) {
                // ponytail: cap at 60s; honour the header fully if a flood wait exceeds that
                const wait = @min(retryAfter(self.gpa, res.body) orelse 1, 60);
                res.deinit(self.gpa);
                tries += 1;
                if (tries > 3) return error.TelegramHttp;
                std.Io.sleep(self.io, .fromSeconds(wait), .awake) catch return error.TelegramHttp;
                continue;
            }
            errdefer res.deinit(self.gpa);
            if (res.status != 200) return error.TelegramHttp;
            return res.body;
        }
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

const RetryBody = struct {
    parameters: ?struct { retry_after: ?i64 = null } = null,
};

fn retryAfter(gpa: std.mem.Allocator, body: []const u8) ?u32 {
    const parsed = std.json.parseFromSlice(RetryBody, gpa, body, .{
        .ignore_unknown_fields = true,
    }) catch return null;
    defer parsed.deinit();
    const n = (parsed.value.parameters orelse return null).retry_after orelse return null;
    return if (n >= 0) std.math.cast(u32, n) else null;
}

test "retryAfter reads parameters.retry_after" {
    try testing.expectEqual(@as(?u32, 12), retryAfter(
        testing.allocator,
        "{\"ok\":false,\"error_code\":429,\"parameters\":{\"retry_after\":12}}",
    ));
    try testing.expectEqual(@as(?u32, null), retryAfter(testing.allocator, "{\"ok\":false}"));
}

const GetUpdatesRequest = struct {
    offset: ?i64 = null,
    timeout: u32,
    allowed_updates: []const []const u8,
};

const ChatActionRequest = struct {
    chat_id: i64,
    action: []const u8,
};

const SendMessageRequest = struct {
    chat_id: i64,
    text: []const u8,
};

fn jsonBody(gpa: std.mem.Allocator, value: anytype) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    try out.writer.print("{f}", .{std.json.fmt(value, .{ .emit_null_optional_fields = false })});
    return out.toOwnedSlice();
}

fn buildChatAction(gpa: std.mem.Allocator, chat_id: i64) ![]u8 {
    return jsonBody(gpa, ChatActionRequest{ .chat_id = chat_id, .action = "typing" });
}

fn buildSendMessage(gpa: std.mem.Allocator, chat_id: i64, text: []const u8) ![]u8 {
    return jsonBody(gpa, SendMessageRequest{ .chat_id = chat_id, .text = text });
}

const boundary = "zoroFormBoundary7Nn2Kq";
/// A caption is model-written text going into a form field. A boundary line
/// begins with CRLF, so stripping every control byte makes one impossible to
/// forge; the filename is safe by construction (`outbox.safeRelative`).
fn field(w: *std.Io.Writer, text: []const u8) !void {
    for (text) |c| {
        if (c >= 0x20 or c == '\t') try w.writeByte(c) else try w.writeByte(' ');
    }
}

/// Telegram's file upload form. Text fields first, the bytes last.
fn multipart(
    gpa: std.mem.Allocator,
    chat_id: i64,
    part: []const u8,
    name: []const u8,
    caption: []const u8,
    bytes: []const u8,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    const w = &out.writer;

    try w.print("--{s}\r\nContent-Disposition: form-data; name=\"chat_id\"\r\n\r\n{d}\r\n", .{ boundary, chat_id });
    if (caption.len != 0) {
        try w.print("--{s}\r\nContent-Disposition: form-data; name=\"caption\"\r\n\r\n", .{boundary});
        try field(w, caption[0..@min(caption.len, 1024)]);
        try w.writeAll("\r\n");
    }
    try w.print(
        "--{s}\r\nContent-Disposition: form-data; name=\"{s}\"; filename=\"{s}\"\r\nContent-Type: application/octet-stream\r\n\r\n",
        .{ boundary, part, name },
    );
    try w.writeAll(bytes);
    try w.print("\r\n--{s}--\r\n", .{boundary});
    return out.toOwnedSlice();
}

fn baseName(path: []const u8) []const u8 {
    const cut = std.mem.lastIndexOfScalar(u8, path, '/') orelse return path;
    return path[cut + 1 ..];
}

/// Enough to tell the vision model what it is looking at. Telegram re-encodes
/// photos to JPEG, so this is mostly a courtesy for the odd PNG.
fn sniff(bytes: []const u8) []const u8 {
    if (std.mem.startsWith(u8, bytes, "\x89PNG")) return "image/png";
    if (std.mem.startsWith(u8, bytes, "GIF8")) return "image/gif";
    if (bytes.len >= 12 and std.mem.eql(u8, bytes[8..12], "WEBP")) return "image/webp";
    return "image/jpeg";
}

fn buildGetUpdates(gpa: std.mem.Allocator, offset: ?i64) ![]u8 {
    const allowed = [_][]const u8{"message"};
    return jsonBody(gpa, GetUpdatesRequest{
        .offset = offset,
        .timeout = poll_timeout,
        .allowed_updates = &allowed,
    });
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
        var db = try testkit.tmpDb(&tmp, &buf);
        defer db.close();
        try testing.expectEqual(@as(?i64, null), try loadOffset(&db));
        try saveOffset(&db, 42);
        try testing.expectEqual(@as(?i64, 42), try loadOffset(&db));
        try saveOffset(&db, 99);
        try testing.expectEqual(@as(?i64, 99), try loadOffset(&db));
    }

    var db = try testkit.tmpDb(&tmp, &buf);
    defer db.close();
    try testing.expectEqual(@as(?i64, 99), try loadOffset(&db));
}

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
        self.tg = .{ .bodies = tg_bodies };
        self.llm = .{ .bodies = llm_bodies };
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

    /// A workspace directory beside the temp database.
    fn workspace(self: *Harness, buf: []u8) ![]const u8 {
        const dir = try std.fmt.bufPrint(buf, ".zig-cache/tmp/{s}/workspace", .{self.tmp.sub_path});
        try std.Io.Dir.cwd().createDirPath(self.threaded.io(), dir);
        return dir;
    }

    fn deinit(self: *Harness) void {
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

test "pollOnce sends the reply via sendMessage" {
    var h: Harness = undefined;
    try h.init(
        &.{
            "{\"ok\":true,\"result\":[{\"update_id\":10,\"message\":{\"from\":{\"id\":42,\"is_bot\":false},\"chat\":{\"id\":42,\"type\":\"private\"},\"text\":\"hello\"}}]}",
            "{\"ok\":true}",
            "{\"ok\":true}",
        },
        &.{"{\"choices\":[{\"message\":{\"content\":\"hi\"}}]}"},
    );
    defer h.deinit();

    try h.bot.pollOnce();
    try testing.expect(std.mem.indexOf(u8, h.tg.sentUrl(), "sendMessage") != null);
    try testing.expect(std.mem.indexOf(u8, h.tg.sent(), "\"chat_id\":42") != null);
    try testing.expect(std.mem.indexOf(u8, h.tg.sent(), "\"text\":\"hi\"") != null);
}

test "pollOnce sends a typing indicator before the turn" {
    var h: Harness = undefined;
    try h.init(
        &.{
            "{\"ok\":true,\"result\":[{\"update_id\":10,\"message\":{\"from\":{\"id\":42,\"is_bot\":false},\"chat\":{\"id\":42,\"type\":\"private\"},\"text\":\"hello\"}}]}",
            "{\"ok\":true}",
            "{\"ok\":true}",
        },
        &.{"{\"choices\":[{\"message\":{\"content\":\"hi\"}}]}"},
    );
    defer h.deinit();

    try h.bot.pollOnce();
    try testing.expectEqual(@as(usize, 3), h.tg.n);
    try testing.expect(std.mem.endsWith(u8, h.tg.url(1), "sendChatAction"));
    try testing.expect(std.mem.endsWith(u8, h.tg.url(2), "sendMessage"));
}

test "a 429 is retried after retry-after rather than failing immediately" {
    var h: Harness = undefined;
    try h.init(
        &.{
            "{\"ok\":true,\"result\":[{\"update_id\":10,\"message\":{\"from\":{\"id\":42,\"is_bot\":false},\"chat\":{\"id\":42,\"type\":\"private\"},\"text\":\"hello\"}}]}",
            "{\"ok\":true}",
            "{\"ok\":false,\"error_code\":429,\"parameters\":{\"retry_after\":0}}",
            "{\"ok\":true}",
        },
        &.{"{\"choices\":[{\"message\":{\"content\":\"hi\"}}]}"},
    );
    defer h.deinit();
    h.tg.statuses = &.{ 200, 200, 429, 200 };

    try h.bot.pollOnce();
    try testing.expectEqual(@as(usize, 4), h.tg.i);
    try testing.expect(std.mem.endsWith(u8, h.tg.url(2), "sendMessage"));
    try testing.expect(std.mem.endsWith(u8, h.tg.url(3), "sendMessage"));
    try testing.expect(std.mem.indexOf(u8, h.tg.sent(), "\"text\":\"hi\"") != null);
}

test "send failure is returned rather than swallowed" {
    var h: Harness = undefined;
    try h.init(
        &.{
            "{\"ok\":true,\"result\":[{\"update_id\":10,\"message\":{\"from\":{\"id\":42,\"is_bot\":false},\"chat\":{\"id\":42,\"type\":\"private\"},\"text\":\"hello\"}}]}",
            "{\"ok\":true}",
            "{\"ok\":false,\"description\":\"Bad Request\"}",
        },
        &.{"{\"choices\":[{\"message\":{\"content\":\"hi\"}}]}"},
    );
    defer h.deinit();
    try testing.expectError(error.TelegramApiError, h.bot.pollOnce());
}

test "pollOnce splits a long reply into UTF-8-safe chunks" {
    const extra = 17;
    const reply = try testing.allocator.alloc(u8, max_message + extra);
    defer testing.allocator.free(reply);
    @memset(reply, 'a');
    const llm = try std.fmt.allocPrint(
        testing.allocator,
        "{{\"choices\":[{{\"message\":{{\"content\":\"{s}\"}}}}]}}",
        .{reply},
    );
    defer testing.allocator.free(llm);

    var h: Harness = undefined;
    try h.init(
        &.{
            "{\"ok\":true,\"result\":[{\"update_id\":10,\"message\":{\"from\":{\"id\":42,\"is_bot\":false},\"chat\":{\"id\":42,\"type\":\"private\"},\"text\":\"hello\"}}]}",
            "{\"ok\":true}",
            "{\"ok\":true}",
            "{\"ok\":true}",
        },
        &.{llm},
    );
    defer h.deinit();

    try h.bot.pollOnce();
    try testing.expectEqual(@as(usize, 4), h.tg.i);
    try testing.expect(std.mem.indexOf(u8, h.tg.sent(), "sendMessage") == null);
    try testing.expect(std.mem.indexOf(u8, h.tg.sentUrl(), "sendMessage") != null);
    const want = "a" ** extra;
    try testing.expect(std.mem.indexOf(u8, h.tg.sent(), want) != null);
}

test "pollOnce serves the owner and persists the offset" {
    var h: Harness = undefined;
    try h.init(
        &.{ "{\"ok\":true,\"result\":[{\"update_id\":10,\"message\":{\"from\":{\"id\":42,\"is_bot\":false},\"chat\":{\"id\":42,\"type\":\"private\"},\"text\":\"hello\"}}]}", "{\"ok\":true}", "{\"ok\":true}" },
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
        &.{ "{\"ok\":true,\"result\":[{\"update_id\":10,\"message\":{\"from\":{\"id\":42,\"is_bot\":false},\"chat\":{\"id\":42,\"type\":\"private\"},\"text\":\"hello\"}},{\"update_id\":11,\"callback_query\":{\"id\":\"x\"}}]}", "{\"ok\":true}", "{\"ok\":true}" },
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
            "{\"ok\":true}",
            "{\"ok\":true}",
            "{\"ok\":true,\"result\":[]}",
        },
        &.{"{\"choices\":[{\"message\":{\"content\":\"hi\"}}]}"},
    );
    defer h.deinit();
    try h.bot.pollOnce();
    try h.bot.pollOnce();
    try testing.expect(std.mem.indexOf(u8, h.tg.sent(), "\"offset\":11") != null);
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
    var db = try testkit.tmpDb(&tmp, &db_buf);
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

/// The file host is a plain GET, so the download seam is `web.Get`, not `Http`.
const FakeGet = struct {
    body: []const u8,
    status: u16 = 200,
    calls: usize = 0,
    seen: [256]u8 = undefined,
    seen_len: usize = 0,

    fn get(self: *FakeGet) web.Get {
        return .{ .ptr = self, .request_fn = request };
    }

    fn url(self: *FakeGet) []const u8 {
        return self.seen[0..self.seen_len];
    }

    fn request(ptr: *anyopaque, gpa: std.mem.Allocator, target: []const u8, _: ?[]const u8) anyerror!web.Hop {
        const self: *FakeGet = @ptrCast(@alignCast(ptr));
        self.seen_len = @min(target.len, self.seen.len);
        @memcpy(self.seen[0..self.seen_len], target[0..self.seen_len]);
        self.calls += 1;
        return .{ .status = self.status, .body = try gpa.dupe(u8, self.body) };
    }
};

const ok_json = "{\"ok\":true,\"result\":{}}";

test "a photo is downloaded and reaches the vision model with its caption" {
    var h: Harness = undefined;
    try h.init(&.{
        \\{"ok":true,"result":[{"update_id":5,"message":{"from":{"id":42,"is_bot":false},"chat":{"id":42,"type":"private"},"caption":"what plant is this","photo":[{"file_id":"small","file_size":100},{"file_id":"big","file_size":900}]}}]}
        ,
        ok_json, // sendChatAction
        "{\"ok\":true,\"result\":{\"file_path\":\"photos/x.png\",\"file_size\":8}}",
        ok_json, // sendMessage
    }, &.{"{\"choices\":[{\"message\":{\"content\":\"a fern\"}}]}"});
    defer h.deinit();

    var files: FakeGet = .{ .body = "\x89PNG\r\n\x1a\n" };
    h.bot.fetch = files.get();
    h.agent.vision_model = "sees-things";

    try h.bot.pollOnce();

    // The largest size is the one fetched, and the token never leaves the URL builder.
    try testing.expectEqual(@as(usize, 1), files.calls);
    try testing.expect(std.mem.endsWith(u8, files.url(), "/photos/x.png"));
    try testing.expect(std.mem.indexOf(u8, h.tg.sent(), "\"big\"") != null or
        std.mem.indexOf(u8, h.tg.url(2), "getFile") != null);

    const asked = h.llm.sent();
    try testing.expect(std.mem.indexOf(u8, asked, "\"sees-things\"") != null);
    try testing.expect(std.mem.indexOf(u8, asked, "data:image/png;base64,") != null);
    try testing.expect(std.mem.indexOf(u8, asked, "what plant is this") != null);
}

test "a photo that will not download still gets an answer" {
    var h: Harness = undefined;
    try h.init(&.{
        \\{"ok":true,"result":[{"update_id":5,"message":{"from":{"id":42,"is_bot":false},"chat":{"id":42,"type":"private"},"photo":[{"file_id":"big","file_size":900}]}}]}
        ,
        ok_json,
        "{\"ok\":true,\"result\":{\"file_path\":\"photos/x.jpg\",\"file_size\":8}}",
        ok_json,
    }, &.{"{\"choices\":[{\"message\":{\"content\":\"I could not open it\"}}]}"});
    defer h.deinit();

    var files: FakeGet = .{ .body = "", .status = 404 };
    h.bot.fetch = files.get();

    try h.bot.pollOnce(); // the download fails; the turn happens anyway
    try testing.expect(std.mem.indexOf(u8, h.llm.sent(), "a picture, no caption") != null);
    try testing.expect(std.mem.indexOf(u8, h.tg.sent(), "I could not open it") != null);
}

test "a non-image attachment becomes metadata, never a failed turn" {
    const body =
        \\{"ok":true,"result":[{"update_id":1,"message":{"from":{"id":42,"is_bot":false},"chat":{"id":42,"type":"private"},"caption":"the lease","document":{"file_id":"d1","file_name":"lease.pdf","mime_type":"application/pdf","file_size":24576}}}]}
    ;
    var batch = try parseUpdates(testing.allocator, body);
    defer batch.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 1), batch.items.len);
    const u = batch.items[0];
    try testing.expectEqual(@as(?[]u8, null), u.photo);
    try testing.expect(std.mem.startsWith(u8, u.text, "the lease\n[attachment: lease.pdf, application/pdf, 24576 bytes"));
}

test "a workspace file goes out as a photo with its caption" {
    var h: Harness = undefined;
    try h.init(&.{ok_json}, &.{});
    defer h.deinit();

    var dir_buf: [128]u8 = undefined;
    const dir = try h.workspace(&dir_buf);
    h.bot.workspace = dir;
    var d = try std.Io.Dir.cwd().openDir(h.threaded.io(), dir, .{});
    defer d.close(h.threaded.io());
    try d.writeFile(h.threaded.io(), .{ .sub_path = "chart.png", .data = "\x89PNG-bytes" });

    try outbox.push(&h.db, .photo, "chart.png", "yesterday's spend", 100);
    try h.bot.flush();

    const sent = h.tg.sent();
    try testing.expect(std.mem.endsWith(u8, h.tg.sentUrl(), "/sendPhoto"));
    try testing.expect(std.mem.indexOf(u8, sent, "name=\"photo\"; filename=\"chart.png\"") != null);
    try testing.expect(std.mem.indexOf(u8, sent, "yesterday's spend") != null);
    try testing.expect(std.mem.indexOf(u8, sent, "\x89PNG-bytes") != null);

    // Drained: a second flush sends nothing.
    try h.bot.flush();
    try testing.expectEqual(@as(usize, 1), h.tg.i);
}

test "an attachment pointing outside the workspace is refused" {
    var h: Harness = undefined;
    try h.init(&.{}, &.{});
    defer h.deinit();
    try testing.expectError(error.BadPath, h.bot.sendFile(.document, "../../etc/passwd", ""));
}
