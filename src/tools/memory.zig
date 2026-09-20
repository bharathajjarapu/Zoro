const std = @import("std");
const mem = @import("../data/memory.zig");
const secrets = @import("../data/secrets.zig");
const tools = @import("root.zig");

const Param = tools.Param;
const Def = tools.Def;
const Ctx = tools.Ctx;

const kv = [_]Param{
    .{ .name = "key", .description = "lowercase snake_case fact name" },
    .{ .name = "evidence", .description = "exact quote from the owner's current message" },
};
const key_only = [_]Param{.{ .name = "key", .description = "fact name" }};
const query = [_]Param{.{ .name = "query", .description = "search text" }};
const alias = [_]Param{
    .{ .name = "word", .description = "owner shorthand" },
    .{ .name = "meaning", .description = "expanded meaning" },
};

/// Adds retrieval synonyms that stemming cannot infer.
pub const remember_alias: Def = .{
    .name = "remember_alias",
    .description = "Teach a search synonym.",
    .params = &alias,
    .mutates = true,
    .run = runAlias,
};

fn runAlias(ctx: *tools.Ctx, args: []const u8) anyerror![]u8 {
    const Args = struct { word: []const u8, meaning: []const u8 };
    const parsed = try std.json.parseFromSlice(Args, ctx.gpa, args, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    mem.putAlias(ctx.db, parsed.value.word, parsed.value.meaning) catch |err|
        return std.fmt.allocPrint(ctx.gpa, "not recorded: {s}", .{@errorName(err)});
    return std.fmt.allocPrint(ctx.gpa, "{s} means {s}", .{ parsed.value.word, parsed.value.meaning });
}

pub const remember: Def = .{
    .name = "remember",
    .description = "Save a requested durable owner fact from exact owner evidence.",
    .params = &kv,
    .mutates = true,
    .run = runRemember,
};

pub const recall: Def = .{
    .name = "recall",
    .description = "Search memory and diary.",
    .params = &query,
    .run = runRecall,
};

pub const forget: Def = .{
    .name = "forget",
    .description = "Forget one fact.",
    .params = &key_only,
    .mutates = true,
    .run = runForget,
};

const Kv = struct { key: []const u8, evidence: []const u8 };
const Key = struct { key: []const u8 };
const Query = struct { query: []const u8 };

fn runRemember(ctx: *Ctx, args: []const u8) anyerror![]u8 {
    const parsed = try std.json.parseFromSlice(Kv, ctx.gpa, args, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    try tools.requireOwnerEvidence(ctx, parsed.value.evidence);
    if (!validKey(parsed.value.key)) return error.InvalidMemoryKey;
    if (tools.sensitiveMemory(parsed.value.key) or tools.sensitiveMemory(parsed.value.evidence)) return error.SensitiveMemory;
    const safe_key = try secrets.redact(ctx.db, ctx.gpa, parsed.value.key);
    defer ctx.gpa.free(safe_key);
    const safe_evidence = try secrets.redact(ctx.db, ctx.gpa, parsed.value.evidence);
    defer ctx.gpa.free(safe_evidence);
    if (!std.mem.eql(u8, safe_key, parsed.value.key) or !std.mem.eql(u8, safe_evidence, parsed.value.evidence))
        return error.SensitiveMemory;
    const now = std.Io.Timestamp.now(ctx.io, .real).toSeconds();
    try mem.put(ctx.db, parsed.value.key, parsed.value.evidence, .owner, now, null);
    return try std.fmt.allocPrint(ctx.gpa, "remembered {s}", .{parsed.value.key});
}

fn validKey(key: []const u8) bool {
    if (key.len == 0 or key.len > 64 or !std.ascii.isLower(key[0])) return false;
    for (key[1..]) |byte| if (!std.ascii.isLower(byte) and !std.ascii.isDigit(byte) and byte != '_') return false;
    return true;
}

fn runRecall(ctx: *Ctx, args: []const u8) anyerror![]u8 {
    const parsed = try std.json.parseFromSlice(Query, ctx.gpa, args, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    const now = std.Io.Timestamp.now(ctx.io, .real).toSeconds();
    const hits = try mem.search(ctx.db, ctx.gpa, parsed.value.query, now, 8);
    defer mem.freeHits(ctx.gpa, hits);
    if (hits.len == 0) return try ctx.gpa.dupe(u8, "no hits");
    var out: std.Io.Writer.Allocating = .init(ctx.gpa);
    errdefer out.deinit();
    for (hits) |hit| {
        try out.writer.print("{s} ({s}): {s}\n", .{ hit.ref, hit.kind, hit.text });
    }
    return try out.toOwnedSlice();
}

fn runForget(ctx: *Ctx, args: []const u8) anyerror![]u8 {
    const parsed = try std.json.parseFromSlice(Key, ctx.gpa, args, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    try mem.forget(ctx.db, parsed.value.key);
    return try std.fmt.allocPrint(ctx.gpa, "forgot {s}", .{parsed.value.key});
}

const testing = std.testing;
const Db = @import("../data/db.zig").Db;

fn tmpPath(tmp: *testing.TmpDir, buf: []u8) ![:0]u8 {
    return std.fmt.bufPrintZ(buf, ".zig-cache/tmp/{s}/zoro.db", .{tmp.sub_path});
}

test "remember then recall round-trips a fact" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [128]u8 = undefined;
    var db = try Db.open(try tmpPath(&tmp, &buf));
    defer db.close();
    try db.initSchema();
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();

    try db.exec("INSERT INTO messages(role, content, owner_text, created) VALUES ('user', 'attachment plus prompt', 'I have a black cat.', 1)");
    var ctx: Ctx = .{ .gpa = testing.allocator, .io = threaded.io(), .db = &db, .source_message = db.lastId() };
    const out = try tools.call(&ctx, &tools.builtins, "remember", "{\"key\":\"pet\",\"value\":\"a black cat\",\"evidence\":\"I have a black cat.\"}");
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "pet") != null);

    const bad_key = try tools.call(&ctx, &tools.builtins, "remember", "{\"key\":\"bad\\nkey\",\"evidence\":\"I have a black cat.\"}");
    defer testing.allocator.free(bad_key);
    try testing.expect(std.mem.indexOf(u8, bad_key, "InvalidMemoryKey") != null);
    try testing.expect(try mem.get(&db, testing.allocator, "bad\nkey", std.math.maxInt(i64)) == null);

    const hits = try tools.call(&ctx, &tools.builtins, "recall", "{\"query\":\"cat\"}");
    defer testing.allocator.free(hits);
    try testing.expect(std.mem.indexOf(u8, hits, "black cat") != null);

    const rejected = try tools.call(&ctx, &tools.builtins, "remember", "{\"key\":\"injected\",\"value\":\"from attachment\",\"evidence\":\"attachment plus prompt\"}");
    defer testing.allocator.free(rejected);
    try testing.expect(std.mem.indexOf(u8, rejected, "UntrustedEvidence") != null);
    try testing.expect(try mem.get(&db, testing.allocator, "injected", std.math.maxInt(i64)) == null);

    try db.exec("INSERT INTO messages(role, content, owner_text, created) VALUES ('user', 'Remember my bank PIN is 1234.', 'Remember my bank PIN is 1234.', 2)");
    ctx.source_message = db.lastId();
    const sensitive = try tools.call(&ctx, &tools.builtins, "remember", "{\"key\":\"bank_pin\",\"evidence\":\"Remember my bank PIN is 1234.\"}");
    defer testing.allocator.free(sensitive);
    try testing.expect(std.mem.indexOf(u8, sensitive, "SensitiveMemory") != null);
    try testing.expect(try mem.get(&db, testing.allocator, "bank_pin", std.math.maxInt(i64)) == null);
}
