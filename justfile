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

[doc("Lint Zig, Nix, Markdown, the workflows, and this justfile: ziglint, the shared ast-grep rules, zig fmt, nix fmt, oxfmt, actionlint, zizmor, and just --fmt")]
[group("lint")]
lint:
    ziglint
    baskingspot-lint src
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

[doc("Everything CI runs: the tests, lint, and the site build")]
[group("ci")]
ci: test lint doc

[doc("Build the site into zig-out/site/toml/: the guide (Zola, from docs/) and the API reference (docgen JSON, rendered by the theme's api.html) under api/. The router in baskingspot/site serves /toml/... from it")]
[group("docs")]
doc: api
    baskingspot-docs build toml

[doc("Edit the guide with live reload (http://127.0.0.1:1111), API reference included")]
[group("docs")]
guide: api
    baskingspot-docs serve toml

# The API reference data. docgen comes from the baskingspot flake's docs shell,
# so this is not a Zig build dependency.
[private]
api:
    docgen --root src/root.zig --title toml --repo-url https://github.com/baskingspot/toml --rev main --format json --out docs/data

[doc("Deploy the rendered docs to Cloudflare as an assets-only Worker (config in wrangler.jsonc). Needs CLOUDFLARE_API_TOKEN in the environment, plus CLOUDFLARE_ACCOUNT_ID if the token can see more than one account")]
[group("docs")]
doc-deploy: doc
    wrangler deploy
