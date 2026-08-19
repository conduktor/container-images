# AGENTS.md

For AI coding agents (Claude Code, Copilot Chat, Cursor, Aider, …) working in
this repo. Humans can read the [README](README.md) instead.

Two jobs only: save you checks you would otherwise redo from scratch, and keep
you out of the traps that *recur*. So:

- **If the code already says it, it is not here.** Read the config, the script
  header, or the workflow — those are the source of truth and they cannot drift
  from themselves. A trap we hit once, fixed, and explained in the file it
  affects is not a rule.
- **Anything that could go stale is written as a command, not as a claim.**
  Verify, don't trust this file.

## What this repo is

Apko-built base and public container images for Conduktor products. Four ship
from here — `base-os`, `base-jre-25`, `base-monitoring` (Prometheus + Cortex
forks + patched supervisord, no JVM) and `debug` (the customer-facing sidecar).
[`images/images.json`](images/images.json) is the inventory: `dir`, published
`name`, and `dockerhub` when an image also mirrors to Docker Hub. Every image is
signed keyless with cosign, ships an apko-emitted SPDX SBOM attested with
cosign, and carries a SLSA build-provenance attestation.

Each image directory holds its own `apko.yaml`, `README.md` and any
`melange*.yaml`; each of those files explains itself in its header, including
how to bump what it pins.

## Verify, don't assume

Wolfi package names, tool subcommands and what a package actually installs are
all things that change under you. Run the check:

| To find out | Run |
|---|---|
| whether a Wolfi package exists, and its real name | `docker run --rm cgr.dev/chainguard/wolfi-base sh -c 'apk update >/dev/null && apk search -e <name>'` |
| whether that package gives you the *command* you wanted | `docker run --rm <image> command -v <tool>` |
| what subcommands a tool has (there is no `apko lint`) | `apko --help`, `melange --help` |
| whether an `apko.yaml` is valid | `apko show-config images/<dir>/apko.yaml >/dev/null` |
| what would actually be installed, resolved | `apko show-packages images/<dir>/apko.yaml` |
| what a melange config declares | `melange package-version images/<dir>/<cfg>.yaml` |
| which sources are pinned + prefetchable for an image | `scripts/melange-sources.sh <dir>` |
| what CI will build, and on which runners | `scripts/build-matrix.sh [subset]` |
| everything, before pushing | `make lint && make test && make precommit-run` |

Package names differ from Debian/Ubuntu more often than you would guess
(`ldap-utils`, `kcat`, `nss-tools`, `pgcli`, `postgresql-client` are all wrong
here), and some tools simply are not packaged. Never write a package name you
have not searched for. The names already in the `apko.yaml` files were verified
this way; each carries a `# why` comment, and yours must too.

Resolving a GitHub Action tag to a commit SHA needs two hops for annotated tags,
because `.object.sha` is then the *tag object* and `uses:` needs a commit:

```sh
resolve_action_sha() {
  read -r type sha < <(gh api "repos/$1/git/refs/tags/$2" -q '"\(.object.type) \(.object.sha)"')
  [ "${type}" = "tag" ] && sha="$(gh api "repos/$1/git/tags/${sha}" -q .object.sha)"
  echo "${sha}"
}
resolve_action_sha actions/upload-artifact v7.0.1
```

## Constraints the code cannot state

Everything below is either a prohibition (the pattern is absent, so nothing in
the repo hints at it) or a contract with something outside this repo.

### Registry and secrets

- **Never add a cloud-credential or private-registry login step.** This repo is
  public and forkable, and a run must not depend on anything outside it being
  reachable. Consumers *pull* from `ghcr.io`; this repo pushes nowhere else.
- The Docker Hub token is the only registry secret, and it is scoped to
  **write on `conduktor/conduktor-debug` only**. Do not widen its scope, reuse it
  elsewhere, or reach for `secrets: inherit` — `nightly.yml` names the secrets it
  passes so a called workflow never receives more than it needs.
- **Mirror inside the single `apko publish` call**, both refs passed as
  arguments, then sign per registry. A later `cosign copy` or registry
  replication hop can drop the cosign accessories (`sha256-<digest>.sig` /
  `.att`) and silently break the `cosign verify` snippet customers follow in the
  README.
- `pr.yml` stays push-free and signing-free. Fork PRs get no secrets, and
  nothing here may use `pull_request_target`.

### Freshness — the reason the nightly exists

A Wolfi update must reach our images within 24h *even though no file here
changed*, which holds only while every run resolves against the live index. A
frozen nightly still looks healthy (green runs, moving tags, new digests), so
[`test-nightly-freshness.sh`](.github/scripts/tests/test-nightly-freshness.sh)
enforces this instead of review.

