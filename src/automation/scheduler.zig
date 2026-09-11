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

/// A run further behind than this was missed while the process was down, not
/// merely delayed by a slow tick.
pub const missed_after: i64 = 5 * 60;

pub fn tick(a: *agent.Agent, now: i64) !void {
    try sync(a.db, a.gpa, a.io, a.skills_dir, now);
    try fire(a, now);
    try compact(a, now);
}

/// Yesterday's transcript becomes yesterday's diary, once. The scheduler owns
/// the only clock in the process, so this is where nightly work belongs.
/// A failure leaves the raw messages and the marker alone, so it retries.
fn compact(a: *agent.Agent, now: i64) !void {
    var day_buf: [10]u8 = undefined;
    const day = memory.formatDay(&day_buf, now - 86_400);
    if (try compacted(a.db, day)) return;

    memory.compact(a.db, a.gpa, a.io, a.diary_dir, day, now, &.{}) catch |err| {
        log.err("compacting {s}: {t}", .{ day, err });
        return;
    };
    try mark(a.db, day);
}

/// A single high-water mark: days only move forward, so one row is enough.
fn compacted(db: *Db, day: []const u8) !bool {
    var q = try db.prepare("SELECT value FROM kv WHERE key = 'compacted'");
    defer q.finalize();
    if (!try q.step()) return false;
    return std.mem.order(u8, q.text(0), day) != .lt;
}

fn mark(db: *Db, day: []const u8) !void {
    var q = try db.prepare(
        \\INSERT INTO kv(key, value) VALUES ('compacted', ?)
        \\ON CONFLICT(key) DO UPDATE SET value = excluded.value
    );
    defer q.finalize();
    try q.bind(1, day);
    _ = try q.step();
}

