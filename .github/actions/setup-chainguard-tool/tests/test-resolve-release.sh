#!/usr/bin/env bash
#
# Tests for setup-chainguard-tool's resolve-release.sh.
# No network: `gh` is stubbed on PATH.
#
# The arch mapping is the point: it only runs on the runner it resolves for, so an
# amd64-only assumption passes every local check and every x86_64 job, and fails
# exactly one thing — the aarch64 `apks` job in the nightly.
# Silent on success; prints only failures.
set -euo pipefail

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/scripts/resolve-release.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

checks=0
fails=0
fail() { fails=$((fails + 1)); echo "  FAIL $1" >&2; }
assert_eq() {
  checks=$((checks + 1))
  if [ "$2" != "$3" ]; then
    echo "  FAIL $1: want '$2', got '$3'" >&2
    fails=$((fails + 1))
  fi
}

mkdir -p "${TMP}/bin"
cat > "${TMP}/bin/gh" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  *"git/ref/tags/"*) echo "${STUB_OBJECT_TYPE:-commit} ${STUB_SHA:-c0ffee1111111111111111111111111111111111}" ;;
  *"git/tags/"*)     echo "${STUB_DEREF_SHA:-deadbeef2222222222222222222222222222222}" ;;
  *"release view"*)  echo "${STUB_LATEST_TAG:-v9.9.9}" ;;
  *) echo "unexpected gh call: $*" >&2; exit 1 ;;
esac
STUB
chmod +x "${TMP}/bin/gh"
export PATH="${TMP}/bin:${PATH}"

# Echoes the script's `key=value` outputs. The status is returned explicitly:
# errexit is suppressed inside an `if` condition, so the trailing `cat` would
# otherwise report success for a failed script.
resolve() {
  local out="${TMP}/out" rc=0
  : > "${out}"
  env GITHUB_OUTPUT="${out}" \
      RUNNER_TOOL_CACHE="${TMP}/tool-cache" \
      TOOL="${TOOL:-melange}" \
      REPOSITORY="${REPOSITORY:-chainguard-dev/melange}" \
      VERSION="${VERSION:-v0.41.1}" \
      EXPECTED_COMMIT_SHA="${EXPECTED_COMMIT_SHA:-}" \
      INSTALL_DIR_INPUT="${INSTALL_DIR_INPUT:-}" \
      "$@" "${SCRIPT}" >/dev/null || rc=$?
  cat "${out}"
  return "${rc}"
}
value() { sed -n "s/^$2=//p" <<<"$1"; }

# --- arch mapping -----------------------------------------------------------
# Both spellings reach the script: GitHub sets RUNNER_ARCH=X64/ARM64, a local run
# falls back to uname's x86_64/aarch64.
for arch in X64 x86_64 amd64; do
  out="$(resolve RUNNER_ARCH="${arch}")"
  assert_eq "${arch} resolves to amd64" "amd64" "$(value "${out}" arch)"
  assert_eq "${arch} picks the amd64 archive" \
    "melange_0.41.1_linux_amd64.tar.gz" "$(value "${out}" archive)"
done

for arch in ARM64 aarch64 arm64; do
  out="$(resolve RUNNER_ARCH="${arch}")"
  assert_eq "${arch} resolves to arm64" "arm64" "$(value "${out}" arch)"
  assert_eq "${arch} picks the arm64 archive" \
    "melange_0.41.1_linux_arm64.tar.gz" "$(value "${out}" archive)"
done

# Per-arch, so a cached amd64 binary can never be served to an arm64 job.
out="$(resolve RUNNER_ARCH=ARM64)"
assert_eq "install dir is arch-scoped" \
  "${TMP}/tool-cache/melange/v0.41.1/arm64" "$(value "${out}" install-dir)"

checks=$((checks + 1))
if resolve RUNNER_ARCH=ARMV7 >/dev/null 2>&1; then
  fail "an arch with no release archive should exit non-zero"
fi

# --- version + tag resolution -----------------------------------------------
out="$(TOOL=apko REPOSITORY=chainguard-dev/apko VERSION=1.2.30 resolve RUNNER_ARCH=X64)"
assert_eq "a version without the v still tags"    "v1.2.30" "$(value "${out}" tag)"
assert_eq "version output drops the v"            "1.2.30"  "$(value "${out}" version)"
assert_eq "tool name drives the archive prefix" \
  "apko_1.2.30_linux_amd64.tar.gz" "$(value "${out}" archive)"

out="$(VERSION=latest resolve RUNNER_ARCH=X64 STUB_LATEST_TAG=v1.2.31)"
assert_eq "latest resolves through gh release view" "v1.2.31" "$(value "${out}" tag)"

out="$(resolve RUNNER_ARCH=X64 STUB_OBJECT_TYPE=commit STUB_SHA=abc1234567890def1234567890abcdef12345678)"
assert_eq "a lightweight tag is used as-is" \
  "abc1234567890def1234567890abcdef12345678" "$(value "${out}" commit-sha)"

# An annotated tag's ref points at the tag object, not the commit, so the pin
# would otherwise be compared against a sha `uses:` never sees.
out="$(resolve RUNNER_ARCH=X64 STUB_OBJECT_TYPE=tag \
  STUB_DEREF_SHA=99991234567890def1234567890abcdef1234567)"
assert_eq "an annotated tag is dereferenced" \
  "99991234567890def1234567890abcdef1234567" "$(value "${out}" commit-sha)"

# --- pins -------------------------------------------------------------------
checks=$((checks + 1))
if ! EXPECTED_COMMIT_SHA=abc1234 resolve RUNNER_ARCH=X64 \
     STUB_SHA=abc1234567890def1234567890abcdef12345678 >/dev/null 2>&1; then
  fail "an abbreviated expected-commit-sha should match its full sha"
fi

checks=$((checks + 1))
if EXPECTED_COMMIT_SHA=0000000 resolve RUNNER_ARCH=X64 >/dev/null 2>&1; then
  fail "a mismatched expected-commit-sha should exit non-zero"
fi

# --- explicit install dir ---------------------------------------------------
out="$(INSTALL_DIR_INPUT=/usr/local/bin resolve RUNNER_ARCH=X64)"
assert_eq "an explicit install-dir wins" "/usr/local/bin" "$(value "${out}" install-dir)"

if [ "${fails}" -ne 0 ]; then
  echo "resolve-release: ${fails}/${checks} failed" >&2
  exit 1
fi
echo "resolve-release: ${checks} checks passed"
