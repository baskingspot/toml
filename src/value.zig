//! The value tree: what a document holds and what the writer emits.

const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;
const Datetime = @import("Datetime.zig");

pub const Value = union(enum) {
    /// Bytes. A string from a parse is owned by the document's arena.
    string: []const u8,
    /// A signed 64-bit integer.
    integer: i64,
    /// An IEEE 754 binary64 float, including `inf` and `nan`.
    float: f64,
    /// True or false.
    boolean: bool,
    /// One of the four TOML datetime forms.
    datetime: Datetime,
    /// A TOML array, in document order.
    array: *Array,
    /// A TOML table, in document order.
    table: *Table,

    /// Whether two trees hold the same document.
    ///
    /// Key order and the parser's bookkeeping are ignored, because neither
    /// changes what a reader of the document sees. Whether an array was
    /// written as `[[x]]` headers or as `[ ... ]` values is compared, because
    /// it changes the text the writer emits.
    pub fn eql(a: Value, b: Value) bool {
        if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
        return switch (a) {
            .string => |s| std.mem.eql(u8, s, b.string),
            .integer => |i| i == b.integer,
            .float => |f| floatEql(f, b.float),
            .boolean => |v| v == b.boolean,
            .datetime => |d| std.meta.eql(d, b.datetime),
            .array => |arr| arrayEql(arr, b.array),
            .table => |t| tableEql(t, b.table),
        };
    }
};

fn floatEql(a: f64, b: f64) bool {
    if (std.math.isNan(a)) return std.math.isNan(b);
    return a == b;
}

fn arrayEql(a: *Array, b: *Array) bool {
    if (a.kind != b.kind) return false;
    if (a.items.items.len != b.items.items.len) return false;
    for (a.items.items, b.items.items) |x, y| {
        if (!Value.eql(x, y)) return false;
    }
    return true;
}

fn tableEql(a: *Table, b: *Table) bool {
    if (a.entries.count() != b.entries.count()) return false;
    var it = a.entries.iterator();
    while (it.next()) |entry| {
        const other = b.entries.get(entry.key_ptr.*) orelse return false;
        if (!Value.eql(entry.value_ptr.*, other)) return false;
    }
    return true;
}

/// The entry storage: string keys, insertion order kept.
const EntryMap = std.array_hash_map.String(Value);

/// A TOML table: keys in the order the document declared them.
pub const Table = struct {
    /// The entries, keyed by the unescaped key text.
    entries: EntryMap = .empty,
    /// Parser bookkeeping. Readers and the writer ignore it.
    flags: Flags = .{},

    /// What the parser remembers about how a table was declared.
    pub const Flags = packed struct(u8) {
        /// A `[header]` defined the table.
        header: bool = false,
        /// A dotted key created the table as an intermediate step.
        dotted: bool = false,
        /// A header created the table as an intermediate step.
        implicit: bool = false,
        /// An inline table, or a table inside one: nothing may be added after
        /// the closing brace.
        sealed: bool = false,
        _: u4 = 0,
    };

    /// The value stored under `key`, or null.
    pub fn get(self: Table, key: []const u8) ?Value {
        return self.entries.get(key);
    }

    /// Whether `key` is present.
    pub fn contains(self: Table, key: []const u8) bool {
        return self.entries.contains(key);
    }

    /// The number of keys.
    pub fn count(self: Table) u32 {
        return @intCast(self.entries.count());
    }

    /// Store `value` under `key`. Fails with `error.DuplicateKey` when the key
    /// is already present, so a table never silently loses an entry.
    pub fn put(
        self: *Table,
        allocator: Allocator,
        key: []const u8,
        value: Value,
    ) error{ DuplicateKey, OutOfMemory }!void {
        if (self.entries.contains(key)) return error.DuplicateKey;
        try self.entries.put(allocator, key, value);
    }

    /// Iterate the entries in document order.
    pub fn iterator(self: Table) EntryMap.Iterator {
        return self.entries.iterator();
    }
};

/// A TOML array: values in document order.
pub const Array = struct {
    items: std.ArrayList(Value) = .empty,
    /// How the document declared the array.
    kind: Kind = .list,

    pub const Kind = enum {
        /// `a = [ ... ]`: a value array.
        list,
        /// `[[a]]` headers: an array of tables.
        tables,
    };

    /// The number of elements.
    pub fn count(self: Array) u32 {
        return @intCast(self.items.items.len);
    }

    /// Append an element.
    pub fn append(self: *Array, allocator: Allocator, value: Value) Allocator.Error!void {
        try self.items.append(allocator, value);
    }
};

test "eql ignores key order and flags" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const first = try a.create(Table);
    first.* = .{ .flags = .{ .header = true } };
    try first.entries.put(a, "x", .{ .integer = 1 });
    try first.entries.put(a, "y", .{ .integer = 2 });

    const second = try a.create(Table);
    second.* = .{};
    try second.entries.put(a, "y", .{ .integer = 2 });
    try second.entries.put(a, "x", .{ .integer = 1 });

    try testing.expect(Value.eql(.{ .table = first }, .{ .table = second }));

    try second.entries.put(a, "z", .{ .integer = 3 });
    try testing.expect(!Value.eql(.{ .table = first }, .{ .table = second }));
}

test "eql distinguishes array kinds" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const list = try a.create(Array);
    list.* = .{ .kind = .list };
    const tables = try a.create(Array);
    tables.* = .{ .kind = .tables };

    try testing.expect(!Value.eql(.{ .array = list }, .{ .array = tables }));
}

test "eql treats every nan as equal" {
    try testing.expect(Value.eql(
        .{ .float = std.math.nan(f64) },
        .{ .float = -std.math.nan(f64) },
    ));
}
