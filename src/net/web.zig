const std = @import("std");
const testing = std.testing;

pub const max_body: usize = 2 * 1024 * 1024;
pub const per_host_per_min: usize = 10;
pub const request_timeout_ms: i64 = 10_000;
const max_hops: u8 = 5;

pub const Api = struct {
    ptr: *anyopaque,
    call_fn: *const fn (*anyopaque, std.mem.Allocator, Request) anyerror!Hop,

    pub const Request = struct {
        method: std.http.Method,
        url: []const u8,
        key: []const u8,
        body: ?[]const u8 = null,
    };

    pub fn call(self: Api, gpa: std.mem.Allocator, req: Request) anyerror!Hop {
        return self.call_fn(self.ptr, gpa, req);
    }

    pub fn callCancellable(self: Api, gpa: std.mem.Allocator, io: std.Io, req: Request, cancel: ?*const std.atomic.Value(bool), parent: ?*const std.atomic.Value(bool)) !Hop {
        return timedFor(self, gpa, io, req, request_timeout_ms, cancel, parent);
    }
};

pub const Get = struct {
    ptr: *anyopaque,
    request_fn: *const fn (*anyopaque, std.mem.Allocator, []const u8, ?[]const u8, ?std.Io.net.IpAddress, usize) anyerror!Hop,

    pub fn request(self: Get, gpa: std.mem.Allocator, url: []const u8, auth: ?[]const u8, address: ?std.Io.net.IpAddress, limit: usize) anyerror!Hop {
        return self.request_fn(self.ptr, gpa, url, auth, address, limit);
    }
};

fn timedFor(api: Api, gpa: std.mem.Allocator, io: std.Io, req: Api.Request, timeout_ms: i64, cancel: ?*const std.atomic.Value(bool), parent: ?*const std.atomic.Value(bool)) !Hop {
    const Race = union(enum) {
        request: anyerror!Hop,
        timeout: std.Io.Cancelable!void,
        cancel: std.Io.Cancelable!void,
    };
    const Run = struct {
        fn request(transport: Api, alloc: std.mem.Allocator, api_req: Api.Request) anyerror!Hop {
            return transport.call(alloc, api_req);
        }

        fn clean(race: *std.Io.Select(Race), alloc: std.mem.Allocator) void {
            while (race.cancel()) |late| switch (late) {
                .request => |result| if (result) |hop| {
                    var owned = hop;
                    owned.deinit(alloc);
                } else |_| {},
                .timeout, .cancel => |result| result catch {},
            };
        }
    };

    var ready: [3]Race = undefined;
    var race = std.Io.Select(Race).init(io, &ready);
    try race.concurrent(.request, Run.request, .{ api, gpa, req });
    {
        errdefer Run.clean(&race, gpa);
        try race.concurrent(.timeout, timeout, .{ io, timeout_ms });
        if (cancel != null or parent != null) try race.concurrent(.cancel, cancelled, .{ io, cancel, parent });
    }

    const first = try race.await();
    defer Run.clean(&race, gpa);
    return switch (first) {
        .request => |result| result,
        .timeout => |result| blk: {
            try result;
            break :blk error.Timeout;
        },
        .cancel => |result| blk: {
            try result;
            break :blk error.Cancelled;
        },
    };
}

fn timeout(io: std.Io, ms: i64) std.Io.Cancelable!void {
    return (std.Io.Clock.Duration{ .raw = .fromMilliseconds(ms), .clock = .awake }).sleep(io);
}

fn cancelled(io: std.Io, local: ?*const std.atomic.Value(bool), parent: ?*const std.atomic.Value(bool)) std.Io.Cancelable!void {
    while (true) {
        if (local) |flag| if (flag.load(.acquire)) return;
        if (parent) |flag| if (flag.load(.acquire)) return;
        try (std.Io.Clock.Duration{ .raw = .fromMilliseconds(25), .clock = .awake }).sleep(io);
    }
}

pub const Hop = struct {
    status: u16,
    body: []u8,
    location: ?[]u8 = null,

    pub fn deinit(self: *Hop, gpa: std.mem.Allocator) void {
        gpa.free(self.body);
        if (self.location) |l| gpa.free(l);
        self.* = undefined;
    }
};

