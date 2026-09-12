const std = @import("std");
const Db = @import("db.zig").Db;
const Stmt = @import("db.zig").Stmt;
const testkit = @import("../testing/testkit.zig");

pub const Status = enum { pending, applying, applied, rolling_back, rolled_back, rejected, quarantined };
pub const Mode = enum { off, propose, auto };

pub const max_evidence = 4 * 1024;
pub const max_reason = 1024;
pub const max_proposed = 64 * 1024;

pub const Proposal = struct {
    id: i64,
    target: []u8,
    source_task: ?i64,
    source_message: ?i64,
    evidence: []u8,
    reason: []u8,
    old_hash: []u8,
    proposed: []u8,
    prior_content: ?[]u8,
    status: Status,
    created: i64,
    updated: i64,
    applied_hash: ?[]u8,

    pub fn deinit(self: *Proposal, gpa: std.mem.Allocator) void {
        gpa.free(self.target);
        gpa.free(self.evidence);
        gpa.free(self.reason);
        gpa.free(self.old_hash);
        gpa.free(self.proposed);
        if (self.prior_content) |v| gpa.free(v);
        if (self.applied_hash) |v| gpa.free(v);
        self.* = undefined;
    }
};

pub fn hash(text: []const u8) [64]u8 {
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(text, &digest, .{});
    return std.fmt.bytesToHex(digest, .lower);
}

pub fn create(db: *Db, target: []const u8, source_task: ?i64, source_message: ?i64, evidence: []const u8, reason: []const u8, old_content: ?[]const u8, proposed: []const u8, now: i64) !i64 {
    if (try mode(db) == .off) return error.LearningOff;
    if (target.len == 0 or target.len > 64 or evidence.len == 0 or evidence.len > max_evidence or reason.len == 0 or reason.len > max_reason or proposed.len == 0 or proposed.len > max_proposed) return error.InvalidProposal;
    if (!validTarget(target)) return error.BadTarget;
    var q = try db.prepare("INSERT INTO learning_proposals(target, source_task, source_message, evidence, reason, old_hash, proposed, prior_content, created, updated) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)");
    defer q.finalize();
    const old_hash = hash(old_content orelse "");
    try q.bind(1, target);
    try q.bind(2, source_task);
    try q.bind(3, source_message);
    try q.bind(4, evidence);
    try q.bind(5, reason);
    try q.bind(6, old_hash[0..]);
    try q.bind(7, proposed);
    try q.bind(8, old_content);
    try q.bind(9, now);
    try q.bind(10, now);
    _ = try q.step();
    return db.lastId();
}

pub fn get(db: *Db, gpa: std.mem.Allocator, id: i64) !?Proposal {
    var q = try db.prepare("SELECT id, target, source_task, source_message, evidence, reason, old_hash, proposed, prior_content, status, created, updated, applied_hash FROM learning_proposals WHERE id = ?");
    defer q.finalize();
    try q.bind(1, id);
    if (!try q.step()) return null;
    return try copy(&q, gpa);
}

pub fn setStatus(db: *Db, id: i64, status: Status, now: i64) !void {
    if (status != .rejected and status != .quarantined) return error.BadStatus;
    var q = try db.prepare("UPDATE learning_proposals SET status = ?, updated = ? WHERE id = ? AND status = 'pending'");
    defer q.finalize();
    try q.bind(1, @tagName(status));
    try q.bind(2, now);
    try q.bind(3, id);
    _ = try q.step();
    if (try changes(db) == 0) return error.BadTransition;
}

pub fn startApply(db: *Db, id: i64, current_hash: []const u8, now: i64) !void {
    var q = try db.prepare("UPDATE learning_proposals SET status = 'applying', updated = ? WHERE id = ? AND status = 'pending' AND old_hash = ?");
    defer q.finalize();
    try q.bind(1, now);
    try q.bind(2, id);
    try q.bind(3, current_hash);
    _ = try q.step();
    if (try changes(db) == 0) return error.StaleProposal;
}

