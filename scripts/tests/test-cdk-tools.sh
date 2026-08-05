#!/usr/bin/env bash
#
# Tests for the cdk-* support scripts in images/debug/tools/. Runs on the host —
# no image build, no containers — so a TSE member can iterate quickly.
#
# Covers the redaction filter (the part with real consequences: this output goes
# into support tickets) and the structural invariants every tool must hold.
# Silent on success; prints only failures.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TOOLS="${REPO_ROOT}/images/debug/tools"

checks=0
fails=0

assert_eq() {
  checks=$((checks + 1))
  if [ "$2" != "$3" ]; then
    echo "  FAIL $1: want '$2', got '$3'" >&2
    fails=$((fails + 1))
  fi
}
fail() { fails=$((fails + 1)); echo "  FAIL $1" >&2; }

# shellcheck source-path=SCRIPTDIR
# shellcheck source=../../images/debug/tools/cdk-common.sh
. "${TOOLS}/cdk-common.sh"

# --- redaction: secrets must be masked ------------------------------------
redact() { printf '%s\n' "$1" | cdk_redact; }

assert_eq "env password"      "CDK_DATABASE_PASSWORD=***REDACTED***" "$(redact 'CDK_DATABASE_PASSWORD=hunter2')"
assert_eq "env token"         "CDK_ADMIN_TOKEN=***REDACTED***"       "$(redact 'CDK_ADMIN_TOKEN=tok_abc')"
assert_eq "env secret"        "MY_CLIENT_SECRET=***REDACTED***"      "$(redact 'MY_CLIENT_SECRET=abc')"
assert_eq "env license"       "CDK_LICENSE_KEY=***REDACTED***"       "$(redact 'CDK_LICENSE_KEY=eyJ')"
assert_eq "yaml password"     "  password: ***REDACTED***"           "$(redact '  password: hunter2')"
assert_eq "yaml nested key"   "  sslKeyPassword: ***REDACTED***"     "$(redact '  sslKeyPassword: hunter2')"
assert_eq "json quoted key"   '  "apiKey": ***REDACTED***'           "$(redact '  "apiKey": "abc123"')"
assert_eq "yaml list item"    "  - jaasConfig: ***REDACTED***"       "$(redact '  - jaasConfig: PlainLoginModule required')"
assert_eq "url credentials"   "url=postgres://u:***REDACTED***@db:5432/x" "$(redact 'url=postgres://u:hunter2@db:5432/x')"

# --- redaction: useful non-secrets must survive ---------------------------
assert_eq "truststore path kept"  "CDK_SSL_TRUSTSTORE_FILE=/opt/ts.jks" "$(redact 'CDK_SSL_TRUSTSTORE_FILE=/opt/ts.jks')"
assert_eq "keystore location"     "  keystoreLocation: /opt/ks.jks"     "$(redact '  keystoreLocation: /opt/ks.jks')"
assert_eq "bootstrap kept"        "CDK_KAFKA_BOOTSTRAP_SERVERS=k:9092"  "$(redact 'CDK_KAFKA_BOOTSTRAP_SERVERS=k:9092')"
assert_eq "log level kept"        "CDK_ROOT_LOG_LEVEL=DEBUG"            "$(redact 'CDK_ROOT_LOG_LEVEL=DEBUG')"
assert_eq "sasl mechanism kept"   "  saslMechanism: PLAIN"              "$(redact '  saslMechanism: PLAIN')"
assert_eq "plain url untouched"   "url=http://kafka:9092/x"             "$(redact 'url=http://kafka:9092/x')"

# A secret must never survive verbatim, whatever the shape.
for line in 'PASSWORD=s3cr3t' 'x_token: s3cr3t' 'DB_SECRET=s3cr3t' '"privateKey": "s3cr3t"'; do
  checks=$((checks + 1))
  case "$(redact "${line}")" in
    *s3cr3t*) fail "secret leaked through redaction: ${line}" ;;
  esac
done

# --- structural invariants for every tool ---------------------------------
shopt -s nullglob
tools=("${TOOLS}"/cdk-*)
[ "${#tools[@]}" -gt 1 ] || fail "no tools found in ${TOOLS}"

for t in "${tools[@]}"; do
  base="$(basename "${t}")"
  [ "${base}" = "cdk-common.sh" ] && continue

  checks=$((checks + 1))
  [ -x "${t}" ] || fail "${base} is not executable (melange installs mode 0755, keep it in sync)"

  checks=$((checks + 1))
  head -n1 "${t}" | grep -q '^#!/usr/bin/env bash' \
    || fail "${base} needs a '#!/usr/bin/env bash' shebang"

  checks=$((checks + 1))
  bash -n "${t}" 2>/dev/null || fail "${base} is not syntactically valid bash"

  # Every tool sources the library by its installed path, not a relative one.
  checks=$((checks + 1))
  grep -q '^\. /usr/local/lib/conduktor/cdk-common.sh$' "${t}" \
    || fail "${base} must source /usr/local/lib/conduktor/cdk-common.sh"

  checks=$((checks + 1))
  grep -q -- '-h|--help' "${t}" || fail "${base} must handle -h/--help"
done

# The library is sourced, so it must not be executable nor have a shebang that
# implies otherwise (melange installs it 0644).
checks=$((checks + 1))
[ ! -x "${TOOLS}/cdk-common.sh" ] || fail "cdk-common.sh is sourced and must not be executable"

# melange.yaml must install everything that exists, so a newly added tool can
# never be silently left out of the package.
checks=$((checks + 1))
grep -q 'for f in tools/cdk-\*' "${REPO_ROOT}/images/debug/melange.yaml" \
  || fail "melange.yaml no longer globs tools/cdk-* — new tools would not ship"

if [ "${fails}" -ne 0 ]; then
  echo "cdk-tools: ${fails}/${checks} failed" >&2
  exit 1
fi
echo "cdk-tools: ${checks} checks passed"
