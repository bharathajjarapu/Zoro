const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const testkit = @import("../testing/testkit.zig");
const FakeHttp = testkit.FakeHttp;
const agent = @import("../agent/root.zig");
const tools = @import("../tools/root.zig");
const config = @import("../app/config.zig");
const Db = @import("../data/db.zig").Db;
const outbox = @import("../data/outbox.zig");
const tasks = @import("../data/tasks.zig");
const web = @import("../net/web.zig");
const workspace = @import("../app/workspace.zig");
const updates = @import("update.zig");

const log = std.log.scoped(.telegram);

const max_message = 3900;
const max_callback = 64;
const sticker_ttl: i64 = 5 * 60;
const max_model_image: usize = 4 * 1024 * 1024;
const max_album: usize = workspace.max_transfer;
const request_timeout_ms: i64 = if (builtin.is_test) 50 else 60_000;

pub const max_text = updates.max_text;
pub const max_file = updates.max_file;
pub const Kind = updates.Kind;
pub const Batch = updates.Batch;
pub const Update = updates.Update;
pub const parseUpdates = updates.parseUpdates;
const utf8ChunkEnd = updates.utf8ChunkEnd;

fn loadPending(db: *Db, gpa: std.mem.Allocator, owner_id: i64, chat_id: i64) ![]Update {
    var q = try db.prepare(
        \\SELECT id, text, message_id, reply_id, reply_text, kind, file_id, preview_id, file_name, mime,
        \\       file_size, file_unique_id, emoji, sticker_type, callback_id,
        \\       callback_data, latitude, longitude, owner_text
        \\FROM telegram_updates WHERE status = 'pending' ORDER BY id
    );
    defer q.finalize();
    var items: std.ArrayList(Update) = .empty;
    errdefer freeUpdates(gpa, items.items);
    while (try q.step()) {
        const kind = std.meta.stringToEnum(Kind, q.text(5)) orelse .text;
        var u: Update = undefined;
        {
            const chat_type = try gpa.dupe(u8, "private");
            errdefer gpa.free(chat_type);
            const reply_text = if (q.isNull(4)) null else try gpa.dupe(u8, q.text(4));
            errdefer if (reply_text) |text| gpa.free(text);
            const text = try gpa.dupe(u8, q.text(1));
            errdefer gpa.free(text);
            u = .{
                .update_id = q.int(0),
                .from_id = owner_id,
                .chat_id = chat_id,
                .chat_type = chat_type,
                .message_id = if (q.isNull(2)) 0 else q.int(2),
                .reply_id = if (q.isNull(3)) null else q.int(3),
                .reply_text = reply_text,
                .kind = kind,
                .text = text,
            };
        }
        errdefer u.deinit(gpa);
        const file_id = if (q.isNull(6)) null else try gpa.dupe(u8, q.text(6));
        if (kind == .photo) u.photo = file_id else u.file_id = file_id;
        u.preview_id = if (q.isNull(7)) null else try gpa.dupe(u8, q.text(7));
        u.file_name = if (q.isNull(8)) null else try gpa.dupe(u8, q.text(8));
        u.mime = if (q.isNull(9)) null else try gpa.dupe(u8, q.text(9));
        u.file_size = if (q.isNull(10)) null else q.int(10);
        u.unique_id = if (q.isNull(11)) null else try gpa.dupe(u8, q.text(11));
        u.emoji = if (q.isNull(12)) null else try gpa.dupe(u8, q.text(12));
        u.sticker_type = if (q.isNull(13)) null else try gpa.dupe(u8, q.text(13));
        u.callback_id = if (q.isNull(14)) null else try gpa.dupe(u8, q.text(14));
        u.callback_data = if (q.isNull(15)) null else try gpa.dupe(u8, q.text(15));
        u.latitude = if (q.isNull(16)) null else q.float(16);
        u.longitude = if (q.isNull(17)) null else q.float(17);
        u.owner_text = if (q.isNull(18)) null else try gpa.dupe(u8, q.text(18));
        try items.append(gpa, u);
    }
    return items.toOwnedSlice(gpa);
}

fn freeUpdates(gpa: std.mem.Allocator, items: []Update) void {
    for (items) |*u| u.deinit(gpa);
    gpa.free(items);
}

fn commandPrompt(text: []const u8) []const u8 {
    const cmd = std.mem.sliceTo(text, ' ');
    if (std.mem.eql(u8, cmd, "/status")) return "Report current task, routine, and delivery status briefly.";
    if (std.mem.eql(u8, cmd, "/tasks")) return "List my tasks.";
    if (std.mem.eql(u8, cmd, "/routines")) return "List my routines.";
    if (std.mem.eql(u8, cmd, "/memory") or std.mem.eql(u8, cmd, "/diary")) return text;
    if (std.mem.eql(u8, cmd, "/skills")) return "List available skills.";
    if (std.mem.eql(u8, cmd, "/character")) return "Summarize your current character files.";
    if (std.mem.eql(u8, cmd, "/learn")) return "Report the learning mode and pending proposals.";
    if (std.mem.eql(u8, cmd, "/stop")) return "stop";
    return text;
}

fn beginStickerLearning(db: *Db, alias: []const u8, now: i64) !void {
    var q = try db.prepare(
        \\INSERT INTO sticker_learning(id, alias, created, expires) VALUES (1, ?, ?, ?)
        \\ON CONFLICT(id) DO UPDATE SET alias = excluded.alias, created = excluded.created, expires = excluded.expires
    );
    defer q.finalize();
    try q.bind(1, alias);
    try q.bind(2, now);
    try q.bind(3, now + sticker_ttl);
    _ = try q.step();
}

fn takeStickerLearning(db: *Db, gpa: std.mem.Allocator, u: Update, now: i64) !?[]u8 {
    var q = try db.prepare("SELECT alias, expires FROM sticker_learning WHERE id = 1");
    defer q.finalize();
    if (!try q.step()) return null;
    if (q.int(1) <= now) {
        try db.exec("DELETE FROM sticker_learning;");
        return null;
    }
    const alias = try gpa.dupe(u8, q.text(0));
    errdefer gpa.free(alias);
    var put = try db.prepare(
        \\INSERT INTO sticker_aliases(alias, file_id, unique_id, emoji, updated) VALUES (?, ?, ?, ?, ?)
        \\ON CONFLICT(alias) DO UPDATE SET file_id = excluded.file_id, unique_id = excluded.unique_id,
        \\emoji = excluded.emoji, updated = excluded.updated
    );
    defer put.finalize();
    try put.bind(1, alias);
    try put.bind(2, u.file_id.?);
    try put.bind(3, u.unique_id orelse "");
    try put.bind(4, u.emoji);
    try put.bind(5, now);
    _ = try put.step();
    try db.exec("DELETE FROM sticker_learning;");
    return alias;
}

fn listStickers(db: *Db, gpa: std.mem.Allocator) ![]u8 {
    var q = try db.prepare("SELECT alias, emoji FROM sticker_aliases ORDER BY alias");
    defer q.finalize();
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    while (try q.step()) try out.writer.print("{s}{s}{s}\n", .{ q.text(0), if (q.isNull(1)) "" else " ", q.text(1) });
    if (out.written().len == 0) try out.writer.writeAll("No learned stickers.");
    return out.toOwnedSlice();
}

