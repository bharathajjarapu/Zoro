const std = @import("std");
const agent = @import("root.zig");
const Db = @import("../data/db.zig").Db;
const tasks = @import("../data/tasks.zig");
const tools = @import("../tools/root.zig");
const testing = std.testing;
const testkit = @import("../testing/testkit.zig");
const FakeHttp = testkit.FakeHttp;

const log = std.log.scoped(.worker);

pub const max_live: usize = 3;
pub const max_rounds: usize = 12;

pub const system_prompt =
    \\You are a subagent with one job and no conversation history. Use the tools
    \\you were given, then reply with what you did and what you found. You are
    \\not talking to the owner; the primary agent reads this and speaks for you.
;

const verify_prompt =
    \\You check whether a piece of work met its stated goal. Reply DONE on the
    \\first line if it did, or FAILED followed by one sentence naming what is
    \\missing. Nothing else.
;

/// Marks a task's final allowed attempt.
const follow_mark = "follow-up: ";

const Slot = struct {
    /// Owns its agent, database, and HTTP client.
    proto: agent.Agent,
    thread: ?std.Thread = null,
    done: std.atomic.Value(bool) = .init(false),
    /// Chains task and pool cancellation.
    cancel: agent.Workers = .{},
    task: i64 = 0,
    summary: []u8 = &.{},
    goal: []u8 = &.{},
    allowed: ?[]u8 = null,

    fn release(self: *Slot, gpa: std.mem.Allocator) void {
        gpa.free(self.summary);
        gpa.free(self.goal);
        if (self.allowed) |a| gpa.free(a);
        self.summary = &.{};
        self.goal = &.{};
        self.allowed = null;
    }
};

pub const Pool = struct {
    gpa: std.mem.Allocator,
    /// The caller's connection, used only from the caller's thread.
    db: *Db,
    state: agent.Workers = .{},
    slots: [max_live]Slot,
    /// Root row for this process's task tree.
    root_id: i64 = 0,

    pub fn init(gpa: std.mem.Allocator, db: *Db, protos: [max_live]agent.Agent) Pool {
        var p: Pool = .{ .gpa = gpa, .db = db, .slots = undefined };
        for (&p.slots, protos) |*slot, proto| slot.* = .{ .proto = proto };
        return p;
    }

    /// Cancels and joins every worker.
    pub fn deinit(self: *Pool) void {
        self.state.stop.store(true, .release);
        self.join();
        self.* = undefined;
    }

    pub fn join(self: *Pool) void {
        for (&self.slots) |*slot| {
            if (slot.thread) |t| t.join();
            slot.thread = null;
            slot.release(self.gpa);
        }
    }

    pub fn live(self: *Pool) usize {
        return self.state.count();
    }

    pub fn cancel(self: *Pool, id: i64) bool {
        for (&self.slots) |*slot| {
            if (slot.thread == null or slot.task != id) continue;
            slot.cancel.stop.store(true, .release);
            return true;
        }
        return false;
    }

    /// Queues work and starts it when a slot is free.
    pub fn spawn(self: *Pool, summary: []const u8, goal: []const u8, allowed: ?[]const u8, now: i64) !i64 {
        const parent = try self.rootTask(now);
        try self.pump(now);
        const id = try tasks.create(self.db, summary, goal, now, parent, 0);
        self.start(id, summary, goal, allowed) catch |err| switch (err) {
            error.Busy => {},
            else => return err,
        };
        return id;
    }

    /// Starts queued work in free slots.
    pub fn pump(self: *Pool, now: i64) !void {
        if (self.root_id == 0) return;
        var q = try self.db.prepare(
            \\SELECT id, summary, goal FROM tasks
            \\WHERE parent = ? AND status = 'queued' AND (due IS NULL OR due <= ?)
            \\ORDER BY prio DESC, id
        );
        defer q.finalize();
        try q.bind(1, self.root_id);
        try q.bind(2, now);
        while (try q.step()) {
            self.start(q.int(0), q.text(1), q.text(2), null) catch |err| switch (err) {
                error.Busy => return,
                else => return err,
            };
        }
    }

    fn rootTask(self: *Pool, now: i64) !i64 {
        if (self.root_id != 0) return self.root_id;
        self.root_id = try tasks.create(self.db, "delegated work", "Subagent runs spawned by the primary.", now, null, 0);
        return self.root_id;
    }

    /// The primary thread alone updates slots.
    fn start(self: *Pool, id: i64, summary: []const u8, goal: []const u8, allowed: ?[]const u8) !void {
        const i = try self.freeSlot();
        // Clear cancellation after the stopped batch exits.
        if (self.state.count() == 0) self.state.stop.store(false, .release);
        const slot = &self.slots[i];
        slot.summary = try self.gpa.dupe(u8, summary);
        errdefer slot.release(self.gpa);
        slot.goal = try self.gpa.dupe(u8, goal);
        slot.allowed = if (allowed) |a| try self.gpa.dupe(u8, a) else null;
        slot.task = id;
        slot.done.store(false, .release);
        slot.cancel.stop.store(false, .release);
        // Pool state has a stable address only after initialization.
        slot.cancel.parent = &self.state;

        try tasks.setStatus(self.db, id, .running);
        _ = self.state.live.fetchAdd(1, .release);
        slot.thread = std.Thread.spawn(.{}, work, .{ self, i }) catch |err| {
            _ = self.state.live.fetchSub(1, .release);
            return err;
        };
    }

    /// Joins a finished thread before reuse.
    fn freeSlot(self: *Pool) !usize {
        for (&self.slots, 0..) |*slot, i| {
            if (slot.thread == null) return i;
            if (!slot.done.load(.acquire)) continue;
            slot.thread.?.join();
            slot.thread = null;
            slot.release(self.gpa);
            return i;
        }
        return error.Busy;
    }
};

