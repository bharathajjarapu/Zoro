const std = @import("std");
const Db = @import("db.zig").Db;
const web = @import("web.zig");
const testing = std.testing;

pub const max_result: usize = 64 * 1024;
const trunc_mark = "\n[truncated]";

pub const Param = struct {
    name: []const u8,
    description: []const u8,
    required: bool = true,
};

pub const Ctx = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    db: *Db,
    skills_dir: []const u8 = "skills",
    workspace: []const u8 = "workspace",
    fetch: ?web.Get = null,
    limiter: ?*web.Limiter = null,
};

pub const Def = struct {
    name: []const u8,
    description: []const u8,
    params: []const Param,
    run: *const fn (*Ctx, []const u8) anyerror![]u8,
    /// Changes state the owner would care about. A `notify` routine never gets one.
    mutates: bool = false,
    /// Withheld from routines and subagents: delegation is the primary's job.
    primary_only: bool = false,
};

/// The tools a restricted caller may use. `read_only` drops everything that
/// mutates, `names` is a space-separated allowlist (null means no allowlist),
/// and `primary_only` tools are never handed out. Caller frees the slice.
pub fn subset(gpa: std.mem.Allocator, all: []const Def, read_only: bool, names: ?[]const u8) ![]Def {
    var out: std.ArrayList(Def) = .empty;
    errdefer out.deinit(gpa);
    for (all) |t| {
        if (t.primary_only) continue;
        if (read_only and t.mutates) continue;
        if (names) |list| if (!listed(list, t.name)) continue;
        try out.append(gpa, t);
    }
    return out.toOwnedSlice(gpa);
}

fn listed(list: []const u8, name: []const u8) bool {
    var it = std.mem.tokenizeAny(u8, list, " ,\t");
    while (it.next()) |word| {
        if (std.mem.eql(u8, word, name)) return true;
    }
    return false;
}

const secrets = @import("secrets.zig");
const secret_params = [_]Param{
    .{ .name = "name", .description = "short name, e.g. weather_api_key" },
    .{ .name = "value", .description = "the secret itself" },
    .{ .name = "host", .description = "the one HTTPS host this secret may be sent to" },
};

pub const store_secret: Def = .{
    .name = "store_secret",
    .description = "Store an API key. The value is scrubbed from the transcript; only the name remains visible.",
    .params = &secret_params,
    .mutates = true,
    .run = runStoreSecret,
};

