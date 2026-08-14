# AGENTS.md

Instructions for AI coding agents (Claude Code, Copilot Chat, Cursor, Aider, …)
working in this repo. Human contributors can read the [README](README.md) for
the same background at a higher level.

## What this repo is

Apko-built base and public container images for Conduktor products. Four
images ship from here:

| Directory | Published tag | Purpose |
|-----------|---------------|---------|
| `images/base-os/` | `ghcr.io/conduktor/base-os` | Minimal Wolfi OS + `conduktor` UID 10001 account. No language runtime. |
| `images/base-jre-25/` | `ghcr.io/conduktor/base-jre-25` | OpenJDK 25 JRE base for Console + Gateway. |
| `images/base-monitoring/` | `ghcr.io/conduktor/base-monitoring` | Console monitoring base: Conduktor's Prometheus + Cortex forks and a patched supervisord. No JVM. Three melange packages, all built from source — see rule 13. |
| `images/debug/` | `ghcr.io/conduktor/conduktor-debug` + `docker.io/conduktor/conduktor-debug` | Debug sidecar (JDK-25 + network/TLS/LDAP/Kafka/JVM tooling). Customer-facing, so it is also on Docker Hub — see rule 8. |

Every image is signed keyless with cosign, ships an SPDX SBOM (apko-emitted,
attested with cosign), and carries a SLSA build-provenance attestation.

## Layout

```
.
├── images/
│   ├── images.json              # image inventory — single source of truth (rule 9)
│   ├── base-os/apko.yaml        # source of truth per image
│   ├── base-jre-25/apko.yaml
│   ├── base-monitoring/apko.yaml
│   └── debug/apko.yaml
├── scripts/                     # runnable by a human as well as CI (rule 12)
│   ├── image-build.sh           # local end-to-end image build (melange -> apko -> docker load)
│   ├── image-matrix.sh          # manifest -> image list (validates the dispatch subset)
│   ├── build-matrix.sh          # both CI matrices: images + per-(image,arch) APK jobs (rule 13)
│   ├── melange-build.sh         # local APK build; also called by scripts/image-build.sh
│   ├── melange-index.sh         # re-sign the APK index after a per-arch fan-out (rule 13)
│   ├── melange-sources.sh       # list/prefetch pinned sources; CI cache key + prefetch
│   └── tests/test-*.sh          # fixture tests for the above; `make test`
├── Makefile                     # dev targets: build / lint / test / scan / sbom / precommit-*
├── flake.nix                    # nix devShell with every tool pinned
├── .pre-commit-config.yaml
├── .yamllint.yaml
├── .github/
│   ├── workflows/build.yml      # reusable: the ONE build definition, `publish` on/off (rule 13)
│   ├── workflows/nightly.yml    # 04:00 UTC cron; calls build.yml with publish -> sign/attest, badges
│   ├── workflows/pr.yml         # lint + calls build.yml without publish; report-only (rule 11)
│   ├── scripts/                 # CI-only scripts — cve-*/scan-*, never run by hand (rule 12)
│   │   └── tests/test-*.sh      # their tests, also picked up by `make test`
│   ├── actions/setup-apko/      # local composite action: verified apko install (Sigstore-checked)
│   ├── actions/scan-image/      # local composite action: trivy + grype + job summary (rule 11)
│   ├── actions/pr-comment/      # local composite action: generic sticky PR comment
│   ├── dependabot.yml           # weekly bumps for GHA SHA pins
│   └── CODEOWNERS               # @conduktor/platform
└── README.md                    # user-facing docs (pull / verify / sidecar)
```

## Rules

### 1. Use apko in priority; verify Wolfi packages before adding

- Prefer apko over Dockerfile or melange. Only reach for melange if a needed
  binary isn't in Wolfi at all — **or** when the Wolfi package's dependencies
  cost more than they give (measure before claiming this). Six melange configs
  exist for those reasons; see rules 10 and 13 before adding another or
  "simplifying" one back to a Wolfi package:

  | Config | Package | Why not Wolfi |
  |--------|---------|---------------|
  | `debug/melange.yaml` | `conduktor-debug-scripts` | our own scripts, nothing to package |
  | `debug/melange-conduktor-ctl.yaml` | `conduktor-ctl` | `conduktor/ctl` is not in Wolfi |
  | `debug/melange-kafka-tools.yaml` | `kafka-tools` | `kafka-4.3` drags an unused second JVM; see below |
  | `base-monitoring/melange-prometheus.yaml` | `prometheus-cdk` | Console runs the `conduktor/prometheus` fork, not upstream |
  | `base-monitoring/melange-cortex.yaml` | `cortex-cdk` | Cortex isn't in Wolfi at all, and we run a fork |
  | `base-monitoring/melange-supervisor.yaml` | `supervisor-cdk` | needs the arbitrary-UID patch applied before packaging |
