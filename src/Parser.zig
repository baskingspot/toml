//! The TOML 1.1.0 parser: source bytes in, value tree out, or a diagnostic.

const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;

const Value = @import("value.zig").Value;
const Table = @import("value.zig").Table;
const Array = @import("value.zig").Array;
const Datetime = @import("Datetime.zig");
const Diagnostic = @import("Diagnostic.zig");

const Parser = @This();

/// The parser's failures. A syntax error also fills in `diagnostic`.
pub const Error = error{ Syntax, OutOfMemory };

/// How many segments a dotted key or a header may have. This also bounds the
/// table depth of any parsed tree, because a header's path length is the depth
/// of the table it defines.
const max_key_segments = 32;

/// How deep arrays and inline tables may nest.
const max_depth = 128;

/// The stack buffer for a number literal with its underscores removed. A
/// longer literal (a float with hundreds of digits) takes an arena buffer
/// instead, so the limit is on this fast path, not on the input.
const max_number_len = 256;

source: []const u8,
pos: usize = 0,
line: u32 = 1,
column: u32 = 1,
allocator: Allocator,
root: *Table = undefined,
current: *Table = undefined,
diagnostic: Diagnostic = .{},
depth: u32 = 0,

/// A position to report errors against, taken before the bytes are read.
const Mark = struct {
    pos: usize,
    line: u32,
    column: u32,
};

/// Prepare to parse `source`. Every value, key, and table is allocated from
/// `allocator`, which is usually an arena's.
pub fn init(allocator: Allocator, source: []const u8) Parser {
    return .{ .source = source, .allocator = allocator };
}

/// Parse the whole source. On `error.Syntax`, `diagnostic` says where and why.
pub fn parse(self: *Parser) Error!Value {
    if (self.source.len > std.math.maxInt(u32)) {
        self.diagnostic = .{
            .span = .{ .start = 0, .end = 0 },
            .line = 1,
            .column = 1,
        };
        self.diagnostic.setMessage("the source is longer than 4 GiB", .{});
        return error.Syntax;
    }
    try self.checkUtf8();
    if (std.mem.startsWith(u8, self.source, "\xEF\xBB\xBF")) self.advanceBy(3);

    self.root = try self.newTable(.{});
    self.current = self.root;
    try self.parseDocument();
    return .{ .table = self.root };
}

// Parsing

fn parseDocument(self: *Parser) Error!void {
    while (true) {
        self.skipSpaces();
        if (self.atEnd()) return;
        switch (self.peek().?) {
            '\n', '\r' => {
                try self.expectNewline();
                continue;
            },
            '#' => {
                try self.skipComment();
                if (!self.atEnd()) try self.expectNewline();
                continue;
            },
            '[' => try self.parseHeader(),
            else => try self.parseKeyValue(self.current),
        }
        self.skipSpaces();
        if (self.peek() == '#') try self.skipComment();
        if (self.atEnd()) return;
        try self.expectNewline();
    }
}

fn parseHeader(self: *Parser) Error!void {
    const mark = self.here();
    _ = self.advance();
    const is_array = self.peek() == '[';
    if (is_array) _ = self.advance();
    self.skipSpaces();

    var segments: [max_key_segments][]const u8 = undefined;
    const path = try self.parseKeyPath(&segments);
    self.skipSpaces();
    if (self.peek() != ']') {
        return self.failAt(mark, "expected `]` to close the table header", .{});
    }
    _ = self.advance();
    if (is_array) {
        if (self.peek() != ']') {
            return self.failAt(mark, "expected `]]` to close the array header", .{});
        }
        _ = self.advance();
    }
    self.current = try self.resolveHeader(path.segments, is_array, mark);
}

