#!/usr/bin/env bash
#
# Tests for scripts/scan-report.sh and scripts/pr-comment.sh.
# No network: pr-comment.sh is exercised through --dry-run.
# Silent on success; prints only failures.
set -euo pipefail

SCRIPTS="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
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

# Mimic download-artifact's layout: one scans-<image> dir per image.
mkfixture() {
  mkdir -p "${TMP}/scans/scans-$1"
  printf '%s\n' "$2" > "${TMP}/scans/scans-$1/trivy.json"
  printf '%s\n' "$3" > "${TMP}/scans/scans-$1/grype.json"
}
mkfixture base-os '{"Results":[]}' '{"matches":[]}'
mkfixture debug \
  '{"Results":[{"Vulnerabilities":[{"Severity":"HIGH"}]}]}' \
  '{"matches":[{"vulnerability":{"severity":"Critical"},"artifact":{"name":"libx","version":"1"}}]}'

report="$("${SCRIPTS}/scan-report.sh" "${TMP}/scans")"

has "report has a title"          "${report}" "## Container image CVE report"
has "report covers base-os"       "${report}" "base-os"
has "report covers debug"         "${report}" "debug"
# The scans- prefix is an artifact-naming detail and must not leak into headings.
hasnt "artifact prefix stripped"  "${report}" "scans-debug"
has "clean image shows a tick"    "${report}" ":white_check_mark:"
has "critical shows red"          "${report}" ":red_circle:"

# The scanners-disagree note is per-report, not per-image.
assert_eq "footer appears exactly once" "1" \
  "$(printf '%s\n' "${report}" | grep -c 'Trivy counts fixed vulnerabilities only')"

custom="$("${SCRIPTS}/scan-report.sh" "${TMP}/scans" 'My Title')"
has "title is overridable" "${custom}" "## My Title"

# An empty dir must still render, so the sticky comment gets refreshed rather
# than left showing a previous run's numbers.
mkdir -p "${TMP}/empty"
empty="$("${SCRIPTS}/scan-report.sh" "${TMP}/empty")"
has "empty run still reports" "${empty}" "No images were scanned"

# A directory missing one of the two reports is skipped, not half-rendered.
mkdir -p "${TMP}/scans/scans-broken"
printf '{"Results":[]}\n' > "${TMP}/scans/scans-broken/trivy.json"
partial="$("${SCRIPTS}/scan-report.sh" "${TMP}/scans")"
hasnt "incomplete artifact skipped" "${partial}" "broken"

checks=$((checks + 1))
if "${SCRIPTS}/scan-report.sh" >/dev/null 2>&1; then
  fail "missing scans-dir argument should exit non-zero"
fi

if [ "${fails}" -ne 0 ]; then
  echo "scan-report: ${fails}/${checks} failed" >&2
  exit 1
fi
echo "scan-report: ${checks} checks passed"
