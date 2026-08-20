const std = @import("std");
const agent = @import("agent.zig");
const Agent = agent.Agent;
const testing = std.testing;

pub const max_prompt = 64 * 1024;

/// Joins argv fragments into `buf` with spaces. Null if there are none.
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

/// One turn, print the reply, return. Caller owns `prompt`.
pub fn oneShot(a: *Agent, prompt: []const u8, out: *std.Io.Writer) !void {
    const reply = try a.turn(prompt);
    defer a.gpa.free(reply);
    try writeReply(out, reply);
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
    }
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

// ── test helpers ──────────────────────────────────────────────────────────

const Db = @import("db.zig").Db;

const FakeHttp = struct {
    bodies: []const []const u8,
    i: usize = 0,

    fn http(self: *FakeHttp) agent.Http {
        return .{ .ptr = self, .post_fn = post };
    }

    fn post(ptr: *anyopaque, gpa: std.mem.Allocator, _: agent.Http.Request) anyerror!agent.Http.Response {
        const self: *FakeHttp = @ptrCast(@alignCast(ptr));
        if (self.i >= self.bodies.len) return error.TooManyCalls;
        const body = try gpa.dupe(u8, self.bodies[self.i]);
        self.i += 1;
        return .{ .status = 200, .body = body };
    }
};

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
