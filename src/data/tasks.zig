const std = @import("std");
const Db = @import("db.zig").Db;
const testing = std.testing;
const testkit = @import("../testing/testkit.zig");

/// One initial attempt and one retry.
pub const max_tries: i64 = 2;
pub const approval_ttl: i64 = 15 * 60;

pub const Status = enum {
    queued,
    running,
    blocked,
    done,
    failed,
    cancelled,

    fn parse(s: []const u8) ?Status {
        inline for (std.meta.fields(Status)) |f| {
            if (std.mem.eql(u8, s, f.name)) return @field(Status, f.name);
        }
        return null;
    }
};

pub const Kind = enum { transient, mutating };

pub const Task = struct {
    id: i64,
    parent: ?i64,
    status: Status,
    prio: i64,
    summary: []u8,
    goal: []u8,
    result: ?[]u8,
    tries: i64,
    created: i64,
    due: ?i64,

    pub fn deinit(self: *Task, gpa: std.mem.Allocator) void {
        gpa.free(self.summary);
        gpa.free(self.goal);
        if (self.result) |r| gpa.free(r);
        self.* = undefined;
    }
};

pub const Approval = struct {
    id: i64,
    task: ?i64,
    tool: []u8,
    args: []u8,
    target: ?[]u8,
    reason: []u8,
    status: []u8,
    created: i64,
    expires: i64,

    pub fn deinit(self: *Approval, gpa: std.mem.Allocator) void {
        gpa.free(self.tool);
        gpa.free(self.args);
        if (self.target) |t| gpa.free(t);
        gpa.free(self.reason);
        gpa.free(self.status);
        self.* = undefined;
    }
};

pub fn create(
    db: *Db,
    summary: []const u8,
    goal: []const u8,
    now: i64,
    parent: ?i64,
    prio: i64,
) !i64 {
    if (summary.len == 0 or goal.len == 0) return error.MissingGoal;
    var q = try db.prepare(
        \\INSERT INTO tasks(parent, status, prio, summary, goal, created)
        \\VALUES (?, 'queued', ?, ?, ?, ?)
    );
    defer q.finalize();
    try q.bind(1, parent);
    try q.bind(2, prio);
    try q.bind(3, summary);
    try q.bind(4, goal);
    try q.bind(5, now);
    _ = try q.step();
    return db.lastId();
}

pub fn get(db: *Db, gpa: std.mem.Allocator, id: i64) !?Task {
    var q = try db.prepare(
        \\SELECT id, parent, status, prio, summary, goal, result, tries, created, due
        \\FROM tasks WHERE id = ?
    );
    defer q.finalize();
    try q.bind(1, id);
    if (!try q.step()) return null;
    return try readTask(gpa, &q);
}

pub fn list(db: *Db, gpa: std.mem.Allocator) ![]Task {
    var q = try db.prepare(
        \\SELECT id, parent, status, prio, summary, goal, result, tries, created, due
        \\FROM tasks ORDER BY COALESCE(parent, id), parent IS NOT NULL, prio DESC, id
    );
    defer q.finalize();
    var out: std.ArrayList(Task) = .empty;
    errdefer freeTasks(gpa, out.items);
    while (try q.step()) {
        try out.append(gpa, try readTask(gpa, &q));
    }
    return out.toOwnedSlice(gpa);
}

pub fn freeTasks(gpa: std.mem.Allocator, items: []Task) void {
    for (items) |*t| t.deinit(gpa);
    gpa.free(items);
}

pub fn setStatus(db: *Db, id: i64, next: Status) !void {
    const cur = (try statusOf(db, id)) orelse return error.NotFound;
    if (!legal(cur, next)) return error.BadTransition;
    var q = try db.prepare("UPDATE tasks SET status = ? WHERE id = ?");
    defer q.finalize();
    try q.bind(1, @tagName(next));
    try q.bind(2, id);
    _ = try q.step();
}

