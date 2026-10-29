//! TOML text for a value tree.

const std = @import("std");
const testing = std.testing;
const Io = std.Io;
const math = std.math;
const mem = std.mem;
const ArenaAllocator = std.heap.ArenaAllocator;

const Array = @import("value.zig").Array;
const Table = @import("value.zig").Table;
const Value = @import("value.zig").Value;

const Writer = @This();

pub const Error = Io.Writer.Error || error{ NotATable, NestingTooDeep };

/// The deepest table path the writer emits. The parser's key limit keeps a
/// parsed tree under this, so only a hand-built tree can hit it.
const max_path = 128;

writer: *Io.Writer,
path: [max_path][]const u8 = undefined,
depth: u32 = 0,
/// Whether anything was written, so a header knows to put a blank line first.
wrote: bool = false,

pub fn init(writer: *Io.Writer) Writer {
    return .{ .writer = writer };
}

/// Write `value` as a TOML document. It must be a table.
pub fn write(self: *Writer, value: Value) Error!void {
    if (value != .table) return error.NotATable;
    try self.writeBody(value.table);
}

fn writeBody(self: *Writer, table: *Table) Error!void {
    // Values come before sub-tables: a header would move anything after it out
    // of this table.
    var it = table.entries.iterator();
    while (it.next()) |entry| {
        if (!isValue(entry.value_ptr.*)) continue;
        try self.writeKey(entry.key_ptr.*);
        try self.writer.writeAll(" = ");
        try self.writeValue(entry.value_ptr.*);
        try self.writer.writeAll("\n");
        self.wrote = true;
    }

    it = table.entries.iterator();
    while (it.next()) |entry| {
        switch (entry.value_ptr.*) {
            .table => |child| {
                try self.beginPath(entry.key_ptr.*);
                defer self.depth -= 1;
                try self.writeHeader(false);
                try self.writeBody(child);
            },
            .array => |array| {
                if (array.kind != .tables) continue;
                try self.beginPath(entry.key_ptr.*);
                defer self.depth -= 1;
                for (array.items.items) |element| {
                    try self.writeHeader(true);
                    try self.writeBody(element.table);
                }
            },
            else => {},
        }
    }
}

fn writeHeader(self: *Writer, is_array: bool) Error!void {
    if (self.wrote) try self.writer.writeAll("\n");
    try self.writer.writeAll(if (is_array) "[[" else "[");
    try self.writePath();
    try self.writer.writeAll(if (is_array) "]]\n" else "]\n");
    self.wrote = true;
}

fn beginPath(self: *Writer, key: []const u8) Error!void {
    if (self.depth == max_path) return error.NestingTooDeep;
    self.path[self.depth] = key;
    self.depth += 1;
}

fn writePath(self: *Writer) Error!void {
    for (self.path[0..self.depth], 0..) |segment, i| {
        if (i != 0) try self.writer.writeByte('.');
        try self.writeKey(segment);
    }
}

fn writeValue(self: *Writer, value: Value) Error!void {
    try switch (value) {
        .string => |text| self.writeString(text),
        .integer => |number| self.writer.print("{d}", .{number}),
        .float => |number| self.writeFloat(number),
        .boolean => |flag| self.writer.writeAll(if (flag) "true" else "false"),
        .datetime => |datetime| datetime.write(self.writer),
        .array => |array| self.writeArray(array),
        .table => |table| self.writeInlineTable(table),
    };
}

fn writeArray(self: *Writer, array: *Array) Error!void {
    try self.writer.writeByte('[');
    for (array.items.items, 0..) |element, i| {
        if (i != 0) try self.writer.writeAll(", ");
        try self.writeValue(element);
    }
    try self.writer.writeByte(']');
}

fn writeInlineTable(self: *Writer, table: *Table) Error!void {
    try self.writer.writeByte('{');
    var first = true;
    var it = table.entries.iterator();
    while (it.next()) |entry| {
        if (!first) try self.writer.writeAll(", ");
        first = false;
        try self.writeKey(entry.key_ptr.*);
        try self.writer.writeAll(" = ");
        try self.writeValue(entry.value_ptr.*);
    }
    try self.writer.writeByte('}');
}

