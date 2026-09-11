const std = @import("std");
const agent = @import("../agent/root.zig");
const memory = @import("../data/memory.zig");
const tasks = @import("../data/tasks.zig");
const outbox = @import("../data/outbox.zig");
const Db = @import("../data/db.zig").Db;
const Agent = agent.Agent;
const testing = std.testing;
const testkit = @import("../testing/testkit.zig");
const FakeHttp = testkit.FakeHttp;

pub const max_prompt = 64 * 1024;

/// Joins arguments into `buf`; returns null when empty.
pub fn takePrompt(buf: []u8, args: anytype) error{StreamTooLong}!?[]u8 {
    var n: usize = 0;
    while (args.next()) |part| {
        if (n != 0) {
            if (n >= buf.len) return error.StreamTooLong;
            buf[n] = ' ';
            n += 1;
        }
        if (part.len > buf.len - n) return error.StreamTooLong;
        @memcpy(buf[n..][0..part.len], part);
        n += part.len;
    }
    return if (n == 0) null else buf[0..n];
}

pub fn oneShot(a: *Agent, prompt: []const u8, out: *std.Io.Writer) !void {
    const reply = try a.turn(prompt);
    defer a.gpa.free(reply);
    try writeReply(out, reply);
    try drain(a, out);
}

pub fn chat(a: *Agent, in: *std.Io.Reader, out: *std.Io.Writer, err_out: *std.Io.Writer) !void {
    try err_out.writeAll("zoro chat (:q to quit)\n");
    try err_out.flush();
    while (true) {
        try err_out.writeAll("zoro> ");
        try err_out.flush();
        const line = (try in.takeDelimiter('\n')) orelse break;
        const text = std.mem.trim(u8, stripCr(line), &std.ascii.whitespace);
        if (text.len == 0) continue;
        if (isQuit(text)) break;
        const reply = try a.turn(text);
        defer a.gpa.free(reply);
        try writeReply(out, reply);
        try drain(a, out);
    }
}

/// Prints output queued outside the agent.
fn drain(a: *Agent, out: *std.Io.Writer) !void {
    const items = try outbox.drain(a.db, a.gpa);
    defer outbox.free(a.gpa, items);
    for (items) |item| {
        if (item.path) |p| try out.print("[{s}] {s}\n", .{ @tagName(item.kind), p });
        if (item.text.len != 0) try writeReply(out, item.text);
    }
    try out.flush();
}

fn writeReply(out: *std.Io.Writer, reply: []const u8) !void {
    try out.writeAll(reply);
    if (reply.len == 0 or reply[reply.len - 1] != '\n') try out.writeByte('\n');
    try out.flush();
}

fn stripCr(line: []const u8) []const u8 {
    return if (std.mem.endsWith(u8, line, "\r")) line[0 .. line.len - 1] else line;
}

fn isQuit(s: []const u8) bool {
    return std.mem.eql(u8, s, ":q") or std.mem.eql(u8, s, ":quit");
}

pub fn printDiary(
    gpa: std.mem.Allocator,
    io: std.Io,
    dir: []const u8,
    date: ?[]const u8,
    now: i64,
    out: *std.Io.Writer,
) !void {
    var buf: [10]u8 = undefined;
    const day = resolveDay(&buf, date, now) catch {
        try out.print("bad date: {s}\n", .{date.?});
        try out.flush();
        return;
    };
    const text = try memory.readDiary(gpa, io, dir, day) orelse {
        try out.print("no diary for {s}\n", .{day});
        try out.flush();
        return;
    };
    defer gpa.free(text);
    try writeReply(out, text);
}

pub fn printMemory(db: *Db, gpa: std.mem.Allocator, query: []const u8, now: i64, out: *std.Io.Writer) !void {
    const hits = try memory.search(db, gpa, query, now, 16);
    defer memory.freeHits(gpa, hits);
    if (hits.len == 0) {
        try out.writeAll("no hits\n");
        try out.flush();
        return;
    }
    for (hits) |h| {
        try out.print("{s}\t{s}\t{d:.4}\n", .{ h.ref, h.kind, h.score });
    }
    try out.flush();
}

pub fn printTasks(db: *Db, gpa: std.mem.Allocator, out: *std.Io.Writer) !void {
    const items = try tasks.list(db, gpa);
    defer tasks.freeTasks(gpa, items);
    const text = try tasks.formatList(gpa, items);
    defer gpa.free(text);
    try writeReply(out, text);
}

