const std = @import("std");
const skills = @import("skills.zig");
const cron = @import("cron.zig");
const testing = std.testing;

const bundled = [_][]const u8{
    @embedFile("default_skills/weather-watch/SKILL.md"),
    @embedFile("default_skills/rss-watch/SKILL.md"),
    @embedFile("default_skills/html-report/SKILL.md"),
    @embedFile("default_skills/publish-static/SKILL.md"),
};

/// Installs missing defaults without replacing owner edits.
pub fn install(gpa: std.mem.Allocator, io: std.Io, root: []const u8) !void {
    for (bundled) |markdown| {
        const skill = try skills.parse(markdown);
        var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buf, "{s}/{s}/SKILL.md", .{ root, skill.name });
        if (std.Io.Dir.cwd().openFile(io, path, .{})) |file| {
            file.close(io);
            continue;
        } else |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        }
        _ = try skills.save(gpa, io, root, markdown);
    }
}

test "defaults install once and preserve owner edits" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var buf: [160]u8 = undefined;
    const root = try std.fmt.bufPrint(&buf, ".zig-cache/tmp/{s}/skills", .{tmp.sub_path});

    for (bundled) |markdown| {
        const skill = try skills.parse(markdown);
        if (skill.schedule) |schedule| _ = try cron.parse(schedule);
    }

    try install(testing.allocator, io, root);
    const names = try skills.list(testing.allocator, io, root);
    defer {
        for (names) |name| testing.allocator.free(name);
        testing.allocator.free(names);
    }
    try testing.expectEqual(@as(usize, bundled.len), names.len);

    const custom = "---\nname: html-report\ndescription: custom\n---\nowner edit";
    _ = try skills.save(testing.allocator, io, root, custom);
    try install(testing.allocator, io, root);
    const got = try skills.readMarkdown(testing.allocator, io, root, "html-report");
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(custom, got);
}
