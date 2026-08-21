const std = @import("std");
const Db = @import("db.zig").Db;
const agent = @import("agent.zig");
const skills = @import("skills.zig");
const tools = @import("tools.zig");
const tasks = @import("tasks.zig");
const outbox = @import("outbox.zig");
const memory = @import("memory.zig");
const testing = std.testing;

const log = std.log.scoped(.scheduler);

pub const tick_every: u64 = 30;

/// A run further behind than this was missed while the process was down, not
/// merely delayed by a slow tick.
pub const missed_after: i64 = 5 * 60;

pub const Spec = union(enum) {
    interval: i64,
    cron: Cron,
};

pub const Cron = struct {
    min: u64,
    hour: u64,
    dom: u64,
    mon: u64,
    dow: u64,
    dom_any: bool,
    dow_any: bool,
};

pub fn parse(expr: []const u8) !Spec {
    const s = std.mem.trim(u8, expr, &std.ascii.whitespace);
    if (std.mem.startsWith(u8, s, "every ")) {
        return .{ .interval = try parseDuration(std.mem.trim(u8, s["every ".len..], &std.ascii.whitespace)) };
    }
    return .{ .cron = try parseCron(s) };
}

pub fn tzOffset(name: ?[]const u8) i32 {
    const n = name orelse return 0;
    if (n.len == 0 or std.ascii.eqlIgnoreCase(n, "UTC") or std.ascii.eqlIgnoreCase(n, "GMT")) return 0;
    if (n[0] == '+' or n[0] == '-') return parseOffset(n) catch 0;
    if (std.mem.eql(u8, n, "Asia/Kolkata") or std.mem.eql(u8, n, "Asia/Calcutta")) return 330;
    if (std.mem.eql(u8, n, "Europe/London")) return 0;
    if (std.mem.eql(u8, n, "America/New_York")) return -300; // ponytail: no DST
    // ponytail: table of four zones; parse /usr/share/zoneinfo via std.tz when a fifth is needed.
    log.warn("unknown timezone {s}: scheduling in UTC", .{n});
    return 0;
}

