#!/usr/bin/env bash
#
# Fixture tests for scripts/publish-badges.sh. Uses a local bare repo as the
# remote — no network, no credentials. Silent on success; failures print.
set -euo pipefail

SCRIPTS="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${SCRIPTS}/publish-badges.sh"
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

# Isolated identity + author so we don't inherit the developer's git config.
export GIT_USER_NAME="test-bot"
export GIT_USER_EMAIL="test-bot@example.com"
export GIT_AUTHOR_NAME="${GIT_USER_NAME}"
export GIT_AUTHOR_EMAIL="${GIT_USER_EMAIL}"
export GIT_COMMITTER_NAME="${GIT_USER_NAME}"
export GIT_COMMITTER_EMAIL="${GIT_USER_EMAIL}"

# Bare repo standing in for the GitHub remote.
BARE="${TMP}/remote.git"
git init -q --bare -b main "${BARE}"
export REMOTE_URL="file://${BARE}"

# A separate clone we use to inspect the badges branch after each run.
INSPECT="${TMP}/inspect"
git clone -q "${BARE}" "${INSPECT}" 2>/dev/null
git -C "${INSPECT}" config user.name  "${GIT_USER_NAME}"
git -C "${INSPECT}" config user.email "${GIT_USER_EMAIL}"

inspect_ls() {
  git -C "${INSPECT}" fetch -q origin badges
  git -C "${INSPECT}" ls-tree --name-only origin/badges | sort | tr '\n' ' ' | sed 's/ $//'
}

inspect_read() {
  git -C "${INSPECT}" fetch -q origin badges
  git -C "${INSPECT}" show "origin/badges:$1"
}

inspect_commits() {
  git -C "${INSPECT}" fetch -q origin badges
  git -C "${INSPECT}" rev-list --count origin/badges
}

# --- First run: branch does not exist yet, script creates it orphan --------
mkdir -p "${TMP}/src1"
echo '{"schemaVersion":1,"label":"trivy CVEs","message":"0 high / 1 total","color":"brightgreen"}' \
  > "${TMP}/src1/foo-trivy.json"
echo '{"schemaVersion":1,"label":"grype CVEs","message":"0 high / 2 total","color":"brightgreen"}' \
  > "${TMP}/src1/foo-grype.json"

"${SCRIPT}" "${TMP}/src1" badges > /dev/null 2>&1

assert_eq "first run: files"  "foo-grype.json foo-trivy.json" "$(inspect_ls)"
assert_eq "first run: content" '{"schemaVersion":1,"label":"trivy CVEs","message":"0 high / 1 total","color":"brightgreen"}' \
  "$(inspect_read foo-trivy.json)"
assert_eq "first run: commits" "1" "$(inspect_commits)"

# --- Second run: identical inputs must be a no-op --------------------------
"${SCRIPT}" "${TMP}/src1" badges > /dev/null 2>&1
assert_eq "no-op run: commits stay at 1" "1" "$(inspect_commits)"

# --- Third run: content changes, one image removed, one added --------------
mkdir -p "${TMP}/src2"
echo '{"schemaVersion":1,"label":"trivy CVEs","message":"1 high / 3 total","color":"orange"}' \
  > "${TMP}/src2/foo-trivy.json"
# note: foo-grype.json intentionally omitted — must be removed from the branch
echo '{"schemaVersion":1,"label":"trivy CVEs","message":"0 high / 0 total","color":"brightgreen"}' \
  > "${TMP}/src2/bar-trivy.json"

"${SCRIPT}" "${TMP}/src2" badges > /dev/null 2>&1

assert_eq "third run: files" "bar-trivy.json foo-trivy.json" "$(inspect_ls)"
assert_eq "third run: updated content" '{"schemaVersion":1,"label":"trivy CVEs","message":"1 high / 3 total","color":"orange"}' \
  "$(inspect_read foo-trivy.json)"
assert_eq "third run: commits advance" "2" "$(inspect_commits)"

# --- Refuse to blank the branch when src has no JSON -----------------------
mkdir -p "${TMP}/empty"
checks=$((checks + 1))
if "${SCRIPT}" "${TMP}/empty" badges >/dev/null 2>&1; then
  echo "  FAIL empty src-dir should exit non-zero" >&2
  fails=$((fails + 1))
fi
assert_eq "empty run: branch untouched" "2" "$(inspect_commits)"

# --- Missing src-dir must fail --------------------------------------------
checks=$((checks + 1))
if "${SCRIPT}" "${TMP}/does-not-exist" badges >/dev/null 2>&1; then
  echo "  FAIL missing src-dir should exit non-zero" >&2
  fails=$((fails + 1))
fi

# --- Missing REMOTE_URL must fail -----------------------------------------
checks=$((checks + 1))
if (unset REMOTE_URL; "${SCRIPT}" "${TMP}/src1" badges >/dev/null 2>&1); then
  echo "  FAIL missing REMOTE_URL should exit non-zero" >&2
  fails=$((fails + 1))
fi

if [ "${fails}" -ne 0 ]; then
  echo "publish-badges: ${fails}/${checks} failed" >&2
  exit 1
fi
echo "publish-badges: ${checks} checks passed"
