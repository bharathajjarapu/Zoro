const std = @import("std");
const builtin = @import("builtin");
const tasks = @import("../data/tasks.zig");
const tools = @import("root.zig");
const workspace_app = @import("../app/workspace.zig");

const max_args: usize = 32;
const max_arg: usize = 4096;
const max_command: usize = 16 * 1024;
const max_output: usize = 32 * 1024;
const max_runtime = std.Io.Clock.Duration{
    .clock = .awake,
    .raw = .fromSeconds(if (builtin.is_test) 1 else 10),
};
const publish_runtime = std.Io.Clock.Duration{ .clock = .awake, .raw = .fromSeconds(if (builtin.is_test) 1 else 60) };

const argv_param = [_]tools.Param{.{
    .name = "argv",
    .description = "command arguments",
    .kind = .array,
}};

pub const run: tools.Def = .{
    .name = "shell",
    .description = "Run a workspace command.",
    .params = &argv_param,
    .mutates = true,
    .primary_only = true,
    .run = runChecked,
};

pub const run_approved: tools.Def = .{
    .name = "shell",
    .description = "Run an approved command.",
    .params = &argv_param,
    .mutates = true,
    .primary_only = true,
    .run = runApproved,
};

const Args = struct {
    argv: []const []const u8,
    workspace: ?[]const u8 = null,
};

const Command = struct {
    parsed: std.json.Parsed(Args),
    argv: [max_args][]const u8,
    len: usize,
    kind: Kind,
    auto: bool,

    fn deinit(self: *Command) void {
        self.parsed.deinit();
    }

    fn slice(self: *const Command) []const []const u8 {
        return self.argv[0..self.len];
    }
};

fn parse(ctx: *tools.Ctx, args: []const u8) !Command {
    if (args.len == 0 or args.len > max_command) return error.InvalidArgs;
    var parsed = try std.json.parseFromSlice(Args, ctx.gpa, args, .{ .ignore_unknown_fields = true });
    errdefer parsed.deinit();
    if (parsed.value.argv.len == 0 or parsed.value.argv.len > max_args) return error.InvalidArgs;

    var out: Command = .{ .parsed = parsed, .argv = undefined, .len = parsed.value.argv.len, .kind = undefined, .auto = false };
    var total: usize = 0;
    for (parsed.value.argv, 0..) |arg, i| {
        if (arg.len == 0 or arg.len > max_arg or std.mem.indexOfScalar(u8, arg, 0) != null) return error.InvalidArgs;
        total += arg.len;
        if (total > max_command or forbidden(arg)) return error.BlockedCommand;
        out.argv[i] = arg;
    }
    const spec = resolve(out.argv[0]) orelse return error.BlockedCommand;
    out.argv[0] = spec.path;
    out.kind = spec.kind;
    out.auto = try validate(spec.kind, out.slice());
    return out;
}

const Kind = enum { pwd, ls, env, yes, sleep, wrangler };
const Spec = struct { path: []const u8, kind: Kind };

fn resolve(name: []const u8) ?Spec {
    const specs = [_]Spec{
        .{ .path = "/bin/pwd", .kind = .pwd },
        .{ .path = "/bin/ls", .kind = .ls },
        .{ .path = "/usr/bin/env", .kind = .env },
        .{ .path = "/usr/bin/yes", .kind = .yes },
        .{ .path = "/bin/sleep", .kind = .sleep },
        .{ .path = "/usr/local/bin/wrangler", .kind = .wrangler },
    };
    for (specs) |spec| {
        if (std.mem.eql(u8, name, spec.path) or std.mem.eql(u8, name, std.fs.path.basename(spec.path))) return spec;
    }
    return null;
}

fn forbidden(arg: []const u8) bool {
    if (std.mem.indexOfAny(u8, arg, "`\n\r") != null) return true;
    if (std.mem.indexOf(u8, arg, "$(") != null) return true;
    if (std.mem.eql(u8, arg, "|") or std.mem.eql(u8, arg, "||") or
        std.mem.eql(u8, arg, "&&") or std.mem.eql(u8, arg, ";") or
        std.mem.eql(u8, arg, ">") or std.mem.eql(u8, arg, ">>") or
        std.mem.eql(u8, arg, "<")) return true;
    if (std.mem.indexOfScalar(u8, arg, '=')) |at| {
        if (at > 0 and envName(arg[0..at])) return true;
    }
    return false;
}

