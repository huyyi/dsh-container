# dsh offline plugins

Repack versioned dsh plugins inside an existing host image, then install the
output directories manually on an intranet. Use the prebuilt image from
[NIyueeE/dsh-container](https://github.com/NIyueeE/dsh-container) directly.

English | [中文](README.zh.md)

## Pack

Docker is the only host requirement. Downloads, installs and builds run in
temporary containers without changing an active dsh profile.

```sh
bash plugin/offline_repack.sh \
  --image ghcr.io/niyueee/dsh-container:dsh-v0.2.2-rc.2 \
  --output ./offline-export
```

[plugin/plugins.json](plugin/plugins.json) records exact versions and
`pack_build_deps`. The initial list contains the previously packaged GenUI
0.16.0 with its intranet map recipe. Old image-preinstalled plugins are not
automatically added. `true` includes locked source and development dependencies
for offline rebuilding; `false` includes built code and runtime dependencies.

Each successful plugin produces a directory named
`plugin-name-plugin-version-dsh-host-version`:

```text
offline-export/
  changfenhuang--dsh-genui-0.16.0-dsh-0.2.2-rc.2/
    plugin/
    build/
    offline-manifest.json
    INSTALL.md
    GENUI.md
    genui-intranet.patch
```

Scoped names drop `@` and replace `/` with `--`. `build/` is included only when
requested. Artifacts and caches stay outside Git. Existing outputs are never
overwritten. Use different output parents for other architectures/host digests.

## Install on the intranet

Transfer the directory and the same host image. Mount `plugin/` outside
`/home/dsh`, for example at `/opt/offline-plugins/genui`, and keep it mounted.
Run inside the target container:

```sh
dsh plugin --profile web add link:/opt/offline-plugins/genui --offline --ignore-scripts
dsh --profile web --dump-config
dsh-restart
```

Newly added bundles may be enabled by dsh; existing disabled bundles need
enabling in Plugin Manager. Build dependencies increase size and build time.
External services and model endpoints remain separate requirements. Runtime
peers require the same host image digest and architecture.

## Verification

Every pack is checked in a separate `--network none` container using a relocated
read-only mount: hashes, links, offline installation, config resolution, entry
import and, when requested, offline rebuild. No model requests are sent.

```sh
bash tests/plugin-offline-repack.sh ghcr.io/niyueee/dsh-container:dsh-v0.2.2-rc.2
```

See [offline packaging](docs/offline-plugins.md), [development](docs/development.md),
[deployment](docs/deployment.md) and [security](docs/security.md). The independent
TUI client is no longer bundled; installation did not establish RPC compatibility.

## License

[MIT](LICENSE)
