const std = @import("std");
const workspace = @import("../app/workspace.zig");

pub const max_file: usize = 16 * 1024;
pub const max_total: usize = 48 * 1024;
const trunc_mark = "\n[truncated]";

pub const File = enum { soul, identity, user, memory };
const names = [_][]const u8{ "SOUL.md", "IDENTITY.md", "USER.md", "MEMORY.md" };

pub fn name(file: File) []const u8 {
    return names[@intFromEnum(file)];
}

/// Caller owns the ordered, visibly bounded prompt context.
pub fn load(gpa: std.mem.Allocator, io: std.Io, root: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    for (names) |file_name| {
        const file_text = workspace.readLimited(gpa, io, root, file_name, max_file, true) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => return err,
        };
        defer gpa.free(file_text);
        if (out.items.len != 0) try out.appendSlice(gpa, "\n\n");
        try out.print(gpa, "## {s}\n\n", .{file_name[0 .. file_name.len - 3]});
        try out.appendSlice(gpa, file_text);
        if (out.items.len >= max_total) break;
    }
    if (out.items.len > max_total) {
        var end = max_total - trunc_mark.len;
        while (end > 0 and out.items[end] & 0xc0 == 0x80) end -= 1;
        out.items.len = end;
        try out.appendSlice(gpa, trunc_mark);
    }
    return out.toOwnedSlice(gpa);
}

pub fn read(gpa: std.mem.Allocator, io: std.Io, root: []const u8, file: File) ![]u8 {
    return workspace.readExact(gpa, io, root, name(file), max_file);
}

pub fn write(io: std.Io, root: []const u8, file: File, text: []const u8) !void {
    try validate(text);
    try workspace.write(io, root, name(file), text);
}

pub fn validate(text: []const u8) !void {
    if (text.len > max_file) return error.FileTooLarge;
    if (protected(text)) return error.ProtectedContent;
}

pub fn reset(io: std.Io, root: []const u8, file: File) !void {
    workspace.delete(io, root, name(file)) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
}

fn protected(text: []const u8) bool {
    const bad = [_][]const u8{
        "TELEGRAM_TOKEN=", "LLM_API_KEY=",    "TINYFISH_API_KEY=", "BEGIN PRIVATE KEY",
        "allowed-tools:",  "ZORO_WORKSPACE=", "ZORO_SHELL=",       "schedule:",
    };
    for (bad) |word| if (std.ascii.indexOfIgnoreCase(text, word) != null) return true;
    return false;
}

const testing = std.testing;

test "identity context loads fixed files in order and tolerates missing files" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    try tmp.dir.writeFile(io, .{ .sub_path = "USER.md", .data = "Likes short replies." });
    try tmp.dir.writeFile(io, .{ .sub_path = "SOUL.md", .data = "Calm and direct." });
    var path: [160]u8 = undefined;
    const root = try std.fmt.bufPrint(&path, ".zig-cache/tmp/{s}", .{tmp.sub_path});

    const text = try load(testing.allocator, io, root);
    defer testing.allocator.free(text);
    const soul = std.mem.indexOf(u8, text, "## SOUL") orelse return error.MissingSoul;
    const user = std.mem.indexOf(u8, text, "## USER") orelse return error.MissingUser;
    try testing.expect(soul < user);
    try testing.expect(std.mem.indexOf(u8, text, "IDENTITY") == null);
}

test "identity updates are atomic and reject authority text" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var path: [160]u8 = undefined;
    const root = try std.fmt.bufPrint(&path, ".zig-cache/tmp/{s}", .{tmp.sub_path});

    try write(io, root, .soul, "Be concise.");
    try testing.expectError(error.ProtectedContent, write(io, root, .soul, "allowed-tools: shell"));
    const current = try read(testing.allocator, io, root, .soul);
    defer testing.allocator.free(current);
    try testing.expectEqualStrings("Be concise.", current);
}
