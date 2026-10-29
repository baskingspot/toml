# toml

TOML 1.1.0 in Zig: a strict parser, a value tree, and a writer.

Zig has no TOML parser in `std`. This one reads the whole of TOML 1.1.0 into a
tree you can walk, and writes that tree back out as TOML. It rejects what the
grammar rejects, including the cases a shortcut gets wrong: a table defined
twice, a dotted key that reaches into a table its own header defined, and an
inline table extended after its closing brace.

Reads 1.1, writes 1.0. The writer never emits the 1.1-only syntax, so any
TOML 1.0 parser accepts its output: inline tables stay on one line, `\e` is
written as `\u001b`, `\xHH` as the codepoint in UTF-8, and a time without
seconds gets `:00`.

```zig
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

The library is incubating: pin a commit, and expect the API to move.

## What is in it

- [Reading a document](docs/content/_index.md#reading-a-document): `parseFromSlice` returns a `Document` or a `Diagnostic` with a byte span, a line, and a column.
- [The value tree](docs/content/_index.md#the-value-tree): `Value`, `Table`, and `Array`, with tables in document order and all four datetime forms.
- [Writing a document](docs/content/_index.md#writing-a-document): `stringify` emits TOML 1.0.0 that parses back to an equal tree, quoting keys only when the bare form cannot carry them.
- [Conformance](docs/content/_index.md#conformance): 218 valid and 502 invalid documents from the `toml-test` 1.1.0 list, run by `just test`.
- [Limits](docs/content/_index.md#limits): a writer that drops comments and extra whitespace, and stays inside TOML 1.0.0.

Not implemented:

- Comment and whitespace preservation: `Value` has no place for them, so `stringify` emits a normalized document.
- A streaming parser: `parseFromSlice` wants the whole document in memory.

## Install

```sh
zig fetch --save git+https://github.com/baskingspot/toml
```

Add the module in `build.zig`:

```zig
const toml = b.dependency("toml", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("toml", toml.module("toml"));
```

`toml` builds with Zig 0.16 only.

## Documentation

- The [guide](docs/content/_index.md) covers parsing, the tree, writing, and the corpus.
- The [API reference](https://baskingspot.dev/toml/api/) documents every public symbol. Every declaration in `src/` carries the doc comment it renders, and `zigdoc toml.Value` reads one from the local build.
- [`AGENTS.md`](AGENTS.md) has the working notes for the repository.

## Work on it

```sh
nix develop   # Zig 0.16, ziglint, and the base tools
just ci       # the unit tests, the toml-test corpus, and lint
just fuzz     # fuzz the parser, 10M iterations by default
```

The conformance target is the vendored corpus in [`test/toml-test/`](test/toml-test/README.md), selected by its `files-toml-1.1.0` manifest. `just test` runs all of it: every valid document parses and matches its tagged-JSON expectation, every invalid document is rejected, and every valid document survives a write and a re-parse.

## License

MIT. See `LICENSE`. The test corpus is vendored from `toml-lang/toml-test`; [`THIRD_PARTY.md`](THIRD_PARTY.md) lists its terms.

## How it's made

Built with LLM assistance. [How, in detail](https://github.com/baskingspot/.github/blob/main/docs/AI.md).

<a href="https://github.com/baskingspot"><img src="https://raw.githubusercontent.com/baskingspot/.github/main/brand/assets/badge.svg" alt="baskingspot" height="24"></a>