/// ponytail: 8 hosts × 10 stamps. Evict the quietest host if we see more.
pub const Limiter = struct {
    mutex: std.atomic.Mutex = .unlocked,
    slots: [8]Slot = .{Slot{}} ** 8,

    const Slot = struct {
        host: [64]u8 = undefined,
        len: usize = 0,
        stamps: [per_host_per_min]i64 = @splat(0),
        n: usize = 0,
    };

    pub fn allow(self: *Limiter, host: []const u8, now: i64) bool {
        while (!self.mutex.tryLock()) std.atomic.spinLoopHint();
        defer self.mutex.unlock();
        const window = now - 60;
        const s = self.find(host) orelse return false;
        var live: usize = 0;
        for (s.stamps[0..s.n]) |t| {
            if (t > window) live += 1;
        }
        if (live >= per_host_per_min) return false;
        if (s.n < s.stamps.len) {
            s.stamps[s.n] = now;
            s.n += 1;
        } else {
            s.stamps[0] = now;
            std.mem.rotate(i64, &s.stamps, 1);
        }
        return true;
    }

    fn find(self: *Limiter, host: []const u8) ?*Slot {
        const take = @min(host.len, 64);
        for (&self.slots) |*s| {
            if (s.len == take and std.mem.eql(u8, s.host[0..take], host[0..take])) return s;
        }
        for (&self.slots) |*s| {
            if (s.len == 0) {
                @memcpy(s.host[0..take], host[0..take]);
                s.len = take;
                return s;
            }
        }
        var quiet: *Slot = &self.slots[0];
        for (&self.slots) |*s| {
            if (s.n < quiet.n) quiet = s;
        }
        quiet.* = .{};
        @memcpy(quiet.host[0..take], host[0..take]);
        quiet.len = take;
        return quiet;
    }
};

/// Host bytes are valid only while `buf` is.
pub fn hostOf(url: []const u8, buf: *[std.Io.net.HostName.max_len]u8) ![]const u8 {
    const uri = std.Uri.parse(url) catch return error.BadUrl;
    const host = uri.getHost(buf) catch return error.BadUrl;
    return host.bytes;
}

/// Validates URL syntax; returned host borrows `buf`.
pub fn guard(url: []const u8, buf: *[std.Io.net.HostName.max_len]u8) ![]const u8 {
    const uri = std.Uri.parse(url) catch return error.Blocked;
    if (!std.ascii.eqlIgnoreCase(uri.scheme, "https")) return error.HttpsOnly;
    const host = uri.getHost(buf) catch return error.Blocked;
    if (std.mem.indexOfScalar(u8, host.bytes, '%') != null) return error.Blocked;
    if (blockedName(host.bytes)) return error.Blocked;
    if (blockedLiteral(host.bytes)) return error.Blocked;
    return host.bytes;
}

pub fn guardResolved(io: std.Io, host: []const u8) !void {
    _ = try resolveAddress(io, host, 443);
}

pub fn resolveAddress(io: std.Io, host: []const u8, port: u16) !std.Io.net.IpAddress {
    if (blockedLiteral(host)) return error.Blocked;
    const name = std.Io.net.HostName.init(host) catch return error.Blocked;
    var buf: [16]std.Io.net.HostName.LookupResult = undefined;
    var q: std.Io.Queue(std.Io.net.HostName.LookupResult) = .init(&buf);
    name.lookup(io, &q, .{ .port = port }) catch return error.Blocked;
    var first: ?std.Io.net.IpAddress = null;
    while (q.getOne(io)) |r| {
        switch (r) {
            .address => |addr| {
                if (blockedAddr(addr)) return error.Blocked;
                if (first == null) first = addr;
            },
            .canonical_name => {},
        }
    } else |err| switch (err) {
        error.Closed => {},
        else => return error.Blocked,
    }
    return first orelse error.Blocked;
}