fn envName(s: []const u8) bool {
    if (s.len == 0 or !(std.ascii.isAlphabetic(s[0]) or s[0] == '_')) return false;
    for (s[1..]) |c| if (!(std.ascii.isAlphanumeric(c) or c == '_')) return false;
    return true;
}

fn validate(kind: Kind, argv: []const []const u8) !bool {
    return switch (kind) {
        .pwd => if (argv.len == 1) true else error.InvalidArgs,
        .env, .yes => if (argv.len == 1) false else error.InvalidArgs,
        .sleep => blk: {
            if (argv.len != 2) return error.InvalidArgs;
            const seconds = std.fmt.parseInt(u8, argv[1], 10) catch return error.InvalidArgs;
            if (seconds > 30) return error.InvalidArgs;
            break :blk false;
        },
        .ls => blk: {
            for (argv[1..]) |arg| if (!listed(&.{ "-a", "-l", "-la", "-al" }, arg)) return error.InvalidArgs;
            break :blk true;
        },
        .wrangler => blk: {
            if (argv.len != 8 or
                !std.mem.eql(u8, argv[1], "deploy") or
                !workspace_app.validPath(argv[2]) or
                !std.mem.eql(u8, argv[3], "--name") or
                !validWorkerName(argv[4]) or
                !std.mem.eql(u8, argv[5], "--temporary") or
                !std.mem.eql(u8, argv[6], "--compatibility-date") or
                !validDate(argv[7])) return error.InvalidArgs;
            break :blk false;
        },
    };
}

fn validWorkerName(name: []const u8) bool {
    if (name.len == 0 or name.len > 63 or name[0] == '-' or name[name.len - 1] == '-') return false;
    for (name) |c| if (!(std.ascii.isLower(c) or std.ascii.isDigit(c) or c == '-')) return false;
    return true;
}

fn validDate(date: []const u8) bool {
    if (date.len != 10 or date[4] != '-' or date[7] != '-') return false;
    for (date, 0..) |c, i| if (i != 4 and i != 7 and !std.ascii.isDigit(c)) return false;
    return true;
}

fn listed(list: []const []const u8, value: []const u8) bool {
    for (list) |item| if (std.mem.eql(u8, item, value)) return true;
    return false;
}

fn runChecked(ctx: *tools.Ctx, args: []const u8) ![]u8 {
    var command = try parse(ctx, args);
    defer command.deinit();
    if (ctx.shell_mode == .deny) return ctx.gpa.dupe(u8, "shell denied by policy");
    if (command.kind == .wrangler) try checkStatic(ctx, command.argv[2]);
    if (command.auto) return execute(ctx, command.slice());
    if (ctx.shell_mode == .allowlist) return ctx.gpa.dupe(u8, "shell command is not allowlisted");
    var bound: std.Io.Writer.Allocating = .init(ctx.gpa);
    defer bound.deinit();
    try bound.writer.print("{f}", .{std.json.fmt(.{
        .argv = command.slice(),
        .workspace = ctx.workspace,
    }, .{})});
    const now = std.Io.Timestamp.now(ctx.io, .real).toSeconds();
    const id = try tasks.ask(ctx.db, "shell", bound.written(), command.argv[0], "run this workspace command", null, now);
    if (ctx.approval_out) |out| out.* = id;
    return std.fmt.allocPrint(ctx.gpa, "pending #{d}: shell approval required", .{id});
}

fn runApproved(ctx: *tools.Ctx, args: []const u8) ![]u8 {
    if (ctx.shell_mode == .deny) return ctx.gpa.dupe(u8, "shell denied by policy");
    var command = try parse(ctx, args);
    defer command.deinit();
    const bound = command.parsed.value.workspace orelse return error.UnboundApproval;
    if (!std.mem.eql(u8, bound, ctx.workspace)) return error.WrongWorkspace;
    if (command.kind == .wrangler) try checkStatic(ctx, command.argv[2]);
    return execute(ctx, command.slice());
}

