const std = @import("std");
const testing = std.testing;
const workspace_guard = @import("workspace.zig");

const log = std.log.scoped(.config);

pub const ShellMode = enum { deny, allowlist, ask };

/// Pointer storage prevents accidental secret formatting.
pub const Secret = struct {
    ptr: [*]const u8,
    len: usize,

    pub fn init(val: []const u8) Secret {
        return .{ .ptr = val.ptr, .len = val.len };
    }

    pub fn reveal(self: Secret) []const u8 {
        return self.ptr[0..self.len];
    }

    pub fn format(self: Secret, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        _ = self;
        try writer.writeAll("[redacted]");
    }
};

pub const Config = struct {
    /// Owned storage borrowed by parsed values.
    text: []u8 = &.{},

    telegram_token: ?Secret = null,
    owner_id: ?i64 = null,
    chat_id: ?i64 = null,
    api_key: ?Secret = null,
    tinyfish_key: ?Secret = null,
    /// Callers apply the default model endpoint.
    base_url: ?[]const u8 = null,
    model: ?[]const u8 = null,
    runtime_root: []const u8 = "",
    data_dir: []const u8 = "data",
    /// Only this directory permits file access.
    workspace: []const u8 = "workspace",
    skills_dir: []const u8 = "skills",
    inbox_dir: []const u8 = "inbox",
    tmp_dir: []const u8 = "tmp",
    shell_mode: ShellMode = .ask,
    home: ?[]const u8 = null,
    owned_paths: [6]?[]u8 = .{ null, null, null, null, null, null },

    /// Later values override earlier ones.
    fn set(self: *Config, key: []const u8, val: []const u8) void {
        if (val.len == 0) return;
        const eql = std.mem.eql;
        if (eql(u8, key, "TELEGRAM_TOKEN")) {
            self.telegram_token = .init(val);
        } else if (eql(u8, key, "OWNER_ID")) {
            self.owner_id = std.fmt.parseInt(i64, val, 10) catch blk: {
                log.warn("{s} is not a number", .{key});
                break :blk null;
            };
        } else if (eql(u8, key, "CHAT_ID")) {
            self.chat_id = std.fmt.parseInt(i64, val, 10) catch blk: {
                log.warn("{s} is not a number", .{key});
                break :blk null;
            };
        } else if (eql(u8, key, "LLM_API_KEY")) {
            self.api_key = .init(val);
        } else if (eql(u8, key, "LLM_BASE_URL")) {
            self.base_url = val;
        } else if (eql(u8, key, "LLM_MODEL")) {
            self.model = val;
        } else if (eql(u8, key, "TINYFISH_API_KEY")) {
            self.tinyfish_key = .init(val);
        } else if (eql(u8, key, "ZORO_DATA_DIR")) {
            self.data_dir = val;
        } else if (eql(u8, key, "ZORO_WORKSPACE")) {
            self.workspace = val;
        } else if (eql(u8, key, "ZORO_SKILLS_DIR")) {
            self.skills_dir = val;
        } else if (eql(u8, key, "ZORO_INBOX_DIR")) {
            self.inbox_dir = val;
        } else if (eql(u8, key, "ZORO_TMP_DIR")) {
            self.tmp_dir = val;
        } else if (eql(u8, key, "ZORO_SHELL")) {
            self.shell_mode = std.meta.stringToEnum(ShellMode, val) orelse blk: {
                log.warn("ZORO_SHELL must be deny, allowlist, or ask", .{});
                break :blk .deny;
            };
        } else if (eql(u8, key, "ZORO_HOME")) {
            self.home = val;
        } else if (eql(u8, key, "ZORO_ENV_FILE")) {
            return;
        } else if (std.mem.startsWith(u8, key, "ZORO_") or std.mem.startsWith(u8, key, "LLM_") or std.mem.startsWith(u8, key, "TINYFISH_")) {
            // Log names only because values may be secrets.
            log.warn("unknown config key: {s}", .{key});
        }
    }

    pub fn deinit(self: *Config, gpa: std.mem.Allocator) void {
        gpa.free(self.text);
        for (&self.owned_paths) |*path| if (path.*) |value| gpa.free(value);
        self.* = undefined;
    }

    /// Environment values override file values.
    pub fn overlay(self: *Config, env: *const std.process.Environ.Map) void {
        var iterator = env.iterator();
        while (iterator.next()) |entry| self.set(entry.key_ptr.*, entry.value_ptr.*);
    }

    pub fn inboxRelative(self: Config) ![]const u8 {
        const root = std.mem.trimEnd(u8, self.workspace, "/");
        if (root.len == 0 or self.inbox_dir.len <= root.len or
            !std.mem.eql(u8, self.inbox_dir[0..root.len], root) or
            self.inbox_dir[root.len] != '/') return error.InboxOutsideWorkspace;
        const rel = self.inbox_dir[root.len + 1 ..];
        if (!workspace_guard.validPath(rel)) return error.InboxOutsideWorkspace;
        return rel;
    }
};

