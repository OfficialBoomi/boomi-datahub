#!/usr/bin/env bash
# DataHub Model operations (Platform API).

source "$(dirname "$0")/datahub-common.sh"

usage() {
  cat <<'EOF'
Usage: datahub-model.sh <subcommand> [args]

Subcommands:
  list [--name <n>] [--status all|draft|publish]
  get  <model-id> [--version <v>] [--draft] [--format xml|json]   default xml (round-trip parity)
  pull <model-id> [--version <v>] [--draft] [--target-path <p>]   save XML to a working file (default active-development/mdm.model/<id>.xml)
  publish <model-id> [--notes <text>]
  create <xml-file>
  update <model-id> <xml-file>
  delete <model-id>                                              confirm with list or a second delete, not get (get returns 200 for deleted models)

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
    name=""; status=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --name)   name="$2"; shift 2;;
        --status) status="$2"; shift 2;;
        *) echo "Unknown arg: $1" >&2; exit 1;;
      esac
    done
    q=""
    [[ -n "$name" ]]   && q+="${q:+&}name=${name}"
    [[ -n "$status" ]] && q+="${q:+&}publicationStatus=${status}"
    url="$(datahub_platform_url "models")"
    [[ -n "$q" ]] && url+="?${q}"
    datahub_api -H "Accept: application/json" "$url"
    ;;
  get)
    [[ -z "${1:-}" ]] && { echo "Need <model-id>" >&2; exit 1; }
    id="$1"; shift
    version=""; draft=""; format="xml"
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --version) version="$2"; shift 2;;
        --draft)   draft=true; shift;;
        --format)  format="$2"; shift 2;;
        *) echo "Unknown arg: $1" >&2; exit 1;;
      esac
    done
    case "$format" in
      xml)  accept="application/xml";;
      json) accept="application/json";;
      *) echo "Invalid --format (use xml|json)" >&2; exit 1;;
    esac
    qs=""
    [[ -n "$version" ]] && qs+="${qs:+&}version=${version}"
    [[ -n "$draft"   ]] && qs+="${qs:+&}draft=true"
    url="$(datahub_platform_url "models/${id}")"
    [[ -n "$qs" ]] && url+="?${qs}"
    datahub_api -H "Accept: ${accept}" "$url"
    maybe_draft_hint "$id" "$draft"
    ;;
  create)
    [[ -z "${1:-}" || ! -f "$1" ]] && { echo "Need <xml-file>" >&2; exit 1; }
    url="$(datahub_platform_url "models")"
    datahub_api -X POST -H "Content-Type: application/xml" --data-binary "@$1" "$url"
    ;;
  update)
    [[ -z "${1:-}" || -z "${2:-}" || ! -f "$2" ]] && { echo "Need <model-id> <xml-file>" >&2; exit 1; }
    url="$(datahub_platform_url "models/$1")"
    datahub_api -X PUT -H "Content-Type: application/xml" --data-binary "@$2" "$url"
    ;;
  delete)
    [[ -z "${1:-}" ]] && { echo "Need <model-id>" >&2; exit 1; }
    url="$(datahub_platform_url "models/$1")"
    datahub_api -X DELETE "$url"
    ;;
  pull)
    [[ -z "${1:-}" ]] && { echo "Need <model-id>" >&2; exit 1; }
    id="$1"; shift
    target=""; version=""; draft=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --target-path) target="$2"; shift 2;;
        --version)     version="$2"; shift 2;;
        --draft)       draft=true; shift;;
        *) echo "Unknown arg: $1" >&2; exit 1;;
      esac
    done
    [[ -z "$target" ]] && target="active-development/mdm.model/${id}.xml"
    qs=""
    [[ -n "$version" ]] && qs+="${qs:+&}version=${version}"
    [[ -n "$draft"   ]] && qs+="${qs:+&}draft=true"
    url="$(datahub_platform_url "models/${id}")"
    [[ -n "$qs" ]] && url+="?${qs}"
    datahub_api -H "Accept: application/xml" "$url"
    maybe_draft_hint "$id" "$draft"
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
  publish)
    [[ -z "${1:-}" ]] && { echo "Need <model-id>" >&2; exit 1; }
    id="$1"; shift
    notes=""
    [[ "${1:-}" == "--notes" ]] && { notes="$2"; shift 2; }
    url="$(datahub_platform_url "models/${id}/publish")"
    body="<mdm:PublishModelRequest xmlns:mdm=\"http://mdm.api.platform.boomi.com/\"><mdm:notes>${notes}</mdm:notes></mdm:PublishModelRequest>"
    datahub_api -X POST -H "Content-Type: application/xml" --data-binary "$body" "$url"
    ;;
  *) usage >&2; exit 1;;
esac

if (( RESPONSE_CODE < 200 || RESPONSE_CODE >= 300 )); then
  echo "ERROR: HTTP $RESPONSE_CODE" >&2
  echo "$RESPONSE_BODY" >&2
  exit 1
fi
echo "$RESPONSE_BODY"
