const std = @import("std");
const tools = @import("tools.zig");
const testing = std.testing;

pub const Skill = struct {
    name: []const u8,
    description: []const u8,
    schedule: ?[]const u8 = null,
    timezone: ?[]const u8 = null,
    authority: ?[]const u8 = null,
    allowed_tools: ?[]const u8 = null,
    model: ?[]const u8 = null,
    body: []const u8,
};

/// What a routine may do when the scheduler fires it. Unrecognised text falls
/// back to the most restrictive tier, so a typo can never widen authority.
pub const Authority = enum {
    notify,
    safe,
    critical,

    pub fn of(text: ?[]const u8) Authority {
        const t = text orelse return .notify;
        inline for (std.meta.fields(Authority)) |f| {
            if (std.ascii.eqlIgnoreCase(t, f.name)) return @field(Authority, f.name);
        }
        return .notify;
    }

    /// `notify` reads, analyses and messages the owner. It never mutates.
    pub fn readOnly(self: Authority) bool {
        return self == .notify;
    }
};

pub const Entry = struct {
    name: []u8,
    description: []u8,

    fn deinit(self: Entry, gpa: std.mem.Allocator) void {
        gpa.free(self.name);
        gpa.free(self.description);
    }
};

pub fn freeIndex(gpa: std.mem.Allocator, entries: []Entry) void {
    for (entries) |e| e.deinit(gpa);
    gpa.free(entries);
}

/// Slices borrow from `text`.
pub fn parse(text: []const u8) !Skill {
    var rest = std.mem.trim(u8, text, "\r\n");
    if (!std.mem.startsWith(u8, rest, "---")) return error.MissingFrontmatter;
    rest = rest[3..];
    if (rest.len > 0 and rest[0] == '\n') rest = rest[1..] else if (std.mem.startsWith(u8, rest, "\r\n")) rest = rest[2..] else return error.MissingFrontmatter;

    const end = std.mem.indexOf(u8, rest, "\n---") orelse return error.MissingFrontmatter;
    const fm = rest[0..end];
    var body = rest[end + 4 ..];
    if (body.len > 0 and body[0] == '\n') body = body[1..] else if (std.mem.startsWith(u8, body, "\r\n")) body = body[2..];
    body = std.mem.trim(u8, body, " \t\r\n");

    var skill: Skill = .{ .name = "", .description = "", .body = body };
    var lines = std.mem.splitScalar(u8, fm, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse return error.BadFrontmatter;
        const key = std.mem.trim(u8, line[0..colon], " \t");
        const val = unquote(std.mem.trim(u8, line[colon + 1 ..], " \t"));
        if (std.mem.eql(u8, key, "name")) {
            skill.name = val;
        } else if (std.mem.eql(u8, key, "description")) {
            skill.description = val;
        } else if (std.mem.eql(u8, key, "schedule")) {
            skill.schedule = val;
        } else if (std.mem.eql(u8, key, "timezone")) {
            skill.timezone = val;
        } else if (std.mem.eql(u8, key, "authority")) {
            skill.authority = val;
        } else if (std.mem.eql(u8, key, "allowed-tools")) {
            skill.allowed_tools = val;
        } else if (std.mem.eql(u8, key, "model")) {
            skill.model = val;
        }
    }
    if (skill.name.len == 0) return error.MissingName;
    if (skill.description.len == 0) return error.MissingDescription;
    if (!validName(skill.name)) return error.BadName;
    return skill;
}

pub fn list(gpa: std.mem.Allocator, io: std.Io, dir: []const u8) ![]Entry {
    var root = std.Io.Dir.cwd().openDir(io, dir, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return &.{},
        else => return err,
    };
    defer root.close(io);

    var out: std.ArrayList(Entry) = .empty;
    errdefer {
        for (out.items) |e| e.deinit(gpa);
        out.deinit(gpa);
    }

    var it = root.iterate();
    while (try it.next(io)) |ent| {
        if (ent.kind != .directory) continue;
        const text = readSkill(gpa, io, dir, ent.name) catch continue;
        defer gpa.free(text);
        const skill = parse(text) catch continue;
        try out.append(gpa, .{
            .name = try gpa.dupe(u8, skill.name),
            .description = try gpa.dupe(u8, skill.description),
        });
    }
    return out.toOwnedSlice(gpa);
}

/// Caller owns the body text.
pub fn load(gpa: std.mem.Allocator, io: std.Io, dir: []const u8, name: []const u8) ![]u8 {
    if (!validName(name)) return error.BadName;
    const text = try readSkill(gpa, io, dir, name);
    defer gpa.free(text);
    const skill = try parse(text);
    return try gpa.dupe(u8, skill.body);
}

pub fn save(gpa: std.mem.Allocator, io: std.Io, dir: []const u8, markdown: []const u8) ![]const u8 {
    const skill = try parse(markdown);
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const sub = try std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ dir, skill.name });
    try std.Io.Dir.cwd().createDirPath(io, sub);
    var d = try std.Io.Dir.cwd().openDir(io, sub, .{});
    defer d.close(io);
    try d.writeFile(io, .{ .sub_path = "SKILL.md", .data = markdown });
    _ = gpa;
    return skill.name;
}

