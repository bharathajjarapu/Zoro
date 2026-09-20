const std = @import("std");
const sqlite = @import("c");
const testing = std.testing;

const log = std.log.scoped(.db);

/// A SQLite connection. One per thread; WAL lets several coexist on one file.
pub const Db = struct {
    ptr: *sqlite.sqlite3,

    /// Opens a configured database. Caller must close it.
    pub fn open(path: [:0]const u8) !Db {
        _ = sqlite.sqlite3_initialize(); // SQLITE_OMIT_AUTOINIT: nobody else does it

        var ptr: ?*sqlite.sqlite3 = null;
        const flags = sqlite.SQLITE_OPEN_READWRITE | sqlite.SQLITE_OPEN_CREATE | sqlite.SQLITE_OPEN_NOMUTEX;
        if (sqlite.sqlite3_open_v2(path.ptr, &ptr, flags, null) != sqlite.SQLITE_OK) {
            // A failed open still allocates a handle carrying the error.
            if (ptr) |handle| {
                log.err("open {s}: {s}", .{ path, sqlite.sqlite3_errmsg(handle) });
                _ = sqlite.sqlite3_close(handle);
            }
            return error.Sqlite;
        }
        var db: Db = .{ .ptr = ptr.? };
        errdefer db.close();

        // journal_mode persists in the file; the rest are per-connection.
        try db.exec(
            \\PRAGMA journal_mode = WAL;
            \\PRAGMA synchronous = NORMAL;
            \\PRAGMA foreign_keys = ON;
            \\PRAGMA busy_timeout = 5000;
        );

        // SQLite silently falls back when the filesystem cannot support WAL.
        var mode = try db.prepare("PRAGMA journal_mode");
        defer mode.finalize();
        if (try mode.step() and !std.mem.eql(u8, mode.text(0), "wal")) {
            log.warn("journal_mode is {s}, not wal: writers will block readers", .{mode.text(0)});
        }
        return db;
    }

    /// Logs leaked statements reported during close.
    pub fn close(self: *Db) void {
        if (sqlite.sqlite3_close(self.ptr) != sqlite.SQLITE_OK) {
            log.err("close: {s}", .{sqlite.sqlite3_errmsg(self.ptr)});
        }
        self.* = undefined;
    }

    pub fn exec(self: *Db, sql: [:0]const u8) !void {
        if (sqlite.sqlite3_exec(self.ptr, sql.ptr, null, null, null) != sqlite.SQLITE_OK) {
            log.err("exec: {s}", .{sqlite.sqlite3_errmsg(self.ptr)});
            return error.Sqlite;
        }
    }

    pub fn initSchema(self: *Db) !void {
        try self.exec("BEGIN;");
        errdefer self.exec("ROLLBACK;") catch {};
        try self.exec(@embedFile("schema.sql"));
        try self.exec("COMMIT;");
    }

    pub fn lastId(self: *Db) i64 {
        return sqlite.sqlite3_last_insert_rowid(self.ptr);
    }

    /// Compiles `sql`. Caller must `finalize()` the result.
    pub fn prepare(self: *Db, sql: [:0]const u8) !Stmt {
        var ptr: ?*sqlite.sqlite3_stmt = null;
        if (sqlite.sqlite3_prepare_v2(self.ptr, sql.ptr, -1, &ptr, null) != sqlite.SQLITE_OK) {
            log.err("prepare {s}: {s}", .{ sql, sqlite.sqlite3_errmsg(self.ptr) });
            return error.Sqlite;
        }
        return .{ .ptr = ptr.?, .db = self.ptr };
    }
};

/// Column slices expire on step, reset, or finalize.
pub const Stmt = struct {
    ptr: *sqlite.sqlite3_stmt,
    db: *sqlite.sqlite3,

    pub fn finalize(self: *Stmt) void {
        _ = sqlite.sqlite3_finalize(self.ptr);
        self.* = undefined;
    }

    /// Binds a 1-based parameter; SQLite copies text.
    pub fn bind(self: *Stmt, index: c_int, val: anytype) !void {
        const result = switch (@typeInfo(@TypeOf(val))) {
            .null => sqlite.sqlite3_bind_null(self.ptr, index),
            .optional => return if (val) |value| self.bind(index, value) else self.bind(index, null),
            .int, .comptime_int => sqlite.sqlite3_bind_int64(self.ptr, index, @intCast(val)),
            .float, .comptime_float => sqlite.sqlite3_bind_double(self.ptr, index, val),
            else => sqlite.sqlite3_bind_text64(
                self.ptr,
                index,
                val.ptr,
                val.len,
                sqlite.SQLITE_TRANSIENT,
                sqlite.SQLITE_UTF8,
            ),
        };
        if (result != sqlite.SQLITE_OK) {
            log.err("bind {d}: {s}", .{ index, sqlite.sqlite3_errmsg(self.db) });
            return error.Sqlite;
        }
    }

    /// Rewinds for reuse. Bindings survive; call `clear` too if that matters.
    pub fn reset(self: *Stmt) !void {
        if (sqlite.sqlite3_reset(self.ptr) != sqlite.SQLITE_OK) {
            log.err("reset: {s}", .{sqlite.sqlite3_errmsg(self.db)});
            return error.Sqlite;
        }
    }

    /// Advances one row. Returns false when the statement is done.
    pub fn step(self: *Stmt) !bool {
        return switch (sqlite.sqlite3_step(self.ptr)) {
            sqlite.SQLITE_ROW => true,
            sqlite.SQLITE_DONE => false,
            else => {
                log.err("step: {s}", .{sqlite.sqlite3_errmsg(self.db)});
                return error.Sqlite;
            },
        };
    }

    pub fn int(self: *Stmt, column: c_int) i64 {
        return sqlite.sqlite3_column_int64(self.ptr, column);
    }

    pub fn float(self: *Stmt, column: c_int) f64 {
        return sqlite.sqlite3_column_double(self.ptr, column);
    }

    pub fn isNull(self: *Stmt, column: c_int) bool {
        return sqlite.sqlite3_column_type(self.ptr, column) == sqlite.SQLITE_NULL;
    }

    /// Returns "" for NULL; use `isNull` to distinguish it.
    pub fn text(self: *Stmt, column: c_int) []const u8 {
        const ptr = sqlite.sqlite3_column_text(self.ptr, column) orelse return "";
        const len: usize = @intCast(sqlite.sqlite3_column_bytes(self.ptr, column));
        return ptr[0..len];
    }
};

