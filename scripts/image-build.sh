#!/usr/bin/env bash
#
# Build one of the images in this repo with apko and load it into the local
# Docker daemon. Uses a native `apko` binary if one is on PATH, otherwise
# falls back to the official apko container image (no local install needed).
#
# Builds for the host architecture only (a single-arch tar is what
# `docker load` understands). CI publishes multi-arch via `apko publish` —
# see .github/workflows/nightly.yml.
#
# The set of images and their published names comes from images/images.json.
#
# Usage (runnable from anywhere — paths resolve from the script's location):
#   scripts/image-build.sh base-os                       # -> conduktor/base-os:local
#   scripts/image-build.sh base-jre-25                   # -> conduktor/base-jre-25:local
#   scripts/image-build.sh debug                         # -> conduktor/conduktor-debug:local
#   scripts/image-build.sh base-jre-25 myrepo/base:tag   # custom image ref
#
# Requires: docker, jq (apko optional — falls back to the apko container).
set -euo pipefail

if [ $# -lt 1 ]; then
  echo "Usage: $0 <image-dir> [image-ref]" >&2
  exit 2
fi

IMAGE_DIR="$1"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MANIFEST="${REPO_ROOT}/images/images.json"

IMAGE_NAME="$(jq -r --arg dir "${IMAGE_DIR}" \
  'map(select(.dir == $dir)) | .[0].name // empty' "${MANIFEST}")"
if [ -z "${IMAGE_NAME}" ]; then
  echo "Unknown image '${IMAGE_DIR}'. Expected one of:" \
    "$(jq -r '[.[].dir] | join(" | ")' "${MANIFEST}")" >&2
  exit 2
fi

IMAGE_REF="${2:-conduktor/${IMAGE_NAME}:local}"
APKO_IMAGE="${APKO_IMAGE:-cgr.dev/chainguard/apko:latest}"

WORK_DIR="${REPO_ROOT}/images/${IMAGE_DIR}"
TAR_NAME="${IMAGE_DIR}.tar"

HOST_ARCH="$(docker version --format '{{.Server.Arch}}' 2>/dev/null || uname -m)"
case "${HOST_ARCH}" in
  x86_64) HOST_ARCH="amd64" ;;
  aarch64) HOST_ARCH="arm64" ;;
esac

# An image with a melange*.yaml ships local packages built from source in its
# directory (images/debug/tools/, images/base-monitoring/'s forks). Build those
# APKs first so apko can resolve them from the `@local ./packages` repository.
# Matched by glob, not by the exact name `melange.yaml`: base-monitoring has
# three configs and no plain melange.yaml.
#
# Only for ${HOST_ARCH}: apko below builds the host arch alone, so a foreign-arch
# APK would be built under qemu emulation and then never installed. We derive the
# arch from the Docker daemon rather than letting melange-build.sh fall back to
# `uname -m`, since the daemon is what actually runs the build. An explicit
# MELANGE_ARCHES still wins, so `make build ARCHES=x86_64,aarch64` works.
shopt -s nullglob
melange_configs=("${WORK_DIR}"/melange*.yaml)
shopt -u nullglob
if [ "${#melange_configs[@]}" -gt 0 ]; then
  case "${HOST_ARCH}" in
    amd64) MELANGE_ARCH="x86_64" ;;
    arm64) MELANGE_ARCH="aarch64" ;;
    *) echo "!! Unsupported host arch '${HOST_ARCH}'" >&2; exit 1 ;;
  esac
  export MELANGE_ARCHES="${MELANGE_ARCHES:-${MELANGE_ARCH}}"
  echo ">> Building local APKs from ${IMAGE_DIR}/melange*.yaml (${MELANGE_ARCHES})"
  "${REPO_ROOT}/scripts/melange-build.sh" "${IMAGE_DIR}"
fi

echo ">> Building ${IMAGE_REF} (arch: ${HOST_ARCH}) with apko"
if command -v apko >/dev/null 2>&1; then
  ( cd "${WORK_DIR}" && apko build apko.yaml "${IMAGE_REF}" "${TAR_NAME}" --arch "${HOST_ARCH}" --sbom-path . )
else
  echo ">> No local 'apko' found; using ${APKO_IMAGE}"
  docker run --rm \
    --user "$(id -u):$(id -g)" \
    -v "${WORK_DIR}:/work" -w /work \
    "${APKO_IMAGE}" \
    build apko.yaml "${IMAGE_REF}" "${TAR_NAME}" --arch "${HOST_ARCH}" --sbom-path .
fi

echo ">> Loading ${WORK_DIR}/${TAR_NAME} into Docker"
# apko may suffix tags with the arch and/or load untagged when the config
# declares multiple archs. Retag whatever landed to the plain ${IMAGE_REF}.
load_out="$(docker load -i "${WORK_DIR}/${TAR_NAME}")"
echo "${load_out}"

# Retag unconditionally: guarding on "does ${IMAGE_REF} already exist" would
# leave a stale tag from a previous build pointing at the old image, so you'd
# silently test yesterday's layers.
loaded_ref="$(printf '%s\n' "${load_out}" | sed -n 's/^Loaded image: //p' | head -n1)"
loaded_id="$(printf '%s\n' "${load_out}" | sed -n 's/^Loaded image ID: //p' | head -n1)"
if [ -n "${loaded_ref}" ] && [ "${loaded_ref}" != "${IMAGE_REF}" ]; then
  docker tag "${loaded_ref}" "${IMAGE_REF}"
elif [ -n "${loaded_id}" ]; then
  docker tag "${loaded_id}" "${IMAGE_REF}"
elif [ -z "${loaded_ref}" ]; then
  echo "!! Could not determine the loaded image ref from 'docker load' output." >&2
  exit 1
fi

echo ">> Done. Try one of:"
echo "     docker run --rm ${IMAGE_REF} /bin/sh -c 'cat /etc/os-release'"
case "${IMAGE_DIR}" in
  base-jre-25|debug)
    echo "     docker run --rm ${IMAGE_REF} java -version"
    ;;
  base-monitoring)
    echo "     docker run --rm ${IMAGE_REF} prometheus --version"
    echo "     docker run --rm ${IMAGE_REF} cortex -version"
    echo "     docker run --rm ${IMAGE_REF} supervisord --version"
    ;;
esac