fn safeName(gpa: std.mem.Allocator, raw: []const u8) ![]u8 {
    const base = baseName(raw);
    const n = @min(base.len, 96);
    const out = try gpa.alloc(u8, if (n == 0) 4 else n);
    if (n == 0) {
        @memcpy(out, "file");
        return out;
    }
    for (base[0..n], 0..) |c, i| out[i] = if (std.ascii.isAlphanumeric(c) or c == '.' or c == '-' or c == '_') c else '_';
    return out;
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

/// Records owner work before Telegram's offset acknowledges it. False is a replay.
fn accept(db: *Db, u: Update, now: i64) !bool {
    try db.exec("BEGIN IMMEDIATE;");
    errdefer db.exec("ROLLBACK;") catch {};
    var q = try db.prepare(
        \\INSERT OR IGNORE INTO telegram_updates(
        \\ id, status, text, created, updated, message_id, reply_id, reply_text, kind,
        \\ file_id, preview_id, file_name, mime, file_size, file_unique_id, emoji,
        \\ sticker_type, callback_id, callback_data, latitude, longitude, owner_text)
        \\VALUES (?, 'pending', ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    );
    defer q.finalize();
    try q.bind(1, u.update_id);
    try q.bind(2, u.text);
    try q.bind(3, now);
    try q.bind(4, now);
    try q.bind(5, u.message_id);
    try q.bind(6, u.reply_id);
    try q.bind(7, u.reply_text);
    try q.bind(8, @tagName(u.kind));
    try q.bind(9, u.photo orelse u.file_id);
    try q.bind(10, u.preview_id);
    try q.bind(11, u.file_name);
    try q.bind(12, u.mime);
    try q.bind(13, u.file_size);
    try q.bind(14, u.unique_id);
    try q.bind(15, u.emoji);
    try q.bind(16, u.sticker_type);
    try q.bind(17, u.callback_id);
    try q.bind(18, u.callback_data);
    try q.bind(19, u.latitude);
    try q.bind(20, u.longitude);
    try q.bind(21, u.owner_text);
    _ = try q.step();
    const fresh = cChanges(db) == 1;
    try saveOffset(db, u.update_id + 1);
    try db.exec("COMMIT;");
    return fresh;
}

fn updateStatus(db: *Db, id: i64, status: []const u8, now: i64) !void {
    var q = try db.prepare("UPDATE telegram_updates SET status = ?, updated = ? WHERE id = ?");
    defer q.finalize();
    try q.bind(1, status);
    try q.bind(2, now);
    try q.bind(3, id);
    _ = try q.step();
}

fn cChanges(db: *Db) i64 {
    const c = @import("c");
    return c.sqlite3_changes(db.ptr);
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
    /// Separate transport for activity and stop polling during a model call.
    live_http: ?agent.Http = null,
    db: *Db,
    agent: *agent.Agent,
    token: config.Secret,
    owner_id: i64,
    chat_id: i64,
    /// Plain GET, used only to pull a photo off Telegram's file host.
    fetch: ?web.Get = null,
    /// The one directory an outbound attachment may come from.
    workspace: []const u8 = "workspace",
    inbox: []const u8 = "inbox",
    cancel: ?*const std.atomic.Value(bool) = null,
    shutdown: ?*const fn () bool = null,

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
            if (u.kind == .callback) self.answerCallback(u.callback_id.?, if (admit(u, self.owner_id, self.chat_id)) "" else "Not allowed") catch |err|
                log.warn("callback answer: {t}", .{err});
            if (!admit(u, self.owner_id, self.chat_id)) {
                try saveOffset(self.db, u.update_id + 1);
                continue;
            }
            const now = std.Io.Timestamp.now(self.io, .real).toSeconds();
            if (!try accept(self.db, u, now)) continue;
            try updateStatus(self.db, u.update_id, "processing", now);
            self.process(u) catch |err| {
                if (err == error.TurnCancelled) {
                    try updateStatus(self.db, u.update_id, "cancelled", now);
                    try self.flush();
                    continue;
                }
                try updateStatus(self.db, u.update_id, "failed", now);
                return err;
            };
            try updateStatus(self.db, u.update_id, "completed", now);
            try self.flush();
        }
        if (batch.next_offset) |n| try saveOffset(self.db, n);
    }

    pub fn run(self: *Bot, stop: *const fn () bool) !void {
        self.shutdown = stop;
        defer self.shutdown = null;
        try outbox.recover(self.db);
        try self.recoverUpdates();
        self.setCommands() catch |err| log.warn("commands: {t}", .{err});
        while (!stop()) {
            self.flush() catch |err| log.warn("outbox: {t}", .{err});
            self.pollOnce() catch |err| {
                if (err == error.Cancelled and stop()) break;
                log.err("{t}", .{err});
                std.Io.sleep(self.io, .fromSeconds(1), .awake) catch {};
            };
        }
    }

    fn process(self: *Bot, u: Update) !void {
        if (u.kind == .callback) return self.handleCallback(u);
        if (u.kind == .reaction) return;
        if (try self.handleCommand(u)) return;
        if (self.live_http == null) self.sendActivity(self.http, "typing") catch |err| log.warn("typing: {t}", .{err});
        try self.answer(u);
    }

    fn recoverUpdates(self: *Bot) !void {
        try self.db.exec("UPDATE telegram_updates SET status = 'uncertain', updated = unixepoch() WHERE status = 'processing';");

        const pending = try loadPending(self.db, self.gpa, self.owner_id, self.chat_id);
        defer freeUpdates(self.gpa, pending);
        for (pending) |u| {
            const now = std.Io.Timestamp.now(self.io, .real).toSeconds();
            try updateStatus(self.db, u.update_id, "processing", now);
            self.process(u) catch {
                try updateStatus(self.db, u.update_id, "failed", now);
                continue;
            };
            try updateStatus(self.db, u.update_id, "completed", now);
        }
        try self.flush();
    }

    fn handleCallback(self: *Bot, u: Update) !void {
        const data = u.callback_data orelse return;
        if (data.len < 3 or data[1] != ':') return;
        const id = std.fmt.parseInt(i64, data[2..], 10) catch return;
        const now = std.Io.Timestamp.now(self.io, .real).toSeconds();
        switch (data[0]) {
            'a', 'd' => {
                const reply = try self.agent.resolveApprovalId(id, if (data[0] == 'a') .approve else .deny);
                defer self.gpa.free(reply);
                try outbox.pushReply(self.db, .text, null, reply, u.message_id, now);
            },
            's' => {
                const stopped = if (self.agent.pool) |pool| pool.cancel(id) else false;
                if (stopped) tasks.setStatus(self.db, id, .cancelled) catch {};
                try outbox.pushReply(self.db, .text, null, if (stopped) "Stopping that task." else "That task is no longer running.", u.message_id, now);
            },
            'r' => {
                const queued = try outbox.retryDelivery(self.db, id);
                try outbox.pushReply(self.db, .text, null, if (queued) "Queued one retry." else "That delivery cannot be retried.", u.message_id, now);
            },
            else => {},
        }
    }

    fn handleCommand(self: *Bot, u: Update) !bool {
        const text = std.mem.trim(u8, u.text, &std.ascii.whitespace);
        if (std.mem.eql(u8, text, "/help")) {
            try self.queueReply(u.message_id, "Use /status, /tasks, /routines, /memory, /diary, /skills, /character, /learn, /model, /cache, /compact, /clear, /stickers, /stop, or /new.");
            return true;
        }
        if (std.mem.eql(u8, text, "/stop")) {
            try self.queueReply(u.message_id, "Nothing is running right now.");
            return true;
        }
        const learn = "/learn sticker ";
        if (std.mem.startsWith(u8, text, learn)) {
            const alias = std.mem.trim(u8, text[learn.len..], &std.ascii.whitespace);
            if (!outbox.safeAlias(alias)) {
                try self.queueReply(u.message_id, "Use /learn sticker followed by one short alias.");
                return true;
            }
            const now = std.Io.Timestamp.now(self.io, .real).toSeconds();
            try beginStickerLearning(self.db, alias, now);
            try self.queueReply(u.message_id, "Send the sticker within five minutes.");
            return true;
        }
        if (std.mem.eql(u8, text, "/stickers")) {
            const list = try listStickers(self.db, self.gpa);
            defer self.gpa.free(list);
            try self.queueReply(u.message_id, list);
            return true;
        }
        const send_prefix = "/sticker ";
        if (std.mem.startsWith(u8, text, send_prefix)) {
            const alias = std.mem.trim(u8, text[send_prefix.len..], &std.ascii.whitespace);
            if (!outbox.safeAlias(alias) or !try outbox.stickerExists(self.db, alias))
                try self.queueReply(u.message_id, "Unknown sticker alias.")
            else
                try outbox.pushReply(self.db, .sticker, alias, "", u.message_id, std.Io.Timestamp.now(self.io, .real).toSeconds());
            return true;
        }
        return false;
    }

    fn queueReply(self: *Bot, reply_id: i64, text: []const u8) !void {
        try outbox.pushReply(self.db, .text, null, text, reply_id, std.Io.Timestamp.now(self.io, .real).toSeconds());
    }

    fn context(self: *Bot, u: Update, picture: *?[]u8, mime: *[]const u8) ![]u8 {
        if (u.kind == .location) return std.fmt.allocPrint(self.gpa, "{s}{s}[location: {d:.6}, {d:.6}]", .{
            u.text,
            if (u.text.len == 0) "" else "\n",
            u.latitude.?,
            u.longitude.?,
        });
        if (u.kind == .sticker) {
            const learned = try takeStickerLearning(self.db, self.gpa, u, std.Io.Timestamp.now(self.io, .real).toSeconds());
            defer if (learned) |alias| self.gpa.free(alias);
            const image_id = if (std.mem.eql(u8, u.sticker_type orelse "", "static")) u.file_id else u.preview_id;
            if (image_id) |id| {
                if (self.download(id)) |bytes| {
                    if (bytes.len <= max_model_image) {
                        picture.* = bytes;
                        mime.* = sniff(bytes);
                    } else self.gpa.free(bytes);
                } else |_| {}
            }
            return std.fmt.allocPrint(self.gpa, "[sticker: {s}, {s}{s}{s}]", .{
                u.emoji orelse "no emoji",
                u.sticker_type orelse "unknown",
                if (learned != null) ", learned as " else "",
                learned orelse "",
            });
        }

        if ((u.file_size orelse 0) > max_file) return std.fmt.allocPrint(self.gpa, "{s}{s}[{s}: too large to download, {d} bytes]", .{
            u.text, if (u.text.len == 0) "" else "\n", @tagName(u.kind), u.file_size.?,
        });

        const bytes = self.download(u.file_id.?) catch |err| return std.fmt.allocPrint(
            self.gpa,
            "{s}{s}[{s}: download failed ({s})]",
            .{ u.text, if (u.text.len == 0) "" else "\n", @tagName(u.kind), @errorName(err) },
        );
        var keep_bytes = false;
        defer if (!keep_bytes) self.gpa.free(bytes);
        const name = try safeName(self.gpa, u.file_name orelse @tagName(u.kind));
        defer self.gpa.free(name);
        var rel_buf: [workspace.max_path]u8 = undefined;
        const rel = try std.fmt.bufPrint(&rel_buf, "{s}/{d}-{s}", .{ self.inbox, u.update_id, name });
        try self.ensureInbox();
        try workspace.writeBounded(self.io, self.workspace, rel, bytes, max_file);
        const detected = imageMime(bytes);
        if (bytes.len <= max_model_image and (detected != null or std.mem.startsWith(u8, u.mime orelse "", "image/"))) {
            picture.* = bytes;
            mime.* = detected orelse u.mime.?;
            keep_bytes = true;
        } else if (u.preview_id) |preview_id| {
            if (self.download(preview_id)) |preview| {
                if (preview.len <= max_model_image) {
                    picture.* = preview;
                    mime.* = sniff(preview);
                } else self.gpa.free(preview);
            } else |_| {}
        }
        const note = switch (u.kind) {
            .voice => "Voice transcription is unavailable; the original file is saved.",
            .audio, .video, .animation => "This media is saved, but its contents were not interpreted.",
            else => "The file is saved.",
        };
        if (std.mem.startsWith(u8, u.mime orelse "", "text/") and bytes.len <= max_text and std.unicode.utf8ValidateSlice(bytes)) {
            return std.fmt.allocPrint(self.gpa, "{s}{s}[{s} in inbox: {s}, {s}, {d} bytes]\n{s}", .{
                u.text,                  if (u.text.len == 0) "" else "\n", @tagName(u.kind), rel,
                u.mime orelse "unknown", bytes.len,                         bytes,
            });
        }
        return std.fmt.allocPrint(self.gpa, "{s}{s}[{s} in inbox: {s}, {s}, {d} bytes] {s}", .{
            u.text,                  if (u.text.len == 0) "" else "\n", @tagName(u.kind), rel,
            u.mime orelse "unknown", bytes.len,                         note,
        });
    }

    fn ensureInbox(self: *Bot) !void {
        try workspace.makeDir(self.io, self.workspace, self.inbox);
    }

    fn sendStickerAlias(self: *Bot, alias: []const u8, reply_id: ?i64) !void {
        var q = try self.db.prepare("SELECT file_id FROM sticker_aliases WHERE alias = ?");
        defer q.finalize();
        try q.bind(1, alias);
        if (!try q.step()) return error.UnknownSticker;
        self.sendActivity(self.live_http, "choose_sticker") catch |err| log.warn("sticker action: {t}", .{err});
        const req = try buildFileId(self.gpa, self.chat_id, "sticker", q.text(0), reply_id);
        defer self.gpa.free(req);
        const body = try self.call("sendSticker", req);
        defer self.gpa.free(body);
        try ensureOk(self.gpa, body);
    }

    fn answerCallback(self: *Bot, id: []const u8, text: []const u8) !void {
        const req = try jsonBody(self.gpa, .{ .callback_query_id = id, .text = text });
        defer self.gpa.free(req);
        const body = try self.call("answerCallbackQuery", req);
        defer self.gpa.free(body);
        try ensureOk(self.gpa, body);
    }

    fn setCommands(self: *Bot) !void {
        const body = try self.call("setMyCommands", commands_json);
        defer self.gpa.free(body);
        try ensureOk(self.gpa, body);
    }

    /// Failed image downloads still produce a text turn.
    fn answer(self: *Bot, u: Update) !void {
        var picture: ?[]u8 = null;
        defer if (picture) |p| self.gpa.free(p);
        var mime: []const u8 = "image/jpeg";
        var prompt: ?[]u8 = null;
        defer if (prompt) |s| self.gpa.free(s);

        if (u.photo) |file_id| {
            if (self.download(file_id)) |bytes| {
                var keep_bytes = false;
                defer if (!keep_bytes) self.gpa.free(bytes);
                const rel = try std.fmt.allocPrint(self.gpa, "{s}/{d}-photo.jpg", .{ self.inbox, u.update_id });
                defer self.gpa.free(rel);
                try self.ensureInbox();
                try workspace.writeBounded(self.io, self.workspace, rel, bytes, max_file);
                prompt = try std.fmt.allocPrint(self.gpa, "{s}{s}[photo in inbox: {s}, {d} bytes]", .{
                    u.text, if (u.text.len == 0) "" else "\n", rel, bytes.len,
                });
                if (bytes.len <= max_model_image) {
                    picture = bytes;
                    mime = sniff(bytes);
                    keep_bytes = true;
                }
            } else |err| {
                log.warn("photo {s}: {t}", .{ file_id, err });
                prompt = try std.fmt.allocPrint(self.gpa, "{s}{s}[photo download failed: {s}]", .{
                    u.text, if (u.text.len == 0) "" else "\n", @errorName(err),
                });
            }
        }

        if (u.kind != .photo and u.kind != .text) prompt = try self.context(u, &picture, &mime);
        const input = commandPrompt(u.text);
        if (u.reply_text) |quoted| {
            const combined = try std.fmt.allocPrint(self.gpa, "[replying to: {s}]\n{s}", .{ quoted, prompt orelse input });
            if (prompt) |old| self.gpa.free(old);
            prompt = combined;
        }

        var cancel: agent.Workers = .{};
        self.cancel = &cancel.stop;
        defer self.cancel = null;
        var done: std.atomic.Value(bool) = .init(false);
        var stop_update: std.atomic.Value(i64) = .init(0);
        var activity_thread: ?std.Thread = null;
        if (self.live_http != null) {
            activity_thread = try std.Thread.spawn(.{}, activity, .{ self, &cancel, &done, &stop_update, u.update_id + 1 });
        }

        const result = self.agent.turnWithCancel(.{
            .text = prompt orelse if (input.len != 0) input else "(a picture, no caption)",
            .owner_text = u.owner_text,
            .image = if (picture) |p| .{ .mime = mime, .data = p } else null,
        }, &cancel);
        cancel.stop.store(true, .release);
        done.store(true, .release);
        if (activity_thread) |thread| thread.join();
        if (stop_update.load(.acquire) != 0) try recordStop(self.db, stop_update.load(.acquire), std.Io.Timestamp.now(self.io, .real).toSeconds());
        const reply = result catch |err| {
            if (err != error.Cancelled) return err;
            try self.queueReply(u.message_id, "Okay, I stopped.");
            return error.TurnCancelled;
        };
        defer self.gpa.free(reply);
        const now = std.Io.Timestamp.now(self.io, .real).toSeconds();
        const approval_id = self.agent.last_approval;
        var id_buf: [32]u8 = undefined;
        if (approval_id) |pending_id| {
            const id = try std.fmt.bufPrint(&id_buf, "{d}", .{pending_id});
            try outbox.pushReply(self.db, .approval, id, reply, u.message_id, now);
        } else if (reply.len != 0) {
            try outbox.push(self.db, .text, null, reply, now);
        }
    }

    /// Sends queued owner output.
    fn flush(self: *Bot) !void {
        var drained: usize = 0;
        while (drained < outbox.max_drain) {
            const n = try self.flushBatch();
            if (n == 0) return;
            drained += n;
        }
    }

    fn flushBatch(self: *Bot) !usize {
        const now = std.Io.Timestamp.now(self.io, .real).toSeconds();
        const items = try outbox.claim(self.db, self.gpa, now);
        defer outbox.free(self.gpa, items);
        if (items.len >= 2) {
            if (self.sendAlbum(items)) |_| {
                for (items) |item| try outbox.delivered(self.db, item.id);
            } else |err| for (items) |item| try self.failDelivery(item.id, err);
            return items.len;
        }
        if (items.len == 0) return 0;
        const item = items[0];
        const result = switch (item.kind) {
            .text => self.send(item.text, item.reply_id, null),
            .approval => self.send(item.text, item.reply_id, std.fmt.parseInt(i64, item.path.?, 10) catch return error.BadCallback),
            .sticker => self.sendStickerAlias(item.path.?, item.reply_id),
            .photo, .document, .audio, .voice, .video, .animation => self.sendFile(item.kind, item.path.?, item.text, item.reply_id),
        };
        if (result) |_| try outbox.delivered(self.db, item.id) else |err| try self.failDelivery(item.id, err);
        return items.len;
    }

    fn failDelivery(self: *Bot, id: i64, err: anyerror) !void {
        if (retryableDelivery(err)) {
            try outbox.retry(self.db, id, @errorName(err));
        } else if (err == error.TelegramRejected or err == error.TelegramApiError or err == error.InvalidTelegramResponse or err == error.UnknownSticker or
            err == error.FileNotFound or err == error.BadPath or err == error.FileTooLarge)
        {
            try outbox.failed(self.db, id, @errorName(err));
        } else {
            try outbox.uncertain(self.db, id, @errorName(err));
        }
        log.warn("outbox: {t}", .{err});
    }

    fn sendAlbum(self: *Bot, items: []const outbox.Item) !void {
        if (items.len < 2 or items.len > 10) return error.BadAlbum;
        var files: [10][]u8 = undefined;
        var n: usize = 0;
        var total: usize = 0;
        defer for (files[0..n]) |bytes| self.gpa.free(bytes);
        for (items) |item| {
            const bytes = try workspace.readBytes(self.gpa, self.io, self.workspace, item.path.?, max_file);
            total = addAlbumSize(total, bytes.len) catch |err| {
                self.gpa.free(bytes);
                return err;
            };
            files[n] = bytes;
            n += 1;
        }
        const body = try albumBody(self.gpa, self.chat_id, items, files[0..n]);
        defer self.gpa.free(body);
        self.sendActivity(self.live_http, actionFor(items[0].kind)) catch |err| log.warn("upload action: {t}", .{err});
        const reply = try self.post("sendMediaGroup", body, "multipart/form-data; boundary=" ++ boundary);
        defer self.gpa.free(reply);
        try ensureOk(self.gpa, reply);
    }

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
        var hop = try get.request(self.gpa, url, null, null, max_file);
        errdefer hop.deinit(self.gpa);
        if (hop.status != 200) return error.TelegramHttp;
        if (hop.body.len > max_file) return error.FileTooLarge;
        const bytes = hop.body;
        hop.body = &.{};
        hop.deinit(self.gpa);
        return bytes;
    }

    fn sendFile(self: *Bot, kind: outbox.Kind, rel: []const u8, caption: []const u8, reply_id: ?i64) !void {
        const bytes = try workspace.readBytes(self.gpa, self.io, self.workspace, rel, max_file);
        defer self.gpa.free(bytes);

        const part = @tagName(kind);
        const body = try multipart(self.gpa, self.chat_id, part, baseName(rel), caption, reply_id, bytes);
        defer self.gpa.free(body);

        const method = switch (kind) {
            .photo => "sendPhoto",
            .document => "sendDocument",
            .audio => "sendAudio",
            .voice => "sendVoice",
            .video => "sendVideo",
            .animation => "sendAnimation",
            else => return error.BadMediaKind,
        };
        self.sendActivity(self.live_http, actionFor(kind)) catch |err| log.warn("upload action: {t}", .{err});
        const reply = try self.post(method, body, "multipart/form-data; boundary=" ++ boundary);
        defer self.gpa.free(reply);
        try ensureOk(self.gpa, reply);
    }

    fn sendActivity(self: *Bot, selected: ?agent.Http, action: []const u8) !void {
        const http = selected orelse return;
        const req = try buildChatAction(self.gpa, self.chat_id, action);
        defer self.gpa.free(req);
        const body = try self.callWith(http, "sendChatAction", req);
        defer self.gpa.free(body);
        try ensureOk(self.gpa, body);
    }

    fn send(self: *Bot, text: []const u8, reply_id: ?i64, approval_id: ?i64) !void {
        const escaped = try escapeHtml(self.gpa, text);
        defer self.gpa.free(escaped);
        var remaining = escaped;
        var first = true;
        while (remaining.len > 0) {
            const end = chunkEnd(remaining, max_message);
            if (end == 0) return error.InvalidTelegramText;
            const req = try buildSendMessage(self.gpa, self.chat_id, remaining[0..end], if (first) reply_id else null, if (first) approval_id else null);
            defer self.gpa.free(req);
            const body = self.call("sendMessage", req) catch |err| return if (first) err else error.PartialDelivery;
            defer self.gpa.free(body);
            ensureOk(self.gpa, body) catch |err| return if (first) err else error.PartialDelivery;
            remaining = remaining[end..];
            first = false;
        }
    }

    fn call(self: *Bot, method: []const u8, body: []const u8) ![]u8 {
        return self.post(method, body, "application/json");
    }

    fn callWith(self: *Bot, http: agent.Http, method: []const u8, body: []const u8) ![]u8 {
        return self.postWith(http, method, body, "application/json");
    }

    fn post(self: *Bot, method: []const u8, body: []const u8, content_type: []const u8) ![]u8 {
        return self.postWith(self.http, method, body, content_type);
    }

    fn postWith(self: *Bot, transport: agent.Http, method: []const u8, body: []const u8, content_type: []const u8) ![]u8 {
        const url = try endpoint(self.gpa, self.token.reveal(), method);
        defer self.gpa.free(url);
        var tries: u8 = 0;
        while (true) {
            var res = try timedPost(self.io, transport, self.gpa, .{
                .url = url,
                .auth = "",
                .body = body,
                .content_type = content_type,
            }, self.cancel, self.shutdown);
            if (res.status == 429) {
                // ponytail: cap flood waits at 60 seconds.
                const wait = @min(retryAfter(self.gpa, res.body) orelse 1, 60);
                res.deinit(self.gpa);
                tries += 1;
                if (tries > 3) return error.TelegramHttp;
                try waitRetry(self.io, wait, self.cancel, self.shutdown);
                continue;
            }
            errdefer res.deinit(self.gpa);
            if (res.status != 200) return error.TelegramRejected;
            return res.body;
        }
    }
};

