const std = @import("std");
const web = @import("../net/web.zig");

pub const max_path: usize = 512;
pub const max_read: usize = 64 * 1024;
pub const max_write: usize = web.max_body;
pub const trunc_mark = "\n[truncated]";

const Parent = struct {
    dir: std.Io.Dir,
    name: []const u8,

    fn close(self: Parent, io: std.Io) void {
        self.dir.close(io);
    }
};

pub fn validPath(path: []const u8) bool {
    if (path.len == 0 or path.len > max_path or std.fs.path.isAbsolute(path)) return false;
    for (path) |c| if (c < 0x20 or c == 0x7f or c == '"' or c == '\\') return false;
    var it = std.mem.splitScalar(u8, path, '/');
    while (it.next()) |part| {
        if (part.len == 0 or part.len > 255) return false;
        if (std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return false;
        if (protected(part)) return false;
    }
    return true;
}

fn protected(part: []const u8) bool {
    if (std.mem.eql(u8, part, ".git") or
        std.mem.eql(u8, part, ".agents") or
        std.mem.eql(u8, part, ".claude") or
        std.mem.eql(u8, part, ".commandcode") or
        std.mem.eql(u8, part, "credentials") or
        std.mem.eql(u8, part, "credentials.json") or
        std.mem.eql(u8, part, "secrets")) return true;
    if (std.mem.eql(u8, part, ".env") or std.mem.startsWith(u8, part, ".env.")) return true;
    return std.mem.endsWith(u8, part, ".db") or
        std.mem.endsWith(u8, part, ".db-wal") or
        std.mem.endsWith(u8, part, ".db-shm") or
        std.mem.endsWith(u8, part, ".sqlite") or
        std.mem.endsWith(u8, part, ".sqlite3");
}

fn openParent(io: std.Io, root: []const u8, path: []const u8) !Parent {
    if (!validPath(path)) return error.BadPath;
    var dir = try std.Io.Dir.cwd().openDir(io, root, .{ .follow_symlinks = false });
    errdefer dir.close(io);

    const slash = std.mem.lastIndexOfScalar(u8, path, '/') orelse
        return .{ .dir = dir, .name = path };
    var it = std.mem.splitScalar(u8, path[0..slash], '/');
    while (it.next()) |part| {
        const next = try dir.openDir(io, part, .{ .follow_symlinks = false });
        dir.close(io);
        dir = next;
    }
    return .{ .dir = dir, .name = path[slash + 1 ..] };
}

pub fn openFile(io: std.Io, root: []const u8, path: []const u8) !std.Io.File {
    const parent = try openParent(io, root, path);
    defer parent.close(io);
    return parent.dir.openFile(io, parent.name, .{
        .allow_directory = false,
        .follow_symlinks = false,
        .resolve_beneath = true,
    });
}

pub fn checkExisting(io: std.Io, root: []const u8, path: []const u8) !void {
    const parent = try openParent(io, root, path);
    defer parent.close(io);
    if (parent.dir.openFile(io, parent.name, .{
        .allow_directory = false,
        .follow_symlinks = false,
        .resolve_beneath = true,
    })) |file| {
        file.close(io);
        return;
    } else |err| switch (err) {
        error.IsDir => {},
        else => return err,
    }
    const dir = try parent.dir.openDir(io, parent.name, .{ .follow_symlinks = false });
    dir.close(io);
}

pub fn checkFile(io: std.Io, root: []const u8, path: []const u8, limit: usize) !void {
    var file = try openFile(io, root, path);
    defer file.close(io);
    const stat = try file.stat(io);
    if (stat.kind != .file) return error.NotFile;
    if (stat.size > limit) return error.FileTooLarge;
}

pub fn makeDir(io: std.Io, root: []const u8, path: []const u8) !void {
    if (!validPath(path)) return error.BadPath;
    var dir = try std.Io.Dir.cwd().openDir(io, root, .{ .follow_symlinks = false });
    defer dir.close(io);
    var it = std.mem.splitScalar(u8, path, '/');
    while (it.next()) |part| {
        dir.createDir(io, part, .default_dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };
        const next = try dir.openDir(io, part, .{ .follow_symlinks = false });
        dir.close(io);
        dir = next;
    }
}

pub fn read(gpa: std.mem.Allocator, io: std.Io, root: []const u8, path: []const u8) ![]u8 {
    return readLimited(gpa, io, root, path, max_read, true);
}

pub fn readExact(gpa: std.mem.Allocator, io: std.Io, root: []const u8, path: []const u8, limit: usize) ![]u8 {
    return readLimited(gpa, io, root, path, limit, false);
}

pub fn readBytes(gpa: std.mem.Allocator, io: std.Io, root: []const u8, path: []const u8, limit: usize) ![]u8 {
    var file = try openFile(io, root, path);
    defer file.close(io);
    const stat = try file.stat(io);
    if (stat.kind != .file) return error.NotFile;
    if (stat.size > limit) return error.FileTooLarge;
    const n: usize = @intCast(stat.size);
    const out = try gpa.alloc(u8, n);
    errdefer gpa.free(out);
    if (try file.readPositionalAll(io, out, 0) != n) return error.ShortRead;
    return out;
}

pub fn readLimited(gpa: std.mem.Allocator, io: std.Io, root: []const u8, path: []const u8, limit: usize, truncate: bool) ![]u8 {
    var file = try openFile(io, root, path);
    defer file.close(io);
    const stat = try file.stat(io);
    if (stat.kind != .file) return error.NotFile;
    if (!truncate and stat.size > limit) return error.FileTooLarge;
    const n: usize = @intCast(@min(stat.size, limit));
    const extra = if (truncate and stat.size > limit) trunc_mark.len else 0;
    const out = try gpa.alloc(u8, n + extra);
    errdefer gpa.free(out);
    const got = try file.readPositionalAll(io, out[0..n], 0);
    if (got != n) return error.ShortRead;
    if (!std.unicode.utf8ValidateSlice(out[0..n]) or std.mem.indexOfScalar(u8, out[0..n], 0) != null)
        return error.UnsupportedBinary;
    if (extra != 0) @memcpy(out[n..], trunc_mark);
    return out;
}

pub fn write(io: std.Io, root: []const u8, path: []const u8, content: []const u8) !void {
    if (content.len > max_write) return error.FileTooLarge;
    const parent = try openParent(io, root, path);
    defer parent.close(io);
    var atomic = try parent.dir.createFileAtomic(io, parent.name, .{ .replace = true });
    defer atomic.deinit(io);
    try atomic.file.writeStreamingAll(io, content);
    try atomic.replace(io);
}

pub fn delete(io: std.Io, root: []const u8, path: []const u8) !void {
    const parent = try openParent(io, root, path);
    defer parent.close(io);
    var file = try parent.dir.openFile(io, parent.name, .{
        .allow_directory = false,
        .follow_symlinks = false,
        .resolve_beneath = true,
    });
    file.close(io);
    try parent.dir.deleteFile(io, parent.name);
}
