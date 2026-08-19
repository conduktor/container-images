# shellcheck shell=bash
#
# Shared library for the cdk-* tools, installed at
# /usr/local/lib/conduktor/cdk-common.sh. Sourced, never executed.
#
# Paths are read from the target process's own /proc/<pid>/environ rather than
# hardcoded, so a chart overriding CDK_VOLUME_DIR still works.

CDK_TOOLS_VERSION="0.1.0"

# --- output ----------------------------------------------------------------

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  _c_red=$'\033[31m'; _c_yel=$'\033[33m'; _c_grn=$'\033[32m'
  _c_dim=$'\033[2m';  _c_bold=$'\033[1m'; _c_off=$'\033[0m'
else
  _c_red=''; _c_yel=''; _c_grn=''; _c_dim=''; _c_bold=''; _c_off=''
fi

cdk_info() { printf '%s\n' "$*"; }
cdk_dim()  { printf '%s%s%s\n' "${_c_dim}" "$*" "${_c_off}"; }
cdk_head() { printf '\n%s== %s%s\n' "${_c_bold}" "$*" "${_c_off}"; }
cdk_ok()   { printf '%sok%s   %s\n' "${_c_grn}" "${_c_off}" "$*"; }
cdk_warn() { printf '%swarn%s %s\n' "${_c_yel}" "${_c_off}" "$*"; }
cdk_bad()  { printf '%sFAIL%s %s\n' "${_c_red}" "${_c_off}" "$*"; }
cdk_die()  { printf '%serror%s %s\n' "${_c_red}" "${_c_off}" "$*" >&2; exit 1; }

cdk_have() { command -v "$1" >/dev/null 2>&1; }
cdk_need() {
  cdk_have "$1" || cdk_die "'$1' is not in this image — see images/debug/apko.yaml"
}

cdk_version_line() { printf 'conduktor-debug-scripts %s\n' "${CDK_TOOLS_VERSION}"; }

# --- target process discovery ----------------------------------------------

# Empty when the sidecar has no shared PID namespace — the usual mistake.
cdk_jvm_pids() {
  local d pid cmd
  for d in /proc/[0-9]*; do
    pid="${d#/proc/}"
    [ -r "${d}/cmdline" ] || continue
    cmd="$(tr '\0' ' ' < "${d}/cmdline" 2>/dev/null)" || continue
    case "${cmd}" in
      *java*) printf '%s\n' "${pid}" ;;
    esac
  done
}

cdk_proc_cmd() { tr '\0' ' ' < "/proc/$1/cmdline" 2>/dev/null || printf '?'; }
cdk_proc_uid() { awk '/^Uid:/ {print $2; exit}' "/proc/$1/status" 2>/dev/null; }

# $CDK_TARGET_PID, else the only JVM. Refuses to guess between several.
cdk_target_pid() {
  if [ -n "${CDK_TARGET_PID:-}" ]; then
    [ -d "/proc/${CDK_TARGET_PID}" ] \
      || cdk_die "CDK_TARGET_PID=${CDK_TARGET_PID} is not a live process"
    printf '%s\n' "${CDK_TARGET_PID}"
    return
  fi

  local pids count p
  pids="$(cdk_jvm_pids)"
  count="$(printf '%s\n' "${pids}" | grep -c . || true)"

  if [ "${count}" = "0" ]; then
    cdk_die "no JVM visible. Start the sidecar with a shared PID namespace:
  Kubernetes: shareProcessNamespace: true
  Compose:    pid: \"service:<name>\"
  docker run: --pid container:<name>"
  fi

  if [ "${count}" != "1" ]; then
    {
      printf 'several JVMs visible — set CDK_TARGET_PID to pick one:\n'
      for p in ${pids}; do
        printf '  %-8s %s\n' "${p}" "$(cdk_proc_cmd "${p}" | cut -c1-90)"
      done
    } >&2
    exit 1
  fi

  printf '%s\n' "${pids}"
}