fn activity(
    self: *Bot,
    cancel: *agent.Workers,
    done: *const std.atomic.Value(bool),
    stop_update: *std.atomic.Value(i64),
    offset: i64,
) void {
    const http = self.live_http orelse return;
    var next_action: i64 = 0;
    while (!done.load(.acquire) and !cancel.cancelled()) {
        if (self.shutdown) |stop| if (stop()) {
            cancel.stop.store(true, .release);
            return;
        };
        const now = std.Io.Timestamp.now(self.io, .awake).toMilliseconds();
        if (now >= next_action) {
            self.sendActivity(http, "typing") catch {
                if (done.load(.acquire) or cancel.cancelled()) return;
                std.Io.sleep(self.io, .fromSeconds(1), .awake) catch {};
                continue;
            };
            next_action = now + 4_000;
        }

        const req = buildCancelUpdates(self.gpa, offset) catch {
            if (done.load(.acquire) or cancel.cancelled()) return;
            std.Io.sleep(self.io, .fromSeconds(1), .awake) catch {};
            continue;
        };
        const body = self.callWith(http, "getUpdates", req) catch {
            self.gpa.free(req);
            if (done.load(.acquire) or cancel.cancelled()) return;
            std.Io.sleep(self.io, .fromSeconds(1), .awake) catch {};
            continue;
        };
        self.gpa.free(req);
        defer self.gpa.free(body);
        var batch = parseUpdates(self.gpa, body) catch return;
        defer batch.deinit(self.gpa);
        for (batch.items) |u| {
            if (!admit(u, self.owner_id, self.chat_id) or u.kind != .text or !stopText(u.text)) continue;
            stop_update.store(u.update_id, .release);
            cancel.stop.store(true, .release);
            return;
        }
    }
}

