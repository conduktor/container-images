#!/usr/bin/env bash
#
# Tests for scripts/melange-index.sh. Uses a stub melange (MELANGE_BIN) that
# records its arguments, so this runs anywhere — no melange, no network, no
# signing. What the real melange does with those arguments is covered by the
# nightly itself; what matters here is that every arch directory gets indexed,
# under one key, with the stale index dropped first.
# Silent on success; prints only failures.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="${REPO_ROOT}/scripts/melange-index.sh"
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

# --- stub melange -----------------------------------------------------------
# Logs every invocation to ${MELANGE_LOG}, and mimics the two subcommands the
# script drives: keygen writes a keypair, index writes its --output file.
STUB="${TMP}/bin/melange"
mkdir -p "${TMP}/bin"
cat > "${STUB}" <<'STUBEOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "${MELANGE_LOG}"
case "${1:-}" in
  keygen)
    printf 'private\n' > "$2"
    printf 'public\n' > "$2.pub"
    ;;
  index)
    out=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --output) out="$2"; shift ;;
      esac
      shift
    done
    printf 'INDEX\n' > "${out}"
    ;;
esac
STUBEOF
chmod +x "${STUB}"
export MELANGE_BIN="${STUB}"

reset_fixture() { # reset_fixture <arch>...
  rm -rf "${TMP}/images" "${TMP}/log"
  export MELANGE_LOG="${TMP}/log"
  : > "${MELANGE_LOG}"
  mkdir -p "${TMP}/images/img"
  : > "${TMP}/images/img/apko.yaml"
  for arch in "$@"; do
    mkdir -p "${TMP}/images/img/packages/${arch}"
    printf 'apk\n' > "${TMP}/images/img/packages/${arch}/thing-1.0.0-r0.apk"
  done
}
export IMAGES_DIR="${TMP}/images"

# --- one arch ---------------------------------------------------------------
reset_fixture x86_64
"${SCRIPT}" img > "${TMP}/out" 2>&1 || fail "single-arch run should succeed"

assert_eq "generates the ephemeral key when absent" "1" \
  "$(grep -c '^keygen melange.rsa$' "${MELANGE_LOG}")"
assert_eq "pub key lands where apko.yaml's keyring points" "public" \
  "$(cat "${TMP}/images/img/melange.rsa.pub" 2>/dev/null || echo MISSING)"
assert_eq "indexes once" "1" "$(grep -c '^index ' "${MELANGE_LOG}")"
assert_eq "index is written into the arch directory" "INDEX" \
  "$(cat "${TMP}/images/img/packages/x86_64/APKINDEX.tar.gz" 2>/dev/null || echo MISSING)"

index_args="$(grep '^index ' "${MELANGE_LOG}")"
for expected in \
  "--output packages/x86_64/APKINDEX.tar.gz" \
  "--arch x86_64" \
  "--signing-key melange.rsa" \
  "packages/x86_64/thing-1.0.0-r0.apk"; do
  checks=$((checks + 1))
  case "${index_args}" in
    *"${expected}"*) ;;
    *) fail "index args missing '${expected}', got: ${index_args}" ;;
  esac
done

# --- both arches, one key ---------------------------------------------------
reset_fixture x86_64 aarch64
"${SCRIPT}" img > "${TMP}/out" 2>&1 || fail "multi-arch run should succeed"

assert_eq "one index per arch" "2" "$(grep -c '^index ' "${MELANGE_LOG}")"
assert_eq "one key for every arch" "1" "$(grep -c '^keygen ' "${MELANGE_LOG}")"
assert_eq "each arch indexed under its own arch flag" "--arch aarch64 --arch x86_64" \
  "$(grep -o -e '--arch [a-z0-9_]*' "${MELANGE_LOG}" | sort | paste -sd' ' -)"

# --- an existing key is reused, not regenerated ------------------------------
reset_fixture x86_64
printf 'preexisting\n' > "${TMP}/images/img/melange.rsa"
printf 'preexisting-pub\n' > "${TMP}/images/img/melange.rsa.pub"
"${SCRIPT}" img > "${TMP}/out" 2>&1 || fail "run with an existing key should succeed"
assert_eq "existing key is not regenerated" "0" "$(grep -c '^keygen ' "${MELANGE_LOG}")"
assert_eq "existing key is left untouched" "preexisting" \
  "$(cat "${TMP}/images/img/melange.rsa")"

# --- a stale index from another key's build is dropped, not merged -----------
reset_fixture x86_64
printf 'STALE-FROM-ANOTHER-KEY\n' > "${TMP}/images/img/packages/x86_64/APKINDEX.tar.gz"
"${SCRIPT}" img > "${TMP}/out" 2>&1 || fail "run over a stale index should succeed"
assert_eq "stale index replaced" "INDEX" \
  "$(cat "${TMP}/images/img/packages/x86_64/APKINDEX.tar.gz")"
checks=$((checks + 1))
case "$(grep '^index ' "${MELANGE_LOG}")" in
  *--merge*|*--source*) fail "the stale index must not be merged in" ;;
esac
# A stale index must never be handed to melange as an input package either.
checks=$((checks + 1))
case "$(grep '^index ' "${MELANGE_LOG}")" in
  *"APKINDEX.tar.gz packages"*) fail "APKINDEX passed as an input package" ;;
esac

# --- failure modes ----------------------------------------------------------
reset_fixture x86_64
checks=$((checks + 1))
if "${SCRIPT}" >/dev/null 2>&1; then
  fail "no image-dir argument should exit non-zero"
fi

checks=$((checks + 1))
if "${SCRIPT}" nosuchimage >/dev/null 2>&1; then
  fail "unknown image directory should exit non-zero"
fi

# No packages/ at all: the artifact download produced nothing.
rm -rf "${TMP}/images/img/packages"
checks=$((checks + 1))
if "${SCRIPT}" img >/dev/null 2>&1; then
  fail "missing packages/ should exit non-zero rather than publish without APKs"
fi

# An arch directory that arrived empty is the same failure, one level down.
reset_fixture x86_64
mkdir -p "${TMP}/images/img/packages/aarch64"
checks=$((checks + 1))
if "${SCRIPT}" img >/dev/null 2>&1; then
  fail "an arch directory with no APKs should exit non-zero"
fi
err="$("${SCRIPT}" img 2>&1 >/dev/null || true)"
checks=$((checks + 1))
case "${err}" in
  *aarch64*) ;;
  *) fail "error should name the empty arch directory, got: ${err}" ;;
esac

if [ "${fails}" -ne 0 ]; then
  echo "melange-index: ${fails}/${checks} failed" >&2
  exit 1
fi
echo "melange-index: ${checks} checks passed"
