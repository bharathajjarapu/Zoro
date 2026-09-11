//! Schedule expressions: `every 15m` intervals and five-field cron, resolved
//! against a fixed-offset timezone. Knows nothing about routines or firing.
const std = @import("std");
const testing = std.testing;

const log = std.log.scoped(.cron);

pub const Spec = union(enum) {
    interval: i64,
    cron: Cron,
};
pub const Cron = struct {
    min: u64,
    hour: u64,
    dom: u64,
    mon: u64,
    dow: u64,
    dom_any: bool,
    dow_any: bool,
};
pub fn parse(expr: []const u8) !Spec {
    const s = std.mem.trim(u8, expr, &std.ascii.whitespace);
    if (std.mem.startsWith(u8, s, "every ")) {
        return .{ .interval = try parseDuration(std.mem.trim(u8, s["every ".len..], &std.ascii.whitespace)) };
    }
    return .{ .cron = try parseCron(s) };
}
pub fn tzOffset(name: ?[]const u8) i32 {
    const n = name orelse return 0;
    if (n.len == 0 or std.ascii.eqlIgnoreCase(n, "UTC") or std.ascii.eqlIgnoreCase(n, "GMT")) return 0;
    if (n[0] == '+' or n[0] == '-') return parseOffset(n) catch 0;
    if (std.mem.eql(u8, n, "Asia/Kolkata") or std.mem.eql(u8, n, "Asia/Calcutta")) return 330;
    if (std.mem.eql(u8, n, "Europe/London")) return 0;
    if (std.mem.eql(u8, n, "America/New_York")) return -300; // ponytail: no DST
    // ponytail: table of four zones; parse /usr/share/zoneinfo via std.tz when a fifth is needed.
    log.warn("unknown timezone {s}: scheduling in UTC", .{n});
    return 0;
}
pub fn nextRun(spec: Spec, now: i64, tz: ?[]const u8) !i64 {
    return switch (spec) {
        .interval => |sec| now + sec,
        .cron => |c| nextCron(c, now, tzOffset(tz)),
    };
}
fn parseDuration(s: []const u8) !i64 {
    if (s.len == 0) return error.BadSchedule;
    const last = s[s.len - 1];
    const num = if (std.ascii.isAlphabetic(last)) s[0 .. s.len - 1] else s;
    const n = std.fmt.parseInt(i64, num, 10) catch return error.BadSchedule;
    if (n <= 0) return error.BadSchedule;
    const mul: i64 = switch (last) {
        's' => 1,
        'm' => 60,
        'h' => 3600,
        'd' => 86400,
        else => if (std.ascii.isDigit(last)) 1 else return error.BadSchedule,
    };
    return n * mul;
}
fn parseOffset(s: []const u8) !i32 {
    const sign: i32 = if (s[0] == '-') -1 else 1;
    const body = s[1..];
    var hour: i32 = 0;
    var min: i32 = 0;
    if (body.len >= 5 and body[2] == ':') {
        hour = try std.fmt.parseInt(i32, body[0..2], 10);
        min = try std.fmt.parseInt(i32, body[3..5], 10);
    } else if (body.len == 4) {
        hour = try std.fmt.parseInt(i32, body[0..2], 10);
        min = try std.fmt.parseInt(i32, body[2..4], 10);
    } else if (body.len == 2 or body.len == 1) {
        hour = try std.fmt.parseInt(i32, body, 10);
    } else return error.BadTimezone;
    return sign * (hour * 60 + min);
}
fn parseCron(s: []const u8) !Cron {
    var it = std.mem.tokenizeAny(u8, s, " \t");
    const min = it.next() orelse return error.BadSchedule;
    const hour = it.next() orelse return error.BadSchedule;
    const dom = it.next() orelse return error.BadSchedule;
    const mon = it.next() orelse return error.BadSchedule;
    const dow = it.next() orelse return error.BadSchedule;
    if (it.next() != null) return error.BadSchedule;
    var c: Cron = .{
        .min = try parseField(min, 0, 59),
        .hour = try parseField(hour, 0, 23),
        .dom = try parseField(dom, 1, 31),
        .mon = try parseField(mon, 1, 12),
        .dow = try parseField(dow, 0, 7),
        .dom_any = std.mem.eql(u8, dom, "*"),
        .dow_any = std.mem.eql(u8, dow, "*"),
    };
    if (c.dow & (@as(u64, 1) << 7) != 0) c.dow |= 1; // 7 = Sunday
    return c;
}
fn parseField(field: []const u8, min: u6, max: u6) !u64 {
    var bits: u64 = 0;
    var parts = std.mem.splitScalar(u8, field, ',');
    while (parts.next()) |part| {
        if (part.len == 0) return error.BadSchedule;
        var rest = part;
        var step: u6 = 1;
        if (std.mem.indexOfScalar(u8, part, '/')) |slash| {
            step = std.fmt.parseInt(u6, part[slash + 1 ..], 10) catch return error.BadSchedule;
            if (step == 0) return error.BadSchedule;
            rest = part[0..slash];
        }
        var start: u32 = min;
        var end: u32 = max;
        if (!std.mem.eql(u8, rest, "*")) {
            if (std.mem.indexOfScalar(u8, rest, '-')) |dash| {
                start = std.fmt.parseInt(u32, rest[0..dash], 10) catch return error.BadSchedule;
                end = std.fmt.parseInt(u32, rest[dash + 1 ..], 10) catch return error.BadSchedule;
            } else {
                start = std.fmt.parseInt(u32, rest, 10) catch return error.BadSchedule;
                end = start;
            }
        }
        if (start < min or end > max or start > end) return error.BadSchedule;
        var v = start;
        while (v <= end) : (v += step) {
            bits |= @as(u64, 1) << @intCast(v);
        }
    }
    return bits;
}
fn nextCron(c: Cron, now: i64, off_min: i32) !i64 {
    var t = now - @mod(now, 60) + 60;
    const limit = now + 366 * 86400;
    while (t <= limit) : (t += 60) {
        if (matchCron(c, t, off_min)) return t;
    }
    return error.NoMatch;
}
fn matchCron(c: Cron, unix: i64, off_min: i32) bool {
    const local = unix + @as(i64, off_min) * 60;
    const tod = @mod(local, 86400);
    const minute: u6 = @intCast(@divFloor(@mod(tod, 3600), 60));
    const hour: u6 = @intCast(@divFloor(tod, 3600));
    if (c.min & (@as(u64, 1) << minute) == 0) return false;
    if (c.hour & (@as(u64, 1) << hour) == 0) return false;
    const days = @divFloor(local, 86400);
    const civil = civilFromDays(days);
    if (c.mon & (@as(u64, 1) << @intCast(civil.month)) == 0) return false;

    const dow: u6 = @intCast(@mod(days + 4, 7));
    const dom_ok = c.dom & (@as(u64, 1) << @intCast(civil.day)) != 0;
    const dow_ok = c.dow & (@as(u64, 1) << dow) != 0;
    // Vixie cron: two restricted day fields are OR'd, not AND'd.
    if (!c.dom_any and !c.dow_any) return dom_ok or dow_ok;
    return dom_ok and dow_ok;
}
const Civil = struct { year: i32, month: u8, day: u8 };

