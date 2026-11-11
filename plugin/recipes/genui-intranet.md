# GenUI 0.16.0 intranet offline package

See `INSTALL.md` and `offline-manifest.json` for the exact host image and CPU
architecture. Use the same image digest on the disconnected machine.

- `plugin/`: patched built plugin, all lazy engines, 38 GeoJSON maps and runtime dependencies.
- `build/` (when requested): patched release source, frozen pnpm lockfile, full development dependencies and built output. System build tools come from the host image.
- `offline-manifest.json`: runtime file hashes and required host packages.
- `offline-manifest.json` also records source/build file hashes and the build environment.
- `genui-intranet.patch`: local changes against the upstream release.

## Install

Transfer the output directory, then mount `plugin/` outside `/home/dsh`, for example at
`/opt/offline-plugins/genui`. Keep the mount after installation. Stop existing
GenUI instances before replacing their files.

```sh
dsh plugin --profile web add link:/opt/offline-plugins/genui --offline --ignore-scripts
dsh --profile web --dump-config
dsh-restart
```

An existing disabled bundle must be enabled in Plugin Manager. The build directory
does not need to be mounted for normal use. Runtime peers reuse the specified host;
do not substitute dependencies from the development tree into the runtime package.

## Intranet raster basemap

Set the `genui` plugin row in the web profile composition:

```yaml
- id: genui
  name: '@changfenhuang/dsh-genui'
  config:
    mapTiles:
      url: 'http://tiles.internal/{z}/{x}/{y}.png'
      scheme: xyz
      tileSize: 256
      minZoom: 0
      maxZoom: 18
      attribution: 'Internal map service'
```

Restart dsh and reload the browser after changing configuration. `scheme: tms`
supports inverted Y tiles. Only HTTP(S) and root-relative raster tile URLs are
supported. The default without `mapTiles` remains the upstream blank map.
The browser must reach the tile service and the service must allow the web UI
origin through CORS. HTTPS pages need HTTPS tile URLs. The plugin does not proxy
tiles or weaken the host policy. Do not put credentials in the URL.

The node half serves the reviewed style from its existing authenticated asset
route. The client calls `setGenuiMapConfig({style})` as described by upstream
`docs/map.md`. This is trusted host configuration, separate from model fences.
Standalone HTML exports keep the upstream blank basemap and do not include the
intranet configuration. Vector tiles, WMS and WMTS capabilities documents are not
supported by this raster template configuration.

## ECharts maps

The full lazy ECharts engine registers all packaged maps, with no external
GeoJSON requests. Use the `echart` node with raw `option`, for example:

```json
{"type":"echart","option":{"series":[{"type":"map","map":"china","data":[]}]}}
```

Names include `world`/`世界`, `china`/`中国`, province file names such as
`guangdong` and Chinese short/full names such as `广东`/`广东省`. See
`plugin/assets/maps/index.json` for the complete map and alias list. Raw GeoJSON
files, LICENSE and NOTICE are under `plugin/assets/maps/`.
These are historical ECharts 4.9.0 datasets, not current administrative boundary
data. City/district maps beyond the bundled datasets require additional data.

## Rebuild without network

When `pack_build_deps` is true, mount a writable copy of `build/` at `/work` in
the same image and run:

```sh
docker run --rm --network none --entrypoint bash \
  -v "$PWD/build:/work" -w /work \
  ghcr.io/niyueee/dsh-container:dsh-v0.2.2-rc.2 \
  -lc 'npm run build'
```

No dependency install is necessary. `npm run build` uses the packaged local
TypeScript and tsdown executables; invoking pnpm may download its pinned manager
unless it is already cached. Rebuilding changes only the development tree; use
the repository packaging script again to update the runtime package.

## Validation scope

Verify offline rebuild and plugin load on the specified image. Real intranet tile
service requests and basemap rendering are intentionally untested because no
test service was supplied. No model requests are needed or sent.
