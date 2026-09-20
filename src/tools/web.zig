const std = @import("std");
const tools = @import("root.zig");
const web = @import("../net/web.zig");
const testing = std.testing;
const testkit = @import("../testing/testkit.zig");

const Param = tools.Param;
const Def = tools.Def;
const Ctx = tools.Ctx;

const search_url = "https://api.search.tinyfish.ai?query=";
const fetch_endpoint = "https://api.fetch.tinyfish.ai";
const url_param = [_]Param{.{ .name = "url", .description = "HTTPS URL" }};
const query_param = [_]Param{.{ .name = "query", .description = "search query" }};
const watch_params = [_]Param{
    .{ .name = "url", .description = "public HTTPS URL" },
    .{ .name = "key", .description = "stable lowercase watcher name" },
};

pub const fetch_url: Def = .{
    .name = "fetch_url",
    .description = "Fetch a page as Markdown.",
    .params = &url_param,
    .run = runFetch,
};

pub const search: Def = .{
    .name = "search",
    .description = "Search the web.",
    .params = &query_param,
    .run = runSearch,
};

pub const watch_url: Def = .{
    .name = "watch_url",
    .description = "Fetch public text and report first, changed, or unchanged.",
    .params = &watch_params,
    .mutates = true,
    .run = runWatch,
};

const UrlArgs = struct { url: []const u8 };
const QueryArgs = struct { query: []const u8 };
const WatchArgs = struct { url: []const u8, key: []const u8 };

