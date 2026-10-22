# Security

Reaching proxy port 3081 grants a fully authenticated dsh session. Keep host publishing on
loopback unless you explicitly configure access control. Set both DSH_PROXY_USER and
DSH_PROXY_PASSWORD for proxy basic auth; use TLS for remote access.

A2A bearer auth protects its protocol endpoint, not the entire dsh UI. For remote A2A,
restrict a dedicated reverse proxy to the exact /a2a and /.well-known/agent-card.json paths.
Basic and bearer auth both use Authorization; do not require both on one endpoint without
an explicit routing/authentication design. Never publish internal dsh port 3080.

The runtime user has passwordless sudo in the inherited development image; it is not a strong
agent isolation boundary. Protect the home directory, which holds credentials, sessions and
generated documents. Never commit demo data or secrets, and back it up before migration.

The image contains no provider secrets. Model requests send data to the configured provider;
do not describe the container as preventing all outbound data. Review inherited upstream
telemetry and provider behavior when deploying. A2A is preinstalled but disabled by default.
