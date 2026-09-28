#!/usr/bin/env bash
# Data Hub Golden Record operations (all Repository API).

source "$(dirname "$0")/datahub-common.sh"

usage() {
  cat <<'EOF'
Usage: datahub-golden-record.sh <subcommand> [args]

Repository API ops (need --universe; read DATAHUB_REPO_* from .env).
Bodies are XML — the Repository API is XML-only on both sides.

  query          --universe <uid> <query-xml>                      POST   /records/query
  query-enddated --universe <uid> <query-xml>                      POST   /records/enddated
  get            --universe <uid> <record-id>                      GET    /records/<id>
  history        --universe <uid> <record-id>                      GET    /records/<id>/history
  meta           --universe <uid> <record-id>                      GET    /records/<id>/meta
  match          --universe <uid> <candidate-xml>                  POST   /match
  update         --universe <uid> <records-xml>                    POST   /records (upsert)
  enddate        --universe <uid> <record-id>                      POST   /records/<id>/enddate
  enddate-bulk   --universe <uid> <request-xml>                    POST   /records/enddate
  restore        --universe <uid> --source <source-id> <entity-id> POST   /records/sources/<sourceId>/entities/<entityId>/restore
  unlink         --universe <uid> <record-id> <source-id>          DELETE /records/<id>/sources/<sourceId>/unlink
  get-by-source  --universe <uid> --source <source-id> <entity-id> GET    /records/sources/<sourceId>/entities/<entityId>

query hides end-dated records — use query-enddated. restore is keyed on the source
entity (read it from meta), not the record id.
EOF
}
[[ -z "${1:-}" ]] && { usage; exit 0; }
help_requested "$@"

sub="$1"; shift

load_env
require_tools curl

# --source feeds get-by-source and restore; whitelisted so the loop doesn't reject it.
uid=""; src=""; positionals=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    # Guard the value slot: under set -u a trailing flag expands $2 unbound, which
    # aborts with a raw interpreter error instead of the usage message.
    --universe) [[ -z "${2:-}" ]] && { echo "Need <universe-id> after --universe" >&2; exit 1; }
                uid="$2"; shift 2;;
    --source)   [[ -z "${2:-}" ]] && { echo "Need <source-id> after --source" >&2; exit 1; }
                src="$2"; shift 2;;
    -*) reject_flags "$1";;
    *) positionals+=("$1"); shift;;
  esac
done
set -- "${positionals[@]+"${positionals[@]}"}"

# Validate in the main shell: repo_url() runs as $(...), where an exit would only kill
# the subshell, leaving datahub_api to run with a blank URL. All subs need both.
require_env DATAHUB_REPO_URI
[[ -z "$uid" ]] && { echo "Need --universe <id>" >&2; exit 1; }

repo_url() {
  datahub_repo_url "$DATAHUB_REPO_URI" "universes/${uid}/$1"
}

case "$sub" in
  query)
    [[ -z "${1:-}" || ! -f "$1" ]] && { echo "Need <query-xml>" >&2; exit 1; }
    datahub_api --repo-auth -X POST -H "Content-Type: application/xml" --data-binary "@$1" "$(repo_url "records/query")"
    ;;
  get)
    [[ -z "${1:-}" ]] && { echo "Need <record-id>" >&2; exit 1; }
    id="$1"
    datahub_api --repo-auth "$(repo_url "records/${id}")"
    ;;
  history)
    [[ -z "${1:-}" ]] && { echo "Need <record-id>" >&2; exit 1; }
    id="$1"
    datahub_api --repo-auth "$(repo_url "records/${id}/history")"
    ;;
  meta)
    [[ -z "${1:-}" ]] && { echo "Need <record-id>" >&2; exit 1; }
    id="$1"
    datahub_api --repo-auth "$(repo_url "records/${id}/meta")"
    ;;
  match)
    [[ -z "${1:-}" || ! -f "$1" ]] && { echo "Need <candidate-xml>" >&2; exit 1; }
    datahub_api --repo-auth -X POST -H "Content-Type: application/xml" --data-binary "@$1" "$(repo_url "match")"
    ;;
  update)
    [[ -z "${1:-}" || ! -f "$1" ]] && { echo "Need <records-xml>" >&2; exit 1; }
    datahub_api --repo-auth -X POST -H "Content-Type: application/xml" --data-binary "@$1" "$(repo_url "records")"
    ;;
  query-enddated)
    [[ -z "${1:-}" || ! -f "$1" ]] && { echo "Need <query-xml>" >&2; exit 1; }
    datahub_api --repo-auth -X POST -H "Content-Type: application/xml" --data-binary "@$1" "$(repo_url "records/enddated")"
    ;;
  enddate)
    [[ -z "${1:-}" ]] && { echo "Need <record-id>" >&2; exit 1; }
    # No request body.
    datahub_api --repo-auth -X POST -H "Content-Type: application/xml" "$(repo_url "records/$1/enddate")"
    ;;
  enddate-bulk)
    [[ -z "${1:-}" || ! -f "$1" ]] && { echo "Need <request-xml>" >&2; exit 1; }
    datahub_api --repo-auth -X POST -H "Content-Type: application/xml" --data-binary "@$1" "$(repo_url "records/enddate")"
    ;;
  restore)
    [[ -z "$src" || -z "${1:-}" ]] && { echo "Need --source <source-id> <entity-id>" >&2; exit 1; }
    datahub_api --repo-auth -X POST -H "Content-Type: application/xml" "$(repo_url "records/sources/${src}/entities/$1/restore")"
    ;;
  unlink)
    [[ -z "${1:-}" || -z "${2:-}" ]] && { echo "Need <record-id> <source-id>" >&2; exit 1; }
    # Trailing /unlink verb required, else the request is a silent no-op.
    datahub_api --repo-auth -X DELETE "$(repo_url "records/$1/sources/$2/unlink")"
    ;;
  get-by-source)
    [[ -z "$uid" || -z "$src" || -z "${1:-}" ]] && { echo "Need --universe <uid> --source <source-id> <entity-id>" >&2; exit 1; }
    eid="$1"
    datahub_api --repo-auth "$(repo_url "records/sources/${src}/entities/${eid}")"
    ;;
  *) usage >&2; exit 1;;
esac

if (( RESPONSE_CODE < 200 || RESPONSE_CODE >= 300 )); then
  echo "ERROR: HTTP $RESPONSE_CODE" >&2
  echo "$RESPONSE_BODY" >&2
  exit 1
fi
echo "$RESPONSE_BODY"