# Only the process owner (or root) may traverse /proc/<pid>/root, so this is
# where a UID mismatch surfaces; report it actionably rather than as EACCES.
cdk_proc_root() {
  local pid="$1" root="/proc/$1/root"
  if ! ls "${root}/" >/dev/null 2>&1; then
    cdk_die "cannot read ${root} (this container is uid $(id -u), target is uid $(cdk_proc_uid "${pid}")).
Run the sidecar with the same UID as the target, e.g. runAsUser: $(cdk_proc_uid "${pid}")."
  fi
  printf '%s\n' "${root}"
}

# One variable from the target's environment, with a fallback default.
cdk_target_env() {
  local pid="$1" var="$2" default="${3:-}" val
  val="$(tr '\0' '\n' < "/proc/${pid}/environ" 2>/dev/null \
         | sed -n "s/^${var}=//p" | head -n1)" || true
  printf '%s\n' "${val:-${default}}"
}

# --- Conduktor config layout ----------------------------------------------
#
# Paths come from the target's own environment; the defaults are only a fallback,
# so a deployment that relocates them still works.

cdk_conf_in_file() {
  local dir
  dir="$(cdk_target_env "$1" CDK_DIR /opt/conduktor)"
  cdk_target_env "$1" CDK_IN_CONF_FILE "${dir}/default-platform-config.yaml"
}

# Where platform-entrypoint renders the effective per-app configs.
cdk_conf_out_dir() {
  local vol
  vol="$(cdk_target_env "$1" CDK_VOLUME_DIR /var/conduktor)"
  cdk_target_env "$1" CDK_APPS_CONF_DIR "${vol}/configs"
}

cdk_log_dir() {
  local vol
  vol="$(cdk_target_env "$1" CDK_VOLUME_DIR /var/conduktor)"
  printf '%s/log\n' "${vol}"
}

cdk_listening_port() {
  local fallback
  fallback="$(cdk_target_env "$1" PLATFORM_LISTENING_PORT 8080)"
  cdk_target_env "$1" CDK_LISTENING_PORT "${fallback}"
}

# --- redaction -------------------------------------------------------------
#
# Masks secret-looking values; errs towards over-redacting because this output
# goes into support tickets. _FILE/_PATH/_LOCATION/_DIR/_TYPE/_ALGORITHM/_ENABLED
# keys are kept — a keystore's location is usually the answer, not a secret.
cdk_redact() {
  sed -E \
    -e '/^[[:space:]]*-?[[:space:]]*"?[A-Za-z0-9_.-]*(_FILE|_PATH|_LOCATION|_DIR|_TYPE|_ALGORITHM|_ENABLED)"?[[:space:]]*[:=]/b' \
    -e 's/^([[:space:]]*"?[A-Za-z0-9_.-]*(PASSWORD|PASSWD|SECRET|TOKEN|CREDENTIAL|APIKEY|API_KEY|JAAS|PRIVATE|LICENSE|SIGNATURE|SALT)[A-Za-z0-9_.-]*"?[[:space:]]*=)(.*)$/\1***REDACTED***/I' \
    -e 's/^([[:space:]]*-?[[:space:]]*"?[A-Za-z0-9_.-]*(password|passwd|secret|token|credential|apikey|api_key|jaas|private|license|signature|salt)[A-Za-z0-9_.-]*"?[[:space:]]*:)[[:space:]]*.+$/\1 ***REDACTED***/I' \
    -e 's#(://[^:/@[:space:]]+):[^@[:space:]]+@#\1:***REDACTED***@#g'
}

cdk_maybe_redact() {
  if [ -n "${CDK_NO_REDACT:-}" ]; then cat; else cdk_redact; fi
}

cdk_redact_note() {
  [ -n "${CDK_NO_REDACT:-}" ] && return 0
  cdk_dim "(secret-looking values masked — set CDK_NO_REDACT=1 to see them)"
}