fn runStoreSecret(ctx: *Ctx, args: []const u8) anyerror![]u8 {
    const Args = struct { name: []const u8, value: []const u8, host: []const u8 };
    const parsed = try std.json.parseFromSlice(Args, ctx.gpa, args, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    const now = std.Io.Timestamp.now(ctx.io, .real).toSeconds();
    try secrets.put(ctx.db, parsed.value.name, parsed.value.value, parsed.value.host, now);
    return try std.fmt.allocPrint(ctx.gpa, "stored {s} for {s}", .{ parsed.value.name, parsed.value.host });
}

pub const memory = @import("tools/memory.zig");
const skills = @import("skills.zig");
const web_tools = @import("tools/web.zig");
const tasks = @import("tasks.zig");
const outbox = @import("outbox.zig");
const routine = @import("tools/routine.zig");

const ask_params = [_]Param{
    .{ .name = "tool", .description = "tool to run if approved" },
    .{ .name = "args", .description = "exact JSON arguments bound to the approval" },
    .{ .name = "reason", .description = "plain-language explanation for the owner" },
    .{ .name = "target", .description = "what the action touches", .required = false },
};

pub const request_permission: Def = .{
    .name = "request_permission",
    .description = "Record a pending action. The owner must approve this exact tool and arguments in chat.",
    .params = &ask_params,
    .mutates = true,
    .run = runAsk,
};

const AskArgs = struct {
    tool: []const u8,
    args: []const u8,
    reason: []const u8,
    target: ?[]const u8 = null,
};

fn runAsk(ctx: *Ctx, args: []const u8) anyerror![]u8 {
    const parsed = try std.json.parseFromSlice(AskArgs, ctx.gpa, args, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    const now = std.Io.Timestamp.now(ctx.io, .real).toSeconds();
    const id = try tasks.ask(ctx.db, parsed.value.tool, parsed.value.args, parsed.value.target, parsed.value.reason, null, now);
    return try std.fmt.allocPrint(ctx.gpa, "pending #{d}: {s} — {s}", .{ id, parsed.value.tool, parsed.value.reason });
}

/// One line per tool. Adding a tool is its file plus a slot here.
pub const builtins = [_]Def{
    memory.remember,
    memory.recall,
    memory.forget,
    skills.load_skill,
    skills.save_skill,
    web_tools.fetch_url,
    web_tools.search,
    store_secret,
    request_permission,
    outbox.notify_owner,
    outbox.attach_file,
};

/// Actions that exist only at the far end of an approval. They are never in
/// `builtins`, so the model has no way to call one without the owner saying yes.
pub const gated = [_]Def{
    routine.enable_routine,
    routine.run_routine,
};

/// Runs an action the owner just approved: gated tools first, then the caller's
/// own list, so an approval can reach either.
pub fn callApproved(ctx: *Ctx, own: []const Def, name: []const u8, args: []const u8) ![]u8 {
    if (find(&gated, name) != null) return call(ctx, &gated, name, args);
    return call(ctx, own, name, args);
}

/// Looks up `name`, rejects bad args, runs, and caps the result. Errors become
/// a string the model can act on — they never crash the loop.
pub fn call(ctx: *Ctx, tools: []const Def, name: []const u8, args: []const u8) ![]u8 {
    const def = find(tools, name) orelse
        return std.fmt.allocPrint(ctx.gpa, "unknown tool: {s}", .{name});
    validate(ctx.gpa, def, args) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return std.fmt.allocPrint(ctx.gpa, "invalid arguments: {s}", .{@errorName(err)}),
    };
    const raw = def.run(ctx, args) catch |err|
        return std.fmt.allocPrint(ctx.gpa, "tool error: {s}", .{@errorName(err)});
    return bound(ctx.gpa, raw);
}

pub fn writeSchema(w: *std.Io.Writer, def: Def) !void {
    try w.writeAll("{\"type\":\"object\",\"properties\":{");
    for (def.params, 0..) |p, i| {
        if (i != 0) try w.writeByte(',');
        try std.json.Stringify.encodeJsonString(p.name, .{}, w);
        try w.writeAll(":{\"type\":\"string\",\"description\":");
        try std.json.Stringify.encodeJsonString(p.description, .{}, w);
        try w.writeByte('}');
    }
    try w.writeAll("},\"required\":[");
    var first = true;
    for (def.params) |p| {
        if (!p.required) continue;
        if (!first) try w.writeByte(',');
        first = false;
        try std.json.Stringify.encodeJsonString(p.name, .{}, w);
    }
    try w.writeAll("]}");
}

fn find(tools: []const Def, name: []const u8) ?Def {
    for (tools) |t| {
        if (std.mem.eql(u8, t.name, name)) return t;
    }
    return null;
}

fn validate(gpa: std.mem.Allocator, def: Def, args: []const u8) !void {
    const parsed = std.json.parseFromSlice(std.json.Value, gpa, args, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidArgs,
    };
    defer parsed.deinit();
    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return error.InvalidArgs,
    };
    for (def.params) |p| {
        if (p.required and obj.get(p.name) == null) return error.MissingParam;
    }
}

fn bound(gpa: std.mem.Allocator, raw: []u8) ![]u8 {
    if (raw.len <= max_result) return raw;
    defer gpa.free(raw);
    const keep = max_result - trunc_mark.len;
    const out = try gpa.alloc(u8, max_result);
    @memcpy(out[0..keep], raw[0..keep]);
    @memcpy(out[keep..], trunc_mark);
    return out;
}

fn tmpPath(tmp: *testing.TmpDir, buf: []u8) ![:0]u8 {
    return std.fmt.bufPrintZ(buf, ".zig-cache/tmp/{s}/zoro.db", .{tmp.sub_path});
}

fn echoRun(ctx: *Ctx, args: []const u8) anyerror![]u8 {
    return try ctx.gpa.dupe(u8, args);
}

fn boomRun(_: *Ctx, _: []const u8) anyerror![]u8 {
    return error.Boom;
}

fn bigRun(ctx: *Ctx, _: []const u8) anyerror![]u8 {
    const n = max_result + 100;
    const out = try ctx.gpa.alloc(u8, n);
    @memset(out, 'x');
    return out;
}

fn gateRun(_: *Ctx, _: []const u8) anyerror![]u8 {
    return error.ShouldNotRun;
}

const echo_params = [_]Param{.{ .name = "text", .description = "text to echo" }};
const echo_def: Def = .{ .name = "echo", .description = "echo", .params = &echo_params, .run = echoRun };
const boom_def: Def = .{ .name = "boom", .description = "boom", .params = &.{}, .run = boomRun };
const big_def: Def = .{ .name = "big", .description = "big", .params = &.{}, .run = bigRun };
const gate_def: Def = .{ .name = "gate", .description = "gate", .params = &echo_params, .run = gateRun };

fn ctxOf(db: *Db, threaded: *std.Io.Threaded) Ctx {
    return .{ .gpa = testing.allocator, .io = threaded.io(), .db = db };
}

