const std = @import("std");
const Db = @import("../data/db.zig").Db;
const config = @import("../app/config.zig");
const web = @import("../net/web.zig");
const testing = std.testing;
const testkit = @import("../testing/testkit.zig");

pub const max_result: usize = 16 * 1024;
const trunc_mark = "\n[truncated]";

pub const Param = struct {
    name: []const u8,
    description: []const u8,
    required: bool = true,
    kind: enum { string, array } = .string,
};

pub const ShellMode = config.ShellMode;

pub const Ctx = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    db: *Db,
    skills_dir: []const u8 = "skills",
    workspace: []const u8 = "workspace",
    web_api: ?web.Api = null,
    fetch: ?web.Get = null,
    tinyfish_key: ?[]const u8 = null,
    limiter: ?*web.Limiter = null,
    pool: ?*worker.Pool = null,
    shell_mode: ShellMode = .ask,
    source_message: ?i64 = null,
    approval_tools: []const Def = &.{},
    approval_out: ?*?i64 = null,
    delivery_out: ?*bool = null,
    cancel: ?*const std.atomic.Value(bool) = null,
    cancel_parent: ?*const std.atomic.Value(bool) = null,

    pub fn cancelled(self: *const Ctx) bool {
        if (self.cancel) |flag| if (flag.load(.acquire)) return true;
        if (self.cancel_parent) |flag| if (flag.load(.acquire)) return true;
        return false;
    }
};

pub fn requireOwnerEvidence(ctx: *Ctx, evidence: []const u8) !void {
    const id = ctx.source_message orelse return error.UntrustedEvidence;
    var statement = try ctx.db.prepare("SELECT owner_text FROM messages WHERE id = ? AND role = 'user'");
    defer statement.finalize();
    try statement.bind(1, id);
    if (!try statement.step() or statement.isNull(0) or evidence.len == 0 or std.mem.indexOf(u8, statement.text(0), evidence) == null)
        return error.UntrustedEvidence;
}

fn requireOwnerReply(ctx: *Ctx, evidence: []const u8) !void {
    const id = ctx.source_message orelse return error.UntrustedEvidence;
    var statement = try ctx.db.prepare("SELECT owner_text FROM messages WHERE id = ? AND role = 'user'");
    defer statement.finalize();
    try statement.bind(1, id);
    if (!try statement.step() or statement.isNull(0) or !std.mem.eql(
        u8,
        std.mem.trim(u8, statement.text(0), &std.ascii.whitespace),
        std.mem.trim(u8, evidence, &std.ascii.whitespace),
    )) return error.UntrustedEvidence;
}

pub fn sensitiveMemory(text: []const u8) bool {
    const words = [_][]const u8{ "password", "passcode", "pin", "secret", "token", "credential", "cvv", "ssn" };
    const phrases = [_][]const u8{ "api key", "private key", "credit card", "card number", "social security", "door code", "seed phrase", "recovery phrase", "one-time password", "verification code" };
    for (words) |word| if (containsWord(text, word)) return true;
    for (phrases) |phrase| if (std.ascii.indexOfIgnoreCase(text, phrase) != null) return true;
    return false;
}

fn containsWord(text: []const u8, word: []const u8) bool {
    var at: usize = 0;
    while (std.ascii.indexOfIgnoreCasePos(text, at, word)) |index| {
        const end = index + word.len;
        if ((index == 0 or !std.ascii.isAlphanumeric(text[index - 1])) and
            (end == text.len or !std.ascii.isAlphanumeric(text[end]))) return true;
        at = index + 1;
    }
    return false;
}

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