/// Walk a header's path from the root and return the table the header opens.
fn resolveHeader(
    self: *Parser,
    path: []const []const u8,
    is_array: bool,
    mark: Mark,
) Error!*Table {
    var table = self.root;
    for (path[0 .. path.len - 1]) |segment| {
        table = try self.descendHeader(table, segment, mark);
    }
    const last = path[path.len - 1];

    if (table.entries.getPtr(last)) |slot| {
        switch (slot.*) {
            .table => |existing| {
                if (is_array) {
                    return self.failAt(
                        mark,
                        "`{s}` is a table, so `[[{s}]]` cannot append to it",
                        .{ last, last },
                    );
                }
                if (existing.flags.implicit and !existing.flags.sealed) {
                    existing.flags.implicit = false;
                    existing.flags.header = true;
                    return existing;
                }
                if (existing.flags.dotted) {
                    return self.failAt(
                        mark,
                        "the table `{s}` was defined by dotted keys, so `[{s}]` cannot define it",
                        .{ last, last },
                    );
                }
                return self.failAt(mark, "the table `{s}` is already defined", .{last});
            },
            .array => |array| {
                if (!is_array) {
                    return self.failAt(mark, "`{s}` is an array, not a table", .{last});
                }
                if (array.kind != .tables) {
                    return self.failAt(
                        mark,
                        "`{s}` was written as a value array, so `[[{s}]]` cannot append to it",
                        .{ last, last },
                    );
                }
                const element = try self.newTable(.{ .header = true });
                try array.items.append(self.allocator, .{ .table = element });
                return element;
            },
            else => return self.failAt(mark, "`{s}` is already defined as a value", .{last}),
        }
    }

    if (is_array) {
        const array = try self.allocator.create(Array);
        array.* = .{ .kind = .tables };
        const element = try self.newTable(.{ .header = true });
        try array.items.append(self.allocator, .{ .table = element });
        try table.entries.put(self.allocator, last, .{ .array = array });
        return element;
    }
    const created = try self.newTable(.{ .header = true });
    try table.entries.put(self.allocator, last, .{ .table = created });
    return created;
}

/// The table a header path segment names. A segment that is an array of
/// tables means its most recently defined element.
fn descendHeader(self: *Parser, table: *Table, segment: []const u8, mark: Mark) Error!*Table {
    if (table.entries.getPtr(segment)) |slot| {
        switch (slot.*) {
            .table => |child| {
                if (child.flags.sealed) {
                    return self.failAt(mark, "the inline table `{s}` is closed", .{segment});
                }
                return child;
            },
            .array => |array| {
                if (array.kind != .tables) {
                    return self.failAt(mark, "`{s}` is an array, not a table", .{segment});
                }
                return array.items.items[array.items.items.len - 1].table;
            },
            else => return self.failAt(mark, "`{s}` is a value, not a table", .{segment}),
        }
    }
    const child = try self.newTable(.{ .implicit = true });
    try table.entries.put(self.allocator, segment, .{ .table = child });
    return child;
}

fn parseKeyValue(self: *Parser, table: *Table) Error!void {
    const mark = self.here();
    var segments: [max_key_segments][]const u8 = undefined;
    const path = try self.parseKeyPath(&segments);
    self.skipSpaces();
    if (self.peek() != '=') {
        return self.failAt(mark, "expected `=` after the key", .{});
    }
    _ = self.advance();
    self.skipSpaces();
    const value = try self.parseValue();
    try self.insert(table, path.segments, mark, path.end, value);
}

/// Insert a key/value pair, creating the intermediate tables a dotted key
/// names.
fn insert(
    self: *Parser,
    table: *Table,
    path: []const []const u8,
    mark: Mark,
    key_end: usize,
    value: Value,
) Error!void {
    var target = table;
    for (path[0 .. path.len - 1]) |segment| {
        if (target.entries.get(segment)) |existing| {
            switch (existing) {
                .table => |child| {
                    if (child.flags.sealed) {
                        return self.failRange(
                            mark,
                            key_end,
                            "the inline table `{s}` is closed",
                            .{segment},
                        );
                    }
                    if (child.flags.header) {
                        return self.failRange(
                            mark,
                            key_end,
                            "a dotted key cannot add to `{s}`, which its own header defined",
                            .{segment},
                        );
                    }
                    target = child;
                },
                .array => return self.failRange(
                    mark,
                    key_end,
                    "`{s}` is an array, not a table",
                    .{segment},
                ),
                else => return self.failRange(
                    mark,
                    key_end,
                    "`{s}` is a value, not a table",
                    .{segment},
                ),
            }
        } else {
            const child = try self.newTable(.{ .dotted = true });
            try target.entries.put(self.allocator, segment, .{ .table = child });
            target = child;
        }
    }

    const last = path[path.len - 1];
    if (target.entries.contains(last)) {
        return self.failRange(mark, key_end, "the key `{s}` is already defined", .{last});
    }
    try target.entries.put(self.allocator, last, value);
}