- **Never invent Wolfi package names.** Verify before editing an `apko.yaml`:
  ```sh
  docker run --rm cgr.dev/chainguard/wolfi-base sh -c 'apk update >/dev/null && apk search -e <name>'
  ```
- Known Wolfi name mismatches vs. Debian/Ubuntu (already burned once):

  | You might type | Actual Wolfi name |
  |----------------|-------------------|
  | `ldap-utils`, `openldap-clients` | `openldap-2.6-clients` |
  | `nmap-ncat`, `netcat-openbsd` | `netcat-openbsd` (nmap-ncat doesn't exist) |
  | `kcat` | `kafkacat` |
  | `nss-tools` | `libnss-tools` |
  | `pgcli` | `py3-pgcli` (a bare `apk search -e pgcli` finds nothing) |
  | `psql`, `postgresql-client` | `postgresql-17-client` (version is part of the name) |
  | `iotop`, `iotop-c` | *not packaged* — use `sysstat` (iostat/pidstat) |
  | `jattach` | *not packaged* — use full `openjdk-25` (has jstack/jmap/jcmd/jhsdb/jfr) instead of `openjdk-25-jre` |

- Every package line in `apko.yaml` gets a trailing `# why this is here`
  comment — the config is the contract with downstream product Dockerfiles.

### 2. `apko lint` doesn't exist

Use `apko show-config apko.yaml > /dev/null` to validate. It parses and
normalizes the config and fails on invalid schema/refs — functionally a
lint. This is what the Makefile, pre-commit hook, and PR workflow all use.

### 3. SBOMs land next to `apko.yaml`, not in a subdir

`apko build/publish --sbom-path .` puts `sbom-*.spdx.json` files directly in
`images/<image>/`. Do not `mkdir sbom` and use `--sbom-path ./sbom` — the
tooling (Makefile, workflows, `.gitignore`) all expect the flat layout.

### 4. Every third-party GitHub Action is SHA-pinned

Format:
```yaml
- uses: owner/repo@<40-char-SHA> # vX.Y.Z
```
Never pin to `@main`, `@master`, or a bare tag. Dependabot
([`.github/dependabot.yml`](.github/dependabot.yml)) opens weekly PRs to
rewrite both the SHA and the trailing version comment. If you add a new
action, resolve the SHA with:
```sh
# Dereference annotated tags: for those, .object.sha is the *tag object*, and
# `uses:` needs a commit SHA. Silently pinning a tag-object SHA gives a ref
# Actions cannot resolve — this has caught us out more than once.
resolve_action_sha() {
  read -r type sha < <(gh api "repos/$1/git/refs/tags/$2" -q '"\(.object.type) \(.object.sha)"')
  [ "${type}" = "tag" ] && sha="$(gh api "repos/$1/git/tags/${sha}" -q .object.sha)"
  echo "${sha}"
}
resolve_action_sha actions/upload-artifact v7.0.1
```

Note: `chainguard-dev/actions/setup-apko` does **not** exist upstream (that
path 404s). We ship our own port at
[`./.github/actions/setup-apko`](.github/actions/setup-apko/action.yml)
that resolves the release tag, verifies the archive's SHA-256 checksum,
verifies the checksums file's Sigstore signature (cosign keyless), and
asserts the installed binary reports the pinned tag + commit. Use
`uses: ./.github/actions/setup-apko` — do not add a third-party setup-apko.

### 5. Tool versions in CI are pinned too

`APKO_VERSION` and `MELANGE_VERSION` live in
[`build.yml`](.github/workflows/build.yml) only — it is the one workflow that
runs either tool, so there is no second copy to drift (rule 13). `APKO_VERSION`
is passed as `version` to the local setup-apko action. Cosign is pinned
transitively via the SHA of
`sigstore/cosign-installer` — do **not** add a `cosign-release:` input.
Since cosign 3.x the installer maintainers explicitly discourage
version-override there, and you must be on `cosign-installer v4+` to
install any `cosign v3.x` (v3.x of the installer downloads a `.sig` asset
that no longer exists in cosign v3 releases; you'll see HTTP 22/404 in
`Install cosign`). Bump the installer SHA + apko version together and
update the flake so `nix develop` matches.

### 6. Badges live on the `badges` branch, not on `main` or a gist

`<image>-{trivy,grype}.json` are shields.io endpoint JSON files that the
`publish-badges` job of the nightly workflow force-updates on a dedicated
orphan `badges` branch of this repo — README URLs point at
`raw.githubusercontent.com/.../badges/...`. That branch is state-only:
`publish-badges.sh` overwrites every file on each run, so a removed image
stops showing a stale badge, and there is no meaningful history to
preserve. Do not touch it by hand, and do not "restore" it onto `main`.
Do not add gist/PAT plumbing either — the branch is written with the
built-in `GITHUB_TOKEN` and needs no extra credential.

### 7. Account convention

- All four images ship the `conduktor` group + user at UID/GID 10001. The
  Ubuntu-era Console and monitoring bases named this account
  `conduktor-platform`; `base-monitoring` deliberately does not, because only
  the numeric IDs are load-bearing downstream (`USER 10001`, and supervisord's
  `user=%(ENV_CDK_USER_UID)s`). If you ever find a consumer that resolves the
  account *by name*, fix the consumer or change all four images — not one.
- The debug image *additionally* ships a legacy `gateway` user at UID/GID
  1001 (kept for compatibility with existing Gateway deployments). Do not
  remove it without checking product Helm charts.
- Base images default to `root` so downstream builds can chown/chmod their
  layers; downstream Dockerfiles must set `USER 10001` themselves. Do not
  add `run-as` at the base layer.
- The debug image also has no `run-as` (root), so `tcpdump`/`strace` work
  ad-hoc. `SYS_PTRACE` is **not** what makes `jcmd`/`jstack`/`jmap` work —
  see the gotcha below before touching those docs.

### 8. Registry topology — this repo pushes *out* only

This repo is public. It publishes to public registries and holds no
credential for any Conduktor-internal system. Trust flows inbound only.

| Target | Which images | Auth |
|--------|--------------|------|
| `ghcr.io/conduktor/*` | all three (canonical) | ephemeral `GITHUB_TOKEN` |
| `docker.io/conduktor/conduktor-debug` | debug only | `DOCKERHUB_USERNAME` + `DOCKERHUB_TOKEN` |

- **Never add a cloud-credential or private-registry login step to a workflow
  here** — no secret-manager fetch, no internal registry push. That would
  materialize a long-lived credential for internal infrastructure onto a
  runner in a publicly forkable repo, and it would make the daily base-image
  rebuild depend on that infrastructure being up. Internal mirrors consume
  these images by *pulling* from `ghcr.io`; they are never pushed to from
  here. Internal consumers should pin the immutable `YYYY.MM.DD` /
  `git-<sha>` tags rather than `latest`.
- The Docker Hub token is the only registry secret in the repo. It is an org
  access token scoped to **write on `conduktor/conduktor-debug` only**. Do
  not widen its scope and do not reuse it for other repositories.
- Mirroring happens *inside the single `apko publish` call* (both refs passed
  as arguments), not via a later `cosign copy` or registry-replication hop.
  One build, one digest in both registries, and `cosign sign`/`cosign attest`
  then run once per registry so each copy carries a natively-created
  signature. A replication hop instead risks dropping the cosign accessories
  (`sha256-<digest>.sig` / `.att`), which silently breaks the `cosign verify`
  snippet in the README for customers.
- `pr.yml` must stay push-free and signing-free. Fork PRs never get secrets,
  and nothing here may use `pull_request_target`.

### 9. `images/images.json` is the image inventory; logic lives in `scripts/`

The image list used to be duplicated in the `Makefile`, `scripts/image-build.sh`, the
nightly matrix and the `pr.yml` `all` JSON. It now lives once in
[`images/images.json`](images/images.json):

```json
{ "dir": "debug", "name": "conduktor-debug", "dockerhub": "docker.io/conduktor/conduktor-debug" }
```

`dir` is the directory under `images/`, `name` is the published image name,
`dockerhub` is optional. Do not re-hardcode the list anywhere.

- Both workflows resolve their matrices with `scripts/build-matrix.sh`, which
  wraps `scripts/image-matrix.sh` and enriches each entry with what is on disk:
  `melange` (boolean, for a workflow `if:`) and `configs` (the comma-separated
  `melange*.yaml` list for melange-build's `multi-config`). It also emits the
  per-`(image, arch)` APK matrix — see rule 13. **Do not glob for melange
  configs inside a workflow `run:` step**; that was the old pattern and the two
  copies were already drifting.
- **Do not add per-step `if:` guards to filter images** — that was the old
  pattern and it needed the same condition on 16 steps. Filter by emitting a
  narrower matrix instead.
- `scripts/image-matrix.sh` exits non-zero on an unknown name, so a typo'd
  `workflow_dispatch` input fails the run instead of quietly building nothing.
  `build-matrix.sh` inherits that, and additionally fails on an arch with no
  runner mapping.
- Non-trivial `run:` logic belongs in `scripts/` with a test in
  `scripts/tests/`, not inline in YAML — inline shell is invisible to
  shellcheck beyond actionlint's basic pass and cannot be unit-tested. The jq
  that computes CVE badge counts is the worked example (`.github/scripts/cve-badge.sh`).
- `make lint-shell` shellchecks every `*.sh` found in the repo, so new scripts
  are covered without registering them anywhere. `make test` runs every
  `scripts/tests/test-*.sh`. The `scripts` job in `pr.yml` runs both.

### 10. Debug-image support scripts: `images/debug/tools/`

The TSE-facing `cdk-*` commands live in `images/debug/tools/` and reach the
image through `images/debug/melange.yaml` as the `conduktor-debug-scripts` APK,
which apko pulls from a `@local ./packages` repository.

- **Adding a tool needs no wiring.** `melange.yaml` globs `tools/cdk-*` and
  `make lint-shell` / the pre-commit hook match `cdk-*` by name. A test asserts
  the glob is still there, so don't replace it with an explicit list.
- **Adding a package needs no wiring either.** Both workflows and
  `scripts/melange-build.sh` glob `images/<dir>/melange*.yaml`, so a new config
  file is picked up automatically (CI passes them via `multi-config`).
- **Do not replace `kafka-tools` with Wolfi's `kafka-4.3`.** It looks like a
  rule-1 improvement and is not. Measured: Wolfi's package is +336 MB because it
  depends on `openjdk-21-default-jvm`, while this image's `JAVA_HOME` points at
  java-25 and Kafka's scripts honour it — so that JVM installs and never runs.
  And it gives up nothing: Wolfi ships upstream's `libs/` verbatim (all 108 jars
  are the same set as `kafka_2.13-4.3.0.tgz`), so there are no patched
  dependencies to lose. Our package is +131 MB. If you re-litigate this, re-run
  the measurement rather than assuming.
- **`/usr/lib/kafka/bin` goes on `PATH`, not symlinked into `/usr/bin`.** Each
  Kafka script resolves `kafka-run-class.sh` and `libs/` from `$0`, so a symlink
  in `/usr/bin` makes it look for `/usr/libs`.
- **Third-party binaries are pinned by SHA-256 we control.** `conduktor/ctl`
  publishes only MD5 sums, which are an integrity check and not a security one,
  so `melange-conduktor-ctl.yaml` carries its own `expected-sha256` per arch and
  a smoke test asserting `conduktor version` matches. Bumping the version means
  replacing both hashes — the recipe is in that file's header. It repackages the
  released static binary rather than building from source on purpose: melange
  builds each arch in a sandbox of that arch, so a Go build would compile under
  qemu emulation for aarch64 on every nightly.
- **Derive paths from the target, never hardcode.** Use the `cdk_target_env`
  helper to read `/proc/<pid>/environ`; the Console defaults
  (`CDK_IN_CONF_FILE`, `CDK_APPS_CONF_DIR` = `${CDK_VOLUME_DIR}/configs`) are
  fallbacks only. A chart overriding `CDK_VOLUME_DIR` must still work.
- **Anything printed goes through `cdk_maybe_redact`.** This output lands in
  support tickets. `scripts/tests/test-cdk-tools.sh` asserts both directions —
  secrets masked, and `*_FILE`/`*_PATH` keys preserved. Add a case there when
  you touch the filter.
- **melange's source cache is READ-ONLY.** The `fetch` pipeline copies from
  `<cache>/sha256:<hash>` when it exists but never writes back, so
  `--cache-dir` on its own caches nothing. `scripts/melange-sources.sh`
  populates it, and is the single source for both the local build and the CI
  `actions/cache` key. Don't "simplify" it away — without it every build
  re-downloads `kafka_2.13-4.3.0.tgz`, which is 135 MB and only available from
  `archive.apache.org` (dlcdn and downloads 404 it) at ~250 KB/s: 12 minutes per
  arch. With the cache a rebuild is ~11s.
  Its listing output *is* the cache key, so it is sorted — glob order follows
  `LC_COLLATE` (`-` sorts before `.`, so `melange-ctl.yaml` precedes
  `melange.yaml`) and an unsorted list would produce different keys on different
  machines for identical inputs.
- **Signing keys are ephemeral and gitignored** (`images/*/melange.rsa*`,
  `images/*/packages/**`). Locally `scripts/melange-build.sh` runs
  `melange keygen` on demand; CI uses
  `chainguard-dev/actions/melange-build` with `sign-with-temporary-key: true`,
  plus one more throwaway key in the publish job (rule 13). Never commit a key
  or wire up a persistent one — a key only has to satisfy apk's index signature
  check inside a single build.
- `apko show-config` does not resolve repositories, so `make lint` passes on a
  fresh clone with no `packages/` present. Only `apko build`/`publish` needs the
  APK, which is why `scripts/image-build.sh` runs melange first when the image dir has any
  `melange*.yaml`. Match that by **glob, never by the literal name
  `melange.yaml`** — `base-monitoring` has three configs and no plain
  `melange.yaml`, and both `image-build.sh` and `melange-build.sh` used to skip it
  silently for exactly that reason.

### 11. Scanning lives in one action, and is report-only

Both workflows scan via [`./.github/actions/scan-image`](.github/actions/scan-image/action.yml).
Do not add a bare `trivy-action` or `anchore/scan-action` step to a workflow —
the two copies had already drifted (different severity lists, different
`ignore-unfixed`), which is why this exists.

- The action writes `trivy.json` + `grype.json` to the job's working directory
  and appends a Markdown table to `$GITHUB_STEP_SUMMARY`. Counting is
  `.github/scripts/cve-counts.sh`, shared with `cve-badge.sh`, so the PR summary
  and the README badge can't report different numbers for the same report.
- **`fail-on: none` on purpose.** A Trivy-based gate is blind to the packages we
  build with melange: Trivy attributes those files to an APK package and finds
  no advisories for it, so `trivy image` reports 0 while `trivy rootfs` on the
  same extracted binary reports the CVEs. Grype walks the filesystem and does
  see them. Measured on the debug image: Trivy 0 critical/0 high, Grype 0
  critical/20 high, same image.
- So if you ever turn gating on, gate on the **Grype** numbers (or the action's
  `critical`/`high` outputs, which take the max of both) — never on Trivy alone.
- PRs also get **one** aggregated comment, edited in place on every run. The
  `report` job runs after the scan matrix, downloads the `scans-*` artifacts and
  renders them with `.github/scripts/scan-report.sh`, then posts via the
  [`pr-comment`](.github/actions/pr-comment/action.yml) action, which upserts on
  a `<!-- conduktor-ci:cve-report -->` marker. That action is deliberately
  generic — it knows nothing about CVEs — so keep report rendering out of it.
  Don't post from inside the matrix (one comment per image) and don't swap in a
  marketplace comment action: this is ~30 lines of `gh api` and avoids handing a
  third-party action `pull-requests: write` on a public repo.
  Fork PRs get a read-only token, so the comment step is skipped there by
  design and the report goes to the job summary instead.
- Trivy runs with `ignore-unfixed: true` and Grype with `only-fixed: false`, on
  purpose: the badge should track what a rebuild can actually clear, while the
  summary should still show the full picture. That asymmetry explains most of the
  gap between the two totals, and the summary says so in its footer.

### 12. Where a script lives says who runs it

- `scripts/` — anything a human might run directly, even if CI runs it too:
  `image-build.sh` (the local image build, what `make build` shells out to),
  `melange-build.sh` (called by `image-build.sh` in turn), `image-matrix.sh`.
  Nothing executable stays at the repo root; `make <target>` is the root-level
  entry point and every target delegates here.
- `.github/scripts/` — CI-only. `cve-counts.sh`, `cve-badge.sh`,
  `scan-summary.sh`, `scan-report.sh`. Nobody runs these by hand; they exist to
  keep logic out of YAML.
- `.github/actions/<name>/` — a script with exactly one consumer lives with its
  action (`pr-comment/sticky-comment.sh`). Shared ones stay in
  `.github/scripts/`: `cve-counts.sh` feeds both the `scan-image` action and the
  nightly's badge step, so burying it in one action would make the other reach
  into that action's internals.

Two things that make this safe rather than just tidy:

- **Tests live next to what they test** and `make test` *discovers* them with a
  `find` over `*/tests/test-*.sh` rather than a fixed glob, so adding a
  `tests/` directory anywhere can't silently drop it from the run.
  `make lint-shell` already walks the whole tree.
- **CI lints via `pre-commit`, not `make lint`**, so every linter version comes
  from `.pre-commit-config.yaml`. `make lint-shell` uses whatever shellcheck is
  on `PATH`; the runner's is older than the pinned one and they disagree (an
  SC2015 passed locally and failed CI). If CI reports a shellcheck finding you
  can't reproduce, run `make precommit-run`. The only hook CI skips is
  `apko-show-config`, which needs apko and is covered by the build job.
