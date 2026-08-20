const std = @import("std");
const c = @import("c");

/// Kept in step with `build.zig.zon` by hand.
const version = "0.0.0";

/// Zig 0.16 hands us a ready gpa, arena, args and the process `Io` — files,
/// timing and cancellation all flow through that one `Io`.
pub fn main(init: std.process.Init) !void {
    var buf: [128]u8 = undefined;
    var file = std.Io.File.stdout().writer(init.io, &buf);
    const out = &file.interface;

    var args = init.minimal.args.iterate();
    _ = args.next(); // argv[0]
    const cmd = args.next() orelse "";

    if (std.mem.eql(u8, cmd, "--version")) {
        try out.print("zoro {s} (sqlite {s})\n", .{ version, sqliteVersion() });
    } else {
        try out.print("usage: zoro --version\n", .{});
    }
    try out.flush();
}

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
}
