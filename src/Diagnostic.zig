//! Where a parse failed and what the parser was reading.

const std = @import("std");

const Diagnostic = @This();

/// Byte offsets into the source. `start` is the first byte the message refers
/// to, and `end` is one past the last byte.
pub const Span = struct {
    start: u32,
    end: u32,
};

/// The bytes the parser gave up on.
span: Span = .{ .start = 0, .end = 0 },
/// The line of `span.start`, counted from one.
line: u32 = 1,
/// The column of `span.start` on that line, counted from one in bytes.
column: u32 = 1,
len: u8 = 0,
buf: [127]u8 = undefined,

/// The explanation, for example "the key `shape` is already defined".
///
/// The bytes live in the diagnostic itself, so the message stays valid after
/// the parser that made it is gone.
pub fn message(self: *const Diagnostic) []const u8 {
    return self.buf[0..self.len];
}

/// Render a message into the diagnostic, truncating on a character boundary
/// when it does not fit.
pub fn setMessage(self: *Diagnostic, comptime fmt: []const u8, args: anytype) void {
    const text = std.fmt.bufPrint(&self.buf, fmt, args) catch {
        // `bufPrint` leaves a partial message on overflow. Cut it back to a
        // UTF-8 boundary so the caller can print it without mojibake.
        var n: usize = self.buf.len;
        while (n > 0 and (self.buf[n - 1] & 0xC0) == 0x80) n -= 1;
        if (n > 0) n -= 1;
        self.len = @intCast(n);
        return;
    };
    self.len = @intCast(text.len);
}

test "message truncates on a character boundary" {
    var d: Diagnostic = .{};
    d.setMessage("é{s}", .{"é" ** 100});
    const text = d.message();
    try std.testing.expect(text.len < 127);
    try std.testing.expect(std.unicode.utf8ValidateSlice(text));
}

test "message keeps short text whole" {
    var d: Diagnostic = .{};
    d.setMessage("the key `{s}` is already defined", .{"shape"});
    try std.testing.expectEqualStrings("the key `shape` is already defined", d.message());
}
