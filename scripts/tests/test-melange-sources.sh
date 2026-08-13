#!/usr/bin/env bash
#
# Tests for scripts/melange-sources.sh. Fully offline: the script only reads
# `expected-sha256` and checks the cache for it, and the one step that would
# reach the network (`melange update-cache`) is stubbed via MELANGE_BIN so the
# missing-source path can be exercised without downloading anything.
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
assert_contains() {
  checks=$((checks + 1))
  case "$3" in
    *"$2"*) ;;
    *) echo "  FAIL $1: '$3' does not contain '$2'" >&2; fails=$((fails + 1)) ;;
  esac
}
fail() { fails=$((fails + 1)); echo "  FAIL $1" >&2; }

# Fixture image dir, pointed at via IMAGES_DIR so the real configs aren't needed.
# The URIs use every templating form we ship — package.version, vars, and a
# var-transform — precisely because the script must NOT need to resolve any of
# them. If it ever starts parsing URIs again, these fixtures make that visible.
mkdir -p "${TMP}/images/demo"
cat > "${TMP}/images/demo/melange.yaml" <<'YAML'
package:
  name: demo
  version: 1.2.3
vars:
  flavour: "2.13"
var-transforms:
  - from: ${{package.version}}
    match: ^(\d+\.\d+)\.\d+$
    replace: "$1"
    to: branch
pipeline:
  - runs: echo no fetch here
  - uses: fetch
    with:
      uri: https://example.invalid/${{vars.branch}}/demo-${{package.version}}-${{vars.flavour}}.tgz
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

# --- listing -----------------------------------------------------------------

out="$("${SCRIPT}" demo)"

assert_eq "every pinned hash is listed, once per config" "2" \
  "$(printf '%s\n' "${out}" | grep -c .)"
assert_eq "listing is hash<TAB>config" \
  "$(printf 'aaaa\tmelange.yaml\nbbbb\tmelange-extra.yaml')" \
  "${out}"

# Glob order is melange-extra.yaml before melange.yaml, so an unsorted listing
# would come out the other way round — and this listing is the CI cache key, so
# identical inputs must key identically on every machine.
assert_eq "listing is sorted, not in glob order" \
  "$(printf '%s\n' "${out}" | LC_ALL=C sort)" "${out}"

# No URI resolution means no way for an unexpanded ${{...}} to reach the output —
# which is what used to hash into a stable-but-wrong CI cache key.
subst="\${{" # escaped so shellcheck sees no unexpanded expression (SC2016)
checks=$((checks + 1))
case "${out}" in *"${subst}"*) fail "a substitution leaked into the listing" ;; esac
checks=$((checks + 1))
case "${out}" in *'example.invalid'*) fail "listing must not contain URLs at all" ;; esac
# Non-fetch pipeline steps must not appear.
checks=$((checks + 1))
case "${out}" in *'no fetch here'*) fail "non-fetch steps must be ignored" ;; esac

# The listing is the cache key, so it must be stable across runs.
assert_eq "listing is deterministic" "${out}" "$("${SCRIPT}" demo)"

# --- prefetch, everything already cached -------------------------------------

cache="${TMP}/cache"
mkdir -p "${cache}"
: > "${cache}/sha256:aaaa"
: > "${cache}/sha256:bbbb"

# A stub `melange` that fails loudly: on a warm cache it must never be called,
# because update-cache re-downloads every source in a config unconditionally.
stub="${TMP}/bin"
mkdir -p "${stub}"
cat > "${stub}/melange" <<STUB
#!/usr/bin/env bash
echo "STUB melange \$*" >> "${TMP}/melange-calls"
# Emulate update-cache: write each pinned artifact into the cache dir.
cache_dir=""
for a in "\$@"; do
  case "\${prev:-}" in --cache-dir) cache_dir="\${a}" ;; esac
  prev="\${a}"
done
config="\${*: -1}"
for sha in \$(yq -r '.pipeline[]? | select(.uses == "fetch") | .with["expected-sha256"] // ""' "\${config}" | grep -v '^\$'); do
  : > "\${cache_dir}/sha256:\${sha}"
done
STUB
chmod +x "${stub}/melange"
# Injected by name rather than by rewriting PATH: the devshell has a real melange
# on PATH, so a PATH-based stub could not express "melange is absent" below.
export MELANGE_BIN="${stub}/melange"
: > "${TMP}/melange-calls"

pre="$("${SCRIPT}" demo --prefetch "${cache}")"
assert_eq "already-cached sources are reported as cached" "2" \
  "$(printf '%s\n' "${pre}" | grep -c '^cached')"