fn readSkill(gpa: std.mem.Allocator, io: std.Io, dir: []const u8, name: []const u8) ![]u8 {
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/{s}/SKILL.md", .{ dir, name });
    return std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(64 * 1024));
}

fn unquote(s: []const u8) []const u8 {
    if (s.len >= 2 and ((s[0] == '"' and s[s.len - 1] == '"') or (s[0] == '\'' and s[s.len - 1] == '\''))) {
        return s[1 .. s.len - 1];
    }
    return s;
}

pub fn validName(name: []const u8) bool {
    if (name.len == 0 or name.len > 64) return false;
    for (name) |c| {
        const ok = std.ascii.isAlphanumeric(c) or c == '-' or c == '_';
        if (!ok) return false;
    }
    return name[0] != '-' and name[0] != '_';
}

const name_param = [_]tools.Param{.{ .name = "name", .description = "skill name" }};
const content_param = [_]tools.Param{.{ .name = "content", .description = "full SKILL.md including frontmatter" }};

pub const load_skill: tools.Def = .{
    .name = "load_skill",
    .description = "Load a skill's instructions by name.",
    .params = &name_param,
    .run = runLoad,
};

pub const save_skill: tools.Def = .{
    .name = "save_skill",
    .description = "Write a SKILL.md. Content must include name and description frontmatter.",
    .params = &content_param,
    .mutates = true,
    .run = runSave,
};

const NameArgs = struct { name: []const u8 };
const ContentArgs = struct { content: []const u8 };

fn runLoad(ctx: *tools.Ctx, args: []const u8) anyerror![]u8 {
    const parsed = try std.json.parseFromSlice(NameArgs, ctx.gpa, args, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    return load(ctx.gpa, ctx.io, ctx.skills_dir, parsed.value.name) catch |err|
        return std.fmt.allocPrint(ctx.gpa, "could not load skill: {s}", .{@errorName(err)});
}

fn runSave(ctx: *tools.Ctx, args: []const u8) anyerror![]u8 {
    const parsed = try std.json.parseFromSlice(ContentArgs, ctx.gpa, args, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    const name = save(ctx.gpa, ctx.io, ctx.skills_dir, parsed.value.content) catch |err|
        return std.fmt.allocPrint(ctx.gpa, "could not save skill: {s}", .{@errorName(err)});
    return try std.fmt.allocPrint(ctx.gpa, "saved skill {s}", .{name});
}

test "parse requires name and description" {
    try testing.expectError(error.MissingFrontmatter, parse("just a body"));
    try testing.expectError(error.MissingName, parse("---\ndescription: x\n---\nbody"));
    try testing.expectError(error.MissingDescription, parse("---\nname: foo\n---\nbody"));
}

test "parse reads required fields, body, and a schedule" {
    const s = try parse(
        \\---
        \\name: morning-brief
        \\description: Summarize overnight mail
        \\schedule: "0 7 * * *"
        \\allowed-tools: fetch_url remember
        \\---
        \\
        \\Check mail first.
    );
    try testing.expectEqualStrings("morning-brief", s.name);
    try testing.expectEqualStrings("Summarize overnight mail", s.description);
    try testing.expectEqualStrings("0 7 * * *", s.schedule.?);
    try testing.expectEqualStrings("fetch_url remember", s.allowed_tools.?);
    try testing.expectEqualStrings("Check mail first.", s.body);
}

test "save then load round-trips, and the index is name plus description only" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var dir_buf: [128]u8 = undefined;
    const dir = try std.fmt.bufPrint(&dir_buf, ".zig-cache/tmp/{s}/skills", .{tmp.sub_path});

    const md =
        \\---
        \\name: weather
        \\description: Look up the forecast
        \\---
        \\
        \\Call fetch_url on wttr.in.
    ;
    _ = try save(testing.allocator, io, dir, md);
    const body = try load(testing.allocator, io, dir, "weather");
    defer testing.allocator.free(body);
    try testing.expectEqualStrings("Call fetch_url on wttr.in.", body);

    const entries = try list(testing.allocator, io, dir);
    defer freeIndex(testing.allocator, entries);
    try testing.expectEqual(@as(usize, 1), entries.len);
    try testing.expectEqualStrings("weather", entries[0].name);
    try testing.expectEqualStrings("Look up the forecast", entries[0].description);
}

test "save rejects a path-like name" {
    try testing.expectError(error.BadName, parse("---\nname: ../etc\ndescription: x\n---\nbody"));
}

test "authority falls back to notify for missing and unknown tiers" {
    try testing.expectEqual(Authority.notify, Authority.of(null));
    try testing.expectEqual(Authority.notify, Authority.of("nonsense"));
    try testing.expectEqual(Authority.notify, Authority.of("NOTIFY"));
    try testing.expectEqual(Authority.safe, Authority.of("safe"));
    try testing.expectEqual(Authority.critical, Authority.of("critical"));
    try testing.expect(Authority.of("notify").readOnly());
    try testing.expect(!Authority.of("safe").readOnly());
}