/// Records a failure. Mutating work never retries. Transient work backs off until `max_tries`.
pub fn fail(db: *Db, id: i64, err_text: []const u8, kind: Kind, now: i64) !void {
    // Close the read cursor before upgrading to a write transaction.
    const tries = blk: {
        var q = try db.prepare("SELECT tries FROM tasks WHERE id = ?");
        defer q.finalize();
        try q.bind(1, id);
        if (!try q.step()) return error.NotFound;
        break :blk q.int(0) + 1;
    };

    var buf: [512]u8 = undefined;
    const result = if (kind == .mutating or tries >= max_tries)
        std.fmt.bufPrint(&buf, "error: {s}\nnext: {s}", .{
            err_text,
            if (kind == .mutating) "do not retry; wait for the owner" else "give up; report to the owner",
        }) catch "error: failed\nnext: give up; report to the owner"
    else
        std.fmt.bufPrint(&buf, "error: {s}\nnext: retry in {d}s", .{ err_text, backoff(tries) }) catch "error: failed\nnext: retry";

    if (kind == .mutating or tries >= max_tries) {
        var q = try db.prepare("UPDATE tasks SET status = 'failed', tries = ?, result = ? WHERE id = ?");
        defer q.finalize();
        try q.bind(1, tries);
        try q.bind(2, result);
        try q.bind(3, id);
        _ = try q.step();
        return;
    }

    var q = try db.prepare(
        \\UPDATE tasks SET status = 'queued', tries = ?, result = ?, due = ? WHERE id = ?
    );
    defer q.finalize();
    try q.bind(1, tries);
    try q.bind(2, result);
    try q.bind(3, now + backoff(tries));
    try q.bind(4, id);
    _ = try q.step();
}

pub fn backoff(tries: i64) i64 {
    const shift: u6 = @intCast(@min(tries - 1, 10));
    return 60 * (@as(i64, 1) << shift);
}

pub fn ask(
    db: *Db,
    tool: []const u8,
    args: []const u8,
    target: ?[]const u8,
    reason: []const u8,
    task: ?i64,
    now: i64,
) !i64 {
    var q = try db.prepare(
        \\INSERT INTO approvals(task, tool, args, target, reason, status, created, expires)
        \\VALUES (?, ?, ?, ?, ?, 'pending', ?, ?)
    );
    defer q.finalize();
    try q.bind(1, task);
    try q.bind(2, tool);
    try q.bind(3, args);
    try q.bind(4, target);
    try q.bind(5, reason);
    try q.bind(6, now);
    try q.bind(7, now + approval_ttl);
    _ = try q.step();
    return db.lastId();
}

pub const AuthorizeError = error{ NotFound, Expired, WrongAction, Sqlite, OutOfMemory };

pub fn authorize(db: *Db, id: i64, tool: []const u8, args: []const u8, now: i64) AuthorizeError!void {
    {
        var claim = try db.prepare("UPDATE approvals SET status = 'executing', updated = ? WHERE id = ? AND tool = ? AND args = ? AND status = 'pending' AND expires > ?");
        defer claim.finalize();
        try claim.bind(1, now);
        try claim.bind(2, id);
        try claim.bind(3, tool);
        try claim.bind(4, args);
        try claim.bind(5, now);
        _ = try claim.step();
    }
    if (try changed(db)) return;
    var q = try db.prepare("SELECT tool, args, expires, status FROM approvals WHERE id = ?");
    defer q.finalize();
    try q.bind(1, id);
    if (!try q.step()) return error.NotFound;
    if (!std.mem.eql(u8, q.text(0), tool) or !std.mem.eql(u8, q.text(1), args)) return error.WrongAction;
    if (q.int(2) <= now) return error.Expired;
    return error.NotFound;
}

pub const Decision = enum { approve, deny, other };

pub fn decide(text: []const u8) Decision {
    const t = std.mem.trim(u8, text, &std.ascii.whitespace);
    if (eqlIgnore(t, "yes") or eqlIgnore(t, "y") or eqlIgnore(t, "ok") or
        eqlIgnore(t, "go ahead") or eqlIgnore(t, "proceed") or eqlIgnore(t, "do it"))
        return .approve;
    if (eqlIgnore(t, "no") or eqlIgnore(t, "n") or eqlIgnore(t, "nope") or
        eqlIgnore(t, "cancel") or eqlIgnore(t, "don't") or eqlIgnore(t, "stop"))
        return .deny;
    return .other;
}

pub fn pendingCount(db: *Db) !usize {
    var q = try db.prepare("SELECT count(*) FROM approvals WHERE status = 'pending'");
    defer q.finalize();
    if (!try q.step()) return error.Sqlite;
    return @intCast(q.int(0));
}

