//! TOML 1.0.0 in Zig: a strict parser, a value tree, and a writer.
//!
//! `parseFromSlice` reads a document into a `Document`: a tree of `Value`s in
//! one arena. `stringify` writes a tree back out. The parser rejects every
//! document that breaks TOML 1.0.0, and the writer emits text the parser reads
//! back to an equal tree.

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
/// Where a parse failed, and what the parser was reading.
pub const Diagnostic = @import("Diagnostic.zig");
/// Byte offsets into the source: the first offending byte and one past the last.
pub const Span = Diagnostic.Span;

const Parser = @import("Parser.zig");
const Writer = @import("Writer.zig");

/// The only error a parse returns: the allocator failed. A document that
/// breaks the grammar is a `failure` in the `ParseResult`, with a diagnostic.
pub const ParseError = error{OutOfMemory};

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

/// Either a document or the first place the source went wrong.
pub const ParseResult = union(enum) {
    /// The parse succeeded.
    document: Document,
    /// The parse failed on the source. The span covers the bytes at fault.
    failure: Diagnostic,
};

/// Parse one TOML document.
///
/// Every string, table, and array is copied into an arena that the returned
/// `Document` owns, so the source may be freed as soon as this returns.
/// `Document.deinit` frees the arena. Allocation failure is `error.OutOfMemory`
/// and carries no span.
pub fn parseFromSlice(allocator: Allocator, source: []const u8) ParseError!ParseResult {
    var arena: std.heap.ArenaAllocator = .init(allocator);
    var parser: Parser = .init(arena.allocator(), source);
    const root = parser.parse() catch |err| switch (err) {
        error.OutOfMemory => {
            arena.deinit();
            return error.OutOfMemory;
        },
        error.Syntax => {
            arena.deinit();
            return .{ .failure = parser.diagnostic };
        },
    };
    return .{ .document = .{ .arena = arena, .root = root } };
}

/// Parse one TOML document into memory the caller already owns.
///
/// Use this when the caller has an arena whose lifetime is known, such as a
/// request or a configuration load. The returned document owns nothing, and
/// `Document.deinit` does not free the caller's memory. The source is still
/// copied, so it may be freed as soon as this returns.
pub fn parseFromSliceLeaky(allocator: Allocator, source: []const u8) ParseError!ParseResult {
    var parser: Parser = .init(allocator, source);
    const root = parser.parse() catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Syntax => return .{ .failure = parser.diagnostic },
    };
    return .{ .document = .{ .root = root } };
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
    const result = try parseFromSlice(testing.allocator, source);
    var document = switch (result) {
        .failure => |diagnostic| {
            std.debug.print("{d}:{d}: {s}\n", .{
                diagnostic.line,
                diagnostic.column,
                diagnostic.message(),
            });
            return error.TestUnexpectedResult;
        },
        .document => |document| document,
    };
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

test "a syntax error reports the line and column" {
    const result = try parseFromSlice(testing.allocator, "a = 1\nb = \nc = 3\n");
    const diagnostic = switch (result) {
        .failure => |diagnostic| diagnostic,
        .document => |document| {
            var copy = document;
            copy.deinit();
            return error.TestUnexpectedResult;
        },
    };
    try testing.expectEqual(@as(u32, 2), diagnostic.line);
    try testing.expectEqual(@as(u32, 5), diagnostic.column);
    try testing.expectEqual(@as(u32, 10), diagnostic.span.start);
    try testing.expect(diagnostic.message().len != 0);
}

test "duplicate keys are rejected" {
    const result = try parseFromSlice(testing.allocator, "a = 1\na = 2\n");
    try testing.expect(result == .failure);
}

test "the document does not borrow the source" {
    const allocator = testing.allocator;
    const source = try allocator.dupe(u8, "key = \"value\"\n");
    const result = try parseFromSlice(allocator, source);
    allocator.free(source);
    var document = switch (result) {
        .failure => return error.TestUnexpectedResult,
        .document => |document| document,
    };
    defer document.deinit();
    try testing.expectEqualStrings("value", document.root.table.get("key").?.string);
}

test "parseFromSliceLeaky writes into the caller's allocator" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const result = try parseFromSliceLeaky(arena.allocator(), "a = 1\n");
    const document = switch (result) {
        .failure => return error.TestUnexpectedResult,
        .document => |document| document,
    };
    try testing.expect(document.arena == null);
    try testing.expectEqual(@as(i64, 1), document.root.table.get("a").?.integer);
}

test "a number literal past the stack buffer still parses" {
    // 402 bytes with underscores: `cleanNumber` has to take an arena buffer.
    const source = "x = 1." ++ ("0_" ** 200) ++ "5\n";
    var document = switch (try parseFromSlice(testing.allocator, source)) {
        .failure => |diagnostic| {
            std.debug.print("{s}\n", .{diagnostic.message()});
            return error.TestUnexpectedResult;
        },
        .document => |document| document,
    };
    defer document.deinit();
    try testing.expectEqual(@as(f64, 1.0), document.root.table.get("x").?.float);
}

test "a key path deeper than the limit is a diagnostic" {
    var text: [256]u8 = undefined;
    var out: std.Io.Writer = .fixed(&text);
    try out.writeAll("a");
    for (0..32) |_| try out.writeAll(".a");
    try out.writeAll(" = 1\n");
    try testing.expect((try parseFromSlice(testing.allocator, out.buffered())) == .failure);
}

test "an array nested past the limit is a diagnostic" {
    const source = "x = " ++ ("[" ** 129) ++ "1" ++ ("]" ** 129);
    try testing.expect((try parseFromSlice(testing.allocator, source)) == .failure);
}

test "fuzz: the parser survives arbitrary bytes" {
    try testing.fuzz({}, fuzzParse, .{ .corpus = &.{
        "a = 1\n",
        "[[a]]\nb = \"x\"\n",
        "a = { b = [1, 2, \"three\"] }\n",
        "a = \"\"\"multi\nline\"\"\"\n",
    } });
}

/// Parse the bytes, write whatever came out, and parse the written text again.
/// Bad input may fail; it must not panic, and anything the parser accepted
/// must survive its own writer.
fn fuzzParse(_: void, smith: *testing.Smith) anyerror!void {
    var buffer: [4096]u8 = undefined;
    const source = buffer[0..smith.slice(&buffer)];

    var first = switch (try parseFromSlice(testing.allocator, source)) {
        .failure => return,
        .document => |document| document,
    };
    defer first.deinit();

    var output: std.Io.Writer.Allocating = .init(testing.allocator);
    defer output.deinit();
    try stringify(first.root, &output.writer);

    var second = switch (try parseFromSlice(testing.allocator, output.written())) {
        .failure => return error.FuzzRoundTripRejected,
        .document => |document| document,
    };
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
    var first = switch (try parseFromSlice(testing.allocator, source)) {
        .failure => return error.TestUnexpectedResult,
        .document => |document| document,
    };
    defer first.deinit();

    var buffer: [1024]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buffer);
    try stringify(first.root, &out);

    var second = switch (try parseFromSlice(testing.allocator, out.buffered())) {
        .failure => return error.TestUnexpectedResult,
        .document => |document| document,
    };
    defer second.deinit();

    try testing.expect(Value.eql(first.root, second.root));
}
