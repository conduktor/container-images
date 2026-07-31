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
| `images/debug/` | `ghcr.io/conduktor/conduktor-debug` | Debug sidecar (JDK-25 + network/TLS/LDAP/Kafka/JVM tooling). |

Every image is signed keyless with cosign, ships an SPDX SBOM (apko-emitted,
attested with cosign), and carries a SLSA build-provenance attestation.

## Layout

```
.
├── images/
│   ├── base-os/apko.yaml        # source of truth per image
│   ├── base-jre-25/apko.yaml
│   └── debug/apko.yaml
├── build.sh                     # local `apko build` wrapper (uses cgr.dev/chainguard/apko fallback)
├── Makefile                     # dev targets: build / lint / scan / sbom / precommit-*
├── flake.nix                    # nix devShell with every tool pinned
├── .pre-commit-config.yaml
├── .yamllint.yaml
├── .github/
│   ├── workflows/nightly.yml    # 04:00 UTC cron; publish + sign + attest + scan + refresh badges
│   ├── workflows/pr.yml         # build-only + scan on PRs; blocks CRITICAL findings
│   ├── badges/*.json            # nightly-refreshed shields.io endpoint JSON (auto-committed by CI)
│   ├── dependabot.yml           # weekly bumps for GHA SHA pins
│   └── CODEOWNERS               # @conduktor/platform
└── README.md                    # user-facing docs (pull / verify / sidecar)
```

## Rules

### 1. Use apko in priority; verify Wolfi packages before adding

- Prefer apko over Dockerfile or melange. Only reach for melange if a needed
  binary isn't in Wolfi at all.
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
gh api repos/<owner>/<repo>/git/refs/tags/<tag> -q .object.sha
```

### 5. Tool versions in CI are pinned too

`APKO_VERSION` and `COSIGN_VERSION` env vars at the top of the workflows are
passed as `apko-version` / `cosign-release` inputs to the installer actions.
Bump both together and update the flake.

### 6. Badges are in-repo, not on a gist

`.github/badges/<image>-{trivy,grype}.json` are shields.io endpoint JSON
files that the `publish-badges` job of the nightly workflow commits back to
`main` with `[skip ci]`. Do not add gist/PAT plumbing.

### 7. Account convention

- All three images ship the `conduktor` group + user at UID/GID 10001.
- The debug image *additionally* ships a legacy `gateway` user at UID/GID
  1001 (kept for compatibility with existing Gateway deployments). Do not
  remove it without checking product Helm charts.
- Base images default to `root` so downstream builds can chown/chmod their
  layers; downstream Dockerfiles must set `USER 10001` themselves. Do not
  add `run-as` at the base layer.

## Common tasks

### Add a package to an image
1. Verify it exists in Wolfi with `apk search -e`.
2. Add it to the correct section of the image's `apko.yaml` with a trailing
   `# why` comment.
3. `make build IMAGE=<image>` locally to prove it resolves.
4. `make scan IMAGE=<image>` to check the CVE delta.
5. `make lint && make precommit-run` before pushing.

### Add a new image
1. Create `images/<name>/apko.yaml` (copy the closest existing one).
2. `IMAGES := base-os base-jre-25 debug` in the `Makefile` — extend.
3. `matrix.image` list in `.github/workflows/nightly.yml` and the `all` JSON
   in `.github/workflows/pr.yml` — extend both.
4. `case "${IMAGE_DIR}"` in `build.sh` — add a branch.
5. Add a row to the README's images + badges tables.

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
- Badge commit rejected → the `publish-badges` job pushes directly to
  `main`. Branch protection can block it — the fix is to give the workflow
  a token/rule exception, not to disable the job.

## Before pushing

```sh
make lint            # yamllint + actionlint + apko show-config + shellcheck
make precommit-run   # all 12 pre-commit hooks
make build IMAGE=<changed image>   # for any apko.yaml change
```

CI runs the same tools. Fixing lint locally is faster than the round-trip.

## Non-obvious gotchas

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
