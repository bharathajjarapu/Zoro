const std = @import("std");
const Db = @import("db.zig").Db;
const Stmt = @import("db.zig").Stmt;
const secrets = @import("secrets.zig");
const testing = std.testing;

pub const Source = enum {
    owner,
    inferred,

    fn sql(self: Source) []const u8 {
        return switch (self) {
            .owner => "owner",
            .inferred => "inferred",
        };
    }

    fn parse(s: []const u8) Source {
        return if (std.mem.eql(u8, s, "owner")) .owner else .inferred;
    }
};

pub const Fact = struct {
    key: []u8,
    value: []u8,
    source: Source,
    confidence: f64,
    created: i64,
    updated: i64,
    expires: ?i64,

    pub fn deinit(self: *Fact, gpa: std.mem.Allocator) void {
        gpa.free(self.key);
        gpa.free(self.value);
        self.* = undefined;
    }
};

/// Writes a fact. An inferred value never overwrites an owner statement.
pub fn put(db: *Db, key: []const u8, value: []const u8, source: Source, now: i64, expires: ?i64) !void {
    try db.exec("BEGIN");
    errdefer db.exec("ROLLBACK") catch {};

    var q = try db.prepare("SELECT source FROM facts WHERE key = ?");
    defer q.finalize();
    try q.bind(1, key);
    if (try q.step()) {
        if (Source.parse(q.text(0)) == .owner and source == .inferred) {
            try db.exec("COMMIT");
            return;
        }
        var u = try db.prepare(
            "UPDATE facts SET value = ?, source = ?, updated = ?, expires = ? WHERE key = ?",
        );
        defer u.finalize();
        try u.bind(1, value);
        try u.bind(2, source.sql());
        try u.bind(3, now);
        try u.bind(4, expires);
        try u.bind(5, key);
        _ = try u.step();
    } else {
        var ins = try db.prepare(
            \\INSERT INTO facts(key, value, source, confidence, created, updated, expires)
            \\VALUES (?, ?, ?, 1.0, ?, ?, ?)
        );
        defer ins.finalize();
        try ins.bind(1, key);
        try ins.bind(2, value);
        try ins.bind(3, source.sql());
        try ins.bind(4, now);
        try ins.bind(5, now);
        try ins.bind(6, expires);
        _ = try ins.step();
    }
    try reindex(db, "fact", key, value);
    try db.exec("COMMIT");
}

fn reindex(db: *Db, kind: []const u8, ref: []const u8, text: []const u8) !void {
    var del = try db.prepare("DELETE FROM chunks WHERE kind = ? AND ref = ?");
    defer del.finalize();
    try del.bind(1, kind);
    try del.bind(2, ref);
    _ = try del.step();

    var ins = try db.prepare("INSERT INTO chunks(text, kind, ref) VALUES (?, ?, ?)");
    defer ins.finalize();
    try ins.bind(1, text);
    try ins.bind(2, kind);
    try ins.bind(3, ref);
    _ = try ins.step();
}

/// Returns null when missing or expired. Caller owns the fact.
pub fn get(db: *Db, gpa: std.mem.Allocator, key: []const u8, now: i64) !?Fact {
    var q = try db.prepare(
        \\SELECT key, value, source, confidence, created, updated, expires
        \\FROM facts WHERE key = ? AND (expires IS NULL OR expires > ?)
    );
    defer q.finalize();
    try q.bind(1, key);
    try q.bind(2, now);
    if (!try q.step()) return null;

    const k = try gpa.dupe(u8, q.text(0));
    errdefer gpa.free(k);
    const v = try gpa.dupe(u8, q.text(1));
    errdefer gpa.free(v);
    return .{
        .key = k,
        .value = v,
        .source = .parse(q.text(2)),
        .confidence = q.float(3),
        .created = q.int(4),
        .updated = q.int(5),
        .expires = if (q.isNull(6)) null else q.int(6),
    };
}

