//! The four datetime forms TOML separates, and the text that spells them.
//!
//! TOML borrows RFC 3339 with four shapes: an offset date-time is an instant,
//! and the local date-time, date, and time forms are wall clock values with no
//! zone. TOML 1.1 makes the seconds optional, in which case they count as
//! zero, and `write` always emits them. A fractional second keeps nanosecond
//! precision; digits past the ninth are truncated, which the specification
//! allows.

const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;

const Datetime = @This();

/// Which of the four forms a value is.
pub const Kind = enum {
    /// Date, time, and offset: an instant.
    offset,
    /// Date and time with no offset.
    local_datetime,
    /// A calendar date with no time.
    local_date,
    /// A clock time with no date.
    local_time,
};

/// Calendar year, 0 to 9999. Zero on a `local_time`.
year: u16 = 0,
/// Month, 1 to 12. Zero on a `local_time`.
month: u8 = 0,
/// Day of the month, 1 to 31. Zero on a `local_time`.
day: u8 = 0,
/// Hour, 0 to 23. Zero on a `local_date`.
hour: u8 = 0,
/// Minute, 0 to 59. Zero on a `local_date`.
minute: u8 = 0,
/// Second, 0 to 60. Sixty is a leap second, which RFC 3339 permits. Zero when
/// the text omitted the seconds.
second: u8 = 0,
/// Fractional second in nanoseconds, 0 to 999_999_999.
nanosecond: u32 = 0,
/// Offset from UTC in minutes, negative west of Greenwich. Zero on the local
/// forms, and on an offset date-time written with `Z`.
offset_minutes: i16 = 0,
kind: Kind,

/// The only failure `scan` and `parse` report: the text is not a datetime.
pub const Error = error{InvalidDatetime};

/// A datetime found at the start of some text, and the bytes it used.
pub const Scanned = struct {
    /// The value.
    value: Datetime,
    /// Bytes of the input the value's text occupies.
    len: usize,
};

/// Read a datetime from the start of `text`.
///
/// Returns null when `text` does not begin with a date or a time. Returns
/// `error.InvalidDatetime` when it begins like one but breaks the grammar or a
/// field range. The caller decides what may follow the bytes that were used.
pub fn scan(text: []const u8) Error!?Scanned {
    if (startsDate(text)) {
        const date = try scanDate(text);
        if (date.len < text.len and isTimeDelimiter(text[date.len])) {
            if (date.len + 1 < text.len and isDigit(text[date.len + 1])) {
                const time = try scanTime(text[date.len + 1 ..]);
                const used = date.len + 1 + time.len;
                var value: Datetime = .{
                    .kind = .local_datetime,
                    .year = date.year,
                    .month = date.month,
                    .day = date.day,
                    .hour = time.hour,
                    .minute = time.minute,
                    .second = time.second,
                    .nanosecond = time.nanosecond,
                };
                if (used < text.len) {
                    switch (text[used]) {
                        'Z', 'z' => {
                            value.kind = .offset;
                            return .{ .value = value, .len = used + 1 };
                        },
                        '+', '-' => {
                            const offset = try scanOffset(text[used..]);
                            value.kind = .offset;
                            value.offset_minutes = offset.minutes;
                            return .{ .value = value, .len = used + offset.len };
                        },
                        else => {},
                    }
                }
                return .{ .value = value, .len = used };
            }
        }
        return .{ .value = .{
            .kind = .local_date,
            .year = date.year,
            .month = date.month,
            .day = date.day,
        }, .len = date.len };
    }

    if (startsTime(text)) {
        const time = try scanTime(text);
        return .{ .value = .{
            .kind = .local_time,
            .hour = time.hour,
            .minute = time.minute,
            .second = time.second,
            .nanosecond = time.nanosecond,
        }, .len = time.len };
    }

    return null;
}

/// Parse `text` as one datetime and nothing else.
pub fn parse(text: []const u8) Error!Datetime {
    const found = (try scan(text)) orelse return error.InvalidDatetime;
    if (found.len != text.len) return error.InvalidDatetime;
    return found.value;
}

/// Write the datetime the way TOML spells it.
pub fn write(self: Datetime, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    switch (self.kind) {
        .offset, .local_datetime, .local_date => try writer.print(
            "{d:0>4}-{d:0>2}-{d:0>2}",
            .{ self.year, self.month, self.day },
        ),
        .local_time => {},
    }
    switch (self.kind) {
        .offset, .local_datetime => try writer.writeByte('T'),
        .local_date => return,
        .local_time => {},
    }
    try writer.print(
        "{d:0>2}:{d:0>2}:{d:0>2}",
        .{ self.hour, self.minute, self.second },
    );

    if (self.nanosecond != 0) {
        assert(self.nanosecond < std.time.ns_per_s);
        var digits: [9]u8 = undefined;
        var value = self.nanosecond;
        var at: usize = digits.len;
        while (at > 0) : (at -= 1) {
            digits[at - 1] = @intCast('0' + value % 10);
            value /= 10;
        }
        var end: usize = digits.len;
        while (end > 0 and digits[end - 1] == '0') end -= 1;
        try writer.writeByte('.');
        try writer.writeAll(digits[0..end]);
    }

    if (self.kind == .offset) {
        const offset: i32 = self.offset_minutes;
        if (offset == 0) {
            try writer.writeByte('Z');
        } else {
            const magnitude: u32 = @intCast(if (offset < 0) -offset else offset);
            try writer.print("{c}{d:0>2}:{d:0>2}", .{
                @as(u8, if (offset < 0) '-' else '+'),
                magnitude / 60,
                magnitude % 60,
            });
        }
    }
}

