# toml-test corpus

This directory is the conformance corpus from
[`toml-lang/toml-test`](https://github.com/toml-lang/toml-test), vendored as
data at commit `96fd088448ec0f4d9f061c730ed7854399c46faf`.

`tests/files-toml-1.0.0` is the manifest of the TOML 1.0.0 suite, and only the
files it lists were copied. The license is in `LICENSE`, and `THIRD_PARTY.md`
at the repository root records the terms.

`test/corpus.zig` reads these files; do not edit them to make a test pass.