pub fn forget(db: *Db, key: []const u8) !void {
    try db.exec("BEGIN");
    errdefer db.exec("ROLLBACK") catch {};
    var del = try db.prepare("DELETE FROM facts WHERE key = ?");
    defer del.finalize();
    try del.bind(1, key);
    _ = try del.step();
    var chunk = try db.prepare("DELETE FROM chunks WHERE kind = 'fact' AND ref = ?");
    defer chunk.finalize();
    try chunk.bind(1, key);
    _ = try chunk.step();
    try db.exec("COMMIT");
}

pub const Hit = struct {
    text: []u8,
    kind: []u8,
    ref: []u8,
    score: f64,

    fn deinit(self: Hit, gpa: std.mem.Allocator) void {
        gpa.free(self.text);
        gpa.free(self.kind);
        gpa.free(self.ref);
    }
};

pub fn freeHits(gpa: std.mem.Allocator, hits: []Hit) void {
    for (hits) |h| h.deinit(gpa);
    gpa.free(hits);
}

/// BM25 over diary and fact chunks. Tokens are ANDed (precise lookup).
/// Caller owns the slice.
pub fn search(db: *Db, gpa: std.mem.Allocator, query: []const u8, now: i64, limit: i64) ![]Hit {
    return searchJoin(db, gpa, query, now, limit, false);
}

/// Like `search`, but ORs tokens so a chat sentence still recalls.
pub fn searchAny(db: *Db, gpa: std.mem.Allocator, query: []const u8, now: i64, limit: i64) ![]Hit {
    return searchJoin(db, gpa, query, now, limit, true);
}

fn searchJoin(db: *Db, gpa: std.mem.Allocator, query: []const u8, now: i64, limit: i64, any: bool) ![]Hit {
    const match = try expandQuery(db, gpa, query, any);
    defer gpa.free(match);
    if (match.len == 0 or limit <= 0) return &.{};

    var q = try db.prepare(
        \\SELECT chunks.text, chunks.kind, chunks.ref, bm25(chunks),
        \\       COALESCE(facts.source, ''),
        \\       COALESCE(facts.updated, diary.created, 0),
        \\       COALESCE(facts.confidence, 1.0)
        \\FROM chunks
        \\LEFT JOIN facts ON chunks.kind = 'fact' AND chunks.ref = facts.key
        \\LEFT JOIN diary ON chunks.kind = 'diary' AND chunks.ref = diary.day
        \\WHERE chunks MATCH ?
        \\  AND (chunks.kind = 'diary' OR (facts.key IS NOT NULL AND (facts.expires IS NULL OR facts.expires > ?)))
        \\LIMIT ?
    );
    defer q.finalize();
    try q.bind(1, match);
    try q.bind(2, now);
    // ponytail: reweight the top 64 BM25 hits. Raise the cap if an owner
    // fact that should rank in the caller's limit is getting cut.
    try q.bind(3, @max(limit, 64));

    var out: std.ArrayList(Hit) = .empty;
    errdefer {
        for (out.items) |h| h.deinit(gpa);
        out.deinit(gpa);
    }
    while (try q.step()) {
        const hit = try readHit(&q, gpa, reweight(q.float(3), q.text(4), q.int(5), q.float(6), now));
        out.append(gpa, hit) catch |err| {
            hit.deinit(gpa);
            return err;
        };
    }
    std.mem.sort(Hit, out.items, {}, struct {
        fn lt(_: void, a: Hit, b: Hit) bool {
            return a.score < b.score;
        }
    }.lt);
    const cap: usize = @intCast(limit);
    if (out.items.len > cap) {
        for (out.items[cap..]) |h| h.deinit(gpa);
        out.items.len = cap;
    }
    return out.toOwnedSlice(gpa);
}

