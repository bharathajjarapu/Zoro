const std = @import("std");
const tools = @import("root.zig");
const web = @import("../net/web.zig");
const secrets = @import("../data/secrets.zig");
const Db = @import("../data/db.zig").Db;
const testing = std.testing;

const Param = tools.Param;
const Def = tools.Def;
const Ctx = tools.Ctx;

const url_param = [_]Param{.{ .name = "url", .description = "HTTPS URL to fetch" }};
const query_param = [_]Param{.{ .name = "query", .description = "search query" }};

pub const fetch_url: Def = .{
    .name = "fetch_url",
    .description = "Fetch an HTTPS URL and return its text. No custom headers.",
    .params = &url_param,
    .run = runFetch,
};

pub const search: Def = .{
    .name = "search",
    .description = "Search the web (DuckDuckGo).",
    .params = &query_param,
    .run = runSearch,
};

const UrlArgs = struct { url: []const u8 };
const QueryArgs = struct { query: []const u8 };

fn runFetch(ctx: *Ctx, args: []const u8) anyerror![]u8 {
    const parsed = try std.json.parseFromSlice(UrlArgs, ctx.gpa, args, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    return doFetch(ctx, parsed.value.url);
}

fn runSearch(ctx: *Ctx, args: []const u8) anyerror![]u8 {
    const parsed = try std.json.parseFromSlice(QueryArgs, ctx.gpa, args, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    const q = std.mem.trim(u8, parsed.value.query, &std.ascii.whitespace);
    if (q.len == 0 or q.len > 512) return error.InvalidArgs;
    var url_buf: [1024]u8 = undefined;
    var w: std.Io.Writer = .fixed(&url_buf);
    try w.writeAll("https://api.duckduckgo.com/?q=");
    try std.Uri.Component.percentEncode(&w, q, isUnreserved);
    try w.writeAll("&format=json&no_html=1&no_redirect=1");
    const body = try doFetch(ctx, w.buffered());
    defer ctx.gpa.free(body);
    return formatSearch(ctx.gpa, body);
}

fn doFetch(ctx: *Ctx, url: []const u8) ![]u8 {
    const get = ctx.fetch orelse return error.WebUnavailable;
    const limiter = ctx.limiter orelse return error.WebUnavailable;
    const now = std.Io.Timestamp.now(ctx.io, .real).toSeconds();
    var host_buf: [std.Io.net.HostName.max_len]u8 = undefined;
    const host = web.hostOf(url, &host_buf) catch null;
    const auth = if (host) |h| secrets.valueFor(ctx.db, ctx.gpa, h) catch null else null;
    defer if (auth) |a| ctx.gpa.free(a);
    return web.fetch(ctx.gpa, ctx.io, get, limiter, now, url, auth) catch |err|
        return std.fmt.allocPrint(ctx.gpa, "fetch failed: {s}", .{@errorName(err)});
}

fn isUnreserved(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.' or c == '~';
}

fn formatSearch(gpa: std.mem.Allocator, body: []const u8) ![]u8 {
    const Parsed = struct {
        AbstractText: ?[]const u8 = null,
        AbstractURL: ?[]const u8 = null,
        Heading: ?[]const u8 = null,
        Answer: ?[]const u8 = null,
    };
    const tree = std.json.parseFromSlice(Parsed, gpa, body, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch return try gpa.dupe(u8, body);
    defer tree.deinit();
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    var any = false;
    if (tree.value.Heading) |h| {
        try out.writer.print("{s}\n", .{h});
        any = true;
    }
    if (tree.value.Answer) |a| {
        try out.writer.print("{s}\n", .{a});
        any = true;
    }
    if (tree.value.AbstractText) |t| {
        try out.writer.print("{s}\n", .{t});
        any = true;
    }
    if (tree.value.AbstractURL) |u| {
        try out.writer.print("{s}\n", .{u});
        any = true;
    }
    if (!any) try out.writer.writeAll("no results\n");
    return try out.toOwnedSlice();
}

fn boom(_: *anyopaque, _: std.mem.Allocator, _: []const u8, _: ?[]const u8) anyerror!web.Hop {
    return error.ShouldNotRun;
}

fn tmpPath(tmp: *testing.TmpDir, buf: []u8) ![:0]u8 {
    return std.fmt.bufPrintZ(buf, ".zig-cache/tmp/{s}/zoro.db", .{tmp.sub_path});
}

test "fetch_url refuses a private address" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [128]u8 = undefined;
    var db = try Db.open(try tmpPath(&tmp, &buf));
    defer db.close();
    try db.migrate();
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    var limiter: web.Limiter = .{};
    var ctx: Ctx = .{
        .gpa = testing.allocator,
        .io = threaded.io(),
        .db = &db,
        .fetch = .{ .ptr = undefined, .request_fn = boom },
        .limiter = &limiter,
    };
    const out = try tools.call(&ctx, &tools.builtins, "fetch_url", "{\"url\":\"https://127.0.0.1/\"}");
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "fetch failed") != null);
}