pub fn printRoutines(db: *Db, out: *std.Io.Writer) !void {
    var q = try db.prepare(
        \\SELECT name, enabled, COALESCE(status, '-'), fails, skips,
        \\       COALESCE(next, 0), COALESCE(last, 0)
        \\FROM routines ORDER BY name
    );
    defer q.finalize();
    var n: usize = 0;
    while (try q.step()) : (n += 1) {
        try out.print("{s} {s} status={s} fails={d} skips={d} next={d} last={d}\n", .{
            q.text(0),
            if (q.int(1) == 1) "on" else "off",
            q.text(2),
            q.int(3),
            q.int(4),
            q.int(5),
            q.int(6),
        });
    }
    if (n == 0) try out.writeAll("no routines\n");
    try out.flush();
}

fn resolveDay(buf: *[10]u8, date: ?[]const u8, now: i64) ![]const u8 {
    const arg = date orelse return memory.formatDay(buf, now);
    if (std.mem.eql(u8, arg, "today")) return memory.formatDay(buf, now);
    if (std.mem.eql(u8, arg, "yesterday")) return memory.formatDay(buf, now - 86_400);
    _ = memory.parseDay(arg) catch return error.BadDay;
    if (arg.len != 10) return error.BadDay;
    return arg;
}

test "run prints the stubbed reply and exits" {
    var h: Harness = undefined;
    try h.init(&.{"{\"choices\":[{\"message\":{\"content\":\"hello back\"}}]}"});
    defer h.deinit();

    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();

    try oneShot(&h.agent, "hello", &out.writer);
    try testing.expectEqualStrings("hello back\n", out.written());
}

test "chat holds a multi-turn conversation over stdin" {
    var h: Harness = undefined;
    try h.init(&.{
        "{\"choices\":[{\"message\":{\"content\":\"hi\"}}]}",
        "{\"choices\":[{\"message\":{\"content\":\"later\"}}]}",
    });
    defer h.deinit();

    var in: std.Io.Reader = .fixed("hello\nagain\n");
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    var err_out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer err_out.deinit();

    try chat(&h.agent, &in, &out.writer, &err_out.writer);
    try testing.expectEqualStrings("hi\nlater\n", out.written());
}

test "chat skips blanks and quits on :q" {
    var h: Harness = undefined;
    try h.init(&.{"{\"choices\":[{\"message\":{\"content\":\"ok\"}}]}"});
    defer h.deinit();

    var in: std.Io.Reader = .fixed("hello\n  \n:q\nignored\n");
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    var err_out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer err_out.deinit();

    try chat(&h.agent, &in, &out.writer, &err_out.writer);
    try testing.expectEqualStrings("ok\n", out.written());
}

test "takePrompt joins args and rejects overflow" {
    var buf: [16]u8 = undefined;
    var it: SliceIter = .{ .items = &.{ "hello", "zig" } };
    try testing.expectEqualStrings("hello zig", (try takePrompt(&buf, &it)).?);

    var empty: SliceIter = .{ .items = &.{} };
    try testing.expect(try takePrompt(&buf, &empty) == null);

    var long: SliceIter = .{ .items = &.{"abcdefghijklmnopqrstuvwxyz"} };
    try testing.expectError(error.StreamTooLong, takePrompt(buf[0..8], &long));
}

const SliceIter = struct {
    items: []const []const u8,
    i: usize = 0,
    fn next(self: *SliceIter) ?[]const u8 {
        if (self.i >= self.items.len) return null;
        const s = self.items[self.i];
        self.i += 1;
        return s;
    }
};

test "diary prints a day's file and reports a missing day clearly" {
    var h: Harness = undefined;
    try h.init(&.{"{\"choices\":[{\"message\":{\"content\":\"x\"}}]}"});
    defer h.deinit();

    const diary_dir = try std.fmt.bufPrint(&h.path_buf, ".zig-cache/tmp/{s}/diary", .{h.tmp.sub_path});
    try std.Io.Dir.cwd().createDirPath(h.agent.io, diary_dir);
    var d = try std.Io.Dir.cwd().openDir(h.agent.io, diary_dir, .{});
    defer d.close(h.agent.io);
    try d.writeFile(h.agent.io, .{ .sub_path = "2026-08-20.md", .data = "# 2026-08-20\n\nwalked the dog\n" });

    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try printDiary(testing.allocator, h.agent.io, diary_dir, "2026-08-20", 0, &out.writer);
    try testing.expect(std.mem.indexOf(u8, out.written(), "walked the dog") != null);

    var missing: std.Io.Writer.Allocating = .init(testing.allocator);
    defer missing.deinit();
    try printDiary(testing.allocator, h.agent.io, diary_dir, "2026-08-21", 0, &missing.writer);
    try testing.expectEqualStrings("no diary for 2026-08-21\n", missing.written());
}

