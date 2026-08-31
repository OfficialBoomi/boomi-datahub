#!/usr/bin/env bash
# Data Hub Model operations (Platform API).

source "$(dirname "$0")/datahub-common.sh"

usage() {
  cat <<'EOF'
Usage: datahub-model.sh <subcommand> [args]

Subcommands:
  list [--name <n>] [--status all|draft|publish]
  get  <model-id> [--version <v>] [--draft] [--format xml|json]   default xml (round-trip parity)
  pull <model-id> [--version <v>] [--draft] [--target-path <p>]   save XML to a working file (default active-development/mdm.model/<id>.xml)
  quality-steps <model-id> [--version <v>] [--draft]              print just the <mdm:dataQualitySteps> block
  add-quality-step <model-id> <step-file> [--draft] [--dry-run]   splice a <mdm:step> into that block
  remove-quality-step <model-id> (--name <n> | --id <i>) [--draft] [--dry-run]
  publish <model-id> [--notes <text>]
  create <xml-file>
  update <model-id> <xml-file>
  delete <model-id>                                              confirm with list or a second delete, not get (get returns 200 for deleted models)

add-quality-step / remove-quality-step edit data quality steps (not match rules) and
write back as a draft; the published version is never changed in place. --draft picks
the version the edit builds from, so every edit after the first needs it -- a write that
would discard an existing draft refuses. --dry-run prints the block, writes nothing.
Publish and deploy to take effect.

Reads BOOMI_* from .env.
EOF
}
[[ -z "${1:-}" ]] && { usage; exit 0; }
help_requested "$@"

# --- Data quality step helpers ---
# The Platform API serves a model as single-line XML. <mdm:step> never nests, so
# splitting on its opening tag isolates whole steps without an XML parser.

DQ_BLOCK=""   # the <mdm:dataQualitySteps> element verbatim, as it appears in the document
DQ_INNER=""   # its contents; empty for <mdm:dataQualitySteps/>

dq_extract() {
  local doc="$1"
  [[ "$doc" != *"<mdm:dataQualitySteps"* ]] && return 1
  if [[ "$doc" == *"<mdm:dataQualitySteps>"* ]]; then
    DQ_INNER="${doc#*<mdm:dataQualitySteps>}"
    DQ_INNER="${DQ_INNER%%</mdm:dataQualitySteps>*}"
    DQ_BLOCK="<mdm:dataQualitySteps>${DQ_INNER}</mdm:dataQualitySteps>"
  else
    local empty_tag="${doc#*<mdm:dataQualitySteps}"
    DQ_BLOCK="<mdm:dataQualitySteps${empty_tag%%>*}>"
    DQ_INNER=""
  fi
  return 0
}

# Rebuild the block, collapsing back to the empty element when no steps remain.
dq_block_from() {
  [[ -z "$1" ]] && { printf '<mdm:dataQualitySteps/>'; return; }
  printf '<mdm:dataQualitySteps>%s</mdm:dataQualitySteps>' "$1"
}

# Swap the block into the document and retarget the root element for an update request.
dq_rewrite() {
  local doc="$1" new_block="$2"
  local prefix="${doc%%"$DQ_BLOCK"*}" suffix="${doc#*"$DQ_BLOCK"}"
  doc="${prefix}${new_block}${suffix}"
  printf '%s' "${doc//mdm:GetModelResponse/mdm:UpdateModelRequest}"
}

# Drop steps whose own opening tag carries attr="val". The closing quote in the
# needle is what keeps name="Price" from matching name="Price Rule".
DQ_MATCHES=0
DQ_PRUNED=""
dq_prune() {
  local needle="$1=\"$2\"" line opening
  DQ_MATCHES=0
  DQ_PRUNED=""
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    opening="${line%%>*}"
    if [[ "$opening" == *"$needle"* ]]; then
      DQ_MATCHES=$(( DQ_MATCHES + 1 ))
      continue
    fi
    DQ_PRUNED+="$line"
  done <<< "${DQ_INNER//<mdm:step/$'\n'<mdm:step}"
}

