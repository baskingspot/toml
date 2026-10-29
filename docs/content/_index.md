+++
title = "toml"
+++

TOML 1.1.0 in Zig: a strict parser, a value tree, and a writer.

Zig has no TOML parser in std. This one reads the whole of TOML 1.1.0 into a
tree you can walk, and writes it back as TOML. It rejects what the grammar
rejects: a table defined twice, a dotted key that reaches into a header's
table, and an inline table extended after its brace.

Reads 1.1, writes 1.0. The writer never emits the 1.1-only syntax, so any
TOML 1.0 parser accepts its output: inline tables stay on one line, `\e` is
written as `\u001b`, `\xHH` as the codepoint in UTF-8, and a time without
seconds gets `:00`.

- [Reading a document](#reading-a-document): `parseFromSlice` returns a `Document` or a `Diagnostic` with a byte span, a line, and a column.
- [The value tree](#the-value-tree): `Value`, `Table`, and `Array`, with tables in document order and all four datetime forms.
- [Writing a document](#writing-a-document): `stringify` emits TOML 1.0.0 that parses back to an equal tree, quoting keys only when the bare form cannot carry them.
- [Conformance](#conformance): 218 valid and 502 invalid documents from the `toml-test` 1.1.0 list, run by `just test`.
- [Limits](#limits): a writer that drops comments and extra whitespace, and stays inside TOML 1.0.0.

The [API reference](api/) documents every public symbol.

# Getting started

## Install

Add the package to `build.zig.zon`:

```sh
zig fetch --save git+https://github.com/baskingspot/toml
```

Then wire the module in `build.zig`:

```zig
const toml = b.dependency("toml", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("toml", toml.module("toml"));
```

`toml` builds with Zig 0.16 only.

## Import it

```zig
const toml = @import("toml");
```

`std` has no `toml` namespace, so the import name does not collide.

## Parse a document

```zig
const source =
    \\name = "toml"
    \\version = 1.0
    \\tags = ["parse", "write"]
    \\
    \\[owner]
    \\login = "matt"
;

const result = try toml.parseFromSlice(gpa, source);
var document = switch (result) {
    .document => |document| document,
    .failure => |failure| {
        std.log.err("{d}:{d}: {s}", .{
            failure.line, failure.column, failure.message(),
        });
        return error.BadConfig;
    },
};
defer document.deinit();
```

`parseFromSlice` returns a `ParseResult`: either `document` or `failure`. The
only thrown error is `error.OutOfMemory`, because a broken document is data you
report, not an exceptional control path.

# Reading a document

## Parse

`toml.parseFromSlice(allocator, source)` takes the whole document as bytes and
returns a `ParseResult`.

```zig
const result = try toml.parseFromSlice(gpa, source);
switch (result) {
    .document => |document| {
        var parsed = document;
        defer parsed.deinit();
        // parsed.root is the root table
    },
    .failure => |failure| std.log.err("{s}", .{failure.message()}),
}
```

The source is copied as it is read. You can free it as soon as the call
returns.

## Report a bad document

A `Diagnostic` says where the parser stopped:

- `span` has `start` and `end` as byte offsets into the source.
- `line` and `column` are one-based, and the column counts bytes.
- `message()` returns the explanation, naming the key or the byte it expected.

```zig
const result = try toml.parseFromSlice(gpa, "name = \"a\"\nname = \"b\"\n");
const failure = switch (result) {
    .failure => |failure| failure,
    .document => |document| {
        var parsed = document;
        parsed.deinit();
        return error.TestUnexpectedResult;
    },
};

// line 2, column 1, and the span covers the second `name`.
const where = failure.span;
```

The parser stops at the first error. It does not collect a list.

## Where the memory lives

`parseFromSlice` creates an arena, and every table, array, key, and string in
the tree lives in it. `Document.deinit` frees the arena and nothing else. There
are no per-value destructors to call.

If you already own an arena, use `parseFromSliceLeaky`. It allocates in the
allocator you pass and returns a `Document` whose `arena` field is null, so its
`deinit` does nothing:

```zig
var arena: std.heap.ArenaAllocator = .init(gpa);
defer arena.deinit();

const result = try toml.parseFromSliceLeaky(arena.allocator(), source);
const document = switch (result) {
    .document => |document| document,
    .failure => return error.BadConfig,
};
```

# The value tree

## Values

`Value` is a tagged union. Switch on it to read a value:

```zig
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
```

Reading the wrong field of a union panics in safe modes. When the type is not
guaranteed, check the tag first:

```zig
const port_value: toml.Value = root.get("port") orelse return error.MissingPort;
const port: u16 = switch (port_value) {
    .integer => |number| std.math.cast(u16, number) orelse return error.PortRange,
    else => return error.PortType,
};
```

## Tables

`Table.get` returns `?Value`. `Table.iterator` walks the entries in the order
the document declared them, and `Table.count` gives the number of keys.

```zig
const root = document.root.table;
var it = root.iterator();
while (it.next()) |entry| {
    std.log.info("{s} = {}", .{ entry.key_ptr.*, entry.value_ptr.* });
}
```

An array of tables (`[[products]]`) is an `Array` with `kind == .tables`; the
elements are tables in document order.

To build a tree by hand, create a `Table` and call `Table.put`. It returns
`error.DuplicateKey` when the key is already there:

```zig
var table: toml.Table = .{};
try table.put(gpa, "answer", .{ .integer = 42 });
```

## Arrays

`Array.items.items` is the element slice, in document order. `Array.count`
returns the length. `Array.kind` is `.list` for `a = [ ... ]` and `.tables` for
`[[a]]` headers, which is what the writer looks at to choose its form.

```zig
const tags = root.get("tags").?.array;
for (tags.items.items) |tag| std.log.info("{s}", .{tag.string});
```

## Datetimes

TOML separates four datetime forms, and `Datetime.kind` keeps them apart:

- `.offset`: an instant, with `offset_minutes` from UTC.
- `.local_datetime`: a date and a time with no zone.
- `.local_date`: a calendar date.
- `.local_time`: a clock time.

Seconds are optional on input, as TOML 1.1.0 allows; an omitted second counts
as zero, and `Datetime.write` always emits one. Fractional seconds keep
nanoseconds; digits past the ninth are truncated, not rounded.

`Datetime.parse` reads the text of a value, and `Datetime.write` emits it:

```zig
const when = try toml.Datetime.parse("1979-05-27T07:32:00Z");
try std.testing.expectEqual(@as(i16, 0), when.offset_minutes);

// The seconds may be omitted on input.
const minute = try toml.Datetime.parse("07:32");
try std.testing.expectEqual(@as(u8, 0), minute.second);

var buffer: [32]u8 = undefined;
var out: std.Io.Writer = .fixed(&buffer);
try when.write(&out);
// out.buffered() is "1979-05-27T07:32:00Z"
```

## Compare trees

`Value.eql` compares two trees by what they hold. Key order and the parser's
bookkeeping flags are ignored, so two documents that read the same are equal.
Whether an array is a value array or an array of tables is compared, because
the writer emits them differently.

```zig
try std.testing.expect(toml.Value.eql(first.root, second.root));
```

# Writing a document

## stringify

`toml.stringify(value, writer)` writes a document to any `std.Io.Writer`. The
value must be a table; anything else is `error.NotATable`. A full writer is
`error.WriteFailed`.

The output is TOML 1.0.0, so a 1.0 parser reads a tree that came from a 1.1.0
document.

```zig
var buffer: [4096]u8 = undefined;
var out: std.Io.Writer = .fixed(&buffer);
try toml.stringify(document.root, &out);
const text = out.buffered();
```

## What the writer keeps

The output parses back to an equal tree. In particular:

- Integers stay integers, floats keep their value, and datetimes keep their
  kind, their offset, and their nanoseconds. A time without seconds is written
  with `:00`.
- An array of tables stays an array of tables: the writer emits `[[name]]`
  headers for it, so a second parse gives the same array kind.
- Keys stay bare when they match `[A-Za-z0-9_-]` and are quoted otherwise.
- Empty tables are written as a header, so they survive the round trip.

## What the writer normalizes

The tree holds values, not source text. Writing it produces a new document
with these differences:

- Comments, blank lines, and indentation are gone.
- A table's own keys are written before its sub-tables, because a header opens
  a new table and cannot be undone, so the order across those two groups
  changes. Within each group, the order is the document's.
- Strings are written as single-line basic strings, with control characters
  escaped as `\u00XX`. `\e` becomes `\u001b`, and `\xHH` becomes the
  codepoint in UTF-8, so neither 1.1 escape appears in the output.
- Datetimes are written with `T`, with `Z` for a zero offset, and without
  trailing zeros in the fraction.
- Floats are written with the shortest decimal that reads back to the same
  bits, and always with a `.0` or an exponent so they stay floats.

# Conformance

## The corpus

Conformance is measured against [`toml-test`](https://github.com/toml-lang/toml-test),
the language-agnostic conformance suite for TOML implementations. The vendored
copy in `test/toml-test/` is exactly the file list in its
`tests/files-toml-1.1.0`, so it is the 1.1.0 suite.

- 218 valid documents, each compared value by value against its tagged-JSON
  expectation.
- 502 invalid documents, each rejected with a diagnostic that has a position
  and a message.
- Every valid document is also parsed, written, and parsed again. The second
  tree must equal the first, and writing it again must produce the same text.

`just test` runs all three passes with the unit tests.

## What the corpus covers

The invalid half is where the parser earns its keep. It includes:

- Table rules: a header twice, a dotted key that adds to a header's table, an
  inline table extended after its brace, `[[x]]` against a value array.
- The 1.1 corners: a lone carriage return in a multi-line string, and a comma
  with no key before or after it.
- Strings: raw control characters, bad escapes, unclosed delimiters, a
  multi-line string used as a key.
- Numbers: leading zeros, `1_` and `_1`, `1.2.3`, and an integer past
  `i64`.
- Datetimes: out-of-range fields, February 30, a year with five digits, an
  offset of `+25:00`.
- Encoding: invalid UTF-8, UTF-16 input, and a byte-order mark past the start
  of the file.

## The fuzzer

`just fuzz` runs the parser over arbitrary bytes under the built-in fuzz
runner. The property is that bad input fails with a diagnostic instead of
panicking, and that anything the parser accepted survives its own writer.

```sh
just fuzz 1M
```

# Limits

## The writer is TOML 1.0.0

`stringify` emits the subset any 1.0 parser reads, whatever version the tree
came from. Inline tables stay on one line, `\e` is written as `\u001b`,
`\xHH` as the codepoint in UTF-8, and every time carries its seconds. The
cost is only in how a document looks after a write; the tree keeps every
value.

## No comments in the tree

`Value` holds no comments and no source positions for ordinary values. A
document read and written again keeps its values and loses its layout, the way
a formatter would.

## Fixed limits

- A dotted key or header has at most 32 segments. A deeper one is rejected with
  a diagnostic.
- Arrays and inline tables nest at most 128 deep.

## Datetime precision

Fractional seconds are stored in nanoseconds. A document with more than nine
fractional digits parses, and the extra digits are dropped. Millisecond
precision, which TOML requires, is kept exactly.

## One error at a time

Parsing stops at the first error it meets. A tool that wants to show every
problem in a file has to fix them one at a time.
