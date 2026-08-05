#!/usr/bin/env bash
#
# Build an image's local APKs from its melange*.yaml into images/<dir>/packages/
# so apko can resolve them via `@local ./packages`.
#
# Usage: scripts/melange-build.sh <image-dir> [arch,arch...]
#
# Defaults to the host arch: build.sh builds the image for the host arch alone,
# and a foreign arch runs the melange pipeline under qemu emulation. Pass arches
# (or MELANGE_ARCHES) to reproduce the multi-arch nightly.
#
# CI does the same via chainguard-dev/actions/melange-build; see the workflows.
#
# Requires: melange + a container runner (MELANGE_RUNNER=bubblewrap to override).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMAGE_DIR="${1:-}"
RUNNER="${MELANGE_RUNNER:-docker}"
CACHE_DIR="${MELANGE_CACHE_DIR:-${XDG_CACHE_HOME:-${HOME}/.cache}/melange}"

# melange spells arches x86_64/aarch64, unlike apko's amd64/arm64.
host_arch() {
  case "$(uname -m)" in
    x86_64|amd64) echo "x86_64" ;;
    aarch64|arm64) echo "aarch64" ;;
    *) echo "unsupported host arch $(uname -m)" >&2; exit 2 ;;
  esac
}
ARCHES="${2:-${MELANGE_ARCHES:-$(host_arch)}}"

[ -n "${IMAGE_DIR}" ] || { echo "Usage: $0 <image-dir> [arches]" >&2; exit 2; }

WORK_DIR="${REPO_ROOT}/images/${IMAGE_DIR}"
[ -f "${WORK_DIR}/melange.yaml" ] \
  || { echo "no melange.yaml in images/${IMAGE_DIR}" >&2; exit 2; }

command -v melange >/dev/null 2>&1 \
  || { echo "melange not found — run inside 'nix develop'" >&2; exit 2; }

cd "${WORK_DIR}"

# Ephemeral: it only has to satisfy apk's index signature check within a build.
if [ ! -f melange.rsa ]; then
  echo ">> generating an ephemeral melange signing key"
  melange keygen melange.rsa
fi

# Stale APKs would still be indexed and could shadow the rebuild.
rm -rf packages

shopt -s nullglob
configs=(melange*.yaml)
[ "${#configs[@]}" -gt 0 ] || { echo "no melange*.yaml in images/${IMAGE_DIR}" >&2; exit 2; }

# melange's cache is read-only, so sources have to be put there for it.
"${REPO_ROOT}/scripts/melange-sources.sh" "${IMAGE_DIR}" --prefetch "${CACHE_DIR}"

for config in "${configs[@]}"; do
  echo ">> melange build ${config} (${ARCHES})"
  # --namespace wolfi: melange defaults SBOM PURLs to pkg:apk/unknown/..., and
  # Trivy skips packages whose namespace doesn't match the image's distro.
  melange build "${config}" \
    --arch "${ARCHES}" \
    --namespace wolfi \
    --signing-key melange.rsa \
    --out-dir ./packages \
    --cache-dir "${CACHE_DIR}" \
    --runner "${RUNNER}"
done

echo ">> built:"
find packages -name '*.apk' | sort | sed 's/^/     /'
