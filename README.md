# Conduktor container images

Public base and debug container images for [Conduktor](https://conduktor.io) products, published nightly with fresh packages updates.
Every image use [apko](https://github.com/chainguard-dev/apko) builds,
is signed keyless with [cosign](https://github.com/sigstore/cosign),
ships with an SPDX SBOM attached as a Sigstore attestation,
and carries a [SLSA build-provenance](https://slsa.dev) attestation.

| Image | Purpose | Reference |
|-------|---------|-----------|
| [`base-os`](images/base-os/apko.yaml) | Minimal Wolfi (glibc) OS layer + `conduktor` UID/GID 10001 account. No language runtime. | `ghcr.io/conduktor/base-os:latest` |
| [`base-jre-25`](images/base-jre-25/apko.yaml) | `base-os` + OpenJDK 25 JRE + GNU userland. Source for Conduktor Console and Gateway images. | `ghcr.io/conduktor/base-jre-25:latest` |
| [`base-monitoring`](images/base-monitoring/apko.yaml) | Conduktor's Prometheus + Cortex builds and a patched `supervisord`, no JVM. Source for the Console monitoring image. | `ghcr.io/conduktor/base-monitoring:latest` |
| [`conduktor-debug`](images/debug/apko.yaml) | Sidecar debug toolkit: network / TLS / LDAP / Kafka / JVM tools. Deploy alongside a running Conduktor pod. | `conduktor/conduktor-debug:latest` (Docker Hub)<br>`ghcr.io/conduktor/conduktor-debug:latest` |

Multi-arch: `linux/amd64` + `linux/arm64` in a single OCI index per tag.

`conduktor-debug` is published to **both Docker Hub and GHCR** in the same
build, so the two references resolve to the same digest and either one
verifies with the commands below. Conduktor docs and Helm charts reference the
Docker Hub name. The base images are GHCR-only.

## Vulnerability status

Nightly scans of each `:latest` image, refreshed on every push.

Each badge reads `<n>C / <n>H / <n>M / <n>L` — findings at critical, high,
medium and low severity. **Click one for the full listing**: every finding with
its CVE ID, package, installed version and fix, refreshed by the same run.

<!--
Each badge is a shields.io endpoint pointing at a JSON file the nightly
workflow refreshes on the dedicated `badges` branch of this repo, and links to
the Markdown report the same run writes beside it. No external gist / PAT
needed. Both come from .github/scripts/cve-publish.sh, which shares its counting
and its Trivy/Grype normalisation with the PR comment — see
.github/scripts/cve-lib.sh.
-->

| Image | Trivy | Grype |
|-------|-------|-------|
| `base-os` | [![trivy](https://img.shields.io/endpoint?url=https://raw.githubusercontent.com/conduktor/container-images/badges/base-os-trivy.json)](../../blob/badges/base-os-trivy.md) | [![grype](https://img.shields.io/endpoint?url=https://raw.githubusercontent.com/conduktor/container-images/badges/base-os-grype.json)](../../blob/badges/base-os-grype.md) |
| `base-jre-25` | [![trivy](https://img.shields.io/endpoint?url=https://raw.githubusercontent.com/conduktor/container-images/badges/base-jre-25-trivy.json)](../../blob/badges/base-jre-25-trivy.md) | [![grype](https://img.shields.io/endpoint?url=https://raw.githubusercontent.com/conduktor/container-images/badges/base-jre-25-grype.json)](../../blob/badges/base-jre-25-grype.md) |
| `base-monitoring` | [![trivy](https://img.shields.io/endpoint?url=https://raw.githubusercontent.com/conduktor/container-images/badges/base-monitoring-trivy.json)](../../blob/badges/base-monitoring-trivy.md) | [![grype](https://img.shields.io/endpoint?url=https://raw.githubusercontent.com/conduktor/container-images/badges/base-monitoring-grype.json)](../../blob/badges/base-monitoring-grype.md) |
| `conduktor-debug` | [![trivy](https://img.shields.io/endpoint?url=https://raw.githubusercontent.com/conduktor/container-images/badges/conduktor-debug-trivy.json)](../../blob/badges/conduktor-debug-trivy.md) | [![grype](https://img.shields.io/endpoint?url=https://raw.githubusercontent.com/conduktor/container-images/badges/conduktor-debug-grype.json)](../../blob/badges/conduktor-debug-grype.md) |

Trivy runs with `--ignore-unfixed`, so it lists only what a rebuild can clear.
Grype includes unfixed findings and every severity down to negligible. The two
disagreeing is expected; that is why both are here.

Pull requests get the same per-severity table as a comment, from the same
counting code, so a PR and a badge never report different numbers.

The raw scan JSON and SBOMs are attached as workflow artifacts on each
[nightly run](../../actions/workflows/nightly.yml) (30-day retention).

## Pull

```sh
docker pull ghcr.io/conduktor/base-jre-25:latest
# pin to an immutable tag in production:
docker pull ghcr.io/conduktor/base-jre-25:2026.07.31
docker pull ghcr.io/conduktor/base-jre-25:git-2f3fd50

# the debug sidecar is on Docker Hub as well (same digest):
docker pull conduktor/conduktor-debug:latest
```

Available tag streams per image:

| Tag | Meaning |
|-----|---------|
| `latest` | Most recent successful nightly. Moves. |
| `nightly` | Alias of `latest`. Moves. |
| `YYYY.MM.DD` | Immutable build for that UTC date. |
| `git-<short-sha>` | Immutable build from that commit. |

## Verify signature + SBOM + provenance

All three attestations are keyless — they are bound to the GitHub Actions
workflow that produced the image, not to a private key. To trust an image
you assert *who* built it, not that a secret was known.

The identity is [`build.yml`](.github/workflows/build.yml), not `nightly.yml`:
Fulcio's SAN names the workflow containing the signing job, not the one that
called it. Only a publishing run on `main` can hold it — `pr.yml` never signs.

```sh
IMAGE=ghcr.io/conduktor/base-jre-25:latest
# ...or the Docker Hub reference for the debug sidecar — same identity, because
# each registry's copy is signed natively by the same workflow:
# IMAGE=docker.io/conduktor/conduktor-debug:latest

# 1. Signature (cosign keyless, Fulcio issuer)
cosign verify \
  --certificate-identity-regexp='^https://github\.com/conduktor/container-images/\.github/workflows/build\.yml@refs/heads/main$' \
  --certificate-oidc-issuer='https://token.actions.githubusercontent.com' \
  "${IMAGE}"

# 2. SPDX SBOM attestation
cosign verify-attestation \
  --type=spdxjson \
  --certificate-identity-regexp='^https://github\.com/conduktor/container-images/\.github/workflows/build\.yml@refs/heads/main$' \
  --certificate-oidc-issuer='https://token.actions.githubusercontent.com' \
  "${IMAGE}" \
  | jq -r '.payload' | base64 -d | jq '.predicate' > sbom.spdx.json

# 3. SLSA build-provenance (verifiable with gh CLI too)
gh attestation verify "oci://${IMAGE}" --repo conduktor/container-images

# 4. apko lock — the exact package set this digest was built from
cosign verify-attestation \
  --type=https://conduktor.io/apko-lock/v1 \
  --certificate-identity-regexp='^https://github\.com/conduktor/container-images/\.github/workflows/build\.yml@refs/heads/main$' \
  --certificate-oidc-issuer='https://token.actions.githubusercontent.com' \
  "${IMAGE}" \
  | jq -r '.payload' | base64 -d | jq '.predicate' > apko.lock.json
```

Scan the extracted SBOM against your own policy:

```sh
grype sbom:./sbom.spdx.json
trivy sbom ./sbom.spdx.json
```

### Diff two builds

The lock is `apko lock` output: every package with its version, architecture and
`.apk` URL, as resolved when the image was built. Extract it for two tags to see
what a nightly changed — usually the answer to "why did the CVE count move":

```sh
jq -r '.contents.packages[] | "\(.architecture) \(.name) \(.version)"' \
  apko.lock.json | sort > new.txt
# ...same for the older tag, then:
diff old.txt new.txt
```

Diff the package list, not the whole file: for `conduktor-debug` and
`base-monitoring` the lock also embeds a per-build melange signing key. And the
`.apk` URLs stop resolving once Wolfi drops those versions, so pin a digest to
keep an exact image — the lock is a record, not a rebuild input.

## Use as a base image

```dockerfile
# Console / Gateway
FROM ghcr.io/conduktor/base-jre-25:latest
COPY --chown=10001:10001 --chmod=0755 ./bin /opt/conduktor/bin
USER 10001
CMD ["/opt/conduktor/bin/run.sh"]
```

```dockerfile
# Console monitoring — prometheus, promtool and cortex are already on PATH,
# and supervisord is pre-patched for arbitrary UIDs (see the image README).
FROM ghcr.io/conduktor/base-monitoring:latest
COPY --chown=0:0 --chmod=0755 ./monitoring-helper /opt/conduktor/bin/
USER 10001
CMD ["/opt/conduktor/scripts/run.sh"]
```

The image default user stays `root` so downstream `RUN` steps can
`chown`/`chmod` freely; switch to `USER 10001` in your final layer.

## Deploy the debug image as a sidecar

`conduktor-debug` is meant to run next to a live Conduktor JVM pod, sharing
its process namespace so the JDK tools can attach to the target process.
Sketch for a Helm values override:

```yaml
podSpec:
  shareProcessNamespace: true
  containers:
    - name: debug
      image: conduktor/conduktor-debug:latest
      command: ["sleep", "infinity"]
      securityContext:
        runAsUser: 10001    # same UID as the target JVM — see below
        runAsGroup: 10001
```

Then `kubectl exec -it <pod> -c debug -- bash` and run `jcmd <pid>
GC.heap_info`, `jstack <pid>`, `openssl s_client -connect kafka:9093`,
`ldapsearch -H ldaps://ldap:636`, `kcat -b kafka:9092 -L`, …

### Privileges the JDK tools actually need

`jcmd`, `jstack`, `jmap`, `jinfo` and `jfr` use the HotSpot *attach* mechanism,
a unix socket whose peer credentials the target JVM checks: it accepts the
attach when the caller is root **or** when the caller's effective UID and GID
both match its own. Since every Conduktor image runs as `conduktor` 10001,
running the sidecar as `runAsUser: 10001` is enough — **no root, and no
`SYS_PTRACE`**, which the attach path never uses.

Add capabilities only for the tools that genuinely need them:

| Tool | Needs |
|------|-------|
| `jcmd` / `jstack` / `jmap` / `jinfo` / `jfr` | matching UID/GID (or root) — nothing else |
| `strace`, `jstack -F`, `jmap -F`, `jhsdb` | `SYS_PTRACE` (these really do `ptrace(2)`) |
| `tcpdump` | `NET_RAW` |

The image itself has no `run-as` and so defaults to root, which keeps every
tool working out of the box for ad-hoc use. Override it with `runAsUser` in
production namespaces where root sidecars are disallowed.

Gateway pods predating the UID change run as `1001`; the image ships that
legacy `gateway` account too, so use `runAsUser: 1001` to match those.

## Build locally

Requires Docker (for the apko container fallback and to `docker load` the
result). A native `apko` binary is used if it's on `PATH`.

```sh
./scripts/image-build.sh base-os
./scripts/image-build.sh base-jre-25
./scripts/image-build.sh debug
# or via Make:
make build IMAGE=base-jre-25
make build-all
```

Then `docker run --rm conduktor/base-jre-25:local java -version`.

### Dev environment

The repo ships a Nix [`flake.nix`](flake.nix) that pins every tool the
Makefile and CI call — `apko`, `cosign`, `trivy`, `grype`, `syft`, `crane`,
`yamllint`, `actionlint`, `shellcheck`, `gitleaks`, `pre-commit`, `jq`, `yq`.

```sh
nix develop           # drop into the dev shell
make help             # list every dev target
make precommit-install  # install the git hooks
```

Non-Nix users can install the same tools via their OS package manager; the
Makefile only cares that they're on `PATH`.

#### Without Nix on your machine

[`.devcontainer/`](.devcontainer/devcontainer.json) defines a dev container that
runs the *same* flake inside a Debian container, so tool versions stay identical
either way — the container installs Nix and a nested Docker daemon and nothing
else. Open the repo in VS Code and choose **Reopen in Container**, in a
Codespace, or from the CLI:

```sh
npx @devcontainers/cli up --workspace-folder .
npx @devcontainers/cli exec --workspace-folder . make lint
```

`make build IMAGE=<image>` works because the Docker daemon is nested rather than
the host's — melange bind-mounts its workspace into the containers it launches,
and those paths only exist inside this container. The Nix store and `~/.cache`
are named volumes, so rebuilding the container re-downloads neither the dev
shell nor melange's sources.

## Contributing

Pull requests are welcome. The [PR workflow](.github/workflows/pr.yml)
builds every affected image on `amd64` and runs Trivy + Grype against the
tarball. Scanning is **report-only**: the counts land in the job summary and a
sticky PR comment, and no severity blocks the merge. Before pushing, run
`make lint` and
`make precommit-run` — the same checks run in CI, and `gitleaks` will catch
accidentally-staged secrets.

- Package additions or removals go in `images/<image>/apko.yaml`. Explain
  *why* the package is needed in a trailing comment — the config is the
  contract with downstream product Dockerfiles.
- Wolfi package names sometimes differ from Debian/Ubuntu (`openldap-clients`
  vs `ldap-utils`, `nmap-ncat` vs `netcat-openbsd`, etc.). Search
  [packages.wolfi.dev](https://packages.wolfi.dev/os/) before adding.
- The nightly workflow assumes GHCR pushes are enabled via the built-in
  `GITHUB_TOKEN` (`packages: write`). No extra secrets are required for
  signing, provenance, or the CVE badges — the badges are plain JSON files,
  and the reports they link to plain Markdown, that the `publish-badges` job
  commits to the dedicated `badges` branch after every nightly (main is
  protected).
- Every third-party GitHub Action is pinned to a commit SHA; Dependabot
  ([`.github/dependabot.yml`](.github/dependabot.yml)) opens PRs to bump
  them weekly.

## License

[Apache-2.0](LICENSE).
