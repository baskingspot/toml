<h1>
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/static/logo-dark.svg">
    <img src="docs/static/logo.svg" alt="toml" height="48">
  </picture>
</h1>

TOML 1.1.0 in Zig: a strict parser, a value tree, and a writer.

Zig has no TOML parser in std. This one reads the whole of TOML 1.1.0 into a
tree you can walk, and writes it back as TOML. It rejects what the grammar
rejects: a table defined twice, a dotted key that reaches into a header's
table, and an inline table extended after its brace.

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

- [Reading a document](https://baskingspot.dev/toml/#reading-a-document): `parseFromSlice` returns a `Document` or a `Diagnostic` with a byte span, a line, and a column.
- [The value tree](https://baskingspot.dev/toml/#the-value-tree): `Value`, `Table`, and `Array`, with tables in document order and all four datetime forms.
- [Writing a document](https://baskingspot.dev/toml/#writing-a-document): `stringify` emits TOML 1.0.0 that parses back to an equal tree, quoting keys only when the bare form cannot carry them.
- [Conformance](https://baskingspot.dev/toml/#conformance): 218 valid and 502 invalid documents from the `toml-test` 1.1.0 list, run by `just test`.
- [Limits](https://baskingspot.dev/toml/#limits): a writer that drops comments and extra whitespace, and stays inside TOML 1.0.0.

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

- The [guide](https://baskingspot.dev/toml/) covers parsing, the tree, writing, and the corpus.
- The [API reference](https://baskingspot.dev/toml/api/) documents every public symbol. Every declaration in `src/` carries the doc comment the API entry renders.
- [`docs/examples/`](docs/examples/) is the test-verified code shown in the guide: `just test` compiles and runs it alongside the module's own tests.
- [`AGENTS.md`](AGENTS.md) has the working notes for the repository.

## Work on it

```sh
just ci
```

`nix develop` provides the toolchain and the site tools. `just` lists the recipes, and `just ci` runs what CI runs: the tests, the conformance corpus, lint, and the site build. `just guide` serves the guide with live reload, `just doc` builds the whole site into `zig-out/site/toml/`, and `just fuzz` runs the parser over arbitrary bytes.

The conformance target is the vendored corpus in [`test/toml-test/`](test/toml-test/README.md), selected by its `files-toml-1.1.0` manifest. `just test` runs all of it: every valid document parses and matches its tagged-JSON expectation, every invalid document is rejected, and every valid document survives a write and a re-parse.

## License

MIT. See [`LICENSE`](LICENSE). The test corpus is vendored from `toml-lang/toml-test`; [`THIRD_PARTY.md`](THIRD_PARTY.md) lists its terms. The logo files in `docs/static/` are baskingspot marks and are not covered by it. See [`docs/static/LICENSE`](docs/static/LICENSE).

## How it's made

Built with LLM assistance. [How, in detail](https://github.com/baskingspot/.github/blob/main/docs/AI.md).

<a href="https://github.com/baskingspot"><img src="https://raw.githubusercontent.com/baskingspot/.github/main/brand/assets/badge.svg" alt="baskingspot" height="24"></a>
