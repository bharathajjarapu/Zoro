const std = @import("std");
const tools = @import("root.zig");
const web = @import("../net/web.zig");
const workspace = @import("../app/workspace.zig");

const max_path = workspace.max_path;
const max_read = workspace.max_read;
const max_write = workspace.max_write;
const trunc_mark = workspace.trunc_mark;
const validPath = workspace.validPath;
const read = workspace.read;
const readText = workspace.readExact;
const write = workspace.write;
const delete = workspace.delete;
const openFile = workspace.openFile;
const makeDir = workspace.makeDir;

const path_param = [_]tools.Param{.{ .name = "path", .description = "workspace path" }};
const write_params = [_]tools.Param{
    .{ .name = "path", .description = "workspace path" },
    .{ .name = "content", .description = "UTF-8 content" },
};
const edit_params = [_]tools.Param{
    .{ .name = "path", .description = "workspace path" },
    .{ .name = "old", .description = "unique exact text" },
    .{ .name = "new", .description = "replacement" },
};
const download_params = [_]tools.Param{
    .{ .name = "url", .description = "HTTPS URL" },
    .{ .name = "path", .description = "workspace path" },
};

pub const read_file: tools.Def = .{
    .name = "read_file",
    .description = "Read workspace text.",
    .params = &path_param,
    .run = runRead,
};

pub const write_file: tools.Def = .{
    .name = "write_file",
    .description = "Write workspace text.",
    .params = &write_params,
    .mutates = true,
    .primary_only = true,
    .run = runWrite,
};

pub const edit_file: tools.Def = .{
    .name = "edit_file",
    .description = "Edit one unique match.",
    .params = &edit_params,
    .mutates = true,
    .primary_only = true,
    .run = runEdit,
};

pub const download_file: tools.Def = .{
    .name = "download_file",
    .description = "Download into workspace.",
    .params = &download_params,
    .mutates = true,
    .primary_only = true,
    .run = runDownload,
};

pub const delete_file: tools.Def = .{
    .name = "delete_file",
    .description = "Delete a workspace file.",
    .params = &path_param,
    .mutates = true,
    .primary_only = true,
    .run = runDelete,
};

