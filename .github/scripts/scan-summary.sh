#!/usr/bin/env bash
#
# Render a Markdown CVE summary for one image, for $GITHUB_STEP_SUMMARY.
#
# Usage: scripts/scan-summary.sh <trivy.json> <grype.json> <image-label>
#
# Prints Markdown on stdout. Deliberately reports both scanners side by side:
# they legitimately disagree here, and hiding that has bitten us — Trivy cannot
# see content we ship via melange (it attributes those files to an APK package
# with no advisories), while Grype walks the filesystem and does. A row where
# Grype is high and Trivy is 0 is expected, not a bug.
#
# Requires: jq
set -euo pipefail

if [ $# -lt 3 ]; then
  echo "Usage: $0 <trivy.json> <grype.json> <image-label>" >&2
  exit 2
fi

TRIVY_JSON="$1"
GRYPE_JSON="$2"
LABEL="$3"

# shellcheck source-path=SCRIPTDIR
# shellcheck source=./cve-counts.sh
. "$(dirname "${BASH_SOURCE[0]}")/cve-counts.sh"

cve_counts "${TRIVY_JSON}" "${GRYPE_JSON}"

# Exported so scan-report.sh can print it once for a multi-image report.
scan_summary_footer() {
  printf '\n<sub>Trivy counts fixed vulnerabilities only; Grype includes unfixed, '
  printf 'so its totals run higher. Full reports are in the workflow artifacts.</sub>\n'
}

verdict() {
  if [ "$1" -gt 0 ]; then printf ':red_circle: %s' "$1"
  elif [ "$2" -gt 0 ]; then printf ':warning: %s' "$2"
  else printf ':white_check_mark: 0'
  fi
}

cat <<EOF
### \`${LABEL}\`

| Scanner | Critical | Critical+High | Total |
|---------|----------|---------------|-------|
| Trivy | $(verdict "${CVE_TRIVY_CRITICAL}" 0) | $(verdict "${CVE_TRIVY_CRITICAL}" "${CVE_TRIVY_HIGH}") | ${CVE_TRIVY_TOTAL} |
| Grype | $(verdict "${CVE_GRYPE_CRITICAL}" 0) | $(verdict "${CVE_GRYPE_CRITICAL}" "${CVE_GRYPE_HIGH}") | ${CVE_GRYPE_TOTAL} |
EOF

# Top offenders are what make the summary actionable — a count alone sends the
# reader off to download the artifact.
top="$(jq -r '
  [ .matches[]?
    | select((.vulnerability.severity | ascii_upcase) == "CRITICAL"
          or (.vulnerability.severity | ascii_upcase) == "HIGH")
    | "\(.artifact.name) \(.artifact.version)" ]
  | group_by(.) | map({k: .[0], n: length}) | sort_by(-.n) | .[:8][]
  | "| `\(.k)` | \(.n) |"
' "${GRYPE_JSON}")"

if [ -n "${top}" ]; then
  printf '\n<details><summary>Grype critical+high by component</summary>\n\n'
  printf '| Component | Findings |\n|-----------|----------|\n%s\n' "${top}"
  printf '\n</details>\n'
fi

# SCAN_SUMMARY_FOOTER=0 lets scan-report.sh stack several images and print the
# explanation once at the end instead of after every table.
if [ "${SCAN_SUMMARY_FOOTER:-1}" != "0" ]; then
  scan_summary_footer
fi
