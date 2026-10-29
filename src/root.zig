//! TOML 1.1.0 in Zig: a strict parser, a value tree, and a writer.
//!
//! `parseFromSlice` reads a document into a `Document`: a tree of `Value`s in
//! one arena. `stringify` writes a tree back out. The parser rejects every
//! document that breaks TOML 1.1.0. The writer emits TOML 1.0.0, so a 1.0
//! parser reads its output, and the parser reads that output back to an equal
//! tree.

const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;

/// A TOML value: a table, an array, a scalar, or a datetime.
pub const Value = @import("value.zig").Value;
/// A table, with its keys in the order the document declared them.
pub const Table = @import("value.zig").Table;
/// An array, with its elements in document order.
pub const Array = @import("value.zig").Array;
/// One of the four TOML datetime forms, down to the nanosecond.
pub const Datetime = @import("Datetime.zig");
/// Where a parse failed: the bytes, the position, and a message. The caller
/// owns this struct and passes it in `ParseOptions`.
pub const Diagnostics = @import("Diagnostics.zig");
/// Byte offsets into the source: the first offending byte and one past the last.
pub const Span = Diagnostics.Span;

const Parser = @import("Parser.zig");
const Writer = @import("Writer.zig");

/// What a parse can return: the allocator failed, or the source breaks the
/// grammar. On `error.SyntaxError`, the `Diagnostics` the caller passed says
/// where.
pub const ParseError = Allocator.Error || error{SyntaxError};

/// How to parse a document.
pub const ParseOptions = struct {
    /// Filled on `error.SyntaxError`. Untouched when the parse succeeds, and
    /// on `error.OutOfMemory`. Null means the caller wants only the error.
    diagnostics: ?*Diagnostics = null,
};

/// A parsed document and the memory that holds it.
pub const Document = struct {
    /// The arena that owns every string, table, and array in `root`, when the
    /// document came from `parseFromSlice`. Null when it came from
    /// `parseFromSliceLeaky`, whose memory belongs to the caller.
    arena: ?std.heap.ArenaAllocator = null,
    /// The root table.
    root: Value,

    /// Free the memory this document owns. Does nothing when the parse was
    /// leaky; that memory belongs to the allocator the caller passed.
    pub fn deinit(self: *Document) void {
        if (self.arena) |*arena| arena.deinit();
        self.* = undefined;
    }
};

/// Parse one TOML document.
///
/// Every string, table, and array is copied into an arena that the returned
/// `Document` owns, so the source may be freed as soon as this returns.
/// `Document.deinit` frees the arena. A document that breaks the grammar is
/// `error.SyntaxError`, and `options.diagnostics` says where.
pub fn parseFromSlice(
    allocator: Allocator,
    source: []const u8,
    options: ParseOptions,
) ParseError!Document {
    var arena: std.heap.ArenaAllocator = .init(allocator);
    errdefer arena.deinit();
    var parser: Parser = .init(arena.allocator(), source, options.diagnostics);
    const root = try parser.parse();
    return .{ .arena = arena, .root = root };
}

/// Parse one TOML document into memory the caller already owns.
///
/// Use this when the caller has an arena whose lifetime is known, such as a
/// request or a configuration load. The returned document owns nothing, and
/// `Document.deinit` does not free the caller's memory. The source is still
/// copied, so it may be freed as soon as this returns.
pub fn parseFromSliceLeaky(
    allocator: Allocator,
    source: []const u8,
    options: ParseOptions,
) ParseError!Document {
    var parser: Parser = .init(allocator, source, options.diagnostics);
    const root = try parser.parse();
    return .{ .root = root };
}

/// What `stringify` can fail with: the sink, a value that is not a table, or
/// a tree nested deeper than the writer walks.
pub const StringifyError = std.Io.Writer.Error || error{ NotATable, NestingTooDeep };

/// Write `value` as a TOML document.
///
/// `value` must be a table; anything else is `error.NotATable`. Keys are
/// quoted only when the bare form cannot carry them. A table's values are
/// written before its sub-tables, which is what keeps the output a valid
/// document, so the order of a table's own keys relative to its sub-tables is
/// not preserved.
pub fn stringify(value: Value, writer: *std.Io.Writer) StringifyError!void {
    var out: Writer = .init(writer);
    try out.write(value);
}

test "parse a small document" {
    const source =
        \\# A document.
        \\name = "toml"
        \\version = 1.0
        \\tags = ["parse", "write"]
        \\
        \\[owner]
        \\login = "matt"
        \\joined = 1979-05-27T07:32:00Z
    ;
    var document = try parseFromSlice(testing.allocator, source, .{});
    defer document.deinit();

    const root = document.root.table;
    try testing.expectEqualStrings("toml", root.get("name").?.string);
    try testing.expectEqual(@as(f64, 1.0), root.get("version").?.float);
    const tags = root.get("tags").?.array;
    try testing.expectEqual(@as(u32, 2), tags.count());
    try testing.expectEqualStrings("write", tags.items.items[1].string);
    const owner = root.get("owner").?.table;
    try testing.expectEqualStrings("matt", owner.get("login").?.string);
    try testing.expectEqual(Datetime.Kind.offset, owner.get("joined").?.datetime.kind);
}