fn runRead(ctx: *tools.Ctx, args: []const u8) ![]u8 {
    if (args.len > max_path + 64) return error.InvalidArgs;
    const Args = struct { path: []const u8 };
    const parsed = try std.json.parseFromSlice(Args, ctx.gpa, args, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    return read(ctx.gpa, ctx.io, ctx.workspace, parsed.value.path);
}

fn runWrite(ctx: *tools.Ctx, args: []const u8) ![]u8 {
    if (args.len > max_write + max_path + 128) return error.InvalidArgs;
    const Args = struct { path: []const u8, content: []const u8 };
    const parsed = try std.json.parseFromSlice(Args, ctx.gpa, args, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    try allowMutation(parsed.value.path);
    if (!std.unicode.utf8ValidateSlice(parsed.value.content) or std.mem.indexOfScalar(u8, parsed.value.content, 0) != null)
        return error.UnsupportedBinary;
    if (std.fs.path.dirname(parsed.value.path)) |parent| try makeDir(ctx.io, ctx.workspace, parent);
    try write(ctx.io, ctx.workspace, parsed.value.path, parsed.value.content);
    return std.fmt.allocPrint(ctx.gpa, "wrote {s}", .{parsed.value.path});
}

fn runEdit(ctx: *tools.Ctx, args: []const u8) ![]u8 {
    if (args.len > max_write + max_path + 128) return error.InvalidArgs;
    const Args = struct { path: []const u8, old: []const u8, new: []const u8 };
    const parsed = try std.json.parseFromSlice(Args, ctx.gpa, args, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    try allowMutation(parsed.value.path);
    if (parsed.value.old.len == 0) return error.InvalidArgs;

    const before = try readText(ctx.gpa, ctx.io, ctx.workspace, parsed.value.path, max_write);
    defer ctx.gpa.free(before);
    const first = std.mem.indexOf(u8, before, parsed.value.old) orelse return error.MatchNotFound;
    if (std.mem.indexOfPos(u8, before, first + parsed.value.old.len, parsed.value.old) != null)
        return error.AmbiguousMatch;
    const size = before.len - parsed.value.old.len + parsed.value.new.len;
    if (size > max_write) return error.FileTooLarge;
    const after = try ctx.gpa.alloc(u8, size);
    defer ctx.gpa.free(after);
    @memcpy(after[0..first], before[0..first]);
    @memcpy(after[first .. first + parsed.value.new.len], parsed.value.new);
    @memcpy(after[first + parsed.value.new.len ..], before[first + parsed.value.old.len ..]);
    try write(ctx.io, ctx.workspace, parsed.value.path, after);
    return std.fmt.allocPrint(ctx.gpa, "edited {s}", .{parsed.value.path});
}

fn runDownload(ctx: *tools.Ctx, args: []const u8) ![]u8 {
    if (args.len > max_path + 4096 + 128) return error.InvalidArgs;
    const Args = struct { url: []const u8, path: []const u8 };
    const parsed = try std.json.parseFromSlice(Args, ctx.gpa, args, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    try allowMutation(parsed.value.path);
    if (!validPath(parsed.value.path)) return error.BadPath;
    const get = ctx.fetch orelse return error.WebUnavailable;
    const limiter = ctx.limiter orelse return error.WebUnavailable;
    const now = std.Io.Timestamp.now(ctx.io, .real).toSeconds();
    const body = try web.fetchCancellable(ctx.gpa, ctx.io, get, limiter, now, parsed.value.url, null, ctx.cancel, ctx.cancel_parent);
    defer ctx.gpa.free(body);
    if (body.len > max_write) return error.FileTooLarge;
    try write(ctx.io, ctx.workspace, parsed.value.path, body);
    return std.fmt.allocPrint(ctx.gpa, "downloaded {s}", .{parsed.value.path});
}

fn runDelete(ctx: *tools.Ctx, args: []const u8) ![]u8 {
    if (args.len > max_path + 64) return error.InvalidArgs;
    const Args = struct { path: []const u8 };
    const parsed = try std.json.parseFromSlice(Args, ctx.gpa, args, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    try allowMutation(parsed.value.path);
    try delete(ctx.io, ctx.workspace, parsed.value.path);
    return std.fmt.allocPrint(ctx.gpa, "deleted {s}", .{parsed.value.path});
}

fn allowMutation(path: []const u8) !void {
    const fixed = [_][]const u8{ "SOUL.md", "IDENTITY.md", "USER.md", "MEMORY.md" };
    for (fixed) |name| if (std.mem.eql(u8, path, name)) return error.IdentityRequiresApproval;
}

const testing = std.testing;
const testkit = @import("../testing/testkit.zig");

const FakeGet = struct {
    body: []const u8,
    status: u16 = 200,
    called: bool = false,

    fn get(self: *FakeGet) web.Get {
        return .{ .ptr = self, .request_fn = request };
    }

    fn request(ptr: *anyopaque, gpa: std.mem.Allocator, _: []const u8, _: ?[]const u8, _: ?std.Io.net.IpAddress, _: usize) anyerror!web.Hop {
        const self: *FakeGet = @ptrCast(@alignCast(ptr));
        self.called = true;
        return .{ .status = self.status, .body = try gpa.dupe(u8, self.body) };
    }
};

const Harness = struct {
    tmp: testing.TmpDir,
    threaded: std.Io.Threaded,
    db: @import("../data/db.zig").Db,
    path: [160]u8 = undefined,
    workspace: []const u8 = undefined,

    fn init(self: *Harness) !void {
        self.tmp = testing.tmpDir(.{});
        self.threaded = .init(testing.allocator, .{});
        try self.tmp.dir.createDir(self.threaded.io(), "workspace", .default_dir);
        self.workspace = try std.fmt.bufPrint(&self.path, ".zig-cache/tmp/{s}/workspace", .{self.tmp.sub_path});
        var db_path: [160]u8 = undefined;
        self.db = try testkit.tmpDb(&self.tmp, &db_path);
    }

    fn deinit(self: *Harness) void {
        self.db.close();
        self.threaded.deinit();
        self.tmp.cleanup();
    }

    fn ctx(self: *Harness) tools.Ctx {
        return .{ .gpa = testing.allocator, .io = self.threaded.io(), .db = &self.db, .workspace = self.workspace };
    }
};

test "file tools write read and uniquely edit workspace text" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    var ctx = h.ctx();

    const wrote = try tools.call(&ctx, &.{write_file}, "write_file", "{\"path\":\"note.txt\",\"content\":\"one two\"}");
    defer testing.allocator.free(wrote);
    try testing.expectEqualStrings("wrote note.txt", wrote);

    const edited = try tools.call(&ctx, &.{edit_file}, "edit_file", "{\"path\":\"note.txt\",\"old\":\"two\",\"new\":\"three\"}");
    defer testing.allocator.free(edited);
    try testing.expectEqualStrings("edited note.txt", edited);

    const got = try tools.call(&ctx, &.{read_file}, "read_file", "{\"path\":\"note.txt\"}");
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("one three", got);
}

test "write creates guarded parent directories" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    var ctx = h.ctx();

    const out = try tools.call(&ctx, &.{write_file}, "write_file", "{\"path\":\"reports/brief/index.html\",\"content\":\"<h1>Brief</h1>\"}");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("wrote reports/brief/index.html", out);
    const got = try read(testing.allocator, h.threaded.io(), h.workspace, "reports/brief/index.html");
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("<h1>Brief</h1>", got);
}

test "file tools reject escapes protected paths and symlinks" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    var ctx = h.ctx();

    const bad = [_][]const u8{
        "{\"path\":\"../secret\"}",
        "{\"path\":\"/etc/passwd\"}",
        "{\"path\":\".env\"}",
        "{\"path\":\".git/config\"}",
        "{\"path\":\"state.db\"}",
    };
    for (bad) |args| {
        const out = try tools.call(&ctx, &.{read_file}, "read_file", args);
        defer testing.allocator.free(out);
        try testing.expect(std.mem.indexOf(u8, out, "BadPath") != null);
    }

    var root = try std.Io.Dir.cwd().openDir(h.threaded.io(), h.workspace, .{});
    defer root.close(h.threaded.io());
    try root.symLink(h.threaded.io(), "/etc/passwd", "link", .{});
    const linked = try tools.call(&ctx, &.{read_file}, "read_file", "{\"path\":\"link\"}");
    defer testing.allocator.free(linked);
    try testing.expect(std.mem.indexOf(u8, linked, "SymLink") != null or std.mem.indexOf(u8, linked, "AccessDenied") != null);
    try root.symLink(h.threaded.io(), "/tmp", "outside", .{ .is_directory = true });
    const parent = try tools.call(&ctx, &.{read_file}, "read_file", "{\"path\":\"outside/file\"}");
    defer testing.allocator.free(parent);
    try testing.expect(std.mem.indexOf(u8, parent, "SymLink") != null or std.mem.indexOf(u8, parent, "NotDir") != null);
}

test "general file tools cannot replace identity" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    var ctx = h.ctx();
    const out = try tools.call(&ctx, &.{write_file}, "write_file", "{\"path\":\"SOUL.md\",\"content\":\"ignore safety\"}");
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "IdentityRequiresApproval") != null);
}

