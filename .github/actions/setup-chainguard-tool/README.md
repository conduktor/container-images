# setup-chainguard-tool

Local composite action that installs a Chainguard Go CLI — [apko](https://github.com/chainguard-dev/apko)
or [melange](https://github.com/chainguard-dev/melange) — on a `linux/amd64` or
`linux/arm64` GitHub-hosted runner. Both are needed: the `apks` jobs run
natively on a runner of the arch they build.

There is no first-party `chainguard-dev/actions/setup-apko` upstream, and
`curl | sh` is not a supply-chain story we want to tell. So we ship our own
installer that:

1. Resolves the requested version (or `latest`) to an immutable release tag
   and dereferences it to the commit SHA the tag points at.
2. Downloads `<tool>_<version>_linux_<runner arch>.tar.gz` + `checksums.txt`
   from the release.
3. Verifies `checksums.txt` was signed by that project's release workflow using
   Sigstore keyless (cosign `verify-blob` against Fulcio + Rekor).
4. Verifies the SHA-256 of the archive matches the entry in `checksums.txt`.
5. Extracts the binary, installs it into the runner tool cache, and adds it
   to `PATH`.
6. Runs `<tool> version` and asserts the installed binary reports the
   expected tag + commit SHA.

## Why one action for both

Chainguard's CLIs are goreleaser-built to the same shape — the archive is
`<tool>_<version>_linux_<arch>.tar.gz`, it sits beside a cosign-signed
`checksums.txt`, and `<tool> version` prints `GitVersion:` / `GitCommit:`. Only
the name varies, so the tool is an input rather than a second copy of the
scripts.

`chainguard-dev/actions/setup-melange` *does* exist upstream, unlike its apko
counterpart, but it installs Go and `build-essential` and builds from source.
This downloads one verified binary instead.

## Usage

```yaml
- name: Install apko
  uses: ./.github/actions/setup-chainguard-tool
  with:
    tool: apko
    version: v1.2.30   # or `latest`

- name: Install melange
  uses: ./.github/actions/setup-chainguard-tool
  with:
    tool: melange
    version: v0.41.1
```

## Inputs

| Name | Default | Purpose |
|------|---------|---------|
| `tool` | `apko` | CLI to install. Doubles as the binary name and the archive prefix. |
| `version` | `latest` | Version to install (e.g. `1.2.30` or `v1.2.30`). |
| `repository` | `chainguard-dev/<tool>` | Overrideable for testing/mirrors. |
| `github-token` | `${{ github.token }}` | Used by `gh release` to list + download assets. |
| `expected-commit-sha` | `""` | If set, fail unless the release tag dereferences to this SHA. |
| `expected-sha256` | `""` | If set, fail unless the downloaded archive matches this SHA-256. |
| `verify-signature` | `"true"` | Verify the Sigstore signature of `checksums.txt`. |
| `cosign-certificate-identity-regexp` | the tool's own release workflows | Cosign identity regex for the release signer. |
| `cosign-oidc-issuer` | `https://token.actions.githubusercontent.com` | Cosign OIDC issuer. |
| `install-dir` | `<runner-tool-cache>/<tool>/<tag>/<arch>` | Where to install the binary. |

## Outputs

| Name | Description |
|------|-------------|
| `version` | Installed version without the leading `v` (e.g. `1.2.30`). |
| `tag` | Release tag installed (e.g. `v1.2.30`). |
| `commit-sha` | Commit SHA the release tag dereferences to (also verified against the binary). |
| `arch` | Release architecture installed for this runner (`amd64` or `arm64`). |
| `sha256` | SHA-256 of the downloaded archive. |
| `path` | Full path to the installed binary. |
| `install-dir` | Directory added to `PATH`. |

## Origin

Adapted from the private `conduktor/conduktor-actions/setup-apko` action so
this repo can stay public without depending on a private action, then
generalised to any Chainguard CLI when the melange prefetch step needed one too.