test "invalid arguments are rejected before the tool runs" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [128]u8 = undefined;
    var db = try Db.open(try tmpPath(&tmp, &buf));
    defer db.close();
    try db.migrate();
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();

    var ctx = ctxOf(&db, &threaded);
    const tools = [_]Def{gate_def};
    const out = try call(&ctx, &tools, "gate", "{}");
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "invalid arguments") != null);
}

test "a failing tool returns an error result instead of crashing" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [128]u8 = undefined;
    var db = try Db.open(try tmpPath(&tmp, &buf));
    defer db.close();
    try db.migrate();
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();

    var ctx = ctxOf(&db, &threaded);
    const tools = [_]Def{boom_def};
    const out = try call(&ctx, &tools, "boom", "{}");
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "tool error") != null);
    try testing.expect(std.mem.indexOf(u8, out, "Boom") != null);
}

test "tool output is truncated at the cap with a visible marker" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [128]u8 = undefined;
    var db = try Db.open(try tmpPath(&tmp, &buf));
    defer db.close();
    try db.migrate();
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();

    var ctx = ctxOf(&db, &threaded);
    const tools = [_]Def{big_def};
    const out = try call(&ctx, &tools, "big", "{}");
    defer testing.allocator.free(out);
    try testing.expectEqual(max_result, out.len);
    try testing.expect(std.mem.endsWith(u8, out, trunc_mark));
}

test "unknown tool is an error result" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [128]u8 = undefined;
    var db = try Db.open(try tmpPath(&tmp, &buf));
    defer db.close();
    try db.migrate();
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();

    var ctx = ctxOf(&db, &threaded);
    const out = try call(&ctx, &.{}, "nope", "{}");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("unknown tool: nope", out);
}

test "schema lists required parameter names" {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try writeSchema(&out.writer, echo_def);
    const s = out.written();
    try testing.expect(std.mem.indexOf(u8, s, "\"text\"") != null);
    try testing.expect(std.mem.indexOf(u8, s, "\"required\"") != null);
}

test "store_secret scrubs the value and keeps the name" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [128]u8 = undefined;
    var db = try Db.open(try tmpPath(&tmp, &buf));
    defer db.close();
    try db.migrate();
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();

    var ins = try db.prepare("INSERT INTO messages(role, content, created) VALUES ('user', ?, 1)");
    defer ins.finalize();
    try ins.bind(1, "store sk-secret-value");
    _ = try ins.step();

    var ctx = ctxOf(&db, &threaded);
    const out = try call(&ctx, &builtins, "store_secret", "{\"name\":\"weather_api_key\",\"value\":\"sk-secret-value\",\"host\":\"api.weather.com\"}");
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "weather_api_key") != null);

    var q = try db.prepare("SELECT content FROM messages");
    defer q.finalize();
    try testing.expect(try q.step());
    try testing.expect(std.mem.indexOf(u8, q.text(0), "sk-secret-value") == null);

    const list = try secrets.names(&db, testing.allocator);
    defer secrets.freeNames(testing.allocator, list);
    try testing.expectEqual(@as(usize, 1), list.len);
    try testing.expectEqualStrings("weather_api_key", list[0]);
}

test "a read-only caller gets no mutating tool, and delegation is never handed out" {
    const list = try subset(testing.allocator, &builtins, true, null);
    defer testing.allocator.free(list);
    for (list) |t| try testing.expect(!t.mutates and !t.primary_only);
    try testing.expect(find(list, "recall") != null);
    try testing.expect(find(list, "remember") == null);
    try testing.expect(find(list, "save_skill") == null);
    try testing.expect(find(list, "notify_owner") != null);
}

test "an allowlist narrows to exactly the named tools" {
    const list = try subset(testing.allocator, &builtins, false, "fetch_url remember");
    defer testing.allocator.free(list);
    try testing.expectEqual(@as(usize, 2), list.len);
    try testing.expect(find(list, "fetch_url") != null);
    try testing.expect(find(list, "remember") != null);
}

test "a gated tool is invisible to the model and reachable only once approved" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [128]u8 = undefined;
    var db = try Db.open(try tmpPath(&tmp, &buf));
    defer db.close();
    try db.migrate();
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();

    try testing.expect(find(&builtins, "enable_routine") == null);

    try db.exec("INSERT INTO routines(name, next, enabled) VALUES ('nightly', 0, 0)");
    var ctx = ctxOf(&db, &threaded);
    const denied = try call(&ctx, &builtins, "enable_routine", "{\"name\":\"nightly\"}");
    defer testing.allocator.free(denied);
    try testing.expectEqualStrings("unknown tool: enable_routine", denied);

    const out = try callApproved(&ctx, &builtins, "enable_routine", "{\"name\":\"nightly\"}");
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "active") != null);

    var q = try db.prepare("SELECT enabled FROM routines WHERE name = 'nightly'");
    defer q.finalize();
    try testing.expect(try q.step());
    try testing.expectEqual(@as(i64, 1), q.int(0));
}
