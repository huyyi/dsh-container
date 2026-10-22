# Build

The only base selection is the full tag-plus-digest reference in Containerfile.
Update both deliberately, then build and test; there is no source-tag compilation or CI variable override.

```sh
docker build -f Containerfile -t dsh-a2a-tui:local .
bash tests/extensions.sh dsh-a2a-tui:local
```

The base provides the runtime and toolchain. Extension code lives in /opt/dsh-plugins and
/opt/dsh-tui; /home/dsh contains data only. Dependency lockfiles are installed frozen, without
package lifecycle scripts. Build caches are not placed in the data home.

See [extension details](derived-image.md) for the installed versions and TUI compatibility limit.