fn reweight(bm25: f64, source: []const u8, updated: i64, confidence: f64, now: i64) f64 {
    const src: f64 = if (Source.parse(source) == .owner) 2.0 else 1.0;
    const age: f64 = @floatFromInt(@max(@as(i64, 0), now - updated));
    const recency = 1.0 / (1.0 + age / (30 * 24 * 60 * 60));
    return bm25 * src * recency * confidence;
}

fn readHit(q: *Stmt, gpa: std.mem.Allocator, score: f64) !Hit {
    const text = try gpa.dupe(u8, q.text(0));
    errdefer gpa.free(text);
    const kind = try gpa.dupe(u8, q.text(1));
    errdefer gpa.free(kind);
    const ref = try gpa.dupe(u8, q.text(2));
    errdefer gpa.free(ref);
    return .{ .text = text, .kind = kind, .ref = ref, .score = score };
}

/// Stores a retrieval synonym. `vet` → `veterinarian` is the load-bearing case
/// porter stemming does not cover.
pub fn putAlias(db: *Db, word: []const u8, meaning: []const u8) !void {
    var key_buf: [72]u8 = undefined;
    const key = aliasKey(&key_buf, word) orelse return error.AliasTooLong;
    var ins = try db.prepare(
        "INSERT INTO kv(key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
    );
    defer ins.finalize();
    try ins.bind(1, key);
    try ins.bind(2, meaning);
    _ = try ins.step();
}

pub const Extracted = struct {
    key: []const u8,
    value: []const u8,
};

const Fail = enum { none, summarize, facts, write, commit, delete };

/// Compacts one day's messages into the diary file and index, then deletes
/// the raw rows. `facts` are durable extracts (empty is fine). Order is
/// load-bearing: summarize → facts → write+fsync → commit → delete.
pub fn compact(
    db: *Db,
    gpa: std.mem.Allocator,
    io: std.Io,
    dir: []const u8,
    day: []const u8,
    now: i64,
    facts: []const Extracted,
) !void {
    return compactAt(db, gpa, io, dir, day, now, facts, .none);
}

fn compactAt(
    db: *Db,
    gpa: std.mem.Allocator,
    io: std.Io,
    dir: []const u8,
    day: []const u8,
    now: i64,
    facts: []const Extracted,
    fail: Fail,
) !void {
    const start = try parseDay(day);
    if (fail == .summarize) return error.Injected;

    const raw = try summarizeDay(db, gpa, start);
    defer gpa.free(raw);
    if (raw.len == 0) return;
    const summary = try secrets.redact(db, gpa, raw);
    defer gpa.free(summary);

    if (fail == .facts) return error.Injected;
    for (facts) |f| try put(db, f.key, f.value, .inferred, now, null);

    if (fail == .write) return error.Injected;
    try writeDiaryFile(io, dir, day, summary);

    if (fail == .commit) return error.Injected;
    try indexDiary(db, day, summary, now);

    if (fail == .delete) return error.Injected;
    try deleteDay(db, start);
}

/// Caller owns the bytes. Null when the file is missing.
pub fn readDiary(gpa: std.mem.Allocator, io: std.Io, dir: []const u8, day: []const u8) !?[]u8 {
    var d = std.Io.Dir.cwd().openDir(io, dir, .{}) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer d.close(io);
    var name: [16]u8 = undefined;
    const file_name = try diaryName(&name, day);
    return d.readFileAlloc(io, file_name, gpa, .limited(1 * 1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => null,
        else => err,
    };
}

/// UTC calendar day for `ts`. `buf` must be at least 10 bytes.
pub fn formatDay(buf: []u8, ts: i64) []const u8 {
    const secs: u64 = @intCast(@max(ts, 0));
    const yd = std.time.epoch.EpochSeconds{ .secs = secs };
    const year_day = yd.getEpochDay().calculateYearDay();
    const md = year_day.calculateMonthDay();
    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}", .{
        year_day.year,
        md.month.numeric(),
        md.day_index + 1,
    }) catch unreachable;
}