/// A dotted key: its segments and the byte just past the last one, so a
/// diagnostic can point at the key itself.
const KeyPath = struct {
    segments: []const []const u8,
    end: usize,
};

/// Fill `buf` with the segments of a dotted key and return the used part.
fn parseKeyPath(self: *Parser, buf: *[max_key_segments][]const u8) Error!KeyPath {
    var count: usize = 0;
    var end: usize = 0;
    while (true) {
        if (count == max_key_segments) {
            return self.failHere("a key path is limited to {d} segments", .{max_key_segments});
        }
        buf[count] = try self.parseSimpleKey();
        count += 1;
        end = self.pos;
        self.skipSpaces();
        if (self.peek() != '.') return .{ .segments = buf[0..count], .end = end };
        _ = self.advance();
        self.skipSpaces();
    }
}

fn parseSimpleKey(self: *Parser) Error![]const u8 {
    const mark = self.here();
    const c = self.peek() orelse return self.failAt(mark, "expected a key", .{});
    switch (c) {
        '"' => {
            if (self.peekAt(1) == '"' and self.peekAt(2) == '"') {
                return self.failAt(mark, "a key cannot be a multiline string", .{});
            }
            return self.parseString(.basic);
        },
        '\'' => {
            if (self.peekAt(1) == '\'' and self.peekAt(2) == '\'') {
                return self.failAt(mark, "a key cannot be a multiline string", .{});
            }
            return self.parseString(.literal);
        },
        else => return self.parseBareKey(),
    }
}

fn parseBareKey(self: *Parser) Error![]const u8 {
    const start = self.pos;
    while (self.peek()) |c| {
        if (isBareKeyChar(c)) {
            _ = self.advance();
        } else {
            break;
        }
    }
    if (self.pos == start) {
        return self.failHere("expected a key", .{});
    }
    const key = try self.allocator.dupe(u8, self.source[start..self.pos]);
    return key;
}

// Values

fn parseValue(self: *Parser) Error!Value {
    const mark = self.here();
    const c = self.peek() orelse return self.failAt(mark, "expected a value", .{});
    const value: Value = switch (c) {
        '"', '\'' => blk: {
            const multiline = self.peekAt(1) == c and self.peekAt(2) == c;
            const form: StringForm = switch (c) {
                '"' => if (multiline) .basic_multiline else .basic,
                else => if (multiline) .literal_multiline else .literal,
            };
            break :blk .{ .string = try self.parseString(form) };
        },
        '[' => .{ .array = try self.parseArray() },
        '{' => .{ .table = try self.parseInlineTable() },
        't', 'f' => .{ .boolean = try self.parseBoolean() },
        '+', '-', '0'...'9', 'i', 'n' => blk: {
            if (c >= '0' and c <= '9' and self.startsDatetime()) {
                break :blk .{ .datetime = try self.parseDatetime() };
            }
            break :blk try self.parseNumber();
        },
        else => return self.failUnexpected(mark, "expected a value"),
    };
    try self.expectValueEnd(mark);
    return value;
}

fn parseArray(self: *Parser) Error!*Array {
    const mark = self.here();
    _ = self.advance();
    const array = try self.allocator.create(Array);
    array.* = .{};
    try self.enter(mark);
    defer self.depth -= 1;

    while (true) {
        try self.skipArraySpace();
        const c = self.peek() orelse {
            return self.failAt(mark, "expected `]` to close the array", .{});
        };
        if (c == ']') {
            _ = self.advance();
            return array;
        }
        const element = try self.parseValue();
        try array.items.append(self.allocator, element);
        try self.skipArraySpace();
        const next = self.peek() orelse {
            return self.failAt(mark, "expected `]` to close the array", .{});
        };
        switch (next) {
            ',' => _ = self.advance(),
            ']' => {
                _ = self.advance();
                return array;
            },
            else => return self.failHere("expected `,` or `]` in the array", .{}),
        }
    }
}