/// Howard Hinnant's civil-from-days.
fn civilFromDays(z: i64) Civil {
    const era = @divFloor(z + 719468, 146097);
    const doe: i64 = z + 719468 - era * 146097;
    const yoe = @divFloor(doe - @divFloor(doe, 1460) + @divFloor(doe, 36524) - @divFloor(doe, 146096), 365);
    var y: i32 = @intCast(yoe + era * 400);
    const doy = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100));
    const mp = @divFloor(5 * doy + 2, 153);
    const d: u8 = @intCast(doy - @divFloor(153 * mp + 2, 5) + 1);
    const m: u8 = @intCast(if (mp < 10) mp + 3 else mp - 9);
    if (m <= 2) y += 1;
    return .{ .year = y, .month = m, .day = d };
}

test "interval and cron parse, including timezone" {
    try testing.expectEqual(@as(i64, 900), (try parse("every 15m")).interval);
    try testing.expectEqual(@as(i64, 3600), (try parse("every 1h")).interval);
    const c = (try parse("0 7 * * *")).cron;
    try testing.expect(c.min & 1 != 0);
    try testing.expect(c.hour & (@as(u64, 1) << 7) != 0);

    const now: i64 = 1_755_648_000; // 2026-08-20 00:00 UTC
    const next_utc = try nextRun(try parse("0 7 * * *"), now, "UTC");
    try testing.expectEqual(@as(i64, now + 7 * 3600), next_utc);

    const next_ist = try nextRun(try parse("0 7 * * *"), now, "Asia/Kolkata");
    try testing.expectEqual(@as(i64, now + (7 * 3600 - 330 * 60)), next_ist);

    const n = try nextRun(try parse("every 30s"), now, null);
    try testing.expectEqual(@as(i64, now + 30), n);
}

test "two restricted day fields are OR'd, one restricted is AND'd" {
    const now: i64 = 1_754_006_400; // 2025-08-01 00:00 UTC, a Friday
    // 1st of the month OR Monday: today (the 1st) matches even though it is not Monday.
    try testing.expectEqual(now + 9 * 3600, try nextRun(try parse("0 9 1 * 1"), now, "UTC"));
    // Only the day-of-week restricted: the next Monday, three days out.
    try testing.expectEqual(now + 3 * 86400 + 9 * 3600, try nextRun(try parse("0 9 * * 1"), now, "UTC"));
}
