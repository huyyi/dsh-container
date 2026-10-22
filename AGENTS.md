# Agent instructions — derived dsh image

## Scope

This repository extends the digest-pinned upstream image in Containerfile. Do not rebuild
Harness, copy upstream runtime scripts, or restore source-build adapters. The base owns dsh,
the toolchain, proxy, healthcheck and runtime user (UID 1000).

- Containerfile: base pin, locked image-owned extension installs, wrapper entrypoint.
- container/derived-entrypoint.sh: seed plugins, then exec the inherited entrypoint.
- container/dsh-plugins-seed.sh: register bundles as installed but disabled; preserve user installs.
- container/plugin-payload/: existing bundles plus A2A, pnpm lockfile.
- container/tui-payload/: independent dsh-tui client, npm lockfile.
- scripts/image_metadata.py: main/PR policy and version labels.
- tests/extensions.sh: image health, proxy auth, offline A2A activation and TUI CLI startup.
- tests/test_image_metadata.py and tests/validate-docs.py: offline validation.
- examples/: deployments and locally maintained demos; never commit runtime data or credentials.

## Invariants

Plugins live outside /home/dsh so mounting data cannot hide the payload.
A2A remains disabled until explicitly enabled. The TUI client is not a dsh bundle and its
dependencies must remain isolated. Keep the documented TUI RPC incompatibility visible;
installation success is not functional terminal-client compatibility.

Expose proxy port 3081 on host loopback by default, never expose internal 3080. The proxy supplies
a fully authenticated dsh session; do not call it secure by default. Basic auth/TLS and trusted
networking are required for broader exposure. This base does not provide the optional SSH server.

## Workflow

Present user-facing changes and their costs before implementation and wait for approval.
Preserve unrelated work. Do not push, tag, publish or merge without explicit user authorization.
main push always builds/tests/publishes both architectures; PR docs-only skips builds, other PRs
build/test without publishing; dispatch validates only. No Git tag or Release automation.
Image labels derive solely from Containerfile's pinned version and the commit's seven-char prefix.

Use apply_patch for edits. Code comments are Chinese; user-facing docs are English except
README.zh.md, which mirrors README.md structure and code examples. Commit messages use feat:,
fix:, docs: or ci:. Deleting obsolete tracked files is recoverable through Git history.

## Validation

Run shell syntax and shellcheck on container/*.sh and tests/*.sh, Python unittest discovery,
the documentation checker and Compose config parsing. Run tests/extensions.sh against the built
image for runtime/package changes. Never send model requests as part of smoke tests.
