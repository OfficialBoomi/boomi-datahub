#!/usr/bin/env bash
# DataHub Source operations (Platform API).

source "$(dirname "$0")/datahub-common.sh"

usage() {
  cat <<'EOF'
Usage: datahub-source.sh <subcommand> [args]

Subcommands:
  list
  get  <source-id>
  pull <source-id> [--target-path <p>]   save XML to a working file (default active-development/mdm.source/<id>.xml)
  status              --repository <repo-id> --universe <uid> <source-id>
  enable-initial-load --repository <repo-id> --universe <uid> <source-id>   (two sequential waits, blocks up to ~2 min; emits the final status JSON)
  finish-initial-load --repository <repo-id> --universe <uid> <source-id>   (blocks ≤60s for the async transition; emits the final status JSON)
  create <xml-file>
  update <source-id> <xml-file>
  delete <source-id>

Reads BOOMI_* from .env.
EOF
}
[[ -z "${1:-}" ]] && { usage; exit 0; }
help_requested "$@"

sub="$1"; shift

load_env
require_env BOOMI_USERNAME BOOMI_API_TOKEN BOOMI_ACCOUNT_ID BOOMI_API_URL
require_tools curl

case "$sub" in
  list)
    [[ $# -gt 0 ]] && { echo "list takes no arguments (got: $*)." >&2; echo "  Use 'status --repository <r> --universe <u> <source-id>' for per-source state." >&2; exit 1; }
    datahub_api -H "Accept: application/json" "$(datahub_platform_url "sources")"
    ;;
  get)
    [[ -z "${1:-}" ]] && { echo "Need <source-id>" >&2; exit 1; }
    datahub_api -H "Accept: application/json" "$(datahub_platform_url "sources/$1")"
    ;;
  pull)
    [[ -z "${1:-}" ]] && { echo "Need <source-id>" >&2; exit 1; }
    id="$1"; shift
    target=""
    [[ "${1:-}" == "--target-path" ]] && { target="$2"; shift 2; }
    [[ -z "$target" ]] && target="active-development/mdm.source/${id}.xml"
    datahub_api -H "Accept: application/xml" "$(datahub_platform_url "sources/${id}")"
    if (( RESPONSE_CODE < 200 || RESPONSE_CODE >= 300 )); then
      echo "ERROR: HTTP $RESPONSE_CODE" >&2
      echo "$RESPONSE_BODY" >&2
      exit 1
    fi
    mkdir -p "$(dirname "$target")"
    echo "$RESPONSE_BODY" > "$target"
    echo "Saved to: $target"
    exit 0
    ;;
  status|enable-initial-load|finish-initial-load)
    repo_id=""; universe_id=""; remaining=()
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --repository) repo_id="$2"; shift 2;;
        --universe) universe_id="$2"; shift 2;;
        -*) reject_flags "$1";;
        *) remaining+=("$1"); shift;;
      esac
    done
    set -- "${remaining[@]+"${remaining[@]}"}"
    [[ -z "$repo_id" || -z "$universe_id" || -z "${1:-}" ]] && { echo "Need --repository <repo-id> --universe <uid> <source-id>" >&2; exit 1; }
    base="repositories/${repo_id}/universes/${universe_id}/sources/$1"
    status_url="$(datahub_platform_url "${base}/status")"
    case "$sub" in
      status)              datahub_api -H "Accept: application/json" "$status_url" ;;
      enable-initial-load)
        # Wait out async attach, POST, then wait until enabled.
        wait_while_state "$status_url" SOURCE_ATTACHMENT_REQUESTED || exit 1
        datahub_api -X POST "$(datahub_platform_url "${base}/enableInitialLoad")"
        (( RESPONSE_CODE < 200 || RESPONSE_CODE >= 300 )) && { echo "ERROR: HTTP $RESPONSE_CODE" >&2; echo "$RESPONSE_BODY" >&2; exit 1; }
        wait_for_state "$status_url" INITIAL_LOAD_ENABLED || exit 1
        echo "$RESPONSE_BODY"; exit 0
        ;;
      finish-initial-load)
        # POST, then wait until finished (one-at-a-time lock).
        datahub_api -X POST "$(datahub_platform_url "${base}/finishInitialLoad")"
        (( RESPONSE_CODE < 200 || RESPONSE_CODE >= 300 )) && { echo "ERROR: HTTP $RESPONSE_CODE" >&2; echo "$RESPONSE_BODY" >&2; exit 1; }
        wait_for_state "$status_url" INITIAL_LOAD_FINISHED || exit 1
        echo "$RESPONSE_BODY"; exit 0
        ;;
    esac
    ;;
  create)
    [[ -z "${1:-}" || ! -f "$1" ]] && { echo "Need <xml-file>" >&2; exit 1; }
    datahub_api -X POST -H "Content-Type: application/xml" --data-binary "@$1" "$(datahub_platform_url "sources/create")"
    ;;
  update)
    [[ -z "${1:-}" || -z "${2:-}" || ! -f "$2" ]] && { echo "Need <source-id> <xml-file>" >&2; exit 1; }
    datahub_api -X PUT -H "Content-Type: application/xml" --data-binary "@$2" "$(datahub_platform_url "sources/$1")"
    ;;
  delete)
    [[ -z "${1:-}" ]] && { echo "Need <source-id>" >&2; exit 1; }
    datahub_api -X DELETE "$(datahub_platform_url "sources/$1")"
    ;;
  *) usage >&2; exit 1;;
esac

if (( RESPONSE_CODE < 200 || RESPONSE_CODE >= 300 )); then
  echo "ERROR: HTTP $RESPONSE_CODE" >&2
  echo "$RESPONSE_BODY" >&2
  exit 1
fi
echo "$RESPONSE_BODY"
