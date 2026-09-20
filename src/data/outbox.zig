const std = @import("std");
const Db = @import("db.zig").Db;
const workspace = @import("../app/workspace.zig");
const tools = @import("../tools/root.zig");
const testing = std.testing;
const testkit = @import("../testing/testkit.zig");

/// Maximum queued message size before channel chunking.
pub const max_text: usize = 8 * 1024;
/// Drained per turn. A runaway routine cannot flood the owner in one go.
pub const max_drain: usize = 16;
const max_attempts: i64 = 3;

pub const Kind = enum { text, photo, document, audio, voice, video, animation, sticker };

pub const Status = enum { queued, claimed, retryable, uncertain, failed };

pub const Item = struct {
    id: i64,
    kind: Kind,
    path: ?[]u8,
    text: []u8,
    reply_id: ?i64,

    pub fn deinit(self: *Item, gpa: std.mem.Allocator) void {
        if (self.path) |p| gpa.free(p);
        gpa.free(self.text);
        self.* = undefined;
    }
};

/// Queues output with an optional workspace-relative path.
pub fn push(db: *Db, kind: Kind, path: ?[]const u8, body: []const u8, now: i64) !void {
    return pushReply(db, kind, path, body, null, now);
}

pub fn pushReply(db: *Db, kind: Kind, path: ?[]const u8, body: []const u8, reply_id: ?i64, now: i64) !void {
    if (kind != .text and (path == null or !safeRelative(path.?))) return error.BadPath;
    const text = clamp(body);
    var q = try db.prepare("INSERT INTO outbox(kind, path, text, reply_id, created) VALUES (?, ?, ?, ?, ?)");
    defer q.finalize();
    try q.bind(1, @tagName(kind));
    try q.bind(2, path);
    try q.bind(3, text);
    try q.bind(4, reply_id);
    try q.bind(5, now);
    _ = try q.step();
}

/// Claims up to `max_drain` rows. Caller must finalize every returned item.
pub fn claim(db: *Db, gpa: std.mem.Allocator, now: i64) ![]Item {
    var out: std.ArrayList(Item) = .empty;
    errdefer free(gpa, out.items);
    try db.exec("BEGIN IMMEDIATE;");
    errdefer db.exec("ROLLBACK;") catch {};
    {
        var q = try db.prepare("SELECT id, kind, path, text, reply_id FROM outbox WHERE status = 'queued' OR (status = 'retryable' AND next_attempt <= ?) ORDER BY id LIMIT ?");
        defer q.finalize();
        try q.bind(1, now);
        try q.bind(2, @as(i64, @intCast(max_drain)));
        while (try q.step()) {
            try out.ensureUnusedCapacity(gpa, 1);
            const kind = std.meta.stringToEnum(Kind, q.text(1)) orelse .text;
            const path = if (q.isNull(2)) null else try gpa.dupe(u8, q.text(2));
            errdefer if (path) |p| gpa.free(p);
            const text = try gpa.dupe(u8, q.text(3));
            errdefer gpa.free(text);
            out.appendAssumeCapacity(.{
                .id = q.int(0),
                .kind = kind,
                .path = path,
                .text = text,
                .reply_id = if (q.isNull(4)) null else q.int(4),
            });
        }
    }
    const keep = claimCount(out.items);
    for (out.items[keep..]) |*item| item.deinit(gpa);
    out.items.len = keep;
    for (out.items) |item| {
        var d = try db.prepare("UPDATE outbox SET status = 'claimed', attempts = attempts + 1, claimed = ?, error = NULL WHERE id = ?");
        defer d.finalize();
        try d.bind(1, now);
        try d.bind(2, item.id);
        _ = try d.step();
    }
    try db.exec("COMMIT;");
    return out.toOwnedSlice(gpa);
}

/// Removes an item only after the destination confirmed it.
pub fn delivered(db: *Db, id: i64) !void {
    var q = try db.prepare("DELETE FROM outbox WHERE id = ? AND status = 'claimed'");
    defer q.finalize();
    try q.bind(1, id);
    _ = try q.step();
}

/// Keeps a definite pre-send failure eligible for a later attempt.
pub fn retry(db: *Db, id: i64, note: []const u8) !void {
    var q = try db.prepare(
        \\UPDATE outbox SET
        \\ status = CASE WHEN attempts >= ? THEN 'failed' ELSE 'retryable' END,
        \\ next_attempt = unixepoch() + CASE attempts WHEN 1 THEN 1 WHEN 2 THEN 5 ELSE 30 END,
        \\ error = ? WHERE id = ? AND status = 'claimed'
    );
    defer q.finalize();
    try q.bind(1, max_attempts);
    try q.bind(2, note);
    try q.bind(3, id);
    _ = try q.step();
}

