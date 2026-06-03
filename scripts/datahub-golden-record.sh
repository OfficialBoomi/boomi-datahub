#!/usr/bin/env bash
# DataHub Golden Record operations.
# All Repository API except `get-by-source` (Platform API).
# Every sub-command requires ALLOW_GR_ACTIONS=true in .env (covers reads too).

source "$(dirname "$0")/datahub-common.sh"

usage() {
  cat <<'EOF'
Usage: datahub-golden-record.sh <subcommand> [args]

GATED: set ALLOW_GR_ACTIONS=true in .env to enable.

Repository API ops (need --universe; read DATAHUB_REPO_* from .env).
Bodies are XML — the Repository API is XML-only on both sides.

  query    --universe <uid> <query-xml>                         POST /records/query
  get      --universe <uid> <record-id> [--accept <type>]       GET /records/<id>
  history  --universe <uid> <record-id> [--accept <type>]       GET /records/<id>/history
  meta     --universe <uid> <record-id> [--accept <type>]       GET /records/<id>/meta
  match    --universe <uid> <candidate-xml>                     POST /match
  update   --universe <uid> <records-xml>                       POST /records (upsert)
  unlink   --universe <uid> <record-id> <source-id>             DELETE /records/<id>/sources/<sourceId>

Platform API op:
  get-by-source --repository <repo-id> --universe <uid> --source <source-id> <entity-id> [--accept <type>]

`--accept <type>` overrides the Accept header for diagnostic probes (e.g. `application/json`
to compare against the default XML). `get-by-source` defaults to XML because the Platform
API JSON serializer is broken for that endpoint's success path.
EOF
}
[[ -z "${1:-}" || "${1:-}" == "--help" || "${1:-}" == "-h" ]] && { usage; exit 0; }

sub="$1"; shift

load_env
require_env BOOMI_USERNAME BOOMI_API_TOKEN BOOMI_ACCOUNT_ID BOOMI_API_URL
require_tools curl

if [[ "${ALLOW_GR_ACTIONS:-}" != "true" ]]; then
  echo "ERROR: golden-record operations are disabled." >&2
  echo "Set ALLOW_GR_ACTIONS=true in .env to enable. Gated by default because" >&2
  echo "golden record data is master data and may contain sensitive content." >&2
  exit 1
fi

# Parse --universe out of positional args (Repository API ops).
uid=""; positionals=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --universe) uid="$2"; shift 2;;
    *) positionals+=("$1"); shift;;
  esac
done
set -- "${positionals[@]}"

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
    id="$1"; shift
    accept_args=()
    [[ "${1:-}" == "--accept" ]] && { accept_args=(-H "Accept: $2"); shift 2; }
    datahub_api --repo-auth "${accept_args[@]}" "$(repo_url "records/${id}")"
    ;;
  history)
    [[ -z "${1:-}" ]] && { echo "Need <record-id>" >&2; exit 1; }
    id="$1"; shift
    accept_args=()
    [[ "${1:-}" == "--accept" ]] && { accept_args=(-H "Accept: $2"); shift 2; }
    datahub_api --repo-auth "${accept_args[@]}" "$(repo_url "records/${id}/history")"
    ;;
  meta)
    [[ -z "${1:-}" ]] && { echo "Need <record-id>" >&2; exit 1; }
    id="$1"; shift
    accept_args=()
    [[ "${1:-}" == "--accept" ]] && { accept_args=(-H "Accept: $2"); shift 2; }
    datahub_api --repo-auth "${accept_args[@]}" "$(repo_url "records/${id}/meta")"
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
    datahub_api --repo-auth -X DELETE "$(repo_url "records/$1/sources/$2")"
    ;;
  get-by-source)
    # Platform API's JSON serializer is broken for the success path on this endpoint
    # (returns truncated `{"@type":"Record","data":{"@type":"","data"`). XML is the
    # working default; `--accept` overrides for diagnostic probes.
    # --universe was already extracted by the top-level parser into $uid.
    repo=""; src=""; remaining=()
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --repository) repo="$2"; shift 2;;
        --source) src="$2"; shift 2;;
        *) remaining+=("$1"); shift;;
      esac
    done
    set -- "${remaining[@]}"
    [[ -z "$repo" || -z "$uid" || -z "$src" || -z "${1:-}" ]] && { echo "Need --repository <repo-id> --universe <uid> --source <source-id> <entity-id>" >&2; exit 1; }
    eid="$1"; shift
    accept="application/xml"
    [[ "${1:-}" == "--accept" ]] && { accept="$2"; shift 2; }
    datahub_api -H "Accept: ${accept}" "$(datahub_platform_url "repositories/${repo}/universes/${uid}/records/sources/${src}/entities/${eid}")"
    ;;
  *) usage >&2; exit 1;;
esac

if (( RESPONSE_CODE < 200 || RESPONSE_CODE >= 300 )); then
  echo "ERROR: HTTP $RESPONSE_CODE" >&2
  echo "$RESPONSE_BODY" >&2
  exit 1
fi
echo "$RESPONSE_BODY"
