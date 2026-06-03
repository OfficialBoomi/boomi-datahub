---
name: boomi-datahub
description: Designs and operates Boomi DataHub master data — model and source design, deployment lifecycle, quarantine triage, and golden-record CRUD — when the user works with Boomi DataHub (MDM) configuration or stewardship. Pairs nicely with the boomi-integration skill.
---

# boomi-datahub

## Scope

In: model design; source configuration; model lifecycle (Draft → Published → Deployed); quarantine triage; repository operations; golden-record CRUD (gated behind `ALLOW_GR_ACTIONS=true`).

Out: building Boomi integration processes — those belong to `boomi-integration`. Integration processes that interact with DataHub (typically via the REST client) are `boomi-integration`'s territory; the REST client connection itself can be bootstrapped from this workspace's `.env` via `datahub-connection.sh bootstrap`.

## API surfaces

| Surface | Base URL | Auth | Used for |
|---|---|---|---|
| **Platform API** | `${BOOMI_API_URL}/mdm/api/rest/v1/${BOOMI_ACCOUNT_ID}/…` | Basic with `BOOMI_TOKEN.${BOOMI_USERNAME}:${BOOMI_API_TOKEN}` | Account-level admin: models, sources, repositories, clouds, deployment |
| **Repository API** | Per-repository base URL ending `/mdm` (from the repository's **Configure** tab) | Basic with `${BOOMI_ACCOUNT_ID}:<Hub Authentication Token>` or JWT | Per-repository: golden records, stewardship/quarantine, deployed-universe listing |

"Hub Cloud" is a runtime *cluster* that hosts repositories — not an API name.

The most common mistake is hitting the wrong surface or carrying the wrong auth header across surfaces. The **Repository API is XML-only on both request and response sides** — POST bodies must be `Content-Type: application/xml`, and responses cannot be negotiated to JSON via the `Accept` header. The Platform API speaks JSON on most read endpoints.

## Credentials

The `boomi-datahub` skill reads credentials from the workspace `.env` (see the plugin or skill `README.md` for the full contract). Sensitive values are never accepted as command-line arguments.

| Surface | `.env` keys |
|---|---|
| Platform API | `BOOMI_USERNAME`, `BOOMI_API_TOKEN`, `BOOMI_ACCOUNT_ID`, `BOOMI_API_URL` |
| Repository API | `DATAHUB_REPO_URI`, `DATAHUB_REPO_USERNAME`, `DATAHUB_REPO_AUTH_TOKEN` |
| Golden-record gate | `ALLOW_GR_ACTIONS=true` (required to enable any `datahub-golden-record.sh` sub-command, reads included) |

## Repository-scoped operations

A repository is the unit of deployment. Models, sources, channels, staging areas, golden records, and quarantine all live inside a repository. A repository has its own base URL (e.g. `https://c01-usa-east.hub-test.boomi.com/mdm`). Repository operations target that URL; account-level admin uses the Platform API.

**Cluster URL ≠ repository.** Multiple repositories can share a cluster host. What scopes a request to a specific repository is the auth pair — `DATAHUB_REPO_USERNAME` follows `<account-id>.<repo-token-id>` where the suffix is repo-specific, paired with that repository's Hub Authentication Token. Mismatch yields a confusing "universe does not exist" error: auth succeeded, but against a different repository's universe registry on the same cluster. **Never reuse an existing REST client connection (or any other DataHub-targeted artifact) on URL match alone** — verify with the user that the auth token targets the intended repository, or create a new connection wired to that repository's token.

## Model lifecycle: Draft → Published → Deployed

| State | Mutable? | What freezes |
|---|---|---|
| Draft | Yes — fields, types, repeatability, match rules can all change | Nothing |
| Published | Schema-frozen — field types and repeatability are locked | Type changes after publish require a new version |
| Deployed | Runtime-bound — attached to a repository, ingesting and merging data | Undeploy is required before structural changes propagate |

Once deployed, the **universe ID equals the model ID** (`mdm:universeId` in the deploy response is the same GUID as the model's `mdm:id`). The deployment ID is a separate value. Scripts that take `<universe-id>` should be given the model ID.

The Platform API's `/models` resource exposes only `publicationStatus` (boolean — draft vs published). Deploy is a separate binding of a published model to a repository (via Deploy Universe) and is not a filter value on `/models`. Query deployment via the repository's universe-deployment status.

**Source attachment** transitions `SOURCE_ATTACHMENT_REQUESTED` → `SOURCE_ATTACHED` → `ENABLE_INITIAL_LOAD_REQUESTED` → `INITIAL_LOAD_ENABLED` → `FINISH_INITIAL_LOAD_REQUESTED` → `INITIAL_LOAD_FINISHED`. The `*_REQUESTED` states are async. After `deploy`, calling `enable-initial-load` before the source reaches `SOURCE_ATTACHED` returns HTTP 400 "Source actual state cannot be null for state change" — poll `source.sh status` until `SOURCE_ATTACHED` (typically ~15s) before enabling initial load. Similarly, an upsert immediately following `enable-initial-load` may return HTTP 400 "not yet marked" before that state settles; retry succeeds (window is short, usually a single intervening roundtrip).

**Only one source at a time can be in initial-load.** Calling `enable-initial-load` against a second source while another is mid-load returns HTTP 400 "Cannot perform an initial load on more than one source at a time." Call `finish-initial-load` on the active source first — and observe that an immediate follow-up `enable-initial-load` on a second source has been seen to still hit the same 400 even after the finish call returned `<true/>`. Poll `source.sh status` until the active source reaches `INITIAL_LOAD_FINISHED` before enabling another source's initial load.

## Field types and structures

| Aspect | Valid values |
|---|---|
| `<mdm:field type="...">` | `BOOLEAN`, `CLOB`, `DATE`, `DATETIME`, `ENUMERATION`, `FLOAT`, `INTEGER`, `REFERENCE`, `STRING`, `TIME` |
| Source `<mdm:channelUpdatesFields>` | `All`, `Changed` |

**STRING** fields have `maxLength` ≤255 (server-enforced). Use `CLOB` for longer text.

**ENUMERATION** declares allowed values via child `<mdm:value>` elements (one per value).

**REFERENCE** is a native cross-model link type. Attributes: `referenceUniverseId="<other-model-id>"`, `incomingReferenceIntegrity="true|false"`, `outgoingReferenceIntegrity="true|false"`. In batch upserts, the field element's text content is the *source-side* natural key of the target record (e.g. `<parentRef>parent-1</parentRef>`); the platform resolves it to the parent's golden-record GUID, and that's what subsequent query responses return. With `incomingReferenceIntegrity="true"`, an unresolvable target → 202 + silent quarantine with `cause=REFERENCE_UNKNOWN`. No STRING-by-convention workaround is needed.

**`id` is reserved at the model root.** Defining a field with `name="id"` at the root fails with "A user-defined 'id' field exists at the root level." The platform auto-provisions the entity id (the `<id>` value sent in batch upserts). Use a different name for your natural-key field (e.g. `recordId`).

**Field groups** wrap related fields in `<mdm:fieldGroup name="..." uniqueId="..." repeatable="..." required="...">...</mdm:fieldGroup>` inside `<mdm:fields>`. The group's `name` becomes the wrapper element required in batch upserts (see below).

**Model name normalization.** On create, the platform lowercases and strips non-alphanumerics from `<mdm:name>` (e.g. `MyModel` → `mymodel`, `Customer(Boomeus)` → `customerboomeus`). The normalized form is what batch upserts must use as the entity wrapper element. Re-fetch the model via `model.sh get` if uncertain.

## Quarantine

Failed ingests do not enter golden state. They land in quarantine with one of these causes:

| Cause | When it fires |
|---|---|
| `PARSE_FAILURE` | XSD schema mismatch — wrong field names (using `uniqueId` instead of field `name`), missing field-group wrapper, unknown elements |
| `FIELD_FORMAT_ERROR` | Field-level format violation — value not in an `ENUMERATION`'s allowed list, malformed `DATETIME`/`FLOAT`/`INTEGER`, etc. |
| `REQUIRED_FIELD` | Missing one or more `required="true"` fields |
| `REFERENCE_UNKNOWN` | A `REFERENCE` field's value doesn't resolve to a target record (when `incomingReferenceIntegrity="true"`) |
| `POSSIBLE_DUPLICATE` | Match rules indicated this could be a duplicate of an existing golden record |

**Resolution is cause-dependent.** Only `POSSIBLE_DUPLICATE` (and other ambiguity-class causes) are `approve`-able — `approve` against a hard-fail cause returns HTTP 400 "not valid for approval." All hard-fail causes (`PARSE_FAILURE`, `FIELD_FORMAT_ERROR`, `REQUIRED_FIELD`, `REFERENCE_UNKNOWN`) are `delete`-only — `reject` returns HTTP 400 "not rejectable" for every one. The fix is source-side (correct the payload and resubmit); `delete` clears the existing quarantine entry. Match rules that produce excessive quarantine entries are a configuration problem, not a runtime fault.

## Size limits

- **Total model size**: 65,331 bytes
- **Single row size**: 8,126 bytes

UTF8MB4 encoding makes STRING fields expensive. ENUMERATION fields cost 1,020 bytes each. Repeatable fields move to child tables and don't count toward row size. Plan for these before publishing; they are deployment-blocking, not warnings.

## `<skill-path>` resolution

- Take the absolute path of this SKILL.md and drop `/SKILL.md`. That is `<skill-path>`.
- Verify by running `bash <skill-path>/scripts/datahub-env-check.sh` from a workspace with `.env`.
- Treat `<skill-path>` as a fixed value for the session.

## Scripts inventory

All scripts support `--help` (or run with no args) for usage. They emit text (JSON or XML) to stdout and errors to stderr.

**Pipeline discipline.** Pipe script output only to standard text filters (`head`, `tail`, `wc`, `grep`). Do **not** pipe to `python3 -c`, `jq -r`, `awk`, or other interpreters with inline code — the Claude Code harness treats each piped executable as a separate trust boundary and prompts for approval per pipe, defeating the point of allowlisting the scripts. If you need a transformation an existing script doesn't provide, surface the request rather than work around it inline — it'll be added to the appropriate CLI tool.

**Temp files stay in the project tree.** When you need a scratch file (XML query body, batch payload, etc.) to pass to a script, write it under `active-development/feedback/` (following bc-integration's working-files paradigm) — not `/tmp/`. The harness prompts for approval on writes outside the project tree, including `/tmp/`.

**Use the Write tool, not bash heredocs.** Create the file with a separate **Write** tool call, then invoke the script with a separate **Bash** call. Do not combine `cat > file <<EOF ... EOF; bash <script> file` into one compound bash command — the harness's static analysis flags heredoc patterns (unquoted delimiters that allow shell expansion, multi-line compound blocks the parser can't fully reason about) and will prompt for approval. Two separate tool calls avoid the prompt entirely.

- `scripts/datahub-common.sh` — sourced helper library.
- `scripts/datahub-env-check.sh` — verify `.env` and reach the Platform API.
- `scripts/datahub-model.sh` — `list | get | pull | create | update | delete | publish`
- `scripts/datahub-source.sh` — `list | get | pull | status | enable-initial-load | finish-initial-load | create | update | delete`
- `scripts/datahub-repository.sh` — `list | get [--universe <id>] | status | clouds | create` (`get --universe` scopes the response to one universe's summary within the repo)
- `scripts/datahub-deployment.sh` — `deploy | undeploy | status | list`
- `scripts/datahub-quarantine.sh` — `query | get | approve | reject | delete`
- `scripts/datahub-golden-record.sh` — `query | get | history | meta | match | update | unlink | get-by-source`
- `scripts/datahub-connection.sh` — `bootstrap` (creates a Boomi REST client connection wired to this workspace's DataHub creds, for use in integration processes). The stored base URL is the cluster host — integration paths must include the `/mdm/` prefix (e.g. `/mdm/universes/<id>/records`).

Repository API sub-commands take `--universe <id>` and read `DATAHUB_REPO_*` from `.env`.

## Sample payloads

These are illustrative shapes. For existing artifacts (model, source) use `pull` to fetch the current XML and edit surgically; samples below are starting points for net-new.

### `CreateModelRequest` — `datahub-model.sh create`

For updates, rename the wrapper to `<mdm:UpdateModelRequest>` (same inner content) and use `datahub-model.sh update <id>`.

```xml
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<mdm:CreateModelRequest xmlns:mdm="http://mdm.api.platform.boomi.com/">
    <mdm:name>myModelName</mdm:name>
    <mdm:fields>
        <mdm:field name="recordId"    repeatable="false" required="true"  type="STRING" uniqueId="RECORDID"   maxLength="50"/>
        <mdm:field name="recordValue" repeatable="false" required="false" type="STRING" uniqueId="RECORDVAL"  maxLength="100"/>
    </mdm:fields>
    <mdm:sources>
        <mdm:source id="Manual" type="Both" allowMultipleLinks="false" default="true">
            <mdm:inbound>
                <mdm:createApproval required="false"/>
                <mdm:updateApproval required="false"/>
                <mdm:updateApprovalWithBaseValue>false</mdm:updateApprovalWithBaseValue>
                <mdm:endDateApproval required="false"/>
                <mdm:earlyChangeDetectionEnabled>false</mdm:earlyChangeDetectionEnabled>
            </mdm:inbound>
            <mdm:outbound>
                <mdm:channelUpdatesFields>All</mdm:channelUpdatesFields>
                <mdm:sendCreates>true</mdm:sendCreates>
            </mdm:outbound>
        </mdm:source>
    </mdm:sources>
    <mdm:dataQualitySteps/>
    <mdm:recordTitle>
        <mdm:titleParameters>
            <mdm:parameter uniqueId="RECORDID"/>
        </mdm:titleParameters>
    </mdm:recordTitle>
    <mdm:matchRules>
        <mdm:matchRule topLevelOperator="AND">
            <mdm:simpleExpression>
                <mdm:fieldUniqueId>RECORDID</mdm:fieldUniqueId>
            </mdm:simpleExpression>
        </mdm:matchRule>
    </mdm:matchRules>
    <mdm:tags/>
</mdm:CreateModelRequest>
```

### `CreateSourceRequest` — `datahub-source.sh create`

Three required: `<mdm:name>` (max 255 chars), `<mdm:sourceId>` (max 50 chars; `A-Z`, `a-z`, `0-9`, `_`, `-`), `<mdm:entityIdUrl>` (UI link template; use `{id}` placeholder, or empty string if none). For updates, rename wrapper to `<mdm:UpdateSourceRequest>`.

```xml
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<mdm:CreateSourceRequest xmlns:mdm="http://mdm.api.platform.boomi.com/">
    <mdm:name>Salesforce Production</mdm:name>
    <mdm:sourceId>SF</mdm:sourceId>
    <mdm:entityIdUrl>https://example.my.salesforce.com/{id}</mdm:entityIdUrl>
</mdm:CreateSourceRequest>
```

### `RecordQueryRequest` — `datahub-golden-record.sh query`

Drop `<filter>` for "return all (up to limit)"; swap `EQUALS` for `CONTAINS` / `GREATER_THAN` / etc.; change `<filter op="AND">` to `OR` for disjunction. Set `includeSourceLinks="true"` on root for per-record source metadata.

Do NOT include `xmlns="..."` on `<RecordQueryRequest>` (HTTP 400 "unable to read message body"). For the first page, omit `offsetToken` entirely — `offsetToken="0"` returns HTTP 400 "unable to parse the provided offset token". Use the token from the previous response's `<offsetToken>` for subsequent pages.

```xml
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<RecordQueryRequest limit="10">
    <filter op="AND">
        <fieldValue>
            <fieldId>RECORDID</fieldId>
            <operator>EQUALS</operator>
            <value>example-value</value>
        </fieldValue>
    </filter>
</RecordQueryRequest>
```

### Batch upsert — `datahub-golden-record.sh update`

The `src` attribute is a configured contributing source. `<id>` is the source-side natural key — NOT the DataHub record ID. Response is `202 Accepted` with `Location` ending in the batch ID.

**Element naming rules:**
- The entity wrapper element (e.g. `<contact>` below) must match the model's normalized `<mdm:name>` (see § Field types — lowercase, non-alphanumerics stripped). Wrong case fails synchronously with HTTP 400 "entity of unknown type".
- Field elements use the field's `name` attribute (camelCase), NOT its `uniqueId` (UPPERCASE).
- Field-group subfields must be wrapped in the group's element (e.g. `<address>...</address>`), not flat.
- `<id>` values are NOT restricted to `A-Z, a-z, 0-9, _, -` ≤50 chars — that constraint applies to source `<mdm:sourceId>` at source-create time. Per-batch `<id>` values are preserved verbatim (`@`, length >50, etc. are accepted).

**Failure modes — HTTP 202 does NOT mean success.**
- HTTP 400 (synchronous): only on wrong entity-wrapper case.
- HTTP 202 + silent quarantine: schema mismatches (wrong field name, missing group wrapper) land as `cause=PARSE_FAILURE`. Missing required fields land as `cause=REQUIRED_FIELD`. Always run `datahub-quarantine.sh query` after a batch to confirm records actually materialized as golden records.

```xml
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<batch src="MANUAL">
    <contact>
        <id>1</id>
        <name>Bob Smith</name>
        <city>Berwyn</city>
    </contact>
    <contact>
        <id>2</id>
        <name>Carol Jones</name>
        <city>Boston</city>
    </contact>
</batch>
```

### Match request — `datahub-golden-record.sh match`

Same `<batch>` body shape as upsert; hits `POST /match` instead of `POST /records`. Preview-only — returns the existing golden records each candidate would merge with under current match rules. No writes.

### `QuarantineQueryRequest` — `datahub-quarantine.sh query`

Root attributes (all optional): `limit`, `offsetToken`, `includeData` (default `true`), `type` (`ACTIVE` default | `RESOLVED` | `ALL`). Filter children: `<sourceId>`, `<sourceEntityId>`, `<createdDate>`, `<endDate>`, `<cause>`, `<resolution>`, `<field name="" value=""/>`. Empty `<QuarantineQueryRequest/>` returns all ACTIVE entries.

```xml
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<QuarantineQueryRequest limit="50" type="ACTIVE">
    <filter op="AND">
        <cause>POSSIBLE_DUPLICATE</cause>
    </filter>
</QuarantineQueryRequest>
```
