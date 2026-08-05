#!/usr/bin/env bash
#
# List — or prefetch — the external sources an image's melange configs fetch.
#
# Usage:
#   scripts/melange-sources.sh <image-dir>                     # print "uri<TAB>sha256"
#   scripts/melange-sources.sh <image-dir> --prefetch <cache>  # download missing
#
# melange's cache is read-only: `fetch` copies from <cache>/sha256:<hash> but
# never writes back, so it has to be populated from outside. The printed list is
# also the CI cache key.
#
# Requires: jq, yq, curl
set -euo pipefail

IMAGE_DIR="${1:-}"
MODE="${2:-}"
CACHE_DIR="${3:-}"

[ -n "${IMAGE_DIR}" ] || { echo "Usage: $0 <image-dir> [--prefetch <cache-dir>]" >&2; exit 2; }
if [ -n "${MODE}" ]; then
  [ "${MODE}" = "--prefetch" ] || { echo "unknown option: ${MODE}" >&2; exit 2; }
  [ -n "${CACHE_DIR}" ] || { echo "--prefetch needs a cache directory" >&2; exit 2; }
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="${IMAGES_DIR:-${REPO_ROOT}/images}/${IMAGE_DIR}"
[ -d "${WORK_DIR}" ] || { echo "no such image directory: ${WORK_DIR}" >&2; exit 2; }

shopt -s nullglob
configs=("${WORK_DIR}"/melange*.yaml)
[ "${#configs[@]}" -gt 0 ] || exit 0

[ -n "${CACHE_DIR}" ] && mkdir -p "${CACHE_DIR}"

sources=()
for config in "${configs[@]}"; do
  # -o=json so the queries below are jq, not a second dialect.
  json="$(yq -o=json '.' "${config}")"
  version="$(jq -r '.package.version' <<<"${json}")"
  mapfile -t varlines < <(jq -r '(.vars // {}) | to_entries[] | "\(.key)=\(.value)"' <<<"${json}")

  while IFS=$'\t' read -r uri sha; do
    [ -n "${sha}" ] && [ "${sha}" != "null" ] || continue

    # The two melange substitutions our configs use.
    uri="${uri//\$\{\{package.version\}\}/${version}}"
    for kv in "${varlines[@]}"; do
      uri="${uri//\$\{\{vars.${kv%%=*}\}\}/${kv#*=}}"
    done

    sources+=("${uri}"$'\t'"${sha}")
  done < <(jq -r '
    .pipeline[]? | select(.uses == "fetch")
    | [.with.uri, .with["expected-sha256"]] | @tsv
  ' <<<"${json}")
done

# Sorted: glob order follows LC_COLLATE, and this list is a cache key.
[ "${#sources[@]}" -gt 0 ] || exit 0
mapfile -t sources < <(printf '%s\n' "${sources[@]}" | sort -u)

if [ "${MODE}" != "--prefetch" ]; then
  printf '%s\n' "${sources[@]}"
  exit 0
fi

for entry in "${sources[@]}"; do
    uri="${entry%%$'\t'*}"
    sha="${entry##*$'\t'}"
    target="${CACHE_DIR}/sha256:${sha}"
    if [ -f "${target}" ]; then
      echo "cached  $(basename "${uri}")"
      continue
    fi

    echo "fetch   $(basename "${uri}")"
    curl -fsSL --retry 3 -o "${target}.part" "${uri}" \
      || { rm -f "${target}.part"; echo "!! download failed: ${uri}" >&2; exit 1; }
    actual="$(sha256sum "${target}.part" | cut -d' ' -f1)"
    if [ "${actual}" != "${sha}" ]; then
      rm -f "${target}.part"
      echo "!! checksum mismatch for ${uri}" >&2
      echo "   expected ${sha}" >&2
      echo "   got      ${actual}" >&2
      exit 1
    fi
    mv "${target}.part" "${target}"
done