pub fn latestPending(db: *Db, gpa: std.mem.Allocator) !?Approval {
    var q = try db.prepare(
        \\SELECT id, task, tool, args, target, reason, status, created, expires
        \\FROM approvals WHERE status = 'pending' ORDER BY id DESC LIMIT 2
    );
    defer q.finalize();
    if (!try q.step()) return null;
    var first = try readApproval(gpa, &q);
    errdefer first.deinit(gpa);
    if (try q.step()) {
        first.deinit(gpa);
        return null; // more than one: caller must ask which
    }
    return first;
}

pub fn pending(db: *Db, gpa: std.mem.Allocator, id: i64) !?Approval {
    var q = try db.prepare(
        \\SELECT id, task, tool, args, target, reason, status, created, expires
        \\FROM approvals WHERE id = ? AND status = 'pending'
    );
    defer q.finalize();
    try q.bind(1, id);
    if (!try q.step()) return null;
    return try readApproval(gpa, &q);
}

pub fn setApproval(db: *Db, id: i64, status: []const u8) !void {
    var q = try db.prepare("UPDATE approvals SET status = ?, updated = unixepoch() WHERE id = ?");
    defer q.finalize();
    try q.bind(1, status);
    try q.bind(2, id);
    _ = try q.step();
}

pub fn transitionApproval(db: *Db, id: i64, from: []const u8, to: []const u8) !bool {
    var q = try db.prepare("UPDATE approvals SET status = ?, updated = unixepoch() WHERE id = ? AND status = ?");
    defer q.finalize();
    try q.bind(1, to);
    try q.bind(2, id);
    try q.bind(3, from);
    _ = try q.step();
    return changed(db);
}

pub fn recoverApprovals(db: *Db, cutoff: i64) !void {
    var q = try db.prepare("UPDATE approvals SET status = 'uncertain', updated = unixepoch() WHERE status = 'executing' AND updated <= ?");
    defer q.finalize();
    try q.bind(1, cutoff);
    _ = try q.step();
}

fn changed(db: *Db) !bool {
    var q = try db.prepare("SELECT changes()");
    defer q.finalize();
    if (!try q.step()) return error.Sqlite;
    return q.int(0) == 1;
}

/// Formats pending approvals oldest first. Caller frees.
pub fn pendingLines(db: *Db, gpa: std.mem.Allocator) ![]u8 {
    var q = try db.prepare("SELECT id, tool, reason FROM approvals WHERE status = 'pending' ORDER BY id");
    defer q.finalize();
    var buf: std.Io.Writer.Allocating = .init(gpa);
    errdefer buf.deinit();
    while (try q.step()) {
        try buf.writer.print("#{d} {s}: {s}\n", .{ q.int(0), q.text(1), q.text(2) });
    }
    return buf.toOwnedSlice();
}

pub fn formatList(gpa: std.mem.Allocator, items: []const Task) ![]u8 {
    if (items.len == 0) return try gpa.dupe(u8, "no tasks\n");
    var buf: std.Io.Writer.Allocating = .init(gpa);
    errdefer buf.deinit();
    for (items) |t| {
        const indent: []const u8 = if (t.parent != null) "  " else "";
        try buf.writer.print("{s}#{d} {s} prio={d}  {s}\n{s}  goal: {s}\n", .{
            indent,
            t.id,
            @tagName(t.status),
            t.prio,
            t.summary,
            indent,
            t.goal,
        });
        if (t.parent) |p| {
            try buf.writer.print("{s}  parent=#{d}\n", .{ indent, p });
        }
        if (t.result) |r| {
            try buf.writer.print("{s}  result: {s}\n", .{ indent, r });
        }
    }
    return buf.toOwnedSlice();
}

fn readTask(gpa: std.mem.Allocator, q: anytype) !Task {
    const status = Status.parse(q.text(2)) orelse return error.BadStatus;
    return .{
        .id = q.int(0),
        .parent = if (q.isNull(1)) null else q.int(1),
        .status = status,
        .prio = q.int(3),
        .summary = try gpa.dupe(u8, q.text(4)),
        .goal = try gpa.dupe(u8, q.text(5)),
        .result = if (q.isNull(6)) null else try gpa.dupe(u8, q.text(6)),
        .tries = q.int(7),
        .created = q.int(8),
        .due = if (q.isNull(9)) null else q.int(9),
    };
}

