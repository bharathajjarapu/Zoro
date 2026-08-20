const std = @import("std");
const testing = std.testing;

const log = std.log.scoped(.config);

/// A bootstrap secret. Stored as pointer + length rather than a slice so that
/// even `{any}` prints an address instead of the bytes; `{f}` prints
/// `[redacted]`. Only `reveal()` hands over the bytes, so every real use of
/// a secret is one grep away.
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

/// Bootstrap configuration.
pub const Config = struct {
    /// Owned `.env` bytes. Every string field below borrows from these or from
    /// the process environment, so this is the only allocation to free.
    text: []u8 = &.{},

    telegram_token: ?Secret = null,
    owner_id: ?i64 = null,
    chat_id: ?i64 = null,
    api_key: ?Secret = null,
    /// OpenAI-compatible base, no trailing slash. Default applied by callers.
    base_url: ?[]const u8 = null,
    model: ?[]const u8 = null,
    /// Profile used when the owner sends a picture. Falls back to `model`.
    vision_model: ?[]const u8 = null,
    data_dir: []const u8 = "data",
    /// The only directory the agent may read files from or attach.
    workspace: []const u8 = "workspace",

    /// Assigns one key. Later calls win, which is what gives the environment
    /// precedence over the file.
    fn set(self: *Config, key: []const u8, val: []const u8) void {
        if (val.len == 0) return;
        const eql = std.mem.eql;
        if (eql(u8, key, "ZORO_TELEGRAM_TOKEN")) {
            self.telegram_token = .init(val);
        } else if (eql(u8, key, "ZORO_OWNER_ID")) {
            self.owner_id = std.fmt.parseInt(i64, val, 10) catch blk: {
                log.warn("{s} is not a number", .{key});
                break :blk null;
            };
        } else if (eql(u8, key, "ZORO_CHAT_ID")) {
            self.chat_id = std.fmt.parseInt(i64, val, 10) catch blk: {
                log.warn("{s} is not a number", .{key});
                break :blk null;
            };
        } else if (eql(u8, key, "ZORO_API_KEY")) {
            self.api_key = .init(val);
        } else if (eql(u8, key, "ZORO_BASE_URL")) {
            self.base_url = val;
        } else if (eql(u8, key, "ZORO_MODEL")) {
            self.model = val;
        } else if (eql(u8, key, "ZORO_VISION_MODEL")) {
            self.vision_model = val;
        } else if (eql(u8, key, "ZORO_DATA_DIR")) {
            self.data_dir = val;
        } else if (eql(u8, key, "ZORO_WORKSPACE")) {
            self.workspace = val;
        } else if (std.mem.startsWith(u8, key, "ZORO_")) {
            // A typo would otherwise be silent. The key is safe to log; the
            // value never is.
            log.warn("unknown config key: {s}", .{key});
        }
    }

    pub fn deinit(self: *Config, gpa: std.mem.Allocator) void {
        gpa.free(self.text);
        self.* = undefined;
    }

    /// Overlays the process environment. Called after `parse`, so a variable
    /// set in the environment beats the same key in the file.
    pub fn overlay(self: *Config, env: *const std.process.Environ.Map) void {
        var it = env.iterator();
        while (it.next()) |e| self.set(e.key_ptr.*, e.value_ptr.*);
    }
};

/// Reports a required key that is absent. The message names the key; a value
/// is never logged, because some of them are secrets.
pub fn missing(key: []const u8) error{MissingConfig} {
    log.err("missing required config: {s} — set it in .env or the environment", .{key});
    return error.MissingConfig;
}

/// The largest `.env` we will read. A config file is a handful of lines; this
/// only exists so a wrong path cannot pull an arbitrary file into memory.
const max_env_bytes = 64 * 1024;

/// Reads `path` and parses it. A missing file yields an empty config: the
/// environment alone may carry everything. Caller owns the result.
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

/// Parses `.env` text. Unparsable lines are skipped; slices borrow from `text`.
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
        \\ZORO_TELEGRAM_TOKEN = 123:abc
        \\
        \\ZORO_OWNER_ID=42
        \\ZORO_API_KEY = sk-test
        \\ZORO_BASE_URL = https://api.example/v1
        \\ZORO_MODEL = gpt-5
    );
    try testing.expectEqualStrings("123:abc", cfg.telegram_token.?.reveal());
    try testing.expectEqual(@as(i64, 42), cfg.owner_id.?);
    try testing.expectEqualStrings("sk-test", cfg.api_key.?.reveal());
    try testing.expectEqualStrings("https://api.example/v1", cfg.base_url.?);
    try testing.expectEqualStrings("gpt-5", cfg.model.?);
}

test "parse reads ZORO_CHAT_ID" {
    const cfg = parse("ZORO_CHAT_ID=99\n");
    try testing.expectEqual(@as(?i64, 99), cfg.chat_id);
}

test "a secret prints redacted, never its value" {
    const cfg = parse("ZORO_TELEGRAM_TOKEN=123:abc");
    var buf: [64]u8 = undefined;
    const line = try std.fmt.bufPrint(&buf, "token={f}", .{cfg.telegram_token.?});
    try testing.expectEqualStrings("token=[redacted]", line);
    try testing.expect(std.mem.indexOf(u8, line, "123:abc") == null);

    // `{any}` sidesteps `format` entirely, so the field layout has to be what
    // keeps the bytes out of it. Verified: a slice field prints as bytes here.
    const dumped = try std.fmt.bufPrint(&buf, "{any}", .{cfg.telegram_token.?});
    try testing.expect(std.mem.indexOf(u8, dumped, "123:abc") == null);
}

test "the environment overrides the file" {
    var env: std.process.Environ.Map = .init(testing.allocator);
    defer env.deinit();
    try env.put("ZORO_MODEL", "from-env");
    try env.put("PATH", "/usr/bin"); // not ours: must be left alone

    var cfg = parse("ZORO_MODEL=from-file\nZORO_OWNER_ID=42\nZORO_MDOEL=a-typo\n");
    cfg.overlay(&env);

    try testing.expectEqualStrings("from-env", cfg.model.?);
    try testing.expectEqual(@as(i64, 42), cfg.owner_id.?); // untouched by env
}

test "load reads a file, and a missing file is not an error" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var buf: [128]u8 = undefined;
    const path = try std.fmt.bufPrint(&buf, ".zig-cache/tmp/{s}/.env", .{tmp.sub_path});
    try tmp.dir.writeFile(io, .{ .sub_path = ".env", .data = "ZORO_MODEL=gpt-5\n" });

    var cfg = try load(testing.allocator, io, path);
    defer cfg.deinit(testing.allocator);
    try testing.expectEqualStrings("gpt-5", cfg.model.?);

    var none = try load(testing.allocator, io, ".zig-cache/tmp/nope/.env");
    defer none.deinit(testing.allocator);
    try testing.expectEqual(@as(?[]const u8, null), none.model);
}
