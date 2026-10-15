#!/usr/bin/env bash
# common stuff used by all the other scripts (meant to be sourced, not run)

set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export ROOT_DIR

# read .env, but if a variable is already set in the shell keep that one.
# handy for overriding things in CI like  NEXUS_HOST=foo make bootstrap
load_env() {
  local env_file="${ROOT_DIR}/.env"
  [[ -f "$env_file" ]] || return 0
  local line key
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" =~ ^[[:space:]]*(#|$) ]] && continue
    key="${line%%=*}"
    [[ -n "${!key+x}" ]] || export "${line?}"
  done < "$env_file"
}

if [[ -t 1 ]]; then
  _c_info=$'\033[1;34m' _c_ok=$'\033[1;32m' _c_warn=$'\033[1;33m' _c_err=$'\033[1;31m' _c_off=$'\033[0m'
else
  _c_info='' _c_ok='' _c_warn='' _c_err='' _c_off=''
fi

log()  { printf '%s==>%s %s\n' "$_c_info" "$_c_off" "$*"; }
ok()   { printf '%s ✔%s  %s\n' "$_c_ok"   "$_c_off" "$*"; }
warn() { printf '%s !%s  %s\n' "$_c_warn" "$_c_off" "$*" >&2; }
die()  { printf '%s ✖%s  %s\n' "$_c_err"  "$_c_off" "$*" >&2; exit 1; }

require() {
  local cmd
  for cmd in "$@"; do
    command -v "$cmd" >/dev/null 2>&1 || die "Required command not found: $cmd"
  done
}

# use our own CA for TLS checks so we never need curl -k
nexus_curl() {
  local tls_opts=()
  if [[ -f "${ROOT_DIR}/certs/ca.crt" ]]; then
    tls_opts=(--cacert "${ROOT_DIR}/certs/ca.crt")
  fi
  curl -sS "${tls_opts[@]}" "$@"
}

_API_OUT="$(mktemp)"
trap 'rm -f "$_API_OUT"' EXIT

# api METHOD PATH [BODY] [CONTENT_TYPE]
# small wrapper around the nexus REST API. after it runs, API_CODE has the
# http status and API_BODY the response. returns success for any 2xx so it
# works nicely in if-statements.
api() {
  local method="$1" path="$2" body="${3:-}" ctype="${4:-application/json}"
  local args=(-X "$method" -u "$NEXUS_AUTH" -H 'Accept: application/json'
              -o "$_API_OUT" -w '%{http_code}')
  if [[ -n "$body" ]]; then
    args+=(-H "Content-Type: $ctype" --data "$body")
  fi
  API_CODE="$(nexus_curl "${args[@]}" "${NEXUS_URL}${path}")" || API_CODE=000
  API_BODY="$(cat "$_API_OUT")"
  [[ "$API_CODE" == 2* ]]
}

# same as api() but stop the script if the call fails
api_or_die() {
  api "$@" || die "$1 $2 failed (HTTP ${API_CODE}): ${API_BODY}"
}
