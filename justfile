# toml: TOML 1.1.0 in Zig: a strict parser, a value tree, and a writer. `just --list` shows the recipes.
# AGENTS.md holds the working conventions.

[private]
default:
    @just --list

[doc("Unit tests (Debug): the module, the toml-test corpus, and the guide's examples")]
[group("test")]
test:
    zig build test --summary all

[doc("Fuzz the parser with an iteration budget, for example `just fuzz 50M`. ReleaseSafe forces the LLVM backend, dodging the 0.16.0 self-hosted-backend bug in Debug fuzz mode (ziglang/zig#30655)")]
[group("test")]
fuzz LIMIT="10M":
    zig build fuzz -Doptimize=ReleaseSafe --fuzz={{ LIMIT }}

[doc("Lint Zig, Nix, Markdown, the workflows, and this justfile: ziglint, zig fmt, nix fmt, oxfmt, actionlint, zizmor, and just --fmt")]
[group("lint")]
lint:
    ziglint
    zig fmt --check src docs/examples test/corpus.zig build.zig build.zig.zon
    nix fmt -- --ci
    oxfmt --check README.md AGENTS.md CHANGELOG.md THIRD_PARTY.md docs/content docs/config.toml .github .oxfmtrc.jsonc
    actionlint
    zizmor .
    just --fmt --check

[doc("Format everything lint checks")]
[group("lint")]
fmt:
    zig fmt src docs/examples test/corpus.zig build.zig build.zig.zon
    nix fmt
    oxfmt README.md AGENTS.md CHANGELOG.md THIRD_PARTY.md docs/content docs/config.toml .github .oxfmtrc.jsonc
    just --fmt

[doc("Everything CI runs: the tests and lint")]
[group("ci")]
ci: test lint
