//! The toml-test conformance corpus, run against the public API.
//!
//! `test/toml-test/` holds the files listed in `tests/files-toml-1.1.0` from
//! github.com/toml-lang/toml-test. Every valid document must parse and match
//! its tagged-JSON expectation, every invalid document must be rejected with a
//! diagnostic, and every valid document must survive a write and a re-parse.
//!
//! The tests read the corpus from the build root, so `build.zig` sets the test
//! runner's working directory. A consumer that runs the tests from somewhere
//! else gets a clear file-not-found instead of a false pass.

const std = @import("std");
const testing = std.testing;
const toml = @import("toml");

const corpus = "test/toml-test/tests";
const manifest = "files-toml-1.1.0";
const max_file_size = 16 * 1024 * 1024;
const max_failures = 10;

/// One line of the corpus's manifest.
const Entry = struct {
    /// `valid/...` or `invalid/...`.
    path: []const u8,
    /// The tagged-JSON expectation, for a valid document.
    expected: ?[]const u8,
    valid: bool,
};

test "the valid corpus parses and matches its expectations" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const entries = try readManifest(allocator);
    var failures: usize = 0;
    var checked: usize = 0;
    for (entries) |entry| {
        if (!entry.valid) continue;
        checked += 1;
        const source = try readFile(allocator, entry.path);
        var diagnostics: toml.Diagnostics = undefined;
        var document = toml.parseFromSlice(allocator, source, .{
            .diagnostics = &diagnostics,
        }) catch |err| switch (err) {
            error.OutOfMemory => return err,
            error.SyntaxError => {
                try report(entry.path, null, "it did not parse: {s}", .{diagnostics.message()});
                failures += 1;
                if (failures == max_failures) break;
                continue;
            },
        };

        const json_bytes = try readFile(allocator, entry.expected.?);
        var expected = try std.json.parseFromSliceLeaky(
            std.json.Value,
            allocator,
            json_bytes,
            .{},
        );
        expectSame(entry.path, &.{}, &expected, document.root) catch {
            failures += 1;
            if (failures == max_failures) break;
        };
        document.deinit();
    }
    try testing.expect(checked > 0);
    if (failures != 0) return error.CorpusMismatch;
}

test "the invalid corpus is rejected with a diagnostic" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const entries = try readManifest(allocator);
    var failures: usize = 0;
    var checked: usize = 0;
    for (entries) |entry| {
        if (entry.valid) continue;
        checked += 1;
        const source = try readFile(allocator, entry.path);
        var diagnostics: toml.Diagnostics = undefined;
        if (toml.parseFromSlice(allocator, source, .{ .diagnostics = &diagnostics })) |parsed| {
            var document = parsed;
            document.deinit();
            try report(entry.path, null, "it parsed, and it must not", .{});
            failures += 1;
        } else |err| switch (err) {
            error.OutOfMemory => return err,
            error.SyntaxError => {
                if (diagnostics.line == 0 or diagnostics.column == 0) {
                    try report(entry.path, null, "the diagnostics have no position", .{});
                    failures += 1;
                } else if (diagnostics.span.end < diagnostics.span.start) {
                    try report(entry.path, null, "the diagnostics span is reversed", .{});
                    failures += 1;
                } else if (diagnostics.span.end > source.len) {
                    try report(entry.path, null, "the diagnostics span runs off the source", .{});
                    failures += 1;
                } else if (diagnostics.message().len == 0) {
                    try report(entry.path, null, "the diagnostics have no message", .{});
                    failures += 1;
                }
            },
        }
        if (failures == max_failures) break;
    }
    try testing.expect(checked > 0);
    if (failures != 0) return error.CorpusMismatch;
}