- **Don't vendor a copy of a script into an action to make it "self-contained".**
  A repo-local action (`uses: ./.github/actions/...`) cannot run without
  `actions/checkout` anyway, so referencing `$GITHUB_WORKSPACE/.github/scripts/`
  costs nothing and duplication costs correctness.

### 13. Long builds fan out to native runners, per arch

`base-monitoring` builds Prometheus and Cortex from source (Go + an npm web-UI
build). melange builds each arch in a sandbox *of that arch*, so building
aarch64 on an amd64 runner runs the entire compile under qemu emulation. The
nightly therefore has two stages:

1. **`apks`** — one job per `(image, arch)` from `build-matrix.sh`'s `.apks`,
   `runs-on: ${{ matrix.apk.runner }}`. Each job builds only its own arch,
   natively, and uploads `images/<dir>/packages` as `apks-<dir>-<arch>`.
2. **`publish`** — one job per image. It downloads every `apks-<dir>-*` with
   `merge-multiple: true` (each artifact holds a single `<arch>/` directory, so
   they merge into one `@local ./packages` repo), re-signs the index, then does
   the single multi-arch `apko publish` exactly as before.

Things that look like simplifications and are not:

- **Runner labels are standard GitHub-hosted only** (`ubuntu-latest`,
  `ubuntu-24.04-arm`), and they live in `build-matrix.sh` with a test asserting
  every label starts with `ubuntu-`. Do not point these at a self-hosted or
  third-party runner pool: this repo is public and forkable, and the nightly
  base-image rebuild must not depend on private infrastructure (same reasoning
  as rule 8). Note arm64 GitHub runners have no `-latest` alias.
