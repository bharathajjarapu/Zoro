const std = @import("std");
const tools = @import("root.zig");
const workspace = @import("../app/workspace.zig");

const max_extract: usize = 4 * 1024 * 1024;
const max_error: usize = 4096;
const timeout = std.Io.Timeout{ .duration = .{
    .clock = .awake,
    .raw = .fromSeconds(10),
} };

const params = [_]tools.Param{.{ .name = "path", .description = "workspace document" }};

pub const inspect_file: tools.Def = .{
    .name = "inspect_file",
    .description = "Extract document text.",
    .params = &params,
    .run = run,
};

fn run(ctx: *tools.Ctx, args: []const u8) ![]u8 {
    if (args.len > workspace.max_path + 64) return error.InvalidArgs;
    const Args = struct { path: []const u8 };
    const parsed = try std.json.parseFromSlice(Args, ctx.gpa, args, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    const dir = try std.process.executableDirPathAlloc(ctx.io, ctx.gpa);
    defer ctx.gpa.free(dir);
    const helper = try std.fs.path.join(ctx.gpa, &.{ dir, "anydoc" });
    defer ctx.gpa.free(helper);
    return extract(ctx, helper, parsed.value.path);
}

fn extract(ctx: *tools.Ctx, helper: []const u8, path: []const u8) ![]u8 {
    if (!workspace.validPath(path)) return error.BadPath;
    if (path.len > workspace.max_path - ".md".len) return error.BadPath;
    try workspace.checkFile(ctx.io, ctx.workspace, path, workspace.max_transfer);
    if (ctx.cancelled()) return error.Cancelled;

    var env = std.process.Environ.Map.init(ctx.gpa);
    defer env.deinit();
    try env.put("LANG", "C.UTF-8");
    var dir = try std.Io.Dir.cwd().openDir(ctx.io, ctx.workspace, .{ .follow_symlinks = false });
    defer dir.close(ctx.io);

    const result = try std.process.run(ctx.gpa, ctx.io, .{
        .argv = &.{ helper, path },
        .cwd = .{ .dir = dir },
        .environ_map = &env,
        .stdout_limit = .limited(max_extract),
        .stderr_limit = .limited(max_error),
        .timeout = timeout,
    });
    defer ctx.gpa.free(result.stdout);
    defer ctx.gpa.free(result.stderr);
    if (ctx.cancelled()) return error.Cancelled;

    switch (result.term) {
        .exited => |code| {
            if (code == 3) return ctx.gpa.dupe(u8, "This PDF needs OCR.");
            if (code != 0) return failure(ctx.gpa, result.stderr);
        },
        else => return ctx.gpa.dupe(u8, "Document extraction failed."),
    }
    if (!std.unicode.utf8ValidateSlice(result.stdout) or std.mem.indexOfScalar(u8, result.stdout, 0) != null)
        return error.UnsupportedBinary;

    const output = try std.fmt.allocPrint(ctx.gpa, "{s}.md", .{path});
    defer ctx.gpa.free(output);
    try workspace.writeBounded(ctx.io, ctx.workspace, output, result.stdout, max_extract);
    return std.fmt.allocPrint(ctx.gpa, "[saved {s}]\n{s}", .{ output, result.stdout });
}

fn failure(gpa: std.mem.Allocator, stderr: []const u8) ![]u8 {
    if (!std.unicode.utf8ValidateSlice(stderr)) return gpa.dupe(u8, "Document extraction failed.");
    const message = std.mem.trim(u8, stderr, " \t\r\n");
    if (message.len == 0) return gpa.dupe(u8, "Document extraction failed.");
    return std.fmt.allocPrint(gpa, "Document extraction failed: {s}", .{message});
}

const testing = std.testing;
const testkit = @import("../testing/testkit.zig");

test "document extraction stays in workspace" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    try tmp.dir.createDir(io, "workspace", .default_dir);
    var path_buf: [160]u8 = undefined;
    const root = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}/workspace", .{tmp.sub_path});
    try workspace.write(io, root, "report.docx", "hello");

    var db_buf: [160]u8 = undefined;
    var db = try testkit.tmpDb(&tmp, &db_buf);
    defer db.close();
    var ctx: tools.Ctx = .{ .gpa = testing.allocator, .io = io, .db = &db, .workspace = root };
    const out = try extract(&ctx, "/bin/cat", "report.docx");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("[saved report.docx.md]\nhello", out);
    const saved = try workspace.read(testing.allocator, io, root, "report.docx.md");
    defer testing.allocator.free(saved);
    try testing.expectEqualStrings("hello", saved);
}
