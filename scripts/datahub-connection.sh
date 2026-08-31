#!/usr/bin/env bash
# Bootstrap a Boomi connection wired to .env Data Hub creds (REST client or Data Hub connector).

# The response echoes back the repo credentials; this script can't be safely traced.
set +x

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/datahub-common.sh"

usage() {
  cat <<'EOF'
Usage: datahub-connection.sh bootstrap <rest|connector> <name> <folder-id>

Creates a Boomi connection component wired to this workspace's Data Hub
credentials (DATAHUB_REPO_URI / _USERNAME / _AUTH_TOKEN from .env) and prints
the new component ID.

  rest       REST client connection pointed at the repository API. Paths used
             with it must include the /mdm/ prefix (e.g. /mdm/universes/<id>/records).
  connector  Boomi Data Hub connector connection, for use with Data Hub
             connector operations. Its Cloud Name is derived from the
             DATAHUB_REPO_URI host, which must be a Boomi-hosted Hub Cloud.

The two are not interchangeable: connector operations only work against the
connector's own connection, and the REST client only against the repository API.
EOF
}
[[ -z "${1:-}" ]] && { usage; exit 0; }
help_requested "$@"

sub="$1"; shift
case "$sub" in
  bootstrap) ;;
  *) usage >&2; exit 1;;
esac

reject_flags "$@"

kind="${1:-}"
if [[ $# -gt 0 ]]; then shift; fi
case "$kind" in
  rest|connector) ;;
  "") echo "ERROR: bootstrap needs a connection kind: 'rest' or 'connector'" >&2; usage >&2; exit 1;;
  *)  echo "ERROR: unknown connection kind '$kind' (expected 'rest' or 'connector')" >&2; usage >&2; exit 1;;
esac

[[ -z "${1:-}" || -z "${2:-}" ]] && { echo "Need <name> <folder-id>" >&2; exit 1; }
name="$1"
folder_id="$2"
shift 2
[[ $# -gt 0 ]] && { echo "ERROR: unexpected argument '$1'" >&2; usage >&2; exit 1; }

# Hub Cloud host to the connector's own Cloud Name string. These differ from the
# names the Platform API reports, so they can't be derived. Unlisted hosts fail.
cloud_name_for_host() {
  case "$1" in
    c01-usa-east.hub.boomi.com)  echo "USA East Hub Cloud (formerly US Hub Cloud)" ;;
    c02-usa-east.hub.boomi.com)  echo "USA East Hub Cloud 02" ;;
    c01-ca.hub.boomi.com)        echo "Canada Hub Cloud 01" ;;
    c01-gbr.hub.boomi.com)       echo "GBR Hub Cloud" ;;
    c01-deu.hub.boomi.com)       echo "DEU Hub Cloud 01" ;;
    c01-aus.hub.boomi.com)       echo "ANZ Hub Cloud" ;;
    c01-aus-local.hub.boomi.com) echo "ANZ Local Hub Cloud 01" ;;
    c01-sg.hub.boomi.com)        echo "Singapore Hub Cloud 01" ;;
    c01-jp.hub.boomi.com)        echo "Japan Hub Cloud 01" ;;
    *) return 1 ;;
  esac
}

# XML-escape one attribute value. A function, not a child process, so a credential
# never reaches an argv. Callers pass credentials — the whole-script set +x above
# is what keeps them out of a trace; a fence here would be too late, since the
# caller's trace line prints the expanded argument before this body runs.
xml_attr() {
  local v="$1"
  v="${v//&/&amp;}"
  v="${v//</&lt;}"
  v="${v//>/&gt;}"
  v="${v//\"/&quot;}"
  printf '%s' "$v"
}

require_tools curl
load_env
require_env BOOMI_USERNAME BOOMI_API_TOKEN BOOMI_ACCOUNT_ID BOOMI_API_URL \
            DATAHUB_REPO_URI DATAHUB_REPO_USERNAME DATAHUB_REPO_AUTH_TOKEN

if [[ "$kind" == "connector" ]]; then
  repo_host="${DATAHUB_REPO_URI#*://}"
  repo_host="${repo_host%%/*}"
  repo_host="${repo_host%%:*}"
  if ! cloud_name="$(cloud_name_for_host "$repo_host")"; then
    echo "ERROR: '$repo_host' is not a Hub Cloud this script can name." >&2
    echo "  Build the connection in the Boomi UI — pick the Cloud Name from its drop-down, or" >&2
    echo "  for a custom Hub Cloud use the Custom Cloud field — and supply the component ID." >&2
    exit 1
  fi
fi

url="${BOOMI_API_URL}/api/rest/v1/${BOOMI_ACCOUNT_ID}/Component"

# Body via tempfile, not stdin — datahub_api reserves stdin for the curl auth config.
body_file="$(mktemp)"
trap 'rm -f "$body_file"' EXIT