fn parseInlineTable(self: *Parser) Error!*Table {
    const mark = self.here();
    _ = self.advance();
    const table = try self.newTable(.{});
    try self.enter(mark);
    defer self.depth -= 1;

    // TOML 1.1: whitespace, newlines, and comments are allowed anywhere
    // between a brace and a key, a comma, or the closing brace.
    try self.skipArraySpace();
    const opening = self.peek() orelse {
        return self.failAt(mark, "expected `}}` to close the inline table", .{});
    };
    if (opening == '}') {
        _ = self.advance();
        seal(table);
        return table;
    }

    while (true) {
        var segments: [max_key_segments][]const u8 = undefined;
        const key_mark = self.here();
        const path = try self.parseKeyPath(&segments);
        self.skipSpaces();
        if (self.peek() != '=') {
            return self.failAt(key_mark, "expected `=` after the key", .{});
        }
        _ = self.advance();
        self.skipSpaces();
        const value = try self.parseValue();
        try self.insert(table, path.segments, key_mark, path.end, value);

        try self.skipArraySpace();
        const next = self.peek() orelse {
            return self.failAt(mark, "expected `}}` to close the inline table", .{});
        };
        switch (next) {
            ',' => {
                _ = self.advance();
                try self.skipArraySpace();
                // A trailing comma is allowed since TOML 1.1.
                if (self.peek() == '}') {
                    _ = self.advance();
                    seal(table);
                    return table;
                }
            },
            '}' => {
                _ = self.advance();
                seal(table);
                return table;
            },
            else => return self.failHere("expected `,` or `}}` in the inline table", .{}),
        }
    }
}

/// Close a table and every table it holds, so no later key can add to them.
fn seal(table: *Table) void {
    if (table.flags.sealed) return;
    table.flags.sealed = true;
    var it = table.entries.iterator();
    while (it.next()) |entry| sealValue(entry.value_ptr.*);
}

fn sealValue(value: Value) void {
    switch (value) {
        .table => |table| seal(table),
        .array => |array| for (array.items.items) |element| sealValue(element),
        else => {},
    }
}

fn parseBoolean(self: *Parser) Error!bool {
    const mark = self.here();
    while (self.peek()) |c| {
        if (!std.ascii.isAlphabetic(c)) break;
        _ = self.advance();
    }
    const word = self.source[mark.pos..self.pos];
    if (std.mem.eql(u8, word, "true")) return true;
    if (std.mem.eql(u8, word, "false")) return false;
    return self.failAt(
        mark,
        "`{s}` is not a boolean; TOML spells them `true` and `false`",
        .{word},
    );
}

fn parseDatetime(self: *Parser) Error!Datetime {
    const mark = self.here();
    const text = self.source[self.pos..];
    const found = Datetime.scan(text) catch {
        const end = self.valueTokenEnd();
        return self.failRange(
            mark,
            self.pos + end,
            "`{s}` is not a valid datetime",
            .{text[0..end]},
        );
    };
    if (found) |datetime| {
        self.advanceBy(datetime.len);
        return datetime.value;
    }
    return self.failHere("expected a datetime", .{});
}

fn parseNumber(self: *Parser) Error!Value {
    const mark = self.here();
    const start = self.pos;
    var sign: ?bool = null;
    switch (self.peek() orelse return self.failAt(mark, "expected a number", .{})) {
        '+' => {
            sign = false;
            _ = self.advance();
        },
        '-' => {
            sign = true;
            _ = self.advance();
        },
        else => {},
    }

    if (self.startsWith("inf")) {
        self.advanceBy(3);
        return .{ .float = if (sign == true) -std.math.inf(f64) else std.math.inf(f64) };
    }
    if (self.startsWith("nan")) {
        self.advanceBy(3);
        return .{ .float = if (sign == true) -std.math.nan(f64) else std.math.nan(f64) };
    }

    var base: u8 = 10;
    if (self.peek() == '0' and self.peekAt(1) != null) {
        base = switch (self.peekAt(1).?) {
            'x' => 16,
            'o' => 8,
            'b' => 2,
            else => 10,
        };
        if (base != 10) {
            if (sign != null) {
                return self.failAt(mark, "a base-prefixed integer cannot have a sign", .{});
            }
            self.advanceBy(2);
            try self.scanDigits(base, mark);
            return self.finishInteger(start, mark, base);
        }
    }

    try self.scanDecimalInt(mark);
    var is_float = false;
    if (self.peek() == '.') {
        is_float = true;
        _ = self.advance();
        try self.scanDigits(10, mark);
    }
    if (self.peek() == 'e' or self.peek() == 'E') {
        is_float = true;
        _ = self.advance();
        if (self.peek() == '+' or self.peek() == '-') _ = self.advance();
        try self.scanDigits(10, mark);
    }
    if (!is_float) return self.finishInteger(start, mark, 10);

    var buf: [max_number_len]u8 = undefined;
    const literal = try self.cleanNumber(start, &buf);
    const value = std.fmt.parseFloat(f64, literal) catch {
        return self.failAt(mark, "`{s}` is not a float", .{self.source[start..self.pos]});
    };
    return .{ .float = value };
}

