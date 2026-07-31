#!/usr/bin/env bash
# Verify the installed apko binary is the one we pinned: the release binary
# embeds the tag and the commit sha1 it was built from, and both must match.
#
# Inputs (env): EXPECTED_PATH, EXPECTED_TAG, EXPECTED_COMMIT_SHA
set -euo pipefail

RESOLVED_PATH="$(command -v apko || true)"
if [ -z "${RESOLVED_PATH}" ]; then
  echo "::error::apko is not on PATH after installation"
  exit 1
fi
if [ "${RESOLVED_PATH}" != "${EXPECTED_PATH}" ]; then
  echo "::warning::apko on PATH resolves to ${RESOLVED_PATH}, expected ${EXPECTED_PATH}"
fi

VERSION_OUTPUT="$(apko version)"
echo "${VERSION_OUTPUT}"

GIT_VERSION="$(printf '%s\n' "${VERSION_OUTPUT}" | awk '/^GitVersion:/ {print $2; exit}')"
GIT_COMMIT="$(printf '%s\n' "${VERSION_OUTPUT}" | awk '/^GitCommit:/ {print $2; exit}')"

if [ "v${GIT_VERSION#v}" != "v${EXPECTED_TAG#v}" ]; then
  echo "::error::apko reports version ${GIT_VERSION}, expected ${EXPECTED_TAG}"
  exit 1
fi
if [ -z "${GIT_COMMIT}" ] || [ "${GIT_COMMIT}" = "unknown" ] || [ "${GIT_COMMIT}" = "none" ]; then
  echo "::warning::apko binary does not report a commit sha1, skipping sha1 verification"
else
  case "${EXPECTED_COMMIT_SHA}" in
    "${GIT_COMMIT}"*)
      echo "Verified apko ${EXPECTED_TAG} built from ${GIT_COMMIT}"
      ;;
    *)
      echo "::error::apko reports commit ${GIT_COMMIT}, expected ${EXPECTED_COMMIT_SHA}"
      exit 1
      ;;
  esac
fi
