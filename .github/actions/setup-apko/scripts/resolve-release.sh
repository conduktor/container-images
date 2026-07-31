#!/usr/bin/env bash
# Resolve the requested apko version to an immutable release tag and the
# commit sha1 that tag points at, then decide where the binary will be
# installed.
#
# Inputs (env): REPOSITORY, VERSION, EXPECTED_COMMIT_SHA, INSTALL_DIR_INPUT, GH_TOKEN
# Outputs (GITHUB_OUTPUT): tag, version, commit-sha, archive, install-dir
set -euo pipefail

# This action only ships the linux/amd64 release archive.
if [ "$(uname -s)" != "Linux" ] || [ "$(uname -m)" != "x86_64" ]; then
  echo "::error::setup-apko only supports linux/amd64 runners (got $(uname -s)/$(uname -m))"
  exit 1
fi

# Resolve the requested version to an immutable release tag.
if [ -z "${VERSION}" ] || [ "${VERSION}" = "latest" ]; then
  TAG="$(gh release view --repo "${REPOSITORY}" --json tagName --jq '.tagName')"
  if [ -z "${TAG}" ]; then
    echo "::error::Could not resolve the latest ${REPOSITORY} release"
    exit 1
  fi
  echo "Resolved latest release: ${TAG}"
else
  TAG="v${VERSION#v}"
fi
VERSION_NUMBER="${TAG#v}"

# Pin the tag to the commit sha1 it points at (dereferencing annotated tags).
read -r OBJECT_TYPE COMMIT_SHA < <(gh api "repos/${REPOSITORY}/git/ref/tags/${TAG}" \
  --jq '"\(.object.type) \(.object.sha)"')
if [ "${OBJECT_TYPE}" = "tag" ]; then
  COMMIT_SHA="$(gh api "repos/${REPOSITORY}/git/tags/${COMMIT_SHA}" --jq '.object.sha')"
fi
if [ -z "${COMMIT_SHA}" ]; then
  echo "::error::Could not resolve a commit sha1 for tag ${TAG} in ${REPOSITORY}"
  exit 1
fi

if [ -n "${EXPECTED_COMMIT_SHA}" ]; then
  case "${COMMIT_SHA}" in
    "${EXPECTED_COMMIT_SHA}"*)
      echo "Commit sha1 matches the expected pin ${EXPECTED_COMMIT_SHA}"
      ;;
    *)
      echo "::error::Tag ${TAG} points at ${COMMIT_SHA} but expected-commit-sha is ${EXPECTED_COMMIT_SHA}"
      exit 1
      ;;
  esac
fi

INSTALL_DIR="${INSTALL_DIR_INPUT}"
if [ -z "${INSTALL_DIR}" ]; then
  INSTALL_DIR="${RUNNER_TOOL_CACHE:-${HOME}/.cache}/apko/${TAG}/amd64"
fi

echo "apko ${TAG} (${COMMIT_SHA}) for linux/amd64 -> ${INSTALL_DIR}"

{
  echo "tag=${TAG}"
  echo "version=${VERSION_NUMBER}"
  echo "commit-sha=${COMMIT_SHA}"
  echo "archive=apko_${VERSION_NUMBER}_linux_amd64.tar.gz"
  echo "install-dir=${INSTALL_DIR}"
} >> "${GITHUB_OUTPUT}"
