const std = @import("std");
const Db = @import("../data/db.zig").Db;
const agent = @import("../agent/root.zig");
const skills = @import("skills.zig");
const cron = @import("cron.zig");
const tools = @import("../tools/root.zig");
const tasks = @import("../data/tasks.zig");
const outbox = @import("../data/outbox.zig");
const memory = @import("../data/memory.zig");
const testing = std.testing;
const testkit = @import("../testing/testkit.zig");
const FakeHttp = testkit.FakeHttp;

const log = std.log.scoped(.scheduler);

pub const tick_every: u64 = 30;

/// Runs older than this are missed, not delayed.
pub const missed_after: i64 = 5 * 60;

pub fn tick(assistant: *agent.Agent, now: i64) !void {
    return tickWithCancel(assistant, now, null);
}

fn tickWithCancel(assistant: *agent.Agent, now: i64, cancel: ?*const agent.Workers) !void {
    try sync(assistant.db, assistant.gpa, assistant.io, assistant.skills_dir, now);
    try fire(assistant, now, cancel);
    try compact(assistant, now);
}

/// Failures preserve messages and retry later.
fn compact(assistant: *agent.Agent, now: i64) !void {
    var day_buf: [10]u8 = undefined;
    const day = memory.formatDay(&day_buf, now - 86_400);
    if (try compacted(assistant.db, day)) return;

    memory.compact(assistant.db, assistant.gpa, assistant.io, assistant.diary_dir, day, now, &.{}) catch |err| {
        log.err("compacting {s}: {t}", .{ day, err });
        return;
    };
    try mark(assistant.db, day);
}

/// One high-water mark covers ordered days.
fn compacted(db: *Db, day: []const u8) !bool {
    var statement = try db.prepare("SELECT value FROM kv WHERE key = 'compacted'");
    defer statement.finalize();
    if (!try statement.step()) return false;
    return std.mem.order(u8, statement.text(0), day) != .lt;
}

fn mark(db: *Db, day: []const u8) !void {
    var statement = try db.prepare(
        \\INSERT INTO kv(key, value) VALUES ('compacted', ?)
        \\ON CONFLICT(key) DO UPDATE SET value = excluded.value
    );
    defer statement.finalize();
    try statement.bind(1, day);
    _ = try statement.step();
}

pub fn loop(assistant: *agent.Agent, stop: *const fn () bool) void {
    var cancel: agent.Workers = .{ .shutdown = stop };
    while (!stop()) {
        const now = std.Io.Timestamp.now(assistant.io, .real).toSeconds();
        tickWithCancel(assistant, now, &cancel) catch |err| log.err("{t}", .{err});
        var left = tick_every;
        while (left > 0 and !stop()) : (left -= 1) {
            std.Io.sleep(assistant.io, .fromSeconds(1), .awake) catch return;
        }
    }
}

fn sync(db: *Db, gpa: std.mem.Allocator, io: std.Io, dir: []const u8, now: i64) !void {
    var root = std.Io.Dir.cwd().openDir(io, dir, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer root.close(io);
    var it = root.iterate();
    while (try it.next(io)) |ent| {
        if (ent.kind != .directory) continue;
        var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "{s}/{s}/SKILL.md", .{ dir, ent.name }) catch continue;
        const text = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(64 * 1024)) catch continue;
        defer gpa.free(text);
        const skill = skills.parse(text) catch continue;
        const expr = skill.schedule orelse continue;
        const spec = cron.parse(expr) catch continue;
        const tier = skills.Authority.of(skill.authority);
        if (!try hasRoutine(db, skill.name)) {
            const next = cron.nextRun(spec, now, skill.timezone) catch continue;
            try insertRoutine(db, skill.name, next, tier);
        }
        try gate(db, gpa, skill.name, skill.description, tier, now);
    }
}

fn hasRoutine(db: *Db, name: []const u8) !bool {
    var statement = try db.prepare("SELECT 1 FROM routines WHERE name = ?");
    defer statement.finalize();
    try statement.bind(1, name);
    return try statement.step();
}

