const std = @import("std");
const Db = @import("db.zig").Db;
const tools = @import("tools.zig");
const testing = std.testing;

/// Nothing the agent queues may be larger than one Telegram message; the
/// channel chunks anything longer.
pub const max_text: usize = 8 * 1024;
/// Drained per turn. A runaway routine cannot flood the owner in one go.
pub const max_drain: usize = 16;

pub const Kind = enum { text, photo, document };

pub const Item = struct {
    id: i64,
    kind: Kind,
    path: ?[]u8,
    text: []u8,

    pub fn deinit(self: *Item, gpa: std.mem.Allocator) void {
        if (self.path) |p| gpa.free(p);
        gpa.free(self.text);
        self.* = undefined;
    }
};

/// Queues one outbound item. `path` is workspace-relative and only meaningful
/// for a photo or document.
pub fn push(db: *Db, kind: Kind, path: ?[]const u8, body: []const u8, now: i64) !void {
    if (kind != .text and (path == null or !safeRelative(path.?))) return error.BadPath;
    const text = clamp(body);
    var q = try db.prepare("INSERT INTO outbox(kind, path, text, created) VALUES (?, ?, ?, ?)");
    defer q.finalize();
    try q.bind(1, @tagName(kind));
    try q.bind(2, path);
    try q.bind(3, text);
    try q.bind(4, now);
    _ = try q.step();
}

/// Takes up to `max_drain` items and removes them. Caller owns the slice.
pub fn drain(db: *Db, gpa: std.mem.Allocator) ![]Item {
    var out: std.ArrayList(Item) = .empty;
    errdefer free(gpa, out.items);
    {
        var q = try db.prepare("SELECT id, kind, path, text FROM outbox ORDER BY id LIMIT ?");
        defer q.finalize();
        try q.bind(1, @as(i64, @intCast(max_drain)));
        while (try q.step()) {
            const kind = std.meta.stringToEnum(Kind, q.text(1)) orelse .text;
            const path = if (q.isNull(2)) null else try gpa.dupe(u8, q.text(2));
            errdefer if (path) |p| gpa.free(p);
            try out.append(gpa, .{
                .id = q.int(0),
                .kind = kind,
                .path = path,
                .text = try gpa.dupe(u8, q.text(3)),
            });
        }
    }
    for (out.items) |item| {
        var d = try db.prepare("DELETE FROM outbox WHERE id = ?");
        defer d.finalize();
        try d.bind(1, item.id);
        _ = try d.step();
    }
    return out.toOwnedSlice(gpa);
}

pub fn free(gpa: std.mem.Allocator, items: []Item) void {
    for (items) |*i| i.deinit(gpa);
    gpa.free(items);
}

/// Trims to `max_text` on a UTF-8 boundary. A routine that produced an essay
/// gets truncated, never a corrupt message and never a failed run.
fn clamp(text: []const u8) []const u8 {
    if (text.len <= max_text) return text;
    var end = max_text;
    while (end > 0 and text[end] & 0xC0 == 0x80) end -= 1;
    return text[0..end];
}

/// Workspace-relative and nothing else: no absolute path, no `..`, no leading
/// slash. The container mount is the outer boundary; this is the inner one.
pub fn safeRelative(path: []const u8) bool {
    if (path.len == 0 or path.len > 512) return false;
    if (path[0] == '/' or path[0] == '\\') return false;
    if (std.mem.indexOfScalar(u8, path, 0) != null) return false;
    var it = std.mem.splitScalar(u8, path, '/');
    while (it.next()) |seg| {
        if (seg.len == 0 or std.mem.eql(u8, seg, "..") or std.mem.eql(u8, seg, ".")) return false;
    }
    return true;
}

const notify_params = [_]tools.Param{
    .{ .name = "text", .description = "message to deliver to the owner" },
};

pub const notify_owner: tools.Def = .{
    .name = "notify_owner",
    .description = "Queue a message for the owner. Use this from a routine; a normal reply reaches them already.",
    .params = &notify_params,
    .run = runNotify,
};

