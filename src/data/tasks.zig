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

    fn parse(text: []const u8) ?Status {
        inline for (std.meta.fields(Status)) |field| {
            if (std.mem.eql(u8, text, field.name)) return @field(Status, field.name);
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
        if (self.result) |result| gpa.free(result);
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
        if (self.target) |target| gpa.free(target);
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
    var statement = try db.prepare(
        \\INSERT INTO tasks(parent, status, prio, summary, goal, created)
        \\VALUES (?, 'queued', ?, ?, ?, ?)
    );
    defer statement.finalize();
    try statement.bind(1, parent);
    try statement.bind(2, prio);
    try statement.bind(3, summary);
    try statement.bind(4, goal);
    try statement.bind(5, now);
    _ = try statement.step();
    return db.lastId();
}

pub fn get(db: *Db, gpa: std.mem.Allocator, id: i64) !?Task {
    var statement = try db.prepare(
        \\SELECT id, parent, status, prio, summary, goal, result, tries, created, due
        \\FROM tasks WHERE id = ?
    );
    defer statement.finalize();
    try statement.bind(1, id);
    if (!try statement.step()) return null;
    return try readTask(gpa, &statement);
}

pub fn list(db: *Db, gpa: std.mem.Allocator) ![]Task {
    var statement = try db.prepare(
        \\SELECT id, parent, status, prio, summary, goal, result, tries, created, due
        \\FROM tasks ORDER BY COALESCE(parent, id), parent IS NOT NULL, prio DESC, id
    );
    defer statement.finalize();
    var out: std.ArrayList(Task) = .empty;
    errdefer freeTasks(gpa, out.items);
    while (try statement.step()) {
        try out.append(gpa, try readTask(gpa, &statement));
    }
    return out.toOwnedSlice(gpa);
}

pub fn freeTasks(gpa: std.mem.Allocator, items: []Task) void {
    for (items) |*task| task.deinit(gpa);
    gpa.free(items);
}

pub fn setStatus(db: *Db, id: i64, next: Status) !void {
    const cur = (try statusOf(db, id)) orelse return error.NotFound;
    if (!legal(cur, next)) return error.BadTransition;
    var statement = try db.prepare("UPDATE tasks SET status = ? WHERE id = ?");
    defer statement.finalize();
    try statement.bind(1, @tagName(next));
    try statement.bind(2, id);
    _ = try statement.step();
}

/// Records a failure. Mutating work never retries. Transient work backs off until `max_tries`.
pub fn fail(db: *Db, id: i64, err_text: []const u8, kind: Kind, now: i64) !void {
    // Close the read cursor before upgrading to a write transaction.
    const tries = blk: {
        var statement = try db.prepare("SELECT tries FROM tasks WHERE id = ?");
        defer statement.finalize();
        try statement.bind(1, id);
        if (!try statement.step()) return error.NotFound;
        break :blk statement.int(0) + 1;
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
        var statement = try db.prepare("UPDATE tasks SET status = 'failed', tries = ?, result = ? WHERE id = ?");
        defer statement.finalize();
        try statement.bind(1, tries);
        try statement.bind(2, result);
        try statement.bind(3, id);
        _ = try statement.step();
        return;
    }

    var statement = try db.prepare(
        \\UPDATE tasks SET status = 'queued', tries = ?, result = ?, due = ? WHERE id = ?
    );
    defer statement.finalize();
    try statement.bind(1, tries);
    try statement.bind(2, result);
    try statement.bind(3, now + backoff(tries));
    try statement.bind(4, id);
    _ = try statement.step();
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
    try db.exec("BEGIN IMMEDIATE;");
    errdefer db.exec("ROLLBACK;") catch {};
    {
        var expire = try db.prepare("UPDATE approvals SET status = 'expired', updated = ? WHERE status = 'pending' AND expires <= ?");
        defer expire.finalize();
        try expire.bind(1, now);
        try expire.bind(2, now);
        _ = try expire.step();
    }
    {
        var existing = try db.prepare("SELECT id FROM approvals WHERE tool = ? AND args = ? AND target IS ? AND status = 'pending' ORDER BY id DESC LIMIT 1");
        defer existing.finalize();
        try existing.bind(1, tool);
        try existing.bind(2, args);
        try existing.bind(3, target);
        if (try existing.step()) {
            const id = existing.int(0);
            try db.exec("COMMIT;");
            return id;
        }
    }
    var statement = try db.prepare(
        \\INSERT INTO approvals(task, tool, args, target, reason, status, created, expires)
        \\VALUES (?, ?, ?, ?, ?, 'pending', ?, ?)
    );
    defer statement.finalize();
    try statement.bind(1, task);
    try statement.bind(2, tool);
    try statement.bind(3, args);
    try statement.bind(4, target);
    try statement.bind(5, reason);
    try statement.bind(6, now);
    try statement.bind(7, now + approval_ttl);
    _ = try statement.step();
    const id = db.lastId();
    try db.exec("COMMIT;");
    return id;
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
    var statement = try db.prepare("SELECT tool, args, expires, status FROM approvals WHERE id = ?");
    defer statement.finalize();
    try statement.bind(1, id);
    if (!try statement.step()) return error.NotFound;
    if (!std.mem.eql(u8, statement.text(0), tool) or !std.mem.eql(u8, statement.text(1), args)) return error.WrongAction;
    if (statement.int(2) <= now) return error.Expired;
    return error.NotFound;
}

pub fn pendingCount(db: *Db) !usize {
    var statement = try db.prepare("SELECT count(*) FROM approvals WHERE status = 'pending'");
    defer statement.finalize();
    if (!try statement.step()) return error.Sqlite;
    return @intCast(statement.int(0));
}

pub fn pending(db: *Db, gpa: std.mem.Allocator, id: i64) !?Approval {
    var statement = try db.prepare(
        \\SELECT id, task, tool, args, target, reason, status, created, expires
        \\FROM approvals WHERE id = ? AND status = 'pending'
    );
    defer statement.finalize();
    try statement.bind(1, id);
    if (!try statement.step()) return null;
    return try readApproval(gpa, &statement);
}

pub fn setApproval(db: *Db, id: i64, status: []const u8) !void {
    var statement = try db.prepare("UPDATE approvals SET status = ?, updated = unixepoch() WHERE id = ?");
    defer statement.finalize();
    try statement.bind(1, status);
    try statement.bind(2, id);
    _ = try statement.step();
}

pub fn transitionApproval(db: *Db, id: i64, from: []const u8, to: []const u8) !bool {
    var statement = try db.prepare("UPDATE approvals SET status = ?, updated = unixepoch() WHERE id = ? AND status = ?");
    defer statement.finalize();
    try statement.bind(1, to);
    try statement.bind(2, id);
    try statement.bind(3, from);
    _ = try statement.step();
    return changed(db);
}

pub fn recoverApprovals(db: *Db, cutoff: i64) !void {
    var statement = try db.prepare("UPDATE approvals SET status = 'uncertain', updated = unixepoch() WHERE status = 'executing' AND updated <= ?");
    defer statement.finalize();
    try statement.bind(1, cutoff);
    _ = try statement.step();
}

fn changed(db: *Db) !bool {
    var statement = try db.prepare("SELECT changes()");
    defer statement.finalize();
    if (!try statement.step()) return error.Sqlite;
    return statement.int(0) == 1;
}

/// Formats unexpired pending approvals oldest first. Caller frees.
pub fn pendingLines(db: *Db, gpa: std.mem.Allocator, now: i64) ![]u8 {
    {
        var expire = try db.prepare("UPDATE approvals SET status = 'expired', updated = ? WHERE status = 'pending' AND expires <= ?");
        defer expire.finalize();
        try expire.bind(1, now);
        try expire.bind(2, now);
        _ = try expire.step();
    }
    var statement = try db.prepare("SELECT id, tool, reason FROM approvals WHERE status = 'pending' ORDER BY id");
    defer statement.finalize();
    var buf: std.Io.Writer.Allocating = .init(gpa);
    errdefer buf.deinit();
    while (try statement.step()) {
        try buf.writer.print("#{d} {s}: {s}\n", .{ statement.int(0), statement.text(1), statement.text(2) });
    }
    return buf.toOwnedSlice();
}

pub fn formatList(gpa: std.mem.Allocator, items: []const Task) ![]u8 {
    if (items.len == 0) return try gpa.dupe(u8, "no tasks\n");
    var buf: std.Io.Writer.Allocating = .init(gpa);
    errdefer buf.deinit();
    for (items) |task| {
        const indent: []const u8 = if (task.parent != null) "  " else "";
        try buf.writer.print("{s}#{d} {s} prio={d}  {s}\n{s}  goal: {s}\n", .{
            indent,
            task.id,
            @tagName(task.status),
            task.prio,
            task.summary,
            indent,
            task.goal,
        });
        if (task.parent) |parent| {
            try buf.writer.print("{s}  parent=#{d}\n", .{ indent, parent });
        }
        if (task.result) |result| {
            try buf.writer.print("{s}  result: {s}\n", .{ indent, result });
        }
    }
    return buf.toOwnedSlice();
}

fn readTask(gpa: std.mem.Allocator, statement: anytype) !Task {
    const status = Status.parse(statement.text(2)) orelse return error.BadStatus;
    return .{
        .id = statement.int(0),
        .parent = if (statement.isNull(1)) null else statement.int(1),
        .status = status,
        .prio = statement.int(3),
        .summary = try gpa.dupe(u8, statement.text(4)),
        .goal = try gpa.dupe(u8, statement.text(5)),
        .result = if (statement.isNull(6)) null else try gpa.dupe(u8, statement.text(6)),
        .tries = statement.int(7),
        .created = statement.int(8),
        .due = if (statement.isNull(9)) null else statement.int(9),
    };
}

fn readApproval(gpa: std.mem.Allocator, statement: anytype) !Approval {
    return .{
        .id = statement.int(0),
        .task = if (statement.isNull(1)) null else statement.int(1),
        .tool = try gpa.dupe(u8, statement.text(2)),
        .args = try gpa.dupe(u8, statement.text(3)),
        .target = if (statement.isNull(4)) null else try gpa.dupe(u8, statement.text(4)),
        .reason = try gpa.dupe(u8, statement.text(5)),
        .status = try gpa.dupe(u8, statement.text(6)),
        .created = statement.int(7),
        .expires = statement.int(8),
    };
}

fn statusOf(db: *Db, id: i64) !?Status {
    var statement = try db.prepare("SELECT status FROM tasks WHERE id = ?");
    defer statement.finalize();
    try statement.bind(1, id);
    if (!try statement.step()) return null;
    return Status.parse(statement.text(0));
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
    var task = (try get(&db, testing.allocator, id)).?;
    defer task.deinit(testing.allocator);
    try testing.expectEqual(Status.queued, task.status);
    try testing.expectEqualStrings("book the vet", task.summary);
    try testing.expectEqualStrings("appointment confirmed for next week", task.goal);
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

    const transient_id = try create(&db, "fetch", "page saved", 0, null, 0);
    try fail(&db, transient_id, "timeout", .transient, 100);
    var transient = (try get(&db, testing.allocator, transient_id)).?;
    defer transient.deinit(testing.allocator);
    try testing.expectEqual(Status.queued, transient.status);
    try testing.expectEqual(@as(i64, 1), transient.tries);
    try testing.expectEqual(@as(i64, 160), transient.due.?);
    try testing.expect(std.mem.indexOf(u8, transient.result.?, "timeout") != null);
    try testing.expect(std.mem.indexOf(u8, transient.result.?, "retry") != null);

    const mutating_id = try create(&db, "send", "message delivered", 0, null, 0);
    try fail(&db, mutating_id, "http 500", .mutating, 100);
    var mutating = (try get(&db, testing.allocator, mutating_id)).?;
    defer mutating.deinit(testing.allocator);
    try testing.expectEqual(Status.failed, mutating.status);
    try testing.expect(std.mem.indexOf(u8, mutating.result.?, "do not retry") != null);
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
    var task = (try get(&db, testing.allocator, id)).?;
    defer task.deinit(testing.allocator);
    try testing.expectEqual(Status.failed, task.status);
    try testing.expectEqual(max_tries, task.tries);
    try testing.expect(std.mem.indexOf(u8, task.result.?, "give up") != null);
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
    var statement = try db.prepare("SELECT status FROM approvals WHERE id = ?");
    defer statement.finalize();
    try statement.bind(1, id);
    try testing.expect(try statement.step());
    try testing.expectEqualStrings("uncertain", statement.text(0));
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
    var approval = (try pending(&db, testing.allocator, 1)).?;
    defer approval.deinit(testing.allocator);
    try testing.expectEqualStrings("pending", approval.status);
    try testing.expectEqualStrings("fetch_url", approval.tool);
}

test "repeated permission requests reuse the pending action" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [128]u8 = undefined;
    var db = try testkit.tmpDb(&tmp, &buf);
    defer db.close();

    const first = try ask(&db, "shell", "{\"argv\":[\"deploy\"]}", "deploy", "publish", null, 10);
    const second = try ask(&db, "shell", "{\"argv\":[\"deploy\"]}", "deploy", "publish", null, 11);
    try testing.expectEqual(first, second);
    try testing.expectEqual(@as(usize, 1), try pendingCount(&db));
}

test "pending context expires stale permissions" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [128]u8 = undefined;
    var db = try testkit.tmpDb(&tmp, &buf);
    defer db.close();

    _ = try ask(&db, "shell", "{}", null, "old", null, 0);
    const lines = try pendingLines(&db, testing.allocator, approval_ttl + 1);
    defer testing.allocator.free(lines);
    try testing.expectEqual(@as(usize, 0), lines.len);
    var statement = try db.prepare("SELECT status FROM approvals WHERE id = 1");
    defer statement.finalize();
    try testing.expect(try statement.step());
    try testing.expectEqualStrings("expired", statement.text(0));
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