pub fn parseDay(s: []const u8) !i64 {
    if (s.len != 10 or s[4] != '-' or s[7] != '-') return error.BadDay;
    const y = try std.fmt.parseInt(u16, s[0..4], 10);
    const m = try std.fmt.parseInt(u4, s[5..7], 10);
    const d = try std.fmt.parseInt(u8, s[8..10], 10);
    if (m < 1 or m > 12 or d < 1 or y < 1970) return error.BadDay;
    const month: std.time.epoch.Month = @enumFromInt(m);
    if (d > std.time.epoch.getDaysInMonth(y, month)) return error.BadDay;

    var days: i64 = 0;
    var year: u16 = 1970;
    while (year < y) : (year += 1) {
        days += std.time.epoch.getDaysInYear(year);
    }
    var i: u4 = 1;
    while (i < m) : (i += 1) {
        days += std.time.epoch.getDaysInMonth(y, @enumFromInt(i));
    }
    days += d - 1;
    return days * 86_400;
}

fn summarizeDay(db: *Db, gpa: std.mem.Allocator, start: i64) ![]u8 {
    var q = try db.prepare(
        \\SELECT role, content FROM messages
        \\WHERE created >= ? AND created < ?
        \\ORDER BY id
    );
    defer q.finalize();
    try q.bind(1, start);
    try q.bind(2, start + 86_400);

    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    var w = &out.writer;
    var any = false;
    while (try q.step()) {
        if (!any) {
            var buf: [10]u8 = undefined;
            try w.print("# {s}\n\n", .{formatDay(&buf, start)});
            any = true;
        }
        try w.print("**{s}:** {s}\n\n", .{ q.text(0), q.text(1) });
    }
    if (!any) return try gpa.dupe(u8, "");
    return try out.toOwnedSlice();
}

fn writeDiaryFile(io: std.Io, dir: []const u8, day: []const u8, summary: []const u8) !void {
    try std.Io.Dir.cwd().createDirPath(io, dir);
    var d = try std.Io.Dir.cwd().openDir(io, dir, .{});
    defer d.close(io);
    var name: [16]u8 = undefined;
    const file_name = try diaryName(&name, day);
    var f = try d.createFile(io, file_name, .{});
    defer f.close(io);
    try f.writeStreamingAll(io, summary);
    try f.sync(io);
}

fn diaryName(buf: []u8, day: []const u8) ![]u8 {
    return std.fmt.bufPrint(buf, "{s}.md", .{day});
}

fn deleteDay(db: *Db, start: i64) !void {
    var q = try db.prepare("DELETE FROM messages WHERE created >= ? AND created < ?");
    defer q.finalize();
    try q.bind(1, start);
    try q.bind(2, start + 86_400);
    _ = try q.step();
}

/// Writes a diary row and its FTS chunk in one transaction. Ticket 10 owns
/// the file + fsync; this is the machine index.
pub fn indexDiary(db: *Db, day: []const u8, summary: []const u8, now: i64) !void {
    try db.exec("BEGIN");
    errdefer db.exec("ROLLBACK") catch {};
    var ins = try db.prepare(
        "INSERT INTO diary(day, summary, created) VALUES (?, ?, ?) ON CONFLICT(day) DO UPDATE SET summary = excluded.summary",
    );
    defer ins.finalize();
    try ins.bind(1, day);
    try ins.bind(2, summary);
    try ins.bind(3, now);
    _ = try ins.step();
    try reindex(db, "diary", day, summary);
    try db.exec("COMMIT");
}

fn expandQuery(db: *Db, gpa: std.mem.Allocator, query: []const u8, any: bool) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);

    const join: []const u8 = if (any) " OR " else " AND ";
    var rest = query;
    var buf: [64]u8 = undefined;
    while (nextToken(&rest, &buf)) |tok| {
        if (isOperator(tok)) continue;
        if (any and tok.len <= 2) continue;
        if (out.items.len != 0) try out.appendSlice(gpa, join);
        if (try lookupAlias(db, gpa, tok)) |meaning| {
            defer gpa.free(meaning);
            try out.appendSlice(gpa, "(");
            try out.appendSlice(gpa, tok);
            try out.appendSlice(gpa, " OR ");
            try out.appendSlice(gpa, meaning);
            try out.appendSlice(gpa, ")");
        } else {
            try out.appendSlice(gpa, tok);
        }
    }
    return out.toOwnedSlice(gpa);
}

