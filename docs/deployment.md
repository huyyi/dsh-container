# Deployment

Use the [upstream image](https://github.com/NIyueeE/dsh-container) directly.
Examples pin `dsh-v0.2.2-rc.2`. Transfer the same image digest recorded in the
plugin manifest to the intranet.

```sh
docker compose -f examples/compose.yaml up -d
```

Open `http://127.0.0.1:3081/`. The proxy supplies an authenticated dsh session
to anyone who can reach it. Loopback is the default; broader exposure requires
basic auth, TLS and trusted networking. Never publish internal 3080. Optional
SSH is not configured. Persist `/home/dsh` and keep plugin payloads outside it.

## Mount and install

Add a read-only bind mount in [compose.yaml](../examples/compose.yaml):

```yaml
volumes:
  - dsh-home:/home/dsh
  - /absolute/path/to/package/plugin:/opt/offline-plugins/genui:ro
```

Recreate the container, then install manually:

```sh
docker exec dsh dsh plugin --profile web add link:/opt/offline-plugins/genui --offline --ignore-scripts
docker exec dsh dsh --profile web --dump-config
docker exec dsh dsh-restart
```

Keep the mount stable. `build/` is not needed for normal use. See
[offline packaging](offline-plugins.md) for compatibility and rebuilding.
Existing multi-agent demos retain their own deployment assumptions; install
their required A2A bundle manually before using them.

## Podman

[dsh.container](../examples/dsh.container) is a minimal Quadlet example.
Follow upstream documentation for optional nested containers and advanced
networking; those features are independent of plugin packaging.