test "the valid corpus round-trips through the writer" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const entries = try readManifest(allocator);
    var failures: usize = 0;
    for (entries) |entry| {
        if (!entry.valid) continue;
        const source = try readFile(allocator, entry.path);
        var first = toml.parseFromSlice(allocator, source, .init) catch |err| switch (err) {
            error.OutOfMemory => return err,
            error.SyntaxError => {
                try report(entry.path, null, "it did not parse", .{});
                failures += 1;
                if (failures == max_failures) break;
                continue;
            },
        };

        var output: std.Io.Writer.Allocating = .init(allocator);
        toml.stringify(first.root, &output.writer) catch |err| {
            try report(entry.path, null, "writing it failed: {s}", .{@errorName(err)});
            failures += 1;
            if (failures == max_failures) break;
            continue;
        };

        var diagnostics: toml.Diagnostics = undefined;
        var second = toml.parseFromSlice(allocator, output.written(), .{
            .diagnostics = &diagnostics,
        }) catch |err| switch (err) {
            error.OutOfMemory => return err,
            error.SyntaxError => {
                try report(entry.path, null, "the written document does not parse: {s}", .{
                    diagnostics.message(),
                });
                try report(entry.path, null, "written text:\n{s}", .{output.written()});
                failures += 1;
                if (failures == max_failures) break;
                continue;
            },
        };
        if (!toml.Value.eql(first.root, second.root)) {
            try report(entry.path, null, "the written document reads back as another tree", .{});
            failures += 1;
        }

        // Writing the re-read tree must produce the same text: a second pass
        // has nothing left to normalize.
        var again: std.Io.Writer.Allocating = .init(allocator);
        try toml.stringify(second.root, &again.writer);
        if (!std.mem.eql(u8, output.written(), again.written())) {
            try report(entry.path, null, "the writer is not stable across a second pass", .{});
            failures += 1;
        }
        first.deinit();
        second.deinit();
        if (failures == max_failures) break;
    }
    if (failures != 0) return error.CorpusMismatch;
}

// Corpus access

fn readManifest(allocator: std.mem.Allocator) ![]Entry {
    const bytes = try readFile(allocator, manifest);
    var entries: std.ArrayList(Entry) = .empty;
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        if (!std.mem.endsWith(u8, line, ".toml")) continue;
        const valid = std.mem.startsWith(u8, line, "valid/");
        const expected = if (valid)
            try std.mem.concat(allocator, u8, &.{ line[0 .. line.len - ".toml".len], ".json" })
        else
            null;
        try entries.append(allocator, .{ .path = line, .expected = expected, .valid = valid });
    }
    return entries.toOwnedSlice(allocator);
}

fn readFile(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const full = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ corpus, path });
    return std.Io.Dir.cwd().readFileAlloc(
        testing.io,
        full,
        allocator,
        .limited(max_file_size),
    );
}

fn report(path: []const u8, key: ?[]const u8, comptime fmt: []const u8, args: anytype) !void {
    std.debug.print("{s}", .{path});
    if (key) |k| {
        if (k.len != 0) std.debug.print(".{s}", .{k});
    }
    std.debug.print(": " ++ fmt ++ "\n", args);
}

// Comparison against the tagged JSON

