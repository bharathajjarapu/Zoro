//! Shared test scaffolding. Only test blocks reference it, so it never reaches
//! the binary. Everything here captures into fixed buffers rather than the
//! allocator, so no test has to free the fake it used.
const std = @import("std");
const agent = @import("agent.zig");
const Db = @import("db.zig").Db;
const testing = std.testing;

pub const max_calls = 32;

/// Stands in for the model endpoint and for Telegram: both speak through
/// `agent.Http`. Replies come from `bodies` in order; running out is an error,
/// which is what makes "it should not have called again" testable.
pub const FakeHttp = struct {
    bodies: []const []const u8 = &.{},
    /// Per-call status codes; falls back to `status` once exhausted.
    statuses: []const u16 = &.{},
    status: u16 = 200,
    i: usize = 0,
    /// Raised on the first call, standing in for the owner saying "stop" while
    /// a worker is mid-round.
    trip: ?*agent.Workers = null,
    /// Parks inside the call so a test can observe several in flight at once.
    hold: ?*std.atomic.Value(bool) = null,

    /// One request body at a time — the largest carries a 64 KiB tool result —
    /// and a short history of URLs, which is all any caller asks for.
    body: [192 * 1024]u8 = undefined,
    body_len: usize = 0,
    urls: [max_calls][160]u8 = undefined,
    url_lens: [max_calls]usize = @splat(0),
    n: usize = 0,

    pub fn http(self: *FakeHttp) agent.Http {
        return .{ .ptr = self, .post_fn = post };
    }

    /// The request body of the most recent call.
    pub fn sent(self: *FakeHttp) []const u8 {
        return self.body[0..self.body_len];
    }

    /// The URL of call `i`, in order.
    pub fn url(self: *FakeHttp, i: usize) []const u8 {
        return self.urls[i][0..self.url_lens[i]];
    }

    pub fn sentUrl(self: *FakeHttp) []const u8 {
        return if (self.n == 0) "" else self.url(self.n - 1);
    }

    fn post(ptr: *anyopaque, gpa: std.mem.Allocator, req: agent.Http.Request) anyerror!agent.Http.Response {
        const self: *FakeHttp = @ptrCast(@alignCast(ptr));
        self.body_len = @min(req.body.len, self.body.len);
        @memcpy(self.body[0..self.body_len], req.body[0..self.body_len]);
        if (self.n < max_calls) {
            const k = @min(req.url.len, self.urls[self.n].len);
            @memcpy(self.urls[self.n][0..k], req.url[0..k]);
            self.url_lens[self.n] = k;
            self.n += 1;
        }
        if (self.trip) |w| w.stop.store(true, .release);
        if (self.hold) |h| while (h.load(.acquire)) std.atomic.spinLoopHint();
        if (self.i >= self.bodies.len) return error.TooManyCalls;
        const st: u16 = if (self.i < self.statuses.len) self.statuses[self.i] else self.status;
        const body = try gpa.dupe(u8, self.bodies[self.i]);
        self.i += 1;
        return .{ .status = st, .body = body };
    }
};

/// A path inside the test's temp directory. `buf` must outlive the use.
pub fn tmpPath(tmp: *testing.TmpDir, buf: []u8, name: []const u8) ![:0]u8 {
    return std.fmt.bufPrintZ(buf, ".zig-cache/tmp/{s}/{s}", .{ tmp.sub_path, name });
}

/// An open, migrated database in the test's temp directory.
pub fn tmpDb(tmp: *testing.TmpDir, buf: []u8) !Db {
    var db = try Db.open(try tmpPath(tmp, buf, "zoro.db"));
    errdefer db.close();
    try db.migrate();
    return db;
}
