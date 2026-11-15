# AGENTS.md

Working notes for AI coding agents in baskingspot/toml.

## What this is

TOML 1.1 in Zig: a strict parser, a value tree, and a writer. The parser reads 1.1.0; the writer emits 1.0.0 so any 1.0 parser accepts its output. It is incubating: unstable, with no promises about its API.

## Environment

Zig 0.17. The flake is the tool contract, from `baskingspot/nix`: `nix develop` provides Zig 0.17, `ziglint`, `baskingspot-lint`, and the base tools, and nothing comes from the system PATH. The justfile is the command interface: `just test`, `just check`, `just lint`, `just ci`. CI runs `just ci` on the default shell. Run `just fmt` before you commit.

Tests run under testingx, the org's test runner, a lazy dependency. Every `addTest` carries `.test_runner = .{ .path = dep.path("src/runner.zig"), .mode = .simple }`; the runner picks and prints its own seed. Fuzz mode stays on the built-in runner, because testingx rejects it. Do not re-add the built-in runner to the test steps.

`zig fmt` owns the enum builtins: it migrates `@intFromEnum` and `@enumFromInt` to `@backingInt` and `@fromBackingInt`, so write the 0.17 spelling and let the formatter settle it. `**`, the array-repeat operator, is gone: repeat with `@splat` or a loop.

The conformance corpus in `test/toml-test/` is vendored from `toml-lang/toml-test` and must not be edited to make a test pass; `THIRD_PARTY.md` records the commit. `just test` runs the corpus, `just fuzz` runs the parser fuzz target.

## Rules

- Lint with `ziglint-0-17`, not `ziglint`: the wrapper points ziglint at the 0.17 std, the one this repo supports, so a deprecation a newer std carries does not fire.
- Commit messages are one line, `area: summary`, and every commit is signed. Do not rewrite pushed history.
- Gate commands on their exit codes, and claim only what you ran.
- Format with `zig fmt`; lint with `ziglint` and `baskingspot-lint`, which runs the org's shared ast-grep rules. `just fmt` formats and `just lint` lints.
- Constructors are named, never a bare `.{}`: a type either carries a `pub const init`/`empty`/`zero` with the defaults spelled out, or a `pub fn init(...)` when there are variables to set. The fields stay required, so a bare `.{}` or a partial literal does not compile. An options bag is the one exception: a `Config`/`Options` struct a caller passes to a function or a type constructor keeps its field defaults, whether the value is comptime or runtime, because the call site overrides one knob and leaves the rest, with `// ast-grep-ignore: public-struct-field-default -- options bag: call sites override one knob` between its doc comment and its declaration.
- This repo's GitHub settings come from `baskingspot/.github`, with `just settings`. Do not change them by hand.
- To graduate the project, follow the `baskingspot-new-repo` skill: logos, a real README, and the audit passing.

## Changelog

`CHANGELOG.md` is one file, Keep a Changelog format, newest first. Add a bullet
under `## [Unreleased]` in the same change that alters something a user can
notice: the public API, expected behavior, performance a benchmark row would
show, a supported backend, or the build requirements. Docs, CI, and internal
refactors do not need one unless they change how someone uses the package.

Write from the user's side: what changed, and what they must do about it. Name
the symbol, flag, or error. One line, under Added, Changed, Fixed, or Removed.

To release, dispatch the repo's `release.yml` with the version. The workflow
moves the Unreleased section into a dated heading, sets `.version` in
`build.zig.zon`, commits, tags, and opens the GitHub release. Do not tag by hand.