fn checkStatic(ctx: *tools.Ctx, path: []const u8) !void {
    var full_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const full = try std.fmt.bufPrint(&full_buf, "{s}/{s}", .{ ctx.workspace, path });
    var dir = try std.Io.Dir.cwd().openDir(ctx.io, full, .{ .iterate = true, .follow_symlinks = false });
    defer dir.close(ctx.io);
    var found = false;
    var it = dir.iterate();
    while (try it.next(ctx.io)) |entry| {
        if (found or entry.kind != .file or !std.mem.eql(u8, entry.name, "index.html"))
            return error.StaticSiteMustBeSingleIndex;
        var file = try dir.openFile(ctx.io, entry.name, .{ .allow_directory = false, .follow_symlinks = false });
        defer file.close(ctx.io);
        const stat = try file.stat(ctx.io);
        if (stat.size == 0 or stat.size > workspace_app.max_write) return error.InvalidStaticSite;
        found = true;
    }
    if (!found) return error.InvalidStaticSite;
}

fn execute(ctx: *tools.Ctx, argv: []const []const u8) ![]u8 {
    var env = std.process.Environ.Map.init(ctx.gpa);
    defer env.deinit();
    try env.put("LANG", "C.UTF-8");
    try env.put("PATH", "/usr/bin:/bin");
    var dir = try std.Io.Dir.cwd().openDir(ctx.io, ctx.workspace, .{ .follow_symlinks = false });
    defer dir.close(ctx.io);

    var child = try std.process.spawn(ctx.io, .{
        .argv = argv,
        .cwd = .{ .dir = dir },
        .environ_map = &env,
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
        .pgid = 0,
    });
    defer child.kill(ctx.io);

    var buffer: std.Io.File.MultiReader.Buffer(2) = undefined;
    var readers: std.Io.File.MultiReader = undefined;
    readers.init(ctx.gpa, ctx.io, buffer.toStreams(), &.{ child.stdout.?, child.stderr.? });
    defer readers.deinit();
    const stdout = readers.reader(0);
    const stderr = readers.reader(1);
    const limit = if (std.mem.endsWith(u8, argv[0], "/wrangler")) publish_runtime else max_runtime;
    const deadline = std.Io.Clock.Timestamp.fromNow(ctx.io, limit);

    while (true) {
        if (ctx.cancelled()) {
            killGroup(&child);
            return error.Cancelled;
        }
        const check = std.Io.Clock.Timestamp.fromNow(ctx.io, .{ .raw = .fromMilliseconds(100), .clock = .awake });
        const next = if (check.compare(.lt, deadline)) check else deadline;
        readers.fill(256, .{ .deadline = next }) catch |err| switch (err) {
            error.EndOfStream => break,
            error.Timeout => {
                if (next.compare(.gte, deadline)) {
                    killGroup(&child);
                    return ctx.gpa.dupe(u8, "shell timed out");
                }
                continue;
            },
            else => |e| return e,
        };
        if (stdout.buffered().len + stderr.buffered().len > max_output) {
            killGroup(&child);
            return ctx.gpa.dupe(u8, "shell output limit exceeded");
        }
    }
    try readers.checkAnyError();
    const term = try child.wait(ctx.io);
    const out = stdout.buffered();
    const err = stderr.buffered();
    var result: std.Io.Writer.Allocating = .init(ctx.gpa);
    errdefer result.deinit();
    switch (term) {
        .exited => |code| try result.writer.print("exit {d}\n", .{code}),
        .signal => |sig| try result.writer.print("signal {d}\n", .{@intFromEnum(sig)}),
        .stopped => |sig| try result.writer.print("stopped {d}\n", .{@intFromEnum(sig)}),
        .unknown => |code| try result.writer.print("status {d}\n", .{code}),
    }
    try result.writer.writeAll(out);
    if (err.len != 0) {
        if (out.len != 0 and out[out.len - 1] != '\n') try result.writer.writeByte('\n');
        try result.writer.writeAll(err);
    }
    return result.toOwnedSlice();
}

