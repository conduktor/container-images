# setup-apko

Local composite action that installs the [Chainguard apko](https://github.com/chainguard-dev/apko)
CLI on a `linux/amd64` GitHub-hosted runner.

There is no first-party `chainguard-dev/actions/setup-apko` upstream, and
`curl | sh` is not a supply-chain story we want to tell. So we ship our own
installer that:

1. Resolves the requested version (or `latest`) to an immutable release tag
   and dereferences it to the commit SHA the tag points at.
2. Downloads `apko_<version>_linux_amd64.tar.gz` + `checksums.txt` from the
   apko release.
3. Verifies `checksums.txt` was signed by the apko release workflow using
   Sigstore keyless (cosign `verify-blob` against Fulcio + Rekor).
4. Verifies the SHA-256 of the archive matches the entry in `checksums.txt`.
5. Extracts the binary, installs it into the runner tool cache, and adds it
   to `PATH`.
6. Runs `apko version` and asserts the installed binary reports the
   expected tag + commit SHA.

## Usage

```yaml
- name: Install apko
  uses: ./.github/actions/setup-apko
  with:
    version: v1.2.30   # or `latest`
```

## Inputs

| Name | Default | Purpose |
|------|---------|---------|
| `version` | `latest` | apko version to install (e.g. `1.2.30` or `v1.2.30`). |
| `repository` | `chainguard-dev/apko` | Overrideable for testing/mirrors. |
| `github-token` | `${{ github.token }}` | Used by `gh release` to list + download assets. |
| `expected-commit-sha` | `""` | If set, fail unless the release tag dereferences to this SHA. |
| `expected-sha256` | `""` | If set, fail unless the downloaded archive matches this SHA-256. |
| `verify-signature` | `"true"` | Verify the Sigstore signature of `checksums.txt`. |
| `cosign-certificate-identity-regexp` | apko release workflow regex | Cosign identity regex for the release signer. |
| `cosign-oidc-issuer` | `https://token.actions.githubusercontent.com` | Cosign OIDC issuer. |
| `install-dir` | `<runner-tool-cache>/apko/<tag>/amd64` | Where to install the binary. |

## Outputs

| Name | Description |
|------|-------------|
| `version` | Installed version without the leading `v` (e.g. `1.2.30`). |
| `tag` | Release tag installed (e.g. `v1.2.30`). |
| `commit-sha` | Commit SHA the release tag dereferences to (also verified against the binary). |
| `sha256` | SHA-256 of the downloaded archive. |
| `path` | Full path to the installed `apko`. |
| `install-dir` | Directory added to `PATH`. |

## Origin

Adapted from the private `conduktor/conduktor-actions/setup-apko` action so
this repo can stay public without depending on a private action. Behavior
and interface are kept in sync with the private version.
