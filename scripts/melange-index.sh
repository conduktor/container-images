#!/usr/bin/env bash
#
# (Re)build and sign an APKINDEX for every arch directory under
# images/<image-dir>/packages/, with a single ephemeral key at
# images/<image-dir>/melange.rsa (generated when missing).
#
# Usage: scripts/melange-index.sh <image-dir>
#
# Why this exists: the nightly builds each arch's APKs in its own native-runner
# job (AGENTS.md rule 13), so they arrive as artifacts from N jobs, each signed
# with that job's own throwaway key and carrying that job's index. apk verifies
# the *index* signature and the package checksums it records — not each APK's own
# signature — so re-indexing the whole set under one key is what makes the
# downloaded APKs installable by apko with the single `./melange.rsa.pub` keyring
# entry apko.yaml declares. (Verified: an APK signed by key A installs from an
# index signed by key B when only B is in the keyring.)
#
# Set MELANGE_BIN to point at a specific melange binary.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMAGE_DIR="${1:-}"
MELANGE="${MELANGE_BIN:-melange}"

[ -n "${IMAGE_DIR}" ] || { echo "Usage: $0 <image-dir>" >&2; exit 2; }

WORK_DIR="${IMAGES_DIR:-${REPO_ROOT}/images}/${IMAGE_DIR}"
[ -d "${WORK_DIR}" ] || { echo "no such image directory: ${WORK_DIR}" >&2; exit 2; }
[ -d "${WORK_DIR}/packages" ] \
  || { echo "no packages/ in images/${IMAGE_DIR} — nothing to index" >&2; exit 2; }

command -v "${MELANGE}" >/dev/null 2>&1 \
  || { echo "melange not found — run inside 'nix develop'" >&2; exit 2; }

cd "${WORK_DIR}"

# Ephemeral, and the only key in play from here on: it just has to satisfy apk's
# index signature check inside this one build. Never commit or reuse it.
if [ ! -f melange.rsa ]; then
  echo ">> generating an ephemeral melange signing key"
  "${MELANGE}" keygen melange.rsa
fi

shopt -s nullglob
arch_dirs=(packages/*/)
shopt -u nullglob
[ "${#arch_dirs[@]}" -gt 0 ] \
  || { echo "no arch directories under images/${IMAGE_DIR}/packages" >&2; exit 2; }

for arch_dir in "${arch_dirs[@]}"; do
  arch="$(basename "${arch_dir}")"

  shopt -s nullglob
  apks=("${arch_dir}"*.apk)
  shopt -u nullglob
  # An empty arch directory means an artifact download went wrong; failing here
  # beats publishing an image quietly missing its local packages.
  [ "${#apks[@]}" -gt 0 ] \
    || { echo "no APKs in images/${IMAGE_DIR}/${arch_dir}" >&2; exit 1; }

  # Dropped rather than merged: any index already here was signed by a different
  # ephemeral key, and `melange index` appends signatures instead of replacing.
  rm -f "${arch_dir}APKINDEX.tar.gz"

  echo ">> indexing ${#apks[@]} APK(s) for ${arch}"
  # --arch makes a package built for the wrong arch fail the index rather than
  # ending up installed by apko for the other one.
  "${MELANGE}" index \
    --output "${arch_dir}APKINDEX.tar.gz" \
    --arch "${arch}" \
    --signing-key melange.rsa \
    "${apks[@]}"
done
