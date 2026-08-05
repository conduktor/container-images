#!/usr/bin/env bash
#
# Tests for the pr-comment action's sticky-comment.sh.
# No network: the script is exercised through --dry-run.
# Silent on success; prints only failures.
set -euo pipefail

ACTION="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
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
has() {
  checks=$((checks + 1))
  case "$2" in *"$3"*) ;; *) fail "$1" ;; esac
}
hasnt() {
  checks=$((checks + 1))
  case "$2" in *"$3"*) fail "$1" ;; *) ;; esac
}

# --- pr-comment.sh ----------------------------------------------------------
printf 'hello report\n' > "${TMP}/body.md"

out="$(GH_REPO=acme/widgets PR_NUMBER=42 \
  "${ACTION}/sticky-comment.sh" --marker cve-report --body-file "${TMP}/body.md" --dry-run)"

has "dry-run names the repo and PR" "${out}" "acme/widgets#42"
has "body is embedded"              "${out}" "hello report"
# The marker is what makes the comment sticky; if it stops being emitted every
# run would create a new comment instead of editing one.
has "marker is emitted"             "${out}" "<!-- conduktor-ci:cve-report -->"

checks=$((checks + 1))
if GH_REPO=acme/widgets PR_NUMBER=42 \
   "${ACTION}/sticky-comment.sh" --body-file "${TMP}/body.md" --dry-run >/dev/null 2>&1; then
  fail "missing --marker should exit non-zero"
fi
checks=$((checks + 1))
if GH_REPO=acme/widgets \
   "${ACTION}/sticky-comment.sh" --marker x --body-file "${TMP}/body.md" --dry-run >/dev/null 2>&1; then
  fail "missing PR_NUMBER should exit non-zero"
fi
checks=$((checks + 1))
if GH_REPO=acme/widgets PR_NUMBER=42 \
   "${ACTION}/sticky-comment.sh" --marker x --body-file /nope.md --dry-run >/dev/null 2>&1; then
  fail "missing body file should exit non-zero"
fi

# Oversized bodies are truncated rather than rejected by the API mid-job.
head -c 70000 /dev/zero | tr '\0' 'x' > "${TMP}/huge.md"
huge="$(GH_REPO=acme/widgets PR_NUMBER=42 \
  "${ACTION}/sticky-comment.sh" --marker x --body-file "${TMP}/huge.md" --dry-run)"
has "oversized body is truncated" "${huge}" "Report truncated"

if [ "${fails}" -ne 0 ]; then
  echo "sticky-comment: ${fails}/${checks} failed" >&2
  exit 1
fi
echo "sticky-comment: ${checks} checks passed"