fn work(self: *Pool, i: usize) void {
    const slot = &self.slots[i];
    defer {
        _ = self.state.live.fetchSub(1, .release);
        slot.done.store(true, .release);
    }
    const db = slot.proto.db;
    const now = std.Io.Timestamp.now(slot.proto.io, .real).toSeconds();

    // Empty allowlists keep subagents read-only and prevent nested delegation.
    const list = tools.subset(self.gpa, slot.proto.tools, slot.allowed == null, slot.allowed) catch |err| {
        return giveUp(db, slot.task, @errorName(err));
    };
    defer self.gpa.free(list);

    // Never retry work that may have caused an external action.
    const kind: tasks.Kind = if (consequential(slot.goal)) .mutating else .transient;

    const reply = slot.proto.isolated(slot.goal, .{
        .tools = list,
        .rounds = max_rounds,
        .system = system_prompt,
        .cancel = &slot.cancel,
    }) catch |err| {
        if (err == error.Cancelled) return markCancelled(db, slot.task);
        tasks.fail(db, slot.task, @errorName(err), kind, now) catch
            giveUp(db, slot.task, @errorName(err));
        return;
    };
    defer self.gpa.free(reply);

    // Verification failure must still leave a terminal task state.
    finish(self, slot, reply, now) catch |err| {
        if (err == error.Cancelled) return markCancelled(db, slot.task);
        log.err("{s}: {t}", .{ slot.summary, err });
        giveUp(db, slot.task, @errorName(err));
    };
}

/// Checks consequential work before reporting success.
fn finish(self: *Pool, slot: *Slot, reply: []const u8, now: i64) !void {
    const db = slot.proto.db;
    if (!consequential(slot.goal)) return store(self.gpa, db, slot.task, .done, "unverified (bounded research)", reply);

    const verdict = try check(self, slot, reply);
    defer self.gpa.free(verdict);
    const trimmed = std.mem.trim(u8, verdict, &std.ascii.whitespace);
    if (std.ascii.startsWithIgnoreCase(trimmed, "DONE")) {
        return store(self.gpa, db, slot.task, .done, "verified", reply);
    }
    try store(self.gpa, db, slot.task, .failed, trimmed, reply);
    try followUp(self, slot, trimmed, now);
}

/// ponytail: checker trusts reports; add evidence when wrong answers matter.
fn check(self: *Pool, slot: *Slot, reply: []const u8) ![]u8 {
    const question = try std.fmt.allocPrint(self.gpa, "goal:\n{s}\n\nreported result:\n{s}", .{ slot.goal, reply });
    defer self.gpa.free(question);
    return slot.proto.isolated(question, .{
        .tools = &.{},
        .rounds = 1,
        .system = verify_prompt,
        .cancel = &slot.cancel,
    });
}