fn readApproval(gpa: std.mem.Allocator, q: anytype) !Approval {
    return .{
        .id = q.int(0),
        .task = if (q.isNull(1)) null else q.int(1),
        .tool = try gpa.dupe(u8, q.text(2)),
        .args = try gpa.dupe(u8, q.text(3)),
        .target = if (q.isNull(4)) null else try gpa.dupe(u8, q.text(4)),
        .reason = try gpa.dupe(u8, q.text(5)),
        .status = try gpa.dupe(u8, q.text(6)),
        .created = q.int(7),
        .expires = q.int(8),
    };
}

fn statusOf(db: *Db, id: i64) !?Status {
    var q = try db.prepare("SELECT status FROM tasks WHERE id = ?");
    defer q.finalize();
    try q.bind(1, id);
    if (!try q.step()) return null;
    return Status.parse(q.text(0));
}

fn legal(from: Status, to: Status) bool {
    if (from == to) return true;
    return switch (from) {
        .queued => to == .running or to == .cancelled or to == .blocked,
        .running => to == .blocked or to == .done or to == .failed or to == .cancelled,
        .blocked => to == .queued or to == .running or to == .cancelled,
        .done, .failed, .cancelled => false,
    };
}

fn eqlIgnore(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (std.ascii.toLower(x) != std.ascii.toLower(y)) return false;
    }
    return true;
}

test "a task survives reopen and carries a success criterion" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [128]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&buf, ".zig-cache/tmp/{s}/zoro.db", .{tmp.sub_path});

    const id = blk: {
        var db = try Db.open(path);
        defer db.close();
        try db.initSchema();
        break :blk try create(&db, "book the vet", "appointment confirmed for next week", 1000, null, 1);
    };

    var db = try Db.open(path);
    defer db.close();
    var t = (try get(&db, testing.allocator, id)).?;
    defer t.deinit(testing.allocator);
    try testing.expectEqual(Status.queued, t.status);
    try testing.expectEqualStrings("book the vet", t.summary);
    try testing.expectEqualStrings("appointment confirmed for next week", t.goal);
}

test "status machine rejects a jump from done back to running" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [128]u8 = undefined;
    var db = try testkit.tmpDb(&tmp, &buf);
    defer db.close();

    const id = try create(&db, "x", "done means the file exists", 0, null, 0);
    try setStatus(&db, id, .running);
    try setStatus(&db, id, .done);
    try testing.expectError(error.BadTransition, setStatus(&db, id, .running));
}

test "transient failure retries with backoff; mutating never retries" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [128]u8 = undefined;
    var db = try testkit.tmpDb(&tmp, &buf);
    defer db.close();

    const a = try create(&db, "fetch", "page saved", 0, null, 0);
    try fail(&db, a, "timeout", .transient, 100);
    var ta = (try get(&db, testing.allocator, a)).?;
    defer ta.deinit(testing.allocator);
    try testing.expectEqual(Status.queued, ta.status);
    try testing.expectEqual(@as(i64, 1), ta.tries);
    try testing.expectEqual(@as(i64, 160), ta.due.?);
    try testing.expect(std.mem.indexOf(u8, ta.result.?, "timeout") != null);
    try testing.expect(std.mem.indexOf(u8, ta.result.?, "retry") != null);

    const b = try create(&db, "send", "message delivered", 0, null, 0);
    try fail(&db, b, "http 500", .mutating, 100);
    var tb = (try get(&db, testing.allocator, b)).?;
    defer tb.deinit(testing.allocator);
    try testing.expectEqual(Status.failed, tb.status);
    try testing.expect(std.mem.indexOf(u8, tb.result.?, "do not retry") != null);
}

test "transient retries stop at the cap" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [128]u8 = undefined;
    var db = try testkit.tmpDb(&tmp, &buf);
    defer db.close();

    const id = try create(&db, "fetch", "ok", 0, null, 0);
    try fail(&db, id, "e", .transient, 0);
    try fail(&db, id, "e", .transient, 0);
    var t = (try get(&db, testing.allocator, id)).?;
    defer t.deinit(testing.allocator);
    try testing.expectEqual(Status.failed, t.status);
    try testing.expectEqual(max_tries, t.tries);
    try testing.expect(std.mem.indexOf(u8, t.result.?, "give up") != null);
}