fn writeKey(self: *Writer, key: []const u8) Error!void {
    if (isBareKey(key)) return self.writer.writeAll(key);
    try self.writeString(key);
}

fn writeString(self: *Writer, text: []const u8) Error!void {
    try self.writer.writeByte('"');
    for (text) |c| {
        switch (c) {
            '"' => try self.writer.writeAll("\\\""),
            '\\' => try self.writer.writeAll("\\\\"),
            0x08 => try self.writer.writeAll("\\b"),
            '\t' => try self.writer.writeAll("\\t"),
            '\n' => try self.writer.writeAll("\\n"),
            0x0C => try self.writer.writeAll("\\f"),
            '\r' => try self.writer.writeAll("\\r"),
            0x00...0x07, 0x0B, 0x0E...0x1F, 0x7F => try self.writer.print("\\u{x:0>4}", .{c}),
            else => try self.writer.writeByte(c),
        }
    }
    try self.writer.writeByte('"');
}

fn writeFloat(self: *Writer, number: f64) Error!void {
    if (math.isNan(number)) {
        return self.writer.writeAll(if (math.signbit(number)) "-nan" else "nan");
    }
    if (math.isInf(number)) {
        return self.writer.writeAll(if (number < 0) "-inf" else "inf");
    }
    // `{d}` prints the shortest decimal that reads back to the same bits, but
    // it prints whole numbers with no fractional part, which TOML would read
    // as an integer.
    var buffer: [512]u8 = undefined;
    const text = std.fmt.bufPrint(&buffer, "{d}", .{number}) catch {
        // The buffer holds every decimal an f64 can produce; scientific
        // notation is the fallback that cannot overflow it.
        return self.writer.print("{e}", .{number});
    };
    try self.writer.writeAll(text);
    if (mem.findScalar(u8, text, '.') == null) try self.writer.writeAll(".0");
}

fn isValue(value: Value) bool {
    return switch (value) {
        .table => false,
        .array => |array| array.kind != .tables,
        else => true,
    };
}

fn isBareKey(key: []const u8) bool {
    if (key.len == 0) return false;
    for (key) |c| {
        switch (c) {
            'A'...'Z', 'a'...'z', '0'...'9', '_', '-' => {},
            else => return false,
        }
    }
    return true;
}

test "stringify writes values before sub-tables" {
    var arena: ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const child = try a.create(Table);
    child.* = .{};
    try child.put(a, "x", .{ .integer = 1 });

    const root = try a.create(Table);
    root.* = .{};
    try root.put(a, "top", .{ .boolean = true });
    try root.put(a, "child", .{ .table = child });

    var buffer: [256]u8 = undefined;
    var out: Io.Writer = .fixed(&buffer);
    var writer: Writer = .init(&out);
    try writer.write(.{ .table = root });
    try testing.expectEqualStrings("top = true\n\n[child]\nx = 1\n", out.buffered());
}

test "stringify quotes keys that the bare form cannot carry" {
    var arena: ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const root = try a.create(Table);
    root.* = .{};
    try root.put(a, "", .{ .integer = 1 });
    try root.put(a, "a.b", .{ .integer = 2 });
    try root.put(a, "with space", .{ .integer = 3 });
    try root.put(a, "é", .{ .integer = 4 });

    var buffer: [256]u8 = undefined;
    var out: Io.Writer = .fixed(&buffer);
    var writer: Writer = .init(&out);
    try writer.write(.{ .table = root });
    try testing.expectEqualStrings(
        "\"\" = 1\n\"a.b\" = 2\n\"with space\" = 3\n\"é\" = 4\n",
        out.buffered(),
    );
}

test "stringify refuses a value that is not a table" {
    var buffer: [16]u8 = undefined;
    var out: Io.Writer = .fixed(&buffer);
    var writer: Writer = .init(&out);
    try testing.expectError(error.NotATable, writer.write(.{ .integer = 1 }));
}
