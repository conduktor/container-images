#!/usr/bin/env bash
#
# Render a Markdown CVE summary for one image, for $GITHUB_STEP_SUMMARY.
#
# Usage: scripts/scan-summary.sh <trivy.json> <grype.json> <image-label>
#
# The section itself is cve_summary_section in cve-lib.sh, so this and the
# multi-image scan-report.sh render from one implementation.
#
# Requires: jq
set -euo pipefail

if [ $# -lt 3 ]; then
  echo "Usage: $0 <trivy.json> <grype.json> <image-label>" >&2
  exit 2
fi

# shellcheck source-path=SCRIPTDIR
# shellcheck source=./cve-lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/cve-lib.sh"

cve_summary_section "$1" "$2" "$3"
printf '\n'
cve_scanner_note
