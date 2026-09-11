const std = @import("std");
const testing = std.testing;

const log = std.log.scoped(.config);

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

    pub fn format(self: Secret, w: *std.Io.Writer) std.Io.Writer.Error!void {
        _ = self;
        try w.writeAll("[redacted]");
    }
};

pub const Config = struct {
    /// Owned storage borrowed by parsed values.
    text: []u8 = &.{},

    telegram_token: ?Secret = null,
    owner_id: ?i64 = null,
    chat_id: ?i64 = null,
    api_key: ?Secret = null,
    /// Callers apply the default model endpoint.
    base_url: ?[]const u8 = null,
    model: ?[]const u8 = null,
    /// Falls back to `model` for pictures.
    vision_model: ?[]const u8 = null,
    data_dir: []const u8 = "data",
    /// Only this directory permits file access.
    workspace: []const u8 = "workspace",
    skills_dir: []const u8 = "skills",

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
        } else if (eql(u8, key, "LLM_VISION_MODEL")) {
            self.vision_model = val;
        } else if (eql(u8, key, "ZORO_DATA_DIR")) {
            self.data_dir = val;
        } else if (eql(u8, key, "ZORO_WORKSPACE")) {
            self.workspace = val;
        } else if (eql(u8, key, "ZORO_SKILLS_DIR")) {
            self.skills_dir = val;
        } else if (std.mem.startsWith(u8, key, "ZORO_") or std.mem.startsWith(u8, key, "LLM_")) {
            // Log names only because values may be secrets.
            log.warn("unknown config key: {s}", .{key});
        }
    }

    pub fn deinit(self: *Config, gpa: std.mem.Allocator) void {
        gpa.free(self.text);
        self.* = undefined;
    }

    /// Environment values override file values.
    pub fn overlay(self: *Config, env: *const std.process.Environ.Map) void {
        var it = env.iterator();
        while (it.next()) |e| self.set(e.key_ptr.*, e.value_ptr.*);
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
    );
    try testing.expectEqualStrings("123:abc", cfg.telegram_token.?.reveal());
    try testing.expectEqual(@as(i64, 42), cfg.owner_id.?);
    try testing.expectEqualStrings("sk-test", cfg.api_key.?.reveal());
    try testing.expectEqualStrings("https://api.example/v1", cfg.base_url.?);
    try testing.expectEqualStrings("gpt-5", cfg.model.?);
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
