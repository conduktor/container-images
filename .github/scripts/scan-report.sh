#!/usr/bin/env bash
#
# Render one Markdown CVE report covering every scanned image, for a PR comment.
#
# Usage: scripts/scan-report.sh <scans-dir> [title]
#
# <scans-dir> holds one subdirectory per image, each containing trivy.json and
# grype.json — the layout `actions/download-artifact` produces from the
# `scans-<image>` artifacts the PR workflow uploads.
#
# Prints Markdown on stdout. Emits a report even when nothing was scanned, so the
# sticky comment gets updated rather than left showing a stale previous run.
#
# Requires: jq
set -euo pipefail

SCANS_DIR="${1:-}"
TITLE="${2:-Container image CVE report}"

[ -n "${SCANS_DIR}" ] || { echo "Usage: $0 <scans-dir> [title]" >&2; exit 2; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

printf '## %s\n' "${TITLE}"

found=0
shopt -s nullglob
for dir in "${SCANS_DIR}"/*/; do
  trivy="${dir}trivy.json"
  grype="${dir}grype.json"
  [ -f "${trivy}" ] && [ -f "${grype}" ] || continue

  # Artifacts are named scans-<image>; strip the prefix for the heading.
  label="$(basename "${dir}")"
  label="${label#scans-}"

  found=$((found + 1))
  printf '\n'
  SCAN_SUMMARY_FOOTER=0 "${SCRIPT_DIR}/scan-summary.sh" "${trivy}" "${grype}" "${label}"
done

if [ "${found}" = "0" ]; then
  printf '\nNo images were scanned in this run.\n'
  exit 0
fi

# The scanners-disagree explanation belongs once at the bottom, not after every
# image's table.
printf '\n<sub>Trivy counts fixed vulnerabilities only; Grype includes unfixed, '
printf 'so its totals run higher. Full reports are in the workflow artifacts.</sub>\n'