/// Opens a database under a fresh temp directory. Caller calls `tmp.cleanup()`.
fn tmpDb(tmp: *testing.TmpDir, buf: []u8) !Db {
    const path = try std.fmt.bufPrintZ(buf, ".zig-cache/tmp/{s}/zoro.db", .{tmp.sub_path});
    return Db.open(path);
}

test "open turns on WAL and foreign keys" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [128]u8 = undefined;
    var db = try tmpDb(&tmp, &buf);
    defer db.close();

    var mode = try db.prepare("PRAGMA journal_mode");
    defer mode.finalize();
    try testing.expect(try mode.step());
    try testing.expectEqualStrings("wal", mode.text(0));

    var fk = try db.prepare("PRAGMA foreign_keys");
    defer fk.finalize();
    try testing.expect(try fk.step());
    try testing.expectEqual(@as(i64, 1), fk.int(0));
}

test "schema creates every table and is idempotent" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [128]u8 = undefined;
    var db = try tmpDb(&tmp, &buf);
    defer db.close();

    try db.initSchema();
    try db.exec("INSERT INTO kv(key, value) VALUES ('tg_offset', '42')");
    try db.initSchema();
    try testing.expectEqual(@as(i64, 1), try scalar(&db, "SELECT count(*) FROM kv"));

    var statement = try db.prepare("SELECT name FROM sqlite_master WHERE type IN ('table','index') AND name NOT LIKE 'sqlite_%' AND name NOT LIKE 'chunks_%' ORDER BY name");
    defer statement.finalize();
    const want = [_][]const u8{
        "approvals",    "approvals_status",      "chunks",             "diary",
        "facts",        "kv",                    "learning_proposals", "learning_proposals_status",
        "messages",     "messages_conversation", "messages_created",   "outbox",
        "outbox_ready", "outbox_status",         "routines",           "routines_next",
        "secrets",      "sticker_aliases",       "sticker_learning",   "tasks",
        "tasks_parent", "tasks_status",          "telegram_updates",   "telegram_updates_status",
    };

    // Compare inside the loop: a column slice dies at the next step().
    var index: usize = 0;
    while (try statement.step()) : (index += 1) {
        try testing.expect(index < want.len);
        try testing.expectEqualStrings(want[index], statement.text(0));
    }
    try testing.expectEqual(want.len, index);
}

fn scalar(db: *Db, sql: [:0]const u8) !i64 {
    var statement = try db.prepare(sql);
    defer statement.finalize();
    if (!try statement.step()) return error.NoRow;
    return statement.int(0);
}

test "deleting a task cascades to its children and approvals" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [128]u8 = undefined;
    var db = try tmpDb(&tmp, &buf);
    defer db.close();
    try db.initSchema();

    var ins = try db.prepare(
        \\INSERT INTO tasks(id, parent, status, summary, goal, model, created)
        \\VALUES (?, ?, 'queued', ?, 'ship it', ?, 0)
    );
    defer ins.finalize();
    for ([_]struct { id: i64, parent: ?i64 }{
        .{ .id = 1, .parent = null },
        .{ .id = 2, .parent = 1 },
        .{ .id = 3, .parent = 2 }, // grandchild: cascade must reach two levels
    }) |row| {
        try ins.bind(1, row.id);
        try ins.bind(2, row.parent);
        try ins.bind(3, "research");
        try ins.bind(4, @as(?[]const u8, null));
        try testing.expect(!try ins.step());
        try ins.reset();
    }

    try db.exec(
        \\INSERT INTO approvals(task, tool, args, reason, created, expires)
        \\VALUES (3, 'web', '{}', 'fetch a page', 0, 900)
    );

    try testing.expectEqual(@as(i64, 3), try scalar(&db, "SELECT count(*) FROM tasks"));
    try db.exec("DELETE FROM tasks WHERE id = 1");
    try testing.expectEqual(@as(i64, 0), try scalar(&db, "SELECT count(*) FROM tasks"));
    try testing.expectEqual(@as(i64, 0), try scalar(&db, "SELECT count(*) FROM approvals"));
}

test "bind copies text, so a caller's buffer need not outlive the step" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [128]u8 = undefined;
    var db = try tmpDb(&tmp, &buf);
    defer db.close();
    try db.initSchema();

    var scratch: [9]u8 = "tg_offset".*;
    var ins = try db.prepare("INSERT INTO kv(key, value) VALUES (?, 'x')");
    defer ins.finalize();
    try ins.bind(1, scratch[0..]);
    @memset(&scratch, '!'); // SQLITE_STATIC would now store "!!!!!!!!!"
    try testing.expect(!try ins.step());

    var statement = try db.prepare("SELECT key FROM kv");
    defer statement.finalize();
    try testing.expect(try statement.step());
    try testing.expectEqualStrings("tg_offset", statement.text(0));
}
