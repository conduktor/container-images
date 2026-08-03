#!/usr/bin/env bash
#
# Tests for scripts/image-matrix.sh, including the real manifest so a malformed
# or out-of-sync images/images.json fails here rather than mid-nightly.
# Silent on success; prints only failures.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="${REPO_ROOT}/scripts/image-matrix.sh"
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

fail() {
  fails=$((fails + 1))
  echo "  FAIL $1" >&2
}

cat > "${TMP}/images.json" <<'JSON'
[
  {"dir":"alpha","name":"alpha"},
  {"dir":"beta","name":"beta-published"},
  {"dir":"gamma","name":"gamma","dockerhub":"docker.io/org/gamma"}
]
JSON
export IMAGES_MANIFEST="${TMP}/images.json"

dirs() { "${SCRIPT}" "$@" | jq -r '[.[].dir] | join(" ")'; }

assert_eq "no arg = every image"  "alpha beta gamma" "$(dirs)"
assert_eq "single subset"         "beta"             "$(dirs beta)"
assert_eq "multi subset"          "alpha gamma"      "$(dirs alpha,gamma)"
assert_eq "manifest order wins"   "alpha gamma"      "$(dirs gamma,alpha)"
assert_eq "trailing comma"        "alpha"            "$(dirs "alpha,")"
assert_eq "published name kept"   "beta-published"   "$("${SCRIPT}" beta | jq -r '.[0].name')"
assert_eq "dockerhub carried"     "docker.io/org/gamma" "$("${SCRIPT}" gamma | jq -r '.[0].dockerhub')"
assert_eq "absent dockerhub null" "null"             "$("${SCRIPT}" alpha | jq -r '.[0].dockerhub')"

checks=$((checks + 1))
if "${SCRIPT}" alpha,nope >/dev/null 2>&1; then
  fail "unknown image should exit non-zero"
fi

# Capture rather than pipe: under `set -o pipefail` the script's exit 2 would
# make an `if ... | grep` condition false no matter what the message said.
err="$("${SCRIPT}" alpha,nope 2>&1 >/dev/null || true)"
checks=$((checks + 1))
case "${err}" in
  *nope*) ;;
  *) fail "error should name the offending image, got: ${err}" ;;
esac

# --- the real manifest -----------------------------------------------------
unset IMAGES_MANIFEST
real="$("${SCRIPT}")"

assert_eq "every entry has dir+name" "true" \
  "$(jq -r 'all(.dir != null and .name != null)' <<<"${real}")"
assert_eq "dirs are unique" "true" \
  "$(jq -r '([.[].dir] | length) == ([.[].dir] | unique | length)' <<<"${real}")"

for dir in $(jq -r '.[].dir' <<<"${real}"); do
  checks=$((checks + 1))
  [ -f "${REPO_ROOT}/images/${dir}/apko.yaml" ] \
    || fail "manifest lists '${dir}' but images/${dir}/apko.yaml is missing"
done

# An image directory missing from the manifest would silently never be built.
for d in "${REPO_ROOT}"/images/*/; do
  dir="$(basename "${d}")"
  checks=$((checks + 1))
  jq -e --arg d "${dir}" 'any(.dir == $d)' <<<"${real}" >/dev/null \
    || fail "images/${dir} exists on disk but is not in images/images.json"
done

if [ "${fails}" -ne 0 ]; then
  echo "image-matrix: ${fails}/${checks} failed" >&2
  exit 1
fi
echo "image-matrix: ${checks} checks passed"