fn lookupAlias(db: *Db, gpa: std.mem.Allocator, word: []const u8) !?[]u8 {
    var key_buf: [72]u8 = undefined;
    const key = aliasKey(&key_buf, word) orelse return null;
    var q = try db.prepare("SELECT value FROM kv WHERE key = ?");
    defer q.finalize();
    try q.bind(1, key);
    if (!try q.step()) return null;
    return try gpa.dupe(u8, q.text(0));
}

fn aliasKey(buf: []u8, word: []const u8) ?[]u8 {
    const prefix = "alias:";
    if (prefix.len + word.len > buf.len) return null;
    @memcpy(buf[0..prefix.len], prefix);
    for (word, 0..) |b, i| buf[prefix.len + i] = std.ascii.toLower(b);
    return buf[0 .. prefix.len + word.len];
}

fn nextToken(rest: *[]const u8, buf: []u8) ?[]u8 {
    var s = rest.*;
    while (s.len > 0 and !std.ascii.isAlphanumeric(s[0])) s = s[1..];
    var n: usize = 0;
    while (n < s.len and std.ascii.isAlphanumeric(s[n])) : (n += 1) {}
    rest.* = s[n..];
    if (n == 0) return null;
    const take = @min(n, buf.len);
    for (s[0..take], 0..) |b, i| buf[i] = std.ascii.toLower(b);
    return buf[0..take];
}

fn isOperator(tok: []const u8) bool {
    return std.ascii.eqlIgnoreCase(tok, "AND") or
        std.ascii.eqlIgnoreCase(tok, "OR") or
        std.ascii.eqlIgnoreCase(tok, "NOT") or
        std.ascii.eqlIgnoreCase(tok, "NEAR");
}

fn tmpPath(tmp: *testing.TmpDir, buf: []u8) ![:0]u8 {
    return std.fmt.bufPrintZ(buf, ".zig-cache/tmp/{s}/zoro.db", .{tmp.sub_path});
}

fn insertMsg(db: *Db, role: []const u8, content: []const u8, created: i64) !void {
    var q = try db.prepare("INSERT INTO messages(role, content, created) VALUES (?, ?, ?)");
    defer q.finalize();
    try q.bind(1, role);
    try q.bind(2, content);
    try q.bind(3, created);
    _ = try q.step();
}

fn countMsgs(db: *Db) !i64 {
    var q = try db.prepare("SELECT COUNT(*) FROM messages");
    defer q.finalize();
    try testing.expect(try q.step());
    return q.int(0);
}

test "a fact survives closing and reopening the database" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [128]u8 = undefined;
    const path = try tmpPath(&tmp, &buf);

    {
        var db = try Db.open(path);
        defer db.close();
        try db.migrate();
        try put(&db, "pet", "a black cat named mittens", .owner, 1000, null);
    }

    var db = try Db.open(path);
    defer db.close();
    var got = try get(&db, testing.allocator, "pet", 1000) orelse return error.MissingFact;
    defer got.deinit(testing.allocator);
    try testing.expectEqualStrings("a black cat named mittens", got.value);
}

test "porter stemming matches inflections" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [128]u8 = undefined;
    var db = try Db.open(try tmpPath(&tmp, &buf));
    defer db.close();
    try db.migrate();

    try put(&db, "cal", "booked the appointment for tuesday", .owner, 1000, null);
    const hits = try search(&db, testing.allocator, "appointments", 1000, 8);
    defer freeHits(testing.allocator, hits);
    try testing.expectEqual(@as(usize, 1), hits.len);
    try testing.expectEqualStrings("cal", hits[0].ref);
}