/// Reports only the missing key name.
pub fn missing(key: []const u8) error{MissingConfig} {
    log.err("missing required config: {s} — set it in .env or the environment", .{key});
    return error.MissingConfig;
}

/// Bounds accidental reads from a wrong path.
const max_env_bytes = 64 * 1024;

/// Caller owns the result; a missing file yields empty config.
pub fn load(gpa: std.mem.Allocator, io: std.Io, path: []const u8) !Config {
    const text = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(max_env_bytes)) catch |err| switch (err) {
        error.FileNotFound => return .{},
        else => return err,
    };
    errdefer gpa.free(text);

    var cfg = parse(text);
    cfg.text = text;
    return cfg;
}

pub fn loadRuntime(gpa: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map) !Config {
    const default_root = env.get("ZORO_HOME") orelse blk: {
        if (env.get("XDG_DATA_HOME")) |base| break :blk try std.fmt.allocPrint(gpa, "{s}/zoro", .{base});
        if (env.get("HOME")) |base| break :blk try std.fmt.allocPrint(gpa, "{s}/.local/share/zoro", .{base});
        return error.MissingHome;
    };
    defer if (env.get("ZORO_HOME") == null) gpa.free(default_root);
    const default_env = if (env.get("ZORO_ENV_FILE") == null)
        try std.fmt.allocPrint(gpa, "{s}/.env", .{default_root})
    else
        null;
    defer if (default_env) |path| gpa.free(path);
    const env_file = env.get("ZORO_ENV_FILE") orelse default_env.?;
    var cfg = try load(gpa, io, env_file);
    errdefer cfg.deinit(gpa);
    cfg.overlay(env);

    const root = cfg.home orelse blk: {
        if (env.get("XDG_DATA_HOME")) |base| break :blk try std.fmt.allocPrint(gpa, "{s}/zoro", .{base});
        if (env.get("HOME")) |base| break :blk try std.fmt.allocPrint(gpa, "{s}/.local/share/zoro", .{base});
        break :blk default_root;
    };
    defer if (cfg.home == null) gpa.free(root);
    if (!std.fs.path.isAbsolute(root)) return error.BadRuntimePath;
    cfg.runtime_root = try ownPath(gpa, &cfg.owned_paths[0], root);

    cfg.data_dir = try configuredPath(gpa, &cfg.owned_paths[1], root, cfg.data_dir);
    cfg.workspace = try configuredPath(gpa, &cfg.owned_paths[2], root, cfg.workspace);
    cfg.skills_dir = try configuredPath(gpa, &cfg.owned_paths[3], root, cfg.skills_dir);
    cfg.inbox_dir = try configuredPath(gpa, &cfg.owned_paths[4], cfg.workspace, cfg.inbox_dir);
    cfg.tmp_dir = try configuredPath(gpa, &cfg.owned_paths[5], root, cfg.tmp_dir);
    _ = try cfg.inboxRelative();
    return cfg;
}

fn ownPath(gpa: std.mem.Allocator, slot: *?[]u8, value: []const u8) ![]const u8 {
    slot.* = try gpa.dupe(u8, value);
    return slot.*.?;
}

