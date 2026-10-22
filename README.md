# dsh Container with A2A and TUI

A thin derivative of `ghcr.io/niyueee/dsh-container`. The base tag and multi-architecture digest
are pinned in [Containerfile](Containerfile); this repository does not compile DeepSeek Harness.

[中文](README.zh.md)

## Included extensions

- `@ryubyte/dsh-a2a@0.3.1`: installed in the image, registered in the web profile, disabled by default.
- `dsh-tui@0.2.19`: standalone terminal client with isolated dependencies.
- Existing pinned bundles remain in the plugin payload.

**Known limitation:** TUI installs and its help/version commands work, but its legacy
`session.list` protocol is incompatible with this base (`session/list`, HTTP 404). Interactive
TUI support is not complete. A2A discovery, authentication and offline enablement are tested.

## Run

After the first successful main publication:

```sh
docker run -d --name dsh -p 127.0.0.1:3081:3081 \
  -v dsh-home:/home/dsh ghcr.io/huyyi/dsh-container:latest
docker exec dsh dsh-tui --version
```

Open http://127.0.0.1:3081 and configure your model. Enable A2A in Settings → Plugins, then
configure its peers or inbound service. The image contains no model credentials.
The existing Compose and multi-agent examples keep their own image references; they are not
automatically switched to this derivative.

## Build and publication

```sh
docker build -f Containerfile -t dsh-a2a-tui:local .
bash tests/extensions.sh dsh-a2a-tui:local
python3 -m unittest discover -s tests -p 'test_*.py'
python3 tests/validate-docs.py
```

Every main push builds, tests and publishes amd64/arm64 images, including documentation-only
updates. Tags use the pinned upstream version plus seven commit characters, for example
`dsh-v0.2.1-rc.2-cf05a2f`; successful publication also updates `latest`.
PRs never publish and skip image builds for Markdown/LICENSE-only changes. Unknown diffs build.
Manual dispatch validates only. Git tags and GitHub Releases are not created.

## Documentation

- [Build](docs/build.md)
- [Deployment](docs/deployment.md)
- [Security](docs/security.md)
- [Publication](docs/releasing.md)
- [Development](docs/development.md)
- [Extension details](docs/derived-image.md)

The upstream runtime, proxy and toolchain come from the base image. This repository maintains
only extension packaging, registration and verification; obsolete source-build adapters are removed.
