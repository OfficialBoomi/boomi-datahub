#!/usr/bin/env bash
# Shared utilities for boomi-datahub CLI tools
# Sourced by all tool scripts — not executed directly

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

# --- Version ---

_skill_version() {
  cat "$(dirname "${BASH_SOURCE[0]}")/../VERSION" 2>/dev/null || echo "unknown"
}

# --- Constants ---

DATAHUB_USER_AGENT="boomi-companion/boomi-datahub/$(_skill_version)"

# --- URL builders ---

# Platform API: account-level admin. `endpoint` is the part after /<accountID>/.
# Example: datahub_platform_url "models"
#   → https://api.boomi.com/mdm/api/rest/v1/<accountID>/models
datahub_platform_url() {
  local endpoint="$1"
  echo "${BOOMI_API_URL}/mdm/api/rest/v1/${BOOMI_ACCOUNT_ID}/${endpoint}"
}

# Repository API: per-repository. `repo_base_url` is the repo's own base URL
# (from the platform UI's repository Configure tab). Tolerates the value with
# or without a trailing /mdm — appends /mdm if missing, since the platform
# response omits it but every Repository API path lives under /mdm.
datahub_repo_url() {
  local repo_base_url="${1%/}"
  local endpoint="$2"
  [[ "$repo_base_url" != */mdm ]] && repo_base_url+="/mdm"
  echo "${repo_base_url}/${endpoint}"
}

# --- API helpers ---

# Sets RESPONSE_BODY and RESPONSE_CODE after each call.
# Usage:
#   datahub_api [--repo-auth] [curl args...]
# Default auth (Platform API): BOOMI_TOKEN.${BOOMI_USERNAME}:${BOOMI_API_TOKEN}
# With --repo-auth: ${DATAHUB_REPO_USERNAME}:${DATAHUB_REPO_AUTH_TOKEN}
#   (both read from .env; never passed on the command line)
RESPONSE_BODY=""
RESPONSE_CODE=""
datahub_api() {
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
  RESPONSE_CODE=$(curl -s $ssl_flag \
    --max-time "${BOOMI_TIMEOUT:-60}" \
    -A "$DATAHUB_USER_AGENT" \
    -u "$userpass" \
    -o "$tmpfile" -w "%{http_code}" \
    "$@")
  RESPONSE_BODY=$(cat "$tmpfile")
  rm -f "$tmpfile"
}
