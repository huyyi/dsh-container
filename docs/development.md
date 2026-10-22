# Development

This repository maintains a derivative, not upstream Harness source. Keep changes scoped to
extension packaging, registration, CI and deployment documentation.

```sh
bash -n container/*.sh tests/*.sh
shellcheck container/*.sh tests/*.sh
python3 -m unittest discover -s tests -p 'test_*.py'
python3 tests/validate-docs.py
docker compose -f examples/compose.yaml config --quiet
```

After runtime or dependency changes, build Containerfile and run tests/extensions.sh against
that image. Tests do not call model providers. Both architectures run the same smoke test in CI.
TUI CLI startup is tested, but the documented RPC incompatibility remains unresolved.

README.md is the English source of truth; README.zh.md mirrors headings, links and code blocks.
Code comments are Chinese. Never include host data, credentials or local demo output in commits.
