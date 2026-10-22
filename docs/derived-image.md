# Derived image: A2A and TUI

The root `Containerfile` extends the published upstream image, pinned to both tag and multi-arch
digest. It inherits the toolchain, UID 1000, proxy and healthcheck (Debian 13 in this published base).
This base does not include the optional SSH server or plugin seeder described by the older
source-build documentation. A small wrapper runs this repository's plugin seeder, then executes
the unmodified upstream entrypoint. SSH is not added by this derivative.
It does not compile Harness or overwrite the upstream runtime. Local changes to runtime scripts
are therefore not incorporated into this derived image; update the base to obtain runtime fixes.

`@ryubyte/dsh-a2a@0.3.1` joins the existing locked payload in `/opt/dsh-plugins`. The inherited
entrypoint wrapper registers it in the web profile as installed but disabled. Enable it in Settings →
Plugins, then configure peers or the inbound service in the plugin's settings. No listener or
credentials are automatically configured. Existing user-installed plugin copies remain untouched.

`dsh-tui@0.2.19` is an independent client with its own locked dependencies in `/opt/dsh-tui`,
and an executable at `/usr/local/bin/dsh-tui`. Its React dependencies are isolated from web bundles.
Neither payload lives in `/home/dsh`, so binding a data directory cannot hide the installed code.

**Known TUI compatibility limitation:** `dsh-tui@0.2.19` installs and its `--version`/`--help`
commands work, but connecting to this pinned host fails with `HTTP 404 from session.list`.
The client uses dot-separated RPC methods and a legacy envelope; this host uses slash-separated
methods. Setting `DSH_URL` does not resolve that protocol mismatch. Interactive/model use is not
supported by this tested combination. No third-party compatibility shim is included; select a
compatible client release or explicitly plan a protocol adaptation before relying on the TUI.

```sh
docker build -f Containerfile -t dsh-a2a-tui:local .
bash tests/extensions.sh dsh-a2a-tui:local
docker run -d --name dsh-demo -p 127.0.0.1:3081:3081 dsh-a2a-tui:local
docker exec dsh-demo dsh-tui --version
```

Configure a model in the web UI before requesting inference. TUI defaults upstream to port 3080;
use port 3081 here for the proxy-managed session. With proxy basic auth enabled, arrange supported
client authentication rather than disabling authentication or exposing the internal service.
Tests cover bundle discovery and TUI installation/CLI startup, not successful TUI connection,
model inference or interactive terminal rendering. The base image's security limitations still
apply; keep the UI private.

Both dependency lockfiles are committed. `BASE_IMAGE` overrides the complete base reference;
`DSH_TAG`, `RUST_TOOLCHAIN` and `UV_VERSION` no longer select builds in this fork. The inherited
`provenance.json` describes the base; `extensions.json` and OCI labels describe this derived layer.
The Image workflow reads the pinned reference directly from Containerfile, checks health,
proxy authentication, A2A and the added client on both architectures. Every main push publishes
the version-plus-commit image tag and latest. PRs and manual runs never publish.
See [Publication](releasing.md). Old source-build and release-preparation code has been removed.