fn child(gpa: std.mem.Allocator, slot: *?[]u8, root: []const u8, name: []const u8) ![]const u8 {
    slot.* = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ root, name });
    return slot.*.?;
}

fn configuredPath(gpa: std.mem.Allocator, slot: *?[]u8, root: []const u8, value: []const u8) ![]const u8 {
    if (std.fs.path.isAbsolute(value)) return ownPath(gpa, slot, value);
    if (!workspace_guard.validPath(value)) return error.BadRuntimePath;
    return child(gpa, slot, root, value);
}

/// Parsed slices borrow from `text`.
fn parse(text: []const u8) Config {
    var cfg: Config = .{};
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        cfg.set(
            std.mem.trim(u8, line[0..eq], " \t"),
            std.mem.trim(u8, line[eq + 1 ..], " \t"),
        );
    }
    return cfg;
}

test "parse reads keys, skipping comments and blanks" {
    const cfg = parse(
        \\# bootstrap
        \\TELEGRAM_TOKEN = 123:abc
        \\
        \\OWNER_ID=42
        \\LLM_API_KEY = sk-test
        \\LLM_BASE_URL = https://api.example/v1
        \\LLM_MODEL = gpt-5
        \\TINYFISH_API_KEY = tf-test
    );
    try testing.expectEqualStrings("123:abc", cfg.telegram_token.?.reveal());
    try testing.expectEqual(@as(i64, 42), cfg.owner_id.?);
    try testing.expectEqualStrings("sk-test", cfg.api_key.?.reveal());
    try testing.expectEqualStrings("https://api.example/v1", cfg.base_url.?);
    try testing.expectEqualStrings("gpt-5", cfg.model.?);
    try testing.expectEqualStrings("tf-test", cfg.tinyfish_key.?.reveal());
}

test "parse reads CHAT_ID" {
    const cfg = parse("CHAT_ID=99\n");
    try testing.expectEqual(@as(?i64, 99), cfg.chat_id);
}

test "a secret prints redacted, never its value" {
    const cfg = parse("TELEGRAM_TOKEN=123:abc");
    var buf: [64]u8 = undefined;
    const line = try std.fmt.bufPrint(&buf, "token={f}", .{cfg.telegram_token.?});
    try testing.expectEqualStrings("token=[redacted]", line);
    try testing.expect(std.mem.indexOf(u8, line, "123:abc") == null);

    // Pointer storage also hides bytes from `{any}`.
    const dumped = try std.fmt.bufPrint(&buf, "{any}", .{cfg.telegram_token.?});
    try testing.expect(std.mem.indexOf(u8, dumped, "123:abc") == null);
}

test "the environment overrides the file" {
    var env: std.process.Environ.Map = .init(testing.allocator);
    defer env.deinit();
    try env.put("LLM_MODEL", "from-env");
    try env.put("PATH", "/usr/bin");

    var cfg = parse("LLM_MODEL=from-file\nOWNER_ID=42\nLLM_MDOEL=a-typo\n");
    cfg.overlay(&env);

    try testing.expectEqualStrings("from-env", cfg.model.?);
    try testing.expectEqual(@as(i64, 42), cfg.owner_id.?);
}

test "load reads a file, and a missing file is not an error" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var buf: [128]u8 = undefined;
    const path = try std.fmt.bufPrint(&buf, ".zig-cache/tmp/{s}/.env", .{tmp.sub_path});
    try tmp.dir.writeFile(io, .{ .sub_path = ".env", .data = "LLM_MODEL=gpt-5\n" });

    var cfg = try load(testing.allocator, io, path);
    defer cfg.deinit(testing.allocator);
    try testing.expectEqualStrings("gpt-5", cfg.model.?);

    var none = try load(testing.allocator, io, ".zig-cache/tmp/nope/.env");
    defer none.deinit(testing.allocator);
    try testing.expectEqual(@as(?[]const u8, null), none.model);
}