fn killGroup(child: *std.process.Child) void {
    if (child.id) |pid| std.posix.kill(-pid, .KILL) catch {};
}

const testing = std.testing;
const testkit = @import("../testing/testkit.zig");

const Harness = struct {
    tmp: testing.TmpDir,
    threaded: std.Io.Threaded,
    db: @import("../data/db.zig").Db,
    buf: [160]u8 = undefined,
    workspace_path: []const u8 = undefined,

    fn init(self: *Harness) !void {
        self.tmp = testing.tmpDir(.{});
        self.threaded = .init(testing.allocator, .{});
        try self.tmp.dir.createDir(self.threaded.io(), "workspace", .default_dir);
        self.workspace_path = try std.fmt.bufPrint(&self.buf, ".zig-cache/tmp/{s}/workspace", .{self.tmp.sub_path});
        var db_path: [160]u8 = undefined;
        self.db = try testkit.tmpDb(&self.tmp, &db_path);
    }

    fn deinit(self: *Harness) void {
        self.db.close();
        self.threaded.deinit();
        self.tmp.cleanup();
    }

    fn ctx(self: *Harness, mode: tools.ShellMode) tools.Ctx {
        return .{
            .gpa = testing.allocator,
            .io = self.threaded.io(),
            .db = &self.db,
            .workspace = self.workspace_path,
            .shell_mode = mode,
        };
    }
};

test "allowlisted commands run with a clean environment" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    var ctx = h.ctx(.allowlist);
    const pwd = try tools.call(&ctx, &.{run}, "shell", "{\"argv\":[\"pwd\"]}");
    defer testing.allocator.free(pwd);
    try testing.expect(std.mem.startsWith(u8, pwd, "exit 0\n"));
    try testing.expect(std.mem.endsWith(u8, std.mem.trim(u8, pwd, "\n"), "/workspace"));

    ctx.shell_mode = .ask;
    const pending = try tools.call(&ctx, &.{run}, "shell", "{\"argv\":[\"env\"]}");
    defer testing.allocator.free(pending);
    try testing.expect(std.mem.indexOf(u8, pending, "approval required") != null);
    var q = try h.db.prepare("SELECT args FROM approvals ORDER BY id DESC LIMIT 1");
    defer q.finalize();
    try testing.expect(try q.step());
    const approved_args = try testing.allocator.dupe(u8, q.text(0));
    defer testing.allocator.free(approved_args);
    const approved = try tools.callApproved(&ctx, &.{run}, "shell", approved_args);
    defer testing.allocator.free(approved);
    try testing.expect(std.mem.indexOf(u8, approved, "LANG=C.UTF-8") != null);
    try testing.expect(std.mem.indexOf(u8, approved, "PATH=/usr/bin:/bin") != null);
    try testing.expect(std.mem.indexOf(u8, approved, "TELEGRAM") == null);
    try testing.expect(std.mem.indexOf(u8, approved, "LLM_") == null);
}

test "shell approval is bound to its workspace" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    var ctx = h.ctx(.ask);
    try testing.expectError(
        error.UnboundApproval,
        tools.callApproved(&ctx, &.{run}, "shell", "{\"argv\":[\"env\"]}"),
    );
}

test "shell rejects wrappers operators assignments and host paths" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    var ctx = h.ctx(.ask);
    const cases = [_][]const u8{
        "{\"argv\":[\"bash\",\"-c\",\"pwd\"]}",
        "{\"argv\":[\"pwd\",\"&&\",\"id\"]}",
        "{\"argv\":[\"pwd\",\"$(id)\"]}",
        "{\"argv\":[\"pwd\",\"A=B\"]}",
        "{\"argv\":[\"ls\",\"/etc\"]}",
        "{\"argv\":[\"ls\",\"../secret\"]}",
    };
    for (cases) |args| {
        const out = try tools.call(&ctx, &.{run}, "shell", args);
        defer testing.allocator.free(out);
        try testing.expect(std.mem.indexOf(u8, out, "tool error") != null);
    }
}

