const std = @import("std");
const c = @import("c");
const testing = std.testing;

const log = std.log.scoped(.db);

/// Bump together with a new migration step in `migrate`.
const version = 1;

/// A SQLite connection. One per thread; WAL lets several coexist on one file.
pub const Db = struct {
    ptr: *c.sqlite3,

    /// Opens (creating if absent) the database at `path` with WAL and foreign
    /// keys on. Caller owns the handle and must `close()` it.
    pub fn open(path: [:0]const u8) !Db {
        _ = c.sqlite3_initialize(); // SQLITE_OMIT_AUTOINIT: nobody else does it

        var ptr: ?*c.sqlite3 = null;
        const flags = c.SQLITE_OPEN_READWRITE | c.SQLITE_OPEN_CREATE | c.SQLITE_OPEN_NOMUTEX;
        if (c.sqlite3_open_v2(path.ptr, &ptr, flags, null) != c.SQLITE_OK) {
            // A failed open still allocates a handle carrying the error.
            if (ptr) |p| {
                log.err("open {s}: {s}", .{ path, c.sqlite3_errmsg(p) });
                _ = c.sqlite3_close(p);
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

        // journal_mode reports the mode it settled on instead of failing, so a
        // filesystem without mmap (9p, NFS, CIFS) leaves us in DELETE silently.
        // Degraded still works for one process; it is concurrency that breaks.
        var mode = try db.prepare("PRAGMA journal_mode");
        defer mode.finalize();
        if (try mode.step() and !std.mem.eql(u8, mode.text(0), "wal")) {
            log.warn("journal_mode is {s}, not wal: writers will block readers", .{mode.text(0)});
        }
        return db;
    }

    /// A non-OK close means a statement was never finalized, which leaks the
    /// connection. Loud in tests is the whole point.
    pub fn close(self: *Db) void {
        if (c.sqlite3_close(self.ptr) != c.SQLITE_OK) {
            log.err("close: {s}", .{c.sqlite3_errmsg(self.ptr)});
        }
        self.* = undefined;
    }

    /// Runs one or more statements, discarding any rows.
    pub fn exec(self: *Db, sql: [:0]const u8) !void {
        if (c.sqlite3_exec(self.ptr, sql.ptr, null, null, null) != c.SQLITE_OK) {
            log.err("exec: {s}", .{c.sqlite3_errmsg(self.ptr)});
            return error.Sqlite;
        }
    }

    /// Brings the database up to the current schema version. Idempotent: the
    /// version gate makes a second call a no-op, and the transaction means a
    /// failed run leaves nothing behind.
    pub fn migrate(self: *Db) !void {
        var q = try self.prepare("PRAGMA user_version");
        defer q.finalize();
        if (!try q.step()) return error.Sqlite;
        if (q.int(0) >= version) return;

        try self.exec("BEGIN;\n" ++ @embedFile("schema.sql") ++
            std.fmt.comptimePrint("\nPRAGMA user_version = {d};\nCOMMIT;", .{version}));
    }

    pub fn lastId(self: *Db) i64 {
        return c.sqlite3_last_insert_rowid(self.ptr);
    }

    /// Compiles `sql`. Caller must `finalize()` the result.
    pub fn prepare(self: *Db, sql: [:0]const u8) !Stmt {
        var ptr: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.ptr, sql.ptr, -1, &ptr, null) != c.SQLITE_OK) {
            log.err("prepare {s}: {s}", .{ sql, c.sqlite3_errmsg(self.ptr) });
            return error.Sqlite;
        }
        return .{ .ptr = ptr.?, .db = self.ptr };
    }
};