fn runFetch(ctx: *Ctx, args: []const u8) anyerror![]u8 {
    const parsed = try std.json.parseFromSlice(UrlArgs, ctx.gpa, args, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    const url = std.mem.trim(u8, parsed.value.url, &std.ascii.whitespace);
    if (url.len == 0 or url.len > 4096) return error.InvalidArgs;

    var host_buf: [std.Io.net.HostName.max_len]u8 = undefined;
    const host = try web.guard(url, &host_buf);
    try web.resolveCancellable(ctx.io, host, ctx.cancel, ctx.cancel_parent);
    try allow(ctx, host);
    try allow(ctx, "api.fetch.tinyfish.ai");

    var body: std.Io.Writer.Allocating = .init(ctx.gpa);
    defer body.deinit();
    try body.writer.writeAll("{\"urls\":[");
    try std.json.Stringify.encodeJsonString(url, .{}, &body.writer);
    try body.writer.writeAll("],\"format\":\"markdown\"}");

    const raw = try call(ctx, .POST, fetch_endpoint, body.written());
    defer ctx.gpa.free(raw);
    return fetchText(ctx.gpa, raw);
}

fn runSearch(ctx: *Ctx, args: []const u8) anyerror![]u8 {
    const parsed = try std.json.parseFromSlice(QueryArgs, ctx.gpa, args, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    const query = std.mem.trim(u8, parsed.value.query, &std.ascii.whitespace);
    if (query.len == 0 or query.len > 512) return error.InvalidArgs;
    try allow(ctx, "api.search.tinyfish.ai");

    var url_buf: [1024]u8 = undefined;
    var w: std.Io.Writer = .fixed(&url_buf);
    try w.writeAll(search_url);
    try std.Uri.Component.percentEncode(&w, query, isUnreserved);
    return call(ctx, .GET, w.buffered(), null);
}

fn runWatch(ctx: *Ctx, args: []const u8) ![]u8 {
    const parsed = try std.json.parseFromSlice(WatchArgs, ctx.gpa, args, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    if (!validWatchKey(parsed.value.key)) return error.InvalidWatchKey;
    const get = ctx.fetch orelse return error.WebUnavailable;
    const limiter = ctx.limiter orelse return error.WebUnavailable;
    const now = std.Io.Timestamp.now(ctx.io, .real).toSeconds();
    const body = try web.fetchCancellable(ctx.gpa, ctx.io, get, limiter, now, parsed.value.url, null, ctx.cancel, ctx.cancel_parent);
    defer ctx.gpa.free(body);
    if (!std.unicode.utf8ValidateSlice(body) or std.mem.indexOfScalar(u8, body, 0) != null)
        return error.UnsupportedBinary;

    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(body, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    var key_buf: [72]u8 = undefined;
    const key = try std.fmt.bufPrint(&key_buf, "watch:{s}", .{parsed.value.key});
    var q = try ctx.db.prepare("SELECT value FROM kv WHERE key = ?");
    defer q.finalize();
    try q.bind(1, key);
    const found = try q.step();
    const same = found and std.mem.eql(u8, q.text(0), &hex);
    if (same) return ctx.gpa.dupe(u8, "unchanged");

    var upsert = try ctx.db.prepare("INSERT INTO kv(key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value");
    defer upsert.finalize();
    try upsert.bind(1, key);
    try upsert.bind(2, &hex);
    _ = try upsert.step();
    return std.fmt.allocPrint(ctx.gpa, "{s}\n{s}", .{ if (found) "changed" else "first", body });
}

fn validWatchKey(key: []const u8) bool {
    if (key.len == 0 or key.len > 64 or !std.ascii.isLower(key[0])) return false;
    for (key[1..]) |c| if (!(std.ascii.isLower(c) or std.ascii.isDigit(c) or c == '_' or c == '-')) return false;
    return true;
}

fn call(ctx: *Ctx, method: std.http.Method, url: []const u8, body: ?[]const u8) ![]u8 {
    const api = ctx.web_api orelse return error.WebUnavailable;
    const key = ctx.tinyfish_key orelse return error.WebUnavailable;
    var res = api.callCancellable(ctx.gpa, ctx.io, .{ .method = method, .url = url, .key = key, .body = body }, ctx.cancel, ctx.cancel_parent) catch |err| switch (err) {
        error.OutOfMemory, error.Timeout, error.Cancelled, error.ResponseTooLarge, error.Blocked, error.HttpsOnly => return err,
        else => return error.HttpTransient,
    };
    defer res.deinit(ctx.gpa);
    try web.checkStatus(res.status);
    const out = res.body;
    res.body = &.{};
    return out;
}

fn allow(ctx: *Ctx, host: []const u8) !void {
    const limiter = ctx.limiter orelse return error.WebUnavailable;
    const now = std.Io.Timestamp.now(ctx.io, .real).toSeconds();
    if (!limiter.allow(host, now)) return error.RateLimited;
}

fn fetchText(gpa: std.mem.Allocator, body: []const u8) ![]u8 {
    const Reply = struct {
        results: []const struct { text: []const u8 = "" } = &.{},
    };
    const parsed = std.json.parseFromSlice(Reply, gpa, body, .{ .ignore_unknown_fields = true }) catch
        return gpa.dupe(u8, body);
    defer parsed.deinit();
    if (parsed.value.results.len == 0 or parsed.value.results[0].text.len == 0) return gpa.dupe(u8, body);
    return gpa.dupe(u8, parsed.value.results[0].text);
}

fn isUnreserved(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.' or c == '~';
}

const FakeApi = struct {
    reply: []const u8,
    status: u16 = 200,
    fail: bool = false,
    called: bool = false,
    method: std.http.Method = .GET,
    key_ok: bool = false,
    url: [2048]u8 = undefined,
    url_len: usize = 0,
    body: [8192]u8 = undefined,
    body_len: usize = 0,

    fn api(self: *FakeApi) web.Api {
        return .{ .ptr = self, .call_fn = request };
    }

    fn request(ptr: *anyopaque, gpa: std.mem.Allocator, req: web.Api.Request) anyerror!web.Hop {
        const self: *FakeApi = @ptrCast(@alignCast(ptr));
        self.called = true;
        if (self.fail) return error.ConnectionResetByPeer;
        self.method = req.method;
        self.key_ok = std.mem.eql(u8, req.key, "tf-test");
        self.url_len = @min(req.url.len, self.url.len);
        @memcpy(self.url[0..self.url_len], req.url[0..self.url_len]);
        if (req.body) |body| {
            self.body_len = @min(body.len, self.body.len);
            @memcpy(self.body[0..self.body_len], body[0..self.body_len]);
        }
        return .{ .status = self.status, .body = try gpa.dupe(u8, self.reply) };
    }
};

const FakeGet = struct {
    body: []const u8,

    fn get(self: *FakeGet) web.Get {
        return .{ .ptr = self, .request_fn = request };
    }

    fn request(ptr: *anyopaque, gpa: std.mem.Allocator, _: []const u8, _: ?[]const u8, _: ?std.Io.net.IpAddress, _: usize) anyerror!web.Hop {
        const self: *FakeGet = @ptrCast(@alignCast(ptr));
        return .{ .status = 200, .body = try gpa.dupe(u8, self.body) };
    }
};

fn ctxOf(db: *@import("../data/db.zig").Db, io: std.Io, fake: *FakeApi, limiter: *web.Limiter) Ctx {
    return .{
        .gpa = testing.allocator,
        .io = io,
        .db = db,
        .web_api = fake.api(),
        .tinyfish_key = "tf-test",
        .limiter = limiter,
    };
}

test "search calls TinyFish with an encoded query" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path: [128]u8 = undefined;
    var db = try testkit.tmpDb(&tmp, &path);
    defer db.close();
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    var fake: FakeApi = .{ .reply = "{\"results\":[{\"title\":\"Zig\",\"snippet\":\"fast\",\"url\":\"https://ziglang.org\"}]}" };
    var limiter: web.Limiter = .{};
    var ctx = ctxOf(&db, threaded.io(), &fake, &limiter);

    const out = try tools.call(&ctx, &tools.builtins, "search", "{\"query\":\"zig 0.16?\"}");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(fake.reply, out);
    try testing.expectEqual(std.http.Method.GET, fake.method);
    try testing.expect(fake.key_ok);
    try testing.expectEqualStrings("https://api.search.tinyfish.ai?query=zig%200.16%3F", fake.url[0..fake.url_len]);
}

test "fetch_url returns TinyFish Markdown" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path: [128]u8 = undefined;
    var db = try testkit.tmpDb(&tmp, &path);
    defer db.close();
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    var fake: FakeApi = .{ .reply = "{\"results\":[{\"text\":\"# Example\"}],\"errors\":[]}" };
    var limiter: web.Limiter = .{};
    var ctx = ctxOf(&db, threaded.io(), &fake, &limiter);

    const out = try tools.call(&ctx, &tools.builtins, "fetch_url", "{\"url\":\"https://8.8.8.8/a?x=1\"}");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("# Example", out);
    try testing.expectEqual(std.http.Method.POST, fake.method);
    try testing.expect(fake.key_ok);
    try testing.expectEqualStrings(fetch_endpoint, fake.url[0..fake.url_len]);
    try testing.expectEqualStrings("{\"urls\":[\"https://8.8.8.8/a?x=1\"],\"format\":\"markdown\"}", fake.body[0..fake.body_len]);
}

test "watch_url reports first change and unchanged" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path: [128]u8 = undefined;
    var db = try testkit.tmpDb(&tmp, &path);
    defer db.close();
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    var fake: FakeGet = .{ .body = "one" };
    var limiter: web.Limiter = .{};
    var ctx: Ctx = .{ .gpa = testing.allocator, .io = threaded.io(), .db = &db, .fetch = fake.get(), .limiter = &limiter };
    const args = "{\"url\":\"https://8.8.8.8/feed\",\"key\":\"news\"}";

    const first = try tools.call(&ctx, &.{watch_url}, "watch_url", args);
    defer testing.allocator.free(first);
    try testing.expectEqualStrings("first\none", first);

    const same = try tools.call(&ctx, &.{watch_url}, "watch_url", args);
    defer testing.allocator.free(same);
    try testing.expectEqualStrings("unchanged", same);

    fake.body = "two";
    const changed = try tools.call(&ctx, &.{watch_url}, "watch_url", args);
    defer testing.allocator.free(changed);
    try testing.expectEqualStrings("changed\ntwo", changed);

    const bad = try tools.call(&ctx, &.{watch_url}, "watch_url", "{\"url\":\"https://8.8.8.8/feed\",\"key\":\"../bad\"}");
    defer testing.allocator.free(bad);
    try testing.expect(std.mem.indexOf(u8, bad, "InvalidWatchKey") != null);
}

test "fetch_url rejects private hosts before TinyFish" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path: [128]u8 = undefined;
    var db = try testkit.tmpDb(&tmp, &path);
    defer db.close();
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    var fake: FakeApi = .{ .reply = "{}" };
    var limiter: web.Limiter = .{};
    var ctx = ctxOf(&db, threaded.io(), &fake, &limiter);

    const out = try tools.call(&ctx, &tools.builtins, "fetch_url", "{\"url\":\"https://127.0.0.1/\"}");
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "Blocked") != null);
    try testing.expect(!fake.called);

    const resolved = try tools.call(&ctx, &tools.builtins, "fetch_url", "{\"url\":\"https://localhost./\"}");
    defer testing.allocator.free(resolved);
    try testing.expect(std.mem.indexOf(u8, resolved, "Blocked") != null);
    try testing.expect(!fake.called);
}

