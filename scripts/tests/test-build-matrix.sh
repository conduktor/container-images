#!/usr/bin/env bash
#
# Tests for scripts/build-matrix.sh, including the real manifest + real image
# directories so an image that builds local APKs without getting a melange job
# (or vice versa) fails here rather than mid-nightly.
# Silent on success; prints only failures.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="${REPO_ROOT}/scripts/build-matrix.sh"
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

# --- fixture: three images, only two of which build local APKs --------------
cat > "${TMP}/images.json" <<'JSON'
[
  {"dir":"alpha","name":"alpha"},
  {"dir":"beta","name":"beta","dockerhub":"docker.io/org/beta"},
  {"dir":"gamma","name":"gamma"}
]
JSON
mkdir -p "${TMP}/images/alpha" "${TMP}/images/beta" "${TMP}/images/gamma"
: > "${TMP}/images/alpha/apko.yaml"
: > "${TMP}/images/beta/apko.yaml"
: > "${TMP}/images/gamma/apko.yaml"
# Deliberately created out of order, and mixing `melange.yaml` with prefixed
# names, to pin the sort.
: > "${TMP}/images/beta/melange.yaml"
: > "${TMP}/images/beta/melange-zeta.yaml"
: > "${TMP}/images/beta/melange-alpha.yaml"
: > "${TMP}/images/gamma/melange.yaml"

export IMAGES_MANIFEST="${TMP}/images.json"
export IMAGES_DIR="${TMP}/images"

out="$("${SCRIPT}")"

assert_eq "every image in .images" "alpha beta gamma" \
  "$(jq -r '[.images[].dir] | join(" ")' <<<"${out}")"
assert_eq "manifest fields kept" "docker.io/org/beta" \
  "$(jq -r '.images[] | select(.dir == "beta") | .dockerhub' <<<"${out}")"
assert_eq "melange flag false without configs" "false" \
  "$(jq -r '.images[] | select(.dir == "alpha") | .melange' <<<"${out}")"
assert_eq "melange flag true with configs" "true" \
  "$(jq -r '.images[] | select(.dir == "beta") | .melange' <<<"${out}")"
assert_eq "configs empty without configs" "" \
  "$(jq -r '.images[] | select(.dir == "alpha") | .configs' <<<"${out}")"
# `-` (0x2D) sorts before `.` (0x2E) under LC_ALL=C, so melange.yaml comes last.
assert_eq "configs byte-sorted" "melange-alpha.yaml,melange-zeta.yaml,melange.yaml" \
  "$(jq -r '.images[] | select(.dir == "beta") | .configs' <<<"${out}")"

# --- .apks: only APK-building images, one entry per arch --------------------
assert_eq "apks skips images without configs" "beta/aarch64 beta/x86_64 gamma/aarch64 gamma/x86_64" \
  "$(jq -r '[.apks[] | .dir + "/" + .arch] | sort | join(" ")' <<<"${out}")"
assert_eq "amd64 runner is standard GitHub-hosted" "ubuntu-latest" \
  "$(jq -r '.apks[] | select(.arch == "x86_64") | .runner' <<<"${out}" | head -n1)"
assert_eq "arm64 runner is standard GitHub-hosted" "ubuntu-24.04-arm" \
  "$(jq -r '.apks[] | select(.arch == "aarch64") | .runner' <<<"${out}" | head -n1)"
assert_eq "apks carry the config list" "melange-alpha.yaml,melange-zeta.yaml,melange.yaml" \
  "$(jq -r '.apks[] | select(.dir == "beta" and .arch == "x86_64") | .configs' <<<"${out}")"
assert_eq "no runner label is self-hosted" "true" \
  "$(jq -r '[.apks[].runner] | all(startswith("ubuntu-"))' <<<"${out}")"

# --- subset + arch selection ------------------------------------------------
sub="$("${SCRIPT}" alpha,beta)"
assert_eq "subset filters .images" "alpha beta" \
  "$(jq -r '[.images[].dir] | join(" ")' <<<"${sub}")"
