const std = @import("std");
const tools = @import("root.zig");
const Db = @import("../data/db.zig").Db;

const name_param = [_]tools.Param{.{ .name = "name", .description = "routine name" }};

/// Owner-only, and never advertised to the model: the whole point of the
/// mutating tier is that the agent cannot switch itself on.
pub const enable_routine: tools.Def = .{
    .name = "enable_routine",
    .description = "Activate a routine that is waiting for approval.",
    .params = &name_param,
    .mutates = true,
    .run = runEnable,
};

/// One approved firing of a `critical` routine. The scheduler consumes the
/// flag on the next tick, so approving twice does not queue two runs.
pub const run_routine: tools.Def = .{
    .name = "run_routine",
    .description = "Let a critical routine execute once.",
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