/// Mutating routines start disabled.
fn insertRoutine(db: *Db, name: []const u8, next: i64, tier: skills.Authority) !void {
    var statement = try db.prepare(
        \\INSERT INTO routines(name, next, last, status, fails, enabled)
        \\VALUES (?, ?, NULL, NULL, 0, ?)
    );
    defer statement.finalize();
    try statement.bind(1, name);
    try statement.bind(2, next);
    try statement.bind(3, @as(i64, if (tier.readOnly()) 1 else 0));
    _ = try statement.step();
}

/// Rechecks disk authority each tick before enabling mutations.
fn gate(db: *Db, gpa: std.mem.Allocator, name: []const u8, why: []const u8, tier: skills.Authority, now: i64) !void {
    if (tier.readOnly()) return;
    if (try hasApproval(db, "enable_routine", name, "approved")) return;
    try setEnabled(db, name, false);
    if (try hasApproval(db, "enable_routine", name, "pending")) return;

    const args = try nameArgs(gpa, name);
    defer gpa.free(args);
    const reason = try std.fmt.allocPrint(
        gpa,
        "The routine {s} ({s}) can act on its own, so it stays off until you approve it. Enable it?",
        .{ name, why },
    );
    defer gpa.free(reason);
    const id = try tasks.ask(db, "enable_routine", args, name, reason, null, now);
    const question = try std.fmt.allocPrint(gpa, "{s} (#{d})", .{ reason, id });
    defer gpa.free(question);
    try outbox.push(db, .text, null, question, now);
}

fn setEnabled(db: *Db, name: []const u8, on: bool) !void {
    var statement = try db.prepare("UPDATE routines SET enabled = ? WHERE name = ?");
    defer statement.finalize();
    try statement.bind(1, @as(i64, if (on) 1 else 0));
    try statement.bind(2, name);
    _ = try statement.step();
}

fn hasApproval(db: *Db, tool: []const u8, target: []const u8, status: []const u8) !bool {
    var statement = try db.prepare("SELECT 1 FROM approvals WHERE tool = ? AND target = ? AND status = ? LIMIT 1");
    defer statement.finalize();
    try statement.bind(1, tool);
    try statement.bind(2, target);
    try statement.bind(3, status);
    return try statement.step();
}

/// Valid names are safe inside the bound approval JSON.
fn nameArgs(gpa: std.mem.Allocator, name: []const u8) ![]u8 {
    if (!skills.validName(name)) return error.BadName;
    return std.fmt.allocPrint(gpa, "{{\"name\":\"{s}\"}}", .{name});
}

fn fire(assistant: *agent.Agent, now: i64, cancel: ?*const agent.Workers) !void {
    var names: std.ArrayList([]u8) = .empty;
    defer {
        for (names.items) |name| assistant.gpa.free(name);
        names.deinit(assistant.gpa);
    }
    {
        var statement = try assistant.db.prepare(
            \\SELECT name FROM routines WHERE enabled = 1 AND next IS NOT NULL AND next <= ?
        );
        defer statement.finalize();
        try statement.bind(1, now);
        while (try statement.step()) {
            try names.append(assistant.gpa, try assistant.gpa.dupe(u8, statement.text(0)));
        }
    }

    for (names.items) |name| {
        runOne(assistant, name, now, cancel) catch |err| {
            if (err == error.Cancelled) return err;
            log.err("{s}: {t}", .{ name, err });
            // Back off broken skills to avoid a hot loop.
            try record(assistant.db, name, now, now + 3600, "failed");
        };
    }
}

fn runOne(assistant: *agent.Agent, name: []const u8, now: i64, cancel: ?*const agent.Workers) !void {
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/{s}/SKILL.md", .{ assistant.skills_dir, name });
    const text = try std.Io.Dir.cwd().readFileAlloc(assistant.io, path, assistant.gpa, .limited(64 * 1024));
    defer assistant.gpa.free(text);
    const skill = try skills.parse(text);
    const expr = skill.schedule orelse return;
    const spec = try cron.parse(expr);
    const next = try cron.nextRun(spec, now, skill.timezone);
    const tier = skills.Authority.of(skill.authority);
    const state = try stateOf(assistant.db, name);

    if (tier == .critical and !state.approved) {
        // Never replay critical work after downtime.
        if (now - state.due > missed_after) return skip(assistant, name, now, next);
        return askFirst(assistant, name, skill.description, now, next);
    }
    return execute(assistant, name, skill, tier, now, next, cancel);
}

