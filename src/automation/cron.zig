//! Parses intervals and five-field cron with fixed-offset timezones.
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
    const text = std.mem.trim(u8, expr, &std.ascii.whitespace);
    if (std.mem.startsWith(u8, text, "every ")) {
        return .{ .interval = try parseDuration(std.mem.trim(u8, text["every ".len..], &std.ascii.whitespace)) };
    }
    return .{ .cron = try parseCron(text) };
}
pub fn tzOffset(name: ?[]const u8) i32 {
    const zone = name orelse return 0;
    if (zone.len == 0 or std.ascii.eqlIgnoreCase(zone, "UTC") or std.ascii.eqlIgnoreCase(zone, "GMT")) return 0;
    if (zone[0] == '+' or zone[0] == '-') return parseOffset(zone) catch 0;
    if (std.mem.eql(u8, zone, "Asia/Kolkata") or std.mem.eql(u8, zone, "Asia/Calcutta")) return 330;
    if (std.mem.eql(u8, zone, "Europe/London")) return 0;
    if (std.mem.eql(u8, zone, "America/New_York")) return -300;
    // ponytail: fixed zones omit DST; use std.tz when needed.
    log.warn("unknown timezone {s}: scheduling in UTC", .{zone});
    return 0;
}
pub fn nextRun(spec: Spec, now: i64, tz: ?[]const u8) !i64 {
    return switch (spec) {
        .interval => |seconds| now + seconds,
        .cron => |schedule| nextCron(schedule, now, tzOffset(tz)),
    };
}
fn parseDuration(text: []const u8) !i64 {
    if (text.len == 0) return error.BadSchedule;
    const last = text[text.len - 1];
    const number = if (std.ascii.isAlphabetic(last)) text[0 .. text.len - 1] else text;
    const value = std.fmt.parseInt(i64, number, 10) catch return error.BadSchedule;
    if (value <= 0) return error.BadSchedule;
    const multiplier: i64 = switch (last) {
        's' => 1,
        'm' => 60,
        'h' => 3600,
        'd' => 86400,
        else => if (std.ascii.isDigit(last)) 1 else return error.BadSchedule,
    };
    return value * multiplier;
}
fn parseOffset(text: []const u8) !i32 {
    const sign: i32 = if (text[0] == '-') -1 else 1;
    const body = text[1..];
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
fn parseCron(text: []const u8) !Cron {
    var it = std.mem.tokenizeAny(u8, text, " \t");
    const min = it.next() orelse return error.BadSchedule;
    const hour = it.next() orelse return error.BadSchedule;
    const dom = it.next() orelse return error.BadSchedule;
    const mon = it.next() orelse return error.BadSchedule;
    const dow = it.next() orelse return error.BadSchedule;
    if (it.next() != null) return error.BadSchedule;
    var schedule: Cron = .{
        .min = try parseField(min, 0, 59),
        .hour = try parseField(hour, 0, 23),
        .dom = try parseField(dom, 1, 31),
        .mon = try parseField(mon, 1, 12),
        .dow = try parseField(dow, 0, 7),
        .dom_any = std.mem.eql(u8, dom, "*"),
        .dow_any = std.mem.eql(u8, dow, "*"),
    };
    if (schedule.dow & (@as(u64, 1) << 7) != 0) schedule.dow |= 1; // 7 = Sunday
    return schedule;
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
        var value = start;
        while (value <= end) : (value += step) {
            bits |= @as(u64, 1) << @intCast(value);
        }
    }
    return bits;
}
fn nextCron(schedule: Cron, now: i64, offset: i32) !i64 {
    var time = now - @mod(now, 60) + 60;
    const limit = now + 366 * 86400;
    while (time <= limit) : (time += 60) {
        if (matchCron(schedule, time, offset)) return time;
    }
    return error.NoMatch;
}
fn matchCron(schedule: Cron, unix: i64, offset: i32) bool {
    const local = unix + @as(i64, offset) * 60;
    const tod = @mod(local, 86400);
    const minute: u6 = @intCast(@divFloor(@mod(tod, 3600), 60));
    const hour: u6 = @intCast(@divFloor(tod, 3600));
    if (schedule.min & (@as(u64, 1) << minute) == 0) return false;
    if (schedule.hour & (@as(u64, 1) << hour) == 0) return false;
    const days = @divFloor(local, 86400);
    const civil = civilFromDays(days);
    if (schedule.mon & (@as(u64, 1) << @intCast(civil.month)) == 0) return false;

    const dow: u6 = @intCast(@mod(days + 4, 7));
    const dom_ok = schedule.dom & (@as(u64, 1) << @intCast(civil.day)) != 0;
    const dow_ok = schedule.dow & (@as(u64, 1) << dow) != 0;
    // Vixie cron ORs two restricted day fields.
    if (!schedule.dom_any and !schedule.dow_any) return dom_ok or dow_ok;
    return dom_ok and dow_ok;
}
const Civil = struct { year: i32, month: u8, day: u8 };

/// Howard Hinnant's civil-from-days.
fn civilFromDays(offset: i64) Civil {
    const adjusted = offset + 719468;
    const era = @divFloor(adjusted, 146097);
    const era_day: i64 = adjusted - era * 146097;
    const era_year = @divFloor(era_day - @divFloor(era_day, 1460) + @divFloor(era_day, 36524) - @divFloor(era_day, 146096), 365);
    var year: i32 = @intCast(era_year + era * 400);
    const year_day = era_day - (365 * era_year + @divFloor(era_year, 4) - @divFloor(era_year, 100));
    const march_month = @divFloor(5 * year_day + 2, 153);
    const day: u8 = @intCast(year_day - @divFloor(153 * march_month + 2, 5) + 1);
    const month: u8 = @intCast(if (march_month < 10) march_month + 3 else march_month - 9);
    if (month <= 2) year += 1;
    return .{ .year = year, .month = month, .day = day };
}

test "interval and cron parse, including timezone" {
    try testing.expectEqual(@as(i64, 900), (try parse("every 15m")).interval);
    try testing.expectEqual(@as(i64, 3600), (try parse("every 1h")).interval);
    const schedule = (try parse("0 7 * * *")).cron;
    try testing.expect(schedule.min & 1 != 0);
    try testing.expect(schedule.hour & (@as(u64, 1) << 7) != 0);

    const now: i64 = 1_755_648_000; // 2026-08-20 00:00 UTC
    const next_utc = try nextRun(try parse("0 7 * * *"), now, "UTC");
    try testing.expectEqual(@as(i64, now + 7 * 3600), next_utc);

    const next_ist = try nextRun(try parse("0 7 * * *"), now, "Asia/Kolkata");
    try testing.expectEqual(@as(i64, now + (7 * 3600 - 330 * 60)), next_ist);

    const next = try nextRun(try parse("every 30s"), now, null);
    try testing.expectEqual(@as(i64, now + 30), next);
}

test "two restricted day fields are OR'd, one restricted is AND'd" {
    const now: i64 = 1_754_006_400; // 2025-08-01 00:00 UTC, a Friday
    try testing.expectEqual(now + 9 * 3600, try nextRun(try parse("0 9 1 * 1"), now, "UTC"));
    try testing.expectEqual(now + 3 * 86400 + 9 * 3600, try nextRun(try parse("0 9 * * 1"), now, "UTC"));
}
