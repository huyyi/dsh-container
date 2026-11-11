#!/usr/bin/env bash
# 与 CI 共用静态检查入口。
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."
for file in plugin/*.sh tests/*.sh; do bash -n "$file"; done
shellcheck plugin/*.sh tests/*.sh
while IFS= read -r file; do node --check "$file"; done < <(rg --files plugin tests -g '*.mjs')
node --test --test-isolation=none tests/*.test.mjs
python3 -m unittest discover -s tests -p 'test_*.py'
python3 tests/validate-docs.py
"${DOCKER:-docker}" compose -f examples/compose.yaml config --quiet
