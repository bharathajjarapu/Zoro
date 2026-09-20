const std = @import("std");
const Db = @import("db.zig").Db;
const testing = std.testing;
const testkit = @import("../testing/testkit.zig");

/// A submitted key reaches the LLM provider once before scrubbing.
pub fn put(db: *Db, name: []const u8, value: []const u8, host: []const u8, now: i64) !void {
    var statement = try db.prepare(
        \\INSERT INTO secrets(name, value, host, created) VALUES (?, ?, ?, ?)
        \\ON CONFLICT(name) DO UPDATE SET value = excluded.value, host = excluded.host
    );
    defer statement.finalize();
    try statement.bind(1, name);
    try statement.bind(2, value);
    try statement.bind(3, host);
    try statement.bind(4, now);
    _ = try statement.step();
    try scrubMessages(db, value, name);
}

/// Value for `host`, or null. Caller owns the bytes. Never log the result.
pub fn valueFor(db: *Db, gpa: std.mem.Allocator, host: []const u8) !?[]u8 {
    var statement = try db.prepare("SELECT value FROM secrets WHERE host = ?");
    defer statement.finalize();
    try statement.bind(1, host);
    if (!try statement.step()) return null;
    return try gpa.dupe(u8, statement.text(0));
}

/// Names only — this is what the model is allowed to see.
pub fn names(db: *Db, gpa: std.mem.Allocator) ![][]u8 {
    var statement = try db.prepare("SELECT name FROM secrets ORDER BY name");
    defer statement.finalize();
    var out: std.ArrayList([]u8) = .empty;
    errdefer {
        for (out.items) |name| gpa.free(name);
        out.deinit(gpa);
    }
    while (try statement.step()) {
        try out.append(gpa, try gpa.dupe(u8, statement.text(0)));
    }
    return out.toOwnedSlice(gpa);
}

fn scrubMessages(db: *Db, value: []const u8, name: []const u8) !void {
    var token_buf: [80]u8 = undefined;
    const token = std.fmt.bufPrint(&token_buf, "[secret:{s}]", .{name}) catch "[secret]";
    var statement = try db.prepare("UPDATE messages SET content = replace(content, ?, ?)");
    defer statement.finalize();
    try statement.bind(1, value);
    try statement.bind(2, token);
    _ = try statement.step();
}

/// Caller owns the result. Used so diary/logs never keep a raw key.
pub fn redact(db: *Db, gpa: std.mem.Allocator, text: []const u8) ![]u8 {
    var cur = try gpa.dupe(u8, text);
    errdefer gpa.free(cur);
    var statement = try db.prepare("SELECT name, value FROM secrets");
    defer statement.finalize();
    while (try statement.step()) {
        const value = statement.text(1);
        if (value.len == 0) continue;
        if (std.mem.indexOf(u8, cur, value) == null) continue;
        var token_buf: [80]u8 = undefined;
        const token = std.fmt.bufPrint(&token_buf, "[secret:{s}]", .{statement.text(0)}) catch "[secret]";
        const next = try replaceAll(gpa, cur, value, token);
        gpa.free(cur);
        cur = next;
    }
    return cur;
}

fn replaceAll(gpa: std.mem.Allocator, text: []const u8, needle: []const u8, with: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var rest = text;
    while (std.mem.indexOf(u8, rest, needle)) |index| {
        try out.appendSlice(gpa, rest[0..index]);
        try out.appendSlice(gpa, with);
        rest = rest[index + needle.len ..];
    }
    try out.appendSlice(gpa, rest);
    return out.toOwnedSlice(gpa);
}

test "the model-visible list is names only" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [128]u8 = undefined;
    var db = try Db.open(try testkit.tmpPath(&tmp, &buf, "zoro.db"));
    defer db.close();
    try db.initSchema();

    try put(&db, "weather_api_key", "sk-secret-value", "api.weather.com", 1000);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const list = try names(&db, arena.allocator());
    try testing.expectEqual(@as(usize, 1), list.len);
    try testing.expectEqualStrings("weather_api_key", list[0]);
}

test "the value is attached only to its approved host" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [128]u8 = undefined;
    var db = try Db.open(try testkit.tmpPath(&tmp, &buf, "zoro.db"));
    defer db.close();
    try db.initSchema();

    try put(&db, "weather_api_key", "sk-secret-value", "api.weather.com", 1000);
    {
        const value = try valueFor(&db, testing.allocator, "evil.com");
        try testing.expect(value == null);
    }
    const value = try valueFor(&db, testing.allocator, "api.weather.com") orelse return error.Missing;
    defer testing.allocator.free(value);
    try testing.expectEqualStrings("sk-secret-value", value);
}

test "storing a secret scrubs it from the transcript" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [128]u8 = undefined;
    var db = try Db.open(try testkit.tmpPath(&tmp, &buf, "zoro.db"));
    defer db.close();
    try db.initSchema();

    var ins = try db.prepare("INSERT INTO messages(role, content, created) VALUES ('user', ?, 1)");
    defer ins.finalize();
    try ins.bind(1, "the key is sk-secret-value please store it");
    _ = try ins.step();

    try put(&db, "weather_api_key", "sk-secret-value", "api.weather.com", 1000);

    var statement = try db.prepare("SELECT content FROM messages");
    defer statement.finalize();
    try testing.expect(try statement.step());
    try testing.expect(std.mem.indexOf(u8, statement.text(0), "sk-secret-value") == null);
    try testing.expect(std.mem.indexOf(u8, statement.text(0), "[secret:weather_api_key]") != null);
}

test "redact strips secret values from text" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [128]u8 = undefined;
    var db = try Db.open(try testkit.tmpPath(&tmp, &buf, "zoro.db"));
    defer db.close();
    try db.initSchema();

    try put(&db, "weather_api_key", "sk-secret-value", "api.weather.com", 1000);
    const out = try redact(&db, testing.allocator, "the key is sk-secret-value");
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "sk-secret-value") == null);
    try testing.expect(std.mem.indexOf(u8, out, "[secret:weather_api_key]") != null);
}