pub fn resolveCancellable(io: std.Io, host: []const u8, cancel: ?*const std.atomic.Value(bool), parent: ?*const std.atomic.Value(bool)) !void {
    const Race = union(enum) {
        resolve: anyerror!void,
        timeout: std.Io.Cancelable!void,
        cancel: std.Io.Cancelable!void,
    };
    const Run = struct {
        fn resolve(run_io: std.Io, name: []const u8) anyerror!void {
            return guardResolved(run_io, name);
        }

        fn clean(race: *std.Io.Select(Race)) void {
            while (race.cancel()) |late| switch (late) {
                .resolve, .timeout, .cancel => |result| result catch {},
            };
        }
    };

    var ready: [3]Race = undefined;
    var race = std.Io.Select(Race).init(io, &ready);
    try race.concurrent(.resolve, Run.resolve, .{ io, host });
    {
        errdefer Run.clean(&race);
        try race.concurrent(.timeout, timeout, .{ io, request_timeout_ms });
        if (cancel != null or parent != null) try race.concurrent(.cancel, cancelled, .{ io, cancel, parent });
    }

    const first = try race.await();
    defer Run.clean(&race);
    return switch (first) {
        .resolve => |result| result,
        .timeout => |result| blk: {
            try result;
            break :blk error.Timeout;
        },
        .cancel => |result| blk: {
            try result;
            break :blk error.Cancelled;
        },
    };
}

pub fn fetch(
    gpa: std.mem.Allocator,
    io: std.Io,
    get: Get,
    limiter: *Limiter,
    now: i64,
    url: []const u8,
    auth: ?[]const u8,
) ![]u8 {
    return fetchCancellable(gpa, io, get, limiter, now, url, auth, null, null);
}

pub fn fetchCancellable(
    gpa: std.mem.Allocator,
    io: std.Io,
    get: Get,
    limiter: *Limiter,
    now: i64,
    url: []const u8,
    auth: ?[]const u8,
    cancel: ?*const std.atomic.Value(bool),
    parent: ?*const std.atomic.Value(bool),
) ![]u8 {
    return fetchFor(gpa, io, get, limiter, now, url, auth, request_timeout_ms, cancel, parent);
}

fn fetchFor(
    gpa: std.mem.Allocator,
    io: std.Io,
    get: Get,
    limiter: *Limiter,
    now: i64,
    url: []const u8,
    auth: ?[]const u8,
    timeout_ms: i64,
    cancel: ?*const std.atomic.Value(bool),
    parent: ?*const std.atomic.Value(bool),
) ![]u8 {
    const Race = union(enum) {
        request: anyerror![]u8,
        timeout: std.Io.Cancelable!void,
        cancel: std.Io.Cancelable!void,
    };
    const Run = struct {
        fn request(alloc: std.mem.Allocator, run_io: std.Io, transport: Get, limit: *Limiter, at: i64, target: []const u8, authorization: ?[]const u8) anyerror![]u8 {
            return fetchInner(alloc, run_io, transport, limit, at, target, authorization);
        }

        fn clean(race: *std.Io.Select(Race), alloc: std.mem.Allocator) void {
            while (race.cancel()) |late| switch (late) {
                .request => |result| if (result) |body| alloc.free(body) else |_| {},
                .timeout, .cancel => |result| result catch {},
            };
        }
    };

    var ready: [3]Race = undefined;
    var race = std.Io.Select(Race).init(io, &ready);
    try race.concurrent(.request, Run.request, .{ gpa, io, get, limiter, now, url, auth });
    {
        errdefer Run.clean(&race, gpa);
        try race.concurrent(.timeout, timeout, .{ io, timeout_ms });
        if (cancel != null or parent != null) try race.concurrent(.cancel, cancelled, .{ io, cancel, parent });
    }

    const first = try race.await();
    defer Run.clean(&race, gpa);
    return switch (first) {
        .request => |result| result,
        .timeout => |result| blk: {
            try result;
            break :blk error.Timeout;
        },
        .cancel => |result| blk: {
            try result;
            break :blk error.Cancelled;
        },
    };
}

