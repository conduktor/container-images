#!/usr/bin/env bash
#
# Upsert a "sticky" pull request comment: one comment per marker, edited in place
# on every run instead of a new comment per commit.
#
# Usage:
#   scripts/pr-comment.sh --marker <id> --body-file <path> [--dry-run]
#
# Environment:
#   GH_TOKEN    required — needs pull-requests: write
#   GH_REPO     owner/repo (defaults to $GITHUB_REPOSITORY)
#   PR_NUMBER   the pull request number
#
# The marker is written into the comment as an HTML comment, which GitHub renders
# as nothing, and is what we match on later. Rolled with `gh api` rather than a
# third-party action because this repo is public: a marketplace action here would
# need pull-requests: write, and this is ~30 lines.
#
# Requires: gh, jq
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

# A comment body over the API limit is rejected outright, which would fail the
# job over a reporting detail. Truncate and say so instead.
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

# --paginate: a busy PR can push our comment past the first page.
existing="$(gh api --paginate "repos/${REPO}/issues/${PR_NUMBER}/comments" \
  --jq "[.[] | select(.body | contains(\"${TAG}\")) | .id] | first // empty")"

if [ -n "${existing}" ]; then
  gh api -X PATCH "repos/${REPO}/issues/comments/${existing}" \
    -f body="${BODY}" --jq '.html_url' | sed 's/^/updated: /'
else
  gh api -X POST "repos/${REPO}/issues/${PR_NUMBER}/comments" \
    -f body="${BODY}" --jq '.html_url' | sed 's/^/created: /'
fi