- **The publish job must re-sign the index** (`scripts/melange-index.sh`).
  Each `apks` job signs with its own temporary key and uploads its own
  `APKINDEX.tar.gz`, so the merged repo would otherwise carry two indexes signed
  by two keys neither of which apko has. Verified while building this: apk
  checks the *index* signature and the checksums it records, not each APK's own
  signature, so re-indexing the whole set under one fresh key is enough — an APK
  signed by key A installs from an index signed by key B. The script drops the
  stale index rather than merging, because `melange index` *appends* signatures.
- **Signing cannot be skipped in the `apks` job to avoid the re-index.**
  `melange-build` adds `--keyring-append <signing-key>.pub` for every config
  after the first, so a multi-config build with no key fails on a missing file.
- **`publish` deliberately does not gate on the `apks` result.** It runs under
  `!cancelled()` so that (a) images with no melange configs still publish when
  the `apks` job is skipped entirely, and (b) one image's failed arch does not
  hold back everyone else's nightly. That image still fails, fail-closed:
  `melange-index.sh` rejects an empty `packages/`, and apko cannot resolve
  `@local` for an arch whose APKs never arrived.
- **`MELANGE_VERSION` is pinned in both workflows** because two jobs have to
  agree — the one that builds the APKs and the one that re-indexes them. Bump it
  with the flake, like apko (rule 5).
