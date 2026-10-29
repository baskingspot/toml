# Changelog

All notable changes to toml are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Changed

- The parser reads TOML 1.1.0: newlines and trailing commas in inline tables, the `\e` and `\xHH` escapes, and optional seconds in times and datetimes. `stringify` still writes TOML 1.0.0, so any 1.0 parser reads its output.

### Added

- `parseFromSlice` and `parseFromSliceLeaky` read a TOML 1.1.0 document into a `Document`, a `Value` tree in one arena.
- `Document.deinit` frees the parse, and `Diagnostic` reports a byte span, a one-based line and column, and a message.
- `Value`, `Table`, `Array`, and `Datetime` describe the tree, with tables in document order and all four datetime forms.
- `stringify` writes a tree as TOML that parses back to an equal tree, quoting keys only when the bare form cannot carry them.
- The toml-test corpus runs in `just test`: 218 valid documents parse and match their JSON expectations, 502 invalid documents are rejected, and every valid document round-trips through the writer.
- `just fuzz` runs the parser over arbitrary bytes and checks the write-and-reparse property.
