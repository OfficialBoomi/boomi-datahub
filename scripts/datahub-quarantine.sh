#!/usr/bin/env bash
# DataHub Quarantine operations. query → Repository API; get/approve/reject/delete → Platform API.

source "$(dirname "$0")/datahub-common.sh"

usage() {
  cat <<'EOF'
Usage: datahub-quarantine.sh <subcommand> [args]

Subcommands:
  query   --universe <uid> [<filter-xml-file>]      list entries (Repository API)
                                                    omit the file to return all ACTIVE entries
                                                    body is XML — the Repository API is XML-only on both sides
  reject  --universe <uid> <transaction-id>         Repository API (only available there)
  get     <repository-id> <universe-id> <transaction-id>     Platform API
  approve <repository-id> <universe-id> <transaction-id>     Platform API
  delete  <repository-id> <universe-id> <transaction-id>     Platform API

Reads BOOMI_* from .env. `query` and `reject` also read DATAHUB_REPO_* from .env.

Note: `approve` is only valid for ambiguity-class causes (POSSIBLE_DUPLICATE and
similar). All hard-fail causes (PARSE_FAILURE, FIELD_FORMAT_ERROR, REQUIRED_FIELD,
REFERENCE_UNKNOWN) are `delete`-only — `reject` returns HTTP 400 "not rejectable."
The fix is source-side: correct the payload and resubmit.
EOF
}
[[ -z "${1:-}" ]] && { usage; exit 0; }
help_requested "$@"

sub="$1"; shift

load_env
require_env BOOMI_USERNAME BOOMI_API_TOKEN BOOMI_ACCOUNT_ID BOOMI_API_URL
require_tools curl

case "$sub" in
  query)
    uid=""; filter=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --universe) uid="$2"; shift 2;;
        -*) reject_flags "$1";;
        *) filter="$1"; shift;;
      esac
    done
    [[ -z "$uid" ]] && { echo "Need --universe <uid> [<filter-xml-file>]" >&2; exit 1; }
    [[ -n "$filter" && ! -f "$filter" ]] && { echo "filter file not found: $filter" >&2; exit 1; }
    require_env DATAHUB_REPO_URI
    url="$(datahub_repo_url "$DATAHUB_REPO_URI" "universes/${uid}/quarantine/query")"
    if [[ -n "$filter" ]]; then
      datahub_api --repo-auth -X POST -H "Content-Type: application/xml" --data-binary "@${filter}" "$url"
    else
      datahub_api --repo-auth -X POST -H "Content-Type: application/xml" --data-binary "<QuarantineQueryRequest/>" "$url"
    fi
    ;;
  reject)
    uid=""; positionals=()
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --universe) uid="$2"; shift 2;;
        -*) reject_flags "$1";;
        *) positionals+=("$1"); shift;;
      esac
    done
    set -- "${positionals[@]+"${positionals[@]}"}"
    [[ -z "$uid" || -z "${1:-}" ]] && { echo "Need --universe <uid> <transaction-id>" >&2; exit 1; }
    require_env DATAHUB_REPO_URI
    url="$(datahub_repo_url "$DATAHUB_REPO_URI" "universes/${uid}/quarantine/$1/reject")"
    datahub_api --repo-auth -X POST "$url"
    ;;
  get|approve|delete)
    reject_flags "$@"
    [[ -z "${1:-}" || -z "${2:-}" || -z "${3:-}" ]] && { echo "Need <repository-id> <universe-id> <transaction-id>" >&2; exit 1; }
    p="repositories/$1/universes/$2/quarantine/$3"
    case "$sub" in
      get)     datahub_api -H "Accept: application/json" "$(datahub_platform_url "$p")";;
      approve) datahub_api -X POST "$(datahub_platform_url "${p}/approve")";;
      delete)  datahub_api -X POST "$(datahub_platform_url "${p}/delete")";;
    esac
    ;;
  *) usage >&2; exit 1;;
esac

if (( RESPONSE_CODE < 200 || RESPONSE_CODE >= 300 )); then
  echo "ERROR: HTTP $RESPONSE_CODE" >&2
  echo "$RESPONSE_BODY" >&2
  exit 1
fi
echo "$RESPONSE_BODY"