fn fetchInner(
    gpa: std.mem.Allocator,
    io: std.Io,
    get: Get,
    limiter: *Limiter,
    now: i64,
    url: []const u8,
    auth: ?[]const u8,
) ![]u8 {
    var current = try gpa.dupe(u8, url);
    defer gpa.free(current);
    var hop: u8 = 0;
    var header = auth;
    while (hop < max_hops) : (hop += 1) {
        var host_buf: [std.Io.net.HostName.max_len]u8 = undefined;
        const host = try guard(current, &host_buf);
        const uri = std.Uri.parse(current) catch return error.BadUrl;
        const address = try resolveAddress(io, host, uri.port orelse 443);
        if (!limiter.allow(host, now)) return error.RateLimited;

        var res = try get.request(gpa, current, header, address, max_body);
        header = null; // never forward a secret across a redirect
        errdefer res.deinit(gpa);

        if (res.status == 301 or res.status == 302 or res.status == 303 or res.status == 307 or res.status == 308) {
            const loc = res.location orelse return error.BadRedirect;
            const next = try gpa.dupe(u8, loc);
            res.deinit(gpa);
            gpa.free(current);
            current = next;
            continue;
        }
        try checkStatus(res.status);
        if (res.body.len > max_body) return error.ResponseTooLarge;
        const body = res.body;
        res.body = &.{};
        res.deinit(gpa);
        return body;
    }
    return error.TooManyRedirects;
}

pub fn checkStatus(status: u16) !void {
    if (status >= 200 and status < 300) return;
    if (status == 429) return error.HttpThrottled;
    if (status == 408 or status == 425 or status >= 500) return error.HttpTransient;
    return error.HttpPermanent;
}

fn blockedName(host: []const u8) bool {
    if (std.ascii.eqlIgnoreCase(host, "localhost")) return true;
    if (std.ascii.endsWithIgnoreCase(host, ".localhost")) return true;
    if (std.ascii.endsWithIgnoreCase(host, ".local")) return true;
    if (std.ascii.eqlIgnoreCase(host, "host.docker.internal")) return true;
    if (std.ascii.eqlIgnoreCase(host, "host.containers.internal")) return true;
    return false;
}

fn blockedLiteral(host: []const u8) bool {
    const bare = if (host.len >= 2 and host[0] == '[' and host[host.len - 1] == ']') host[1 .. host.len - 1] else host;
    if (std.Io.net.IpAddress.parse(bare, 0)) |addr| {
        return blockedAddr(addr);
    } else |_| {}
    // 2130706433 → 127.0.0.1
    if (decimalV4(bare)) |b| return blockedV4(b);
    return false;
}

fn decimalV4(host: []const u8) ?[4]u8 {
    if (host.len == 0) return null;
    for (host) |c| {
        if (!std.ascii.isDigit(c)) return null;
    }
    const n = std.fmt.parseInt(u32, host, 10) catch return null;
    return .{
        @truncate(n >> 24),
        @truncate(n >> 16),
        @truncate(n >> 8),
        @truncate(n),
    };
}

fn blockedAddr(addr: std.Io.net.IpAddress) bool {
    return switch (addr) {
        .ip4 => |a| blockedV4(a.bytes),
        .ip6 => |a| blockedV6(a.bytes),
    };
}

fn blockedV4(b: [4]u8) bool {
    if (b[0] == 127) return true; // loopback
    if (b[0] == 10) return true; // private
    if (b[0] == 172 and b[1] >= 16 and b[1] <= 31) return true; // private
    if (b[0] == 192 and b[1] == 168) return true; // private
    if (b[0] == 169 and b[1] == 254) return true; // link-local
    if (b[0] == 0) return true;
    if (b[0] == 100 and b[1] >= 64 and b[1] <= 127) return true; // CGNAT
    if (b[0] >= 224) return true; // multicast / reserved
    return false;
}