const attach_params = [_]tools.Param{
    .{ .name = "path", .description = "workspace-relative file path" },
    .{ .name = "caption", .description = "text sent with the file", .required = false },
    .{ .name = "as", .description = "photo or document (default document)", .required = false },
};

pub const attach_file: tools.Def = .{
    .name = "attach_file",
    .description = "Send a file from the workspace to the owner as a photo or document.",
    .params = &attach_params,
    .run = runAttach,
};

fn runNotify(ctx: *tools.Ctx, args: []const u8) anyerror![]u8 {
    const Args = struct { text: []const u8 };
    const parsed = try std.json.parseFromSlice(Args, ctx.gpa, args, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    const now = std.Io.Timestamp.now(ctx.io, .real).toSeconds();
    push(ctx.db, .text, null, parsed.value.text, now) catch |err|
        return std.fmt.allocPrint(ctx.gpa, "not queued: {s}", .{@errorName(err)});
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
    const kind: Kind = if (a.as) |s| (std.meta.stringToEnum(Kind, s) orelse .document) else .document;
    const now = std.Io.Timestamp.now(ctx.io, .real).toSeconds();
    push(ctx.db, if (kind == .text) .document else kind, a.path, a.caption orelse "", now) catch |err|
        return std.fmt.allocPrint(ctx.gpa, "not queued: {s}", .{@errorName(err)});
    return std.fmt.allocPrint(ctx.gpa, "queued {s}", .{a.path});
}

fn tmpDb(tmp: *testing.TmpDir, buf: []u8) !Db {
    const path = try std.fmt.bufPrintZ(buf, ".zig-cache/tmp/{s}/zoro.db", .{tmp.sub_path});
    var db = try Db.open(path);
    errdefer db.close();
    try db.migrate();
    return db;
}

test "safeRelative refuses escapes and absolutes" {
    try testing.expect(safeRelative("report.pdf"));
    try testing.expect(safeRelative("out/chart.png"));
    try testing.expect(!safeRelative("/etc/passwd"));
    try testing.expect(!safeRelative("../secrets"));
    try testing.expect(!safeRelative("out/../../etc"));
    try testing.expect(!safeRelative(""));
    try testing.expect(!safeRelative("./x"));
}

test "push then drain returns items once and empties the queue" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [128]u8 = undefined;
    var db = try tmpDb(&tmp, &buf);
    defer db.close();

    try push(&db, .text, null, "brief is ready", 100);
    try push(&db, .photo, "out/chart.png", "yesterday", 101);
    try testing.expectError(error.BadPath, push(&db, .photo, "../etc/shadow", "", 102));

    const items = try drain(&db, testing.allocator);
    defer free(testing.allocator, items);
    try testing.expectEqual(@as(usize, 2), items.len);
    try testing.expectEqual(Kind.text, items[0].kind);
    try testing.expectEqualStrings("brief is ready", items[0].text);
    try testing.expectEqual(Kind.photo, items[1].kind);
    try testing.expectEqualStrings("out/chart.png", items[1].path.?);

    const again = try drain(&db, testing.allocator);
    defer free(testing.allocator, again);
    try testing.expectEqual(@as(usize, 0), again.len);
}

test "an over-long message is trimmed on a codepoint boundary, not rejected" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [128]u8 = undefined;
    var db = try tmpDb(&tmp, &buf);
    defer db.close();

    const long = try testing.allocator.alloc(u8, max_text + 64);
    defer testing.allocator.free(long);
    // "é" is two bytes, so a naive cut at max_text lands mid-codepoint.
    var i: usize = 0;
    while (i + 1 < long.len) : (i += 2) {
        long[i] = 0xC3;
        long[i + 1] = 0xA9;
    }
    long[long.len - 1] = 'x';

    try push(&db, .text, null, long, 1);
    const items = try drain(&db, testing.allocator);
    defer free(testing.allocator, items);
    try testing.expect(items[0].text.len <= max_text);
    try testing.expect(std.unicode.utf8ValidateSlice(items[0].text));
}
