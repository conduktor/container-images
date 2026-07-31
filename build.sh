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
# Usage:
#   ./build.sh base-os                       # -> conduktor/base-os:local
#   ./build.sh base-jre-25                   # -> conduktor/base-jre-25:local
#   ./build.sh debug                         # -> conduktor/conduktor-debug:local
#   ./build.sh base-jre-25 myrepo/base:tag   # custom image ref
set -euo pipefail

if [ $# -lt 1 ]; then
  echo "Usage: $0 <base-os|base-jre-25|debug> [image-ref]" >&2
  exit 2
fi

IMAGE_DIR="$1"
case "${IMAGE_DIR}" in
  base-os)      DEFAULT_REF="conduktor/base-os:local" ;;
  base-jre-25)  DEFAULT_REF="conduktor/base-jre-25:local" ;;
  debug)        DEFAULT_REF="conduktor/conduktor-debug:local" ;;
  *) echo "Unknown image '${IMAGE_DIR}'. Expected: base-os | base-jre-25 | debug" >&2; exit 2 ;;
esac

IMAGE_REF="${2:-${DEFAULT_REF}}"
APKO_IMAGE="${APKO_IMAGE:-cgr.dev/chainguard/apko:latest}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK_DIR="${REPO_ROOT}/images/${IMAGE_DIR}"
TAR_NAME="${IMAGE_DIR}.tar"

HOST_ARCH="$(docker version --format '{{.Server.Arch}}' 2>/dev/null || uname -m)"
case "${HOST_ARCH}" in
  x86_64) HOST_ARCH="amd64" ;;
  aarch64) HOST_ARCH="arm64" ;;
esac

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

if ! docker image inspect "${IMAGE_REF}" >/dev/null 2>&1; then
  loaded_ref="$(printf '%s\n' "${load_out}" | sed -n 's/^Loaded image: //p' | head -n1)"
  loaded_id="$(printf '%s\n' "${load_out}" | sed -n 's/^Loaded image ID: //p' | head -n1)"
  if [ -n "${loaded_ref}" ]; then
    docker tag "${loaded_ref}" "${IMAGE_REF}"
  elif [ -n "${loaded_id}" ]; then
    docker tag "${loaded_id}" "${IMAGE_REF}"
  else
    echo "!! Could not determine the loaded image ref from 'docker load' output." >&2
    exit 1
  fi
fi

echo ">> Done. Try one of:"
echo "     docker run --rm ${IMAGE_REF} /bin/sh -c 'cat /etc/os-release'"
if [ "${IMAGE_DIR}" != "base-os" ]; then
  echo "     docker run --rm ${IMAGE_REF} java -version"
fi
