# Third-party code and data

toml is MIT (`LICENSE`). No upstream code is adapted: the parser, the tree, and
the writer are written for this repository. Two upstream artifacts define what
that code must do, and one of them ships here as test data.

## TOML 1.0.0

- Upstream: https://github.com/toml-lang/toml/tree/1.0.0
- Files: `toml.md` (the specification) and `toml.abnf` (the grammar)
- License: MIT
- Pinned tag: `1.0.0`, released 2021-01-11

The grammar and the prose are the reference for `src/Parser.zig` and
`src/Writer.zig`. No text from either file is copied into this repository, so
nothing from it ships in a release.

## toml-test

- Upstream: https://github.com/toml-lang/toml-test
- License: MIT, in `test/toml-test/LICENSE`, kept verbatim
- Pinned commit: `96fd088448ec0f4d9f061c730ed7854399c46faf`

`test/toml-test/` holds the conformance corpus, vendored as data:

- `tests/files-toml-1.0.0` is the manifest of the 1.0.0 suite, and it decides
  which files were copied.
- `tests/valid/**` holds 208 documents and their 208 tagged-JSON expectations.
- `tests/invalid/**` holds 509 documents that must be rejected.

Only the files the 1.0.0 manifest lists are present. The 1.1-only cases
(`valid/spec-1.1.0/`, `invalid/spec-1.1.0/`, and the individual 1.1 additions)
are not vendored, so the corpus cannot silently require TOML 1.1 behavior.

The corpus is read by `test/corpus.zig` at test time. It is not compiled into
the library and is not listed in `build.zig.zon`'s `paths`, so a `zig fetch`
tarball does not carry it.