/// Requeues one terminal delivery after an owner retry.
pub fn retryDelivery(db: *Db, id: i64) !bool {
    var q = try db.prepare("UPDATE outbox SET status = 'retryable', attempts = 0, next_attempt = 0, error = NULL WHERE id = ? AND status IN ('failed', 'uncertain')");
    defer q.finalize();
    try q.bind(1, id);
    _ = try q.step();
    return @import("c").sqlite3_changes(db.ptr) == 1;
}

/// Records an outcome that may have reached Telegram without retrying it.
pub fn uncertain(db: *Db, id: i64, note: []const u8) !void {
    try setStatus(db, id, .uncertain, note);
}

pub fn failed(db: *Db, id: i64, note: []const u8) !void {
    try setStatus(db, id, .failed, note);
}

/// A crashed claimed send may already have reached its destination.
pub fn recover(db: *Db) !void {
    try db.exec("UPDATE outbox SET status = 'uncertain', error = 'interrupted during delivery' WHERE status = 'claimed';");
}

pub fn recoverBefore(db: *Db, cutoff: i64) !void {
    var q = try db.prepare("UPDATE outbox SET status = 'uncertain', error = 'interrupted during delivery' WHERE status = 'claimed' AND claimed <= ?");
    defer q.finalize();
    try q.bind(1, cutoff);
    _ = try q.step();
}

fn setStatus(db: *Db, id: i64, status: Status, note: []const u8) !void {
    var q = try db.prepare("UPDATE outbox SET status = ?, error = ? WHERE id = ? AND status = 'claimed'");
    defer q.finalize();
    try q.bind(1, @tagName(status));
    try q.bind(2, note);
    try q.bind(3, id);
    _ = try q.step();
}

fn claimCount(items: []const Item) usize {
    if (items.len == 0) return 0;
    const class = albumClass(items[0].kind);
    if (class == 0) return 1;
    var n: usize = 1;
    while (n < items.len and n < 10 and albumClass(items[n].kind) == class) : (n += 1) {}
    return n;
}

fn albumClass(kind: Kind) u2 {
    return switch (kind) {
        .photo, .video => 1,
        .audio => 2,
        .document => 3,
        else => 0,
    };
}

pub fn free(gpa: std.mem.Allocator, items: []Item) void {
    for (items) |*i| i.deinit(gpa);
    gpa.free(items);
}

/// Trims to `max_text` on a UTF-8 boundary.
fn clamp(text: []const u8) []const u8 {
    if (text.len <= max_text) return text;
    var end = max_text;
    while (end > 0 and text[end] & 0xC0 == 0x80) end -= 1;
    return text[0..end];
}

/// Accepts safe workspace-relative paths for multipart headers.
pub fn safeRelative(path: []const u8) bool {
    return workspace.validPath(path);
}

const notify_params = [_]tools.Param{
    .{ .name = "text", .description = "message" },
};

pub const notify_owner: tools.Def = .{
    .name = "notify_owner",
    .description = "Queue an owner message.",
    .params = &notify_params,
    .primary_only = true,
    .run = runNotify,
};

const attach_params = [_]tools.Param{
    .{ .name = "path", .description = "workspace path" },
    .{ .name = "caption", .description = "caption", .required = false },
    .{ .name = "as", .description = "photo, document, audio, voice, video, or animation", .required = false },
};

pub const attach_file: tools.Def = .{
    .name = "attach_file",
    .description = "Send a workspace file now.",
    .params = &attach_params,
    .primary_only = true,
    .run = runAttach,
};

const sticker_params = [_]tools.Param{
    .{ .name = "alias", .description = "learned sticker alias" },
};

pub const send_sticker: tools.Def = .{
    .name = "send_sticker",
    .description = "Send a learned sticker.",
    .params = &sticker_params,
    .primary_only = true,
    .run = runSticker,
};