fn finishInteger(self: *Parser, start: usize, mark: Mark, base: u8) Error!Value {
    var buf: [max_number_len]u8 = undefined;
    const literal = try self.cleanNumber(start, &buf);
    const digits = if (base == 10) literal else literal[2..];
    const value = std.fmt.parseInt(i64, digits, base) catch |err| switch (err) {
        error.Overflow => return self.failAt(
            mark,
            "`{s}` does not fit in a 64-bit signed integer",
            .{self.source[start..self.pos]},
        ),
        error.InvalidCharacter => return self.failAt(
            mark,
            "`{s}` is not an integer",
            .{self.source[start..self.pos]},
        ),
    };
    return .{ .integer = value };
}

/// Copy the number literal that starts at `start` without its underscores,
/// when it has any.
fn cleanNumber(
    self: *Parser,
    start: usize,
    buf: *[max_number_len]u8,
) Error![]const u8 {
    const literal = self.source[start..self.pos];
    if (std.mem.findScalar(u8, literal, '_') == null) return literal;
    if (literal.len <= buf.len) {
        var len: usize = 0;
        for (literal) |c| {
            if (c == '_') continue;
            buf[len] = c;
            len += 1;
        }
        return buf[0..len];
    }
    // Hundreds of digits with underscores: rare enough to take an arena
    // buffer rather than reject a valid literal.
    const clean = try self.allocator.alloc(u8, literal.len);
    var len: usize = 0;
    for (literal) |c| {
        if (c == '_') continue;
        clean[len] = c;
        len += 1;
    }
    return clean[0..len];
}

fn scanDecimalInt(self: *Parser, mark: Mark) Error!void {
    if (self.peek() == '0') {
        _ = self.advance();
        if (self.peek()) |c| {
            if (c >= '0' and c <= '9') {
                return self.failAt(mark, "a decimal integer cannot have a leading zero", .{});
            }
        }
        return;
    }
    try self.scanDigits(10, mark);
}

/// Read one or more digits of `base`, allowing underscores between digits.
fn scanDigits(self: *Parser, base: u8, mark: Mark) Error!void {
    const c = self.peek() orelse return self.failAt(mark, "expected a digit", .{});
    if (!digitValue(c, base)) return self.failUnexpected(mark, "expected a digit");
    _ = self.advance();
    while (self.peek()) |next| {
        if (digitValue(next, base)) {
            _ = self.advance();
            continue;
        }
        if (next == '_') {
            _ = self.advance();
            const after = self.peek() orelse
                return self.failAt(mark, "an underscore must sit between two digits", .{});
            if (!digitValue(after, base)) {
                return self.failAt(mark, "an underscore must sit between two digits", .{});
            }
            continue;
        }
        return;
    }
}

const StringForm = enum {
    basic,
    basic_multiline,
    literal,
    literal_multiline,

    fn multiline(self: StringForm) bool {
        return self == .basic_multiline or self == .literal_multiline;
    }

    fn quote(self: StringForm) u8 {
        return if (self == .basic or self == .basic_multiline) '"' else '\'';
    }

    fn escapes(self: StringForm) bool {
        return self == .basic or self == .basic_multiline;
    }
};

fn parseString(self: *Parser, form: StringForm) Error![]const u8 {
    const mark = self.here();
    const quote = form.quote();
    _ = self.advance();
    if (form.multiline()) {
        if (self.peekAt(0) != quote or self.peekAt(1) != quote) {
            return self.failAt(mark, "a multiline string opens with three `{c}`", .{quote});
        }
        self.advanceBy(2);
        self.trimLeadingNewline();
    }

    const content_start = self.pos;
    var escaped = false;
    while (true) {
        const c = self.peek() orelse {
            return self.failAt(mark, "the string has no closing `{c}`", .{quote});
        };
        if (c == quote) {
            if (!form.multiline()) {
                const content = self.source[content_start..self.pos];
                _ = self.advance();
                return self.finishString(content, form, escaped);
            }
            const run = self.quoteRun(quote);
            if (run < 3) {
                self.advanceBy(run);
                continue;
            }
            const keep: usize = @min(run - 3, 2);
            const content = self.source[content_start .. self.pos + keep];
            self.advanceBy(keep + 3);
            return self.finishString(content, form, escaped);
        }
        if (form.escapes() and c == '\\') {
            const escape = decodeEscape(self.source[self.pos..], form.multiline()) orelse {
                return self.failAt(mark, "`\\` here is not a valid escape", .{});
            };
            escaped = true;
            self.advanceBy(escape.len);
            continue;
        }
        if (c == '\n' or c == '\r') {
            if (!form.multiline()) {
                return self.failAt(mark, "a single-line string cannot span lines", .{});
            }
            try self.scanNewline(mark);
            continue;
        }
        if (c < 0x20 or c == 0x7F) {
            if (c == '\t') {
                _ = self.advance();
                continue;
            }
            return self.failAt(
                mark,
                "the control character 0x{x:0>2} is not allowed in a string",
                .{c},
            );
        }
        _ = self.advance();
    }
}