test "approval for action A cannot authorize action B" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [128]u8 = undefined;
    var db = try testkit.tmpDb(&tmp, &buf);
    defer db.close();

    const id = try ask(&db, "fetch_url", "{\"url\":\"https://example.com\"}", "example.com", "read the page", null, 0);
    try authorize(&db, id, "fetch_url", "{\"url\":\"https://example.com\"}", 1);
    try testing.expectError(error.WrongAction, authorize(&db, id, "fetch_url", "{\"url\":\"https://evil.test\"}", 1));
    try testing.expectError(error.NotFound, authorize(&db, id, "fetch_url", "{\"url\":\"https://example.com\"}", 1));
}

test "an interrupted approval becomes uncertain" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [128]u8 = undefined;
    var db = try Db.open(try testkit.tmpPath(&tmp, &buf, "zoro.db"));
    defer db.close();
    try db.initSchema();
    const id = try ask(&db, "shell", "{}", null, "run it", null, 1);
    try authorize(&db, id, "shell", "{}", 2);
    try recoverApprovals(&db, 2);
    var q = try db.prepare("SELECT status FROM approvals WHERE id = ?");
    defer q.finalize();
    try q.bind(1, id);
    try testing.expect(try q.step());
    try testing.expectEqualStrings("uncertain", q.text(0));
}

test "expired approval is refused" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [128]u8 = undefined;
    var db = try testkit.tmpDb(&tmp, &buf);
    defer db.close();

    const id = try ask(&db, "fetch_url", "{}", null, "x", null, 0);
    try testing.expectError(error.Expired, authorize(&db, id, "fetch_url", "{}", approval_ttl + 1));
}

test "approvals survive reopen" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [128]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&buf, ".zig-cache/tmp/{s}/zoro.db", .{tmp.sub_path});
    {
        var db = try Db.open(path);
        defer db.close();
        try db.initSchema();
        _ = try ask(&db, "fetch_url", "{}", "h", "why", null, 10);
    }
    var db = try Db.open(path);
    defer db.close();
    var a = (try latestPending(&db, testing.allocator)).?;
    defer a.deinit(testing.allocator);
    try testing.expectEqualStrings("pending", a.status);
    try testing.expectEqualStrings("fetch_url", a.tool);
}

test "yes maps to the single pending action; two pendings need clarification" {
    try testing.expectEqual(.approve, decide("Yes"));
    try testing.expectEqual(.approve, decide("go ahead"));
    try testing.expectEqual(.deny, decide("no"));
    try testing.expectEqual(.other, decide("book the vet"));

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [128]u8 = undefined;
    var db = try testkit.tmpDb(&tmp, &buf);
    defer db.close();

    _ = try ask(&db, "a", "{}", null, "one", null, 0);
    var one = (try latestPending(&db, testing.allocator)).?;
    defer one.deinit(testing.allocator);
    try testing.expectEqualStrings("a", one.tool);

    _ = try ask(&db, "b", "{}", null, "two", null, 0);
    try testing.expect(try latestPending(&db, testing.allocator) == null);
}

test "formatList indents child tasks" {
    const items = [_]Task{
        .{
            .id = 1,
            .parent = null,
            .status = .queued,
            .prio = 2,
            .summary = @constCast("research"),
            .goal = @constCast("notes written"),
            .result = null,
            .tries = 0,
            .created = 0,
            .due = null,
        },
        .{
            .id = 2,
            .parent = 1,
            .status = .running,
            .prio = 0,
            .summary = @constCast("fetch sources"),
            .goal = @constCast("three urls saved"),
            .result = null,
            .tries = 0,
            .created = 0,
            .due = null,
        },
    };
    const text = try formatList(testing.allocator, &items);
    defer testing.allocator.free(text);
    try testing.expect(std.mem.indexOf(u8, text, "#1 queued prio=2  research") != null);
    try testing.expect(std.mem.indexOf(u8, text, "  #2 running") != null);
    try testing.expect(std.mem.indexOf(u8, text, "parent=#1") != null);
}
