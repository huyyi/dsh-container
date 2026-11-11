# OpenViking integration

OpenViking is not preinstalled. To package it, add the required exact version of
`@openviking/dsh-memory-plugin` to [plugins.json](../plugin/plugins.json), with
`pack_build_deps=false` for a published runtime bundle. Pack using the target
host, transfer the output and install `plugin/` with the documented `link:` form.

Follow the [official guide](https://docs.openviking.ai/zh/agent-integrations/17-dsh)
for server compatibility and runtime configuration. The packer does not install
or start an OpenViking server or Python services. Keep credentials outside Git.
Enable only for data permitted on your server: memory features can send
conversation and tool content to that server.

Offline validation checks installation, loading and config resolution. It does
not prove compatibility with a live OpenViking server, send model requests or
modify an existing deployment.
