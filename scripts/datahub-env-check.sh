#!/usr/bin/env bash
# Verify .env vars and reach the Platform API; Repository API is informational.

source "$(dirname "$0")/datahub-common.sh"

usage() {
  cat <<'EOF'
Usage: datahub-env-check.sh [--help]

Reports two surfaces:
  - Platform API (required)     fails if missing or unreachable
  - Repository API (optional)   live check if keys set; warns (non-fatal) on failure
EOF
}
[[ "${1:-}" == "--help" || "${1:-}" == "-h" ]] && { usage; exit 0; }

load_env
require_env BOOMI_USERNAME BOOMI_API_TOKEN BOOMI_ACCOUNT_ID BOOMI_API_URL
require_tools curl

echo "=== Platform API (required) ==="
for v in BOOMI_USERNAME BOOMI_API_TOKEN BOOMI_ACCOUNT_ID BOOMI_API_URL; do
  [[ -n "${!v:-}" ]] && echo "  $v=SET" || echo "  $v=UNSET"
done

url="$(datahub_platform_url "clouds")"
echo "  GET $url"
# Tolerate connection failure so the FAIL line reports it.
datahub_api -H "Accept: application/json" "$url" || true

if (( RESPONSE_CODE < 200 || RESPONSE_CODE >= 300 )); then
  echo "  HTTP $RESPONSE_CODE — FAIL" >&2
  echo "  Response: $RESPONSE_BODY" >&2
  exit 1
fi
echo "  HTTP $RESPONSE_CODE — OK (authenticated as ${BOOMI_USERNAME})"

echo
echo "=== Repository API (optional) ==="
missing=0
for v in DATAHUB_REPO_URI DATAHUB_REPO_USERNAME DATAHUB_REPO_AUTH_TOKEN; do
  [[ -n "${!v:-}" ]] && echo "  $v=SET" || { echo "  $v=UNSET"; missing=1; }
done
if (( missing )); then
  echo "  Set the three keys above to enable Repository API sub-commands"
  echo "  (deployment.sh list, quarantine.sh query, all of golden-record.sh)."
else
  repo_url="$(datahub_repo_url "$DATAHUB_REPO_URI" "universes")"
  echo "  GET $repo_url"
  # Non-fatal: fall through to the WARN branch on failure.
  datahub_api --repo-auth "$repo_url" || true
  if (( RESPONSE_CODE >= 200 && RESPONSE_CODE < 300 )); then
    count=$(printf '%s' "$RESPONSE_BODY" | grep -o '<universe>' | wc -l | tr -d ' ') || true
    echo "  HTTP $RESPONSE_CODE — OK (auth accepted; reached a repository with ${count} deployed universe(s))"
    echo "  Note: a valid token for a different repository on the same cluster also returns 2xx."
    echo "  Confirm it's the intended repository with: deployment.sh list"
  else
    echo "  HTTP $RESPONSE_CODE — WARN (Repository API call failed; details on stderr)"
    echo "  HTTP $RESPONSE_CODE — WARN: keys are set but the Repository API call failed." >&2
    echo "  Response: $RESPONSE_BODY" >&2
    echo "  Repository sub-commands won't work until this resolves. Platform-only workflows" >&2
    echo "  are unaffected, so env-check still passes." >&2
  fi
fi
