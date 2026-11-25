#!/usr/bin/env bash
# 兼容 profile 在 plugin 之前的写法，其余参数原样交给上游 CLI。
set -euo pipefail
cli=/opt/deepseek-harness/apps/cli/lib/bin.js
if [ "$#" -ge 3 ] && [ "$1" = --profile ] && [ "$3" = plugin ]; then
  profile="$2"
  shift 3
  exec "$cli" plugin --profile "$profile" "$@"
fi
if [ "$#" -ge 2 ] && [[ "$1" == --profile=* ]] && [ "$2" = plugin ]; then
  profile="${1#--profile=}"
  shift 2
  exec "$cli" plugin --profile "$profile" "$@"
fi
exec "$cli" "$@"