test "diary with no date argument defaults to today" {
    var h: Harness = undefined;
    try h.init(&.{"{\"choices\":[{\"message\":{\"content\":\"x\"}}]}"});
    defer h.deinit();

    const now: i64 = 1_755_648_000; // 2026-08-20 00:00 UTC
    var day: [10]u8 = undefined;
    const today = memory.formatDay(&day, now);
    const diary_dir = try std.fmt.bufPrint(&h.path_buf, ".zig-cache/tmp/{s}/diary", .{h.tmp.sub_path});
    try std.Io.Dir.cwd().createDirPath(h.agent.io, diary_dir);
    var d = try std.Io.Dir.cwd().openDir(h.agent.io, diary_dir, .{});
    defer d.close(h.agent.io);
    var name: [16]u8 = undefined;
    try d.writeFile(h.agent.io, .{
        .sub_path = try std.fmt.bufPrint(&name, "{s}.md", .{today}),
        .data = "today's log\n",
    });

    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try printDiary(testing.allocator, h.agent.io, diary_dir, null, now, &out.writer);
    try testing.expectEqualStrings("today's log\n", out.written());
}

test "memory prints ref, kind, and score per hit" {
    var h: Harness = undefined;
    try h.init(&.{"{\"choices\":[{\"message\":{\"content\":\"x\"}}]}"});
    defer h.deinit();

    try memory.put(h.agent.db, "pet", "a black cat named mittens", .owner, 1000, null);

    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try printMemory(h.agent.db, testing.allocator, "mittens", 1000, &out.writer);
    try testing.expect(std.mem.indexOf(u8, out.written(), "pet") != null);
    try testing.expect(std.mem.indexOf(u8, out.written(), "fact") != null);
    try testing.expect(std.mem.indexOf(u8, out.written(), ".") != null);
}

test "tasks lists parent and child with status, priority, and goal" {
    var h: Harness = undefined;
    try h.init(&.{"{\"choices\":[{\"message\":{\"content\":\"x\"}}]}"});
    defer h.deinit();

    const parent = try tasks.create(h.agent.db, "research", "notes written", 0, null, 2);
    _ = try tasks.create(h.agent.db, "fetch sources", "three urls saved", 0, parent, 0);

    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try printTasks(h.agent.db, testing.allocator, &out.writer);
    try testing.expect(std.mem.indexOf(u8, out.written(), "research") != null);
    try testing.expect(std.mem.indexOf(u8, out.written(), "queued") != null);
    try testing.expect(std.mem.indexOf(u8, out.written(), "prio=2") != null);
    try testing.expect(std.mem.indexOf(u8, out.written(), "notes written") != null);
    try testing.expect(std.mem.indexOf(u8, out.written(), "  #") != null);
}

const Harness = struct {
    tmp: testing.TmpDir,
    db: Db,
    threaded: std.Io.Threaded,
    fake: FakeHttp,
    agent: Agent,
    path_buf: [128]u8 = undefined,

    fn init(self: *Harness, bodies: []const []const u8) !void {
        self.tmp = testing.tmpDir(.{});
        errdefer self.tmp.cleanup();
        self.threaded = .init(testing.allocator, .{});
        errdefer self.threaded.deinit();
        self.fake = .{ .bodies = bodies };
        const path = try std.fmt.bufPrintZ(&self.path_buf, ".zig-cache/tmp/{s}/zoro.db", .{self.tmp.sub_path});
        self.db = try Db.open(path);
        errdefer self.db.close();
        try self.db.migrate();
        self.agent = .{
            .gpa = testing.allocator,
            .io = self.threaded.io(),
            .db = &self.db,
            .http = self.fake.http(),
            .api_key = .init("k"),
            .base_url = "https://api.openai.com/v1",
            .model = "m",
        };
    }

    fn deinit(self: *Harness) void {
        self.db.close();
        self.threaded.deinit();
        self.tmp.cleanup();
        self.* = undefined;
    }
};

test "zoro routines shows tier state and the runs that were skipped" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [128]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&buf, ".zig-cache/tmp/{s}/zoro.db", .{tmp.sub_path});
    var db = try Db.open(path);
    defer db.close();
    try db.migrate();

    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try printRoutines(&db, &out.writer);
    try testing.expectEqualStrings("no routines\n", out.written());

    try db.exec(
        \\INSERT INTO routines(name, next, last, status, fails, enabled, skips)
        \\VALUES ('payer', 900, 100, 'skipped', 0, 0, 2)
    );
    out.clearRetainingCapacity();
    try printRoutines(&db, &out.writer);
    try testing.expect(std.mem.indexOf(u8, out.written(), "payer off status=skipped") != null);
    try testing.expect(std.mem.indexOf(u8, out.written(), "skips=2") != null);
}
