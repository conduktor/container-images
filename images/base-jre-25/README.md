# base-jre-25

Minimal Wolfi (glibc) base image with **OpenJDK 25 JRE** and the GNU
userland Conduktor product startup scripts depend on. This is the `FROM`
base for [Conduktor Console](https://conduktor.io/console) and
[Conduktor Gateway](https://conduktor.io/gateway) product images.

- **Image:** `ghcr.io/conduktor/base-jre-25`
- **Source:** [`apko.yaml`](apko.yaml)
- **Architectures:** `linux/amd64`, `linux/arm64` (single OCI index per tag)
- **JAVA_HOME:** `/usr/lib/jvm/java-25-openjdk`
- **Default user:** `root` (product build layers chown/chmod; switch to
  `USER 10001` at the end of your Dockerfile)
- **Size:** ~180 MB compressed

## Contract with downstream product Dockerfiles

Anything a Conduktor product Dockerfile expects at its `FROM` layer:

- glibc + headless OpenJDK 25 JRE, CA trust wired into the JVM truststore
  (via `java-cacerts`)
- `bash` + GNU userland (`coreutils`, `sed`, `gawk`, `findutils`, `grep`)
  — startup scripts use bash-only features and rely on GNU behavior
- `/bin/sh` (busybox) so Docker's default `RUN` shell works during a
  downstream build
- `curl` (healthcheck), `openssl` (TLS tooling), tzdata, working NSS/DNS
- `conduktor` UID/GID 10001 account exists but is not the default user

If you change any of the above, coordinate with the product Dockerfiles —
Console + Gateway both assume this contract.

## Pull

```sh
docker pull ghcr.io/conduktor/base-jre-25:latest
docker run --rm ghcr.io/conduktor/base-jre-25:latest java -version
# Immutable tag for production:
docker pull ghcr.io/conduktor/base-jre-25:2026.07.31
```

Tagging model: `latest`, `nightly`, `YYYY.MM.DD`, `git-<sha>` — see the
[repo README](../../README.md#pull) for the full model.

## Verify signature + SBOM + provenance

Same recipe as the rest of the repo — see
[Verify signature + SBOM + provenance](../../README.md#verify-signature--sbom--provenance)
for the full cosign / gh-attestation commands.

## Use as a FROM base

```dockerfile
FROM ghcr.io/conduktor/base-jre-25:latest

# Layer the application in as the conduktor user
COPY --chown=10001:10001 --chmod=0755 ./bin /opt/conduktor/bin
COPY --chown=10001:10001 --chmod=0644 ./config /opt/conduktor/config

USER 10001
WORKDIR /opt/conduktor
ENTRYPOINT ["/opt/conduktor/bin/run.sh"]
```

The image default user stays `root` so build-time `RUN mkdir -p /var/…`
and `chown` steps just work. Switch to `USER 10001` in your final layer.

## Verify JVM layout on first build after a JDK bump

The `JAVA_HOME` path is asserted in the config. Confirm once and adjust
`apko.yaml` if the Wolfi layout ever changes:

```sh
docker run --rm ghcr.io/conduktor/base-jre-25:latest ls -d /usr/lib/jvm/*
docker run --rm ghcr.io/conduktor/base-jre-25:latest java -version
```

## Related

- [`base-os`](../base-os/) — same image, minus the JRE (~10 MB)
- [`debug`](../debug/) — sidecar debug image with the full JDK + tools

## Contributing

Package changes go in [`apko.yaml`](apko.yaml) with a trailing `# why`
comment. Verify Wolfi names first (see the [agent
guide](../../AGENTS.md#1-use-apko-in-priority-verify-wolfi-packages-before-adding)),
then `make build IMAGE=base-jre-25 && make scan IMAGE=base-jre-25` before
opening a PR.
