#!/usr/bin/env bash
# 解压后可从任意工作目录批量安装，目录必须保留在持久卷里。
set -euo pipefail
exec python3 "$(cd -- "$(dirname -- "$0")" && pwd)/install-plugins.py" "$@"
