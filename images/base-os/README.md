# base-os

Minimal Wolfi (glibc) OS-only image with the `conduktor` UID/GID 10001
account, a CA trust bundle, tzdata and `busybox` — nothing else. No
language runtime and no package manager: apko does not lay one down.

- **Image:** `ghcr.io/conduktor/base-os`
- **Source:** [`apko.yaml`](apko.yaml)
- **Architectures:** `linux/amd64`, `linux/arm64` (single OCI index per tag)
- **Default user:** `root` (downstream `RUN` steps need chown/chmod; switch
  to `USER 10001` in your final layer)
- **Size:** ~10 MB compressed

## When to use it

- As `FROM` for a distroless-style Go / Rust / native binary image.
- As a tiny baseline for one-shot job containers or init containers.
- Anywhere you'd otherwise reach for `alpine` or `gcr.io/distroless/static`
  but want the Conduktor UID convention and Wolfi's CVE hygiene.

If you need Java, use [`base-jre-25`](../base-jre-25/) instead.

## Pull

```sh
docker pull ghcr.io/conduktor/base-os:latest
# or pin to an immutable tag in production:
docker pull ghcr.io/conduktor/base-os:2026.07.31
docker pull ghcr.io/conduktor/base-os:git-<short-sha>
```

Available tags: `latest`, `nightly` (both move), `YYYY.MM.DD`, `git-<sha>`
(both immutable). Full tagging model is documented in the [repo
README](../../README.md#pull).

## Verify signature + SBOM + provenance

Same recipe as every image in this repo — see
[Verify signature + SBOM + provenance](../../README.md#verify-signature--sbom--provenance)
in the top-level README. TL;DR:

```sh
IMAGE=ghcr.io/conduktor/base-os:latest
cosign verify \
  --certificate-identity-regexp='^https://github\.com/conduktor/container-images/\.github/workflows/nightly\.yml@refs/heads/.+$' \
  --certificate-oidc-issuer='https://token.actions.githubusercontent.com' \
  "${IMAGE}"
```

## Use as a FROM base

```dockerfile
FROM ghcr.io/conduktor/base-os:latest
COPY --chown=10001:10001 --chmod=0755 ./bin/myapp /usr/local/bin/myapp
USER 10001
ENTRYPOINT ["/usr/local/bin/myapp"]
```

## Contents

The full package list lives in [`apko.yaml`](apko.yaml). Notable choices:

- `wolfi-baselayout` — `/etc/passwd`, `/etc/group`, `/etc/nsswitch.conf`
- `glibc` — includes the NSS resolver modules so DNS works
- `ca-certificates-bundle` — system trust store
- `busybox` — provides `/bin/sh` and a core set of userland utilities
- `tzdata` — zoneinfo for `TZ`

## Contributing

Package additions go in [`apko.yaml`](apko.yaml) with a trailing `# why`
comment. Verify the Wolfi package name first (see the [agent
guide](../../AGENTS.md#1-use-apko-in-priority-verify-wolfi-packages-before-adding)),
then `make build IMAGE=base-os && make scan IMAGE=base-os` locally before
opening a PR.