- **Never `actions/cache` the go-apk cache directory**, never `apko --offline`,
  never an `apko lock` file. Each turns later builds into a replay of the day
  the cache was filled. GitHub runners starting empty is *why* the nightly is
  fresh.
- **Never cache the built `.apk`s in the nightly.** `prometheus-cdk` and
  `cortex-cdk` bake the Go toolchain and every module into the binary, which is
  what Grype matches CVEs against, and no key you can compute sees a `go-1.26`
  bump in Wolfi. On PR runs it is defensible — gate it on `publish == false` and
  extend the freshness test to assert that gate.
- Content-addressed caches are fine and already in use: melange's
  `sha256:<hash>` source cache, plus `gomodcache`, `npm` and the `gocache` the
  Go recipes export. They cannot serve anything but what was asked for.

### Downstream contracts

- **UID/GID 10001** in all four images, and the consumer resolves it
  *numerically* — `USER 10001`, supervisord's `user=%(ENV_CDK_USER_UID)s`. That
  is why `base-monitoring` did not keep the Ubuntu-era `conduktor-platform`
  name. If you ever find a consumer resolving the account by name, fix the
  consumer or change all four images, not one.
- The debug image also ships a legacy `gateway` user at 1001. Check the product
  Helm charts before removing it.
- **Base images stay root** — no `run-as` — so downstream builds can
  chown/chmod; the consumer sets `USER 10001` in its final layer. The debug
  image stays root so `tcpdump`/`strace` work ad-hoc.
- `latest` and `nightly` move on every run. Downstream pins `YYYY.MM.DD` or
  `git-<sha>`.

### Licences of what we redistribute

These images are published publicly, so every melange package must ship the
licences of what it installs — Apache-2.0 s4(d) obliges us to carry the upstream
NOTICE, BSD/MIT to carry the copyright text. Nothing fails on its own when a
licence is missing, which is why this is a rule rather than a check.

- **Never install third-party code without checking its licence and shipping
  it.** Install the upstream `LICENSE`/`NOTICE` in the recipe *and* assert they
  exist there, so a version bump that moves them fails the build instead of
  publishing unlicensed. See `melange-kafka-tools.yaml` and `melange-cortex.yaml`.
- Statically linked and bundled dependencies count: `cortex-cdk` ships
  `licenses/` collected from `vendor/`, `prometheus-cdk` ships
  `npm_licenses.tar.bz2` for the JS compiled into its binary.
- **If a recipe patches upstream source, check whether the licence obliges a
  modification notice** — supervisor's clause 4 does, so
  `melange-supervisor.yaml` prepends one to each file it `sed`s, carrying a
  `patch-date` that must not become a build timestamp.
- `copyright.license` must match what the upstream file says, not what the
  project is known for. Check it, don't assume: `head -3 <src>/LICENSE`.
- When the source archive carries licences broader than the subset we install,
  say so in a provenance note rather than shipping the broader licence — copying
  it in would misstate our own terms (`melange-kafka-tools.yaml`).
- Wolfi packages listed in an `apko.yaml` carry their own metadata and need
  nothing extra; this rule is about what *we* build and install.

### CI shape

- **One build definition.** [`build.yml`](.github/workflows/build.yml) is called
  by both `nightly.yml` (`publish: true`) and `pr.yml` (`publish: false`). Do
  not inline a simplified build into the PR again: that is what left the risky
  machinery (artifact merge, index re-signing, `@local` resolution across jobs)
  running only after merge, on a schedule, unwatched.
- **Runner labels stay GitHub-hosted.** No self-hosted or third-party pool, for
  the same reason as the credential rule above.
- **Emit a narrower matrix instead of filtering downstream.** Do not add
  per-step `if:` guards to skip images (that once needed the same condition on
  16 steps), and do not glob for melange configs inside a workflow `run:` step —
  `build-matrix.sh` owns both, so the two copies cannot drift.
- **If a CVE gate is ever added, gate on Grype**, never Trivy alone: Trivy
  attributes melange-built files to an APK with no advisories and reports 0
  where `trivy rootfs` on the same binary reports findings.
- Keep the CVE comment out of the scan matrix (it would post once per image),
  and do not hand a marketplace action `pull-requests: write` on a public repo.

## Conventions when editing

- Every package line in an `apko.yaml` carries a trailing `# why` — the config
  is the contract with downstream product Dockerfiles.
- `melange*.yaml` is matched by **glob** everywhere, never by the literal name
  `melange.yaml` (`base-monitoring` has three configs and no plain one). Adding
  a config or a `cdk-*` tool therefore needs no wiring, and tests assert the
  globs stay globs.
