#!/usr/bin/env bash
# 使用真实宿主验证两种产物、覆盖保护和 GenUI 资源路由。
# shellcheck disable=SC2016
set -euo pipefail
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
DOCKER="${DOCKER:-docker}"
image="${1:-ghcr.io/niyueee/dsh-container:dsh-v0.2.2-rc.2}"
existing="${2:-}"
mkdir -p "$root/offline-export"
temporary="$(mktemp -d "$root/offline-export/.test-XXXXXXXX")"
cid=""
cleanup() {
  if [[ -n "$cid" ]]; then "$DOCKER" rm -f "$cid" >/dev/null; fi
  rm -rf -- "$temporary"
}
trap cleanup EXIT
if [[ -n "$existing" ]]; then
  output="$(cd -- "$existing" && pwd)"
  image_metadata="$("$DOCKER" image inspect --format '{{json .}}' "$image")"
  "$DOCKER" run --rm --network none --entrypoint node \
    -e "REPACK_IMAGE_METADATA=$image_metadata" -e DSH_HOME=/tmp/offline-home \
    -v "$output:/received:ro" -v "$root/plugin:/tools:ro" \
    "$image" /tools/verify.mjs /received
else
  output="$temporary/output"
  bash "$root/plugin/offline_repack.sh" --image "$image" --output "$output"
fi
packages=("$output"/changfenhuang--dsh-genui-0.16.0-dsh-*)
[[ ${#packages[@]} == 1 && -d "${packages[0]}" ]]
package="${packages[0]}"
if bash "$root/plugin/offline_repack.sh" --image "$image" --output "$output" >"$temporary/collision.log" 2>&1; then
  echo 'Existing output was accepted' >&2; exit 1
fi
rg -q 'Output already exists' "$temporary/collision.log"
echo 'PASS: existing output rejected before downloads'
# 仅作为测试输入，不改动默认清单。
cat >"$temporary/plugins.json" <<'JSON'
{"schema_version":1,"plugins":[{"name":"@ryubyte/dsh-a2a","version":"0.3.1","pack_build_deps":false}]}
JSON
bash "$root/plugin/offline_repack.sh" --image "$image" --config "$temporary/plugins.json" --output "$temporary/runtime"
cid="$("$DOCKER" run -d --network none --entrypoint bash \
  -v "$package/plugin:/opt/offline-plugins/genui:ro" "$image" -ec '
  dsh plugin --profile web add link:/opt/offline-plugins/genui --offline --ignore-scripts
  cat > /home/dsh/.dsh/profiles/web/cordis.patch.yml <<"YAML"
- id: genui
  name: "@changfenhuang/dsh-genui"
  config:
    mapTiles:
      url: "http://tiles.internal/{z}/{x}/{y}.png"
      scheme: tms
      maxZoom: 18
      attribution: "Internal map service"
YAML
  exec /usr/local/bin/entrypoint
')"
if ! "$DOCKER" exec "$cid" node --input-type=module -e '
  import assert from "node:assert/strict";
  import fs from "node:fs";
  assert.deepEqual(fs.readdirSync("/sys/class/net"), ["lo"]);
  const base = "http://127.0.0.1:3081/plugins/@changfenhuang/dsh-genui/assets/";
  let config;
  for (let i = 0; i < 45; i++) {
    try {
      const response = await fetch(base + "map-config.json", {signal: AbortSignal.timeout(1000)});
      if (response.ok) { config = await response.json(); break; }
    } catch {}
    await new Promise(resolve => setTimeout(resolve, 1000));
  }
  assert(config, "GenUI did not register its configuration route");
  const source = config.style.sources["genui-intranet"];
  assert.deepEqual(source.tiles, ["http://tiles.internal/{z}/{x}/{y}.png"]);
  assert.equal(source.scheme, "tms");
  assert.equal(source.maxzoom, 18);
  assert.equal((await fetch(base + "maplibre.js")).status, 200);
  const engine = await fetch(base + "echarts-full.js");
  assert.equal(engine.status, 200);
  assert((await engine.text()).includes("FeatureCollection"));
  console.log("PASS: real offline host load, intranet map configuration and packaged engine routes");
'; then
  "$DOCKER" logs "$cid" >&2
  exit 1
fi
echo 'PASS: both pack_build_deps modes, overwrite rejection and real host load; no model requests'
echo 'SKIP: real intranet tile requests and browser rendering (no tile service supplied)'
