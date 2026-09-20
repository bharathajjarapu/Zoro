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
    var size: usize = 0;
    while (args.next()) |part| {
        if (size != 0) {
            if (size >= buf.len) return error.StreamTooLong;
            buf[size] = ' ';
            size += 1;
        }
        if (part.len > buf.len - size) return error.StreamTooLong;
        @memcpy(buf[size..][0..part.len], part);
        size += part.len;
    }
    return if (size == 0) null else buf[0..size];
}

pub fn oneShot(assistant: *Agent, prompt: []const u8, writer: *std.Io.Writer) !void {
    const reply = try assistant.turn(prompt);
    defer assistant.gpa.free(reply);
    try writeReply(writer, reply);
    try drain(assistant, writer);
}

pub fn chat(assistant: *Agent, reader: *std.Io.Reader, writer: *std.Io.Writer, errors: *std.Io.Writer) !void {
    try errors.writeAll("zoro chat (:q to quit)\n");
    try errors.flush();
    while (true) {
        try errors.writeAll("zoro> ");
        try errors.flush();
        const line = (try reader.takeDelimiter('\n')) orelse break;
        const text = std.mem.trim(u8, stripCr(line), &std.ascii.whitespace);
        if (text.len == 0) continue;
        if (isQuit(text)) break;
        const reply = try assistant.turn(text);
        defer assistant.gpa.free(reply);
        try writeReply(writer, reply);
        try drain(assistant, writer);
    }
}

/// Prints output queued outside the agent.
fn drain(assistant: *Agent, writer: *std.Io.Writer) !void {
    const now = std.Io.Timestamp.now(assistant.io, .real).toSeconds();
    try outbox.recoverBefore(assistant.db, now - 300);
    var sent: usize = 0;
    while (sent < outbox.max_drain) {
        const items = try outbox.claim(assistant.db, assistant.gpa, now);
        defer outbox.free(assistant.gpa, items);
        if (items.len == 0) break;
        sent += items.len;
        for (items, 0..) |item, index| {
            writeItem(writer, item) catch |err| {
                try outbox.uncertain(assistant.db, item.id, @errorName(err));
                for (items[index + 1 ..]) |rest| try outbox.retry(assistant.db, rest.id, @errorName(err));
                return err;
            };
            try outbox.delivered(assistant.db, item.id);
        }
    }
    try writer.flush();
}