pub fn nextRun(spec: Spec, now: i64, tz: ?[]const u8) !i64 {
    return switch (spec) {
        .interval => |sec| now + sec,
        .cron => |c| nextCron(c, now, tzOffset(tz)),
    };
}

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
        const spec = parse(expr) catch continue;
        const tier = skills.Authority.of(skill.authority);
        if (!try hasRoutine(db, skill.name)) {
            const next = nextRun(spec, now, skill.timezone) catch continue;
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
    if (try approved(db, "enable_routine", name)) return;
    try setEnabled(db, name, false);
    if (try pendingFor(db, "enable_routine", name)) return;

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

fn approved(db: *Db, tool: []const u8, target: []const u8) !bool {
    return exists(db, "SELECT 1 FROM approvals WHERE tool = ? AND target = ? AND status = 'approved' LIMIT 1", tool, target);
}

fn pendingFor(db: *Db, tool: []const u8, target: []const u8) !bool {
    return exists(db, "SELECT 1 FROM approvals WHERE tool = ? AND target = ? AND status = 'pending' LIMIT 1", tool, target);
}

fn exists(db: *Db, sql: [:0]const u8, tool: []const u8, target: []const u8) !bool {
    var q = try db.prepare(sql);
    defer q.finalize();
    try q.bind(1, tool);
    try q.bind(2, target);
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
    const spec = try parse(expr);
    const next = try nextRun(spec, now, skill.timezone);
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
    if (try pendingFor(a.db, "run_routine", name)) {
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

fn parseDuration(s: []const u8) !i64 {
    if (s.len == 0) return error.BadSchedule;
    const last = s[s.len - 1];
    const num = if (std.ascii.isAlphabetic(last)) s[0 .. s.len - 1] else s;
    const n = std.fmt.parseInt(i64, num, 10) catch return error.BadSchedule;
    if (n <= 0) return error.BadSchedule;
    const mul: i64 = switch (last) {
        's' => 1,
        'm' => 60,
        'h' => 3600,
        'd' => 86400,
        else => if (std.ascii.isDigit(last)) 1 else return error.BadSchedule,
    };
    return n * mul;
}

fn parseOffset(s: []const u8) !i32 {
    const sign: i32 = if (s[0] == '-') -1 else 1;
    const body = s[1..];
    var hour: i32 = 0;
    var min: i32 = 0;
    if (body.len >= 5 and body[2] == ':') {
        hour = try std.fmt.parseInt(i32, body[0..2], 10);
        min = try std.fmt.parseInt(i32, body[3..5], 10);
    } else if (body.len == 4) {
        hour = try std.fmt.parseInt(i32, body[0..2], 10);
        min = try std.fmt.parseInt(i32, body[2..4], 10);
    } else if (body.len == 2 or body.len == 1) {
        hour = try std.fmt.parseInt(i32, body, 10);
    } else return error.BadTimezone;
    return sign * (hour * 60 + min);
}

fn parseCron(s: []const u8) !Cron {
    var it = std.mem.tokenizeAny(u8, s, " \t");
    const min = it.next() orelse return error.BadSchedule;
    const hour = it.next() orelse return error.BadSchedule;
    const dom = it.next() orelse return error.BadSchedule;
    const mon = it.next() orelse return error.BadSchedule;
    const dow = it.next() orelse return error.BadSchedule;
    if (it.next() != null) return error.BadSchedule;
    var c: Cron = .{
        .min = try parseField(min, 0, 59),
        .hour = try parseField(hour, 0, 23),
        .dom = try parseField(dom, 1, 31),
        .mon = try parseField(mon, 1, 12),
        .dow = try parseField(dow, 0, 7),
        .dom_any = std.mem.eql(u8, dom, "*"),
        .dow_any = std.mem.eql(u8, dow, "*"),
    };
    if (c.dow & (@as(u64, 1) << 7) != 0) c.dow |= 1; // 7 = Sunday
    return c;
}

fn parseField(field: []const u8, min: u6, max: u6) !u64 {
    var bits: u64 = 0;
    var parts = std.mem.splitScalar(u8, field, ',');
    while (parts.next()) |part| {
        if (part.len == 0) return error.BadSchedule;
        var rest = part;
        var step: u6 = 1;
        if (std.mem.indexOfScalar(u8, part, '/')) |slash| {
            step = std.fmt.parseInt(u6, part[slash + 1 ..], 10) catch return error.BadSchedule;
            if (step == 0) return error.BadSchedule;
            rest = part[0..slash];
        }
        var start: u32 = min;
        var end: u32 = max;
        if (!std.mem.eql(u8, rest, "*")) {
            if (std.mem.indexOfScalar(u8, rest, '-')) |dash| {
                start = std.fmt.parseInt(u32, rest[0..dash], 10) catch return error.BadSchedule;
                end = std.fmt.parseInt(u32, rest[dash + 1 ..], 10) catch return error.BadSchedule;
            } else {
                start = std.fmt.parseInt(u32, rest, 10) catch return error.BadSchedule;
                end = start;
            }
        }
        if (start < min or end > max or start > end) return error.BadSchedule;
        var v = start;
        while (v <= end) : (v += step) {
            bits |= @as(u64, 1) << @intCast(v);
        }
    }
    return bits;
}

fn nextCron(c: Cron, now: i64, off_min: i32) !i64 {
    var t = now - @mod(now, 60) + 60;
    const limit = now + 366 * 86400;
    while (t <= limit) : (t += 60) {
        if (matchCron(c, t, off_min)) return t;
    }
    return error.NoMatch;
}

fn matchCron(c: Cron, unix: i64, off_min: i32) bool {
    const local = unix + @as(i64, off_min) * 60;
    const tod = @mod(local, 86400);
    const minute: u6 = @intCast(@divFloor(@mod(tod, 3600), 60));
    const hour: u6 = @intCast(@divFloor(tod, 3600));
    if (c.min & (@as(u64, 1) << minute) == 0) return false;
    if (c.hour & (@as(u64, 1) << hour) == 0) return false;
    const days = @divFloor(local, 86400);
    const civil = civilFromDays(days);
    if (c.mon & (@as(u64, 1) << @intCast(civil.month)) == 0) return false;

    const dow: u6 = @intCast(@mod(days + 4, 7));
    const dom_ok = c.dom & (@as(u64, 1) << @intCast(civil.day)) != 0;
    const dow_ok = c.dow & (@as(u64, 1) << dow) != 0;
    // Vixie cron: two restricted day fields are OR'd, not AND'd.
    if (!c.dom_any and !c.dow_any) return dom_ok or dow_ok;
    return dom_ok and dow_ok;
}

const Civil = struct { year: i32, month: u8, day: u8 };

fn civilFromDays(z: i64) Civil {
    const era = @divFloor(z + 719468, 146097);
    const doe: i64 = z + 719468 - era * 146097;
    const yoe = @divFloor(doe - @divFloor(doe, 1460) + @divFloor(doe, 36524) - @divFloor(doe, 146096), 365);
    var y: i32 = @intCast(yoe + era * 400);
    const doy = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100));
    const mp = @divFloor(5 * doy + 2, 153);
    const d: u8 = @intCast(doy - @divFloor(153 * mp + 2, 5) + 1);
    const m: u8 = @intCast(if (mp < 10) mp + 3 else mp - 9);
    if (m <= 2) y += 1;
    return .{ .year = y, .month = m, .day = d };
}

fn tmpDb(tmp: *testing.TmpDir, buf: []u8) !Db {
    const path = try std.fmt.bufPrintZ(buf, ".zig-cache/tmp/{s}/zoro.db", .{tmp.sub_path});
    var db = try Db.open(path);
    try db.migrate();
    return db;
}

test "interval and cron parse, including timezone" {
    try testing.expectEqual(@as(i64, 900), (try parse("every 15m")).interval);
    try testing.expectEqual(@as(i64, 3600), (try parse("every 1h")).interval);
    const c = (try parse("0 7 * * *")).cron;
    try testing.expect(c.min & 1 != 0);
    try testing.expect(c.hour & (@as(u64, 1) << 7) != 0);

    const now: i64 = 1_755_648_000; // 2026-08-20 00:00 UTC
    const next_utc = try nextRun(try parse("0 7 * * *"), now, "UTC");
    try testing.expectEqual(@as(i64, now + 7 * 3600), next_utc);

    const next_ist = try nextRun(try parse("0 7 * * *"), now, "Asia/Kolkata");
    try testing.expectEqual(@as(i64, now + (7 * 3600 - 330 * 60)), next_ist);

    const n = try nextRun(try parse("every 30s"), now, null);
    try testing.expectEqual(@as(i64, now + 30), n);
}

test "tick runs a due routine through agent.turn and updates next/last" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [128]u8 = undefined;

    var fake: FakeHttp = .{
        .bodies = &.{"{\"choices\":[{\"message\":{\"content\":\"briefed\"}}]}"},
    };

    var db = try tmpDb(&tmp, &buf);
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

const FakeHttp = struct {
    bodies: []const []const u8,
    i: usize = 0,
    seen: [8 * 1024]u8 = undefined,
    last: ?[]const u8 = null,

    fn http(self: *FakeHttp) agent.Http {
        return .{ .ptr = self, .post_fn = post };
    }

    fn post(ptr: *anyopaque, gpa: std.mem.Allocator, req: agent.Http.Request) anyerror!agent.Http.Response {
        const self: *FakeHttp = @ptrCast(@alignCast(ptr));
        if (self.i >= self.bodies.len) return error.TooManyCalls;
        const n = @min(req.body.len, self.seen.len);
        @memcpy(self.seen[0..n], req.body[0..n]);
        self.last = self.seen[0..n];
        const body = try gpa.dupe(u8, self.bodies[self.i]);
        self.i += 1;
        return .{ .status = 200, .body = body };
    }
};

test "two restricted day fields are OR'd, one restricted is AND'd" {
    const now: i64 = 1_754_006_400; // 2025-08-01 00:00 UTC, a Friday
    // 1st of the month OR Monday: today (the 1st) matches even though it is not Monday.
    try testing.expectEqual(now + 9 * 3600, try nextRun(try parse("0 9 1 * 1"), now, "UTC"));
    // Only the day-of-week restricted: the next Monday, three days out.
    try testing.expectEqual(now + 3 * 86400 + 9 * 3600, try nextRun(try parse("0 9 * * 1"), now, "UTC"));
}

test "a routine whose skill vanished backs off instead of hot-looping" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [128]u8 = undefined;
    var db = try tmpDb(&tmp, &buf);
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
        self.db = try tmpDb(&self.tmp, &path_buf);
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
    const sent = rig.fake.last.?;
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