assert_contains "a fully warm cache says so" "all sources already cached" "${pre}"
assert_eq "a warm cache never invokes melange" "0" \
  "$(grep -c . "${TMP}/melange-calls" || true)"

# --- prefetch with a missing source ------------------------------------------

rm -f "${cache}/sha256:bbbb"
: > "${TMP}/melange-calls"
pre="$("${SCRIPT}" demo --prefetch "${cache}")"

assert_contains "a missing source triggers a fetch" "fetch   melange-extra.yaml" "${pre}"
assert_eq "only the config that is missing something is fetched" "1" \
  "$(grep -c 'STUB melange' "${TMP}/melange-calls")"
assert_contains "melange is called as update-cache" "update-cache" \
  "$(cat "${TMP}/melange-calls")"
assert_contains "the cache dir is passed through" "--cache-dir ${cache}" \
  "$(cat "${TMP}/melange-calls")"
checks=$((checks + 1))
[ -f "${cache}/sha256:bbbb" ] || fail "the missing source should be in the cache afterwards"

# --- a pin that upstream no longer serves ------------------------------------
# melange writes each artifact under the hash it actually got, so a stale pin
# leaves the expected filename absent. That must fail here, not silently produce
# a build that fetches at build time.

cat > "${TMP}/images/demo/melange-stale.yaml" <<'YAML'
package:
  name: stale
  version: 1.0.0
pipeline:
  - uses: fetch
    with:
      uri: https://example.invalid/stale.tgz
      expected-sha256: dddd
YAML
# Stub that "downloads" something with a different hash than pinned.
cat > "${stub}/melange" <<STUB
#!/usr/bin/env bash
prev=""
for a in "\$@"; do
  case "\${prev}" in --cache-dir) : > "\${a}/sha256:somethingelse" ;; esac
  prev="\${a}"
done
STUB
chmod +x "${stub}/melange"

checks=$((checks + 1))
if "${SCRIPT}" demo --prefetch "${cache}" >/dev/null 2>&1; then
  fail "a pin upstream no longer serves should exit non-zero"
fi
err="$("${SCRIPT}" demo --prefetch "${cache}" 2>&1 || true)"
assert_contains "the stale pin names the config" "melange-stale.yaml" "${err}"
assert_contains "the stale pin is explained" "does not match what upstream served" "${err}"
rm -f "${TMP}/images/demo/melange-stale.yaml"

# --- prefetch without melange ------------------------------------------------
# Listing must keep working with no melange on PATH; only prefetching needs it.

rm -f "${cache}/sha256:bbbb"
export MELANGE_BIN="${TMP}/definitely-not-installed/melange"
checks=$((checks + 1))
if "${SCRIPT}" demo --prefetch "${cache}" >/dev/null 2>&1; then
  fail "prefetching a missing source without melange should exit non-zero"
fi
err="$("${SCRIPT}" demo --prefetch "${cache}" 2>&1 || true)"
assert_contains "the missing melange is explained" "melange not found" "${err}"
checks=$((checks + 1))
if ! "${SCRIPT}" demo >/dev/null 2>&1; then
  fail "listing must not require melange"
fi
unset MELANGE_BIN

# --- misc --------------------------------------------------------------------

# An image with no melange configs is not an error — base-os has none.
mkdir -p "${TMP}/images/plain"
checks=$((checks + 1))
if ! "${SCRIPT}" plain >/dev/null 2>&1; then
  fail "an image without melange configs should exit 0"
fi
assert_eq "no configs means no sources" "" "$("${SCRIPT}" plain)"

checks=$((checks + 1))
if "${SCRIPT}" >/dev/null 2>&1; then fail "missing image-dir should exit non-zero"; fi
checks=$((checks + 1))
if "${SCRIPT}" demo --bogus "${cache}" >/dev/null 2>&1; then
  fail "an unknown option should exit non-zero"
fi
checks=$((checks + 1))
if "${SCRIPT}" demo --prefetch >/dev/null 2>&1; then
  fail "--prefetch without a cache dir should exit non-zero"
fi
checks=$((checks + 1))
if "${SCRIPT}" nosuchimage >/dev/null 2>&1; then
  fail "an unknown image dir should exit non-zero"
fi

if [ "${fails}" -gt 0 ]; then
  echo "melange-sources: ${fails}/${checks} failed" >&2
  exit 1
fi
echo "melange-sources: ${checks} checks passed"
