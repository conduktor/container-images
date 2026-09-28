#!/usr/bin/env bash
#
# Publish everything the README and its readers link to by fixed URL — the
# shields.io endpoint JSON, the Markdown report behind each badge, and the raw
# scanner output and SBOMs under reports/ and sbom/ — to a dedicated branch of
# the same repo, so those URLs live on raw.githubusercontent.com without this
# ever needing to push to `main` (which is protected).
#
# The badge branch is treated as a state-only branch: on every run we resync to
# it (or create it orphan on first run), replace its entire tree with <src-dir>,
# and commit only if something actually changed. Anything the run did not
# produce is dropped rather than left to go stale — an image that stopped being
# built must stop being served.
#
# A run with badge JSON but no Markdown or raw reports is accepted — those are
# an addition, and refusing would take the badges down with them.
#
# Usage: publish-badges.sh <src-dir> <branch>
#
# Env:
#   REMOTE_URL  Authenticated git remote URL (https://x-access-token:<token>@...
#               in CI; file:///path/to/bare.git in tests). Required.
#   GIT_USER_NAME  / GIT_USER_EMAIL  Author for the commit. Optional; defaults
#               to the github-actions[bot] identity.
set -euo pipefail

if [ $# -ne 2 ]; then
  echo "Usage: $0 <src-dir> <branch>" >&2
  exit 2
fi

SRC="$1"
BRANCH="$2"
: "${REMOTE_URL:?REMOTE_URL is required}"

[ -d "${SRC}" ] || { echo "src-dir not found: ${SRC}" >&2; exit 2; }

# Only the top level counts: the badges are what the README cannot do without,
# and a raw report under reports/ must not stand in for one.
shopt -s nullglob
badges=("${SRC}"/*.json)
shopt -u nullglob
if [ "${#badges[@]}" -eq 0 ]; then
  echo "no badge JSON files in ${SRC} — refusing to blank the branch" >&2
  exit 2
fi

work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT

git -C "${work}" init -q -b "${BRANCH}"
git -C "${work}" config user.name  "${GIT_USER_NAME:-github-actions[bot]}"
git -C "${work}" config user.email "${GIT_USER_EMAIL:-41898282+github-actions[bot]@users.noreply.github.com}"
git -C "${work}" remote add origin "${REMOTE_URL}"

# Fetch the existing branch if it's there; on first run it isn't, and we stay
# on the fresh orphan branch created by `git init -b`.
if git -C "${work}" fetch --depth=1 origin "${BRANCH}" 2>/dev/null; then
  git -C "${work}" reset --hard "origin/${BRANCH}"
  # Drop the whole previous tree — a removed image, report or SBOM must stop
  # being served, and everything below is rewritten from <src-dir> anyway.
  find "${work}" -mindepth 1 -maxdepth 1 ! -name .git -exec rm -rf {} +
fi

cp -R "${SRC}/." "${work}/"

git -C "${work}" add -A
if git -C "${work}" diff --cached --quiet; then
  echo "no badge changes"
  exit 0
fi

git -C "${work}" commit -q -m "ci: refresh CVE badges, reports and SBOMs [skip ci]"
git -C "${work}" push origin "${BRANCH}"