# Read a <mdm:step> from a file: strip any XML declaration, join lines, and drop
# only whitespace that sits between tags so element text is never disturbed.
# A standalone step file must declare the mdm namespace to be well-formed on its own;
# inside the model document the root already declares it, so drop the duplicate.
dq_read_step_file() {
  local step
  step=$(tr -d '\n\r' < "$1" \
    | sed -e 's/<?xml[^>]*?>//' \
          -e 's/ xmlns:mdm="http:\/\/mdm\.api\.platform\.boomi\.com\/"//g' \
          -e 's/>[[:space:]]*</></g')
  step="${step#"${step%%[![:space:]]*}"}"
  step="${step%"${step##*[![:space:]]}"}"
  printf '%s' "$step"
}

# Fetch a model as XML into RESPONSE_BODY, exiting on a non-2xx.
# A write always lands as a new draft. Sourcing that write from the published version
# while a draft exists would silently discard the draft's edits, so refuse instead.
dq_fetch_model() {
  local id="$1" draft="$2" url
  if [[ -z "$draft" ]]; then
    datahub_api -H "Accept: application/xml" "$(datahub_platform_url "models/${id}")?draft=true"
    if (( RESPONSE_CODE >= 200 && RESPONSE_CODE < 300 )); then
      echo "ERROR: model ${id} has an unpublished draft." >&2
      echo "  Re-run with --draft to build on it (sourcing the edit from the published" >&2
      echo "  version would discard the draft), or publish the draft first." >&2
      exit 1
    fi
  fi
  url="$(datahub_platform_url "models/${id}")"
  [[ -n "$draft" ]] && url+="?draft=true"
  datahub_api -H "Accept: application/xml" "$url"
  maybe_draft_hint "$id" "$draft"
  if (( RESPONSE_CODE < 200 || RESPONSE_CODE >= 300 )); then
    echo "ERROR: HTTP $RESPONSE_CODE" >&2
    echo "$RESPONSE_BODY" >&2
    exit 1
  fi
}

# PUT a rewritten model document back.
dq_push_model() {
  local id="$1" doc="$2" tmp
  tmp=$(mktemp)
  printf '%s' "$doc" > "$tmp"
  datahub_api -X PUT -H "Content-Type: application/xml" --data-binary "@$tmp" \
    "$(datahub_platform_url "models/${id}")"
  rm -f "$tmp"
}

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
    [[ -z "${1:-}" ]] && { echo "Need <xml-file>" >&2; exit 1; }
    [[ ! -f "$1"   ]] && { echo "File not found: $1" >&2; exit 1; }
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
  quality-steps)
    [[ -z "${1:-}" ]] && { echo "Need <model-id>" >&2; exit 1; }
    id="$1"; shift
    version=""; draft=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --version) version="$2"; shift 2;;
        --draft)   draft=true; shift;;
        *) echo "Unknown arg: $1" >&2; exit 1;;
      esac
    done
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
    # Populated form first: the alternation must not settle for the empty-element match.
    steps=$(printf '%s' "$RESPONSE_BODY" \
      | grep -oE '<mdm:dataQualitySteps>.*</mdm:dataQualitySteps>|<mdm:dataQualitySteps[[:space:]]*/>' || true)
    if [[ -z "$steps" ]]; then
      echo "ERROR: no <mdm:dataQualitySteps> block in model ${id}" >&2
      exit 1
    fi
    echo "$steps"
    exit 0
    ;;
  add-quality-step)
    [[ -z "${1:-}" || -z "${2:-}" ]] && { echo "Need <model-id> <step-file>" >&2; exit 1; }
    [[ ! -f "$2" ]] && { echo "File not found: $2" >&2; exit 1; }
    id="$1"; step_file="$2"; shift 2
    draft=""; dry=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --draft)   draft=true; shift;;
        --dry-run) dry=true; shift;;
        *) echo "Unknown arg: $1" >&2; exit 1;;
      esac
    done
    step="$(dq_read_step_file "$step_file")"
    step_ok=""
    [[ "$step" == "<mdm:step"* ]] && [[ "$step" == *"</mdm:step>" || "$step" == *"/>" ]] && step_ok=true
    if [[ -z "$step_ok" ]]; then
      echo "ERROR: $step_file must hold a single <mdm:step> element" >&2
      exit 1
    fi
    dq_fetch_model "$id" "$draft"
    model="$RESPONSE_BODY"
    dq_extract "$model" || { echo "ERROR: no <mdm:dataQualitySteps> block in model ${id}" >&2; exit 1; }
    new_block="$(dq_block_from "${DQ_INNER}${step}")"
    if [[ -n "$dry" ]]; then
      echo "$new_block"
      exit 0
    fi
    dq_push_model "$id" "$(dq_rewrite "$model" "$new_block")"
    ;;
  remove-quality-step)
    [[ -z "${1:-}" ]] && { echo "Need <model-id>" >&2; exit 1; }
    id="$1"; shift
    draft=""; dry=""; sel_attr=""; sel_val=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --name)    sel_attr="name"; sel_val="$2"; shift 2;;
        --id)      sel_attr="id";   sel_val="$2"; shift 2;;
        --draft)   draft=true; shift;;
        --dry-run) dry=true; shift;;
        *) echo "Unknown arg: $1" >&2; exit 1;;
      esac
    done
    [[ -z "$sel_attr" ]] && { echo "Need --name <n> or --id <i>" >&2; exit 1; }
    dq_fetch_model "$id" "$draft"
    model="$RESPONSE_BODY"
    dq_extract "$model" || { echo "ERROR: no <mdm:dataQualitySteps> block in model ${id}" >&2; exit 1; }
    dq_prune "$sel_attr" "$sel_val"
    if (( DQ_MATCHES == 0 )); then
      echo "ERROR: no data quality step with ${sel_attr}=\"${sel_val}\" in model ${id}" >&2
      exit 1
    fi
    # Names are not unique; removing an arbitrary one of several would be a coin flip.
    if (( DQ_MATCHES > 1 )); then
      echo "ERROR: ${DQ_MATCHES} steps carry ${sel_attr}=\"${sel_val}\"; re-run with --id to pick one" >&2
      exit 1
    fi
    new_block="$(dq_block_from "$DQ_PRUNED")"
    if [[ -n "$dry" ]]; then
      echo "$new_block"
      exit 0
    fi
    dq_push_model "$id" "$(dq_rewrite "$model" "$new_block")"
    ;;
  publish)
    [[ -z "${1:-}" ]] && { echo "Need <model-id>" >&2; exit 1; }
    id="$1"; shift
    notes=""
    [[ "${1:-}" == "--notes" ]] && { notes="$2"; shift 2; }
    # Entity-escape notes for XML interpolation; & first so produced entities aren't re-escaped.
    notes="${notes//&/&amp;}"; notes="${notes//</&lt;}"; notes="${notes//>/&gt;}"
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