/// Returns allowed non-primary tools. Caller frees.
pub fn subset(gpa: std.mem.Allocator, all: []const Def, read_only: bool, names: ?[]const u8) ![]Def {
    var out: std.ArrayList(Def) = .empty;
    errdefer out.deinit(gpa);
    for (all) |tool| {
        if (tool.primary_only) continue;
        if (read_only and tool.mutates) continue;
        if (names) |list| if (!listed(list, tool.name)) continue;
        try out.append(gpa, tool);
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

const secrets = @import("../data/secrets.zig");
const secret_params = [_]Param{
    .{ .name = "name", .description = "secret name" },
    .{ .name = "value", .description = "secret value" },
    .{ .name = "host", .description = "allowed HTTPS host" },
};

pub const store_secret: Def = .{
    .name = "store_secret",
    .description = "Store a host-bound secret.",
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

pub const memory = @import("memory.zig");
const skills = @import("../automation/skills.zig");
const web_tools = @import("web.zig");
const tasks = @import("../data/tasks.zig");
const outbox = @import("../data/outbox.zig");
const routine = @import("routine.zig");
const worker = @import("../agent/worker.zig");
const workspace = @import("workspace.zig");
const shell = @import("shell.zig");
const learning = @import("learning.zig");
const document = @import("document.zig");

const ask_params = [_]Param{
    .{ .name = "tool", .description = "tool name" },
    .{ .name = "args", .description = "exact JSON arguments" },
    .{ .name = "reason", .description = "approval reason" },
    .{ .name = "target", .description = "affected target", .required = false },
};

pub const request_permission: Def = .{
    .name = "request_permission",
    .description = "Ask the owner directly for permission to perform one action.",
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
    if (ctx.approval_out) |out| out.* = id;
    return try std.fmt.allocPrint(ctx.gpa, "May I {s}? (#{d}: {s})", .{ parsed.value.reason, id, parsed.value.tool });
}

const resolve_params = [_]Param{
    .{ .name = "id", .description = "permission id from the question" },
    .{ .name = "decision", .description = "approve or deny" },
    .{ .name = "evidence", .description = "exact current owner words showing the decision" },
};

pub const resolve_permission: Def = .{
    .name = "resolve_permission",
    .description = "Resolve one pending permission from the current owner's clear reply.",
    .params = &resolve_params,
    .mutates = true,
    .primary_only = true,
    .run = runResolve,
};

fn runResolve(ctx: *Ctx, args: []const u8) anyerror![]u8 {
    const Args = struct { id: []const u8, decision: []const u8, evidence: []const u8 };
    const parsed = try std.json.parseFromSlice(Args, ctx.gpa, args, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    try requireOwnerReply(ctx, parsed.value.evidence);
    const id = try std.fmt.parseInt(i64, parsed.value.id, 10);
    const now = std.Io.Timestamp.now(ctx.io, .real).toSeconds();
    var pending = (try tasks.pending(ctx.db, ctx.gpa, id)) orelse return error.NotPending;
    defer pending.deinit(ctx.gpa);
    if (std.mem.eql(u8, parsed.value.decision, "deny")) {
        if (!try tasks.transitionApproval(ctx.db, id, "pending", "denied")) return error.NotPending;
        return std.fmt.allocPrint(ctx.gpa, "cancelled {s}", .{pending.tool});
    }
    if (!std.mem.eql(u8, parsed.value.decision, "approve")) return error.InvalidDecision;
    if (pending.expires <= now) {
        _ = try tasks.transitionApproval(ctx.db, id, "pending", "expired");
        return error.Expired;
    }
    try tasks.authorize(ctx.db, id, pending.tool, pending.args, now);
    const raw = callApproved(ctx, ctx.approval_tools, pending.tool, pending.args) catch |err| {
        _ = try tasks.transitionApproval(ctx.db, id, "executing", "uncertain");
        return err;
    };
    errdefer ctx.gpa.free(raw);
    if (!try tasks.transitionApproval(ctx.db, id, "executing", "approved")) return error.ApprovalStateLost;
    return raw;
}

pub const builtins = [_]Def{
    memory.remember,
    memory.recall,
    memory.forget,
    memory.remember_alias,
    skills.load_skill,
    skills.save_skill,
    web_tools.fetch_url,
    web_tools.search,
    web_tools.watch_url,
    workspace.read_file,
    workspace.write_file,
    workspace.edit_file,
    workspace.download_file,
    workspace.delete_file,
    document.inspect_file,
    shell.run,
    learning.character_inspect,
    learning.character_propose,
    learning.learning_inspect,
    learning.learning_propose,
    store_secret,
    request_permission,
    resolve_permission,
    outbox.notify_owner,
    outbox.attach_file,
    outbox.send_sticker,
    worker.delegate,
    worker.check_tasks,
    worker.cancel_task,
};

/// Approval-only actions hidden from the model.
pub const gated = [_]Def{
    routine.enable_routine,
    routine.run_routine,
    shell.run_approved,
    learning.learning_apply,
    learning.learning_reject,
    learning.learning_quarantine,
    learning.learning_rollback,
    learning.learning_set_mode,
    learning.apply_identity,
    learning.rollback_identity,
    learning.reset_identity,
};

/// Runs an owner-approved action.
pub fn callApproved(ctx: *Ctx, own: []const Def, name: []const u8, args: []const u8) ![]u8 {
    const def = find(&gated, name) orelse find(own, name) orelse return error.UnknownTool;
    try validate(ctx.gpa, def, args);
    return bound(ctx.gpa, try def.run(ctx, args));
}

/// Runs a tool and returns bounded output or an error string.
pub fn call(ctx: *Ctx, tools: []const Def, name: []const u8, args: []const u8) ![]u8 {
    const def = find(tools, name) orelse
        return std.fmt.allocPrint(ctx.gpa, "unknown tool: {s}", .{name});
    validate(ctx.gpa, def, args) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return std.fmt.allocPrint(ctx.gpa, "invalid arguments: {s}", .{@errorName(err)}),
    };
    const raw = def.run(ctx, args) catch |err| switch (err) {
        error.Cancelled, error.OutOfMemory => return err,
        else => return std.fmt.allocPrint(ctx.gpa, "tool error: {s}", .{@errorName(err)}),
    };
    return bound(ctx.gpa, raw);
}

pub fn writeSchema(writer: *std.Io.Writer, def: Def) !void {
    try writer.writeAll("{\"type\":\"object\",\"properties\":{");
    for (def.params, 0..) |param, index| {
        if (index != 0) try writer.writeByte(',');
        try std.json.Stringify.encodeJsonString(param.name, .{}, writer);
        try writer.writeAll(":{\"type\":\"");
        try writer.writeAll(@tagName(param.kind));
        try writer.writeAll("\",\"description\":");
        try std.json.Stringify.encodeJsonString(param.description, .{}, writer);
        if (param.kind == .array) try writer.writeAll(",\"items\":{\"type\":\"string\"}");
        try writer.writeByte('}');
    }
    try writer.writeAll("},\"required\":[");
    var first = true;
    for (def.params) |param| {
        if (!param.required) continue;
        if (!first) try writer.writeByte(',');
        first = false;
        try std.json.Stringify.encodeJsonString(param.name, .{}, writer);
    }
    try writer.writeAll("]}");
}

fn find(tools: []const Def, name: []const u8) ?Def {
    for (tools) |tool| {
        if (std.mem.eql(u8, tool.name, name)) return tool;
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
        .object => |object| object,
        else => return error.InvalidArgs,
    };
    for (def.params) |param| {
        if (param.required and obj.get(param.name) == null) return error.MissingParam;
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

fn echoRun(ctx: *Ctx, args: []const u8) anyerror![]u8 {
    return try ctx.gpa.dupe(u8, args);
}

fn boomRun(_: *Ctx, _: []const u8) anyerror![]u8 {
    return error.Boom;
}

fn bigRun(ctx: *Ctx, _: []const u8) anyerror![]u8 {
    const size = max_result + 100;
    const out = try ctx.gpa.alloc(u8, size);
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
    var db = try Db.open(try testkit.tmpPath(&tmp, &buf, "zoro.db"));
    defer db.close();
    try db.initSchema();
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
    var db = try Db.open(try testkit.tmpPath(&tmp, &buf, "zoro.db"));
    defer db.close();
    try db.initSchema();
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
    var db = try Db.open(try testkit.tmpPath(&tmp, &buf, "zoro.db"));
    defer db.close();
    try db.initSchema();
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
    var db = try Db.open(try testkit.tmpPath(&tmp, &buf, "zoro.db"));
    defer db.close();
    try db.initSchema();
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();

    var ctx = ctxOf(&db, &threaded);
    const out = try call(&ctx, &.{}, "nope", "{}");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("unknown tool: nope", out);
}

test "permission resolution requires the whole current owner reply" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [128]u8 = undefined;
    var db = try Db.open(try testkit.tmpPath(&tmp, &buf, "zoro.db"));
    defer db.close();
    try db.initSchema();
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const now = std.Io.Timestamp.now(threaded.io(), .real).toSeconds();
    _ = try tasks.ask(&db, "echo", "{\"text\":\"x\"}", null, "test", null, now);
    var insert = try db.prepare("INSERT INTO messages(role, content, owner_text, ref, created) VALUES ('user', ?, ?, 1, ?)");
    defer insert.finalize();
    try insert.bind(1, "Not yes");
    try insert.bind(2, "Not yes");
    try insert.bind(3, now);
    _ = try insert.step();

    const own = [_]Def{echo_def};
    var ctx = ctxOf(&db, &threaded);
    ctx.source_message = db.lastId();
    ctx.approval_tools = &own;
    const out = try call(&ctx, &.{resolve_permission}, "resolve_permission", "{\"id\":\"1\",\"decision\":\"approve\",\"evidence\":\"yes\"}");
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "UntrustedEvidence") != null);
    var statement = try db.prepare("SELECT status FROM approvals WHERE id = 1");
    defer statement.finalize();
    try testing.expect(try statement.step());
    try testing.expectEqualStrings("pending", statement.text(0));
}

test "schema lists required parameter names" {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try writeSchema(&out.writer, echo_def);
    const schema = out.written();
    try testing.expect(std.mem.indexOf(u8, schema, "\"text\"") != null);
    try testing.expect(std.mem.indexOf(u8, schema, "\"required\"") != null);
}

test "store_secret scrubs the value and keeps the name" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [128]u8 = undefined;
    var db = try Db.open(try testkit.tmpPath(&tmp, &buf, "zoro.db"));
    defer db.close();
    try db.initSchema();
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

    var statement = try db.prepare("SELECT content FROM messages");
    defer statement.finalize();
    try testing.expect(try statement.step());
    try testing.expect(std.mem.indexOf(u8, statement.text(0), "sk-secret-value") == null);

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const list = try secrets.names(&db, arena.allocator());
    try testing.expectEqual(@as(usize, 1), list.len);
    try testing.expectEqualStrings("weather_api_key", list[0]);
}

test "a read-only caller gets no mutating tool, and delegation is never handed out" {
    const list = try subset(testing.allocator, &builtins, true, null);
    defer testing.allocator.free(list);
    for (list) |tool| try testing.expect(!tool.mutates and !tool.primary_only);
    try testing.expect(find(list, "recall") != null);
    try testing.expect(find(list, "remember") == null);
    try testing.expect(find(list, "save_skill") == null);
    try testing.expect(find(list, "notify_owner") == null);
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
    var db = try Db.open(try testkit.tmpPath(&tmp, &buf, "zoro.db"));
    defer db.close();
    try db.initSchema();
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

    var statement = try db.prepare("SELECT enabled FROM routines WHERE name = 'nightly'");
    defer statement.finalize();
    try testing.expect(try statement.step());
    try testing.expectEqual(@as(i64, 1), statement.int(0));
}