const State = struct { due: i64, approved: bool };

fn stateOf(db: *Db, name: []const u8) !State {
    var statement = try db.prepare("SELECT COALESCE(next, 0), COALESCE(status, '') FROM routines WHERE name = ?");
    defer statement.finalize();
    try statement.bind(1, name);
    if (!try statement.step()) return error.NoRoutine;
    return .{ .due = statement.int(0), .approved = std.mem.eql(u8, statement.text(1), "approved") };
}

fn execute(assistant: *agent.Agent, name: []const u8, skill: skills.Skill, tier: skills.Authority, now: i64, next: i64, cancel: ?*const agent.Workers) !void {
    const list = try tools.subset(assistant.gpa, assistant.tools, tier.readOnly(), skill.allowed_tools);
    defer assistant.gpa.free(list);
    const prompt = try std.fmt.allocPrint(assistant.gpa, "Run routine {s}.\n\n{s}", .{ name, skill.body });
    defer assistant.gpa.free(prompt);

    // This thread exclusively owns the agent.
    const full = assistant.tools;
    assistant.tools = list;
    defer assistant.tools = full;

    const result = if (cancel) |state|
        assistant.turnWithCancel(.{ .text = prompt }, state)
    else
        assistant.turn(prompt);
    if (result) |reply| {
        defer assistant.gpa.free(reply);
        if (reply.len != 0) try outbox.push(assistant.db, .text, null, reply, now);
        try record(assistant.db, name, now, next, "ok");
    } else |err| {
        if (err == error.Cancelled) return err;
        log.err("{s}: {t}", .{ name, err });
        try record(assistant.db, name, now, next, "failed");
    }
}

/// Keeps one pending approval per firing.
fn askFirst(assistant: *agent.Agent, name: []const u8, why: []const u8, now: i64, next: i64) !void {
    if (try hasApproval(assistant.db, "run_routine", name, "pending")) {
        return record(assistant.db, name, now, next, "awaiting-approval");
    }
    const args = try nameArgs(assistant.gpa, name);
    defer assistant.gpa.free(args);
    const reason = try std.fmt.allocPrint(assistant.gpa, "{s} ({s}) is due. Run it?", .{ name, why });
    defer assistant.gpa.free(reason);
    const id = try tasks.ask(assistant.db, "run_routine", args, name, reason, null, now);
    const question = try std.fmt.allocPrint(assistant.gpa, "{s} (#{d})", .{ reason, id });
    defer assistant.gpa.free(question);
    try outbox.push(assistant.db, .text, null, question, now);
    try record(assistant.db, name, now, next, "awaiting-approval");
}

fn skip(assistant: *agent.Agent, name: []const u8, now: i64, next: i64) !void {
    const note = try std.fmt.allocPrint(
        assistant.gpa,
        "Skipped {s}: it came due while I was down, and I never replay a critical routine on my own.",
        .{name},
    );
    defer assistant.gpa.free(note);
    try outbox.push(assistant.db, .text, null, note, now);
    try record(assistant.db, name, now, next, "skipped");
}

/// Records outcomes and advances `next` together.
fn record(db: *Db, name: []const u8, now: i64, next: i64, status: []const u8) !void {
    var statement = try db.prepare(
        \\UPDATE routines SET last = ?, next = ?, status = ?, fails = fails + ?, skips = skips + ?
        \\WHERE name = ?
    );
    defer statement.finalize();
    try statement.bind(1, now);
    try statement.bind(2, next);
    try statement.bind(3, status);
    try statement.bind(4, @as(i64, if (std.mem.eql(u8, status, "failed")) 1 else 0));
    try statement.bind(5, @as(i64, if (std.mem.eql(u8, status, "skipped")) 1 else 0));
    try statement.bind(6, name);
    _ = try statement.step();
}

