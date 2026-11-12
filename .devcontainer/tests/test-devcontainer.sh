#!/usr/bin/env bash
#
# Tests for .devcontainer/, asserting what a broken config would only reveal
# minutes into a rebuild on someone else's machine: flake.nix stays the only
# place tool versions live, flakes are enabled, and the Docker daemon is nested
# (melange bind-mounts its workspace, so host-socket paths do not resolve).
#
# Silent on success; prints only failures.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CONFIG="${DEVCONTAINER_CONFIG:-${REPO_ROOT}/.devcontainer/devcontainer.json}"
SELF="${BASH_SOURCE[0]}"

checks=0
fails=0

fail() {
  fails=$((fails + 1))
  echo "  FAIL $1" >&2
}

assert_eq() {
  checks=$((checks + 1))
  [ "$2" = "$3" ] || fail "$1: want '$2', got '$3'"
}

# devcontainer.json is JSONC; jq is not. Whole-line comments only — an
# unanchored `//` would also eat the `https://` inside a string value.
json="$(sed 's:^[[:space:]]*//.*$::' "${CONFIG}")"

checks=$((checks + 1))
jq -e . >/dev/null 2>&1 <<<"${json}" || fail "devcontainer.json does not parse as JSON(C)"

features="$(jq -r '.features | keys[]' <<<"${json}")"
lifecycle="$(jq -r '[.postCreateCommand?, .onCreateCommand?, .updateContentCommand?,
                     .postStartCommand?, .postAttachCommand?] | map(select(. != null))
                    | tostring' <<<"${json}")"

# The flake owns the toolchain.
for tool in apko melange cosign syft crane trivy grype yamllint actionlint \
            shellcheck gitleaks pre-commit; do
  checks=$((checks + 1))
  case "${features}" in
    *"${tool}"*) fail "feature installs '${tool}' — it belongs in flake.nix" ;;
  esac
  checks=$((checks + 1))
  case "${lifecycle}" in
    *"install ${tool}"*|*"nix profile install"*"${tool}"*)
      fail "lifecycle command installs '${tool}' — it belongs in flake.nix" ;;
  esac
done

# Flakes must be on explicitly, or `nix develop` fails at runtime.
nix_cfg="$(jq -r '.features | to_entries
                  | map(select(.key | test("/nix(:|$)")))[0].value.extraNixConfig // ""' \
                 <<<"${json}")"
checks=$((checks + 1))
case "${nix_cfg}" in
  *"experimental-features = nix-command flakes"*) ;;
  *) fail "the nix feature must set 'experimental-features = nix-command flakes' via extraNixConfig" ;;
esac

# docker-in-docker, never docker-outside-of-docker.
checks=$((checks + 1))
case "${features}" in
  *docker-outside-of-docker*)
    fail "docker-outside-of-docker breaks melange's docker runner — use docker-in-docker" ;;
esac
checks=$((checks + 1))
case "${features}" in
  *docker-in-docker*) ;;
  *) fail "no docker-in-docker feature: 'make build' needs a daemon in the container" ;;
esac

# Unpinned features drift silently.
while IFS= read -r ref; do
  checks=$((checks + 1))
  case "${ref}" in
    */*:*) ;;
    *) fail "feature '${ref}' is not pinned to a version tag" ;;
  esac
done <<<"${features}"

# Must be executable, or container creation fails late.
hook="$(jq -r '.postCreateCommand' <<<"${json}")"
checks=$((checks + 1))
[ -x "${REPO_ROOT}/${hook}" ] || fail "postCreateCommand '${hook}' is not an executable file"

# A dropped cache mount just makes every rebuild slow — easy to not notice.
assert_eq "cache volume mounted" "1" \
  "$(jq -r '[.mounts[]? | select(test("target=/home/[^,]*/\\.cache"))] | length' <<<"${json}")"

# The guards are only worth having if they can fail: every mutation must be
# rejected when the file is re-run against it.
if [ -z "${DEVCONTAINER_CONFIG:-}" ]; then
  TMP="$(mktemp -d)"
  trap 'rm -rf "${TMP}"' EXIT

  mutate() { # <name> <jq filter>
    jq "$2" <<<"${json}" > "${TMP}/$1.json"
    checks=$((checks + 1))
    if DEVCONTAINER_CONFIG="${TMP}/$1.json" bash "${SELF}" >/dev/null 2>&1; then
      fail "mutation '$1' should have been rejected"
    fi
  }

  mutate host-socket \
    '.features["ghcr.io/devcontainers/features/docker-outside-of-docker:1"] = {}
     | del(.features["ghcr.io/devcontainers/features/docker-in-docker:2"])'
  mutate no-flakes \
    '.features["ghcr.io/devcontainers/features/nix:1"].extraNixConfig = ""'
  mutate unpinned-feature \
    '.features["ghcr.io/devcontainers/features/go"] = {}'
  mutate tool-outside-flake \
    '.features["ghcr.io/devcontainers-extra/features/trivy:1"] = {}'
  mutate no-cache-volume 'del(.mounts)'
fi

if [ "${fails}" -ne 0 ]; then
  echo "${fails} of ${checks} checks failed" >&2
  exit 1
fi

# Quiet in the self-check runs above, which would print five times.
[ -n "${DEVCONTAINER_CONFIG:-}" ] || echo "devcontainer: ${checks} checks passed"