/// How many `quote` bytes start at the current position, capped at five.
fn quoteRun(self: *const Parser, quote: u8) usize {
    var count: usize = 0;
    while (count < 5 and self.peekAt(count) == quote) count += 1;
    return count;
}

fn finishString(
    self: *Parser,
    content: []const u8,
    form: StringForm,
    escaped: bool,
) Error![]const u8 {
    const buffer = try self.allocator.dupe(u8, content);
    if (!escaped) return buffer;
    return buffer[0..unescape(buffer, form.multiline())];
}

/// Decode `buffer` in place. `buffer` came from a scan that validated every
/// escape, so an unknown escape here is a broken invariant, not bad input.
fn unescape(buffer: []u8, multiline: bool) usize {
    var read: usize = 0;
    var write: usize = 0;
    while (read < buffer.len) {
        if (buffer[read] != '\\') {
            buffer[write] = buffer[read];
            read += 1;
            write += 1;
            continue;
        }
        const escape = decodeEscape(buffer[read..], multiline).?;
        for (escape.value[0..escape.value_len]) |byte| {
            buffer[write] = byte;
            write += 1;
        }
        read += escape.len;
    }
    return write;
}

const Escape = struct {
    /// Bytes the escape occupies in the source.
    len: usize,
    value: [4]u8 = undefined,
    value_len: u8 = 0,
};

/// Decode the escape that starts at `text[0]`, or null when it is not one.
///
/// A line-ending backslash in a multiline string decodes to no bytes and eats
/// the whitespace and newlines that follow it.
fn decodeEscape(text: []const u8, multiline: bool) ?Escape {
    if (text.len < 2 or text[0] != '\\') return null;

    if (multiline) {
        var at: usize = 1;
        while (at < text.len and (text[at] == ' ' or text[at] == '\t')) at += 1;
        if (at < text.len and (text[at] == '\n' or text[at] == '\r')) {
            if (text[at] == '\r') {
                if (at + 1 >= text.len or text[at + 1] != '\n') return null;
                at += 2;
            } else {
                at += 1;
            }
            while (at < text.len) {
                switch (text[at]) {
                    ' ', '\t', '\n' => at += 1,
                    '\r' => {
                        if (at + 1 >= text.len or text[at + 1] != '\n') return null;
                        at += 2;
                    },
                    else => break,
                }
            }
            return .{ .len = at };
        }
    }

    const byte = text[1];
    const simple: ?u8 = switch (byte) {
        'b' => 0x08,
        't' => '\t',
        'n' => '\n',
        'f' => 0x0C,
        'r' => '\r',
        'e' => 0x1B,
        '"' => '"',
        '\\' => '\\',
        else => null,
    };
    if (simple) |value| return .{ .len = 2, .value = .{ value, 0, 0, 0 }, .value_len = 1 };

    switch (byte) {
        'x' => {
            if (text.len < 4) return null;
            const code = hexValue(text[2..4]) orelse return null;
            return encodeEscape(@intCast(code), 4);
        },
        'u' => {
            if (text.len < 6) return null;
            const code = hexValue(text[2..6]) orelse return null;
            if (code > 0x10FFFF) return null;
            return encodeEscape(@intCast(code), 6);
        },
        'U' => {
            if (text.len < 10) return null;
            const code = hexValue(text[2..10]) orelse return null;
            if (code > 0x10FFFF) return null;
            return encodeEscape(@intCast(code), 10);
        },
        else => return null,
    }
}

