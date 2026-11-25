#!/usr/bin/env bash
# 使用已构建的目标架构镜像打包，并在断网容器中验证搬迁后的批量安装。
set -euo pipefail
image="${1:?Usage: package-plugins.sh IMAGE TAG OUTPUT}"
tag="${2:?missing tag}"
output="$(realpath -m "${3:?missing output directory}")"
repo="$(cd -- "$(dirname -- "$0")/.." && pwd)"
mkdir -p "$output"
stage="$(mktemp -d "$repo/.plugin-package.XXXXXX")"
trap 'docker run --rm --user 0 --entrypoint sh -v "$stage:/cleanup" "$image" -c "rm -rf /cleanup/*" >/dev/null 2>&1 || true; rm -rf "$stage"' EXIT
chmod 777 "$stage"
cache="${npm_config_cache:-$stage/npm-cache}"
if [ ! -d "$cache" ]; then
  mkdir -p "$cache"
  chmod 777 "$cache"
fi
docker run --rm -v "$cache:/npm-cache" -e npm_config_cache=/npm-cache --entrypoint bash -v "$repo:/src:ro" -v "$stage:/out" "$image" \
  -euc 'python3 /src/scripts/package-plugins.py /src/plugins/plugins.json /out/payload
         python3 /src/scripts/registry-plugins.py /out/payload /out/registry'
arch="$(docker run --rm --entrypoint uname "$image" -m)"
case "$arch" in x86_64) arch=amd64 ;; aarch64) arch=arm64 ;; *) exit 1 ;; esac
archive="dsh-plugins-$tag-linux-$arch.tgz"
registry_archive="dsh-plugin-registry-$tag-linux-$arch.tgz"
# GitHub runner 的 uid 不一定是 1000；确保宿主能读取容器生成的物料。
docker run --rm --user 0 --entrypoint chmod -v "$stage:/work" "$image" -R a+rX /work/payload /work/registry
docker run --rm --network none --entrypoint python3 -v "$stage/registry:/registry:ro" "$image" \
  /registry/import-registry.py --verify-only
tar -czf "$output/$registry_archive" -C "$stage/registry" .
docker run --rm --user 0 --entrypoint rm -v "$stage:/work" "$image" -rf /work/registry
tar -czf "$output/$archive" -C "$stage/payload" .
docker run --rm --user 0 --entrypoint rm -v "$stage:/work" "$image" -rf /work/payload
mkdir "$stage/relocated"
tar -xzf "$output/$archive" -C "$stage/relocated"
docker run --rm --user 0 --entrypoint chown -v "$stage/relocated:/work" "$image" -R 1000:1000 /work
docker run --rm --network none --entrypoint bash -v "$stage/relocated:/home/dsh/offline" "$image" -c '
  dsh plugin --profile web version-exemptions
  bash /home/dsh/offline/install.sh web
'
(cd "$output" && sha256sum "$archive" > "$archive.sha256"
 sha256sum "$registry_archive" > "$registry_archive.sha256")
