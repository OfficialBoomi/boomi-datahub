#!/usr/bin/env bash
# DataHub Deployment operations (Platform API; list via Repository API).

source "$(dirname "$0")/datahub-common.sh"

usage() {
  cat <<'EOF'
Usage: datahub-deployment.sh <subcommand> [args]

Subcommands (Platform API except `list`):
  deploy <universe-id> <repository-id> --version <v>   --version is required
  undeploy <repository-id> <universe-id>
  status <universe-id> <deployment-id>
  list                                                  list deployed universes (Repository API)

Reads BOOMI_* from .env. `list` also reads DATAHUB_REPO_* from .env.
EOF
}
[[ -z "${1:-}" || "${1:-}" == "--help" || "${1:-}" == "-h" ]] && { usage; exit 0; }

sub="$1"; shift

load_env
require_env BOOMI_USERNAME BOOMI_API_TOKEN BOOMI_ACCOUNT_ID BOOMI_API_URL
require_tools curl

case "$sub" in
  deploy)
    [[ -z "${1:-}" || -z "${2:-}" ]] && { echo "Need <universe-id> <repository-id>" >&2; exit 1; }
    uid="$1"; repo="$2"; shift 2
    version=""
    [[ "${1:-}" == "--version" ]] && { version="$2"; shift 2; }
    [[ -z "$version" ]] && { echo "Need --version <v>" >&2; exit 1; }
    url="$(datahub_platform_url "universe/${uid}/deploy")?version=${version}&repositoryId=${repo}"
    datahub_api -X POST "$url"
    ;;
  undeploy)
    [[ -z "${1:-}" || -z "${2:-}" ]] && { echo "Need <repository-id> <universe-id>" >&2; exit 1; }
    datahub_api -X DELETE "$(datahub_platform_url "repositories/$1/universe/$2")"
    ;;
  status)
    [[ -z "${1:-}" || -z "${2:-}" ]] && { echo "Need <universe-id> <deployment-id>" >&2; exit 1; }
    datahub_api -H "Accept: application/json" "$(datahub_platform_url "universe/$1/deployments/$2")"
    ;;
  list)
    require_env DATAHUB_REPO_URI
    datahub_api --repo-auth "$(datahub_repo_url "$DATAHUB_REPO_URI" "universes")"
    ;;
  *) usage >&2; exit 1;;
esac

if (( RESPONSE_CODE < 200 || RESPONSE_CODE >= 300 )); then
  echo "ERROR: HTTP $RESPONSE_CODE" >&2
  echo "$RESPONSE_BODY" >&2
  exit 1
fi
echo "$RESPONSE_BODY"