fn blockedV6(bytes: [16]u8) bool {
    const segs = [8]u16{
        (@as(u16, bytes[0]) << 8) | bytes[1],
        (@as(u16, bytes[2]) << 8) | bytes[3],
        (@as(u16, bytes[4]) << 8) | bytes[5],
        (@as(u16, bytes[6]) << 8) | bytes[7],
        (@as(u16, bytes[8]) << 8) | bytes[9],
        (@as(u16, bytes[10]) << 8) | bytes[11],
        (@as(u16, bytes[12]) << 8) | bytes[13],
        (@as(u16, bytes[14]) << 8) | bytes[15],
    };
    if (segs[0] == 0 and segs[1] == 0 and segs[2] == 0 and segs[3] == 0 and
        segs[4] == 0 and segs[5] == 0 and segs[6] == 0 and segs[7] == 1) return true;
    if (segs[0] == 0 and segs[1] == 0 and segs[2] == 0 and segs[3] == 0 and
        segs[4] == 0 and segs[5] == 0 and segs[6] == 0 and segs[7] == 0) return true;
    if (segs[0] & 0xff00 == 0xff00) return true; // multicast
    if (segs[0] & 0xfe00 == 0xfc00) return true; // unique local
    if (segs[0] & 0xffc0 == 0xfe80) return true; // link-local
    if (segs[0] == 0 and segs[1] == 0 and segs[2] == 0 and segs[3] == 0 and
        segs[4] == 0 and segs[5] == 0xffff)
    {
        return blockedV4(.{
            @truncate(segs[6] >> 8),
            @truncate(segs[6] & 0xff),
            @truncate(segs[7] >> 8),
            @truncate(segs[7] & 0xff),
        });
    }
    return false;
}

test "guard refuses http, loopback, private and link-local" {
    var buf: [std.Io.net.HostName.max_len]u8 = undefined;
    try testing.expectError(error.HttpsOnly, guard("http://example.com/", &buf));
    try testing.expectError(error.Blocked, guard("https://127.0.0.1/", &buf));
    try testing.expectError(error.Blocked, guard("https://192.168.1.1/", &buf));
    try testing.expectError(error.Blocked, guard("https://10.0.0.1/", &buf));
    try testing.expectError(error.Blocked, guard("https://172.16.0.1/", &buf));
    try testing.expectError(error.Blocked, guard("https://169.254.1.1/", &buf));
    try testing.expectError(error.Blocked, guard("https://localhost/", &buf));
    try testing.expectError(error.Blocked, guard("https://[::1]/", &buf));
    try testing.expectError(error.Blocked, guard("https://2130706433/", &buf));
    try testing.expectError(error.Blocked, guard("https://100.64.0.1/", &buf));
    _ = try guard("https://example.com/path", &buf);
}

test "a redirect into a private address is refused" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    var fake: FakeGet = .{ .status = 302, .location = "https://127.0.0.1/secret" };
    defer fake.deinit(testing.allocator);
    var limiter: Limiter = .{};
    try testing.expectError(error.Blocked, fetch(
        testing.allocator,
        threaded.io(),
        fake.get(),
        &limiter,
        1000,
        "https://8.8.8.8/",
        null,
    ));
}

test "per-host rate limit is 10 per minute" {
    var lim: Limiter = .{};
    var i: usize = 0;
    while (i < 10) : (i += 1) {
        try testing.expect(lim.allow("example.com", 1000));
    }
    try testing.expect(!lim.allow("example.com", 1000));
    try testing.expect(lim.allow("other.com", 1000));
    try testing.expect(lim.allow("example.com", 1000 + 61));
}

test "shared limiter stays exact under concurrent callers" {
    const Run = struct {
        fn run(lim: *Limiter, allowed: *std.atomic.Value(usize)) void {
            for (0..10) |_| {
                if (lim.allow("example.com", 1000)) _ = allowed.fetchAdd(1, .monotonic);
            }
        }
    };
    var lim: Limiter = .{};
    var allowed: std.atomic.Value(usize) = .init(0);
    var threads: [4]std.Thread = undefined;
    for (&threads) |*thread| thread.* = try std.Thread.spawn(.{}, Run.run, .{ &lim, &allowed });
    for (threads) |thread| thread.join();
    try testing.expectEqual(per_host_per_min, allowed.load(.acquire));
}

test "fetch returns the body of a 200" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    var fake: FakeGet = .{ .body = "hello world" };
    defer fake.deinit(testing.allocator);
    var limiter: Limiter = .{};
    const out = try fetch(testing.allocator, threaded.io(), fake.get(), &limiter, 1000, "https://8.8.8.8/", null);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("hello world", out);
}

