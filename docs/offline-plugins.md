# Offline plugin packaging

## Configuration

[plugins.json](../plugin/plugins.json) is the list to pack. Keep versions exact.
The initial entry is the previously packaged GenUI 0.16.0. The old image payload
list is not evidence of offline packaging. Packing never rewrites this file.

```json
{
  "schema_version": 1,
  "plugins": [
    {
      "name": "@ryubyte/dsh-a2a",
      "version": "0.3.1",
      "pack_build_deps": false
    }
  ]
}
```

This is a runtime-only example, not an entry in the initial list. Registry
packages must already contain built entry points. Lifecycle scripts and
automatic peer installation are disabled.

Source builds require `source.url` (an HTTPS tarball with one top-level directory)
and `source.sha256`. Source must match the configured name/version and contain
`pnpm-lock.yaml` and an `npm run build` command. Frozen dependencies are installed
inside the supplied image. `pack_build_deps=true` requires these source inputs;
missing source cannot be reconstructed from a published runtime package.

`recipe: "genui-intranet"` is restricted to GenUI 0.16.0. It applies the existing
map configuration patch and includes 38 pinned historical GeoJSON datasets with
notices. Its patch and instructions accompany the output. Build dependencies
are isolated from runtime dependencies to preserve host singletons.

## Command

```sh
bash plugin/offline_repack.sh \
  --image ghcr.io/niyueee/dsh-container:dsh-v0.2.2-rc.2 \
  --config plugin/plugins.json \
  --output offline-export \
  --only @changfenhuang/dsh-genui
```

`--image` is required. Other flags are optional. Use a fixed image tag or digest.
The script resolves it to an immutable local image ID, reads `dsh --version`
inside it and uses that ID for producer and consumer. It pulls the image only
when absent locally. `DOCKER` selects a Docker-compatible CLI. The output parent
must be writable by the caller; Docker copies container-owned files out after
successful validation. The host needs Bash, Docker and standard Linux utilities.

Temporary containers and volumes are removed on success or failure. Downloads,
installs and builds stay in containers. A separate consumer gets only the output
at a new read-only mount path, with `--network none` and no producer cache.
No active user profile is modified.

## Output and compatibility

Directories use `plugin-name-version-dsh-host-version`. Scoped names drop `@`
and replace `/` with `--`; collisions are rejected. `plugin/` contains built code
and runtime dependencies. `pack_build_deps=true` adds `build/` with locked source
and development dependencies. System tools come from the host image.

`offline-manifest.json` records plugin configuration, actual dsh version, image
ID/repo digests, Node version, architecture, runtime dependency graph, host
dependency paths and file/link hashes for runtime and build trees.
`INSTALL.md` explains installation; the GenUI recipe adds `GENUI.md`.
Do not edit verified artifacts without repacking.

Use the same image digest and architecture in production. Different images with
the same dsh version are not interchangeable. Use separate output parents for
different architectures/digests. Native dependencies are architecture specific;
the tool does not cross-compile. Offline rebuilds need extra disk space and
memory. External executables, downloads and services require explicit recipe
support; validation fails if a rebuild still needs network access.

## Install and enable

Transfer the whole output directory and host image to the intranet. Mount
`plugin/` at a stable path outside `/home/dsh`. Run inside the target container:

```sh
dsh plugin --profile web add link:/opt/offline-plugins/genui --offline --ignore-scripts
dsh --profile web --dump-config
dsh-restart
```

The `link:` form preserves packaged dependencies. Keep the mount afterward.
New bundles may be enabled automatically; an existing disabled bundle needs
enabling in Plugin Manager. A2A is only installed by an explicit user action.
The packer does not call models or start external plugin services.

## Validation

The consumer checks host identity, file hashes/links, dependency versions,
offline installation, config resolution and entry-point import. With build
dependencies it copies `build/` into a writable temporary directory and runs
`npm run build`, without networking or a dependency install. GenUI also checks
rebuilt map engines and the 38-map index. Existing output directories are
rejected; failed validation exports nothing.

The [integration test](../tests/plugin-offline-repack.sh) checks GenUI's real
host asset routes, both `pack_build_deps` values and overwrite rejection.
No model requests are sent. Actual intranet tile requests and browser rendering
require a tile service and are outside this test.

Pass an existing output parent as the test's second argument to revalidate a
transferred package, rebuild it offline and check the real host routes without
downloading the GenUI source again.