fn stopText(text: []const u8) bool {
    const value = std.mem.trim(u8, text, &std.ascii.whitespace);
    return std.ascii.eqlIgnoreCase(value, "stop") or std.ascii.eqlIgnoreCase(value, "/stop");
}

fn retryableDelivery(err: anyerror) bool {
    const name = @errorName(err);
    const retryable = [_][]const u8{
        "TelegramHttp",    "ConnectionRefused", "NetworkUnreachable",
        "HostUnreachable", "UnknownHostName",   "TemporaryNameServerFailure",
    };
    for (retryable) |candidate| if (std.mem.eql(u8, name, candidate)) return true;
    return false;
}

fn actionFor(kind: outbox.Kind) []const u8 {
    return switch (kind) {
        .photo => "upload_photo",
        .video, .animation => "upload_video",
        .voice => "upload_voice",
        else => "upload_document",
    };
}

fn waitRetry(io: std.Io, seconds: u64, cancel: ?*const std.atomic.Value(bool), shutdown: ?*const fn () bool) !void {
    var ticks: u64 = 0;
    while (ticks < seconds * 10) : (ticks += 1) {
        if (cancel) |flag| if (flag.load(.acquire)) return error.Cancelled;
        if (shutdown) |stop| if (stop()) return error.Cancelled;
        std.Io.sleep(io, .fromMilliseconds(100), .awake) catch return error.TelegramHttp;
    }
}

