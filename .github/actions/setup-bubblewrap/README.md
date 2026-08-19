# setup-bubblewrap

Installs [bubblewrap](https://github.com/containers/bubblewrap) so melange can
use its default Linux runner, and nothing else.

## Why this exists separately

melange resolves an empty `--runner` to bubblewrap on Linux, and then requires
`bwrap` on `PATH` plus a working `bwrap --unshare-user` before it will build.
Neither holds on a stock `ubuntu-24.04` runner: bubblewrap is not in the image,
and 24.04 blocks unprivileged user namespaces through apparmor
([melange#1508](https://github.com/chainguard-dev/melange/issues/1508)).

`chainguard-dev/actions/setup-melange` fixes both, but also installs a Go
toolchain, `build-essential` and `qemu-user-static`, and finishes by
`curl`-installing an unverified melange tarball into `/usr/local/bin`. In this
repo melange is installed by [`setup-chainguard-tool`](../setup-chainguard-tool),
which verifies the release checksums against their Sigstore signature and asserts
the binary reports the pinned commit — so the only piece worth keeping is the
sandbox setup. The Go toolchain only matters for `version: tip` (building melange
from source) and qemu only for emulating a foreign arch, which the `apks` jobs
never do: each runs natively on a runner of its own arch.

## Usage

```yaml
- name: Install melange
  uses: ./.github/actions/setup-chainguard-tool
  with:
    tool: melange
    version: v0.41.1
    # sudo's secure_path is what `sudo melange` searches.
    install-dir: /usr/local/bin

- name: Setup bubblewrap
  uses: ./.github/actions/setup-bubblewrap
```

No inputs, no outputs. The two steps are lifted from `setup-melange`, with one
change: `apt-get install` runs against the image's existing apt lists and only
falls back to `apt-get update` if they are too stale. Upstream needs no fallback
because its qemu step already ran `apt update` — the step that stalled this job
for 20+ minutes when the runner's Azure mirror was degraded.

Verification is upstream's `bwrap --unshare-user --bind / / true`, unprivileged.
That is stricter than our builds need — `melange-build-pkg` runs
`sudo melange build`, and as root melange never asks for a uid map, so apparmor's
userns restriction does not apply — but it fails at setup rather than mid-build.