test "tick runs a due routine through agent.turn and updates next/last" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [128]u8 = undefined;

    var fake: FakeHttp = .{
        .bodies = &.{"{\"choices\":[{\"message\":{\"content\":\"briefed\"}}]}"},
    };

    var db = try testkit.tmpDb(&tmp, &buf);
    defer db.close();

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const dir = try std.fmt.bufPrint(&buf, ".zig-cache/tmp/{s}/skills", .{tmp.sub_path});
    _ = try skills.save(testing.allocator, io, dir,
        \\---
        \\name: morning-brief
        \\description: overnight mail
        \\schedule: every 1h
        \\timezone: UTC
        \\---
        \\
        \\Summarize overnight mail.
    );

    var assistant: agent.Agent = .{
        .gpa = testing.allocator,
        .io = io,
        .db = &db,
        .http = fake.http(),
        .api_key = .init("k"),
        .base_url = "https://api.openai.com/v1",
        .model = "m",
        .skills_dir = dir,
    };

    const now: i64 = 1_000;
    try tick(&assistant, now);
    try testing.expectEqual(@as(usize, 0), fake.index);

    try db.exec("UPDATE routines SET next = 500 WHERE name = 'morning-brief'");
    try tick(&assistant, now);
    try testing.expectEqual(@as(usize, 1), fake.index);

    var statement = try db.prepare("SELECT last, next, status FROM routines WHERE name = 'morning-brief'");
    defer statement.finalize();
    try testing.expect(try statement.step());
    try testing.expectEqual(@as(i64, now), statement.int(0));
    try testing.expectEqual(@as(i64, now + 3600), statement.int(1));
    try testing.expectEqualStrings("ok", statement.text(2));
}

test "a routine whose skill vanished backs off instead of hot-looping" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [128]u8 = undefined;
    var db = try testkit.tmpDb(&tmp, &buf);
    defer db.close();

    try insertRoutine(&db, "ghost", 0, .notify);
    try record(&db, "ghost", 100, 100 + 3600, "failed");

    var statement = try db.prepare("SELECT next, status FROM routines WHERE name = 'ghost'");
    defer statement.finalize();
    try testing.expect(try statement.step());
    try testing.expectEqual(@as(i64, 100 + 3600), statement.int(0));
    try testing.expectEqualStrings("failed", statement.text(1));
}

const Rig = struct {
    tmp: testing.TmpDir,
    threaded: std.Io.Threaded,
    db: Db,
    fake: FakeHttp,
    dir_buf: [128]u8 = undefined,
    dir: []const u8 = &.{},
    assistant: agent.Agent = undefined,

    fn init(self: *Rig, bodies: []const []const u8) !void {
        self.tmp = testing.tmpDir(.{});
        errdefer self.tmp.cleanup();
        self.threaded = .init(testing.allocator, .{});
        var path_buf: [128]u8 = undefined;
        self.db = try testkit.tmpDb(&self.tmp, &path_buf);
        self.fake = .{ .bodies = bodies };
        self.dir = try std.fmt.bufPrint(&self.dir_buf, ".zig-cache/tmp/{s}/skills", .{self.tmp.sub_path});
        self.assistant = .{
            .gpa = testing.allocator,
            .io = self.threaded.io(),
            .db = &self.db,
            .http = self.fake.http(),
            .api_key = .init("k"),
            .base_url = "https://api.openai.com/v1",
            .model = "m",
            .tools = &tools.builtins,
            .skills_dir = self.dir,
        };
    }

    fn write(self: *Rig, markdown: []const u8) !void {
        _ = try skills.save(testing.allocator, self.threaded.io(), self.dir, markdown);
    }

    fn routine(self: *Rig, name: []const u8) !struct { enabled: i64, skips: i64, next: i64 } {
        var statement = try self.db.prepare("SELECT enabled, skips, COALESCE(next, 0) FROM routines WHERE name = ?");
        defer statement.finalize();
        try statement.bind(1, name);
        if (!try statement.step()) return error.NoRoutine;
        return .{ .enabled = statement.int(0), .skips = statement.int(1), .next = statement.int(2) };
    }

    /// Column slices die at the next step, so the caller supplies the storage.
    fn status(self: *Rig, name: []const u8, buf: []u8) ![]const u8 {
        var statement = try self.db.prepare("SELECT COALESCE(status, '') FROM routines WHERE name = ?");
        defer statement.finalize();
        try statement.bind(1, name);
        if (!try statement.step()) return error.NoRoutine;
        return std.fmt.bufPrint(buf, "{s}", .{statement.text(0)});
    }

    fn approve(self: *Rig, tool: []const u8, name: []const u8) !void {
        var statement = try self.db.prepare("UPDATE approvals SET status = 'approved' WHERE tool = ? AND target = ?");
        defer statement.finalize();
        try statement.bind(1, tool);
        try statement.bind(2, name);
        _ = try statement.step();
    }

    fn deinit(self: *Rig) void {
        self.db.close();
        self.threaded.deinit();
        self.tmp.cleanup();
    }
};