test "an alias makes vet find veterinarian" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [128]u8 = undefined;
    var db = try Db.open(try tmpPath(&tmp, &buf));
    defer db.close();
    try db.migrate();

    try put(&db, "clinic", "the veterinarian is on oak street", .owner, 1000, null);
    {
        const hits = try search(&db, testing.allocator, "vet", 1000, 8);
        defer freeHits(testing.allocator, hits);
        try testing.expectEqual(@as(usize, 0), hits.len);
    }
    try putAlias(&db, "vet", "veterinarian");
    const hits = try search(&db, testing.allocator, "vet", 1000, 8);
    defer freeHits(testing.allocator, hits);
    try testing.expectEqual(@as(usize, 1), hits.len);
    try testing.expectEqualStrings("clinic", hits[0].ref);
}

test "alias expansion keeps other query terms" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [128]u8 = undefined;
    var db = try Db.open(try tmpPath(&tmp, &buf));
    defer db.close();
    try db.migrate();

    try put(&db, "weather", "the weather is nice today", .owner, 1000, null);
    try put(&db, "clinic", "the veterinarian is on oak street", .owner, 1000, null);
    try putAlias(&db, "vet", "veterinarian");
    const hits = try search(&db, testing.allocator, "the vet", 1000, 8);
    defer freeHits(testing.allocator, hits);
    try testing.expectEqual(@as(usize, 1), hits.len);
    try testing.expectEqualStrings("clinic", hits[0].ref);
}

test "raw messages are never indexed" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [128]u8 = undefined;
    var db = try Db.open(try tmpPath(&tmp, &buf));
    defer db.close();
    try db.migrate();

    try put(&db, "pet", "a black cat named mittens", .owner, 1000, null);
    try db.exec("INSERT INTO messages(role, content, created) VALUES ('user', 'secretwordxyz never in a fact', 1000)");

    {
        const hits = try search(&db, testing.allocator, "secretwordxyz", 1000, 8);
        defer freeHits(testing.allocator, hits);
        try testing.expectEqual(@as(usize, 0), hits.len);
    }
    const hits = try search(&db, testing.allocator, "mittens", 1000, 8);
    defer freeHits(testing.allocator, hits);
    try testing.expectEqual(@as(usize, 1), hits.len);
}

test "diary entries are indexed" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [128]u8 = undefined;
    var db = try Db.open(try tmpPath(&tmp, &buf));
    defer db.close();
    try db.migrate();

    try indexDiary(&db, "2026-08-21", "walked the dog at sunrise", 1000);
    const hits = try search(&db, testing.allocator, "walked", 1000, 8);
    defer freeHits(testing.allocator, hits);
    try testing.expectEqual(@as(usize, 1), hits.len);
    try testing.expectEqualStrings("diary", hits[0].kind);
    try testing.expectEqualStrings("2026-08-21", hits[0].ref);
}

test "expired facts are not returned" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [128]u8 = undefined;
    var db = try Db.open(try tmpPath(&tmp, &buf));
    defer db.close();
    try db.migrate();

    try put(&db, "temp", "the plumber comes on friday", .owner, 10, 50);
    try testing.expect(try get(&db, testing.allocator, "temp", 50) == null);
    try testing.expect(try get(&db, testing.allocator, "temp", 51) == null);
    var live = try get(&db, testing.allocator, "temp", 49) orelse return error.MissingFact;
    defer live.deinit(testing.allocator);
    try testing.expectEqualStrings("the plumber comes on friday", live.value);

    {
        const hits = try search(&db, testing.allocator, "plumber", 51, 8);
        defer freeHits(testing.allocator, hits);
        try testing.expectEqual(@as(usize, 0), hits.len);
    }
    const hits = try search(&db, testing.allocator, "plumber", 49, 8);
    defer freeHits(testing.allocator, hits);
    try testing.expectEqual(@as(usize, 1), hits.len);
}

