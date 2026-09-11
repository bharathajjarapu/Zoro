const std = @import("std");
const agent = @import("../agent/root.zig");
const web = @import("web.zig");
const testing = std.testing;

pub const max_body: usize = 2 * 1024 * 1024;

pub const StdHttp = struct {
    client: std.http.Client,

    pub fn init(gpa: std.mem.Allocator, io: std.Io) StdHttp {
        return .{ .client = .{ .allocator = gpa, .io = io } };
    }

    pub fn deinit(self: *StdHttp) void {
        self.client.deinit();
        self.* = undefined;
    }

    pub fn http(self: *StdHttp) agent.Http {
        return .{ .ptr = self, .post_fn = post };
    }

    pub fn getter(self: *StdHttp) web.Get {
        return web.fromClient(&self.client);
    }

    pub fn webApi(self: *StdHttp) web.Api {
        return .{ .ptr = self, .call_fn = webCall };
    }

    fn post(ptr: *anyopaque, gpa: std.mem.Allocator, req: agent.Http.Request) anyerror!agent.Http.Response {
        const self: *StdHttp = @ptrCast(@alignCast(ptr));
        var cap: CappedBody = undefined;
        cap.init(gpa, max_body);
        defer cap.deinit();

        const result = self.client.fetch(.{
            .location = .{ .url = req.url },
            .method = .POST,
            .payload = req.body,
            .headers = .{
                .authorization = .{ .override = req.auth },
                .content_type = .{ .override = req.content_type },
            },
            .response_writer = &cap.writer,
        }) catch |err| {
            if (cap.overflow) return error.ResponseTooLarge;
            return err;
        };

        return .{
            .status = @intFromEnum(result.status),
            .body = try cap.take(),
        };
    }

    fn webCall(ptr: *anyopaque, gpa: std.mem.Allocator, req: web.Api.Request) anyerror!web.Hop {
        const self: *StdHttp = @ptrCast(@alignCast(ptr));
        var cap: CappedBody = undefined;
        cap.init(gpa, max_body);
        defer cap.deinit();
        const key = [_]std.http.Header{.{ .name = "X-API-Key", .value = req.key }};
        const result = self.client.fetch(.{
            .location = .{ .url = req.url },
            .method = req.method,
            .payload = req.body,
            .headers = .{
                .content_type = if (req.body != null) .{ .override = "application/json" } else .omit,
                .user_agent = .{ .override = "zoro/0.0" },
            },
            .extra_headers = &key,
            .redirect_behavior = .unhandled,
            .response_writer = &cap.writer,
        }) catch |err| {
            if (cap.overflow) return error.ResponseTooLarge;
            return err;
        };
        return .{ .status = @intFromEnum(result.status), .body = try cap.take() };
    }
};

/// Stops the fetch once the response exceeds `max_body`.
const CappedBody = struct {
    body: std.Io.Writer.Allocating,
    writer: std.Io.Writer,
    max: usize,
    overflow: bool = false,
    taken: bool = false,
    /// Zig I/O requires non-empty writer storage.
    buf: [4096]u8 = undefined,

    /// Initializes in place because the writer points into `self`.
    fn init(self: *CappedBody, gpa: std.mem.Allocator, max: usize) void {
        self.* = .{
            .body = .init(gpa),
            .writer = undefined,
            .max = max,
        };
        self.writer = .{ .buffer = &self.buf, .vtable = &.{ .drain = drain } };
    }

    fn deinit(self: *CappedBody) void {
        if (!self.taken) self.body.deinit();
        self.* = undefined;
    }

    fn take(self: *CappedBody) ![]u8 {
        if (self.writer.end != 0) {
            self.append(self.writer.buffered()) catch return error.ResponseTooLarge;
            self.writer.end = 0;
        }
        const bytes = try self.body.toOwnedSlice();
        self.taken = true;
        return bytes;
    }

    fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const self: *CappedBody = @alignCast(@fieldParentPtr("writer", w));
        if (w.end != 0) {
            self.append(w.buffered()) catch {
                self.overflow = true;
                return error.WriteFailed;
            };
            w.end = 0;
        }
        if (data.len == 0) return 0;
        var n: usize = 0;
        for (data[0 .. data.len - 1]) |bytes| {
            self.append(bytes) catch {
                self.overflow = true;
                return error.WriteFailed;
            };
            n += bytes.len;
        }
        const last = data[data.len - 1];
        for (0..splat) |_| {
            self.append(last) catch {
                self.overflow = true;
                return error.WriteFailed;
            };
            n += last.len;
        }
        return n;
    }

    fn append(self: *CappedBody, bytes: []const u8) error{Overflow}!void {
        if (bytes.len == 0) return;
        const next = std.math.add(usize, self.body.written().len, bytes.len) catch return error.Overflow;
        if (next > self.max) return error.Overflow;
        self.body.writer.writeAll(bytes) catch return error.Overflow;
    }
};

test "the response writer has room for std to stream into" {
    var cap: CappedBody = undefined;
    cap.init(testing.allocator, 64);
    defer cap.deinit();

    const room = try cap.writer.writableSliceGreedy(1);
    try testing.expect(room.len >= 1);
    @memcpy(room[0..5], "hello");
    cap.writer.advance(5);

    const body = try cap.take();
    defer testing.allocator.free(body);
    try testing.expectEqualStrings("hello", body);
}

test "a response past the cap is refused, whether it drains or not" {
    var small: CappedBody = undefined;
    small.init(testing.allocator, 8);
    defer small.deinit();
    try small.writer.writeAll("far more than eight bytes");
    try testing.expectError(error.ResponseTooLarge, small.take());

    var big: CappedBody = undefined;
    big.init(testing.allocator, 8);
    defer big.deinit();
    const flood = try testing.allocator.alloc(u8, big.buf.len * 2);
    defer testing.allocator.free(flood);
    @memset(flood, 'x');
    try testing.expectError(error.WriteFailed, big.writer.writeAll(flood));
    try testing.expect(big.overflow);
}
