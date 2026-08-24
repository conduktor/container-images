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
# Per-image sections come from cve_summary_section, the same function the
# single-image scan-summary.sh calls, so a PR comment and the nightly job
# summary cannot describe the same scan differently.
#
# Requires: jq
set -euo pipefail

SCANS_DIR="${1:-}"
TITLE="${2:-Container image CVE report}"

[ -n "${SCANS_DIR}" ] || { echo "Usage: $0 <scans-dir> [title]" >&2; exit 2; }

# shellcheck source-path=SCRIPTDIR
# shellcheck source=./cve-lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/cve-lib.sh"

printf '## %s\n' "${TITLE}"

found=0
shopt -s nullglob
for dir in "${SCANS_DIR}"/*/; do
  trivy="${dir}trivy.json"
  grype="${dir}grype.json"
  [ -f "${trivy}" ] || continue
  [ -f "${grype}" ] || continue

  label="$(basename "${dir}")"
  label="${label#scans-}"

  found=$((found + 1))
  printf '\n'
  cve_summary_section "${trivy}" "${grype}" "${label}"
done

if [ "${found}" = "0" ]; then
  printf '\nNo images were scanned in this run.\n'
  exit 0
fi

printf '\n'
cve_scanner_note
