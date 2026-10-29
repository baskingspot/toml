# Changelog

All notable changes to toml are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

## [0.1.0] - 2026-10-29

### Added

- `parseFromSlice` and `parseFromSliceLeaky` read a TOML 1.1.0 document into a
  `Document`, a `Value` tree in one arena. A syntax error is
  `error.SyntaxError`, and `ParseOptions.diagnostics` points at a caller-owned
  `Diagnostics` with a byte span, a one-based line and column, and a message.
- `Document.deinit` frees the parse.
- `Value`, `Table`, `Array`, and `Datetime` describe the tree, with tables in
  document order and all four datetime forms.
- `stringify` writes a tree as TOML 1.0.0 that parses back to an equal tree,
  quoting keys only when the bare form cannot carry them. Any 1.0 parser reads
  its output.
- The toml-test corpus runs in `just test`: 218 valid documents parse and match
  their JSON expectations, 502 invalid documents are rejected, and every valid
  document round-trips through the writer.
- `just fuzz` runs the parser over arbitrary bytes and checks the
  write-and-reparse property.
