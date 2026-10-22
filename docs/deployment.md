# Deployment

Use ghcr.io/huyyi/dsh-container:latest after a successful main publication, or pin an immutable
version-and-commit image tag described in [Publication](releasing.md).

Publish 127.0.0.1:3081:3081 and persist /home/dsh. Host bind directories must be writable by
UID 1000. Each agent needs its own home; do not share agent workspaces for A2A transport.
Existing examples retain their own image references; choose the derivative explicitly.

The inherited proxy manages the browser session. Configure model credentials in the web UI,
enable A2A in Settings → Plugins, then configure discovery URLs and bearer tokens.
For separate hosts, use reachable advertised URLs and TLS or a trusted private network.

Use dsh-restart inside a running container to restart the inherited web service.
The pinned base does not include an SSH daemon. Nested Podman support depends on the base
and host permissions and is not guaranteed by this derivative.

See [Security](security.md) and [extension details](derived-image.md).