test "a body over the cap is refused" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const too_big = try testing.allocator.alloc(u8, max_body + 1);
    defer testing.allocator.free(too_big);
    @memset(too_big, 'x');
    var fake: FakeGet = .{ .body = too_big };
    defer fake.deinit(testing.allocator);
    var limiter: Limiter = .{};
    try testing.expectError(error.ResponseTooLarge, fetch(
        testing.allocator,
        threaded.io(),
        fake.get(),
        &limiter,
        1000,
        "https://8.8.8.8/",
        null,
    ));
}

test "auth is dropped on redirect" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    var fake: FakeGet = .{ .status = 302, .location = "https://8.8.8.8/next", .body = "hello" };
    defer fake.deinit(testing.allocator);
    var limiter: Limiter = .{};
    const out = try fetch(
        testing.allocator,
        threaded.io(),
        fake.get(),
        &limiter,
        1000,
        "https://8.8.8.8/",
        "tok",
    );
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("hello", out);
    try testing.expect(fake.auth_first);
    try testing.expect(!fake.auth_later);
}

test "a request is cancelled at its total deadline" {
    const Slow = struct {
        io: std.Io,

        fn api(self: *@This()) Api {
            return .{ .ptr = self, .call_fn = call };
        }

        fn call(ptr: *anyopaque, gpa: std.mem.Allocator, _: Api.Request) anyerror!Hop {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            try (std.Io.Clock.Duration{ .raw = .fromMilliseconds(50), .clock = .awake }).sleep(self.io);
            return .{ .status = 200, .body = try gpa.dupe(u8, "late") };
        }
    };

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var slow: Slow = .{ .io = io };
    const req: Api.Request = .{
        .method = .GET,
        .url = "https://example.com",
        .key = "test",
    };
    try testing.expectError(error.Timeout, timedFor(slow.api(), testing.allocator, io, req, 1, null, null));
    var cancel: std.atomic.Value(bool) = .init(true);
    try testing.expectError(error.Cancelled, timedFor(slow.api(), testing.allocator, io, req, 100, &cancel, null));
}

test "one deadline covers every redirect hop" {
    const Slow = struct {
        io: std.Io,
        hops: u8 = 0,

        fn get(self: *@This()) Get {
            return .{ .ptr = self, .request_fn = request };
        }

        fn request(ptr: *anyopaque, gpa: std.mem.Allocator, _: []const u8, _: ?[]const u8, _: ?std.Io.net.IpAddress, _: usize) anyerror!Hop {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            try (std.Io.Clock.Duration{ .raw = .fromMilliseconds(8), .clock = .awake }).sleep(self.io);
            self.hops += 1;
            if (self.hops < 4) return .{
                .status = 302,
                .body = try gpa.dupe(u8, ""),
                .location = try gpa.dupe(u8, "https://8.8.8.8/next"),
            };
            return .{ .status = 200, .body = try gpa.dupe(u8, "late") };
        }
    };

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    var slow: Slow = .{ .io = threaded.io() };
    var limiter: Limiter = .{};
    try testing.expectError(error.Timeout, fetchFor(
        testing.allocator,
        threaded.io(),
        slow.get(),
        &limiter,
        1000,
        "https://8.8.8.8/",
        null,
        15,
        null,
        null,
    ));

    var cancel: std.atomic.Value(bool) = .init(true);
    var fresh_limiter: Limiter = .{};
    try testing.expectError(error.Cancelled, fetchFor(
        testing.allocator,
        threaded.io(),
        slow.get(),
        &fresh_limiter,
        1000,
        "https://8.8.8.8/",
        null,
        100,
        &cancel,
        null,
    ));
}

test "direct fetch rejects HTTP failure bodies" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    var fake: FakeGet = .{ .status = 404, .body = "not found" };
    defer fake.deinit(testing.allocator);
    var limiter: Limiter = .{};
    try testing.expectError(error.HttpPermanent, fetch(
        testing.allocator,
        threaded.io(),
        fake.get(),
        &limiter,
        1000,
        "https://8.8.8.8/missing",
        null,
    ));
    try testing.expect(fake.pinned);
}