fn timedPost(
    io: std.Io,
    transport: agent.Http,
    gpa: std.mem.Allocator,
    req: agent.Http.Request,
    cancel: ?*const std.atomic.Value(bool),
    shutdown: ?*const fn () bool,
) !agent.Http.Response {
    const Race = union(enum) {
        request: anyerror!agent.Http.Response,
        timeout: std.Io.Cancelable!void,
        cancel: std.Io.Cancelable!void,
    };
    const Run = struct {
        fn request(http: agent.Http, alloc: std.mem.Allocator, arg: agent.Http.Request) anyerror!agent.Http.Response {
            return http.post(alloc, arg);
        }

        fn timeout(io_arg: std.Io) std.Io.Cancelable!void {
            return (std.Io.Clock.Duration{ .raw = .fromMilliseconds(request_timeout_ms), .clock = .awake }).sleep(io_arg);
        }

        fn cancelled(io_arg: std.Io, flag: ?*const std.atomic.Value(bool), stop: ?*const fn () bool) std.Io.Cancelable!void {
            while (true) {
                if (flag) |value| if (value.load(.acquire)) return;
                if (stop) |requested| if (requested()) return;
                try (std.Io.Clock.Duration{ .raw = .fromMilliseconds(25), .clock = .awake }).sleep(io_arg);
            }
        }

        fn clean(race: *std.Io.Select(Race), alloc: std.mem.Allocator) void {
            while (race.cancel()) |late| switch (late) {
                .request => |result| if (result) |response| {
                    var owned = response;
                    owned.deinit(alloc);
                } else |_| {},
                .timeout, .cancel => |result| result catch {},
            };
        }
    };

    var ready: [3]Race = undefined;
    var race = std.Io.Select(Race).init(io, &ready);
    try race.concurrent(.request, Run.request, .{ transport, gpa, req });
    {
        errdefer Run.clean(&race, gpa);
        try race.concurrent(.timeout, Run.timeout, .{io});
        if (cancel != null or shutdown != null)
            try race.concurrent(.cancel, Run.cancelled, .{ io, cancel, shutdown });
    }

    const first = try race.await();
    defer Run.clean(&race, gpa);
    return switch (first) {
        .request => |result| result,
        .timeout => |result| blk: {
            try result;
            break :blk error.TelegramTimeout;
        },
        .cancel => |result| blk: {
            try result;
            break :blk error.Cancelled;
        },
    };
}

fn recordStop(db: *Db, id: i64, now: i64) !void {
    var q = try db.prepare(
        \\INSERT OR IGNORE INTO telegram_updates(id, status, text, created, updated, kind, callback_data)
        \\VALUES (?, 'completed', '/stop', ?, ?, 'text', NULL)
    );
    defer q.finalize();
    try q.bind(1, id);
    try q.bind(2, now);
    try q.bind(3, now);
    _ = try q.step();
}

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
    parse_mode: []const u8 = "HTML",
    reply_parameters: ?ReplyParameters = null,
    reply_markup: ?Markup = null,
};

const ReplyParameters = struct { message_id: i64 };
const Button = struct { text: []const u8, callback_data: []const u8 };
const Markup = struct { inline_keyboard: []const []const Button };

fn jsonBody(gpa: std.mem.Allocator, value: anytype) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    try out.writer.print("{f}", .{std.json.fmt(value, .{ .emit_null_optional_fields = false })});
    return out.toOwnedSlice();
}

