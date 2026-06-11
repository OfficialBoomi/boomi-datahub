#!/usr/bin/env bash
# DataHub Golden Record operations (all Repository API).

source "$(dirname "$0")/datahub-common.sh"

usage() {
  cat <<'EOF'
Usage: datahub-golden-record.sh <subcommand> [args]

Repository API ops (need --universe; read DATAHUB_REPO_* from .env).
Bodies are XML — the Repository API is XML-only on both sides.

  query          --universe <uid> <query-xml>                      POST   /records/query
  get            --universe <uid> <record-id>                      GET    /records/<id>
  history        --universe <uid> <record-id>                      GET    /records/<id>/history
  meta           --universe <uid> <record-id>                      GET    /records/<id>/meta
  match          --universe <uid> <candidate-xml>                  POST   /match
  update         --universe <uid> <records-xml>                    POST   /records (upsert)
  unlink         --universe <uid> <record-id> <source-id>          DELETE /records/<id>/sources/<sourceId>/unlink
  get-by-source  --universe <uid> --source <source-id> <entity-id> GET    /records/sources/<sourceId>/entities/<entityId>
EOF
}
[[ -z "${1:-}" ]] && { usage; exit 0; }
help_requested "$@"

sub="$1"; shift

load_env
require_tools curl

# --source feeds get-by-source; whitelisted so the loop doesn't reject it.
uid=""; src=""; positionals=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --universe) uid="$2"; shift 2;;
    --source) src="$2"; shift 2;;
    -*) reject_flags "$1";;
    *) positionals+=("$1"); shift;;
  esac
done
set -- "${positionals[@]+"${positionals[@]}"}"

repo_url() {
  require_env DATAHUB_REPO_URI
  [[ -z "$uid" ]] && { echo "Need --universe <id>" >&2; exit 1; }
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
