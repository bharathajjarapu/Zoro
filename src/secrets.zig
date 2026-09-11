const std = @import("std");
const Db = @import("db.zig").Db;
const testing = std.testing;
const testkit = @import("testkit.zig");

/// Accepted risk: the raw key reaches the LLM provider once, in the message
/// that carries it. Intake is conversational; the scrub runs after storage.
/// Treat any key handed over this way as disclosed to the provider.
const intake_risk = "accepted risk: secret reaches the provider once before scrub";

pub fn put(db: *Db, name: []const u8, value: []const u8, host: []const u8, now: i64) !void {
    _ = intake_risk;
    var q = try db.prepare(
        \\INSERT INTO secrets(name, value, host, created) VALUES (?, ?, ?, ?)
        \\ON CONFLICT(name) DO UPDATE SET value = excluded.value, host = excluded.host
    );
    defer q.finalize();
    try q.bind(1, name);
    try q.bind(2, value);
    try q.bind(3, host);
    try q.bind(4, now);
    _ = try q.step();
    try scrubMessages(db, value, name);
}

/// Value for `host`, or null. Caller owns the bytes. Never log the result.
pub fn valueFor(db: *Db, gpa: std.mem.Allocator, host: []const u8) !?[]u8 {
    var q = try db.prepare("SELECT value FROM secrets WHERE host = ?");
    defer q.finalize();
    try q.bind(1, host);
    if (!try q.step()) return null;
    return try gpa.dupe(u8, q.text(0));
}

/// Names only — this is what the model is allowed to see.
pub fn names(db: *Db, gpa: std.mem.Allocator) ![][]u8 {
    var q = try db.prepare("SELECT name FROM secrets ORDER BY name");
    defer q.finalize();
    var out: std.ArrayList([]u8) = .empty;
    errdefer {
        for (out.items) |n| gpa.free(n);
        out.deinit(gpa);
    }
    while (try q.step()) {
        try out.append(gpa, try gpa.dupe(u8, q.text(0)));
    }
    return out.toOwnedSlice(gpa);
}

fn scrubMessages(db: *Db, value: []const u8, name: []const u8) !void {
    var token_buf: [80]u8 = undefined;
    const token = std.fmt.bufPrint(&token_buf, "[secret:{s}]", .{name}) catch "[secret]";
    var q = try db.prepare("UPDATE messages SET content = replace(content, ?, ?)");
    defer q.finalize();
    try q.bind(1, value);
    try q.bind(2, token);
    _ = try q.step();
}

/// Caller owns the result. Used so diary/logs never keep a raw key.
pub fn redact(db: *Db, gpa: std.mem.Allocator, text: []const u8) ![]u8 {
    var cur = try gpa.dupe(u8, text);
    errdefer gpa.free(cur);
    var q = try db.prepare("SELECT name, value FROM secrets");
    defer q.finalize();
    while (try q.step()) {
        const value = q.text(1);
        if (value.len == 0) continue;
        if (std.mem.indexOf(u8, cur, value) == null) continue;
        var token_buf: [80]u8 = undefined;
        const token = std.fmt.bufPrint(&token_buf, "[secret:{s}]", .{q.text(0)}) catch "[secret]";
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
    while (std.mem.indexOf(u8, rest, needle)) |i| {
        try out.appendSlice(gpa, rest[0..i]);
        try out.appendSlice(gpa, with);
        rest = rest[i + needle.len ..];
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
    try db.migrate();

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
    try db.migrate();

    try put(&db, "weather_api_key", "sk-secret-value", "api.weather.com", 1000);
    {
        const v = try valueFor(&db, testing.allocator, "evil.com");
        try testing.expect(v == null);
    }
    const v = try valueFor(&db, testing.allocator, "api.weather.com") orelse return error.Missing;
    defer testing.allocator.free(v);
    try testing.expectEqualStrings("sk-secret-value", v);
}

test "storing a secret scrubs it from the transcript" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [128]u8 = undefined;
    var db = try Db.open(try testkit.tmpPath(&tmp, &buf, "zoro.db"));
    defer db.close();
    try db.migrate();

    var ins = try db.prepare("INSERT INTO messages(role, content, created) VALUES ('user', ?, 1)");
    defer ins.finalize();
    try ins.bind(1, "the key is sk-secret-value please store it");
    _ = try ins.step();

    try put(&db, "weather_api_key", "sk-secret-value", "api.weather.com", 1000);

    var q = try db.prepare("SELECT content FROM messages");
    defer q.finalize();
    try testing.expect(try q.step());
    try testing.expect(std.mem.indexOf(u8, q.text(0), "sk-secret-value") == null);
    try testing.expect(std.mem.indexOf(u8, q.text(0), "[secret:weather_api_key]") != null);
}

test "redact strips secret values from text" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [128]u8 = undefined;
    var db = try Db.open(try testkit.tmpPath(&tmp, &buf, "zoro.db"));
    defer db.close();
    try db.migrate();

    try put(&db, "weather_api_key", "sk-secret-value", "api.weather.com", 1000);
    const out = try redact(&db, testing.allocator, "the key is sk-secret-value");
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "sk-secret-value") == null);
    try testing.expect(std.mem.indexOf(u8, out, "[secret:weather_api_key]") != null);
}