pub fn loop(a: *agent.Agent, stop: *const fn () bool) void {
    while (!stop()) {
        const now = std.Io.Timestamp.now(a.io, .real).toSeconds();
        tick(a, now) catch |err| log.err("{t}", .{err});
        var left = tick_every;
        while (left > 0 and !stop()) : (left -= 1) {
            std.Io.sleep(a.io, .fromSeconds(1), .awake) catch return;
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
    var q = try db.prepare("SELECT 1 FROM routines WHERE name = ?");
    defer q.finalize();
    try q.bind(1, name);
    return try q.step();
}

/// A read-only routine is active on sight; one that can act starts off.
fn insertRoutine(db: *Db, name: []const u8, next: i64, tier: skills.Authority) !void {
    var q = try db.prepare(
        \\INSERT INTO routines(name, next, last, status, fails, enabled)
        \\VALUES (?, ?, NULL, NULL, 0, ?)
    );
    defer q.finalize();
    try q.bind(1, name);
    try q.bind(2, next);
    try q.bind(3, @as(i64, if (tier.readOnly()) 1 else 0));
    _ = try q.step();
}

/// The tier lives on disk and the agent can rewrite its own SKILL.md, so this
/// re-checks every tick against the owner's approvals rather than against
/// whatever the row said last time. Rewriting `notify` to `safe` therefore
/// switches the routine back off instead of granting it authority.
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
    _ = try tasks.ask(db, "enable_routine", args, name, reason, null, now);
    try outbox.push(db, .text, null, reason, now);
}

fn setEnabled(db: *Db, name: []const u8, on: bool) !void {
    var q = try db.prepare("UPDATE routines SET enabled = ? WHERE name = ?");
    defer q.finalize();
    try q.bind(1, @as(i64, if (on) 1 else 0));
    try q.bind(2, name);
    _ = try q.step();
}

fn hasApproval(db: *Db, tool: []const u8, target: []const u8, status: []const u8) !bool {
    var q = try db.prepare("SELECT 1 FROM approvals WHERE tool = ? AND target = ? AND status = ? LIMIT 1");
    defer q.finalize();
    try q.bind(1, tool);
    try q.bind(2, target);
    try q.bind(3, status);
    return try q.step();
}

/// The approval binds to these exact bytes, so the name has to be the same
/// restricted alphabet `skills.validName` already enforces — no escaping needed,
/// and nothing else can reach here.
fn nameArgs(gpa: std.mem.Allocator, name: []const u8) ![]u8 {
    if (!skills.validName(name)) return error.BadName;
    return std.fmt.allocPrint(gpa, "{{\"name\":\"{s}\"}}", .{name});
}

fn fire(a: *agent.Agent, now: i64) !void {
    var names: std.ArrayList([]u8) = .empty;
    defer {
        for (names.items) |n| a.gpa.free(n);
        names.deinit(a.gpa);
    }
    {
        var q = try a.db.prepare(
            \\SELECT name FROM routines WHERE enabled = 1 AND next IS NOT NULL AND next <= ?
        );
        defer q.finalize();
        try q.bind(1, now);
        while (try q.step()) {
            try names.append(a.gpa, try a.gpa.dupe(u8, q.text(0)));
        }
    }

    for (names.items) |name| {
        runOne(a, name, now) catch |err| {
            log.err("{s}: {t}", .{ name, err });
            // A routine whose skill will not even load backs off an hour so it
            // cannot hot-loop the tick.
            try record(a.db, name, now, now + 3600, "failed");
        };
    }
}

fn runOne(a: *agent.Agent, name: []const u8, now: i64) !void {
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/{s}/SKILL.md", .{ a.skills_dir, name });
    const text = try std.Io.Dir.cwd().readFileAlloc(a.io, path, a.gpa, .limited(64 * 1024));
    defer a.gpa.free(text);
    const skill = try skills.parse(text);
    const expr = skill.schedule orelse return;
    const spec = try cron.parse(expr);
    const next = try cron.nextRun(spec, now, skill.timezone);
    const tier = skills.Authority.of(skill.authority);
    const state = try stateOf(a.db, name);

    if (tier == .critical and !state.approved) {
        // Downtime must never turn into an unattended action, so a critical run
        // that came due while we were off is dropped rather than queued.
        if (now - state.due > missed_after) return skip(a, name, now, next);
        return askFirst(a, name, skill.description, now, next);
    }
    return execute(a, name, skill, tier, now, next);
}

const State = struct { due: i64, approved: bool };

fn stateOf(db: *Db, name: []const u8) !State {
    var q = try db.prepare("SELECT COALESCE(next, 0), COALESCE(status, '') FROM routines WHERE name = ?");
    defer q.finalize();
    try q.bind(1, name);
    if (!try q.step()) return error.NoRoutine;
    return .{ .due = q.int(0), .approved = std.mem.eql(u8, q.text(1), "approved") };
}

fn execute(a: *agent.Agent, name: []const u8, skill: skills.Skill, tier: skills.Authority, now: i64, next: i64) !void {
    const list = try tools.subset(a.gpa, a.tools, tier.readOnly(), skill.allowed_tools);
    defer a.gpa.free(list);
    const prompt = try std.fmt.allocPrint(a.gpa, "Run routine {s}.\n\n{s}", .{ name, skill.body });
    defer a.gpa.free(prompt);

    // The scheduler owns this agent on its own thread, so swapping the tool
    // list for one turn is safe and costs nothing.
    const full = a.tools;
    a.tools = list;
    defer a.tools = full;

    if (a.turn(prompt)) |reply| {
        defer a.gpa.free(reply);
        if (reply.len != 0) try outbox.push(a.db, .text, null, reply, now);
        try record(a.db, name, now, next, "ok");
    } else |err| {
        log.err("{s}: {t}", .{ name, err });
        try record(a.db, name, now, next, "failed");
    }
}

/// Asks once per firing, not once per tick, and never twice while the owner
/// still has the first question open.
fn askFirst(a: *agent.Agent, name: []const u8, why: []const u8, now: i64, next: i64) !void {
    if (try hasApproval(a.db, "run_routine", name, "pending")) {
        return record(a.db, name, now, next, "awaiting-approval");
    }
    const args = try nameArgs(a.gpa, name);
    defer a.gpa.free(args);
    const reason = try std.fmt.allocPrint(a.gpa, "{s} ({s}) is due. Run it?", .{ name, why });
    defer a.gpa.free(reason);
    _ = try tasks.ask(a.db, "run_routine", args, name, reason, null, now);
    try outbox.push(a.db, .text, null, reason, now);
    try record(a.db, name, now, next, "awaiting-approval");
}

fn skip(a: *agent.Agent, name: []const u8, now: i64, next: i64) !void {
    const note = try std.fmt.allocPrint(
        a.gpa,
        "Skipped {s}: it came due while I was down, and I never replay a critical routine on my own.",
        .{name},
    );
    defer a.gpa.free(note);
    try outbox.push(a.db, .text, null, note, now);
    try record(a.db, name, now, next, "skipped");
}

/// The one place a run's outcome lands, so `next` always moves forward.
fn record(db: *Db, name: []const u8, now: i64, next: i64, status: []const u8) !void {
    var q = try db.prepare(
        \\UPDATE routines SET last = ?, next = ?, status = ?, fails = fails + ?, skips = skips + ?
        \\WHERE name = ?
    );
    defer q.finalize();
    try q.bind(1, now);
    try q.bind(2, next);
    try q.bind(3, status);
    try q.bind(4, @as(i64, if (std.mem.eql(u8, status, "failed")) 1 else 0));
    try q.bind(5, @as(i64, if (std.mem.eql(u8, status, "skipped")) 1 else 0));
    try q.bind(6, name);
    _ = try q.step();
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

    var a: agent.Agent = .{
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
    try tick(&a, now); // sync; next is now+3600, not due yet
    try testing.expectEqual(@as(usize, 0), fake.i);

    try db.exec("UPDATE routines SET next = 500 WHERE name = 'morning-brief'");
    try tick(&a, now);
    try testing.expectEqual(@as(usize, 1), fake.i);

    var q = try db.prepare("SELECT last, next, status FROM routines WHERE name = 'morning-brief'");
    defer q.finalize();
    try testing.expect(try q.step());
    try testing.expectEqual(@as(i64, now), q.int(0));
    try testing.expectEqual(@as(i64, now + 3600), q.int(1));
    try testing.expectEqualStrings("ok", q.text(2));
}

test "a routine whose skill vanished backs off instead of hot-looping" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [128]u8 = undefined;
    var db = try testkit.tmpDb(&tmp, &buf);
    defer db.close();

    try insertRoutine(&db, "ghost", 0, .notify);
    try record(&db, "ghost", 100, 100 + 3600, "failed");

    var q = try db.prepare("SELECT next, status FROM routines WHERE name = 'ghost'");
    defer q.finalize();
    try testing.expect(try q.step());
    try testing.expectEqual(@as(i64, 100 + 3600), q.int(0));
    try testing.expectEqualStrings("failed", q.text(1));
}

/// Builds a scheduler-driven agent over a temp DB and a skills dir on disk.
const Rig = struct {
    tmp: testing.TmpDir,
    threaded: std.Io.Threaded,
    db: Db,
    fake: FakeHttp,
    dir_buf: [128]u8 = undefined,
    dir: []const u8 = &.{},
    a: agent.Agent = undefined,

    fn init(self: *Rig, bodies: []const []const u8) !void {
        self.tmp = testing.tmpDir(.{});
        errdefer self.tmp.cleanup();
        self.threaded = .init(testing.allocator, .{});
        var path_buf: [128]u8 = undefined;
        self.db = try testkit.tmpDb(&self.tmp, &path_buf);
        self.fake = .{ .bodies = bodies };
        self.dir = try std.fmt.bufPrint(&self.dir_buf, ".zig-cache/tmp/{s}/skills", .{self.tmp.sub_path});
        self.a = .{
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
        var q = try self.db.prepare("SELECT enabled, skips, COALESCE(next, 0) FROM routines WHERE name = ?");
        defer q.finalize();
        try q.bind(1, name);
        if (!try q.step()) return error.NoRoutine;
        return .{ .enabled = q.int(0), .skips = q.int(1), .next = q.int(2) };
    }

    /// Column slices die at the next step, so the caller supplies the storage.
    fn status(self: *Rig, name: []const u8, buf: []u8) ![]const u8 {
        var q = try self.db.prepare("SELECT COALESCE(status, '') FROM routines WHERE name = ?");
        defer q.finalize();
        try q.bind(1, name);
        if (!try q.step()) return error.NoRoutine;
        return std.fmt.bufPrint(buf, "{s}", .{q.text(0)});
    }

    /// Stands in for the owner saying yes to the pending approval.
    fn approve(self: *Rig, tool: []const u8, name: []const u8) !void {
        var q = try self.db.prepare("UPDATE approvals SET status = 'approved' WHERE tool = ? AND target = ?");
        defer q.finalize();
        try q.bind(1, tool);
        try q.bind(2, name);
        _ = try q.step();
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

    try tick(&rig.a, 1000);
    const before = try rig.routine("payer");
    try testing.expectEqual(@as(i64, 0), before.enabled);

    // One pending approval, and re-syncing does not file a second.
    try tick(&rig.a, 1001);
    try testing.expectEqual(@as(usize, 1), try tasks.pendingCount(&rig.db));
    try testing.expectEqual(@as(usize, 0), rig.fake.i); // never ran
}

test "rewriting notify to critical switches the routine back off" {
    var rig: Rig = undefined;
    try rig.init(&.{});
    defer rig.deinit();
    try rig.write(notify_skill);
    try tick(&rig.a, 1000);
    try testing.expectEqual(@as(i64, 1), (try rig.routine("brief")).enabled);

    // The agent rewrites its own SKILL.md to claim a higher tier.
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
    try tick(&rig.a, 1001);
    try testing.expectEqual(@as(i64, 0), (try rig.routine("brief")).enabled);
    try testing.expectEqual(@as(usize, 1), try tasks.pendingCount(&rig.db));
}

test "a notify routine is handed no tool that can mutate" {
    var rig: Rig = undefined;
    try rig.init(&.{"{\"choices\":[{\"message\":{\"content\":\"briefed\"}}]}"});
    defer rig.deinit();
    try rig.write(notify_skill);
    try tick(&rig.a, 1000);
    try rig.db.exec("UPDATE routines SET next = 500 WHERE name = 'brief'");
    try tick(&rig.a, 1000);

    try testing.expectEqual(@as(usize, 1), rig.fake.i);
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
    try tick(&rig.a, 1000);
    try rig.approve("enable_routine", "payer");
    try rig.db.exec("UPDATE routines SET enabled = 1, next = 900 WHERE name = 'payer'");

    // Due and inside the grace window: it asks instead of acting.
    var buf: [32]u8 = undefined;
    try tick(&rig.a, 1000);
    try testing.expectEqual(@as(usize, 0), rig.fake.i);
    try testing.expectEqualStrings("awaiting-approval", try rig.status("payer", &buf));

    // The owner approves this exact firing.
    try rig.db.exec("UPDATE routines SET next = 0, status = 'approved' WHERE name = 'payer'");
    try tick(&rig.a, 1100);
    try testing.expectEqual(@as(usize, 1), rig.fake.i);
    try testing.expectEqualStrings("ok", try rig.status("payer", &buf));
}

test "a day of downtime is one catch-up run, and a missed critical is skipped" {
    var rig: Rig = undefined;
    try rig.init(&.{"{\"choices\":[{\"message\":{\"content\":\"briefed\"}}]}"});
    defer rig.deinit();
    try rig.write(notify_skill);
    try rig.write(critical_skill);

    const now: i64 = 2_000_000;
    try tick(&rig.a, now - 86400); // discovers both, schedules an hour out
    try rig.approve("enable_routine", "payer");
    try rig.db.exec("UPDATE routines SET enabled = 1");

    // The clock is injected: a day passes with the process down.
    try tick(&rig.a, now);
    try testing.expectEqual(@as(usize, 1), rig.fake.i); // exactly one, not 24

    const brief = try rig.routine("brief");
    try testing.expect(brief.next > now);
    const payer = try rig.routine("payer");
    var buf: [32]u8 = undefined;
    try testing.expectEqualStrings("skipped", try rig.status("payer", &buf));
    try testing.expectEqual(@as(i64, 1), payer.skips);
    try testing.expect(payer.next > now);

    // A second tick with nothing due adds no further runs.
    try tick(&rig.a, now + 1);
    try testing.expectEqual(@as(usize, 1), rig.fake.i);
}

test "an unanswered critical routine asks once, not once per firing" {
    var rig: Rig = undefined;
    try rig.init(&.{});
    defer rig.deinit();
    try rig.write(critical_skill);
    try tick(&rig.a, 1000);
    try rig.approve("enable_routine", "payer");
    try rig.db.exec("UPDATE routines SET enabled = 1, next = 900 WHERE name = 'payer'");

    try tick(&rig.a, 1000);
    try tick(&rig.a, 1000);
    try tick(&rig.a, 1000);

    var q = try rig.db.prepare("SELECT count(*) FROM approvals WHERE tool = 'run_routine' AND target = 'payer'");
    defer q.finalize();
    try testing.expect(try q.step());
    try testing.expectEqual(@as(i64, 1), q.int(0));
}

test "yesterday is compacted once, and the diary the owner can read appears" {
    var rig: Rig = undefined;
    try rig.init(&.{});
    defer rig.deinit();

    var dir_buf: [128]u8 = undefined;
    rig.a.diary_dir = try std.fmt.bufPrint(&dir_buf, ".zig-cache/tmp/{s}/diary", .{rig.tmp.sub_path});

    // 2026-08-21 00:00 UTC, so "yesterday" is 2026-08-20.
    const today: i64 = 1_787_270_400;
    const yesterday = today - 86_400;
    var ins = try rig.db.prepare("INSERT INTO messages(role, content, created) VALUES ('user', 'walked the dog', ?)");
    defer ins.finalize();
    try ins.bind(1, yesterday + 3600);
    _ = try ins.step();

    try tick(&rig.a, today);

    const text = (try memory.readDiary(testing.allocator, rig.a.io, rig.a.diary_dir, "2026-08-20")).?;
    defer testing.allocator.free(text);
    try testing.expect(std.mem.indexOf(u8, text, "walked the dog") != null);

    // The raw rows are gone only after the diary committed.
    var q = try rig.db.prepare("SELECT count(*) FROM messages");
    defer q.finalize();
    try testing.expect(try q.step());
    try testing.expectEqual(@as(i64, 0), q.int(0));

    // A second tick is a no-op rather than a rewrite.
    try ins.reset();
    try ins.bind(1, yesterday + 7200);
    _ = try ins.step();
    try tick(&rig.a, today + 60);
    var again = try rig.db.prepare("SELECT count(*) FROM messages");
    defer again.finalize();
    try testing.expect(try again.step());
    try testing.expectEqual(@as(i64, 1), again.int(0));
}
