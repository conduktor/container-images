#!/usr/bin/env bash
#
# Tests for scripts/melange-sources.sh. Offline: listing is checked against a
# fixture, and prefetch only against sources already "cached", so no network.
# Silent on success; prints only failures.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="${REPO_ROOT}/scripts/melange-sources.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

checks=0
fails=0
assert_eq() {
  checks=$((checks + 1))
  if [ "$2" != "$3" ]; then
    echo "  FAIL $1: want '$2', got '$3'" >&2
    fails=$((fails + 1))
  fi
}
fail() { fails=$((fails + 1)); echo "  FAIL $1" >&2; }

# Fixture image dir, pointed at via IMAGES_DIR so the real configs aren't needed.
mkdir -p "${TMP}/images/demo"
cat > "${TMP}/images/demo/melange.yaml" <<'YAML'
package:
  name: demo
  version: 1.2.3
vars:
  flavour: "2.13"
pipeline:
  - runs: echo no fetch here
  - uses: fetch
    with:
      uri: https://example.invalid/demo-${{package.version}}-${{vars.flavour}}.tgz
      expected-sha256: aaaa
YAML
cat > "${TMP}/images/demo/melange-extra.yaml" <<'YAML'
package:
  name: extra
  version: 9.9.9
pipeline:
  - uses: fetch
    with:
      uri: https://example.invalid/extra-${{package.version}}.tgz
      expected-sha256: bbbb
YAML
export IMAGES_DIR="${TMP}/images"

out="$("${SCRIPT}" demo)"

# Both substitution forms must be expanded, or the cache key would contain a
# literal ${{...}} and never change on a version bump.
assert_eq "package.version and vars expanded" \
  "https://example.invalid/demo-1.2.3-2.13.tgz	aaaa" \
  "$(printf '%s\n' "${out}" | head -n1)"
assert_eq "every melange*.yaml is walked" "2" "$(printf '%s\n' "${out}" | grep -c .)"
assert_eq "second config expanded too" \
  "https://example.invalid/extra-9.9.9.tgz	bbbb" \
  "$(printf '%s\n' "${out}" | tail -n1)"

subst="\${{" # escaped so shellcheck sees no unexpanded expression (SC2016)
checks=$((checks + 1))
case "${out}" in *"${subst}"*) fail "an unexpanded substitution leaked into the output" ;; esac
# Non-fetch pipeline steps must not appear.
checks=$((checks + 1))
case "${out}" in *'no fetch here'*) fail "non-fetch steps must be ignored" ;; esac

# The listing is the cache key, so it must be stable across runs.
assert_eq "listing is deterministic" "${out}" "$("${SCRIPT}" demo)"

# --- prefetch ---------------------------------------------------------------
cache="${TMP}/cache"
mkdir -p "${cache}"
: > "${cache}/sha256:aaaa"
: > "${cache}/sha256:bbbb"
pre="$("${SCRIPT}" demo --prefetch "${cache}")"
assert_eq "already-cached sources are not refetched" "2" \
  "$(printf '%s\n' "${pre}" | grep -c '^cached')"
checks=$((checks + 1))
case "${pre}" in *'^fetch'*) fail "should not fetch what is already cached" ;; esac

# An image with no melange configs is not an error — base-os has none.
mkdir -p "${TMP}/images/plain"
checks=$((checks + 1))
if ! "${SCRIPT}" plain >/dev/null 2>&1; then
  fail "an image without melange configs should exit 0"
fi
assert_eq "no configs means no sources" "" "$("${SCRIPT}" plain)"

# Argument validation.
checks=$((checks + 1))
if "${SCRIPT}" >/dev/null 2>&1; then fail "missing image-dir should exit non-zero"; fi
checks=$((checks + 1))
if "${SCRIPT}" nope >/dev/null 2>&1; then fail "unknown image-dir should exit non-zero"; fi
checks=$((checks + 1))
if "${SCRIPT}" demo --prefetch >/dev/null 2>&1; then fail "--prefetch without a dir should exit non-zero"; fi
checks=$((checks + 1))
if "${SCRIPT}" demo --bogus x >/dev/null 2>&1; then fail "unknown option should exit non-zero"; fi

if [ "${fails}" -ne 0 ]; then
  echo "melange-sources: ${fails}/${checks} failed" >&2
  exit 1
fi
echo "melange-sources: ${checks} checks passed"
