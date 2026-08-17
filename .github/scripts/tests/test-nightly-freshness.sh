#!/usr/bin/env bash
#
# Guards the one property the nightly exists for: every run must resolve Wolfi
# packages against the *live* index, so an image picks up package updates even
# when no apko.yaml or melange*.yaml changed (AGENTS.md rule 14).
#
# Nothing here is hypothetical — each assertion blocks a specific, plausible
# "optimization" that would silently freeze the images:
#   1. caching apko/melange's apk+index cache dir across runs,
#   2. running apko `--offline`, which serves whatever that cache holds,
#   3. committing an apko lockfile, which pins exact package versions.
#
# A frozen nightly looks completely healthy — green runs, fresh tags, moving
# digests — so this is a test rather than a comment.
#
# Silent on success; prints only failures.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

checks=0
fails=0

fail() {
  fails=$((fails + 1))
  echo "  FAIL $1" >&2
}

assert_eq() {
  checks=$((checks + 1))
  if [ "$2" != "$3" ]; then
    echo "  FAIL $1: want '$2', got '$3'" >&2
    fails=$((fails + 1))
  fi
}

# Paths that hold downloaded apks / APKINDEX. `dev.chainguard.go-apk` is
# go-apk's system cache (used by both apko and melange); the flags are the
# explicit overrides. Persisting any of them across runs makes the cache
# authoritative instead of incidental.
apk_cache_pattern='dev\.chainguard\.go-apk|\.cache/apko|apk-cache'

# Every composite action and workflow, so a cache added to an action we call is
# caught too.
ci_yaml() {
  find "$1" -type f \( -name '*.yml' -o -name '*.yaml' \) \
    \( -path '*/workflows/*' -o -path '*/actions/*' \) | sort
}

# Prints one line per offending cache step; empty output means clean.
scan_caches() {
  local root="$1" file paths
  while IFS= read -r file; do
    [ -n "${file}" ] || continue
    # `.path` of every actions/cache (or cache/restore, cache/save) step.
    paths="$(yq -r '
      [ .jobs[]?.steps[]?, .runs.steps[]? ]
      | .[]
      | select(((.uses // "") | test("actions/cache")))
      | .with.path // ""
    ' "${file}" 2>/dev/null || true)"
    if printf '%s' "${paths}" | grep -Eq "${apk_cache_pattern}"; then
      echo "${file}: caches an apk/index directory"
    fi
  done < <(ci_yaml "${root}")
}

# --- the real repo ----------------------------------------------------------
checks=$((checks + 1))
offenders="$(scan_caches "${REPO_ROOT}/.github")"
[ -z "${offenders}" ] || fail "apk cache is persisted across runs:
${offenders}"

# `--offline` makes apko build from the cache alone. Correct for an air-gapped
# rebuild, fatal for a nightly.
checks=$((checks + 1))
if grep -rn -- '--offline' "${REPO_ROOT}/.github" \
     "${REPO_ROOT}/scripts" 2>/dev/null | grep -v '/tests/'; then
  fail "apko --offline would build from cache instead of the live index"
fi

# `apko lock` writes resolved versions to a lockfile; a committed one turns
# every later build into a replay of the day it was generated.
checks=$((checks + 1))
locks="$(find "${REPO_ROOT}/images" -name '*.lock.json' -o -name 'apko.lock*' 2>/dev/null)"
[ -z "${locks}" ] || fail "apko lockfile(s) present — images would stop picking up updates:
${locks}"

checks=$((checks + 1))
if grep -rn -e '--lockfile' -e 'apko lock' "${REPO_ROOT}/.github" \
     "${REPO_ROOT}/scripts" 2>/dev/null | grep -v '/tests/'; then
  fail "apko lockfile flag in use — images would stop picking up updates"
fi

# The cache we *do* persist must stay the content-addressed source cache, keyed
# by the expected-sha256 in the melange configs, which cannot serve different
# content than it is asked for. Located by scanning the CI tree rather than one
# named workflow, so moving the build into a reusable workflow doesn't turn this
# into a false alarm.
checks=$((checks + 1))
if ! grep -rq 'melange-cache' "${REPO_ROOT}/.github/workflows/"; then
  fail "the melange source cache disappeared from CI — re-check rule 14"
fi

# --- fixtures: prove the scan actually catches a violation ------------------
mkdir -p "${TMP}/.github/workflows"
cat > "${TMP}/.github/workflows/bad.yml" <<'YAML'
name: bad
on: workflow_dispatch
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/cache@v4
        with:
          path: ~/.cache/dev.chainguard.go-apk
          key: apk-${{ github.sha }}
YAML
assert_eq "detects a cached go-apk dir" "1" \
  "$(scan_caches "${TMP}/.github" | wc -l)"

cat > "${TMP}/.github/workflows/bad.yml" <<'YAML'
name: bad
on: workflow_dispatch
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/cache/restore@v4
        with:
          path: |
            /tmp/melange-cache
            /tmp/apk-cache
          key: mixed
YAML
assert_eq "detects an apk dir hidden in a multi-line path" "1" \
  "$(scan_caches "${TMP}/.github" | wc -l)"

# A composite action is just as able to cache the wrong thing.
rm -f "${TMP}/.github/workflows/bad.yml"
mkdir -p "${TMP}/.github/actions/sneaky"
cat > "${TMP}/.github/actions/sneaky/action.yml" <<'YAML'
name: sneaky
runs:
  using: composite
  steps:
    - uses: actions/cache@v4
      with:
        path: ~/.cache/apko
        key: apko
YAML
assert_eq "detects a cache inside a composite action" "1" \
  "$(scan_caches "${TMP}/.github" | wc -l)"

# And must not cry wolf over the source cache we rely on.
rm -rf "${TMP}/.github/actions"
cat > "${TMP}/.github/workflows/good.yml" <<'YAML'
name: good
on: workflow_dispatch
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/cache@v4
        with:
          path: ${{ runner.temp }}/melange-cache
          key: melange-src-debug
YAML
assert_eq "leaves the melange source cache alone" "0" \
  "$(scan_caches "${TMP}/.github" | wc -l)"

if [ "${fails}" -ne 0 ]; then
  echo "nightly-freshness: ${fails}/${checks} failed" >&2
  exit 1
fi
echo "nightly-freshness: ${checks} checks passed"
