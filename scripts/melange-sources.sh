#!/usr/bin/env bash
#
# List — or prefetch — the external sources an image's melange configs fetch.
#
# Usage:
#   scripts/melange-sources.sh <image-dir>                     # print "uri<TAB>sha256"
#   scripts/melange-sources.sh <image-dir> --prefetch <cache>  # download missing
#
# melange's cache is read-only: `fetch` copies from <cache>/sha256:<hash> but
# never writes back, so it has to be populated from outside. That is why this
# script exists and must not be "simplified" into just passing --cache-dir:
# without it every build re-downloads kafka_2.13-4.3.0.tgz, which is 135 MB and
# only served by archive.apache.org (dlcdn and downloads 404 it) at ~250 KB/s —
# 12 minutes per arch, against ~11s warm.
#
# The printed list is also the CI cache key, hence the sort: glob order follows
# LC_COLLATE, so an unsorted list would key identical inputs differently on
# different machines.
#
# Only `uses: fetch` steps appear here. A git-checkout source has no content
# hash to address, so the forks contribute nothing to this cache by design.
#
# This re-implements the subset of melange's templating our configs use —
# ${{package.version}}, ${{vars.*}} and var-transforms — rather than asking
# melange to resolve it. `melange query` would do that correctly, but this script
# runs in CI *before* melange is installed (it populates the cache the melange
# build then reads), so it cannot depend on the binary. Anything left unresolved
# is a hard error rather than a URL that 404s later; see the guard below.
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

  # var-transforms derive further vars from existing ones, and melange evaluates
  # them after `vars`. kafka-tools uses one to get the archive's release branch
  # (8.3) out of the package version (8.3.1), so skipping this leaves a literal
  # ${{vars.release-branch}} in the URL.
  # Read field by field, NOT via @tsv: @tsv escapes backslashes, so a `match` of
  # ^(\d+\.\d+)\.\d+$ would arrive as ^(\\d+\\.\\d+)\\.\\d+$ and quietly fail to
  # match — leaving the version untransformed and the URL pointing at /8.3.1/.
  n_transforms="$(jq '(.["var-transforms"] // []) | length' <<<"${json}")"
  for ((i = 0; i < n_transforms; i++)); do
    t_from="$(jq -r --argjson i "${i}" '.["var-transforms"][$i].from // ""' <<<"${json}")"
    t_match="$(jq -r --argjson i "${i}" '.["var-transforms"][$i].match // ""' <<<"${json}")"
    t_replace="$(jq -r --argjson i "${i}" '.["var-transforms"][$i].replace // ""' <<<"${json}")"
    t_to="$(jq -r --argjson i "${i}" '.["var-transforms"][$i].to // ""' <<<"${json}")"
    [ -n "${t_to}" ] || continue

    src="${t_from//\$\{\{package.version\}\}/${version}}"
    for kv in "${varlines[@]}"; do
      src="${src//\$\{\{vars.${kv%%=*}\}\}/${kv#*=}}"
    done

    # melange's regexes are Go's, and sed's are POSIX ERE. Translate the
    # shorthand classes Go accepts and ERE does not — `\d` is the one our config
    # uses, and it is what anyone writing a new transform will reach for — plus
    # Go's `$1` capture references, which ERE spells `\1`.
    ere="$(printf '%s' "${t_match}" \
      | sed -e 's/\\d/[0-9]/g' -e 's/\\w/[A-Za-z0-9_]/g' -e 's/\\s/[[:space:]]/g')"
    # shellcheck disable=SC2016  # `$([0-9])` is sed's syntax here, not a subshell
    repl="$(printf '%s' "${t_replace}" | sed -E 's/\$([0-9])/\\\1/g')"

    transformed="$(printf '%s' "${src}" | sed -E "s|${ere}|${repl}|")"

    # sed prints its input unchanged when the pattern does not match, so a
    # non-matching transform is indistinguishable from an identity one. melange
    # would report this; we would silently build a wrong URL.
    if [ "${transformed}" = "${src}" ]; then
      echo "var-transform '${t_to}' in ${config} did not match:" >&2
      echo "  input   ${src}" >&2
      echo "  match   ${t_match}" >&2
      exit 1
    fi

    varlines+=("${t_to}=${transformed}")
  done

  while IFS=$'\t' read -r uri sha; do
    case "${sha}" in ''|null) continue ;; esac

    uri="${uri//\$\{\{package.version\}\}/${version}}"
    for kv in "${varlines[@]}"; do
      uri="${uri//\$\{\{vars.${kv%%=*}\}\}/${kv#*=}}"
    done

    # Fail loudly on anything this script cannot resolve. Emitting the URL
    # unexpanded is worse than useless: the cache key stays stable so CI reports
    # a hit, and the prefetch dies on `curl: (3) nested brace in URL`.
    # shellcheck disable=SC2016  # matching a literal ${{ , not expanding it
    case "${uri}" in
      *'${{'*)
        echo "unresolved melange substitution in ${config}:" >&2
        echo "  ${uri}" >&2
        echo "  This script re-implements melange's templating (see its header)." >&2
        echo "  Teach it the new form, or express the value as a var-transform." >&2
        exit 1 ;;
    esac

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
