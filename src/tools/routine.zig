const std = @import("std");
const tools = @import("root.zig");
const Db = @import("../data/db.zig").Db;

const name_param = [_]tools.Param{.{ .name = "name", .description = "routine name" }};

/// Owner-only; the model cannot enable mutations.
pub const enable_routine: tools.Def = .{
    .name = "enable_routine",
    .description = "Enable an approved routine.",
    .params = &name_param,
    .mutates = true,
    .run = runEnable,
};

/// Allows one approved critical run.
pub const run_routine: tools.Def = .{
    .name = "run_routine",
    .description = "Run an approved routine.",
    .params = &name_param,
    .mutates = true,
    .run = runNow,
};

const Args = struct { name: []const u8 };

fn runEnable(ctx: *tools.Ctx, args: []const u8) anyerror![]u8 {
    const parsed = try std.json.parseFromSlice(Args, ctx.gpa, args, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    try update(ctx.db, "UPDATE routines SET enabled = 1, status = 'ok' WHERE name = ?", parsed.value.name);
    return std.fmt.allocPrint(ctx.gpa, "{s} is active", .{parsed.value.name});
}

fn runNow(ctx: *tools.Ctx, args: []const u8) anyerror![]u8 {
    const parsed = try std.json.parseFromSlice(Args, ctx.gpa, args, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    try update(ctx.db, "UPDATE routines SET next = 0, status = 'approved' WHERE name = ?", parsed.value.name);
    return std.fmt.allocPrint(ctx.gpa, "{s} will run on the next tick", .{parsed.value.name});
}

fn update(db: *Db, sql: [:0]const u8, name: []const u8) !void {
    var q = try db.prepare(sql);
    defer q.finalize();
    try q.bind(1, name);
    _ = try q.step();
}
