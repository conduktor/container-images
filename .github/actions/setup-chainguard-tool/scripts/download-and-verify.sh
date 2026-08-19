#!/usr/bin/env bash
# Download the pinned tool release archive, verify the release checksums (and
# their Sigstore signature), then install the binary and add it to PATH.
#
# Inputs (env): TOOL, REPOSITORY, TAG, ARCHIVE, INSTALL_DIR, EXPECTED_SHA256,
#               VERIFY_SIGNATURE, CERTIFICATE_IDENTITY_REGEXP, OIDC_ISSUER, GH_TOKEN
# Outputs (GITHUB_OUTPUT): sha256, path
set -euo pipefail

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "${WORK_DIR}"' EXIT

PATTERNS=(--pattern "${ARCHIVE}" --pattern "checksums.txt")
if [ "${VERIFY_SIGNATURE}" = "true" ]; then
  PATTERNS+=(--pattern "checksums.txt.sig" --pattern "checksums.txt.crt")
fi

echo "Downloading ${REPOSITORY} ${TAG} assets: ${ARCHIVE}, checksums.txt"
gh release download "${TAG}" \
  --repo "${REPOSITORY}" \
  --dir "${WORK_DIR}" \
  "${PATTERNS[@]}"

# Verify the checksums file itself was signed by the tool's release workflow.
if [ "${VERIFY_SIGNATURE}" = "true" ]; then
  cosign verify-blob \
    --certificate "${WORK_DIR}/checksums.txt.crt" \
    --signature "${WORK_DIR}/checksums.txt.sig" \
    --certificate-identity-regexp "${CERTIFICATE_IDENTITY_REGEXP}" \
    --certificate-oidc-issuer "${OIDC_ISSUER}" \
    "${WORK_DIR}/checksums.txt"
  echo "cosign verified checksums.txt"
else
  echo "::warning::Skipping Sigstore signature verification of checksums.txt (verify-signature=false)"
fi

EXPECTED="$(awk -v archive="${ARCHIVE}" '$2 == archive {print $1}' "${WORK_DIR}/checksums.txt")"
if [ -z "${EXPECTED}" ]; then
  echo "::error::${ARCHIVE} is not listed in the release checksums.txt"
  exit 1
fi
ACTUAL="$(sha256sum "${WORK_DIR}/${ARCHIVE}" | awk '{print $1}')"
if [ "${EXPECTED}" != "${ACTUAL}" ]; then
  echo "::error::Checksum mismatch for ${ARCHIVE}: expected ${EXPECTED}, got ${ACTUAL}"
  exit 1
fi
echo "SHA-256 verified: ${ACTUAL}"

if [ -n "${EXPECTED_SHA256}" ] && [ "${EXPECTED_SHA256}" != "${ACTUAL}" ]; then
  echo "::error::Checksum ${ACTUAL} does not match the expected-sha256 pin ${EXPECTED_SHA256}"
  exit 1
fi

tar -xzf "${WORK_DIR}/${ARCHIVE}" -C "${WORK_DIR}"
BINARY="$(find "${WORK_DIR}" -type f -name "${TOOL}" | head -n 1)"
if [ -z "${BINARY}" ]; then
  echo "::error::No ${TOOL} binary found in ${ARCHIVE}"
  exit 1
fi

# A root-owned install-dir is deliberate: `sudo melange` (what melange-build-pkg
# runs) searches sudo's secure_path, which the tool cache is not in.
SUDO=()
mkdir -p "${INSTALL_DIR}" 2>/dev/null || true
if [ ! -w "${INSTALL_DIR}" ]; then
  SUDO=(sudo)
  "${SUDO[@]}" mkdir -p "${INSTALL_DIR}"
fi
"${SUDO[@]}" install -m 0755 "${BINARY}" "${INSTALL_DIR}/${TOOL}"
echo "${INSTALL_DIR}" >> "${GITHUB_PATH}"

{
  echo "sha256=${ACTUAL}"
  echo "path=${INSTALL_DIR}/${TOOL}"
} >> "${GITHUB_OUTPUT}"
