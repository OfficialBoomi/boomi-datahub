#!/usr/bin/env bash
# Bootstrap a Boomi REST client connection wired to .env DataHub creds.

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
[[ -z "${1:-}" ]] && { usage; exit 0; }
help_requested "$@"

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

# Heredoc stdin (not pipe) so RESPONSE_CODE/BODY propagate from the current shell.
if ! datahub_api -X POST -H "Content-Type: application/xml" --data-binary @- "$url" <<XML
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
then
  echo "  The component may have been created server-side anyway — check the Boomi UI for" >&2
  echo "  a component named '${name}' before retrying, to avoid creating a duplicate." >&2
  exit 1
fi
if (( RESPONSE_CODE < 200 || RESPONSE_CODE >= 300 )); then
  echo "ERROR: Component create failed (HTTP $RESPONSE_CODE)" >&2
  echo "$RESPONSE_BODY" | head -c 500 >&2
  exit 1
fi

# Don't print RESPONSE_BODY — it contains the username/password fields.
component_id=$(echo "$RESPONSE_BODY" | grep -o 'componentId="[^"]*"' | head -1 | sed 's/componentId="//;s/"$//' || true)
[[ -z "$component_id" ]] && { echo "ERROR: Component created but could not parse componentId from response" >&2; exit 1; }
echo "$component_id"
