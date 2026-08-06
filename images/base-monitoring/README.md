# base-monitoring

Base image for the Conduktor Console **monitoring** service: Conduktor's
Prometheus and Cortex builds plus a `supervisord` patched to tolerate
arbitrary UIDs. No JVM — monitoring is not a Java service.

- **Image:** `ghcr.io/conduktor/base-monitoring`
- **Source:** [`apko.yaml`](apko.yaml) + the three
  [`melange-*.yaml`](melange-prometheus.yaml) recipes next to it
- **Architectures:** `linux/amd64`, `linux/arm64` (single OCI index per tag)
- **Default user:** `root` (the downstream build needs chown/chmod on
  `/var/conduktor`; it switches to `USER 10001` in its final layer)
- **Size:** ~220 MB uncompressed, most of it the Prometheus web assets and
  the two Go binaries

If you need Java, use [`base-jre-25`](../base-jre-25/) instead.

## What's in it, and where

| Path | Package | Contents |
|------|---------|----------|
| `/opt/monitoring/prometheus/` | `prometheus-cdk` | `prometheus`, `promtool` |
| `/opt/monitoring/cortex/` | `cortex-cdk` | `cortex` plus `migrations/` (also exported as `MIGRATIONS_DIR`) |
| `/usr/bin/supervisord`, `/usr/bin/supervisorctl` | `supervisor-cdk` | supervisor, pre-patched (see below) |

Both `/opt/monitoring/prometheus` and `/opt/monitoring/cortex` are on `PATH`,
so the supervisor `conf.d` programs can invoke `prometheus` / `cortex` bare.

> **Prometheus ships without its web UI.** Console runs Prometheus as an
> internal TSDB behind Cortex and only ever calls `/-/healthy` and the HTTP
> API, so the React UI is not built in: `/`, `/graph` and `/query` return 404.
> `/api/v1/*`, `/metrics`, `/-/healthy` and `/-/ready` behave normally, so
> `kubectl port-forward` debugging works — through the API, not the browser:
>
> ```sh
> curl -s localhost:9090/api/v1/query --data-urlencode 'query=up' | jq
> curl -s localhost:9090/api/v1/status/tsdb | jq
> ```
>
> This drops ~86s per architecture from every nightly and takes the entire npm
> dependency tree out of a build we sign and attest. It saves only ~4 MB —
> the package is two ~190 MB Go binaries, not assets. The rationale and the
> one-step revert are in
> [`melange-prometheus.yaml`](melange-prometheus.yaml)'s header.

Alongside those: `bash` + the GNU userland, `curl`, `openssl`, `envsubst`
(config templating), `logrotate`, `netcat-openbsd`, `procps`, `less` and
`nano`. The full list, with a `# why` per line, is in [`apko.yaml`](apko.yaml).

## Why three melange packages instead of Wolfi packages

- **`prometheus-cdk` / `cortex-cdk`** — Console runs Conduktor forks
  ([conduktor/prometheus](https://github.com/conduktor/prometheus),
  [conduktor/cortex](https://github.com/conduktor/cortex)) whose changes are not
  upstream, and Cortex is not in Wolfi at all. Each recipe pins a fork tag *and*
  its `expected-commit`, so a moved tag fails the build instead of silently
  changing what ships.
- **`supervisor-cdk`** — supervisord calls `pwd.getpwuid(uid)` on the UID it is
  told to run as, which raises `KeyError` under OpenShift's arbitrary UIDs. The
  Ubuntu base `sed`'d the installed `site-packages` at image build time; apko has
  no `RUN` phase, so the same substitution is applied at *package* build time and
  the shipped `options.py` / `datatypes.py` are already patched. A build-time
  guardrail fails the package if the patch stops applying.

```sh
# the patch, from outside the container:
docker run --rm ghcr.io/conduktor/base-monitoring:latest bash -c \
  'grep -c "None, None, uid, 0" /usr/lib/python3*/site-packages/supervisor/options.py'
# and the behaviour it buys — a UID with no /etc/passwd entry:
docker run --rm --user 31337:31337 ghcr.io/conduktor/base-monitoring:latest \
  supervisord --version
```

## Pull

```sh
docker pull ghcr.io/conduktor/base-monitoring:latest
# or pin to an immutable tag in production:
docker pull ghcr.io/conduktor/base-monitoring:2026.08.05
docker pull ghcr.io/conduktor/base-monitoring:git-<short-sha>
```

Available tags: `latest`, `nightly` (both move), `YYYY.MM.DD`, `git-<sha>`
(both immutable). Full tagging model is in the [repo
README](../../README.md#pull).

## Verify signature + SBOM + provenance

Same recipe as every image in this repo — see
[Verify signature + SBOM + provenance](../../README.md#verify-signature--sbom--provenance)
in the top-level README. TL;DR:

```sh
IMAGE=ghcr.io/conduktor/base-monitoring:latest
cosign verify \
  --certificate-identity-regexp='^https://github\.com/conduktor/container-images/\.github/workflows/nightly\.yml@refs/heads/.+$' \
  --certificate-oidc-issuer='https://token.actions.githubusercontent.com' \
  "${IMAGE}"
```

## Use as a FROM base

```dockerfile
FROM ghcr.io/conduktor/base-monitoring:latest
COPY fs/03-monitoring /
COPY --chown=0:0 --chmod=0755 ./monitoring-helper /opt/conduktor/bin/
USER 10001
CMD ["/opt/conduktor/scripts/run.sh"]
```

The account is `conduktor` at **UID/GID 10001** — the repo-wide convention
([AGENTS.md rule 7](../../AGENTS.md#7-account-convention)). The Ubuntu
monitoring base called it `conduktor-platform`; only the numeric IDs are
load-bearing (`USER 10001`, supervisord's `user=%(ENV_CDK_USER_UID)s`), so a
consumer that never resolves the account by name needs no change.

## Building it locally

```sh
make build IMAGE=base-monitoring   # host arch only
make scan  IMAGE=base-monitoring
```

That runs the three melange recipes first (from-source Go + npm builds, so
budget ~10 minutes cold, and expect the Prometheus source download to
dominate a cold cache), then apko. Building the foreign arch locally runs
those compiles under qemu — don't; the nightly builds each arch on a native
runner instead ([AGENTS.md rule 13](../../AGENTS.md#13-long-builds-fan-out-to-native-runners-per-arch)).

## Contributing

Package additions go in [`apko.yaml`](apko.yaml) with a trailing `# why`
comment. Verify the Wolfi package name first (see the [agent
guide](../../AGENTS.md#1-use-apko-in-priority-verify-wolfi-packages-before-adding)).
Bumping a fork or supervisor version is documented in the header of each
`melange-*.yaml`. Then `make build IMAGE=base-monitoring && make scan
IMAGE=base-monitoring` before opening a PR.