fn buildChatAction(gpa: std.mem.Allocator, chat_id: i64, action: []const u8) ![]u8 {
    return jsonBody(gpa, ChatActionRequest{ .chat_id = chat_id, .action = action });
}

fn buildSendMessage(gpa: std.mem.Allocator, chat_id: i64, text: []const u8, reply_id: ?i64, approval_id: ?i64) ![]u8 {
    var approve_buf: [32]u8 = undefined;
    var deny_buf: [32]u8 = undefined;
    const buttons = [_]Button{
        .{ .text = "Approve", .callback_data = if (approval_id) |id| try std.fmt.bufPrint(&approve_buf, "a:{d}", .{id}) else "" },
        .{ .text = "Deny", .callback_data = if (approval_id) |id| try std.fmt.bufPrint(&deny_buf, "d:{d}", .{id}) else "" },
    };
    const rows = [_][]const Button{&buttons};
    return jsonBody(gpa, SendMessageRequest{
        .chat_id = chat_id,
        .text = text,
        .reply_parameters = if (reply_id) |id| .{ .message_id = id } else null,
        .reply_markup = if (approval_id != null) .{ .inline_keyboard = &rows } else null,
    });
}

fn buildFileId(gpa: std.mem.Allocator, chat_id: i64, field_name: []const u8, file_id: []const u8, reply_id: ?i64) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    try out.writer.print("{{\"chat_id\":{d},\"{s}\":", .{ chat_id, field_name });
    try std.json.Stringify.encodeJsonString(file_id, .{}, &out.writer);
    if (reply_id) |id| try out.writer.print(",\"reply_parameters\":{{\"message_id\":{d}}}", .{id});
    try out.writer.writeByte('}');
    return out.toOwnedSlice();
}

const commands_json =
    \\{"commands":[{"command":"help","description":"Show help"},{"command":"status","description":"Show status"},{"command":"tasks","description":"List tasks"},{"command":"routines","description":"List routines"},{"command":"memory","description":"Search memory"},{"command":"diary","description":"Show diary"},{"command":"skills","description":"List skills"},{"command":"character","description":"Show character"},{"command":"learn","description":"Show learning"},{"command":"model","description":"Change model"},{"command":"cache","description":"Show prompt cache"},{"command":"compact","description":"Compact conversation"},{"command":"clear","description":"Save and clear"},{"command":"stickers","description":"List stickers"},{"command":"stop","description":"Stop work"},{"command":"new","description":"New conversation"}]}
;

fn escapeHtml(gpa: std.mem.Allocator, text: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    for (text) |c| switch (c) {
        '&' => try out.writer.writeAll("&amp;"),
        '<' => try out.writer.writeAll("&lt;"),
        '>' => try out.writer.writeAll("&gt;"),
        else => try out.writer.writeByte(c),
    };
    return out.toOwnedSlice();
}

fn chunkEnd(text: []const u8, max_bytes: usize) usize {
    var end = utf8ChunkEnd(text, max_bytes);
    if (end == text.len) return end;
    if (std.mem.lastIndexOf(u8, text[0..end], "\n\n")) |cut| {
        if (cut > max_bytes / 2) end = cut + 2;
    }
    if (std.mem.lastIndexOfScalar(u8, text[0..end], '\n')) |cut| {
        if (cut > max_bytes / 2) end = cut + 1;
    }
    const amp = std.mem.lastIndexOfScalar(u8, text[0..end], '&');
    const semi = std.mem.lastIndexOfScalar(u8, text[0..end], ';');
    if (amp != null and (semi == null or amp.? > semi.?)) end = amp.?;
    return end;
}

const boundary = "zoroFormBoundary7Nn2Kq";

fn albumBody(gpa: std.mem.Allocator, chat_id: i64, items: []const outbox.Item, files: []const []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    const w = &out.writer;
    try w.print("--{s}\r\nContent-Disposition: form-data; name=\"chat_id\"\r\n\r\n{d}\r\n", .{ boundary, chat_id });
    if (items[0].reply_id) |id| try w.print("--{s}\r\nContent-Disposition: form-data; name=\"reply_parameters\"\r\nContent-Type: application/json\r\n\r\n{{\"message_id\":{d}}}\r\n", .{ boundary, id });
    try w.print("--{s}\r\nContent-Disposition: form-data; name=\"media\"\r\nContent-Type: application/json\r\n\r\n[", .{boundary});
    for (items, 0..) |item, i| {
        if (i != 0) try w.writeByte(',');
        try w.print("{{\"type\":\"{s}\",\"media\":\"attach://f{d}\"", .{ @tagName(item.kind), i });
        if (i == 0 and item.text.len != 0) {
            try w.writeAll(",\"caption\":");
            try std.json.Stringify.encodeJsonString(item.text[0..@min(item.text.len, 1024)], .{}, w);
        }
        try w.writeByte('}');
    }
    try w.writeAll("]\r\n");
    for (items, files, 0..) |item, bytes, i| {
        try w.print(
            "--{s}\r\nContent-Disposition: form-data; name=\"f{d}\"; filename=\"{s}\"\r\nContent-Type: application/octet-stream\r\n\r\n",
            .{ boundary, i, baseName(item.path.?) },
        );
        try w.writeAll(bytes);
        try w.writeAll("\r\n");
    }
    try w.print("--{s}--\r\n", .{boundary});
    return out.toOwnedSlice();
}

fn addAlbumSize(total: usize, n: usize) !usize {
    if (n > max_album - total) return error.FileTooLarge;
    return total + n;
}

test "album size is bounded before assembly" {
    try testing.expectEqual(max_album, try addAlbumSize(max_album - 1, 1));
    try testing.expectError(error.FileTooLarge, addAlbumSize(max_album - 1, 2));
}

/// Removes control bytes that could forge multipart boundaries.
fn field(w: *std.Io.Writer, text: []const u8) !void {
    for (text) |c| {
        if (c >= 0x20 or c == '\t') try w.writeByte(c) else try w.writeByte(' ');
    }
}

