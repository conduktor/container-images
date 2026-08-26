#!/usr/bin/env bash
#
# Validate that every images/*/apko.yaml parses: apko has no `lint`, and
# `show-config` resolves the same config a build would.
#
# Usage:
#   scripts/apko-show-config.sh              # every image dir
#   scripts/apko-show-config.sh debug ...    # named image dirs
#
# Set APKO_BIN / MELANGE_BIN to point at specific binaries.
#
# Requires: apko; melange only for an image whose key is missing.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMAGES_DIR="${REPO_ROOT}/images"
APKO="${APKO_BIN:-apko}"
MELANGE="${MELANGE_BIN:-melange}"

command -v "${APKO}" >/dev/null 2>&1 \
  || { echo "apko not found — run inside 'nix develop'" >&2; exit 2; }

# apko 1.2.x initializes the apk keyring during show-config, so a config whose
# `keyring:` names a melange key fails on a fresh clone (the keys are ephemeral
# and gitignored). Generating one is not a build, so it is undone on the way out
# and a pre-existing pair is left alone.
generated=()
cleanup() {
  [ "${#generated[@]}" -gt 0 ] && rm -f "${generated[@]}"
  return 0
}
trap cleanup EXIT

if [ "$#" -gt 0 ]; then
  dirs=("$@")
else
  shopt -s nullglob
  dirs=()
  for d in "${IMAGES_DIR}"/*/apko.yaml; do dirs+=("$(basename "$(dirname "${d}")")"); done
  shopt -u nullglob
fi
[ "${#dirs[@]}" -gt 0 ] || { echo "no images/*/apko.yaml found" >&2; exit 2; }

for dir in "${dirs[@]}"; do
  work_dir="${IMAGES_DIR}/${dir}"
  [ -f "${work_dir}/apko.yaml" ] || { echo "no apko.yaml in images/${dir}" >&2; exit 2; }

  cd "${work_dir}"

  # Only the local keys this config actually names, so an image without an
  # @local repo never needs melange on PATH.
  while read -r key; do
    [ -n "${key}" ] && [ ! -f "${key}" ] || continue
    command -v "${MELANGE}" >/dev/null 2>&1 \
      || { echo "images/${dir}/apko.yaml needs ${key}; melange not found to generate it" >&2; exit 2; }
    "${MELANGE}" keygen "${key%.pub}" >/dev/null 2>&1 \
      || { echo "melange keygen failed for images/${dir}/${key%.pub}" >&2; exit 1; }
    priv="${work_dir}/${key#./}"
    priv="${priv%.pub}"
    generated+=("${priv}" "${priv}.pub")
  done < <(grep -oE '\./[[:alnum:]_.-]+\.rsa\.pub' apko.yaml | sort -u)

  echo ">> apko show-config images/${dir}/apko.yaml"
  "${APKO}" show-config apko.yaml >/dev/null
done