- `package.version` in a melange config is asserted against what the built
  binary reports. Keep them equal or the SBOM — and the CVE matching that reads
  it — describes the wrong version.
- Signing keys are ephemeral and gitignored. Never commit one or wire up a
  persistent one; a key only has to satisfy apk's index check within one build.
- SBOMs land next to `apko.yaml` via `--sbom-path .`; the Makefile, workflows
  and `.gitignore` all expect that flat layout.
- Non-trivial `run:` logic belongs in a script with a test, not inline in YAML —
  inline shell cannot be unit-tested and is nearly invisible to shellcheck.
  `scripts/` is for anything a human may run, `.github/scripts/` for CI-only,
  and a script with exactly one consumer lives beside its action. Nothing
  executable sits at the repo root; `make <target>` delegates.
- Tests live next to what they test and `make test` *discovers* them by `find`,
  so a new `tests/` directory cannot be silently left out.
- **CI lints via `pre-commit`, not `make lint`**, so linter versions are pinned
  by `.pre-commit-config.yaml`. The runner's shellcheck is older than the pinned
  one and they disagree, so if CI reports a finding you cannot reproduce, run
  `make precommit-run`.
- In the `cdk-*` debug tools: derive paths from the target with `cdk_target_env`
  (a chart overriding `CDK_VOLUME_DIR` must still work), and put everything you
  print through `cdk_maybe_redact` — that output lands in support tickets, and
  `scripts/tests/test-cdk-tools.sh` asserts both directions.

## Common tasks

### Add a package to an image
1. Search for it (see the table above) — do not guess the name.
2. Add it to the right section of `apko.yaml` with a `# why` comment.
3. `make build IMAGE=<image>` to prove it resolves, then
   `make scan IMAGE=<image>` for the CVE delta.

### Add a new image
1. Create `images/<dir>/apko.yaml` (copy the closest existing one), plus a
   `README.md` and any `melange*.yaml`.
2. Add one entry to `images/images.json` — `dockerhub` only if it must mirror
   there. Do not hardcode the image list anywhere else.
3. Add a row to the README's images + badges tables.

`make test` asserts the manifest and `images/*/` stay in sync, so a directory
added without a manifest entry fails the PR rather than never being built.

### Bump apko / melange / cosign in CI
`APKO_VERSION` and `MELANGE_VERSION` live in `build.yml` only; `MELANGE_VERSION`
has to agree between the job that builds the APKs and the one that re-indexes
them. Update `flake.nix` to match so `nix develop` does not drift, then open a
PR — it runs the same `build.yml` the nightly will.

Cosign is pinned transitively by the `sigstore/cosign-installer` SHA. Do not add
a `cosign-release:` input, and note that installing any cosign 3.x needs
installer v4+ (v3.x fetches a `.sig` asset that no longer exists — it shows up
as HTTP 22/404 in `Install cosign`).

### Debug a failed nightly
- `apko publish` failed → usually a Wolfi package rename (search for it) or a
  keyring URL change. If only one arch failed to resolve `@local`, the real
  failure is that arch's `apks-<image>-<arch>` job.
- index signing failed → an `apks` job produced nothing for some arch. Fix that
  job; do not work around it by publishing a single arch.
- `cosign sign/attest` failed → OIDC. Check `id-token: write` and that the
  workflow ref still matches the identity regex in the README's verify snippet.
- `publish-badges` failed → it pushes to the orphan `badges` branch, so `main`'s
  protection cannot block it. If that branch is itself protected, drop the
  protection: it is state-only and the workflow is its only writer.

## Before pushing

```sh
make lint            # yamllint + actionlint + apko show-config + shellcheck
make test            # fixture tests (also asserts images.json is in sync)
make precommit-run   # all 12 pre-commit hooks
make build IMAGE=<changed image>   # for any apko.yaml change
```

`make build` is host-arch only, on purpose: the foreign arch runs the melange
pipeline under qemu, which is slow for `kafka-tools` and far worse for
`base-monitoring`, which compiles Prometheus and Cortex. The nightly produces
multi-arch on one native runner per arch. To reproduce that locally before a
risky packaging change, `make build IMAGE=debug ARCHES=x86_64,aarch64`. To
rehearse the *assembly* step instead, drop each arch's `.apk` files into
`images/<image>/packages/<arch>/` and run `scripts/melange-index.sh <image>`
before `apko build`.

## Where to look for context you don't have

- Wolfi package index: <https://packages.wolfi.dev/os/>
- Cosign keyless identity: `https://github.com/conduktor/container-images/.github/workflows/nightly.yml@refs/heads/<branch>`,
  issuer `https://token.actions.githubusercontent.com`
- Anything about *why a specific pin, patch or package is what it is*: that
  file's own header comment.