const FakeGet = struct {
    status: u16 = 200,
    body: []const u8 = "ok",
    location: ?[]const u8 = null,
    seen: ?[]u8 = null,
    hop: u8 = 0,
    auth_first: bool = false,
    auth_later: bool = false,
    pinned: bool = false,

    fn deinit(self: *FakeGet, gpa: std.mem.Allocator) void {
        if (self.seen) |s| gpa.free(s);
        self.* = undefined;
    }

    fn get(self: *FakeGet) Get {
        return .{ .ptr = self, .request_fn = request };
    }

    fn request(ptr: *anyopaque, gpa: std.mem.Allocator, url: []const u8, auth: ?[]const u8, address: ?std.Io.net.IpAddress, _: usize) anyerror!Hop {
        const self: *FakeGet = @ptrCast(@alignCast(ptr));
        self.hop += 1;
        self.pinned = address != null;
        if (auth != null) {
            if (self.hop == 1) self.auth_first = true else self.auth_later = true;
        }
        if (self.seen) |s| gpa.free(s);
        self.seen = try gpa.dupe(u8, url);
        if (self.hop == 1 and (self.status != 200 or self.location != null)) {
            return .{
                .status = self.status,
                .body = try gpa.dupe(u8, self.body),
                .location = if (self.location) |l| try gpa.dupe(u8, l) else null,
            };
        }
        return .{
            .status = 200,
            .body = try gpa.dupe(u8, self.body),
            .location = null,
        };
    }
};

pub fn fromClient(client: *std.http.Client) Get {
    return .{ .ptr = client, .request_fn = stdRequest };
}

pub fn pinnedConnection(client: *std.http.Client, uri: std.Uri, addr: std.Io.net.IpAddress) !*std.http.Client.Connection {
    var remote_buf: [std.Io.net.HostName.max_len]u8 = undefined;
    const remote = uri.getHost(&remote_buf) catch return error.BadUrl;
    var endpoint_buf: [96]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&endpoint_buf);
    try addr.format(&writer);
    const endpoint = writer.buffered();
    const host_text = if (endpoint[0] == '[')
        endpoint[1 .. std.mem.indexOfScalar(u8, endpoint, ']') orelse return error.BadUrl]
    else
        endpoint[0 .. std.mem.lastIndexOfScalar(u8, endpoint, ':') orelse return error.BadUrl];
    const host = std.Io.net.HostName.init(host_text) catch return error.BadUrl;
    const port = uri.port orelse 443;
    return client.connectTcpOptions(.{
        .host = host,
        .port = port,
        .protocol = .tls,
        .proxied_host = remote,
        .proxied_port = port,
    });
}

fn stdRequest(ptr: *anyopaque, gpa: std.mem.Allocator, url: []const u8, auth: ?[]const u8, address: ?std.Io.net.IpAddress, limit: usize) anyerror!Hop {
    const client: *std.http.Client = @ptrCast(@alignCast(ptr));
    const uri = std.Uri.parse(url) catch return error.BadUrl;

    var auth_buf: [256]u8 = undefined;
    const auth_header: ?[]const u8 = if (auth) |a|
        std.fmt.bufPrint(&auth_buf, "Bearer {s}", .{a}) catch return error.AuthTooLong
    else
        null;

    var connection: ?*std.http.Client.Connection = null;
    var handed_off = false;
    defer if (!handed_off) if (connection) |conn| {
        conn.closing = true;
        client.connection_pool.release(conn, client.io);
    };
    if (address) |addr| {
        connection = try pinnedConnection(client, uri, addr);
    }

    var req = try client.request(.GET, uri, .{
        .redirect_behavior = .unhandled,
        .connection = connection,
        .headers = .{
            .user_agent = .{ .override = "zoro/0.0" },
            .authorization = if (auth_header) |h| .{ .override = h } else .omit,
        },
    });
    handed_off = true;
    defer req.deinit();
    try req.sendBodiless();
    // ponytail: Zig 0.16 ignores request timeouts; revisit when supported.
    var response = try req.receiveHead(&.{});

    const status: u16 = @intFromEnum(response.head.status);
    const location = if (response.head.location) |l| try gpa.dupe(u8, l) else null;
    errdefer if (location) |l| gpa.free(l);

    const reader = response.reader(&.{});
    const body = reader.allocRemaining(gpa, .limited(limit)) catch |err| switch (err) {
        error.StreamTooLong => return error.ResponseTooLarge,
        else => return err,
    };
    return .{ .status = status, .body = body, .location = location };
}