test "an inferred fact does not overwrite an owner statement" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [128]u8 = undefined;
    var db = try Db.open(try tmpPath(&tmp, &buf));
    defer db.close();
    try db.migrate();

    try put(&db, "clinic", "oak street", .owner, 1000, null);
    try put(&db, "clinic", "maple street", .inferred, 2000, null);
    var got = try get(&db, testing.allocator, "clinic", 2000) orelse return error.MissingFact;
    defer got.deinit(testing.allocator);
    try testing.expectEqualStrings("oak street", got.value);
    try testing.expectEqual(Source.owner, got.source);

    try put(&db, "pet", "maybe a dog", .inferred, 1000, null);
    try put(&db, "pet", "a black cat", .owner, 2000, null);
    var pet = try get(&db, testing.allocator, "pet", 2000) orelse return error.MissingFact;
    defer pet.deinit(testing.allocator);
    try testing.expectEqualStrings("a black cat", pet.value);
    try testing.expectEqual(Source.owner, pet.source);
}

test "forget removes a fact from lookup and search" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [128]u8 = undefined;
    var db = try Db.open(try tmpPath(&tmp, &buf));
    defer db.close();
    try db.migrate();

    try put(&db, "pet", "a black cat named mittens", .owner, 1000, null);
    try forget(&db, "pet");
    try testing.expect(try get(&db, testing.allocator, "pet", 1000) == null);
    const hits = try search(&db, testing.allocator, "mittens", 1000, 8);
    defer freeHits(testing.allocator, hits);
    try testing.expectEqual(@as(usize, 0), hits.len);
}

test "owner facts rank above inferred facts with the same text" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [128]u8 = undefined;
    var db = try Db.open(try tmpPath(&tmp, &buf));
    defer db.close();
    try db.migrate();

    try put(&db, "guess", "the cat sat on the mat", .inferred, 1000, null);
    try put(&db, "told", "the cat sat on the mat", .owner, 1000, null);
    const hits = try search(&db, testing.allocator, "cat", 1000, 8);
    defer freeHits(testing.allocator, hits);
    try testing.expectEqual(@as(usize, 2), hits.len);
    try testing.expectEqualStrings("told", hits[0].ref);
    try testing.expect(hits[0].score < hits[1].score);
}

test "recent facts rank above older facts with the same text" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [128]u8 = undefined;
    var db = try Db.open(try tmpPath(&tmp, &buf));
    defer db.close();
    try db.migrate();

    const month: i64 = 30 * 24 * 60 * 60;
    try put(&db, "old", "the cat sat on the mat", .inferred, 1000, null);
    try put(&db, "new", "the cat sat on the mat", .inferred, 1000 + month, null);
    const hits = try search(&db, testing.allocator, "cat", 1000 + month, 8);
    defer freeHits(testing.allocator, hits);
    try testing.expectEqual(@as(usize, 2), hits.len);
    try testing.expectEqualStrings("new", hits[0].ref);
    try testing.expect(hits[0].score < hits[1].score);
}

test "compaction writes a diary file and deletes that day's messages" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [128]u8 = undefined;
    var db = try Db.open(try tmpPath(&tmp, &buf));
    defer db.close();
    try db.migrate();

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const day = "2026-08-20";
    const start = try parseDay(day);
    try insertMsg(&db, "user", "walked the dog at sunrise", start + 10);
    try insertMsg(&db, "assistant", "nice, that's a good start", start + 20);
    try insertMsg(&db, "user", "tomorrow's note", start + 86_400);

    const diary_dir = try std.fmt.bufPrint(&buf, ".zig-cache/tmp/{s}/diary", .{tmp.sub_path});
    const facts = [_]Extracted{.{ .key = "pet_walk", .value = "walks the dog at sunrise" }};
    try compact(&db, testing.allocator, io, diary_dir, day, start + 30, &facts);

    const text = try readDiary(testing.allocator, io, diary_dir, day) orelse return error.MissingDiary;
    defer testing.allocator.free(text);
    try testing.expect(std.mem.indexOf(u8, text, "walked the dog at sunrise") != null);
    try testing.expect(std.mem.indexOf(u8, text, "tomorrow's note") == null);

    try testing.expectEqual(@as(i64, 1), try countMsgs(&db));
    var pet = try get(&db, testing.allocator, "pet_walk", start) orelse return error.MissingFact;
    defer pet.deinit(testing.allocator);
    try testing.expectEqualStrings("walks the dog at sunrise", pet.value);

    const hits = try search(&db, testing.allocator, "sunrise", start, 8);
    defer freeHits(testing.allocator, hits);
    try testing.expect(hits.len >= 1);
}