- **There is one build definition, not two.**
  [`build.yml`](.github/workflows/build.yml) is a `workflow_call` workflow that
  owns `prepare` → `apks` → `build`; `nightly.yml` calls it with
  `publish: true` and `pr.yml` with `publish: false`. Everything that differs
  between a PR check and a release — registry logins, `apko publish` vs
  `apko build` into a tar, cosign signing, SBOM attestation, SLSA provenance,
  badge JSON — is a step gated on that one input.
  Do not "simplify" the PR back to an inline single-job build. It was written
  that way first, and it meant the riskiest machinery in this repo (artifact
  merge, `melange-index.sh`, `@local` resolution across two jobs) was only ever
  executed by the nightly, i.e. after merge, on a schedule, with no reviewer
  watching. Same reasoning as rule 11's single scan action.
- **The PR still builds one arch.** It passes `arches: x86_64`, so the fan-out
  is a one-element matrix: same shape, same code path, without doubling the wall
  clock of every image-touching PR. The nightly is what proves aarch64.
- **Arch names come from `build-matrix.sh`, both spellings.** It emits `arches`
  (melange: `x86_64,aarch64`) and `apko_arches` (OCI: `amd64,arm64`) from one
  input, so a workflow cannot hand apko an arch set the APKs were never built
  for. Don't hardcode `--arch amd64,arm64` in a workflow again.