test "deny mode and allowlist misses fail closed" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    var ctx = h.ctx(.deny);
    const denied = try tools.call(&ctx, &.{run}, "shell", "{\"argv\":[\"pwd\"]}");
    defer testing.allocator.free(denied);
    try testing.expectEqualStrings("shell denied by policy", denied);

    ctx.shell_mode = .allowlist;
    const miss = try tools.call(&ctx, &.{run}, "shell", "{\"argv\":[\"env\"]}");
    defer testing.allocator.free(miss);
    try testing.expectEqualStrings("shell command is not allowlisted", miss);
}

test "temporary Wrangler deployment is exact and always asks" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    var ctx = h.ctx(.ask);
    try workspace_app.makeDir(h.threaded.io(), h.workspace_path, "reports/brief");
    try workspace_app.write(h.threaded.io(), h.workspace_path, "reports/brief/index.html", "<h1>Brief</h1>");
    const good = try tools.call(&ctx, &.{run}, "shell", "{\"argv\":[\"wrangler\",\"deploy\",\"reports/brief\",\"--name\",\"zoro-brief\",\"--temporary\",\"--compatibility-date\",\"2026-09-19\"]}");
    defer testing.allocator.free(good);
    try testing.expect(std.mem.indexOf(u8, good, "approval required") != null);

    const bad = [_][]const u8{
        "{\"argv\":[\"wrangler\",\"deploy\",\"../private\",\"--name\",\"zoro-brief\",\"--temporary\",\"--compatibility-date\",\"2026-09-19\"]}",
        "{\"argv\":[\"wrangler\",\"deploy\",\"reports/brief\",\"--name\",\"Bad_Name\",\"--temporary\",\"--compatibility-date\",\"2026-09-19\"]}",
        "{\"argv\":[\"wrangler\",\"deploy\",\"reports/brief\",\"--name\",\"zoro-brief\",\"--compatibility-date\",\"2026-09-19\",\"--temporary\"]}",
    };
    for (bad) |args| {
        const out = try tools.call(&ctx, &.{run}, "shell", args);
        defer testing.allocator.free(out);
        try testing.expect(std.mem.indexOf(u8, out, "InvalidArgs") != null);
    }

    try workspace_app.write(h.threaded.io(), h.workspace_path, "reports/brief/private.txt", "no");
    const extra = try tools.call(&ctx, &.{run}, "shell", "{\"argv\":[\"wrangler\",\"deploy\",\"reports/brief\",\"--name\",\"zoro-brief\",\"--temporary\",\"--compatibility-date\",\"2026-09-19\"]}");
    defer testing.allocator.free(extra);
    try testing.expect(std.mem.indexOf(u8, extra, "StaticSiteMustBeSingleIndex") != null);
}

test "shell bounds output and runtime" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    var ctx = h.ctx(.ask);
    const loud_args = try boundArgs(testing.allocator, h.workspace_path, &.{"yes"});
    defer testing.allocator.free(loud_args);
    const loud = try tools.callApproved(&ctx, &.{run}, "shell", loud_args);
    defer testing.allocator.free(loud);
    try testing.expectEqualStrings("shell output limit exceeded", loud);

    const slow_args = try boundArgs(testing.allocator, h.workspace_path, &.{ "sleep", "2" });
    defer testing.allocator.free(slow_args);
    const slow = try tools.callApproved(&ctx, &.{run}, "shell", slow_args);
    defer testing.allocator.free(slow);
    try testing.expectEqualStrings("shell timed out", slow);
}

test "shell cancellation stops an approved process" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    var ctx = h.ctx(.ask);
    var stop: std.atomic.Value(bool) = .init(true);
    ctx.cancel = &stop;
    const args = try boundArgs(testing.allocator, h.workspace_path, &.{ "sleep", "1" });
    defer testing.allocator.free(args);
    try testing.expectError(error.Cancelled, tools.callApproved(&ctx, &.{run}, "shell", args));
}

fn boundArgs(gpa: std.mem.Allocator, workspace: []const u8, argv: []const []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    try out.writer.print("{f}", .{std.json.fmt(.{ .argv = argv, .workspace = workspace }, .{})});
    return out.toOwnedSlice();
}