if [[ "$kind" == "rest" ]]; then
cat > "$body_file" <<XML
<?xml version="1.0" encoding="UTF-8"?>
<bns:Component xmlns:bns="http://api.platform.boomi.com/"
               xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
               name="$(xml_attr "$name")"
               type="connector-settings"
               subType="officialboomi-X3979C-rest-prod"
               folderId="$(xml_attr "$folder_id")">
  <bns:encryptedValues/>
  <bns:object>
    <GenericConnectionConfig>
      <field id="url" type="string" value="$(xml_attr "$DATAHUB_REPO_URI")"/>
      <field id="auth" type="string" value="BASIC"/>
      <field id="username" type="string" value="$(xml_attr "$DATAHUB_REPO_USERNAME")"/>
      <field id="password" type="password" value="$(xml_attr "$DATAHUB_REPO_AUTH_TOKEN")"/>
      <field id="preemptive" type="boolean" value="true"/>
      <field id="connectTimeout" type="integer" value="-1"/>
      <field id="readTimeout" type="integer" value="-1"/>
      <field id="cookieScope" type="string" value="GLOBAL"/>
      <field id="enableConnectionPooling" type="boolean" value="false"/>
      <field id="domain" type="string" value=""/>
      <field id="workstation" type="string" value=""/>
      <field id="customAuthCredentials" type="password" value=""/>
      <field id="awsAccessKey" type="string" value=""/>
      <field id="awsSecretKey" type="password" value=""/>
      <field id="awsService" type="string" value=""/>
      <field id="customAwsService" type="string" value=""/>
      <field id="awsRegion" type="string" value=""/>
      <field id="customAwsRegion" type="string" value=""/>
      <field id="awsProfileArn" type="string" value=""/>
      <field id="awsRoleArn" type="string" value=""/>
      <field id="awsTrustAnchorArn" type="string" value=""/>
      <field id="awsRolesAnywhereRegion" type="string" value=""/>
      <field id="awsRolesAnywhereCustomRegion" type="string" value=""/>
      <field id="awsSessionName" type="string" value=""/>
      <field id="awsDuration" type="integer" value=""/>
      <field id="awsPublicCertificate" type="publiccertificate" value=""/>
      <field id="awsPrivateKey" type="privatecertificate" value=""/>
      <field id="oauthContext" type="oauth">
        <OAuth2Config grantType="code">
          <credentials clientId=""/>
          <authorizationTokenEndpoint url=""><sslOptions/></authorizationTokenEndpoint>
          <authorizationParameters/>
          <accessTokenEndpoint url=""><sslOptions/></accessTokenEndpoint>
          <accessTokenParameters/>
          <scope/>
          <jwtParameters><expiration>0</expiration></jwtParameters>
        </OAuth2Config>
      </field>
      <field id="privateCertificate" type="privatecertificate"/>
      <field id="publicCertificate" type="publiccertificate"/>
      <field id="maxTotal" type="integer" value=""/>
      <field id="idleTimeout" type="integer" value=""/>
    </GenericConnectionConfig>
  </bns:object>
</bns:Component>
XML
else
# customUrl is the Custom Cloud alternative to cloudName; only one is set.
cat > "$body_file" <<XML
<?xml version="1.0" encoding="UTF-8"?>
<bns:Component xmlns:bns="http://api.platform.boomi.com/"
               xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
               name="$(xml_attr "$name")"
               type="connector-settings"
               subType="officialboomi-X3979C-boomid-prod"
               folderId="$(xml_attr "$folder_id")">
  <bns:encryptedValues/>
  <bns:object>
    <GenericConnectionConfig>
      <field id="cloudName" type="string" value="$(xml_attr "$cloud_name")"/>
      <field id="customUrl" type="string" value=""/>
      <field id="accountId" type="string" value="$(xml_attr "$DATAHUB_REPO_USERNAME")"/>
      <field id="token" type="password" value="$(xml_attr "$DATAHUB_REPO_AUTH_TOKEN")"/>
    </GenericConnectionConfig>
  </bns:object>
</bns:Component>
XML
fi

if ! datahub_api -X POST -H "Content-Type: application/xml" --data-binary "@${body_file}" "$url"; then
  echo "  The component may have been created server-side anyway — check the Boomi UI for" >&2
  echo "  a component named '${name}' before retrying, to avoid creating a duplicate." >&2
  exit 1
fi
if (( RESPONSE_CODE < 200 || RESPONSE_CODE >= 300 )); then
  echo "ERROR: Component create failed (HTTP $RESPONSE_CODE)" >&2
  echo "$RESPONSE_BODY" | head -c 500 >&2
  exit 1
fi

# Don't print RESPONSE_BODY — it contains the credential fields.
component_id=$(echo "$RESPONSE_BODY" | grep -o 'componentId="[^"]*"' | head -1 | sed 's/componentId="//;s/"$//' || true)
[[ -z "$component_id" ]] && { echo "ERROR: Component created but could not parse componentId from response" >&2; exit 1; }
echo "$component_id"