/// The toml-test JSON encoding: a table is an object, an array is an array, and
/// every scalar is `{"type": "...", "value": "..."}`.
fn expectSame(
    path: []const u8,
    key: []const u8,
    expected: *const std.json.Value,
    actual: toml.Value,
) !void {
    switch (expected.*) {
        .object => |object| {
            // A tagged scalar is exactly `{"type": ..., "value": ...}`, and a
            // table with those two keys is ambiguous in this encoding.
            if (object.count() == 2 and object.contains("type") and object.contains("value")) {
                const kind = switch (object.get("type").?) {
                    .string => |text| text,
                    else => return report(path, key, "the expectation's type is not a string", .{}),
                };
                const value = switch (object.get("value").?) {
                    .string => |text| text,
                    else => return report(
                        path,
                        key,
                        "the expectation's value is not a string",
                        .{},
                    ),
                };
                try expectScalar(path, key, kind, value, actual);
                return;
            }
            const table = switch (actual) {
                .table => |table| table,
                else => return report(path, key, "expected a table, found a {s}", .{
                    tagName(actual),
                }),
            };
            if (object.count() != table.count()) {
                return report(path, key, "expected {d} keys, found {d}", .{
                    object.count(),
                    table.count(),
                });
            }
            var it = object.iterator();
            while (it.next()) |entry| {
                const child = table.get(entry.key_ptr.*) orelse {
                    return report(path, entry.key_ptr.*, "a key is missing", .{});
                };
                try expectSame(path, entry.key_ptr.*, entry.value_ptr, child);
            }
        },
        .array => |items| {
            const array = switch (actual) {
                .array => |array| array,
                else => return report(path, key, "expected an array, found a {s}", .{
                    tagName(actual),
                }),
            };
            if (items.items.len != array.items.items.len) {
                return report(path, key, "expected {d} elements, found {d}", .{
                    items.items.len,
                    array.items.items.len,
                });
            }
            for (items.items, array.items.items) |expected_item, actual_item| {
                try expectSame(path, key, &expected_item, actual_item);
            }
        },
        else => return report(path, key, "the expectation holds an unexpected JSON value", .{}),
    }
}

fn expectScalar(
    path: []const u8,
    key: []const u8,
    kind: []const u8,
    value: []const u8,
    actual: toml.Value,
) !void {
    switch (actual) {
        .string => |text| {
            if (!std.mem.eql(u8, kind, "string")) {
                return report(path, key, "expected type {s}, found string", .{kind});
            }
            if (!std.mem.eql(u8, text, value)) {
                return report(path, key, "expected {s}, found {s}", .{ value, text });
            }
        },
        .integer => |number| {
            if (!std.mem.eql(u8, kind, "integer")) {
                return report(path, key, "expected type {s}, found integer", .{kind});
            }
            const wanted = std.fmt.parseInt(i64, value, 10) catch {
                return report(path, key, "the expectation's integer {s} is malformed", .{value});
            };
            if (wanted != number) {
                return report(path, key, "expected {d}, found {d}", .{ wanted, number });
            }
        },
        .float => |number| {
            if (!std.mem.eql(u8, kind, "float")) {
                return report(path, key, "expected type {s}, found float", .{kind});
            }
            const wanted = std.fmt.parseFloat(f64, value) catch {
                return report(path, key, "the expectation's float {s} is malformed", .{value});
            };
            const same = if (std.math.isNan(wanted))
                std.math.isNan(number)
            else
                wanted == number;
            if (!same) {
                return report(path, key, "expected {s}, found {d}", .{ value, number });
            }
        },
        .boolean => |flag| {
            if (!std.mem.eql(u8, kind, "bool")) {
                return report(path, key, "expected type {s}, found bool", .{kind});
            }
            if ((value[0] == 't') != flag) {
                return report(path, key, "expected {s}, found {s}", .{
                    value,
                    if (flag) "true" else "false",
                });
            }
        },
        .datetime => |datetime| {
            const wanted_kind = switch (datetime.kind) {
                .offset => "datetime",
                .local_datetime => "datetime-local",
                .local_date => "date-local",
                .local_time => "time-local",
            };
            if (!std.mem.eql(u8, kind, wanted_kind)) {
                return report(path, key, "expected type {s}, found {s}", .{ kind, wanted_kind });
            }
            const wanted = toml.Datetime.parse(value) catch {
                return report(path, key, "the expectation's datetime {s} is malformed", .{value});
            };
            if (!std.meta.eql(wanted, datetime)) {
                return report(path, key, "expected {s}, found another datetime", .{value});
            }
        },
        else => return report(path, key, "expected type {s}, found a {s}", .{
            kind,
            tagName(actual),
        }),
    }
}

fn tagName(value: toml.Value) []const u8 {
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