test "TinyFish HTTP failures have distinct classes" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path: [128]u8 = undefined;
    var db = try testkit.tmpDb(&tmp, &path);
    defer db.close();
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    var fake: FakeApi = .{ .reply = "{}", .status = 429 };
    var limiter: web.Limiter = .{};
    var ctx = ctxOf(&db, threaded.io(), &fake, &limiter);

    const throttled = try tools.call(&ctx, &tools.builtins, "search", "{\"query\":\"zig\"}");
    defer testing.allocator.free(throttled);
    try testing.expectEqualStrings("tool error: HttpThrottled", throttled);

    fake.status = 503;
    const transient = try tools.call(&ctx, &tools.builtins, "search", "{\"query\":\"zig\"}");
    defer testing.allocator.free(transient);
    try testing.expectEqualStrings("tool error: HttpTransient", transient);

    fake.status = 400;
    const permanent = try tools.call(&ctx, &tools.builtins, "search", "{\"query\":\"zig\"}");
    defer testing.allocator.free(permanent);
    try testing.expectEqualStrings("tool error: HttpPermanent", permanent);

    fake.status = 200;
    fake.fail = true;
    const transport = try tools.call(&ctx, &tools.builtins, "search", "{\"query\":\"zig\"}");
    defer testing.allocator.free(transport);
    try testing.expectEqualStrings("tool error: HttpTransient", transport);
}
