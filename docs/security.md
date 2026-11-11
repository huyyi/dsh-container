# Security

The upstream proxy supplies an authenticated dsh session to anyone who can
reach it. Keep 3081 on host loopback by default; broader access needs basic auth,
TLS and trusted networking. Never publish internal 3080. Consult the
[upstream guide](https://github.com/NIyueeE/dsh-container/blob/main/docs/security.md)
for the exact host version's behavior.

Plugins execute with the runtime user's permissions. Review source and pinned
versions. SHA-256 checks establish integrity, not trust in plugin code.
Registry lifecycle scripts are disabled; configured source builds execute their
build command. Consumers verify packages with networking disabled. External
services and runtime privileges remain separate concerns.

Keep credentials, profiles and runtime data outside plugin source and Git.
Never commit generated archives or dependency caches. Keep plugin mounts outside
`/home/dsh`. No optional SSH server is configured. Installing the independent TUI
client does not establish its RPC compatibility with the host.
