#!/usr/bin/env bash
#
# List — or prefetch — the pinned sources an image's melange configs fetch.
#
# Usage:
#   scripts/melange-sources.sh <image-dir>                     # print "sha256<TAB>config"
#   scripts/melange-sources.sh <image-dir> --prefetch <cache>  # populate the cache
#
# melange's cache is read-only: the `fetch` pipeline copies from
# <cache>/sha256:<hash> when it exists but never writes back, so `--cache-dir` on
# its own caches nothing and the cache has to be populated from outside. That is
# why this script exists: without it every build re-downloads
# confluent-community-8.3.1.tar.gz (414 MB), against ~11s warm.
#
# Only `uses: fetch` steps appear here. A git-checkout source has no content
# hash to address, so the forks contribute nothing to this cache by design.
#
# This deliberately does NOT resolve download URLs. The cache is keyed by content
# hash and `expected-sha256` needs no templating, so listing and the is-it-cached
# check are plain yq; downloading, the one step that needs a resolved URL, is
# handed to `melange update-cache`. An earlier version re-implemented the
# templating and fell behind it — a var-transform left a literal
# ${{vars.release-branch}} in the URL, which still hashed to a stable CI cache
# key, so the cache reported a hit and the download died on
# `curl: (3) nested brace in URL`.
#
# `melange update-cache` re-downloads every source in a config unconditionally,
# so it is only invoked for configs that are actually missing something. On a
# warm cache this makes no network calls at all.
#
# Listing needs yq only. --prefetch also needs melange on PATH.
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
# Overridable so a caller can point at a specific build, and so the tests can
# exercise both the stubbed and the absent case without rewriting PATH.
MELANGE_BIN="${MELANGE_BIN:-melange}"
WORK_DIR="${IMAGES_DIR:-${REPO_ROOT}/images}/${IMAGE_DIR}"
[ -d "${WORK_DIR}" ] || { echo "no such image directory: ${WORK_DIR}" >&2; exit 2; }

shopt -s nullglob
configs=("${WORK_DIR}"/melange*.yaml)
[ "${#configs[@]}" -gt 0 ] || exit 0

# The sha256 of every `fetch` pin in a config, in pipeline order.
pinned_hashes() {
  yq -r '
    .pipeline[]? | select(.uses == "fetch") | .with["expected-sha256"] // ""
  ' "$1" | grep -v '^$' || true
}

# --- list -------------------------------------------------------------------

if [ -z "${MODE}" ]; then
  # Sorted, because this listing *is* the CI cache key: glob order follows
  # LC_COLLATE (`-` sorts before `.`, so melange-ctl.yaml precedes melange.yaml)
  # and an unsorted list would key identical inputs differently per machine.
  {
    for config in "${configs[@]}"; do
      while IFS= read -r sha; do
        printf '%s\t%s\n' "${sha}" "$(basename "${config}")"
      done < <(pinned_hashes "${config}")
    done
  } | LC_ALL=C sort
  exit 0
fi

# --- prefetch ---------------------------------------------------------------

mkdir -p "${CACHE_DIR}"
fetched=0

for config in "${configs[@]}"; do
  name="$(basename "${config}")"
  mapfile -t hashes < <(pinned_hashes "${config}")
  [ "${#hashes[@]}" -gt 0 ] || continue

  missing=()
  for sha in "${hashes[@]}"; do
    if [ -f "${CACHE_DIR}/sha256:${sha}" ]; then
      echo "cached  ${name}  ${sha}"
    else
      missing+=("${sha}")
    fi
  done
  [ "${#missing[@]}" -gt 0 ] || continue

  command -v "${MELANGE_BIN}" >/dev/null 2>&1 || {
    echo "melange not found (${MELANGE_BIN}), and ${#missing[@]} source(s) for ${name} are not cached" >&2
    echo "  run inside 'nix develop', or install melange, to prefetch" >&2
    exit 2
  }

  echo "fetch   ${name}  (${#missing[@]} of ${#hashes[@]} not cached)"
  "${MELANGE_BIN}" update-cache --cache-dir "${CACHE_DIR}" "${config}"
  fetched=$((fetched + 1))

  # melange writes each artifact under the hash it *actually* got, so a pin that
  # no longer matches upstream leaves the expected filename absent rather than
  # failing loudly. Catch it here, where the message can name the config.
  for sha in "${missing[@]}"; do
    [ -f "${CACHE_DIR}/sha256:${sha}" ] && continue
    echo "expected-sha256 in ${name} does not match what upstream served:" >&2
    echo "  pinned  ${sha}" >&2
    echo "  melange wrote:" >&2
    find "${CACHE_DIR}" -maxdepth 1 -name 'sha256:*' -newer "${config}" \
      -printf '    %f\n' >&2 2>/dev/null || true
    exit 1
  done
done

[ "${fetched}" -gt 0 ] || echo "all sources already cached"
