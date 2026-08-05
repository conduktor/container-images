#!/usr/bin/env bash
#
# Upsert a sticky PR comment: one per marker, edited in place on each run.
#
#   sticky-comment.sh --marker <id> --body-file <path> [--dry-run]
#
# Env: GH_TOKEN (needs pull-requests: write), GH_REPO, PR_NUMBER.
#
# Requires: gh
set -euo pipefail

MARKER=""
BODY_FILE=""
DRY_RUN=0

while [ $# -gt 0 ]; do
  case "$1" in
    --marker) MARKER="${2:-}"; shift 2 ;;
    --body-file) BODY_FILE="${2:-}"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

[ -n "${MARKER}" ] || { echo "--marker is required" >&2; exit 2; }
[ -n "${BODY_FILE}" ] || { echo "--body-file is required" >&2; exit 2; }
[ -f "${BODY_FILE}" ] || { echo "body file not found: ${BODY_FILE}" >&2; exit 2; }

REPO="${GH_REPO:-${GITHUB_REPOSITORY:-}}"
[ -n "${REPO}" ] || { echo "GH_REPO or GITHUB_REPOSITORY is required" >&2; exit 2; }
[ -n "${PR_NUMBER:-}" ] || { echo "PR_NUMBER is required" >&2; exit 2; }

TAG="<!-- conduktor-ci:${MARKER} -->"
BODY="$(printf '%s\n\n%s\n' "${TAG}" "$(cat "${BODY_FILE}")")"

# Over the API limit the whole call is rejected; truncate rather than fail.
LIMIT=60000
if [ "${#BODY}" -gt "${LIMIT}" ]; then
  BODY="${BODY:0:${LIMIT}}"$'\n\n_Report truncated; see the workflow artifacts for the full reports._'
fi

if [ "${DRY_RUN}" = "1" ]; then
  printf 'would upsert comment on %s#%s with marker %s (%s bytes)\n' \
    "${REPO}" "${PR_NUMBER}" "${MARKER}" "${#BODY}"
  printf '%s\n' "${BODY}"
  exit 0
fi

# --paginate: a busy PR can push our comment past page one.
existing="$(gh api --paginate "repos/${REPO}/issues/${PR_NUMBER}/comments" \
  --jq "[.[] | select(.body | contains(\"${TAG}\")) | .id] | first // empty")"

if [ -n "${existing}" ]; then
  gh api -X PATCH "repos/${REPO}/issues/comments/${existing}" \
    -f body="${BODY}" --jq '.html_url' | sed 's/^/updated: /'
else
  gh api -X POST "repos/${REPO}/issues/${PR_NUMBER}/comments" \
    -f body="${BODY}" --jq '.html_url' | sed 's/^/created: /'
fi
