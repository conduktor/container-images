#!/usr/bin/env bash
#
# Publish the shields.io endpoint JSON files to a dedicated branch of the same
# repo, so the README's badge URLs can point at a raw.githubusercontent.com URL
# on that branch without ever needing to push to `main` (which is protected).
#
# The badge branch is treated as a state-only branch: on every run we resync to
# it (or create it orphan on first run), replace all *.json files with the fresh
# set, and commit only if something actually changed. Older images that no
# longer produce badges are dropped instead of lingering.
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

shopt -s nullglob
srcs=("${SRC}"/*.json)
shopt -u nullglob
if [ "${#srcs[@]}" -eq 0 ]; then
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
  # Drop every previous badge — a removed image must stop showing.
  find "${work}" -maxdepth 1 -name '*.json' -delete
fi

cp "${srcs[@]}" "${work}/"

git -C "${work}" add -A
if git -C "${work}" diff --cached --quiet; then
  echo "no badge changes"
  exit 0
fi

git -C "${work}" commit -q -m "ci: refresh CVE badges [skip ci]"
git -C "${work}" push origin "${BRANCH}"