assert_eq "subset filters .apks" "beta beta" \
  "$(jq -r '[.apks[].dir] | join(" ")' <<<"${sub}")"

one="$("${SCRIPT}" "" x86_64)"
assert_eq "arch argument narrows .apks" "x86_64 x86_64" \
  "$(jq -r '[.apks[].arch] | join(" ")' <<<"${one}")"
assert_eq "arch argument leaves .images alone" "3" \
  "$(jq -r '.images | length' <<<"${one}")"

# apko names architectures amd64/arm64 and melange x86_64/aarch64. Both come
# from this script so a workflow cannot ask apko for an arch whose APKs were
# never built.
assert_eq "apko arches translated, both" "amd64,arm64" \
  "$(jq -r '.apko_arches' <<<"${out}")"
assert_eq "apko arches translated, one" "amd64" \
  "$(jq -r '.apko_arches' <<<"${one}")"
assert_eq "melange arches echoed back" "x86_64" \
  "$(jq -r '.arches' <<<"${one}")"
assert_eq "arch order is preserved" "arm64,amd64" \
  "$(jq -r '.apko_arches' <<<"$("${SCRIPT}" "" aarch64,x86_64)")"

# --- failure modes ----------------------------------------------------------
checks=$((checks + 1))
if "${SCRIPT}" alpha,nope >/dev/null 2>&1; then
  fail "unknown image should exit non-zero (delegated to image-matrix.sh)"
fi

checks=$((checks + 1))
if "${SCRIPT}" "" riscv64 >/dev/null 2>&1; then
  fail "an arch with no runner mapping should exit non-zero"
fi

# Capture rather than pipe: under `set -o pipefail` a non-zero exit would make
# an `if ... | grep` condition false no matter what the message said.
err="$("${SCRIPT}" "" riscv64 2>&1 >/dev/null || true)"
checks=$((checks + 1))
case "${err}" in
  *riscv64*) ;;
  *) fail "error should name the unmapped arch, got: ${err}" ;;
esac

# --- the real repo ----------------------------------------------------------
unset IMAGES_MANIFEST IMAGES_DIR
real="$("${SCRIPT}")"

assert_eq "real matrices are non-empty" "true" \
  "$(jq -r '(.images | length) > 0 and (.apks | length) > 0' <<<"${real}")"

# The two are derived from the same on-disk state, so they cannot disagree about
# which images build local APKs.
assert_eq "melange flag matches apks membership" "true" \
  "$(jq -r '
    ([.images[] | select(.melange) | .dir] | unique) as $flagged
    | ([.apks[].dir] | unique) as $fanned
    | $flagged == $fanned
  ' <<<"${real}")"

# Every named config must exist, or melange-build's multi-config silently drops it.
while IFS=$'\t' read -r dir configs; do
  [ -n "${configs}" ] || continue
  IFS=',' read -ra files <<<"${configs}"
  for f in "${files[@]}"; do
    checks=$((checks + 1))
    [ -f "${REPO_ROOT}/images/${dir}/${f}" ] \
      || fail "matrix lists images/${dir}/${f} but it does not exist"
  done
done < <(jq -r '.images[] | [.dir, .configs] | @tsv' <<<"${real}")

# Both arches, so a nightly can never publish a multi-arch index from one arch's
# packages.
assert_eq "each APK-building image gets both arches" "true" \
  "$(jq -r '
    [.apks[] | .dir] | group_by(.) | all(length == 2)
  ' <<<"${real}")"

# The publish job collects APKs with `pattern: apks-<dir>-*`, so one image dir
# being a `<other>-` prefixed extension of another would silently pull the wrong
# image's packages into the build.
assert_eq "no image dir is a dash-prefix of another" "true" \
  "$(jq -r '
    [.images[].dir] as $dirs
    | all($dirs[]; . as $a | all($dirs[]; . == $a or (startswith($a + "-") | not)))
  ' <<<"${real}")"

if [ "${fails}" -ne 0 ]; then
  echo "build-matrix: ${fails}/${checks} failed" >&2
  exit 1
fi
echo "build-matrix: ${checks} checks passed"
