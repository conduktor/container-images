#!/usr/bin/env bash
#
# Resolve both CI matrices — the per-image one and the per-(image,arch) melange
# one — from images/images.json plus what is actually on disk (AGENTS.md rule 9).
#
# Prints one compact JSON object on stdout:
#   {
#     "images": [
#       {"dir":"base-os","name":"base-os","melange":false,"configs":""},
#       {"dir":"debug","name":"conduktor-debug","dockerhub":"docker.io/...",
#        "melange":true,"configs":"melange-conduktor-ctl.yaml,melange-kafka-tools.yaml,melange.yaml"}
#     ],
#     "apks": [
#       {"dir":"debug","arch":"x86_64","runner":"ubuntu-latest",
#        "configs":"melange-conduktor-ctl.yaml,melange-kafka-tools.yaml,melange.yaml"}
#     ]
#   }
#
# `images` drives the build/publish job. `melange` and `configs` say the same
# thing two ways on purpose: the boolean is what a workflow `if:` should test,
# the list is what melange-build's `multi-config` input wants — so no workflow
# has to glob the image directory itself.
#
# `apks` drives the melange fan-out: one job per image *and* arch, each pinned to
# a runner of that arch so nothing cross-builds under qemu (AGENTS.md rule 13).
# Images with no melange*.yaml contribute no `apks` entries at all, which is how
# base-os and base-jre-25 skip the fan-out without a per-step `if:`.
#
# Usage:
#   scripts/build-matrix.sh                    # every image, both arches
#   scripts/build-matrix.sh base-os,debug      # a subset (same names as image-matrix.sh)
#   scripts/build-matrix.sh "" x86_64          # every image, amd64 APKs only
#
# Exits 2 on an unknown image name (delegated to image-matrix.sh) or an arch with
# no runner mapping, so a typo'd workflow_dispatch input fails the run instead of
# quietly resolving to an empty matrix.
#
# Requires: jq
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMAGES_DIR="${IMAGES_DIR:-${REPO_ROOT}/images}"
subset="${1:-}"
arches="${2:-x86_64,aarch64}"

# Reused rather than reimplemented: this is where subset validation and manifest
# ordering live.
images="$("${REPO_ROOT}/scripts/image-matrix.sh" "${subset}")"

# Per-image melange config list, keyed by dir: {"debug":"melange-a.yaml,melange.yaml"}
# LC_ALL=C so the list is byte-sorted rather than locale-sorted — it is a job
# input, and `-` vs `.` ordering flips between collations.
configs="{}"
while IFS= read -r dir; do
  [ -n "${dir}" ] || continue
  shopt -s nullglob
  files=("${IMAGES_DIR}/${dir}"/melange*.yaml)
  shopt -u nullglob
  [ "${#files[@]}" -gt 0 ] || continue
  list="$(printf '%s\n' "${files[@]##*/}" | LC_ALL=C sort | paste -sd, -)"
  configs="$(jq -c --arg d "${dir}" --arg l "${list}" '. + {($d): $l}' <<<"${configs}")"
done < <(jq -r '.[].dir' <<<"${images}")

# Standard GitHub-hosted labels only — no self-hosted or third-party runner
# pool, so a fork can run this workflow unchanged. arm64 GitHub runners have no
# `-latest` alias, hence the pinned image version.
jq -cn \
  --argjson images "${images}" \
  --argjson configs "${configs}" \
  --arg arches "${arches}" '
  {"x86_64": "ubuntu-latest", "aarch64": "ubuntu-24.04-arm"} as $runners
  | ($arches | split(",") | map(select(length > 0))) as $arches
  | ($images | map(($configs[.dir] // "") as $c | . + {melange: ($c != ""), configs: $c})) as $images
  | {
      images: $images,
      apks: [
        $images[]
        | . as $img
        | ($configs[$img.dir] // "")
        | select(. != "")
        | . as $c
        | $arches[]
        | { dir: $img.dir,
            arch: .,
            runner: ($runners[.] // ("no runner mapping for arch: " + . | error)),
            configs: $c }
      ]
    }
'