const Date = struct {
    year: u16,
    month: u8,
    day: u8,
    len: usize,
};

const Time = struct {
    hour: u8,
    minute: u8,
    second: u8,
    nanosecond: u32,
    len: usize,
};

const Offset = struct {
    minutes: i16,
    len: usize,
};

fn scanDate(text: []const u8) Error!Date {
    if (text.len < 10) return error.InvalidDatetime;
    const year = fourDigits(text, 0) orelse return error.InvalidDatetime;
    if (text[4] != '-') return error.InvalidDatetime;
    const month = twoDigits(text, 5) orelse return error.InvalidDatetime;
    if (text[7] != '-') return error.InvalidDatetime;
    const day = twoDigits(text, 8) orelse return error.InvalidDatetime;
    if (month < 1 or month > 12) return error.InvalidDatetime;
    if (day < 1 or day > daysInMonth(year, month)) return error.InvalidDatetime;
    return .{ .year = year, .month = month, .day = day, .len = 10 };
}

fn scanTime(text: []const u8) Error!Time {
    if (text.len < 5) return error.InvalidDatetime;
    const hour = twoDigits(text, 0) orelse return error.InvalidDatetime;
    if (text[2] != ':') return error.InvalidDatetime;
    const minute = twoDigits(text, 3) orelse return error.InvalidDatetime;
    if (hour > 23 or minute > 59) return error.InvalidDatetime;

    var len: usize = 5;
    var second: u8 = 0;
    var nanosecond: u32 = 0;
    if (len < text.len and text[len] == ':') {
        len += 1;
        second = twoDigits(text, len) orelse return error.InvalidDatetime;
        if (second > 60) return error.InvalidDatetime;
        len += 2;
        if (len < text.len and text[len] == '.') {
            len += 1;
            const start = len;
            while (len < text.len and isDigit(text[len])) : (len += 1) {
                if (len - start < 9) nanosecond = nanosecond * 10 + (text[len] - '0');
            }
            if (len == start) return error.InvalidDatetime;
            var digits = len - start;
            while (digits < 9) : (digits += 1) nanosecond *= 10;
        }
    } else if (len < text.len and text[len] == '.') {
        // A fractional second needs the second it belongs to.
        return error.InvalidDatetime;
    }
    return .{
        .hour = hour,
        .minute = minute,
        .second = second,
        .nanosecond = nanosecond,
        .len = len,
    };
}

fn scanOffset(text: []const u8) Error!Offset {
    if (text.len < 6) return error.InvalidDatetime;
    const sign: i16 = switch (text[0]) {
        '+' => 1,
        '-' => -1,
        else => return error.InvalidDatetime,
    };
    const hour = twoDigits(text, 1) orelse return error.InvalidDatetime;
    if (text[3] != ':') return error.InvalidDatetime;
    const minute = twoDigits(text, 4) orelse return error.InvalidDatetime;
    if (hour > 23 or minute > 59) return error.InvalidDatetime;
    const magnitude: i16 = @intCast(@as(u16, hour) * 60 + minute);
    return .{ .minutes = sign * magnitude, .len = 6 };
}

fn startsDate(text: []const u8) bool {
    if (text.len < 5) return false;
    for (text[0..4]) |c| if (!isDigit(c)) return false;
    return text[4] == '-';
}

fn startsTime(text: []const u8) bool {
    if (text.len < 3) return false;
    return isDigit(text[0]) and isDigit(text[1]) and text[2] == ':';
}

fn isTimeDelimiter(c: u8) bool {
    return c == 'T' or c == 't' or c == ' ';
}

fn twoDigits(text: []const u8, at: usize) ?u8 {
    if (at + 2 > text.len) return null;
    if (!isDigit(text[at]) or !isDigit(text[at + 1])) return null;
    return (text[at] - '0') * 10 + (text[at + 1] - '0');
}

fn fourDigits(text: []const u8, at: usize) ?u16 {
    if (at + 4 > text.len) return null;
    var value: u16 = 0;
    for (text[at .. at + 4]) |c| {
        if (!isDigit(c)) return null;
        value = value * 10 + (c - '0');
    }
    return value;
}

fn isDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}

fn daysInMonth(year: u16, month: u8) u8 {
    const named: std.time.epoch.Month = @enumFromInt(month);
    return @intCast(std.time.epoch.getDaysInMonth(year, named));
}

