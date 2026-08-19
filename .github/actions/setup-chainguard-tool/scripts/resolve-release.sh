#!/usr/bin/env bash
# Resolve the requested tool version to an immutable release tag and the
# commit sha1 that tag points at, then decide where the binary will be
# installed.
#
# Inputs (env): TOOL, REPOSITORY, VERSION, EXPECTED_COMMIT_SHA, INSTALL_DIR_INPUT, GH_TOKEN
# Outputs (GITHUB_OUTPUT): tag, version, commit-sha, arch, archive, install-dir
set -euo pipefail

# The runner's own architecture, not the image's: this picks which release
# archive to download. `apks` jobs run natively on an arm64 runner, so hardcoding
# amd64 here fails half the matrix. RUNNER_ARCH is what GitHub sets; uname is the
# fallback for local runs, and both spellings of each arch are accepted.
if [ "$(uname -s)" != "Linux" ]; then
  echo "::error::setup-chainguard-tool only supports Linux runners (got $(uname -s))"
  exit 1
fi
case "${RUNNER_ARCH:-$(uname -m)}" in
  X64 | x86_64 | amd64) ARCH="amd64" ;;
  ARM64 | aarch64 | arm64) ARCH="arm64" ;;
  *)
    echo "::error::setup-chainguard-tool has no release archive for ${RUNNER_ARCH:-$(uname -m)}"
    exit 1
    ;;
esac

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
  INSTALL_DIR="${RUNNER_TOOL_CACHE:-${HOME}/.cache}/${TOOL}/${TAG}/${ARCH}"
fi

echo "${TOOL} ${TAG} (${COMMIT_SHA}) for linux/${ARCH} -> ${INSTALL_DIR}"

{
  echo "tag=${TAG}"
  echo "version=${VERSION_NUMBER}"
  echo "commit-sha=${COMMIT_SHA}"
  echo "arch=${ARCH}"
  echo "archive=${TOOL}_${VERSION_NUMBER}_linux_${ARCH}.tar.gz"
  echo "install-dir=${INSTALL_DIR}"
} >> "${GITHUB_OUTPUT}"