const notify_skill =
    \\---
    \\name: brief
    \\description: overnight mail
    \\schedule: every 1h
    \\timezone: UTC
    \\authority: notify
    \\---
    \\
    \\Summarize overnight mail.
;

const critical_skill =
    \\---
    \\name: payer
    \\description: pay the card bill
    \\schedule: every 1h
    \\timezone: UTC
    \\authority: critical
    \\---
    \\
    \\Pay the card bill.
;

test "a mutating routine stays off until the owner approves it" {
    var rig: Rig = undefined;
    try rig.init(&.{});
    defer rig.deinit();
    try rig.write(critical_skill);

    try tick(&rig.assistant, 1000);
    const before = try rig.routine("payer");
    try testing.expectEqual(@as(i64, 0), before.enabled);

    try tick(&rig.assistant, 1001);
    try testing.expectEqual(@as(usize, 1), try tasks.pendingCount(&rig.db));
    try testing.expectEqual(@as(usize, 0), rig.fake.index);
}

test "rewriting notify to critical switches the routine back off" {
    var rig: Rig = undefined;
    try rig.init(&.{});
    defer rig.deinit();
    try rig.write(notify_skill);
    try tick(&rig.assistant, 1000);
    try testing.expectEqual(@as(i64, 1), (try rig.routine("brief")).enabled);

    try rig.write(
        \\---
        \\name: brief
        \\description: overnight mail
        \\schedule: every 1h
        \\timezone: UTC
        \\authority: critical
        \\---
        \\
        \\Summarize overnight mail.
    );
    try tick(&rig.assistant, 1001);
    try testing.expectEqual(@as(i64, 0), (try rig.routine("brief")).enabled);
    try testing.expectEqual(@as(usize, 1), try tasks.pendingCount(&rig.db));
}

test "a notify routine is handed no tool that can mutate" {
    var rig: Rig = undefined;
    try rig.init(&.{"{\"choices\":[{\"message\":{\"content\":\"briefed\"}}]}"});
    defer rig.deinit();
    try rig.write(notify_skill);
    try tick(&rig.assistant, 1000);
    try rig.db.exec("UPDATE routines SET next = 500 WHERE name = 'brief'");
    try tick(&rig.assistant, 1000);

    try testing.expectEqual(@as(usize, 1), rig.fake.index);
    const sent = rig.fake.sent();
    try testing.expect(std.mem.indexOf(u8, sent, "\"recall\"") != null);
    try testing.expect(std.mem.indexOf(u8, sent, "\"remember\"") == null);
    try testing.expect(std.mem.indexOf(u8, sent, "\"save_skill\"") == null);
}

