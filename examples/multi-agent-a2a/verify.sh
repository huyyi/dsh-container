#!/usr/bin/env bash
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")"
# 从 A 容器访问 B，验证真实的跨实例网络路径。
docker compose exec -T agent-a node --input-type=module - "$@" < verify.mjs
