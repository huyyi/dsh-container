# Development

Maintain the offline plugin packer. Host images come from
[upstream](https://github.com/NIyueeE/dsh-container); no host image is built or
published here.

## Layout

- [plugin/](../plugin/): configuration, orchestration, runtime graph, verifier
  and plugin recipes.
- [tests/](../tests/): static checks and container integration tests.
- [examples/](../examples/): deployments and existing local demos.
- `offline-export/`: ignored local output.

Keep patches in recipes. Do not copy upstream runtime scripts. New plugins
need exact versions and explicit `pack_build_deps`. Only previously packaged
plugins belong in the initial migrated list. Downloads, caches and artifacts
must stay outside Git.

## Checks

```sh
just lint
bash tests/plugin-offline-repack.sh ghcr.io/niyueee/dsh-container:dsh-v0.2.2-rc.2
```

Checks include shellcheck, Node tests, Python unittest discovery, documentation,
README parity and Compose parsing. Integration tests download inputs in a
producer and validate in a separate offline consumer. No model requests are
sent. CI validates without publishing images or rewriting the plugin list.