fn encodeEscape(code: u21, len: usize) ?Escape {
    var value: [4]u8 = undefined;
    const written = std.unicode.utf8Encode(code, &value) catch return null;
    return .{ .len = len, .value = value, .value_len = written };
}

fn hexValue(digits: []const u8) ?u32 {
    var value: u32 = 0;
    for (digits) |c| {
        const digit: u32 = switch (c) {
            '0'...'9' => c - '0',
            'a'...'f' => c - 'a' + 10,
            'A'...'F' => c - 'A' + 10,
            else => return null,
        };
        value = value * 16 + digit;
    }
    return value;
}

// Scanning helpers

fn atEnd(self: *const Parser) bool {
    return self.pos >= self.source.len;
}

fn peek(self: *const Parser) ?u8 {
    if (self.pos >= self.source.len) return null;
    return self.source[self.pos];
}

fn peekAt(self: *const Parser, offset: usize) ?u8 {
    const at = self.pos + offset;
    if (at >= self.source.len) return null;
    return self.source[at];
}

fn here(self: *const Parser) Mark {
    return .{ .pos = self.pos, .line = self.line, .column = self.column };
}

fn advance(self: *Parser) u8 {
    const c = self.source[self.pos];
    self.pos += 1;
    if (c == '\n') {
        self.line += 1;
        self.column = 1;
    } else {
        self.column += 1;
    }
    return c;
}

fn advanceBy(self: *Parser, count: usize) void {
    var left = count;
    while (left > 0) : (left -= 1) _ = self.advance();
}

fn startsWith(self: *const Parser, text: []const u8) bool {
    return std.mem.startsWith(u8, self.source[self.pos..], text);
}

/// Whether the value at the current position starts with a date or a time,
/// which only the datetime reader can tell apart from a number.
fn startsDatetime(self: *const Parser) bool {
    var digits: usize = 0;
    while (digits < 4) : (digits += 1) {
        const c = self.peekAt(digits) orelse return self.startsTime();
        if (c < '0' or c > '9') return self.startsTime();
    }
    return self.peekAt(4) == '-';
}

fn startsTime(self: *const Parser) bool {
    var digits: usize = 0;
    while (digits < 2) : (digits += 1) {
        const c = self.peekAt(digits) orelse return false;
        if (c < '0' or c > '9') return false;
    }
    return self.peekAt(2) == ':';
}

fn skipSpaces(self: *Parser) void {
    while (self.peek()) |c| {
        if (c != ' ' and c != '\t') return;
        _ = self.advance();
    }
}

fn skipComment(self: *Parser) Error!void {
    const mark = self.here();
    _ = self.advance();
    while (self.peek()) |c| {
        switch (c) {
            '\n', '\r' => return,
            '\t', 0x20...0x7E => _ = self.advance(),
            0x80...0xFF => _ = self.advance(),
            else => return self.failAt(
                mark,
                "the control character 0x{x:0>2} is not allowed in a comment",
                .{c},
            ),
        }
    }
}

fn skipArraySpace(self: *Parser) Error!void {
    while (true) {
        const c = self.peek() orelse return;
        switch (c) {
            ' ', '\t' => _ = self.advance(),
            '\n' => _ = self.advance(),
            '\r' => try self.scanNewline(self.here()),
            '#' => try self.skipComment(),
            else => return,
        }
    }
}

fn expectNewline(self: *Parser) Error!void {
    const c = self.peek() orelse return;
    if (c == '\n') {
        _ = self.advance();
        return;
    }
    if (c == '\r') return self.scanNewline(self.here());
    return self.failUnexpected(self.here(), "expected the end of the line");
}

/// Consume a newline: LF, or CRLF. A bare carriage return is not a newline.
fn scanNewline(self: *Parser, mark: Mark) Error!void {
    const c = self.peek() orelse return;
    if (c == '\n') {
        _ = self.advance();
        return;
    }
    if (c == '\r' and self.peekAt(1) == '\n') {
        self.advanceBy(2);
        return;
    }
    if (c == '\r') {
        return self.failAt(mark, "a carriage return must be followed by a line feed", .{});
    }
    return self.failUnexpected(mark, "expected a newline");
}

fn trimLeadingNewline(self: *Parser) void {
    if (self.peek() == '\n') {
        _ = self.advance();
    } else if (self.peek() == '\r' and self.peekAt(1) == '\n') {
        self.advanceBy(2);
    }
}