fn runNotify(ctx: *tools.Ctx, args: []const u8) anyerror![]u8 {
    const Args = struct { text: []const u8 };
    const parsed = try std.json.parseFromSlice(Args, ctx.gpa, args, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    const now = std.Io.Timestamp.now(ctx.io, .real).toSeconds();
    push(ctx.db, .text, null, parsed.value.text, now) catch |err|
        return std.fmt.allocPrint(ctx.gpa, "not queued: {s}", .{@errorName(err)});
    if (ctx.delivery_out) |out| out.* = true;
    return ctx.gpa.dupe(u8, "queued for the owner");
}

fn runAttach(ctx: *tools.Ctx, args: []const u8) anyerror![]u8 {
    const Args = struct {
        path: []const u8,
        caption: ?[]const u8 = null,
        as: ?[]const u8 = null,
    };
    const parsed = try std.json.parseFromSlice(Args, ctx.gpa, args, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    const a = parsed.value;
    const kind: Kind = if (a.as) |s| std.meta.stringToEnum(Kind, s) orelse return error.BadMediaKind else .document;
    if (kind == .text or kind == .sticker) return error.BadMediaKind;
    try workspace.checkFile(ctx.io, ctx.workspace, a.path, workspace.max_transfer);
    const now = std.Io.Timestamp.now(ctx.io, .real).toSeconds();
    push(ctx.db, kind, a.path, a.caption orelse "", now) catch |err|
        return std.fmt.allocPrint(ctx.gpa, "not queued: {s}", .{@errorName(err)});
    if (ctx.delivery_out) |out| out.* = true;
    return std.fmt.allocPrint(ctx.gpa, "queued {s}", .{a.path});
}

fn runSticker(ctx: *tools.Ctx, args: []const u8) anyerror![]u8 {
    const Args = struct { alias: []const u8 };
    const parsed = try std.json.parseFromSlice(Args, ctx.gpa, args, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    if (!safeAlias(parsed.value.alias)) return ctx.gpa.dupe(u8, "invalid sticker alias");
    if (!try stickerExists(ctx.db, parsed.value.alias)) return ctx.gpa.dupe(u8, "unknown sticker alias");
    if (try stickerQueued(ctx.db, parsed.value.alias)) return ctx.gpa.dupe(u8, "sticker already queued");
    push(ctx.db, .sticker, parsed.value.alias, "", std.Io.Timestamp.now(ctx.io, .real).toSeconds()) catch |err|
        return std.fmt.allocPrint(ctx.gpa, "not queued: {s}", .{@errorName(err)});
    if (ctx.delivery_out) |out| out.* = true;
    return ctx.gpa.dupe(u8, "sticker queued");
}

pub fn stickerExists(db: *Db, alias: []const u8) !bool {
    var q = try db.prepare("SELECT 1 FROM sticker_aliases WHERE alias = ?");
    defer q.finalize();
    try q.bind(1, alias);
    return q.step();
}

fn stickerQueued(db: *Db, alias: []const u8) !bool {
    var q = try db.prepare("SELECT 1 FROM outbox WHERE kind = 'sticker' AND path = ? AND status = 'queued'");
    defer q.finalize();
    try q.bind(1, alias);
    return q.step();
}

pub fn safeAlias(alias: []const u8) bool {
    if (alias.len == 0 or alias.len > 32) return false;
    for (alias) |c| if (!std.ascii.isAlphanumeric(c) and c != '_' and c != '-') return false;
    return true;
}

test "safeRelative refuses escapes and absolutes" {
    try testing.expect(safeRelative("report.pdf"));
    try testing.expect(safeRelative("out/chart.png"));
    try testing.expect(!safeRelative("/etc/passwd"));
    try testing.expect(!safeRelative("../secrets"));
    try testing.expect(!safeRelative("out/../../etc"));
    try testing.expect(!safeRelative(""));
    try testing.expect(!safeRelative("./x"));
    try testing.expect(!safeRelative("a\"b.png"));
    try testing.expect(!safeRelative("a\r\nb.png"));
    try testing.expect(safeRelative("a b.png"));
    try testing.expect(!safeRelative("a\\b.png"));
}

test "claimed output remains until delivery is confirmed" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [128]u8 = undefined;
    var db = try testkit.tmpDb(&tmp, &buf);
    defer db.close();

    try push(&db, .text, null, "brief is ready", 100);
    try push(&db, .photo, "out/chart.png", "yesterday", 101);
    try testing.expectError(error.BadPath, push(&db, .photo, "../etc/shadow", "", 102));

    const items = try claim(&db, testing.allocator, 200);
    defer free(testing.allocator, items);
    try testing.expectEqual(@as(usize, 1), items.len);
    try testing.expectEqual(Kind.text, items[0].kind);
    try testing.expectEqualStrings("brief is ready", items[0].text);

    const again = try claim(&db, testing.allocator, 201);
    defer free(testing.allocator, again);
    try testing.expectEqual(@as(usize, 1), again.len);
    try testing.expectEqual(Kind.photo, again[0].kind);
    try testing.expectEqualStrings("out/chart.png", again[0].path.?);

    try delivered(&db, items[0].id);
    try retry(&db, again[0].id, "offline");
    const retrying = try claim(&db, testing.allocator, std.math.maxInt(i64));
    defer free(testing.allocator, retrying);
    try testing.expectEqual(@as(usize, 1), retrying.len);
    try testing.expectEqual(again[0].id, retrying[0].id);
    try uncertain(&db, retrying[0].id, "timeout");
    const final = try claim(&db, testing.allocator, 203);
    defer free(testing.allocator, final);
    try testing.expectEqual(@as(usize, 0), final.len);
}

test "unknown stickers never enter the outbox" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [128]u8 = undefined;
    var db = try testkit.tmpDb(&tmp, &buf);
    defer db.close();
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    var ctx: tools.Ctx = .{ .gpa = testing.allocator, .io = threaded.io(), .db = &db };

    const result = try tools.call(&ctx, &.{send_sticker}, "send_sticker", "{\"alias\":\"missing\"}");
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("unknown sticker alias", result);
    var q = try db.prepare("SELECT count(*) FROM outbox");
    defer q.finalize();
    try testing.expect(try q.step());
    try testing.expectEqual(@as(i64, 0), q.int(0));
}

test "the same pending sticker is queued once" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [128]u8 = undefined;
    var db = try testkit.tmpDb(&tmp, &buf);
    defer db.close();
    try db.exec("INSERT INTO sticker_aliases(alias, file_id, unique_id, updated) VALUES ('pro', 'file', 'stable', 1)");
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    var ctx: tools.Ctx = .{ .gpa = testing.allocator, .io = threaded.io(), .db = &db };

    for (0..2) |_| {
        const result = try tools.call(&ctx, &.{send_sticker}, "send_sticker", "{\"alias\":\"pro\"}");
        testing.allocator.free(result);
    }
    var q = try db.prepare("SELECT count(*) FROM outbox WHERE kind = 'sticker' AND status = 'queued'");
    defer q.finalize();
    try testing.expect(try q.step());
    try testing.expectEqual(@as(i64, 1), q.int(0));
}