test "a critical routine asks first and only runs once approved" {
    var rig: Rig = undefined;
    try rig.init(&.{"{\"choices\":[{\"message\":{\"content\":\"paid\"}}]}"});
    defer rig.deinit();
    try rig.write(critical_skill);
    try tick(&rig.assistant, 1000);
    try rig.approve("enable_routine", "payer");
    try rig.db.exec("UPDATE routines SET enabled = 1, next = 900 WHERE name = 'payer'");

    var buf: [32]u8 = undefined;
    try tick(&rig.assistant, 1000);
    try testing.expectEqual(@as(usize, 0), rig.fake.index);
    try testing.expectEqualStrings("awaiting-approval", try rig.status("payer", &buf));

    try rig.db.exec("UPDATE routines SET next = 0, status = 'approved' WHERE name = 'payer'");
    try tick(&rig.assistant, 1100);
    try testing.expectEqual(@as(usize, 1), rig.fake.index);
    try testing.expectEqualStrings("ok", try rig.status("payer", &buf));
}

test "a day of downtime is one catch-up run, and a missed critical is skipped" {
    var rig: Rig = undefined;
    try rig.init(&.{"{\"choices\":[{\"message\":{\"content\":\"briefed\"}}]}"});
    defer rig.deinit();
    try rig.write(notify_skill);
    try rig.write(critical_skill);

    const now: i64 = 2_000_000;
    try tick(&rig.assistant, now - 86400);
    try rig.approve("enable_routine", "payer");
    try rig.db.exec("UPDATE routines SET enabled = 1");

    try tick(&rig.assistant, now);
    try testing.expectEqual(@as(usize, 1), rig.fake.index);

    const brief = try rig.routine("brief");
    try testing.expect(brief.next > now);
    const payer = try rig.routine("payer");
    var buf: [32]u8 = undefined;
    try testing.expectEqualStrings("skipped", try rig.status("payer", &buf));
    try testing.expectEqual(@as(i64, 1), payer.skips);
    try testing.expect(payer.next > now);

    try tick(&rig.assistant, now + 1);
    try testing.expectEqual(@as(usize, 1), rig.fake.index);
}

test "an unanswered critical routine asks once, not once per firing" {
    var rig: Rig = undefined;
    try rig.init(&.{});
    defer rig.deinit();
    try rig.write(critical_skill);
    try tick(&rig.assistant, 1000);
    try rig.approve("enable_routine", "payer");
    try rig.db.exec("UPDATE routines SET enabled = 1, next = 900 WHERE name = 'payer'");

    try tick(&rig.assistant, 1000);
    try tick(&rig.assistant, 1000);
    try tick(&rig.assistant, 1000);

    var statement = try rig.db.prepare("SELECT count(*) FROM approvals WHERE tool = 'run_routine' AND target = 'payer'");
    defer statement.finalize();
    try testing.expect(try statement.step());
    try testing.expectEqual(@as(i64, 1), statement.int(0));
}

test "yesterday is compacted once, and the diary the owner can read appears" {
    var rig: Rig = undefined;
    try rig.init(&.{});
    defer rig.deinit();

    var dir_buf: [128]u8 = undefined;
    rig.assistant.diary_dir = try std.fmt.bufPrint(&dir_buf, ".zig-cache/tmp/{s}/diary", .{rig.tmp.sub_path});

    const today: i64 = 1_787_270_400;
    const yesterday = today - 86_400;
    var ins = try rig.db.prepare("INSERT INTO messages(role, content, created) VALUES ('user', 'walked the dog', ?)");
    defer ins.finalize();
    try ins.bind(1, yesterday + 3600);
    _ = try ins.step();

    try tick(&rig.assistant, today);

    const text = (try memory.readDiary(testing.allocator, rig.assistant.io, rig.assistant.diary_dir, "2026-08-20")).?;
    defer testing.allocator.free(text);
    try testing.expect(std.mem.indexOf(u8, text, "walked the dog") != null);

    var statement = try rig.db.prepare("SELECT count(*) FROM messages");
    defer statement.finalize();
    try testing.expect(try statement.step());
    try testing.expectEqual(@as(i64, 0), statement.int(0));

    try ins.reset();
    try ins.bind(1, yesterday + 7200);
    _ = try ins.step();
    try tick(&rig.assistant, today + 60);
    var again = try rig.db.prepare("SELECT count(*) FROM messages");
    defer again.finalize();
    try testing.expect(try again.step());
    try testing.expectEqual(@as(i64, 1), again.int(0));
}