pub fn finishApply(db: *Db, id: i64, applied_hash: []const u8, now: i64) !void {
    var q = try db.prepare("UPDATE learning_proposals SET status = 'applied', applied_hash = ?, updated = ? WHERE id = ? AND status = 'applying'");
    defer q.finalize();
    try q.bind(1, applied_hash);
    try q.bind(2, now);
    try q.bind(3, id);
    _ = try q.step();
    if (try changes(db) == 0) return error.BadTransition;
}

pub fn startRollback(db: *Db, id: i64, now: i64) !void {
    var q = try db.prepare("UPDATE learning_proposals SET status = 'rolling_back', updated = ? WHERE id = ? AND status = 'applied'");
    defer q.finalize();
    try q.bind(1, now);
    try q.bind(2, id);
    _ = try q.step();
    if (try changes(db) == 0) return error.BadTransition;
}

pub fn finishRollback(db: *Db, id: i64, now: i64) !void {
    var q = try db.prepare("UPDATE learning_proposals SET status = 'rolled_back', updated = ? WHERE id = ? AND status = 'rolling_back'");
    defer q.finalize();
    try q.bind(1, now);
    try q.bind(2, id);
    _ = try q.step();
    if (try changes(db) == 0) return error.BadTransition;
}

pub fn recoverApply(db: *Db, id: i64, status: Status, applied_hash: ?[]const u8, now: i64) !void {
    if (status != .pending and status != .applied and status != .quarantined) return error.BadStatus;
    var q = try db.prepare("UPDATE learning_proposals SET status = ?, applied_hash = ?, updated = ? WHERE id = ? AND status = 'applying'");
    defer q.finalize();
    try q.bind(1, @tagName(status));
    try q.bind(2, applied_hash);
    try q.bind(3, now);
    try q.bind(4, id);
    _ = try q.step();
    if (try changes(db) == 0) return error.BadTransition;
}

pub fn recoverRollback(db: *Db, id: i64, status: Status, now: i64) !void {
    if (status != .applied and status != .rolled_back and status != .quarantined) return error.BadStatus;
    var q = try db.prepare("UPDATE learning_proposals SET status = ?, updated = ? WHERE id = ? AND status = 'rolling_back'");
    defer q.finalize();
    try q.bind(1, @tagName(status));
    try q.bind(2, now);
    try q.bind(3, id);
    _ = try q.step();
    if (try changes(db) == 0) return error.BadTransition;
}

pub fn list(db: *Db, gpa: std.mem.Allocator, status: ?Status) ![]Proposal {
    var q = try db.prepare(if (status == null)
        "SELECT id, target, source_task, source_message, evidence, reason, old_hash, proposed, prior_content, status, created, updated, applied_hash FROM learning_proposals ORDER BY id DESC LIMIT 32"
    else
        "SELECT id, target, source_task, source_message, evidence, reason, old_hash, proposed, prior_content, status, created, updated, applied_hash FROM learning_proposals WHERE status = ? ORDER BY id DESC LIMIT 32");
    defer q.finalize();
    if (status) |s| try q.bind(1, @tagName(s));
    var out: std.ArrayList(Proposal) = .empty;
    errdefer {
        for (out.items) |*p| p.deinit(gpa);
        out.deinit(gpa);
    }
    while (try q.step()) {
        try out.ensureUnusedCapacity(gpa, 1);
        out.appendAssumeCapacity(try copy(&q, gpa));
    }
    return out.toOwnedSlice(gpa);
}

pub fn mode(db: *Db) !Mode {
    var q = try db.prepare("SELECT value FROM kv WHERE key = 'learning_mode'");
    defer q.finalize();
    if (!try q.step()) return .propose;
    return std.meta.stringToEnum(Mode, q.text(0)) orelse .propose;
}