fn expectValueEnd(self: *Parser, mark: Mark) Error!void {
    const c = self.peek() orelse return;
    if (isValueEnd(c)) return;
    return self.failUnexpected(mark, "expected the end of the value");
}

/// The length of the run of bytes that could be part of a value literal, for
/// reporting an invalid one.
fn valueTokenEnd(self: *const Parser) usize {
    var at = self.pos;
    while (at < self.source.len and !isValueEnd(self.source[at])) at += 1;
    return at - self.pos;
}

fn enter(self: *Parser, mark: Mark) Error!void {
    if (self.depth == max_depth) {
        return self.failAt(mark, "values cannot nest more than {d} deep", .{max_depth});
    }
    self.depth += 1;
}

/// Check that the whole source is UTF-8, so no later scan has to.
fn checkUtf8(self: *Parser) Error!void {
    if (std.unicode.utf8ValidateSlice(self.source)) return;
    return self.failUtf8(firstInvalidUtf8(self.source));
}

/// The offset of the first byte that is not part of a valid UTF-8 sequence.
/// Only runs on a source `utf8ValidateSlice` already rejected.
fn firstInvalidUtf8(source: []const u8) usize {
    var at: usize = 0;
    while (at < source.len) {
        const length = std.unicode.utf8ByteSequenceLength(source[at]) catch return at;
        if (at + length > source.len) return at;
        switch (length) {
            1 => {},
            2 => _ = std.unicode.utf8Decode2(source[at..][0..2].*) catch return at,
            3 => _ = std.unicode.utf8Decode3(source[at..][0..3].*) catch return at,
            4 => _ = std.unicode.utf8Decode4(source[at..][0..4].*) catch return at,
            else => unreachable,
        }
        at += length;
    }
    return at;
}

fn failUtf8(self: *Parser, at: usize) Error {
    var line: u32 = 1;
    var column: u32 = 1;
    for (self.source[0..at]) |c| {
        if (c == '\n') {
            line += 1;
            column = 1;
        } else {
            column += 1;
        }
    }
    self.diagnostic = .{
        .span = .{ .start = @intCast(at), .end = @intCast(at + 1) },
        .line = line,
        .column = column,
    };
    self.diagnostic.setMessage("the source is not valid UTF-8", .{});
    return error.Syntax;
}

// Failures

fn failHere(self: *Parser, comptime fmt: []const u8, args: anytype) Error {
    return self.failAt(self.here(), fmt, args);
}

/// Fail on the bytes between `mark` and the current position.
fn failAt(self: *Parser, mark: Mark, comptime fmt: []const u8, args: anytype) Error {
    return self.failRange(mark, self.pos, fmt, args);
}

fn failRange(self: *Parser, mark: Mark, end: usize, comptime fmt: []const u8, args: anytype) Error {
    self.diagnostic = .{
        .span = .{ .start = @intCast(mark.pos), .end = @intCast(end) },
        .line = mark.line,
        .column = mark.column,
    };
    self.diagnostic.setMessage(fmt, args);
    return error.Syntax;
}

fn failUnexpected(self: *Parser, mark: Mark, comptime context: []const u8) Error {
    const c = self.peek() orelse {
        return self.failAt(mark, context ++ ": the input ends here", .{});
    };
    if (c < 0x20 or c >= 0x7F) {
        return self.failAt(mark, context ++ ": the byte 0x{x:0>2} is not allowed here", .{c});
    }
    return self.failAt(mark, context ++ ": found `{c}`", .{c});
}

fn newTable(self: *Parser, flags: Table.Flags) Error!*Table {
    const table = try self.allocator.create(Table);
    table.* = .{ .flags = flags };
    return table;
}

fn isValueEnd(c: u8) bool {
    return switch (c) {
        ' ', '\t', '\n', '\r', ',', ']', '}', '#' => true,
        else => false,
    };
}

fn isBareKeyChar(c: u8) bool {
    return switch (c) {
        'A'...'Z', 'a'...'z', '0'...'9', '_', '-' => true,
        else => false,
    };
}

fn digitValue(c: u8, base: u8) bool {
    return switch (base) {
        2 => c == '0' or c == '1',
        8 => c >= '0' and c <= '7',
        10 => c >= '0' and c <= '9',
        16 => std.ascii.isHex(c),
        else => unreachable,
    };
}
