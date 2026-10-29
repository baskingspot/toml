//! The guide's examples, compiled and run with the module's own test suite.
//! A guide page cannot show code that does not build.

const std = @import("std");
const testing = std.testing;
const toml = @import("toml");

const source =
    \\name = "toml"
    \\version = 1.0
    \\tags = ["parse", "write"]
    \\
    \\[owner]
    \\login = "matt"
    \\joined = 1979-05-27T07:32:00Z
;

test "parse a document and look up a value" {
    const result = try toml.parseFromSlice(testing.allocator, source);
    var document = switch (result) {
        .document => |document| document,
        .failure => |failure| {
            std.debug.print("{d}:{d}: {s}\n", .{
                failure.line, failure.column, failure.message(),
            });
            return error.TestUnexpectedResult;
        },
    };
    defer document.deinit();

    const root = document.root.table;
    try testing.expectEqualStrings("toml", root.get("name").?.string);
    try testing.expectEqual(@as(f64, 1.0), root.get("version").?.float);
    try testing.expectEqualStrings("matt", root.get("owner").?.table.get("login").?.string);
}

test "a bad document comes back with its position" {
    const result = try toml.parseFromSlice(testing.allocator, "name = \"a\"\nname = \"b\"\n");
    const failure = switch (result) {
        .failure => |failure| failure,
        .document => |document| {
            var parsed = document;
            parsed.deinit();
            return error.TestUnexpectedResult;
        },
    };

    try testing.expectEqual(@as(u32, 2), failure.line);
    try testing.expectEqual(@as(u32, 1), failure.column);
    // The span covers the second `name`.
    try testing.expectEqual(@as(u32, 11), failure.span.start);
    try testing.expectEqual(@as(u32, 15), failure.span.end);
    try testing.expect(failure.message().len != 0);
}

test "the leaky variant uses the caller's arena" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const result = try toml.parseFromSliceLeaky(arena.allocator(), source);
    const document = switch (result) {
        .document => |document| document,
        .failure => return error.TestUnexpectedResult,
    };
    try testing.expect(document.arena == null);
    try testing.expectEqualStrings("toml", document.root.table.get("name").?.string);
}

fn describe(value: toml.Value) []const u8 {
    return switch (value) {
        .string => "string",
        .integer => "integer",
        .float => "float",
        .boolean => "boolean",
        .datetime => "datetime",
        .array => "array",
        .table => "table",
    };
}

test "read a value by its tag" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const document = switch (try toml.parseFromSlice(arena.allocator(), source)) {
        .document => |document| document,
        .failure => return error.TestUnexpectedResult,
    };
    const root = document.root.table;

    try testing.expectEqualStrings("float", describe(root.get("version").?));
    try testing.expectEqualStrings("table", describe(root.get("owner").?));

    // The check a config loader writes when the type is not guaranteed.
    const port_value: toml.Value = root.get("port") orelse .{ .integer = 8080 };
    const port: u16 = switch (port_value) {
        .integer => |number| std.math.cast(u16, number) orelse return error.PortRange,
        else => return error.PortType,
    };
    try testing.expectEqual(@as(u16, 8080), port);

    var it = root.iterator();
    try testing.expectEqualStrings("name", it.next().?.key_ptr.*);
    try testing.expectEqual(@as(u32, 4), root.count());
}

test "build a table by hand" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    var table: toml.Table = .{};
    try table.put(arena.allocator(), "answer", .{ .integer = 42 });
    try testing.expectError(
        error.DuplicateKey,
        table.put(arena.allocator(), "answer", .{ .integer = 43 }),
    );
    try testing.expectEqual(@as(i64, 42), table.get("answer").?.integer);
}

test "walk an array of tables" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const text =
        \\[[products]]
        \\name = "Hammer"
        \\[[products]]
        \\name = "Nail"
    ;
    const document = switch (try toml.parseFromSlice(arena.allocator(), text)) {
        .document => |document| document,
        .failure => return error.TestUnexpectedResult,
    };
    const products = document.root.table.get("products").?.array;
    try testing.expectEqual(toml.Array.Kind.tables, products.kind);
    try testing.expectEqual(@as(u32, 2), products.count());
    try testing.expectEqualStrings("Nail", products.items.items[1].table.get("name").?.string);
}

test "parse and write a datetime" {
    const when = try toml.Datetime.parse("1979-05-27T07:32:00Z");
    try testing.expectEqual(@as(i16, 0), when.offset_minutes);
    try testing.expectEqual(toml.Datetime.Kind.offset, when.kind);

    var buffer: [32]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buffer);
    try when.write(&out);
    try testing.expectEqualStrings("1979-05-27T07:32:00Z", out.buffered());
}

test "write a document and read it back" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const first = switch (try toml.parseFromSlice(arena.allocator(), source)) {
        .document => |document| document,
        .failure => return error.TestUnexpectedResult,
    };

    var buffer: [4096]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buffer);
    try toml.stringify(first.root, &out);
    const text = out.buffered();

    const second = switch (try toml.parseFromSlice(arena.allocator(), text)) {
        .document => |document| document,
        .failure => return error.TestUnexpectedResult,
    };
    try testing.expect(toml.Value.eql(first.root, second.root));
}

test "stringify refuses a value that is not a table" {
    var buffer: [16]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buffer);
    try testing.expectError(error.NotATable, toml.stringify(.{ .integer = 1 }, &out));
}
