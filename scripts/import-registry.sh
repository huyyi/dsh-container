#!/usr/bin/env bash
# 使用 npm 已配置的凭据，将原始包导入显式指定的内部 registry。
set -euo pipefail
exec python3 "$(cd -- "$(dirname -- "$0")" && pwd)/import-registry.py" "$@"
