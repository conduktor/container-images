#!/usr/bin/env bash
#
# Render one Markdown CVE report covering every scanned image, for a PR comment.
#
# Usage: scripts/scan-report.sh <scans-dir> [title]
#
# <scans-dir> holds one scans-<image>/ per image with trivy.json + grype.json —
# the layout download-artifact produces. Always emits something, so the sticky
# comment refreshes instead of showing a stale run.
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

printf '\n<sub>Trivy counts fixed vulnerabilities only; Grype includes unfixed, '
printf 'so its totals run higher. Full reports are in the workflow artifacts.</sub>\n'
