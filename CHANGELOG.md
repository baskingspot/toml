# Changelog

All notable changes to toml are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added

- `parseFromSlice` and `parseFromSliceLeaky` read a TOML 1.0.0 document into a `Document`, a `Value` tree in one arena.
- `Document.deinit` frees the parse, and `Diagnostic` reports a byte span, a one-based line and column, and a message.
- `Value`, `Table`, `Array`, and `Datetime` describe the tree, with tables in document order and all four datetime forms.
- `stringify` writes a tree as TOML that parses back to an equal tree, quoting keys only when the bare form cannot carry them.
- The toml-test 1.0.0 corpus runs in `just test`: 208 valid documents parse and match their JSON expectations, 509 invalid documents are rejected, and every valid document round-trips through the writer.
- `just fuzz` runs the parser over arbitrary bytes and checks the write-and-reparse property.