/// Builds Telegram's multipart upload form.
fn multipart(
    gpa: std.mem.Allocator,
    chat_id: i64,
    part: []const u8,
    name: []const u8,
    caption: []const u8,
    reply_id: ?i64,
    bytes: []const u8,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    const w = &out.writer;

    try w.print("--{s}\r\nContent-Disposition: form-data; name=\"chat_id\"\r\n\r\n{d}\r\n", .{ boundary, chat_id });
    if (reply_id) |id| try w.print("--{s}\r\nContent-Disposition: form-data; name=\"reply_parameters\"\r\nContent-Type: application/json\r\n\r\n{{\"message_id\":{d}}}\r\n", .{ boundary, id });
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

/// Sniffs common image types for the model.
fn sniff(bytes: []const u8) []const u8 {
    return imageMime(bytes) orelse "image/jpeg";
}

fn imageMime(bytes: []const u8) ?[]const u8 {
    if (std.mem.startsWith(u8, bytes, "\x89PNG")) return "image/png";
    if (std.mem.startsWith(u8, bytes, "GIF8")) return "image/gif";
    if (std.mem.startsWith(u8, bytes, "\xff\xd8\xff")) return "image/jpeg";
    if (bytes.len >= 12 and std.mem.eql(u8, bytes[8..12], "WEBP")) return "image/webp";
    return null;
}

fn buildGetUpdates(gpa: std.mem.Allocator, offset: ?i64) ![]u8 {
    const allowed = [_][]const u8{ "message", "edited_message", "callback_query" };
    return jsonBody(gpa, GetUpdatesRequest{
        .offset = offset,
        .timeout = poll_timeout,
        .allowed_updates = &allowed,
    });
}

fn buildCancelUpdates(gpa: std.mem.Allocator, offset: i64) ![]u8 {
    const allowed = [_][]const u8{"message"};
    return jsonBody(gpa, GetUpdatesRequest{
        .offset = offset,
        .timeout = 1,
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
        try self.db.initSchema();
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

test "Telegram requests have a deadline" {
    const Slow = struct {
        io: std.Io,

        fn http(self: *@This()) agent.Http {
            return .{ .ptr = self, .post_fn = post };
        }

        fn post(ptr: *anyopaque, gpa: std.mem.Allocator, _: agent.Http.Request) anyerror!agent.Http.Response {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            try (std.Io.Clock.Duration{ .raw = .fromSeconds(5), .clock = .awake }).sleep(self.io);
            return .{ .status = 200, .body = try gpa.dupe(u8, ok_json) };
        }
    };

    var h: Harness = undefined;
    try h.init(&.{}, &.{});
    defer h.deinit();
    var slow: Slow = .{ .io = h.threaded.io() };
    h.bot.http = slow.http();
    try testing.expectError(error.TelegramTimeout, h.bot.getMe());
}

test "getMe rejects HTTP non-200" {
    var h: Harness = undefined;
    try h.init(&.{"unauthorized"}, &.{});
    defer h.deinit();
    h.tg.status = 401;
    try testing.expectError(error.TelegramRejected, h.bot.getMe());
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
    try testing.expect(std.mem.indexOf(u8, h.tg.sent(), "reply_parameters") == null);
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

test "a rejected send remains inspectable without repeating the turn" {
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
    try h.bot.pollOnce();
    try testing.expectEqual(@as(i64, 1), try scalar(&h.db, "SELECT count(*) FROM outbox WHERE status = 'failed'"));
    try testing.expectEqual(@as(i64, 1), try scalar(&h.db, "SELECT count(*) FROM telegram_updates WHERE status = 'completed'"));
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

/// Fakes Telegram's file download endpoint.
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

    fn request(ptr: *anyopaque, gpa: std.mem.Allocator, target: []const u8, _: ?[]const u8, _: ?std.Io.net.IpAddress, _: usize) anyerror!web.Hop {
        const self: *FakeGet = @ptrCast(@alignCast(ptr));
        self.seen_len = @min(target.len, self.seen.len);
        @memcpy(self.seen[0..self.seen_len], target[0..self.seen_len]);
        self.calls += 1;
        return .{ .status = self.status, .body = try gpa.dupe(u8, self.body) };
    }
};

const ok_json = "{\"ok\":true,\"result\":{}}";

test "a photo is downloaded and reaches the base model with its caption" {
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
    var workspace_buf: [128]u8 = undefined;
    h.bot.workspace = try h.workspace(&workspace_buf);
    try h.bot.pollOnce();

    try testing.expectEqual(@as(usize, 1), files.calls);
    try testing.expect(std.mem.endsWith(u8, files.url(), "/photos/x.png"));
    try testing.expect(std.mem.indexOf(u8, h.tg.sent(), "\"big\"") != null or
        std.mem.indexOf(u8, h.tg.url(2), "getFile") != null);

    const asked = h.llm.sent();
    try testing.expect(std.mem.indexOf(u8, asked, "\"m\"") != null);
    try testing.expect(std.mem.indexOf(u8, asked, "data:image/png;base64,") != null);
    try testing.expect(std.mem.indexOf(u8, asked, "what plant is this") != null);
    const saved = try workspace.readBytes(testing.allocator, h.threaded.io(), h.bot.workspace, "inbox/5-photo.jpg", 8);
    defer testing.allocator.free(saved);
    try testing.expectEqualStrings("\x89PNG\r\n\x1a\n", saved);
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
    try testing.expect(std.mem.indexOf(u8, h.llm.sent(), "photo download failed") != null);
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

test "reply text and identifier survive parsing" {
    const body =
        \\{"ok":true,"result":[{"update_id":2,"message":{"message_id":8,"from":{"id":42},"chat":{"id":42,"type":"private"},"reply_to_message":{"message_id":7,"text":"original"},"text":"follow up"}}]}
    ;
    var batch = try parseUpdates(testing.allocator, body);
    defer batch.deinit(testing.allocator);
    try testing.expectEqual(@as(?i64, 7), batch.items[0].reply_id);
    try testing.expectEqualStrings("original", batch.items[0].reply_text.?);
}

test "document bytes land in the configured inbox" {
    var h: Harness = undefined;
    try h.init(&.{
        \\{"ok":true,"result":[{"update_id":1,"message":{"message_id":8,"from":{"id":42},"chat":{"id":42,"type":"private"},"caption":"read this","document":{"file_id":"d1","file_name":"note.txt","mime_type":"text/plain","file_size":5}}}]}
        ,
        ok_json,
        "{\"ok\":true,\"result\":{\"file_path\":\"documents/note.txt\",\"file_size\":5}}",
        ok_json,
    }, &.{"{\"choices\":[{\"message\":{\"content\":\"read\"}}]}"});
    defer h.deinit();
    var root_buf: [128]u8 = undefined;
    h.bot.workspace = try h.workspace(&root_buf);
    h.bot.inbox = "incoming";
    var files: FakeGet = .{ .body = "hello" };
    h.bot.fetch = files.get();

    try h.bot.pollOnce();
    const saved = try workspace.readBytes(testing.allocator, h.threaded.io(), h.bot.workspace, "incoming/1-note.txt", 5);
    defer testing.allocator.free(saved);
    try testing.expectEqualStrings("hello", saved);
    try testing.expect(std.mem.indexOf(u8, h.llm.sent(), "in inbox: incoming/1-note.txt") != null);
}

test "an image document is saved and shown to the model" {
    var h: Harness = undefined;
    try h.init(&.{
        \\{"ok":true,"result":[{"update_id":2,"message":{"message_id":9,"from":{"id":42},"chat":{"id":42,"type":"private"},"document":{"file_id":"image","file_name":"scan.png","mime_type":"application/octet-stream","file_size":8}}}]}
        ,
        ok_json,
        "{\"ok\":true,\"result\":{\"file_path\":\"documents/scan.png\",\"file_size\":8}}",
        ok_json,
    }, &.{"{\"choices\":[{\"message\":{\"content\":\"a scan\"}}]}"});
    defer h.deinit();
    var root_buf: [128]u8 = undefined;
    h.bot.workspace = try h.workspace(&root_buf);
    var files: FakeGet = .{ .body = "\x89PNG\r\n\x1a\n" };
    h.bot.fetch = files.get();

    try h.bot.pollOnce();
    try testing.expect(std.mem.indexOf(u8, h.llm.sent(), "data:image/png;base64,") != null);
    const saved = try workspace.readBytes(testing.allocator, h.threaded.io(), h.bot.workspace, "inbox/2-scan.png", 8);
    defer testing.allocator.free(saved);
    try testing.expectEqualStrings("\x89PNG\r\n\x1a\n", saved);
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

    try h.bot.flush();
    try testing.expectEqual(@as(usize, 1), h.tg.i);
}

test "compatible media are sent as one bounded album" {
    var h: Harness = undefined;
    try h.init(&.{ok_json}, &.{});
    defer h.deinit();

    var dir_buf: [128]u8 = undefined;
    const dir = try h.workspace(&dir_buf);
    h.bot.workspace = dir;
    var d = try std.Io.Dir.cwd().openDir(h.threaded.io(), dir, .{});
    defer d.close(h.threaded.io());
    try d.writeFile(h.threaded.io(), .{ .sub_path = "a.png", .data = "a" });
    try d.writeFile(h.threaded.io(), .{ .sub_path = "b.mp4", .data = "b" });
    try outbox.pushReply(&h.db, .photo, "a.png", "album", 12, 1);
    try outbox.push(&h.db, .video, "b.mp4", "ignored", 2);

    try h.bot.flush();
    try testing.expect(std.mem.endsWith(u8, h.tg.sentUrl(), "/sendMediaGroup"));
    try testing.expect(std.mem.indexOf(u8, h.tg.sent(), "\"media\":\"attach://f0\"") != null);
    try testing.expect(std.mem.indexOf(u8, h.tg.sent(), "\"media\":\"attach://f1\"") != null);
    try testing.expect(std.mem.indexOf(u8, h.tg.sent(), "\"message_id\":12") != null);
    try testing.expectEqual(@as(i64, 0), try scalar(&h.db, "SELECT count(*) FROM outbox"));
}

test "a later text chunk failure is uncertain" {
    var h: Harness = undefined;
    try h.init(&.{ok_json}, &.{});
    defer h.deinit();
    var body: [max_message + 1]u8 = @splat('a');
    try outbox.push(&h.db, .text, null, &body, 1);

    try h.bot.flush();

    try testing.expectEqual(@as(i64, 1), try scalar(&h.db, "SELECT count(*) FROM outbox WHERE status = 'uncertain'"));
    try testing.expectEqual(@as(usize, 1), h.tg.i);
}

test "a stop message cancels the active model turn" {
    const Slow = struct {
        io: std.Io,

        fn http(self: *@This()) agent.Http {
            return .{ .ptr = self, .post_fn = post };
        }

        fn post(ptr: *anyopaque, gpa: std.mem.Allocator, _: agent.Http.Request) anyerror!agent.Http.Response {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            try (std.Io.Clock.Duration{ .raw = .fromSeconds(5), .clock = .awake }).sleep(self.io);
            return .{ .status = 200, .body = try gpa.dupe(u8, "{\"choices\":[{\"message\":{\"content\":\"late\"}}]}") };
        }
    };

    var h: Harness = undefined;
    try h.init(&.{
        \\{"ok":true,"result":[{"update_id":4,"message":{"message_id":9,"from":{"id":42,"is_bot":false},"chat":{"id":42,"type":"private"},"text":"work"}}]}
        ,
        ok_json,
    }, &.{});
    defer h.deinit();
    var live: FakeHttp = .{ .bodies = &.{
        ok_json,
        \\{"ok":true,"result":[{"update_id":5,"message":{"message_id":10,"from":{"id":42,"is_bot":false},"chat":{"id":42,"type":"private"},"text":"/stop"}}]}
        ,
    } };
    var slow: Slow = .{ .io = h.threaded.io() };
    h.agent.http = slow.http();
    h.bot.live_http = live.http();

    try h.bot.pollOnce();
    try testing.expect(std.mem.indexOf(u8, h.tg.sent(), "Okay, I stopped.") != null);
    try testing.expect(std.mem.endsWith(u8, live.url(0), "/sendChatAction"));
    try testing.expect(std.mem.endsWith(u8, live.url(1), "/getUpdates"));
    try testing.expectEqual(@as(i64, 1), try scalar(&h.db, "SELECT count(*) FROM telegram_updates WHERE id = 5 AND status = 'completed'"));
}

test "an attachment pointing outside the workspace is refused" {
    var h: Harness = undefined;
    try h.init(&.{}, &.{});
    defer h.deinit();
    try testing.expectError(error.BadPath, h.bot.sendFile(.document, "../../etc/passwd", "", null));
}

test "a failed approved action becomes uncertain" {
    var h: Harness = undefined;
    try h.init(
        &.{
            \\{"ok":true,"result":[{"update_id":7,"callback_query":{"id":"cb1","from":{"id":42,"is_bot":false},"message":{"message_id":90,"chat":{"id":42,"type":"private"}},"data":"a:1"}}]}
            ,
            ok_json,
            ok_json,
        },
        &.{},
    );
    defer h.deinit();
    _ = try tasks.ask(&h.db, "missing_tool", "{}", null, "test action", null, std.Io.Timestamp.now(h.threaded.io(), .real).toSeconds());

    try testing.expectError(error.UnknownTool, h.bot.pollOnce());
    try testing.expect(std.mem.endsWith(u8, h.tg.url(1), "/answerCallbackQuery"));
    try testing.expectEqual(@as(usize, 2), h.tg.i);
    var q = try h.db.prepare("SELECT status FROM approvals WHERE id = 1");
    defer q.finalize();
    try testing.expect(try q.step());
    try testing.expectEqualStrings("uncertain", q.text(0));
}

test "foreign callback is answered without granting authority" {
    var h: Harness = undefined;
    try h.init(
        &.{
            \\{"ok":true,"result":[{"update_id":7,"callback_query":{"id":"cb1","from":{"id":99,"is_bot":false},"message":{"message_id":90,"chat":{"id":42,"type":"private"}},"data":"a:1"}}]}
            ,
            ok_json,
        },
        &.{},
    );
    defer h.deinit();
    _ = try tasks.ask(&h.db, "missing_tool", "{}", null, "test action", null, 1);

    try h.bot.pollOnce();
    try testing.expect(std.mem.endsWith(u8, h.tg.sentUrl(), "/answerCallbackQuery"));
    var q = try h.db.prepare("SELECT status FROM approvals WHERE id = 1");
    defer q.finalize();
    try testing.expect(try q.step());
    try testing.expectEqualStrings("pending", q.text(0));
}

test "HTML output is escaped and chunks keep entities whole" {
    const escaped = try escapeHtml(testing.allocator, "<a&b>");
    defer testing.allocator.free(escaped);
    try testing.expectEqualStrings("&lt;a&amp;b&gt;", escaped);
    const cut = chunkEnd("abc&amp;def", 6);
    try testing.expectEqual(@as(usize, 3), cut);
}

test "sticker aliases are durable and listed" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [128]u8 = undefined;
    var db = try testkit.tmpDb(&tmp, &buf);
    defer db.close();

    try beginStickerLearning(&db, "wave", 10);
    var u: Update = .{
        .update_id = 1,
        .from_id = 42,
        .chat_id = 42,
        .chat_type = try testing.allocator.dupe(u8, "private"),
        .kind = .sticker,
        .text = try testing.allocator.dupe(u8, ""),
        .file_id = try testing.allocator.dupe(u8, "sticker-file"),
        .unique_id = try testing.allocator.dupe(u8, "stable"),
        .emoji = try testing.allocator.dupe(u8, "👋"),
    };
    defer u.deinit(testing.allocator);
    const alias = (try takeStickerLearning(&db, testing.allocator, u, 11)).?;
    defer testing.allocator.free(alias);
    try testing.expectEqualStrings("wave", alias);

    const list = try listStickers(&db, testing.allocator);
    defer testing.allocator.free(list);
    try testing.expectEqualStrings("wave 👋\n", list);
}

test "sending a sticker does not add an emoji reply" {
    var h: Harness = undefined;
    try h.init(&.{
        \\{"ok":true,"result":[{"update_id":1,"message":{"message_id":2,"from":{"id":42},"chat":{"id":42,"type":"private"},"text":"Send pro"}}]}
        ,
        ok_json,
        ok_json,
        ok_json,
    }, &.{
        \\{"choices":[{"message":{"tool_calls":[{"id":"c1","type":"function","function":{"name":"send_sticker","arguments":"{\"alias\":\"pro\"}"}}]}}]}
        ,
        "{\"choices\":[{\"message\":{\"content\":\"😎\"}}]}",
    });
    defer h.deinit();
    h.agent.tools = &tools.builtins;
    try h.db.exec("INSERT INTO sticker_aliases(alias, file_id, unique_id, updated) VALUES ('pro', 'file', 'stable', 1)");

    try h.bot.pollOnce();
    try testing.expectEqual(@as(usize, 3), h.tg.i);
    try testing.expect(std.mem.endsWith(u8, h.tg.sentUrl(), "/sendSticker"));
}
