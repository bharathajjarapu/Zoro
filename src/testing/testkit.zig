const std = @import("std");
const agent = @import("../agent/root.zig");
const Db = @import("../data/db.zig").Db;
const testing = std.testing;

pub const max_calls = 32;

pub const FakeHttp = struct {
    bodies: []const []const u8 = &.{},
    /// Per-call status codes; falls back to `status` once exhausted.
    statuses: []const u16 = &.{},
    status: u16 = 200,
    index: usize = 0,
    /// Cancels workers on the first call.
    trip: ?*agent.Workers = null,
    /// Parks inside the call so a test can observe several in flight at once.
    hold: ?*std.atomic.Value(bool) = null,

    /// Fixed request and URL capture.
    body: [192 * 1024]u8 = undefined,
    body_len: usize = 0,
    urls: [max_calls][160]u8 = undefined,
    url_lens: [max_calls]usize = @splat(0),
    count: usize = 0,

    pub fn http(self: *FakeHttp) agent.Http {
        return .{ .ptr = self, .post_fn = post };
    }

    pub fn sent(self: *FakeHttp) []const u8 {
        return self.body[0..self.body_len];
    }

    pub fn url(self: *FakeHttp, index: usize) []const u8 {
        return self.urls[index][0..self.url_lens[index]];
    }

    pub fn sentUrl(self: *FakeHttp) []const u8 {
        return if (self.count == 0) "" else self.url(self.count - 1);
    }

    fn post(ptr: *anyopaque, gpa: std.mem.Allocator, req: agent.Http.Request) anyerror!agent.Http.Response {
        const self: *FakeHttp = @ptrCast(@alignCast(ptr));
        self.body_len = @min(req.body.len, self.body.len);
        @memcpy(self.body[0..self.body_len], req.body[0..self.body_len]);
        if (self.count < max_calls) {
            const size = @min(req.url.len, self.urls[self.count].len);
            @memcpy(self.urls[self.count][0..size], req.url[0..size]);
            self.url_lens[self.count] = size;
            self.count += 1;
        }
        if (self.trip) |workers| workers.stop.store(true, .release);
        if (self.hold) |gate| while (gate.load(.acquire)) std.atomic.spinLoopHint();
        if (self.index >= self.bodies.len) return error.TooManyCalls;
        const status: u16 = if (self.index < self.statuses.len) self.statuses[self.index] else self.status;
        const body = try gpa.dupe(u8, self.bodies[self.index]);
        self.index += 1;
        return .{ .status = status, .body = body };
    }
};

/// A path inside the test's temp directory. `buf` must outlive the use.
pub fn tmpPath(tmp: *testing.TmpDir, buf: []u8, name: []const u8) ![:0]u8 {
    return std.fmt.bufPrintZ(buf, ".zig-cache/tmp/{s}/{s}", .{ tmp.sub_path, name });
}

/// An open database in the test's temp directory.
pub fn tmpDb(tmp: *testing.TmpDir, buf: []u8) !Db {
    var db = try Db.open(try tmpPath(tmp, buf, "zoro.db"));
    errdefer db.close();
    try db.initSchema();
    return db;
}
