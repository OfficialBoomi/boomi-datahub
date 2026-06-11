#!/usr/bin/env bash
# Shared utilities for boomi-datahub CLI tools; sourced, not executed directly.

set -euo pipefail

# --- Environment ---

load_env() {
  local env_file=".env"
  if [[ -f "$env_file" ]]; then
    set -a
    source "$env_file"
    set +a
  else
    echo "ERROR: .env file not found in $(pwd)" >&2
    exit 1
  fi
}

require_env() {
  local missing=()
  for var in "$@"; do
    if [[ -z "${!var:-}" ]]; then
      missing+=("$var")
    fi
  done
  if [[ ${#missing[@]} -gt 0 ]]; then
    echo "ERROR: Missing required environment variables: ${missing[*]}" >&2
    echo "Check your .env file." >&2
    exit 1
  fi
}

require_tools() {
  local missing=()
  for tool in "$@"; do
    if ! command -v "$tool" &>/dev/null; then
      missing+=("$tool")
    fi
  done
  if [[ ${#missing[@]} -gt 0 ]]; then
    echo "ERROR: Missing required tools: ${missing[*]}" >&2
    exit 1
  fi
}

# --- Argument handling ---

# Pass the full arg vector before load_env so --help works after the subcommand.
help_requested() {
  local arg
  for arg in "$@"; do
    case "$arg" in --help|-h) usage; exit 0 ;; esac
  done
}

# Must exit (not return): shift-less callers loop forever otherwise.
reject_flags() {
  local arg
  for arg in "$@"; do
    case "$arg" in -*) echo "ERROR: unexpected option '$arg'" >&2; usage >&2; exit 1 ;; esac
  done
}

# --- Version ---

_skill_version() {
  cat "$(dirname "${BASH_SOURCE[0]}")/../VERSION" 2>/dev/null || echo "unknown"
}

# --- Constants ---

DATAHUB_USER_AGENT="boomi-companion/boomi-datahub/$(_skill_version)"

# --- URL builders ---

# Platform API URL; `endpoint` is the part after /<accountID>/.
datahub_platform_url() {
  local endpoint="$1"
  echo "${BOOMI_API_URL}/mdm/api/rest/v1/${BOOMI_ACCOUNT_ID}/${endpoint}"
}

# Repository API URL; appends /mdm to the base if missing.
datahub_repo_url() {
  local repo_base_url="${1%/}"
  local endpoint="$2"
  [[ "$repo_base_url" != */mdm ]] && repo_base_url+="/mdm"
  echo "${repo_base_url}/${endpoint}"
}

# --- API helpers ---

# Sets RESPONSE_BODY and RESPONSE_CODE. --repo-auth uses DATAHUB_REPO_* creds, else Platform API.
RESPONSE_BODY=""
RESPONSE_CODE=""
datahub_api() {
  # Disable xtrace so a caller's set -x can't leak the token.
  local _xtrace_enabled=0
  case $- in *x*) _xtrace_enabled=1 ;; esac
  set +x

  local userpass="BOOMI_TOKEN.${BOOMI_USERNAME}:${BOOMI_API_TOKEN}"
  if [[ "${1:-}" == "--repo-auth" ]]; then
    : "${DATAHUB_REPO_USERNAME:?DATAHUB_REPO_USERNAME must be set in .env}"
    : "${DATAHUB_REPO_AUTH_TOKEN:?DATAHUB_REPO_AUTH_TOKEN must be set in .env}"
    userpass="${DATAHUB_REPO_USERNAME}:${DATAHUB_REPO_AUTH_TOKEN}"
    shift
  fi

  local ssl_flag=""
  [[ "${BOOMI_VERIFY_SSL:-true}" == "false" ]] && ssl_flag="-k"

  local tmpfile
  tmpfile=$(mktemp)

  # Run curl without errexit so connection failures return, not abort.
  local rc
  set +e
  RESPONSE_CODE=$(curl -s $ssl_flag \
    --max-time "${BOOMI_TIMEOUT:-60}" \
    -A "$DATAHUB_USER_AGENT" \
    -u "$userpass" \
    -o "$tmpfile" -w "%{http_code}" \
    "$@")
  rc=$?
  set -e
  RESPONSE_BODY=$(cat "$tmpfile")
  rm -f "$tmpfile"

  # Restore the caller's xtrace setting.
  (( _xtrace_enabled )) && set -x

  if (( rc != 0 )) || [[ -z "$RESPONSE_CODE" || "$RESPONSE_CODE" == "000" ]]; then
    echo "ERROR: could not reach the Boomi API -- network or connection failure (curl exit ${rc})." >&2
    echo "  Likely a request timeout (BOOMI_TIMEOUT=${BOOMI_TIMEOUT:-60}s), DNS failure, refused" >&2
    echo "  connection, or no network. No HTTP response was received, so the request may or may" >&2
    echo "  not have reached the server." >&2
    return 1
  fi
  return 0
}

# Hint a model may be draft-only when --draft wasn't passed.
maybe_draft_hint() {
  [[ -z "$2" && "$RESPONSE_BODY" == *"is not a valid component ID"* ]] \
    && echo "HINT: model '$1' may be draft-only (never published). Retry with --draft." >&2 || true
}

# --- Polling ---

# Poll .status until it equals <target> (~60s); fail on error or timeout.
wait_for_state() {
  local url="$1" target="$2" attempt state
  for (( attempt=1; attempt<=30; attempt++ )); do
    datahub_api -H "Accept: application/json" "$url"
    (( RESPONSE_CODE < 200 || RESPONSE_CODE >= 300 )) && { echo "ERROR: HTTP $RESPONSE_CODE while waiting for $target" >&2; echo "$RESPONSE_BODY" >&2; return 1; }
    state=$(printf '%s' "$RESPONSE_BODY" | sed -n 's/.*"status"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
    [[ "$state" == "$target" ]] && return 0
    sleep 2
  done
  echo "ERROR: status still '${state:-none}' after ~60s waiting for $target" >&2
  return 1
}

# Poll until .status is anything other than <transient> (~60s).
wait_while_state() {
  local url="$1" transient="$2" attempt state
  for (( attempt=1; attempt<=30; attempt++ )); do
    datahub_api -H "Accept: application/json" "$url"
    (( RESPONSE_CODE < 200 || RESPONSE_CODE >= 300 )) && { echo "ERROR: HTTP $RESPONSE_CODE while waiting out $transient" >&2; echo "$RESPONSE_BODY" >&2; return 1; }
    state=$(printf '%s' "$RESPONSE_BODY" | sed -n 's/.*"status"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
    [[ -n "$state" && "$state" != "$transient" ]] && return 0
    sleep 2
  done
  echo "ERROR: status still '$transient' after ~60s" >&2
  return 1
}
