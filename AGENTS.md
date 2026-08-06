# AGENTS.md

Instructions for AI coding agents (Claude Code, Copilot Chat, Cursor, Aider, …)
working in this repo. Human contributors can read the [README](README.md) for
the same background at a higher level.

## What this repo is

Apko-built base and public container images for Conduktor products. Three
images ship from here:

| Directory | Published tag | Purpose |
|-----------|---------------|---------|
| `images/base-os/` | `ghcr.io/conduktor/base-os` | Minimal Wolfi OS + `conduktor` UID 10001 account. No language runtime. |
| `images/base-jre-25/` | `ghcr.io/conduktor/base-jre-25` | OpenJDK 25 JRE base for Console + Gateway. |
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
│   └── debug/apko.yaml
├── scripts/                     # runnable by a human as well as CI (rule 12)
│   ├── image-matrix.sh          # manifest -> CI build matrix (validates the dispatch subset)
│   ├── melange-build.sh         # local APK build; also called by build.sh
│   ├── melange-sources.sh       # list/prefetch pinned sources; CI cache key + prefetch
│   └── tests/test-*.sh          # fixture tests for the above; `make test`
├── build.sh                     # local `apko build` wrapper (uses cgr.dev/chainguard/apko fallback)
├── Makefile                     # dev targets: build / lint / test / scan / sbom / precommit-*
├── flake.nix                    # nix devShell with every tool pinned
├── .pre-commit-config.yaml
├── .yamllint.yaml
├── .github/
│   ├── workflows/nightly.yml    # 04:00 UTC cron; publish + sign + attest + scan + refresh badges
│   ├── workflows/pr.yml         # build + scan on PRs; report-only, no CVE gate (rule 11)
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
  cost more than they give (measure before claiming this). Three melange configs
  exist under `images/debug/` for those reasons; see rule 10 before adding a
  fourth or "simplifying" one back to a Wolfi package:

  | Config | Package | Why not Wolfi |
  |--------|---------|---------------|
  | `melange.yaml` | `conduktor-debug-scripts` | our own scripts, nothing to package |
  | `melange-conduktor-ctl.yaml` | `conduktor-ctl` | `conduktor/ctl` is not in Wolfi |
  | `melange-kafka-tools.yaml` | `kafka-tools` | `kafka-4.3` drags an unused second JVM; see below |
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

`APKO_VERSION` at the top of the workflows is passed as `version` to the
local setup-apko action. Cosign is pinned transitively via the SHA of
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

- All three images ship the `conduktor` group + user at UID/GID 10001.
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

The image list used to be duplicated in the `Makefile`, `build.sh`, the
nightly matrix and the `pr.yml` `all` JSON. It now lives once in
[`images/images.json`](images/images.json):

```json
{ "dir": "debug", "name": "conduktor-debug", "dockerhub": "docker.io/conduktor/conduktor-debug" }
```

`dir` is the directory under `images/`, `name` is the published image name,
`dockerhub` is optional. Do not re-hardcode the list anywhere.

- The nightly's `prepare` job resolves the matrix with
  `scripts/image-matrix.sh`. **Do not add per-step `if:` guards to filter
  images** — that was the old pattern and it needed the same condition on 16
  steps. Filter by emitting a narrower matrix instead.
- `scripts/image-matrix.sh` exits non-zero on an unknown name, so a typo'd
  `workflow_dispatch` input fails the run instead of quietly building nothing.
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
  `chainguard-dev/actions/melange-build` with `sign-with-temporary-key: true`.
  Never commit a key or wire up a persistent one — the key only has to satisfy
  apk's index signature check inside a single build.
- `apko show-config` does not resolve repositories, so `make lint` passes on a
  fresh clone with no `packages/` present. Only `apko build`/`publish` needs the
  APK, which is why `build.sh` runs melange first when a `melange.yaml` exists.

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
  `melange-build.sh` (called by `build.sh`), `image-matrix.sh`.
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

## Common tasks

### Add a package to an image
1. Verify it exists in Wolfi with `apk search -e`.
2. Add it to the correct section of the image's `apko.yaml` with a trailing
   `# why` comment.
3. `make build IMAGE=<image>` locally to prove it resolves.
4. `make scan IMAGE=<image>` to check the CVE delta.
5. `make lint && make precommit-run` before pushing.

### Add a new image
1. Create `images/<dir>/apko.yaml` (copy the closest existing one).
2. Add one entry to [`images/images.json`](images/images.json) — `dir`, `name`,
   and `dockerhub` only if it must also ship to Docker Hub (see rule 8).
3. Add a row to the README's images + badges tables.

That's it — the Makefile, `build.sh` and both workflows all derive the image
list from the manifest (rule 9). `make test` asserts the manifest and
`images/*/` stay in sync, so a directory added without a manifest entry fails
the PR rather than silently never being built.

### Bump apko / cosign in CI
1. Update `APKO_VERSION` / `COSIGN_VERSION` env in `.github/workflows/*.yml`.
2. Update the same pin in `flake.nix` (via nixpkgs revision) if it drifts.
3. Trigger the nightly with `workflow_dispatch` to verify.

### Debugging a failed nightly
- `apko publish` failed → look at `Publish with apko` step. Most common
  cause: a Wolfi package rename (see rule 1) or the Wolfi keyring URL
  changing.
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
minutes once `kafka-tools` is involved). The nightly is what produces multi-arch.
To reproduce it locally before a risky packaging change:

```sh
make build IMAGE=debug ARCHES=x86_64,aarch64
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
  `debug`, and any consuming Dockerfiles.
- The badge JSON follows the shields.io *endpoint* schema
  (`{schemaVersion, label, message, color, namedLogo}`), not the *dynamic*
  schema. Don't confuse them.

## Where to look for context you don't have

- Wolfi package index: <https://packages.wolfi.dev/os/> — search there when
  a package name doesn't resolve.
- Cosign keyless verification identity: `https://github.com/conduktor/
  container-images/.github/workflows/nightly.yml@refs/heads/<branch>`;
  issuer is always `https://token.actions.githubusercontent.com`.
