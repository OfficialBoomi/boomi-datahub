#!/usr/bin/env bash
# DataHub REST client connection bootstrap.
#
# Why this exists: DataHub's auth token (DATAHUB_REPO_AUTH_TOKEN in .env) is
# needed in two places — our datahub-* CLIs read it from .env to hit the
# Repository API directly, AND Boomi integration processes that talk to
# DataHub via the REST client need the same token configured on a Boomi
# connection component. Without this script, the user maintains the same
# credential in both .env and the Boomi GUI, and mirrors any rotation.
#
# Alternatives considered and rejected:
#   - Ask the user to manually configure the GUI connection — real friction.
#   - JWT-based REST connections — would let us drop DATAHUB_REPO_* from .env,
#     but JWTs minted from BOOMI_* creds can hit any repo the account has
#     access to, losing per-repo scoping (scratchpad #5c).
#   - Generic .env templating in bc-integration's component-push — heavy
#     philosophical shift, affects all of its connections, not just this one
#     bridge.
#
# How it works: the auth token flows .env → bash subshell → curl stdin →
# platform encrypted storage. It never enters agent context. The platform
# auto-encrypts password-type fields on new Component create. See scratchpad
# #5d on acceptable bridges between workspace .env and platform encrypted
# storage.
#
# Trust note: the script's discipline (no echoes, no curl -v, sanitized
# errors) is established by one-time human code review of this source.
# Future invocations trust the file.

set +x  # defeat xtrace in calling shell

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/datahub-common.sh"

usage() {
  cat <<'EOF'
Usage: datahub-connection.sh bootstrap <name> <folder-id>

Creates a Boomi REST client connection component wired to this workspace's
DataHub credentials (DATAHUB_REPO_URI / _USERNAME / _AUTH_TOKEN from .env).
Prints the new component ID on success.
EOF
}
[[ -z "${1:-}" || "${1:-}" == "--help" || "${1:-}" == "-h" ]] && { usage; exit 0; }

sub="$1"; shift
case "$sub" in
  bootstrap) ;;
  *) usage >&2; exit 1;;
esac

[[ -z "${1:-}" || -z "${2:-}" ]] && { echo "Need <name> <folder-id>" >&2; exit 1; }
name="$1"
folder_id="$2"

require_tools curl
load_env
require_env BOOMI_USERNAME BOOMI_API_TOKEN BOOMI_ACCOUNT_ID BOOMI_API_URL \
            DATAHUB_REPO_URI DATAHUB_REPO_USERNAME DATAHUB_REPO_AUTH_TOKEN

url="${BOOMI_API_URL}/api/rest/v1/${BOOMI_ACCOUNT_ID}/Component"

# Heredoc as stdin (not `cat | datahub_api`) so the function runs in the
# current shell and RESPONSE_CODE / RESPONSE_BODY propagate back. Piping
# into a function puts the function in a subshell and assignments are lost.
datahub_api -X POST -H "Content-Type: application/xml" --data-binary @- "$url" <<XML
<?xml version="1.0" encoding="UTF-8"?>
<bns:Component xmlns:bns="http://api.platform.boomi.com/"
               xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
               name="${name}"
               type="connector-settings"
               subType="officialboomi-X3979C-rest-prod"
               folderId="${folder_id}">
  <bns:encryptedValues/>
  <bns:object>
    <GenericConnectionConfig>
      <field id="url" type="string" value="${DATAHUB_REPO_URI}"/>
      <field id="auth" type="string" value="BASIC"/>
      <field id="username" type="string" value="${DATAHUB_REPO_USERNAME}"/>
      <field id="password" type="password" value="${DATAHUB_REPO_AUTH_TOKEN}"/>
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

if [[ -z "$RESPONSE_CODE" ]]; then
  echo "ERROR: Component create did not return an HTTP code (network or invocation issue)." >&2
  echo "  The component may have been created server-side anyway — check the Boomi UI for" >&2
  echo "  a component named '${name}' before retrying, to avoid creating a duplicate." >&2
  exit 1
fi
if (( RESPONSE_CODE < 200 || RESPONSE_CODE >= 300 )); then
  echo "ERROR: Component create failed (HTTP $RESPONSE_CODE)" >&2
  echo "$RESPONSE_BODY" | head -c 500 >&2
  exit 1
fi

# Extract componentId from the response root attribute. Do NOT print RESPONSE_BODY —
# the full component XML includes username and other fields we shouldn't surface.
component_id=$(echo "$RESPONSE_BODY" | grep -o 'componentId="[^"]*"' | head -1 | sed 's/componentId="//;s/"$//')
[[ -z "$component_id" ]] && { echo "ERROR: Component created but could not parse componentId from response" >&2; exit 1; }
echo "$component_id"