### 14. Nothing may make the apk cache authoritative

The nightly exists so a Wolfi package update reaches our images within 24h *even
though no file in this repo changed*. That only holds while every run resolves
against the live index, so the apk cache must stay an accelerator, never a
source of truth. `.github/scripts/tests/test-nightly-freshness.sh` enforces the
three ways it could stop being one — a frozen nightly still looks perfectly
healthy (green runs, moving tags, new digests), so this cannot be left to
review.

- **Never `actions/cache` the apk cache directory.** apko and melange both use
  go-apk, which caches packages *and* the APKINDEX in
  `~/.cache/dev.chainguard.go-apk` (overridable with apko's `--cache-dir` and
  melange's `--apk-cache-dir`). GitHub-hosted runners start with it empty, which
  is exactly why the nightly is fresh today. Persisting it is the one change
  that would break rule-14 semantics while looking like a speedup.
- **Never `--offline`, never a lockfile.** `apko --offline` builds from the
  cache alone, and `apko lock` pins resolved versions — either turns every later
  build into a replay of the day it was generated. Neither belongs in this repo.
- **The cache we do persist is safe by construction.** `melange-cache` holds
  melange's *inputs*: files named `sha256:<hash>` from `fetch`'s
  `expected-sha256`, so it cannot serve content other than what was asked for.
  It cannot hold apks — melange keeps those under `--apk-cache-dir`, a different
  directory (verified: no `.apk` and no `APKINDEX` ever appears in it). It also
  accumulates melange's `gomodcache/` and `npm/`, which are pinned by `go.sum` /
  `package-lock.json` and equally cannot go stale — but they are why the entry
  reaches ~1 GB for `base-monitoring`.
- Worth knowing before someone "fixes" a warm cache they think is stale: a warm
  cache is not stale anyway. Measured against an 11 GB local one, a rebuild
  re-downloaded the 10 MB APKINDEX and picked up packages published three hours
  earlier; go-apk fetches the index every build, and package entries are keyed
  `name-version-rN`, so a newer version is always a miss.

## Common tasks

### Add a package to an image
1. Verify it exists in Wolfi with `apk search -e`.
2. Add it to the correct section of the image's `apko.yaml` with a trailing
   `# why` comment.
3. `make build IMAGE=<image>` locally to prove it resolves.
4. `make scan IMAGE=<image>` to check the CVE delta.
5. `make lint && make precommit-run` before pushing.

### Add a new image
1. Create `images/<dir>/apko.yaml` (copy the closest existing one), plus a
   `README.md` and any `melange*.yaml` it needs.
2. Add one entry to [`images/images.json`](images/images.json) — `dir`, `name`,
   and `dockerhub` only if it must also ship to Docker Hub (see rule 8).
3. Add a row to the README's images + badges tables.

That's it — the Makefile, `scripts/image-build.sh` and both workflows all derive the image
list from the manifest (rule 9), and an image with `melange*.yaml` files picks
up its per-arch APK jobs from the same place (rule 13). `make test` asserts the
manifest and `images/*/` stay in sync, so a directory added without a manifest
entry fails the PR rather than silently never being built.

### Bump apko / melange / cosign in CI
1. Update `APKO_VERSION` / `MELANGE_VERSION` env in
   `.github/workflows/build.yml` — one place, both workflows (rule 5).
2. Update the same pin in `flake.nix` (via nixpkgs revision) if it drifts.
3. Open a PR: it runs the same build.yml the nightly will, so the bump is
   exercised before merge. Then trigger the nightly with `workflow_dispatch`.

### Debugging a failed nightly
- `apko publish` failed → look at `Publish with apko` step. Most common
  cause: a Wolfi package rename (see rule 1) or the Wolfi keyring URL
  changing. If it failed to resolve an `@local` package for one arch only,
  the real failure is that arch's `apks-<image>-<arch>` job (rule 13).
- `Sign the local APK index` failed → an `apks` job produced nothing for some
  arch. Fix that job; do not work around it by publishing a single arch.
- `cosign sign/attest` failed → OIDC issue. Check `id-token: write`
  permission and that the workflow ref matches the identity regex readers
  use in the README verify snippet.
- `publish-badges` failed → check `Publish badges to `badges` branch`.
  It pushes to the orphan `badges` branch, not to `main`, so branch
  protection on `main` cannot block it (rule 6). If the branch itself is
  protected, drop the protection — the branch is state-only and the
  workflow is the only writer.

## Before pushing

```sh
make lint            # yamllint + actionlint + apko show-config + shellcheck
make test            # fixture tests for scripts/ (also asserts images.json is in sync)
make precommit-run   # all 12 pre-commit hooks
make build IMAGE=<changed image>   # for any apko.yaml change
```

`make build` is **host-arch only** — it is a test artifact, and building the
foreign arch runs the melange pipeline under qemu emulation (~30s becomes several
minutes once `kafka-tools` is involved, and far worse for `base-monitoring`,
which compiles Prometheus and Cortex). The nightly is what produces multi-arch,
one native runner per arch (rule 13). To reproduce it locally before a risky
packaging change:

```sh
make build IMAGE=debug ARCHES=x86_64,aarch64
```

To rehearse the nightly's *assembly* step instead — APKs from several sources
merged and re-indexed under one key — drop each arch's `.apk` files into
`images/<image>/packages/<arch>/` and run:

```sh
scripts/melange-index.sh <image> && (cd images/<image> && apko build apko.yaml ...)
```

CI runs the same tools. Fixing lint locally is faster than the round-trip.

## Non-obvious gotchas

- `SYS_PTRACE` is not required to attach with `jcmd`/`jstack`/`jmap`/`jfr`.
  HotSpot's attach listener checks the socket peer's credentials —
  `is_root(uid) || (geteuid() == uid && getegid() == gid)` in
  `os::Posix::matches_effective_uid_and_gid_or_root` — so running the debug
  sidecar as UID/GID 10001, matching the product container, is sufficient.
  `SYS_PTRACE` is only for tools that call `ptrace(2)`: `strace`, `jstack -F`,
  `jmap -F`, `jhsdb`. `tcpdump` wants `NET_RAW`, not `SYS_PTRACE`. The README
  documented all of these as needing `SYS_PTRACE`, which was wrong and led
  people to grant it unnecessarily.
- `openjdk-25-jre` in Wolfi is a slim JRE; `openjdk-25` (no suffix) is the
  full JDK. The debug image intentionally uses the JDK for `jstack`/`jmap`
  /`jcmd`/`jfr` because jattach isn't packaged.
- `apko publish` prints one `<ref>@sha256:...` line per pushed tag; they all
  resolve to the same OCI index digest. The workflow takes the last line.
- The `nightly` and `latest` tags are aliases — they move on every run.
  Immutable references for downstream products are `YYYY.MM.DD` or
  `git-<sha>` tags.
- `JAVA_HOME` is `/usr/lib/jvm/java-25-openjdk` — hardcoded in the configs.
  If Wolfi changes the JDK layout, update all three of `base-jre-25`,
  `debug`, and any consuming Dockerfiles. `base-monitoring` has no JVM at all.
- Wolfi's `gnupg` is a **meta package that installs no `gpg` binary**. The
  Ubuntu monitoring base listed it because `install_packages` needed it for apt
  repository keys at build time; there is no apt in an apko image, so it was
  dropped from `base-monitoring` rather than carried over. Check
  `docker run --rm <img> command -v <tool>` before assuming a package name
  gives you the command you expect.
- `supervisor-cdk` bakes the python `site-packages` path chosen at package
  build time, and depends on `python-3` (the moving meta package) rather than a
  pinned minor. That is deliberate and self-correcting: the melange build env
  and the apko image resolve `python-3` from the same Wolfi snapshot minutes
  apart. Never hardcode `python3.13` anywhere in that recipe.
- The `melange*.yaml` `package.version` fields are asserted against what the
  built binary reports (`prometheus --version`, `cortex -version`,
  `conduktor version`). This is not ceremony: it caught the ported Prometheus
  recipe declaring `3.8.0` while the fork tag actually builds `3.8.1`, which
  would have put the wrong version in the SBOM — and Grype matches CVEs on
  exactly that.
- The badge JSON follows the shields.io *endpoint* schema
  (`{schemaVersion, label, message, color, namedLogo}`), not the *dynamic*
  schema. Don't confuse them.

## Where to look for context you don't have

- Wolfi package index: <https://packages.wolfi.dev/os/> — search there when
  a package name doesn't resolve.
- Cosign keyless verification identity: `https://github.com/conduktor/
  container-images/.github/workflows/nightly.yml@refs/heads/<branch>`;
  issuer is always `https://token.actions.githubusercontent.com`.
