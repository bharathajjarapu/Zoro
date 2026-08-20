const std = @import("std");
const c = @import("c");
const config = @import("config.zig");
const Db = @import("db.zig").Db;

const log = std.log.scoped(.zoro);

/// Kept in step with `build.zig.zon` by hand.
const version = "0.0.0";

/// Zig 0.16 hands us a ready gpa, arena, args and the process `Io` — files,
/// timing and cancellation all flow through that one `Io`, which is why
/// nothing below ever builds its own.
pub fn main(init: std.process.Init) !void {
    run(init) catch |err| switch (err) {
        // Already reported in the owner's terms; a stack trace would only bury it.
        error.MissingConfig => std.process.exit(1),
        else => return err,
    };
}

fn run(init: std.process.Init) !void {
    var args = init.minimal.args.iterate();
    _ = args.next(); // argv[0]
    const cmd = args.next() orelse return daemon(init);

    const eql = std.mem.eql;
    if (eql(u8, cmd, "--version")) return print(init.io, "zoro {s} (sqlite {s})\n", .{ version, sqliteVersion() });
    if (eql(u8, cmd, "help") or eql(u8, cmd, "--help")) return print(init.io, usage, .{});

    log.err("unknown command: {s}", .{cmd});
    try print(init.io, usage, .{});
    std.process.exit(2);
}

const usage =
    \\usage:
    \\  zoro            run the Telegram daemon
    \\  zoro --version  print the zoro and SQLite versions
    \\  zoro help       print this
    \\
;

/// Startup and shutdown for the daemon. The Telegram poller lands here next.
fn daemon(init: std.process.Init) !void {
    var cfg = try config.load(init.gpa, init.io, ".env");
    defer cfg.deinit(init.gpa);
    cfg.overlay(init.environ_map);

    if (cfg.telegram_token == null) return config.missing("ZORO_TELEGRAM_TOKEN");
    if (cfg.owner_id == null) return config.missing("ZORO_OWNER_ID");

    var db = try openDb(init.io, cfg.data_dir);
    defer db.close();
    try db.migrate();

    stop.install();
    log.info("started; waiting for a shutdown signal", .{});

    // ponytail: a 100 ms tick is enough to notice the flag. Ticket 06 replaces
    // this with the getUpdates long poll, which wakes on its own cadence.
    while (!stop.requested()) try std.Io.sleep(init.io, .fromMilliseconds(100), .awake);

    log.info("shutting down", .{});
}

fn openDb(io: std.Io, dir: []const u8) !Db {
    try std.Io.Dir.cwd().createDirPath(io, dir);
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    return Db.open(try std.fmt.bufPrintZ(&buf, "{s}/zoro.db", .{dir}));
}

fn print(io: std.Io, comptime fmt: []const u8, args: anytype) !void {
    var buf: [256]u8 = undefined;
    var file = std.Io.File.stdout().writer(io, &buf);
    try file.interface.print(fmt, args);
    try file.interface.flush();
}

/// Graceful shutdown. A signal handler is handed no context, so the flag has to
/// be a global — the only one in the codebase.
const stop = struct {
    var flag: std.atomic.Value(bool) = .init(false);

    fn install() void {
        const act: std.posix.Sigaction = .{
            .handler = .{ .handler = onSignal },
            .mask = std.posix.sigemptyset(),
            .flags = 0,
        };
        std.posix.sigaction(.INT, &act, null);
        std.posix.sigaction(.TERM, &act, null);
    }

    /// Async-signal-safe: one atomic store and nothing else.
    fn onSignal(_: std.posix.SIG) callconv(.c) void {
        flag.store(true, .release);
    }

    fn requested() bool {
        return flag.load(.acquire);
    }

    /// Test-only: puts the disposition back so a later interrupt still kills
    /// the test runner.
    fn restoreDefault() void {
        flag.store(false, .release);
        const act: std.posix.Sigaction = .{
            .handler = .{ .handler = std.posix.SIG.DFL },
            .mask = std.posix.sigemptyset(),
            .flags = 0,
        };
        std.posix.sigaction(.INT, &act, null);
        std.posix.sigaction(.TERM, &act, null);
    }
};

/// SQLITE_OMIT_AUTOINIT means nothing initialises SQLite for us.
fn sqliteVersion() []const u8 {
    _ = c.sqlite3_initialize();
    return std.mem.span(c.sqlite3_libversion());
}

test "sqlite is linked with fts5 and bm25" {
    _ = c.sqlite3_initialize();

    var db: ?*c.sqlite3 = null;
    try std.testing.expectEqual(c.SQLITE_OK, c.sqlite3_open(":memory:", &db));
    defer _ = c.sqlite3_close(db);

    const setup =
        \\CREATE VIRTUAL TABLE chunks USING fts5(text, tokenize='porter');
        \\INSERT INTO chunks(text) VALUES('booked the appointment for tuesday');
    ;
    try std.testing.expectEqual(c.SQLITE_OK, c.sqlite3_exec(db, setup, null, null, null));

    // 'appointments' stems to 'appointment'. Porter is inflectional only:
    // it does NOT match abbreviations or synonyms (vet != veterinarian).
    var stmt: ?*c.sqlite3_stmt = null;
    const sql = "SELECT bm25(chunks) FROM chunks WHERE chunks MATCH 'appointments'";
    try std.testing.expectEqual(c.SQLITE_OK, c.sqlite3_prepare_v2(db, sql, -1, &stmt, null));
    defer _ = c.sqlite3_finalize(stmt);

    try std.testing.expectEqual(c.SQLITE_ROW, c.sqlite3_step(stmt));
    try std.testing.expect(c.sqlite3_column_double(stmt, 0) < 0); // bm25 scores are negative
}

test "sqlite reports the pinned version" {
    try std.testing.expectEqualStrings("3.51.0", sqliteVersion());
}

test {
    _ = @import("db.zig");
    _ = @import("config.zig");
    _ = @import("agent.zig");
}

test "a signal asks for shutdown instead of killing the process" {
    stop.install();
    defer stop.restoreDefault();

    try std.testing.expect(!stop.requested());
    try std.posix.raise(.INT);
    try std.testing.expect(stop.requested());
}