test "restart preserves an interrupted send as uncertain" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [128]u8 = undefined;
    var db = try testkit.tmpDb(&tmp, &buf);
    defer db.close();

    try push(&db, .text, null, "sent maybe", 1);
    const items = try claim(&db, testing.allocator, 2);
    defer free(testing.allocator, items);
    try recover(&db);

    var q = try db.prepare("SELECT status FROM outbox WHERE id = ?");
    defer q.finalize();
    try q.bind(1, items[0].id);
    try testing.expect(try q.step());
    try testing.expectEqualStrings("uncertain", q.text(0));
}

test "delivery retries stop after three attempts" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [128]u8 = undefined;
    var db = try testkit.tmpDb(&tmp, &buf);
    defer db.close();

    try push(&db, .text, null, "later", 1);
    var attempt: i64 = 0;
    while (attempt < max_attempts) : (attempt += 1) {
        const items = try claim(&db, testing.allocator, std.math.maxInt(i64));
        defer free(testing.allocator, items);
        try testing.expectEqual(@as(usize, 1), items.len);
        try retry(&db, items[0].id, "offline");
    }
    var q = try db.prepare("SELECT status, attempts FROM outbox");
    defer q.finalize();
    try testing.expect(try q.step());
    try testing.expectEqualStrings("failed", q.text(0));
    try testing.expectEqual(max_attempts, q.int(1));
}

test "an over-long message is trimmed on a codepoint boundary, not rejected" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [128]u8 = undefined;
    var db = try testkit.tmpDb(&tmp, &buf);
    defer db.close();

    const long = try testing.allocator.alloc(u8, max_text + 64);
    defer testing.allocator.free(long);
    var i: usize = 0;
    while (i + 1 < long.len) : (i += 2) {
        long[i] = 0xC3;
        long[i + 1] = 0xA9;
    }
    long[long.len - 1] = 'x';

    try push(&db, .text, null, long, 1);
    const items = try claim(&db, testing.allocator, 2);
    defer free(testing.allocator, items);
    try testing.expect(items[0].text.len <= max_text);
    try testing.expect(std.unicode.utf8ValidateSlice(items[0].text));
}
