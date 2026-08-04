#!/usr/bin/env bash
#
# Build an image's local APK from its melange.yaml into images/<dir>/packages/,
# so apko can resolve it via the `@local ./packages` repository.
#
# This is the LOCAL path only. CI uses chainguard-dev/actions/melange-build with
# sign-with-temporary-key, pointed at the same two output paths — see the
# "Build local APK with melange" step in the workflows.
#
# The signing key is generated on demand and never committed (.gitignore covers
# images/*/melange.rsa*): it exists only to satisfy apk's index signature check
# within a single build, so a fresh key per machine or per CI run is correct.
#
# Usage: scripts/melange-build.sh <image-dir> [arch,arch...]
#
# Defaults to the HOST arch only, because build.sh also builds the image for the
# host arch alone — a local build is a test artifact, not a release. Building the
# foreign arch means running the melange pipeline under qemu emulation, which for
# kafka-tools costs minutes rather than seconds. Pass arches explicitly (or set
# MELANGE_ARCHES) to reproduce the multi-arch nightly:
#   scripts/melange-build.sh debug x86_64,aarch64
#
# Requires: melange, and a container runner (docker by default — override with
# MELANGE_RUNNER=bubblewrap if you have bwrap and no daemon).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMAGE_DIR="${1:-}"
RUNNER="${MELANGE_RUNNER:-docker}"

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

if [ ! -f melange.rsa ]; then
  echo ">> generating an ephemeral melange signing key"
  melange keygen melange.rsa
fi

# Stale APKs from a previous run would still be indexed and could shadow the
# rebuild, so start from an empty repository each time.
rm -rf packages

# Every melange*.yaml in the image dir is built into the same repository, so
# adding a package is just adding a file. Mirrors the workflows' multi-config.
shopt -s nullglob
configs=(melange*.yaml)
[ "${#configs[@]}" -gt 0 ] || { echo "no melange*.yaml in images/${IMAGE_DIR}" >&2; exit 2; }

for config in "${configs[@]}"; do
  echo ">> melange build ${config} (${ARCHES})"
  # --namespace matters for scanning, not cosmetics: melange defaults SBOM PURLs
  # to pkg:apk/unknown/..., and Trivy skips any package whose PURL namespace does
  # not match the image's detected distro ("Some OS packages were skipped due to
  # mismatched PURL namespace"). Without this our local packages are invisible to
  # Trivy while Grype still reports them, so the two scanners disagree.
  melange build "${config}" \
    --arch "${ARCHES}" \
    --namespace wolfi \
    --signing-key melange.rsa \
    --out-dir ./packages \
    --runner "${RUNNER}"
done

echo ">> built:"
find packages -name '*.apk' | sort | sed 's/^/     /'
