#!/usr/bin/env bash
# 只在指定宿主容器中安装和构建；验证成功后才导出目录。
set -euo pipefail
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
DOCKER="${DOCKER:-docker}"
image=""
config="$root/plugins.json"
output="$root/../offline-export"
only=""
usage() {
  echo 'Usage: bash plugin/offline_repack.sh --image IMAGE [--config FILE] [--output DIRECTORY] [--only PACKAGE]'
}
while (($#)); do
  case "$1" in
    --image|--config|--output|--only)
      (($# >= 2)) || { usage >&2; exit 2; }
      case "$1" in
        --image) image="$2" ;;
        --config) config="$2" ;;
        --output) output="$2" ;;
        --only) only="$2" ;;
      esac
      shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
done
[[ -n "$image" && -f "$config" ]] || { usage >&2; exit 2; }
config="$(cd -- "$(dirname -- "$config")" && pwd)/$(basename -- "$config")"
mkdir -p "$output"
output="$(cd -- "$output" && pwd)"
if ! "$DOCKER" image inspect "$image" >/dev/null 2>&1; then
  "$DOCKER" pull "$image"
fi
# 固定到实际镜像 ID，防止两次容器启动之间标签发生变化。
image_id="$("$DOCKER" image inspect --format '{{.Id}}' "$image")"
image_metadata="$("$DOCKER" image inspect --format '{{json .}}' "$image_id")"
plan="$("$DOCKER" run --rm -i --network none --entrypoint node \
  -e "REPACK_IMAGE=$image" -e "REPACK_IMAGE_METADATA=$image_metadata" \
  -v "$root:/tools:ro" "$image_id" /tools/preflight.mjs - "$only" <"$config")"
while IFS= read -r name; do
  [[ ! -e "$output/$name" && ! -L "$output/$name" ]] || {
    echo "Output already exists: $output/$name" >&2; exit 1;
  }
done <<<"$plan"
volume="dsh-repack-$$-$RANDOM"
producer=""
staging=""
cleanup() {
  if [[ -n "$producer" ]]; then "$DOCKER" rm -f "$producer" >/dev/null; fi
  "$DOCKER" volume rm "$volume" >/dev/null
  if [[ -n "$staging" ]]; then rm -rf -- "$staging"; fi
}
"$DOCKER" volume create "$volume" >/dev/null
trap cleanup EXIT
"$DOCKER" run --rm --network none --user 0 --entrypoint chown \
  -v "$volume:/work" "$image_id" 1000:1000 /work
producer="$("$DOCKER" create -i --entrypoint node \
  -e "REPACK_IMAGE=$image" -e "REPACK_IMAGE_METADATA=$image_metadata" \
  -v "$volume:/work" -v "$root:/tools:ro" \
  "$image_id" /tools/offline_repack.mjs - /work/output "$only")"
"$DOCKER" start -a -i "$producer" <"$config"
[[ "$("$DOCKER" inspect --format '{{.State.ExitCode}}' "$producer")" == 0 ]] || exit 1
# 消费端换挂载路径且禁网，不带生产端安装缓存。
"$DOCKER" run --rm --network none --entrypoint node \
  -e "REPACK_IMAGE_METADATA=$image_metadata" -e DSH_HOME=/tmp/offline-home \
  -v "$volume:/transfer:ro" -v "$root:/tools:ro" \
  "$image_id" /tools/verify.mjs /transfer/output
staging="$(mktemp -d "$output/.repack-XXXXXXXX")"
"$DOCKER" cp "$producer:/work/output/." "$staging/"
# 先检查全部冲突，避免批量导出时覆盖已有插件。
for directory in "$staging"/*; do
  [[ ! -e "$output/$(basename -- "$directory")" && ! -L "$output/$(basename -- "$directory")" ]] || {
    echo "Output already exists: $output/$(basename -- "$directory")" >&2; exit 1;
  }
done
for directory in "$staging"/*; do
  mv -T -n -- "$directory" "$output/$(basename -- "$directory")"
  [[ ! -e "$directory" ]] || { echo 'Output collision during export' >&2; exit 1; }
  echo "Created $output/$(basename -- "$directory")"
done