test "runtime paths stay under the application root" {
    var env: std.process.Environ.Map = .init(testing.allocator);
    defer env.deinit();
    try env.put("ZORO_ENV_FILE", ".zig-cache/tmp/no-runtime.env");
    try env.put("ZORO_HOME", "/tmp/zoro-runtime");

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    var cfg = try loadRuntime(testing.allocator, threaded.io(), &env);
    defer cfg.deinit(testing.allocator);

    try testing.expectEqualStrings("/tmp/zoro-runtime", cfg.runtime_root);
    try testing.expectEqualStrings("/tmp/zoro-runtime/data", cfg.data_dir);
    try testing.expectEqualStrings("/tmp/zoro-runtime/workspace", cfg.workspace);
    try testing.expectEqualStrings("/tmp/zoro-runtime/skills", cfg.skills_dir);
    try testing.expectEqualStrings("/tmp/zoro-runtime/workspace/inbox", cfg.inbox_dir);
    try testing.expectEqualStrings("inbox", try cfg.inboxRelative());
    try testing.expectEqualStrings("/tmp/zoro-runtime/tmp", cfg.tmp_dir);
}

test "relative path overrides use stable roots" {
    var env: std.process.Environ.Map = .init(testing.allocator);
    defer env.deinit();
    try env.put("ZORO_ENV_FILE", ".zig-cache/tmp/no-runtime.env");
    try env.put("ZORO_HOME", "/tmp/zoro-runtime");
    try env.put("ZORO_DATA_DIR", "state");
    try env.put("ZORO_WORKSPACE", "work");
    try env.put("ZORO_SKILLS_DIR", "extensions");
    try env.put("ZORO_INBOX_DIR", "received");
    try env.put("ZORO_TMP_DIR", "scratch");

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    var cfg = try loadRuntime(testing.allocator, threaded.io(), &env);
    defer cfg.deinit(testing.allocator);

    try testing.expectEqualStrings("/tmp/zoro-runtime/state", cfg.data_dir);
    try testing.expectEqualStrings("/tmp/zoro-runtime/work", cfg.workspace);
    try testing.expectEqualStrings("/tmp/zoro-runtime/extensions", cfg.skills_dir);
    try testing.expectEqualStrings("/tmp/zoro-runtime/work/received", cfg.inbox_dir);
    try testing.expectEqualStrings("received", try cfg.inboxRelative());
    try testing.expectEqualStrings("/tmp/zoro-runtime/scratch", cfg.tmp_dir);
}

test "runtime config never falls back to the launch directory" {
    var env: std.process.Environ.Map = .init(testing.allocator);
    defer env.deinit();
    try env.put("ZORO_HOME", "/tmp/zoro-no-cwd");

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    var cfg = try loadRuntime(testing.allocator, threaded.io(), &env);
    defer cfg.deinit(testing.allocator);
    try testing.expectEqualStrings("/tmp/zoro-no-cwd", cfg.runtime_root);
}

test "runtime env overrides file paths" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    try tmp.dir.writeFile(threaded.io(), .{ .sub_path = ".env", .data = "ZORO_HOME=/tmp/from-file\nZORO_DATA_DIR=/tmp/file-data\n" });

    var env_path: [128]u8 = undefined;
    const env_file = try std.fmt.bufPrint(&env_path, ".zig-cache/tmp/{s}/.env", .{tmp.sub_path});
    var env: std.process.Environ.Map = .init(testing.allocator);
    defer env.deinit();
    try env.put("ZORO_ENV_FILE", env_file);
    try env.put("ZORO_HOME", "/tmp/from-env");
    try env.put("ZORO_DATA_DIR", "/tmp/env-data");

    var cfg = try loadRuntime(testing.allocator, threaded.io(), &env);
    defer cfg.deinit(testing.allocator);
    try testing.expectEqualStrings("/tmp/from-env", cfg.runtime_root);
    try testing.expectEqualStrings("/tmp/env-data", cfg.data_dir);
}

test "the inbox must stay inside the workspace" {
    var env: std.process.Environ.Map = .init(testing.allocator);
    defer env.deinit();
    try env.put("ZORO_HOME", "/tmp/zoro-runtime");
    try env.put("ZORO_INBOX_DIR", "/tmp/outside");
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    try testing.expectError(error.InboxOutsideWorkspace, loadRuntime(testing.allocator, threaded.io(), &env));
}