test "a failure at each compaction step leaves raw messages intact" {
    const steps = [_]Fail{ .summarize, .facts, .write, .commit, .delete };
    for (steps) |step| {
        var tmp = testing.tmpDir(.{});
        defer tmp.cleanup();
        var buf: [128]u8 = undefined;
        var db = try Db.open(try tmpPath(&tmp, &buf));
        defer db.close();
        try db.migrate();

        var threaded: std.Io.Threaded = .init(testing.allocator, .{});
        defer threaded.deinit();
        const io = threaded.io();

        const day = "2026-08-20";
        const start = try parseDay(day);
        try insertMsg(&db, "user", "keep this", start + 1);

        const diary_dir = try std.fmt.bufPrint(&buf, ".zig-cache/tmp/{s}/diary", .{tmp.sub_path});
        const facts = [_]Extracted{.{ .key = "k", .value = "v" }};
        try testing.expectError(error.Injected, compactAt(
            &db,
            testing.allocator,
            io,
            diary_dir,
            day,
            start,
            &facts,
            step,
        ));
        try testing.expectEqual(@as(i64, 1), try countMsgs(&db));
    }
}

test "compaction can be retried after a failed commit" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [128]u8 = undefined;
    var db = try Db.open(try tmpPath(&tmp, &buf));
    defer db.close();
    try db.migrate();

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const day = "2026-08-20";
    const start = try parseDay(day);
    try insertMsg(&db, "user", "retried day", start + 1);
    const diary_dir = try std.fmt.bufPrint(&buf, ".zig-cache/tmp/{s}/diary", .{tmp.sub_path});

    try testing.expectError(error.Injected, compactAt(
        &db,
        testing.allocator,
        io,
        diary_dir,
        day,
        start,
        &.{},
        .commit,
    ));
    try compact(&db, testing.allocator, io, diary_dir, day, start, &.{});
    try testing.expectEqual(@as(i64, 0), try countMsgs(&db));
    const text = try readDiary(testing.allocator, io, diary_dir, day) orelse return error.MissingDiary;
    defer testing.allocator.free(text);
    try testing.expect(std.mem.indexOf(u8, text, "retried day") != null);
}

test "compaction redacts secret values from the diary" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [128]u8 = undefined;
    var db = try Db.open(try tmpPath(&tmp, &buf));
    defer db.close();
    try db.migrate();

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const day = "2026-08-20";
    const start = try parseDay(day);
    try secrets.put(&db, "weather_api_key", "sk-secret-value", "api.weather.com", start);
    try insertMsg(&db, "user", "the key is sk-secret-value", start + 10);

    const diary_dir = try std.fmt.bufPrint(&buf, ".zig-cache/tmp/{s}/diary", .{tmp.sub_path});
    try compact(&db, testing.allocator, io, diary_dir, day, start + 30, &.{});

    const text = try readDiary(testing.allocator, io, diary_dir, day) orelse return error.MissingDiary;
    defer testing.allocator.free(text);
    try testing.expect(std.mem.indexOf(u8, text, "sk-secret-value") == null);
    try testing.expect(std.mem.indexOf(u8, text, "[secret:weather_api_key]") != null);
}
