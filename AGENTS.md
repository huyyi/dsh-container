# Agent instructions — dsh offline plugins

## Scope

Maintain plugin packaging only. Use an existing upstream host image; do not
build, publish or modify a host image or copy its runtime scripts.

- `plugin/plugins.json`: exact versions and per-plugin `pack_build_deps`.
- `plugin/offline_repack.sh`: host CLI and producer/consumer containers.
- `plugin/offline_repack.mjs`: source preparation, dependency install and output.
- `plugin/runtime.mjs`: portable dependency graph and host singleton links.
- `plugin/verify.mjs`: independent offline checks and rebuilds.
- `plugin/recipes/`: pinned plugin-specific inputs and patches.
- `tests/`: static checks and integration tests; never send model requests.

## Invariants

Downloads, installs and builds run in the supplied host image. Record actual
dsh version, image ID/digests, Node version and architecture. Fix the image ID
for producer and consumer. Never rely on derived image metadata or preinstalled
third-party bundles. Output one directory per plugin, named with plugin name,
version and dsh host version; reject existing outputs.

`pack_build_deps=true` includes source, lockfile and portable development
dependencies and must pass a rebuild without network access. Runtime peers
reuse compatible host packages; do not duplicate Cordis or host singletons.
Keep plugin mounts outside `/home/dsh`. No automatic installation/enabling in
an active user profile. External services remain separate requirements.

Preserve unrelated work and existing generated artifacts. Never commit archives,
downloads, dependency caches, runtime data or credentials. Expose proxy 3081 on
host loopback by default; never publish 3080. Broader exposure requires basic
auth/TLS and trusted networking. The upstream proxy supplies an authenticated
session; do not call it secure by default. Do not claim optional SSH or TUI RPC
compatibility.

## Workflow

Present user-facing changes and costs before implementation and wait for
approval unless already authorized. Do not push, tag, publish or merge without
explicit authorization. CI validates packaging; it does not publish host images.
Use apply_patch for edits. Code comments are Chinese. User-facing docs are
English except README.zh.md, which mirrors README.md structure and examples.
Commit messages use feat:, fix:, docs: or ci:.

## Validation

Run Bash syntax and shellcheck for plugin/test scripts, Node syntax and unit
tests, Python unittest discovery, doc validation and Compose config parsing.
Run `tests/plugin-offline-repack.sh` on the user-selected host for packaging
changes. Default: `ghcr.io/niyueee/dsh-container:dsh-v0.2.2-rc.2`.