test "a syntax error fills the diagnostics the caller passed" {
    var diagnostics: Diagnostics = undefined;
    try testing.expectError(
        error.SyntaxError,
        parseFromSlice(testing.allocator, "a = 1\nb = \nc = 3\n", .{
            .diagnostics = &diagnostics,
        }),
    );
    try testing.expectEqual(@as(u32, 2), diagnostics.line);
    try testing.expectEqual(@as(u32, 5), diagnostics.column);
    try testing.expectEqual(@as(u32, 10), diagnostics.span.start);
    try testing.expect(diagnostics.message().len != 0);
}

test "a successful parse leaves the diagnostics alone" {
    var diagnostics: Diagnostics = .{ .line = 99, .column = 7 };
    var document = try parseFromSlice(testing.allocator, "a = 1\n", .{
        .diagnostics = &diagnostics,
    });
    defer document.deinit();
    try testing.expectEqual(@as(u32, 99), diagnostics.line);
    try testing.expectEqual(@as(u32, 7), diagnostics.column);
}

test "duplicate keys are rejected" {
    try testing.expectError(
        error.SyntaxError,
        parseFromSlice(testing.allocator, "a = 1\na = 2\n", .{}),
    );
}

test "the document does not borrow the source" {
    const allocator = testing.allocator;
    const source = try allocator.dupe(u8, "key = \"value\"\n");
    var document = try parseFromSlice(allocator, source, .{});
    allocator.free(source);
    defer document.deinit();
    try testing.expectEqualStrings("value", document.root.table.get("key").?.string);
}

test "parseFromSliceLeaky writes into the caller's allocator" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const document = try parseFromSliceLeaky(arena.allocator(), "a = 1\n", .{});
    try testing.expect(document.arena == null);
    try testing.expectEqual(@as(i64, 1), document.root.table.get("a").?.integer);
}

test "an inline table may span lines and hold a comment" {
    const source =
        \\tbl = {
        \\  # a comment between the brace and the first key
        \\  a = 1,
        \\  b = [1,
        \\       2],
        \\  c = {
        \\    d = 2,
        \\  },
        \\}
    ;
    var document = try parseFromSlice(testing.allocator, source, .{});
    defer document.deinit();

    const table = document.root.table.get("tbl").?.table;
    try testing.expectEqual(@as(i64, 1), table.get("a").?.integer);
    try testing.expectEqual(@as(u32, 2), table.get("b").?.array.count());
    try testing.expectEqual(@as(i64, 2), table.get("c").?.table.get("d").?.integer);
}

test "an inline table may end with a comma" {
    const source =
        \\one = { a = 1, }
        \\two = {
        \\  b = 2,
        \\}
    ;
    var document = try parseFromSlice(testing.allocator, source, .{});
    defer document.deinit();

    const root = document.root.table;
    try testing.expectEqual(@as(i64, 1), root.get("one").?.table.get("a").?.integer);
    try testing.expectEqual(@as(i64, 2), root.get("two").?.table.get("b").?.integer);
}

test "\\e is the escape character" {
    var document = try parseFromSlice(testing.allocator, "x = \"a\\eb\"\n", .{});
    defer document.deinit();
    try testing.expectEqualStrings("a\x1bb", document.root.table.get("x").?.string);
}

test "\\xHH is a codepoint up to 255" {
    const source = "x = \"\\x41\\xf8\\x00\\x7f\"\n";
    var document = try parseFromSlice(testing.allocator, source, .{});
    defer document.deinit();
    // \xHH is a codepoint, not a byte: U+00F8 is two UTF-8 bytes.
    try testing.expectEqualStrings("A\u{f8}\x00\x7f", document.root.table.get("x").?.string);
}

