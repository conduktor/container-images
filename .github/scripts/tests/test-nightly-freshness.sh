#!/usr/bin/env bash
#
# Guards the one property the nightly exists for: every run must resolve Wolfi
# packages against the *live* index, so an image picks up package updates even
# when no apko.yaml or melange*.yaml changed.
#
# Nothing here is hypothetical — each assertion blocks a specific, plausible
# "optimization" that would silently freeze the images:
#   1. caching apko/melange's apk+index cache dir across runs,
#   2. running apko `--offline`, which serves whatever that cache holds,
#   3. feeding apko a lockfile from anywhere but the current run — committed,
#      cached or restored — which pins exact package versions. Note the
#      asymmetry: build.yml generates and attests a lock every run, which is
#      required; only consuming a stale one is fatal.
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
# authoritative instead of incidental. A cached lockfile does the same thing by
# a different route, so it belongs in the same pattern.
apk_cache_pattern='dev\.chainguard\.go-apk|\.cache/apko|apk-cache|\.lock\.json'

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
      echo "${file}: caches an apk/index directory or a lockfile"
    fi
  done < <(ci_yaml "${root}")
}

# Prints one line per `apko lock` step a PR run would skip — otherwise this path
# first executes on a nightly, after merge.
scan_lock_gated() {
  local root="$1" file gated
  while IFS= read -r file; do
    [ -n "${file}" ] || continue
    gated="$(yq -r '
      [ .jobs[]?.steps[]?, .runs.steps[]? ]
      | .[]
      | select(((.run // "") | test("apko lock")))
      | .if // ""
    ' "${file}" 2>/dev/null || true)"
    if printf '%s' "${gated}" | grep -q 'publish'; then
      echo "${file}: \`apko lock\` is gated on publish, so PRs never run it"
    fi
  done < <(ci_yaml "${root}")
}

# Prints one line per apko publish/build step that ignores the lock — a lock
# nothing builds from describes a resolution that never shipped.
scan_apko_unlocked() {
  local root="$1" file steps
  while IFS= read -r file; do
    [ -n "${file}" ] || continue
    steps="$(yq -r '
      [ .jobs[]?.steps[]?, .runs.steps[]? ]
      | .[]
      | select(((.run // "") | test("apko (publish|build) ")))
      | select(((.run // "") | test("--lockfile")) | not)
      | .name // "(unnamed step)"
    ' "${file}" 2>/dev/null || true)"
    while IFS= read -r step; do
      [ -n "${step}" ] || continue
      echo "${file}: '${step}' runs apko without --lockfile"
    done <<< "${steps}"
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

# A lock next to an apko.yaml is a committed one by definition.
checks=$((checks + 1))
locks="$(find "${REPO_ROOT}/images" -name '*.lock.json' -o -name 'apko.lock*' 2>/dev/null)"
[ -z "${locks}" ] || fail "apko lockfile(s) committed next to an image — images would stop picking up updates:
${locks}"

# Every --lockfile must name a RUNNER_TEMP path, on the flag's own line — keep it
# inline rather than behind an `env:` indirection so this check stays possible.
checks=$((checks + 1))
offenders="$(grep -rn -- '--lockfile' \
  "${REPO_ROOT}/.github/workflows" "${REPO_ROOT}/.github/actions" 2>/dev/null \
  | grep -v -e 'RUNNER_TEMP' -e 'runner\.temp' || true)"
[ -z "${offenders}" ] || fail "--lockfile reads a path not generated by this run:
${offenders}"

checks=$((checks + 1))
offenders="$(scan_lock_gated "${REPO_ROOT}/.github")"
[ -z "${offenders}" ] || fail "the lock is not produced on PR runs:
${offenders}"

checks=$((checks + 1))
offenders="$(scan_apko_unlocked "${REPO_ROOT}/.github")"
[ -z "${offenders}" ] || fail "the generated lock never reaches apko, so it cannot describe the built image:
${offenders}"

# The cache we *do* persist must stay the content-addressed source cache, keyed
# by the expected-sha256 in the melange configs, which cannot serve different
# content than it is asked for. Located by scanning the CI tree rather than one
# named workflow, so moving the build into a reusable workflow doesn't turn this
# into a false alarm.
checks=$((checks + 1))
if ! grep -rq 'melange-cache' "${REPO_ROOT}/.github/workflows/"; then
  fail "the melange source cache disappeared from CI — see the freshness rules in AGENTS.md"
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

# A cached lockfile freezes the images exactly like a cached apk dir.
cat > "${TMP}/.github/workflows/good.yml" <<'YAML'
name: bad
on: workflow_dispatch
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/cache@v4
        with:
          path: ${{ runner.temp }}/apko.lock.json
          key: lock-debug
YAML
assert_eq "detects a cached lockfile" "1" \
  "$(scan_caches "${TMP}/.github" | wc -l)"

# --- fixtures: the lock must be produced on PRs and reach apko --------------
rm -f "${TMP}/.github/workflows/good.yml"
cat > "${TMP}/.github/workflows/lock.yml" <<'YAML'
name: lock
on: workflow_call
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - name: Lock the resolved package set
        if: inputs.publish
        run: apko lock --output "${RUNNER_TEMP}/apko.lock.json" apko.yaml
      - name: Publish
        run: apko publish --lockfile "${RUNNER_TEMP}/apko.lock.json" apko.yaml ref
YAML
assert_eq "detects a lock step a PR would skip" "1" \
  "$(scan_lock_gated "${TMP}/.github" | wc -l)"
assert_eq "accepts an apko step that consumes the lock" "0" \
  "$(scan_apko_unlocked "${TMP}/.github" | wc -l)"

cat > "${TMP}/.github/workflows/lock.yml" <<'YAML'
name: lock
on: workflow_call
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - name: Lock the resolved package set
        run: apko lock --output "${RUNNER_TEMP}/apko.lock.json" apko.yaml
      - name: Build image tar
        run: apko build --sbom-path . apko.yaml ref image.tar
      - name: Publish
        run: apko publish --lockfile "${RUNNER_TEMP}/apko.lock.json" apko.yaml ref
YAML
assert_eq "ungated lock step passes" "0" \
  "$(scan_lock_gated "${TMP}/.github" | wc -l)"
assert_eq "detects the apko step that ignores the lock" "1" \
  "$(scan_apko_unlocked "${TMP}/.github" | wc -l)"

if [ "${fails}" -ne 0 ]; then
  echo "nightly-freshness: ${fails}/${checks} failed" >&2
  exit 1
fi
echo "nightly-freshness: ${checks} checks passed"
