# Third-party code and data

toml is MIT (`LICENSE`). No upstream code is adapted: the parser, the tree, and
the writer are written for this repository. Two upstream artifacts define what
that code must do, and one of them ships here as test data.

## TOML

- Upstream: https://github.com/toml-lang/toml
- Files: `toml.md` (the specification) and `toml.abnf` (the grammar)
- License: MIT
- Pinned tags: `1.1.0`, released 2025-12-18, for the parser, and `1.0.0`,
  released 2021-01-11, for what the writer emits

The grammar and the prose are the reference for `src/Parser.zig` and
`src/Writer.zig`. No text from either file is copied into this repository, so
nothing from it ships in a release.

## toml-test

- Upstream: https://github.com/toml-lang/toml-test
- License: MIT, in `test/toml-test/LICENSE`, kept verbatim
- Pinned commit: `96fd088448ec0f4d9f061c730ed7854399c46faf`

`test/toml-test/` holds the conformance corpus, vendored as data:

- `tests/files-toml-1.1.0` is the manifest of the 1.1.0 suite, and it decides
  which files were copied.
- `tests/valid/**` holds 218 documents and their 218 tagged-JSON expectations.
- `tests/invalid/**` holds 502 documents that must be rejected.

Only the files the 1.1.0 manifest lists are present. The 1.0 manifest is not
vendored: several documents that 1.0 rejects are valid 1.1, so keeping both
would make the suite contradict itself.

The corpus is read by `test/corpus.zig` at test time. It is not compiled into
the library and is not listed in `build.zig.zon`'s `paths`, so a `zig fetch`
tarball does not carry it.
