#!/usr/bin/env bash
# 基础镜像没有 seeder；注册镜像载荷后由原入口继续准备环境。
set -euo pipefail
if ! /usr/local/bin/dsh-plugins-seed; then
  echo '[derived-entrypoint] plugin registration failed' >&2
  exit 1
fi
exec /usr/local/bin/entrypoint "$@"