pub fn setMode(db: *Db, next: Mode) !void {
    var q = try db.prepare("INSERT INTO kv(key, value) VALUES ('learning_mode', ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value");
    defer q.finalize();
    try q.bind(1, @tagName(next));
    _ = try q.step();
}

fn copy(q: *Stmt, gpa: std.mem.Allocator) !Proposal {
    const target = try gpa.dupe(u8, q.text(1));
    errdefer gpa.free(target);
    const evidence = try gpa.dupe(u8, q.text(4));
    errdefer gpa.free(evidence);
    const reason = try gpa.dupe(u8, q.text(5));
    errdefer gpa.free(reason);
    const old_hash = try gpa.dupe(u8, q.text(6));
    errdefer gpa.free(old_hash);
    const proposed = try gpa.dupe(u8, q.text(7));
    errdefer gpa.free(proposed);
    const prior_content = if (q.isNull(8)) null else try gpa.dupe(u8, q.text(8));
    errdefer if (prior_content) |v| gpa.free(v);
    const applied_hash = if (q.isNull(12)) null else try gpa.dupe(u8, q.text(12));
    errdefer if (applied_hash) |v| gpa.free(v);
    return .{
        .id = q.int(0),
        .target = target,
        .source_task = if (q.isNull(2)) null else q.int(2),
        .source_message = if (q.isNull(3)) null else q.int(3),
        .evidence = evidence,
        .reason = reason,
        .old_hash = old_hash,
        .proposed = proposed,
        .prior_content = prior_content,
        .status = std.meta.stringToEnum(Status, q.text(9)) orelse return error.BadStatus,
        .created = q.int(10),
        .updated = q.int(11),
        .applied_hash = applied_hash,
    };
}

fn changes(db: *Db) !i64 {
    var q = try db.prepare("SELECT changes()");
    defer q.finalize();
    if (!try q.step()) return error.Sqlite;
    return q.int(0);
}

fn validTarget(s: []const u8) bool {
    for (s) |c| if (!(std.ascii.isAlphanumeric(c) or c == '-' or c == '_')) return false;
    return true;
}

test "proposal hash is stable" {
    try std.testing.expectEqual(hash("same"), hash("same"));
}

test "proposal transitions require a pending proposal" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path: [128]u8 = undefined;
    var db = try Db.open(try testkit.tmpPath(&tmp, &path, "zoro.db"));
    defer db.close();
    try db.initSchema();

    const id = try create(&db, "skill-weather", null, null, "Owner asked twice.", "Reuse forecast workflow.", null, "---\nname: weather\ndescription: Forecast\n---\nFetch weather.", 1);
    try setStatus(&db, id, .rejected, 2);
    try std.testing.expectError(error.BadTransition, setStatus(&db, id, .quarantined, 3));
    const p = (try get(&db, std.testing.allocator, id)).?;
    defer {
        var owned = p;
        owned.deinit(std.testing.allocator);
    }
    try std.testing.expectEqual(Status.rejected, p.status);
}

test "apply and rollback have durable intermediate states" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path: [128]u8 = undefined;
    var db = try Db.open(try testkit.tmpPath(&tmp, &path, "zoro.db"));
    defer db.close();
    try db.initSchema();

    const old = hash("");
    const next = hash("new");
    const id = try create(&db, "skill-weather", null, null, "Owner asked twice.", "Reuse forecast workflow.", null, "new", 1);
    try startApply(&db, id, &old, 2);
    try std.testing.expectError(error.BadTransition, startRollback(&db, id, 3));
    try finishApply(&db, id, &next, 4);
    try startRollback(&db, id, 5);
    try finishRollback(&db, id, 6);
    const p = (try get(&db, std.testing.allocator, id)).?;
    defer {
        var owned = p;
        owned.deinit(std.testing.allocator);
    }
    try std.testing.expectEqual(Status.rolled_back, p.status);
}