test "seconds are optional in times and datetimes" {
    const source =
        \\time = 07:32
        \\local = 1979-05-27T07:32
        \\offset = 1979-05-27 07:32Z
        \\fraction = 07:32:00.5
        \\full = 1979-05-27T07:32:00
    ;
    var document = try parseFromSlice(testing.allocator, source, .{});
    defer document.deinit();

    const root = document.root.table;
    const time = root.get("time").?.datetime;
    try testing.expectEqual(Datetime.Kind.local_time, time.kind);
    try testing.expectEqual(@as(u8, 7), time.hour);
    try testing.expectEqual(@as(u8, 32), time.minute);
    try testing.expectEqual(@as(u8, 0), time.second);

    const local = root.get("local").?.datetime;
    try testing.expectEqual(Datetime.Kind.local_datetime, local.kind);
    try testing.expectEqual(@as(u8, 0), local.second);

    const offset = root.get("offset").?.datetime;
    try testing.expectEqual(Datetime.Kind.offset, offset.kind);
    try testing.expectEqual(@as(u8, 0), offset.second);
    try testing.expectEqual(@as(i16, 0), offset.offset_minutes);

    try testing.expectEqual(@as(u32, 500_000_000), root.get("fraction").?.datetime.nanosecond);
    try testing.expectEqual(@as(u8, 0), root.get("full").?.datetime.nanosecond);
}

test "the writer emits TOML 1.0 for every 1.1 feature" {
    const source =
        \\esc = "\e"
        \\hex = "\x68\xe9"
        \\when = 07:32
        \\arr = [{a = 1},
        \\       {b = 2}]
        \\tbl = {
        \\  a = 1,
        \\}
    ;
    var document = try parseFromSlice(testing.allocator, source, .{});
    defer document.deinit();

    var buffer: [512]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buffer);
    try stringify(document.root, &out);

    // No `\e`, no `\xHH`, seconds always present, and the inline table in
    // the array stays on one line. A TOML 1.0 parser reads every line.
    try testing.expectEqualStrings(
        "esc = \"\\u001b\"\n" ++
            "hex = \"h\u{e9}\"\n" ++
            "when = 07:32:00\n" ++
            "arr = [{a = 1}, {b = 2}]\n" ++
            "\n[tbl]\na = 1\n",
        out.buffered(),
    );
}

test "a number literal past the stack buffer still parses" {
    // 402 bytes with underscores: `cleanNumber` has to take an arena buffer.
    const source = "x = 1." ++ ("0_" ** 200) ++ "5\n";
    var document = try parseFromSlice(testing.allocator, source, .{});
    defer document.deinit();
    try testing.expectEqual(@as(f64, 1.0), document.root.table.get("x").?.float);
}

test "a key path deeper than the limit is a diagnostic" {
    var text: [256]u8 = undefined;
    var out: std.Io.Writer = .fixed(&text);
    try out.writeAll("a");
    for (0..32) |_| try out.writeAll(".a");
    try out.writeAll(" = 1\n");
    try testing.expectError(
        error.SyntaxError,
        parseFromSlice(testing.allocator, out.buffered(), .{}),
    );
}

test "an array nested past the limit is a diagnostic" {
    const source = "x = " ++ ("[" ** 129) ++ "1" ++ ("]" ** 129);
    try testing.expectError(error.SyntaxError, parseFromSlice(testing.allocator, source, .{}));
}

test "fuzz: the parser survives arbitrary bytes" {
    try testing.fuzz({}, fuzzParse, .{ .corpus = &.{
        "a = 1\n",
        "[[a]]\nb = \"x\"\n",
        "a = { b = [1, 2, \"three\"] }\n",
        "a = \"\"\"multi\nline\"\"\"\n",
        "tbl = {\n  a = 1,\n}\n",
        "esc = \"\\e and \\x41\"\n",
        "t = 07:32\n",
    } });
}

/// Parse the bytes, write whatever came out, and parse the written text again.
/// Bad input may fail; it must not panic, and anything the parser accepted
/// must survive its own writer.
fn fuzzParse(_: void, smith: *testing.Smith) anyerror!void {
    var buffer: [4096]u8 = undefined;
    const source = buffer[0..smith.slice(&buffer)];

    var first = parseFromSlice(testing.allocator, source, .{}) catch return;
    defer first.deinit();

    var output: std.Io.Writer.Allocating = .init(testing.allocator);
    defer output.deinit();
    try stringify(first.root, &output.writer);

    var second = parseFromSlice(testing.allocator, output.written(), .{}) catch
        return error.FuzzRoundTripRejected;
    defer second.deinit();
    if (!Value.eql(first.root, second.root)) return error.FuzzRoundTripMismatch;
}

test "writer round-trips a document" {
    const source =
        \\title = "TOML Example"
        \\[owner]
        \\name = "Tom"
        \\dob = 1979-05-27T07:32:00-08:00
        \\[[products]]
        \\name = "Hammer"
        \\sku = 738594937
        \\[[products]]
        \\name = "Nail"
        \\[products.dimensions]
        \\width = 1.5
        \\tags = ["a", "b"]
    ;
    var first = try parseFromSlice(testing.allocator, source, .{});
    defer first.deinit();

    var buffer: [1024]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buffer);
    try stringify(first.root, &out);

    var second = try parseFromSlice(testing.allocator, out.buffered(), .{});
    defer second.deinit();

    try testing.expect(Value.eql(first.root, second.root));
}
