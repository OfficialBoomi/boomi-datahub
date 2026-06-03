#!/usr/bin/env bash
# DataHub Repository operations (Platform API).

source "$(dirname "$0")/datahub-common.sh"

usage() {
  cat <<'EOF'
Usage: datahub-repository.sh <subcommand> [args]

Subcommands:
  list                                                 all repositories accessible to the account
  get <repository-id> [--universe <universe-id>]       one repository's summary; with --universe,
                                                       just that universe's entry within the repo
  status <repository-id>                               creation/operational status
  clouds                        Hub Clouds (infrastructure regions)
  create <cloud-id> <name>      create a repository in a Hub Cloud

Reads BOOMI_* from .env.
EOF
}
[[ -z "${1:-}" || "${1:-}" == "--help" || "${1:-}" == "-h" ]] && { usage; exit 0; }

sub="$1"; shift

load_env
require_env BOOMI_USERNAME BOOMI_API_TOKEN BOOMI_ACCOUNT_ID BOOMI_API_URL
require_tools curl

case "$sub" in
  list)
    datahub_api -H "Accept: application/json" "$(datahub_platform_url "repositories")"
    ;;
  get)
    [[ -z "${1:-}" ]] && { echo "Need <repository-id>" >&2; exit 1; }
    repo_id="$1"; shift
    universe_id=""
    [[ "${1:-}" == "--universe" ]] && { universe_id="$2"; shift 2; }
    if [[ -n "$universe_id" ]]; then
      datahub_api -H "Accept: application/json" "$(datahub_platform_url "repositories/${repo_id}/universes/${universe_id}")"
    else
      datahub_api -H "Accept: application/json" "$(datahub_platform_url "repositories/${repo_id}")"
    fi
    ;;
  status)
    [[ -z "${1:-}" ]] && { echo "Need <repository-id>" >&2; exit 1; }
    datahub_api -H "Accept: application/json" "$(datahub_platform_url "repositories/$1/status")"
    ;;
  clouds)
    datahub_api -H "Accept: application/json" "$(datahub_platform_url "clouds")"
    ;;
  create)
    [[ -z "${1:-}" || -z "${2:-}" ]] && { echo "Need <cloud-id> <name>" >&2; exit 1; }
    datahub_api -X POST "$(datahub_platform_url "clouds/$1/repositories/$2/create")"
    ;;
  *) usage >&2; exit 1;;
esac

if (( RESPONSE_CODE < 200 || RESPONSE_CODE >= 300 )); then
  echo "ERROR: HTTP $RESPONSE_CODE" >&2
  echo "$RESPONSE_BODY" >&2
  exit 1
fi
echo "$RESPONSE_BODY"
