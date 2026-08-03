#!/usr/bin/env bash
#
# Resolve the CI build matrix from images/images.json, the single source of
# truth for the image inventory (see AGENTS.md rule 9).
#
# Prints a compact JSON array on stdout:
#   [{"dir":"debug","name":"conduktor-debug","dockerhub":"docker.io/..."}]
#
# Usage:
#   scripts/image-matrix.sh                  # every image, manifest order
#   scripts/image-matrix.sh base-os,debug    # a comma-separated subset
#
# Exits 2 on an unknown name so a typo'd workflow_dispatch input fails the run
# instead of silently resolving to an empty matrix.
#
# Requires: jq
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MANIFEST="${IMAGES_MANIFEST:-${REPO_ROOT}/images/images.json}"
subset="${1:-}"

if [ ! -f "${MANIFEST}" ]; then
  echo "image manifest not found: ${MANIFEST}" >&2
  exit 2
fi

if [ -z "${subset}" ]; then
  jq -c '.' "${MANIFEST}"
  exit 0
fi

missing="$(jq -r --arg subset "${subset}" '
  ($subset | split(",") | map(select(length > 0))) as $want
  | ($want - [.[].dir]) | join(", ")
' "${MANIFEST}")"

if [ -n "${missing}" ]; then
  echo "unknown image(s): ${missing}" >&2
  echo "known images: $(jq -r '[.[].dir] | join(", ")' "${MANIFEST}")" >&2
  exit 2
fi

# Filter in manifest order, not the order the caller happened to list.
jq -c --arg subset "${subset}" '
  ($subset | split(",") | map(select(length > 0))) as $want
  | map(select([.dir] - $want | length == 0))
' "${MANIFEST}"