/// Allows one follow-up, never a retry chain.
fn followUp(self: *Pool, slot: *Slot, why: []const u8, now: i64) !void {
    if (std.mem.startsWith(u8, slot.summary, follow_mark)) return;
    const summary = try std.fmt.allocPrint(self.gpa, "{s}{s}", .{ follow_mark, slot.summary });
    defer self.gpa.free(summary);
    const goal = try std.fmt.allocPrint(self.gpa, "The previous attempt did not meet the goal: {s}\n\nOriginal goal:\n{s}", .{ why, slot.goal });
    defer self.gpa.free(goal);
    _ = try tasks.create(slot.proto.db, summary, goal, now, self.root_id, 1);
}

/// Detects goals with external consequences.
fn consequential(goal: []const u8) bool {
    const acts = [_][]const u8{
        "send",   "email",  "post",     "message", "reply",  "buy",
        "pay",    "order",  "book",     "delete",  "remove", "create",
        "update", "cancel", "transfer", "publish", "deploy", "install",
        "commit", "upload", "schedule", "routine",
    };
    for (acts) |w| if (hasWord(goal, w)) return true;
    return false;
}

fn hasWord(text: []const u8, word: []const u8) bool {
    var at: usize = 0;
    while (std.ascii.indexOfIgnoreCasePos(text, at, word)) |i| {
        at = i + 1;
        const before_ok = i == 0 or !std.ascii.isAlphanumeric(text[i - 1]);
        const end = i + word.len;
        // Allows the inflections a goal is actually written in: sends, sending, emailed.
        const after_ok = end == text.len or !std.ascii.isAlphanumeric(text[end]);
        if (before_ok and (after_ok or trailing(text[end..]))) return true;
    }
    return false;
}

fn trailing(rest: []const u8) bool {
    for ([_][]const u8{ "s", "ed", "ing", "es" }) |suffix| {
        if (!std.ascii.startsWithIgnoreCase(rest, suffix)) continue;
        const end = rest[suffix.len..];
        if (end.len == 0 or !std.ascii.isAlphanumeric(end[0])) return true;
    }
    return false;
}

fn store(gpa: std.mem.Allocator, db: *Db, id: i64, status: tasks.Status, note: []const u8, reply: []const u8) !void {
    const text = try std.fmt.allocPrint(gpa, "{s}\n\n{s}", .{ note, reply });
    defer gpa.free(text);
    try tasks.setStatus(db, id, status);
    try setResult(db, id, text);
}

fn markCancelled(db: *Db, id: i64) void {
    tasks.setStatus(db, id, .cancelled) catch {};
    setResult(db, id, "cancelled by the owner") catch {};
}

fn giveUp(db: *Db, id: i64, why: []const u8) void {
    tasks.setStatus(db, id, .failed) catch {};
    setResult(db, id, why) catch {};
}

fn setResult(db: *Db, id: i64, text: []const u8) !void {
    var q = try db.prepare("UPDATE tasks SET result = ? WHERE id = ?");
    defer q.finalize();
    try q.bind(1, text);
    try q.bind(2, id);
    _ = try q.step();
}

const delegate_params = [_]tools.Param{
    .{ .name = "summary", .description = "short task name" },
    .{ .name = "goal", .description = "success criterion" },
    .{ .name = "tools", .description = "allowed tool names", .required = false },
};

pub const delegate: tools.Def = .{
    .name = "delegate",
    .description = "Delegate independent work.",
    .params = &delegate_params,
    .mutates = true,
    .primary_only = true,
    .run = runDelegate,
};

pub const check_tasks: tools.Def = .{
    .name = "check_tasks",
    .description = "Check delegated work.",
    .params = &.{},
    // Sibling goals belong only in the primary context.
    .primary_only = true,
    .run = runCheck,
};