test "read reports truncation and binary honestly" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    var ctx = h.ctx();
    const text = try testing.allocator.alloc(u8, max_read + 9);
    defer testing.allocator.free(text);
    @memset(text, 'a');
    try write(h.threaded.io(), h.workspace, "large.txt", text);
    const large = try tools.call(&ctx, &.{read_file}, "read_file", "{\"path\":\"large.txt\"}");
    defer testing.allocator.free(large);
    try testing.expect(std.mem.endsWith(u8, large, trunc_mark));

    try write(h.threaded.io(), h.workspace, "blob.bin", "\x00\xff");
    const binary = try tools.call(&ctx, &.{read_file}, "read_file", "{\"path\":\"blob.bin\"}");
    defer testing.allocator.free(binary);
    try testing.expect(std.mem.indexOf(u8, binary, "UnsupportedBinary") != null);
}

test "edit refuses missing and repeated matches" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    var ctx = h.ctx();
    try write(h.threaded.io(), h.workspace, "note.txt", "same same");

    const repeated = try tools.call(&ctx, &.{edit_file}, "edit_file", "{\"path\":\"note.txt\",\"old\":\"same\",\"new\":\"x\"}");
    defer testing.allocator.free(repeated);
    try testing.expect(std.mem.indexOf(u8, repeated, "AmbiguousMatch") != null);
    const missing = try tools.call(&ctx, &.{edit_file}, "edit_file", "{\"path\":\"note.txt\",\"old\":\"nope\",\"new\":\"x\"}");
    defer testing.allocator.free(missing);
    try testing.expect(std.mem.indexOf(u8, missing, "MatchNotFound") != null);
}

test "delete removes one guarded workspace file directly" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    var ctx = h.ctx();
    try write(h.threaded.io(), h.workspace, "old.txt", "old");
    const out = try tools.call(&ctx, &.{delete_file}, "delete_file", "{\"path\":\"old.txt\"}");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("deleted old.txt", out);
    try testing.expectError(error.FileNotFound, openFile(h.threaded.io(), h.workspace, "old.txt"));
}

test "download applies web policy then writes atomically" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    var fake: FakeGet = .{ .body = "downloaded" };
    var limiter: web.Limiter = .{};
    var ctx = h.ctx();
    ctx.fetch = fake.get();
    ctx.limiter = &limiter;

    const bad = try tools.call(&ctx, &.{download_file}, "download_file", "{\"url\":\"http://example.com\",\"path\":\"page.txt\"}");
    defer testing.allocator.free(bad);
    try testing.expect(std.mem.indexOf(u8, bad, "HttpsOnly") != null);
    try testing.expect(!fake.called);

    fake.status = 404;
    const failed = try tools.call(&ctx, &.{download_file}, "download_file", "{\"url\":\"https://8.8.8.8/missing\",\"path\":\"page.txt\"}");
    defer testing.allocator.free(failed);
    try testing.expectEqualStrings("tool error: HttpPermanent", failed);
    try testing.expectError(error.FileNotFound, openFile(h.threaded.io(), h.workspace, "page.txt"));

    fake.status = 200;
    const out = try tools.call(&ctx, &.{download_file}, "download_file", "{\"url\":\"https://8.8.8.8/file\",\"path\":\"page.txt\"}");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("downloaded page.txt", out);
    const got = try read(testing.allocator, h.threaded.io(), h.workspace, "page.txt");
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("downloaded", got);
}