fn writeItem(out: *std.Io.Writer, item: outbox.Item) !void {
    if (item.path) |path| try out.print("[{s}] {s}\n", .{ @tagName(item.kind), path });
    if (item.text.len != 0) return writeReply(out, item.text);
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

fn isQuit(text: []const u8) bool {
    return std.mem.eql(u8, text, ":q") or std.mem.eql(u8, text, ":quit");
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
    for (hits) |hit| {
        try out.print("{s}\t{s}\t{d:.4}\n", .{ hit.ref, hit.kind, hit.score });
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
    var statement = try db.prepare(
        \\SELECT name, enabled, COALESCE(status, '-'), fails, skips,
        \\       COALESCE(next, 0), COALESCE(last, 0)
        \\FROM routines ORDER BY name
    );
    defer statement.finalize();
    var count: usize = 0;
    while (try statement.step()) : (count += 1) {
        try out.print("{s} {s} status={s} fails={d} skips={d} next={d} last={d}\n", .{
            statement.text(0),
            if (statement.int(1) == 1) "on" else "off",
            statement.text(2),
            statement.int(3),
            statement.int(4),
            statement.int(5),
            statement.int(6),
        });
    }
    if (count == 0) try out.writeAll("no routines\n");
    try out.flush();
}

pub fn printStatus(db: *Db, out: *std.Io.Writer) !void {
    var statement = try db.prepare(
        \\SELECT
        \\ (SELECT count(*) FROM tasks WHERE status IN ('queued','running','blocked')) + (SELECT count(*) FROM outbox WHERE status IN ('queued','claimed','retryable')) + (SELECT count(*) FROM telegram_updates WHERE status IN ('pending','processing','retryable')) + (SELECT count(*) FROM approvals WHERE status IN ('pending','executing')),
        \\ (SELECT count(*) FROM tasks WHERE status = 'failed') + (SELECT count(*) FROM outbox WHERE status = 'failed') + (SELECT count(*) FROM telegram_updates WHERE status = 'failed'),
        \\ (SELECT count(*) FROM outbox WHERE status = 'uncertain') + (SELECT count(*) FROM telegram_updates WHERE status = 'uncertain') + (SELECT count(*) FROM approvals WHERE status = 'uncertain')
    );
    defer statement.finalize();
    if (!try statement.step()) return error.NoRow;
    const pending = statement.int(0);
    const failed = statement.int(1);
    const uncertain = statement.int(2);
    const state: []const u8 = if (uncertain != 0 or failed != 0) "blocked" else if (pending != 0) "recovering" else "usable";
    try out.print("{s} pending={d} failed={d} uncertain={d}\n", .{ state, pending, failed, uncertain });
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
    var harness: Harness = undefined;
    try harness.init(&.{"{\"choices\":[{\"message\":{\"content\":\"hello back\"}}]}"});
    defer harness.deinit();

    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();

    try oneShot(&harness.agent, "hello", &out.writer);
    try testing.expectEqualStrings("hello back\n", out.written());
}

test "chat holds a multi-turn conversation over stdin" {
    var harness: Harness = undefined;
    try harness.init(&.{
        "{\"choices\":[{\"message\":{\"content\":\"hi\"}}]}",
        "{\"choices\":[{\"message\":{\"content\":\"later\"}}]}",
    });
    defer harness.deinit();

    var reader: std.Io.Reader = .fixed("hello\nagain\n");
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    var err_out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer err_out.deinit();

    try chat(&harness.agent, &reader, &out.writer, &err_out.writer);
    try testing.expectEqualStrings("hi\nlater\n", out.written());
}

test "chat skips blanks and quits on :q" {
    var harness: Harness = undefined;
    try harness.init(&.{"{\"choices\":[{\"message\":{\"content\":\"ok\"}}]}"});
    defer harness.deinit();

    var reader: std.Io.Reader = .fixed("hello\n  \n:q\nignored\n");
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    var err_out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer err_out.deinit();

    try chat(&harness.agent, &reader, &out.writer, &err_out.writer);
    try testing.expectEqualStrings("ok\n", out.written());
}

test "takePrompt joins args and rejects overflow" {
    var buf: [16]u8 = undefined;
    var iterator: SliceIter = .{ .items = &.{ "hello", "zig" } };
    try testing.expectEqualStrings("hello zig", (try takePrompt(&buf, &iterator)).?);

    var empty: SliceIter = .{ .items = &.{} };
    try testing.expect(try takePrompt(&buf, &empty) == null);

    var long: SliceIter = .{ .items = &.{"abcdefghijklmnopqrstuvwxyz"} };
    try testing.expectError(error.StreamTooLong, takePrompt(buf[0..8], &long));
}

const SliceIter = struct {
    items: []const []const u8,
    index: usize = 0,
    fn next(self: *SliceIter) ?[]const u8 {
        if (self.index >= self.items.len) return null;
        const item = self.items[self.index];
        self.index += 1;
        return item;
    }
};

test "diary prints a day's file and reports a missing day clearly" {
    var harness: Harness = undefined;
    try harness.init(&.{"{\"choices\":[{\"message\":{\"content\":\"x\"}}]}"});
    defer harness.deinit();

    const diary_dir = try std.fmt.bufPrint(&harness.path_buf, ".zig-cache/tmp/{s}/diary", .{harness.tmp.sub_path});
    try std.Io.Dir.cwd().createDirPath(harness.agent.io, diary_dir);
    var folder = try std.Io.Dir.cwd().openDir(harness.agent.io, diary_dir, .{});
    defer folder.close(harness.agent.io);
    try folder.writeFile(harness.agent.io, .{ .sub_path = "2026-08-20.md", .data = "# 2026-08-20\n\nwalked the dog\n" });

    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try printDiary(testing.allocator, harness.agent.io, diary_dir, "2026-08-20", 0, &out.writer);
    try testing.expect(std.mem.indexOf(u8, out.written(), "walked the dog") != null);

    var missing: std.Io.Writer.Allocating = .init(testing.allocator);
    defer missing.deinit();
    try printDiary(testing.allocator, harness.agent.io, diary_dir, "2026-08-21", 0, &missing.writer);
    try testing.expectEqualStrings("no diary for 2026-08-21\n", missing.written());
}

test "diary with no date argument defaults to today" {
    var harness: Harness = undefined;
    try harness.init(&.{"{\"choices\":[{\"message\":{\"content\":\"x\"}}]}"});
    defer harness.deinit();

    const now: i64 = 1_755_648_000; // 2026-08-20 00:00 UTC
    var day: [10]u8 = undefined;
    const today = memory.formatDay(&day, now);
    const diary_dir = try std.fmt.bufPrint(&harness.path_buf, ".zig-cache/tmp/{s}/diary", .{harness.tmp.sub_path});
    try std.Io.Dir.cwd().createDirPath(harness.agent.io, diary_dir);
    var folder = try std.Io.Dir.cwd().openDir(harness.agent.io, diary_dir, .{});
    defer folder.close(harness.agent.io);
    var name: [16]u8 = undefined;
    try folder.writeFile(harness.agent.io, .{
        .sub_path = try std.fmt.bufPrint(&name, "{s}.md", .{today}),
        .data = "today's log\n",
    });

    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try printDiary(testing.allocator, harness.agent.io, diary_dir, null, now, &out.writer);
    try testing.expectEqualStrings("today's log\n", out.written());
}

test "memory prints ref, kind, and score per hit" {
    var harness: Harness = undefined;
    try harness.init(&.{"{\"choices\":[{\"message\":{\"content\":\"x\"}}]}"});
    defer harness.deinit();

    try memory.put(harness.agent.db, "pet", "a black cat named mittens", .owner, 1000, null);

    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try printMemory(harness.agent.db, testing.allocator, "mittens", 1000, &out.writer);
    try testing.expect(std.mem.indexOf(u8, out.written(), "pet") != null);
    try testing.expect(std.mem.indexOf(u8, out.written(), "fact") != null);
    try testing.expect(std.mem.indexOf(u8, out.written(), ".") != null);
}

test "tasks lists parent and child with status, priority, and goal" {
    var harness: Harness = undefined;
    try harness.init(&.{"{\"choices\":[{\"message\":{\"content\":\"x\"}}]}"});
    defer harness.deinit();

    const parent = try tasks.create(harness.agent.db, "research", "notes written", 0, null, 2);
    _ = try tasks.create(harness.agent.db, "fetch sources", "three urls saved", 0, parent, 0);

    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try printTasks(harness.agent.db, testing.allocator, &out.writer);
    try testing.expect(std.mem.indexOf(u8, out.written(), "research") != null);
    try testing.expect(std.mem.indexOf(u8, out.written(), "queued") != null);
    try testing.expect(std.mem.indexOf(u8, out.written(), "prio=2") != null);
    try testing.expect(std.mem.indexOf(u8, out.written(), "notes written") != null);
    try testing.expect(std.mem.indexOf(u8, out.written(), "  #") != null);
}

test "status reports recovery without transcript or secrets" {
    var harness: Harness = undefined;
    try harness.init(&.{"{\"choices\":[{\"message\":{\"content\":\"x\"}}]}"});
    defer harness.deinit();
    _ = try tasks.create(harness.agent.db, "work", "done", 0, null, 0);

    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try printStatus(harness.agent.db, &out.writer);
    try testing.expectEqualStrings("recovering pending=1 failed=0 uncertain=0\n", out.written());
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
        try self.db.initSchema();
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
    try db.initSchema();

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