fn runDelegate(ctx: *tools.Ctx, args: []const u8) anyerror![]u8 {
    const Args = struct { summary: []const u8, goal: []const u8, tools: ?[]const u8 = null };
    const parsed = try std.json.parseFromSlice(Args, ctx.gpa, args, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    const pool = ctx.pool orelse return ctx.gpa.dupe(u8, "delegation is not available; do it yourself");
    const now = std.Io.Timestamp.now(ctx.io, .real).toSeconds();
    const id = try pool.spawn(parsed.value.summary, parsed.value.goal, parsed.value.tools, now);
    return std.fmt.allocPrint(ctx.gpa, "task #{d} filed: {s}. Three run at once; check_tasks shows where it got to.", .{ id, parsed.value.summary });
}

const cancel_params = [_]tools.Param{.{ .name = "id", .description = "task id" }};

pub const cancel_task: tools.Def = .{
    .name = "cancel_task",
    .description = "Cancel one delegated task.",
    .params = &cancel_params,
    .mutates = true,
    .primary_only = true,
    .run = runCancel,
};

fn runCancel(ctx: *tools.Ctx, args: []const u8) anyerror![]u8 {
    const Args = struct { id: []const u8 };
    const parsed = try std.json.parseFromSlice(Args, ctx.gpa, args, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    const id = std.fmt.parseInt(i64, std.mem.trim(u8, parsed.value.id, " #"), 10) catch
        return ctx.gpa.dupe(u8, "that is not a task number");
    const pool = ctx.pool orelse return ctx.gpa.dupe(u8, "nothing is delegated");
    if (!pool.cancel(id)) return std.fmt.allocPrint(ctx.gpa, "task #{d} is not running", .{id});
    return std.fmt.allocPrint(ctx.gpa, "task #{d} is stopping", .{id});
}

fn runCheck(ctx: *tools.Ctx, _: []const u8) anyerror![]u8 {
    if (ctx.pool) |pool| try pool.pump(std.Io.Timestamp.now(ctx.io, .real).toSeconds());
    const items = try tasks.list(ctx.db, ctx.gpa);
    defer tasks.freeTasks(ctx.gpa, items);
    return tasks.formatList(ctx.gpa, items);
}

/// One fake HTTP client per worker slot.
const said_done = "{\"choices\":[{\"message\":{\"content\":\"DONE\"}}]}";
const said_failed = "{\"choices\":[{\"message\":{\"content\":\"FAILED nothing was actually sent\"}}]}";
const said_ok = "{\"choices\":[{\"message\":{\"content\":\"finished\"}}]}";

/// Mirrors production worker ownership in tests.
const Rig = struct {
    tmp: testing.TmpDir,
    threaded: std.Io.Threaded,
    path: [128]u8 = undefined,
    main_db: Db = undefined,
    dbs: [max_live]Db = undefined,
    fakes: [max_live]FakeHttp = undefined,
    pool: Pool = undefined,
    owner_fake: FakeHttp = .{ .bodies = &.{} },
    primary: agent.Agent = undefined,

    fn init(self: *Rig, bodies: [max_live][]const []const u8) !void {
        self.tmp = testing.tmpDir(.{});
        self.threaded = .init(testing.allocator, .{});
        const path = try testkit.tmpPath(&self.tmp, &self.path, "zoro.db");
        self.main_db = try Db.open(path);
        try self.main_db.initSchema();
        self.owner_fake = .{ .bodies = &.{} };

        var protos: [max_live]agent.Agent = undefined;
        for (&self.dbs, &self.fakes, &protos, bodies) |*db, *fake, *proto, list| {
            db.* = try Db.open(path);
            fake.* = .{ .bodies = list };
            proto.* = .{
                .gpa = testing.allocator,
                .io = self.threaded.io(),
                .db = db,
                .http = fake.http(),
                .api_key = .init("k"),
                .base_url = "https://api.openai.com/v1",
                .model = "m",
                .tools = &tools.builtins,
            };
        }
        self.pool = Pool.init(testing.allocator, &self.main_db, protos);
        self.primary = .{
            .gpa = testing.allocator,
            .io = self.threaded.io(),
            .db = &self.main_db,
            .http = self.owner_fake.http(),
            .api_key = .init("k"),
            .base_url = "https://api.openai.com/v1",
            .model = "m",
            .tools = &tools.builtins,
            .workers = &self.pool.state,
            .pool = &self.pool,
        };
    }

    fn deinit(self: *Rig) void {
        self.pool.deinit();
        for (&self.dbs) |*db| db.close();
        self.main_db.close();
        self.threaded.deinit();
        self.tmp.cleanup();
    }

    fn statusOf(self: *Rig, id: i64) ![]const u8 {
        var t = (try tasks.get(&self.main_db, testing.allocator, id)) orelse return error.NoTask;
        defer t.deinit(testing.allocator);
        return @tagName(t.status);
    }
};

test "a subagent's context excludes the parent's messages" {
    var rig: Rig = undefined;
    try rig.init(.{ &.{said_ok}, &.{}, &.{} });
    defer rig.deinit();

    try rig.main_db.exec("INSERT INTO messages(role, content, created) VALUES ('user', 'my bank pin is hunter2', 1)");

    const id = try rig.pool.spawn("research", "Look up the tide table for Chennai.", null, 100);
    rig.pool.join();

    const sent = rig.fakes[0].sent();
    try testing.expect(std.mem.indexOf(u8, sent, "hunter2") == null);
    try testing.expect(std.mem.indexOf(u8, sent, "tide table") != null);
    try testing.expectEqualStrings("done", try rig.statusOf(id));
}

test "at most three subagents run at once; the fourth waits its turn" {
    var rig: Rig = undefined;
    try rig.init(.{ &.{said_ok}, &.{said_ok}, &.{said_ok} });
    defer rig.deinit();

    var held: std.atomic.Value(bool) = .init(true);
    for (&rig.fakes) |*f| f.hold = &held;

    for (0..3) |i| {
        var buf: [16]u8 = undefined;
        _ = try rig.pool.spawn(try std.fmt.bufPrint(&buf, "job{d}", .{i}), "Summarize the news.", null, 100);
    }
    try testing.expectEqual(max_live, rig.pool.live());

    const fourth = try rig.pool.spawn("job3", "Summarize the news.", null, 100);
    try testing.expectEqualStrings("queued", try rig.statusOf(fourth));

    held.store(false, .release);
    rig.pool.join();
    try testing.expectEqual(@as(usize, 0), rig.pool.live());

    for (&rig.fakes) |*f| f.i = 0;
    try rig.pool.pump(100);
    rig.pool.join();
    try testing.expectEqualStrings("done", try rig.statusOf(fourth));
}

test "a subagent is handed no way to delegate and no tool that reaches Telegram" {
    const list = try tools.subset(testing.allocator, &tools.builtins, false, null);
    defer testing.allocator.free(list);
    for (list) |t| {
        try testing.expect(!std.mem.eql(u8, t.name, "delegate"));
        try testing.expect(!std.mem.eql(u8, t.name, "notify_owner"));
        try testing.expect(!std.mem.eql(u8, t.name, "attach_file"));
        try testing.expect(!std.mem.eql(u8, t.name, "send_sticker"));
        try testing.expect(std.mem.indexOf(u8, t.name, "telegram") == null);
    }
}

test "a research subagent given only web tools cannot touch skills or memory" {
    var rig: Rig = undefined;
    try rig.init(.{ &.{said_ok}, &.{}, &.{} });
    defer rig.deinit();

    _ = try rig.pool.spawn("research", "Find the tide table.", "fetch_url search", 100);
    rig.pool.join();

    const sent = rig.fakes[0].sent();
    try testing.expect(std.mem.indexOf(u8, sent, "\"fetch_url\"") != null);
    try testing.expect(std.mem.indexOf(u8, sent, "\"save_skill\"") == null);
    try testing.expect(std.mem.indexOf(u8, sent, "\"remember\"") == null);
    try testing.expect(std.mem.indexOf(u8, sent, "\"attach_file\"") == null);
}

const called_recall = "{\"choices\":[{\"message\":{\"content\":\"\",\"tool_calls\":[{\"id\":\"1\",\"type\":\"function\",\"function\":{\"name\":\"recall\",\"arguments\":\"{\\\"query\\\":\\\"news\\\"}\"}}]}}]}";

test "stop halts a subagent between rounds and the task lands cancelled" {
    var rig: Rig = undefined;
    try rig.init(.{ &.{ called_recall, said_ok }, &.{}, &.{} });
    defer rig.deinit();
    rig.fakes[0].trip = &rig.pool.state;

    const id = try rig.pool.spawn("slow", "Summarize the news.", null, 100);
    rig.pool.join();

    try testing.expectEqual(@as(usize, 1), rig.fakes[0].i); // it never asked again
    try testing.expectEqualStrings("cancelled", try rig.statusOf(id));

    var t = (try tasks.get(&rig.main_db, testing.allocator, id)).?;
    defer t.deinit(testing.allocator);
    try testing.expectEqualStrings("cancelled by the owner", t.result.?);
}

test "bounded research is taken at its word; a consequential goal is checked" {
    var rig: Rig = undefined;
    try rig.init(.{ &.{said_ok}, &.{ said_ok, said_done }, &.{} });
    defer rig.deinit();

    var held: std.atomic.Value(bool) = .init(true);
    rig.fakes[0].hold = &held;
    rig.fakes[1].hold = &held;

    _ = try rig.pool.spawn("research", "Summarize the tide table for Chennai.", null, 100);
    const acted = try rig.pool.spawn("mail", "Send the summary to the landlord.", null, 100);
    held.store(false, .release);
    rig.pool.join();

    try testing.expectEqual(@as(usize, 1), rig.fakes[0].i); // no second call: not verified
    try testing.expectEqual(@as(usize, 2), rig.fakes[1].i); // work, then the check
    try testing.expectEqualStrings("done", try rig.statusOf(acted));

    var t = (try tasks.get(&rig.main_db, testing.allocator, acted)).?;
    defer t.deinit(testing.allocator);
    try testing.expect(std.mem.startsWith(u8, t.result.?, "verified"));
}

test "a subagent that fails its criterion spawns a follow-up, not a false success" {
    var rig: Rig = undefined;
    try rig.init(.{ &.{ said_ok, said_failed }, &.{}, &.{} });
    defer rig.deinit();

    const id = try rig.pool.spawn("mail", "Send the summary to the landlord.", null, 100);
    rig.pool.join();

    try testing.expectEqualStrings("failed", try rig.statusOf(id));

    const items = try tasks.list(&rig.main_db, testing.allocator);
    defer tasks.freeTasks(testing.allocator, items);
    var follow: ?i64 = null;
    for (items) |t| {
        if (std.mem.startsWith(u8, t.summary, follow_mark)) follow = t.id;
    }
    try testing.expect(follow != null);

    var f = (try tasks.get(&rig.main_db, testing.allocator, follow.?)).?;
    defer f.deinit(testing.allocator);
    try testing.expectEqual(rig.pool.root_id, f.parent.?);
    try testing.expect(std.mem.indexOf(u8, f.goal, "nothing was actually sent") != null);
}

test "consequential goals are told apart from bounded research" {
    try testing.expect(consequential("Send the summary to the landlord."));
    try testing.expect(consequential("Emailed the report already; confirm it."));
    try testing.expect(consequential("Book a table for four."));
    try testing.expect(consequential("Set up a routine for the morning brief."));
    try testing.expect(!consequential("Summarize the tide table for Chennai."));
    try testing.expect(!consequential("Compare the three phone plans."));
    try testing.expect(!consequential("Find the sender of that newsletter."));
}

test "the owner is answered while subagents keep running, and stop cancels them" {
    var rig: Rig = undefined;
    try rig.init(.{ &.{said_ok}, &.{said_ok}, &.{said_ok} });
    defer rig.deinit();
    rig.owner_fake.bodies = &.{said_ok};

    var held: std.atomic.Value(bool) = .init(true);
    for (&rig.fakes) |*f| f.hold = &held;
    for (0..3) |i| {
        var buf: [16]u8 = undefined;
        _ = try rig.pool.spawn(try std.fmt.bufPrint(&buf, "job{d}", .{i}), "Summarize the news.", null, 100);
    }

    const answer = try rig.primary.turn("what is the weather");
    defer testing.allocator.free(answer);
    try testing.expectEqualStrings("finished", answer);
    try testing.expectEqual(max_live, rig.pool.live());

    const stopped = try rig.primary.turn("stop");
    defer testing.allocator.free(stopped);
    try testing.expect(std.mem.indexOf(u8, stopped, "Stopping 3") != null);
    try testing.expectEqual(@as(usize, 1), rig.owner_fake.i); // "stop" spent no model call

    held.store(false, .release);
    rig.pool.join();
    try testing.expectEqual(@as(usize, 0), rig.pool.live());
}

test "one task is called off without touching the other two" {
    var rig: Rig = undefined;
    try rig.init(.{ &.{ called_recall, said_ok }, &.{said_ok}, &.{said_ok} });
    defer rig.deinit();

    var held: std.atomic.Value(bool) = .init(true);
    for (&rig.fakes) |*f| f.hold = &held;

    const doomed = try rig.pool.spawn("job0", "Summarize the news.", null, 100);
    const spared = try rig.pool.spawn("job1", "Summarize the news.", null, 100);

    try testing.expect(rig.pool.cancel(doomed));
    try testing.expect(!rig.pool.cancel(9999));
    held.store(false, .release);
    rig.pool.join();

    try testing.expectEqualStrings("cancelled", try rig.statusOf(doomed));
    try testing.expectEqualStrings("done", try rig.statusOf(spared));
}

test "a stop does not cancel every delegation that follows it" {
    var rig: Rig = undefined;
    try rig.init(.{ &.{ called_recall, said_ok }, &.{said_ok}, &.{said_ok} });
    defer rig.deinit();
    rig.owner_fake.bodies = &.{};

    var held: std.atomic.Value(bool) = .init(true);
    rig.fakes[0].hold = &held;
    const doomed = try rig.pool.spawn("job0", "Summarize the news.", null, 100);

    const stopped = try rig.primary.turn("stop");
    defer testing.allocator.free(stopped);
    try testing.expect(std.mem.indexOf(u8, stopped, "Stopping 1") != null);
    held.store(false, .release);
    rig.pool.join();
    try testing.expectEqualStrings("cancelled", try rig.statusOf(doomed));

    const after = try rig.pool.spawn("job1", "Summarize the news.", null, 100);
    rig.pool.join();
    try testing.expectEqualStrings("done", try rig.statusOf(after));
}

test "a subagent with no allowlist is a researcher, not a free hand" {
    var rig: Rig = undefined;
    try rig.init(.{ &.{said_ok}, &.{}, &.{} });
    defer rig.deinit();

    _ = try rig.pool.spawn("research", "Summarize the tide table.", null, 100);
    rig.pool.join();

    const sent = rig.fakes[0].sent();
    try testing.expect(std.mem.indexOf(u8, sent, "\"recall\"") != null);
    try testing.expect(std.mem.indexOf(u8, sent, "\"save_skill\"") == null);
    try testing.expect(std.mem.indexOf(u8, sent, "\"store_secret\"") == null);
    try testing.expect(std.mem.indexOf(u8, sent, "\"remember\"") == null);
    try testing.expect(std.mem.indexOf(u8, sent, "\"check_tasks\"") == null);
}

test "a verification that is cancelled leaves the task cancelled, not running" {
    var rig: Rig = undefined;
    try rig.init(.{ &.{said_ok}, &.{}, &.{} });
    defer rig.deinit();
    rig.fakes[0].trip = &rig.pool.state;

    const id = try rig.pool.spawn("mail", "Send the summary to the landlord.", null, 100);
    rig.pool.join();
    try testing.expectEqualStrings("cancelled", try rig.statusOf(id));
}

test "a subagent that could act is never retried; research is re-queued with backoff" {
    var rig: Rig = undefined;
    try rig.init(.{ &.{}, &.{}, &.{} });
    defer rig.deinit();

    var held: std.atomic.Value(bool) = .init(true);
    rig.fakes[0].hold = &held;
    rig.fakes[1].hold = &held;
    const acted = try rig.pool.spawn("mail", "Send the summary to the landlord.", null, 100);
    const research = try rig.pool.spawn("read", "Summarize the tide table.", null, 100);
    held.store(false, .release);
    rig.pool.join();

    var a = (try tasks.get(&rig.main_db, testing.allocator, acted)).?;
    defer a.deinit(testing.allocator);
    try testing.expectEqual(tasks.Status.failed, a.status);
    try testing.expect(std.mem.indexOf(u8, a.result.?, "do not retry") != null);

    var r = (try tasks.get(&rig.main_db, testing.allocator, research)).?;
    defer r.deinit(testing.allocator);
    try testing.expectEqual(tasks.Status.queued, r.status);
    try testing.expectEqual(@as(i64, 1), r.tries);
    // Real time makes the exact retry deadline nondeterministic.
    try testing.expect(r.due.? > 100);

    try rig.pool.pump(r.due.? - 1);
    try testing.expectEqualStrings("queued", try rig.statusOf(research));
}
