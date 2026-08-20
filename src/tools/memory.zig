const std = @import("std");
const mem = @import("../memory.zig");
const tools = @import("../tools.zig");

const Param = tools.Param;
const Def = tools.Def;
const Ctx = tools.Ctx;

const kv = [_]Param{
    .{ .name = "key", .description = "short name for this fact" },
    .{ .name = "value", .description = "the fact itself" },
};
const key_only = [_]Param{.{ .name = "key", .description = "fact key to forget" }};
const query = [_]Param{.{ .name = "query", .description = "what to search for" }};

pub const remember: Def = .{
    .name = "remember",
    .description = "Save a durable fact about the owner. Use a short key.",
    .params = &kv,
    .run = runRemember,
};

pub const recall: Def = .{
    .name = "recall",
    .description = "Search saved facts and diary entries.",
    .params = &query,
    .run = runRecall,
};

pub const forget: Def = .{
    .name = "forget",
    .description = "Delete a saved fact by key.",
    .params = &key_only,
    .run = runForget,
};

const Kv = struct { key: []const u8, value: []const u8 };
const Key = struct { key: []const u8 };
const Query = struct { query: []const u8 };

fn runRemember(ctx: *Ctx, args: []const u8) anyerror![]u8 {
    const parsed = try std.json.parseFromSlice(Kv, ctx.gpa, args, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    const now = std.Io.Timestamp.now(ctx.io, .real).toSeconds();
    try mem.put(ctx.db, parsed.value.key, parsed.value.value, .owner, now, null);
    return try std.fmt.allocPrint(ctx.gpa, "remembered {s}", .{parsed.value.key});
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
    for (hits) |h| {
        try out.writer.print("{s} ({s}): {s}\n", .{ h.ref, h.kind, h.text });
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
const Db = @import("../db.zig").Db;

fn tmpPath(tmp: *testing.TmpDir, buf: []u8) ![:0]u8 {
    return std.fmt.bufPrintZ(buf, ".zig-cache/tmp/{s}/zoro.db", .{tmp.sub_path});
}

test "remember then recall round-trips a fact" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [128]u8 = undefined;
    var db = try Db.open(try tmpPath(&tmp, &buf));
    defer db.close();
    try db.migrate();
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();

    var ctx: Ctx = .{ .gpa = testing.allocator, .io = threaded.io(), .db = &db };
    const out = try tools.call(&ctx, &tools.builtins, "remember", "{\"key\":\"pet\",\"value\":\"a black cat\"}");
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "pet") != null);

    const hits = try tools.call(&ctx, &tools.builtins, "recall", "{\"query\":\"cat\"}");
    defer testing.allocator.free(hits);
    try testing.expect(std.mem.indexOf(u8, hits, "black cat") != null);
}
