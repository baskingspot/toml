//! Shims for the Zig 0.16 and 0.17 APIs. Private to the module.

const std = @import("std");
const mem = std.mem;

/// Zig 0.17's `zig fmt` rewrites `@enumFromInt` to `@fromBackingInt`, which
/// Zig 0.16 cannot compile. Keep the builtin out of the formatter's reach
/// until 0.16 support drops.
// zig fmt: off
pub fn enumFromInt(comptime E: type, raw: anytype) E {
    return @enumFromInt(raw);
}
// zig fmt: on

/// Zig 0.17 removed the `**` array-repeat operator.
pub fn repeatString(comptime s: []const u8, comptime n: usize) [s.len * n]u8 {
    var out: [s.len * n]u8 = undefined;
    for (0..n) |i| @memcpy(out[i * s.len ..][0..s.len], s);
    return out;
}

// `std.fmt.allocPrint`/`bufPrint` are the only spelling that compiles on
// 0.16; 0.17 moved them to `Allocator.print` and `mem.print`. Lint runs
// against the 0.16 std (`ziglint-0-16`), so the fallback is not deprecated.
// ziglint-ignore: Z023 -- mirrors the std.fmt argument order
pub fn allocPrint(a: mem.Allocator, comptime format: []const u8, args: anytype) ![]u8 {
    if (comptime @hasDecl(mem.Allocator, "print")) return a.print(format, args);
    return std.fmt.allocPrint(a, format, args);
}

// ziglint-ignore: Z023 -- mirrors the std.fmt argument order
pub fn bufPrint(buf: []u8, comptime format: []const u8, args: anytype) ![]u8 {
    if (comptime @hasDecl(mem, "print")) return mem.print(buf, format, args);
    return std.fmt.bufPrint(buf, format, args);
}