/// A compiled statement. Column slices point into SQLite's own memory and stay
/// valid only until the next `step`, `reset` or `finalize`.
pub const Stmt = struct {
    ptr: *c.sqlite3_stmt,
    db: *c.sqlite3,

    pub fn finalize(self: *Stmt) void {
        _ = c.sqlite3_finalize(self.ptr);
        self.* = undefined;
    }

    /// Binds parameter `i` (1-based). Text is copied by SQLite, so the caller's
    /// slice need not outlive the call. Accepts integers, floats, `[]const u8`,
    /// `null` and optionals of those.
    pub fn bind(self: *Stmt, i: c_int, val: anytype) !void {
        const rc = switch (@typeInfo(@TypeOf(val))) {
            .null => c.sqlite3_bind_null(self.ptr, i),
            .optional => return if (val) |v| self.bind(i, v) else self.bind(i, null),
            .int, .comptime_int => c.sqlite3_bind_int64(self.ptr, i, @intCast(val)),
            .float, .comptime_float => c.sqlite3_bind_double(self.ptr, i, val),
            else => c.sqlite3_bind_text64(
                self.ptr,
                i,
                val.ptr,
                val.len,
                c.SQLITE_TRANSIENT,
                c.SQLITE_UTF8,
            ),
        };
        if (rc != c.SQLITE_OK) {
            log.err("bind {d}: {s}", .{ i, c.sqlite3_errmsg(self.db) });
            return error.Sqlite;
        }
    }

    /// Rewinds for reuse. Bindings survive; call `clear` too if that matters.
    pub fn reset(self: *Stmt) !void {
        if (c.sqlite3_reset(self.ptr) != c.SQLITE_OK) {
            log.err("reset: {s}", .{c.sqlite3_errmsg(self.db)});
            return error.Sqlite;
        }
    }

    /// Advances one row. Returns false when the statement is done.
    pub fn step(self: *Stmt) !bool {
        return switch (c.sqlite3_step(self.ptr)) {
            c.SQLITE_ROW => true,
            c.SQLITE_DONE => false,
            else => {
                log.err("step: {s}", .{c.sqlite3_errmsg(self.db)});
                return error.Sqlite;
            },
        };
    }

    pub fn int(self: *Stmt, col: c_int) i64 {
        return c.sqlite3_column_int64(self.ptr, col);
    }

    pub fn float(self: *Stmt, col: c_int) f64 {
        return c.sqlite3_column_double(self.ptr, col);
    }

    pub fn isNull(self: *Stmt, col: c_int) bool {
        return c.sqlite3_column_type(self.ptr, col) == c.SQLITE_NULL;
    }

    /// Returns "" for a NULL column, so it cannot tell NULL from an empty
    /// string. Use `isNull` when that distinction matters.
    pub fn text(self: *Stmt, col: c_int) []const u8 {
        const ptr = c.sqlite3_column_text(self.ptr, col) orelse return "";
        const len: usize = @intCast(c.sqlite3_column_bytes(self.ptr, col));
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

test "migrate creates every table and is idempotent" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [128]u8 = undefined;
    var db = try tmpDb(&tmp, &buf);
    defer db.close();

    try db.migrate();
    try db.exec("INSERT INTO kv(key, value) VALUES ('tg_offset', '42')");
    try db.migrate(); // a no-op: no error, and it must not wipe what is there
    try testing.expectEqual(@as(i64, 1), try scalar(&db, "SELECT count(*) FROM kv"));

    var q = try db.prepare("SELECT name FROM sqlite_master WHERE type IN ('table','index') AND name NOT LIKE 'sqlite_%' AND name NOT LIKE 'chunks_%' ORDER BY name");
    defer q.finalize();
    const want = [_][]const u8{
        "approvals",    "approvals_status", "chunks",   "diary",
        "facts",        "kv",               "messages", "messages_created",
        "routines",     "routines_next",    "secrets",  "tasks",
        "tasks_parent", "tasks_status",
    };

    // Compare inside the loop: a column slice dies at the next step().
    var n: usize = 0;
    while (try q.step()) : (n += 1) {
        try testing.expect(n < want.len);
        try testing.expectEqualStrings(want[n], q.text(0));
    }
    try testing.expectEqual(want.len, n);
}

/// One-column, one-row integer query. Test-only sugar.
fn scalar(db: *Db, sql: [:0]const u8) !i64 {
    var q = try db.prepare(sql);
    defer q.finalize();
    if (!try q.step()) return error.NoRow;
    return q.int(0);
}

test "deleting a task cascades to its children and approvals" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [128]u8 = undefined;
    var db = try tmpDb(&tmp, &buf);
    defer db.close();
    try db.migrate();

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
    try db.migrate();

    var scratch: [9]u8 = "tg_offset".*;
    var ins = try db.prepare("INSERT INTO kv(key, value) VALUES (?, 'x')");
    defer ins.finalize();
    try ins.bind(1, scratch[0..]);
    @memset(&scratch, '!'); // SQLITE_STATIC would now store "!!!!!!!!!"
    try testing.expect(!try ins.step());

    var q = try db.prepare("SELECT key FROM kv");
    defer q.finalize();
    try testing.expect(try q.step());
    try testing.expectEqualStrings("tg_offset", q.text(0));
}