test "scan reads the four forms" {
    const offset = (try scan("1979-05-27T00:32:00.999999-07:00")).?;
    try testing.expectEqual(Kind.offset, offset.value.kind);
    try testing.expectEqual(@as(u32, 999_999_000), offset.value.nanosecond);
    try testing.expectEqual(@as(i16, -420), offset.value.offset_minutes);
    try testing.expectEqual(@as(usize, 32), offset.len);

    const local = (try scan("1979-05-27 07:32:00")).?;
    try testing.expectEqual(Kind.local_datetime, local.value.kind);
    try testing.expectEqual(@as(usize, 19), local.len);

    const date = (try scan("1979-05-27")).?;
    try testing.expectEqual(Kind.local_date, date.value.kind);
    try testing.expectEqual(@as(usize, 10), date.len);

    const time = (try scan("00:32:00.5")).?;
    try testing.expectEqual(Kind.local_time, time.value.kind);
    try testing.expectEqual(@as(u32, 500_000_000), time.value.nanosecond);
    try testing.expectEqual(@as(usize, 10), time.len);

    // TOML 1.1: the seconds may be omitted, and count as zero.
    const minute_only = (try scan("07:32")).?;
    try testing.expectEqual(Kind.local_time, minute_only.value.kind);
    try testing.expectEqual(@as(u8, 0), minute_only.value.second);
    try testing.expectEqual(@as(usize, 5), minute_only.len);

    const no_seconds = (try scan("1979-05-27T07:32Z")).?;
    try testing.expectEqual(Kind.offset, no_seconds.value.kind);
    try testing.expectEqual(@as(u8, 0), no_seconds.value.second);
    try testing.expectEqual(@as(usize, 17), no_seconds.len);
}

test "scan stops at the end of the datetime" {
    const found = (try scan("1979-05-27, rest")).?;
    try testing.expectEqual(@as(usize, 10), found.len);

    // A trailing T with no time is a local date; the caller rejects the T.
    const date = (try scan("1979-05-27T")).?;
    try testing.expectEqual(Kind.local_date, date.value.kind);
}

test "scan rejects bad fields" {
    try testing.expectError(error.InvalidDatetime, scan("2021-02-29"));
    try testing.expectError(error.InvalidDatetime, scan("2020-13-01"));
    try testing.expectError(error.InvalidDatetime, scan("2020-01-00"));
    try testing.expectError(error.InvalidDatetime, scan("2020-01-01T24:00:00Z"));
    try testing.expectError(error.InvalidDatetime, scan("2020-01-01T00:00:61Z"));
    try testing.expectError(error.InvalidDatetime, scan("2020-01-01T00:00:00+24:00"));
    try testing.expectError(error.InvalidDatetime, scan("07:32.5"));
    try testing.expectError(error.InvalidDatetime, scan("2020-01-01T00:00:61"));
}

test "scan accepts leap days and leap seconds" {
    try testing.expect((try scan("2000-02-29")) != null);
    try testing.expect((try scan("2024-02-29")) != null);
    try testing.expect((try scan("2016-12-31T23:59:60Z")) != null);
}

test "scan leaves non-datetimes alone" {
    try testing.expectEqual(@as(?Scanned, null), try scan("1979"));
    try testing.expectEqual(@as(?Scanned, null), try scan("true"));
    try testing.expectEqual(@as(?Scanned, null), try scan(""));
}

test "parse wants the whole text" {
    try testing.expectError(error.InvalidDatetime, parse("2020-01-01T00:00:00.5.5"));
    try testing.expectError(error.InvalidDatetime, parse("1979-05-27T"));
    try testing.expectError(error.InvalidDatetime, parse("1979-05-27 x"));
    _ = try parse("1979-05-27");
}

test "write normalizes spelling and keeps the meaning" {
    const Case = struct { input: []const u8, output: []const u8 };
    const cases = [_]Case{
        .{ .input = "1979-05-27T07:32:00Z", .output = "1979-05-27T07:32:00Z" },
        .{ .input = "1979-05-27T00:32:00.999-07:00", .output = "1979-05-27T00:32:00.999-07:00" },
        .{ .input = "1979-05-27T00:00:00+00:00", .output = "1979-05-27T00:00:00Z" },
        .{ .input = "1979-05-27t07:32:00z", .output = "1979-05-27T07:32:00Z" },
        .{ .input = "1979-05-27 07:32:00.600", .output = "1979-05-27T07:32:00.6" },
        .{ .input = "1979-05-27", .output = "1979-05-27" },
        .{ .input = "00:32:00.999999", .output = "00:32:00.999999" },
        .{ .input = "07:32", .output = "07:32:00" },
        .{ .input = "1979-05-27T07:32", .output = "1979-05-27T07:32:00" },
    };
    for (cases) |case| {
        const value = try parse(case.input);
        var buffer: [64]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&buffer);
        try value.write(&writer);
        try testing.expectEqualStrings(case.output, writer.buffered());
    }
}
