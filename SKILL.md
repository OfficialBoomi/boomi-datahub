---
name: boomi-datahub
description: Designs and operates Boomi DataHub master data — model and source design, deployment lifecycle, quarantine triage, and golden-record CRUD — when the user works with Boomi DataHub (MDM) configuration or stewardship. Pairs nicely with the boomi-integration skill.
---

# boomi-datahub

## Scope

In: model design; source configuration; model lifecycle (Draft → Published → Deployed); quarantine triage; repository operations; golden-record CRUD.

Out: building Boomi integration processes — those belong to `boomi-integration`. Integration processes that interact with DataHub (typically via the REST client) are `boomi-integration`'s territory; the REST client connection itself can be bootstrapped from this workspace's `.env` via `datahub-connection.sh bootstrap`.

## API surfaces

DataHub exposes two API surfaces. **Always reach them through the CLI tools in § Scripts inventory — never hand-roll curl, URLs, or auth headers.** The scripts build the URLs, route to the correct surface, and read credentials from `.env`; constructing your own request is how the wrong-surface / wrong-auth mistakes happen.

- **Platform API** — account-level admin: models, sources, repositories, clouds, deployment.
- **Repository API** — per-repository: golden records, stewardship/quarantine, deployed-universe listing. It is **XML-only** on both request and response, so the payloads you author for these scripts are always XML (the Platform API speaks JSON on most reads).

A **Hub Cloud** is the runtime host that holds repositories (along with their deployed models and golden records) — not an API name. Multiple repositories can live on one Hub Cloud.

## Credentials

The skill reads credentials from the workspace `.env`. Sensitive values are never accepted as command-line arguments — the scripts source them from `.env` directly.

| Surface | `.env` keys |
|---|---|
| Platform API | `BOOMI_USERNAME`, `BOOMI_API_TOKEN`, `BOOMI_ACCOUNT_ID`, `BOOMI_API_URL` |
| Repository API | `DATAHUB_REPO_URI`, `DATAHUB_REPO_USERNAME`, `DATAHUB_REPO_AUTH_TOKEN` |

Setting the Repository API keys is the opt-in for golden-record operations.

## Repository-scoped operations

A repository is the unit of deployment: models, sources, channels, staging areas, golden records, and quarantine all live inside one. Repository CLI tools target its base URL (e.g. `https://c01-usa-east.hub-test.boomi.com/mdm`); account-level admin uses the Platform API.

That base URL is a **Hub Cloud host**, shared by every repository on it — so the URL alone never identifies a repository. The auth pair does: `DATAHUB_REPO_USERNAME` is `<account-id>.<repo-token-id>` (suffix is repo-specific), paired with that repository's Hub Authentication Token. A URL match with the wrong token authenticates fine but lands on a different repository's universe registry — the confusing "universe does not exist" error. **Never reuse a REST client connection (or any DataHub artifact) on URL match alone** — confirm the token targets the intended repository, or wire a new connection to it - discuss with the user if in any doubt.

## Model lifecycle: Draft → Published → Deployed

| State | Mutable? | What freezes |
|---|---|---|
| Draft | Yes — fields, types, repeatability, match rules can all change | Nothing |
| Published | Partly — new fields can be added (the update lands in a new draft to republish) | Type and repeatability of **existing** fields are locked; adding new fields is not |
| Deployed | Runtime-bound — attached to a repository, ingesting and merging data | Undeploy is required before structural changes propagate |

Once deployed, the **universe ID equals the model ID** (`mdm:universeId` in the deploy response is the same GUID as the model's `mdm:id`). The deployment ID is a separate value. Scripts that take `<universe-id>` should be given the model ID.

The Platform API's `/models` resource exposes only `publicationStatus` (boolean — draft vs published). Deploy is a separate binding of a published model to a repository (via Deploy Universe) and is not a filter value on `/models`. Query deployment via the repository's universe-deployment status.

**Draft-only models require `--draft`.** `model.sh get`/`pull` target the published version by default; a never-published model has none, so pass `--draft` — otherwise the API returns a misleading HTTP 400 "… is not a valid component ID".

**`get` is not a deletion liveness check.** After a successful `delete`, `model.sh get`/`pull` by ID still returns HTTP 200 with the full model XML — the Platform API retains the schema of deleted models and only excludes them from `list`. To confirm a model is deleted, use `list` (the model will be absent) or a second `delete` (returns "A model with ID … does not exist"). This applies to models only; source `get` on a deleted ID correctly returns HTTP 400.

**Source attachment** transitions `SOURCE_ATTACHMENT_REQUESTED` → `SOURCE_ATTACHED` → `ENABLE_INITIAL_LOAD_REQUESTED` → `INITIAL_LOAD_ENABLED` → `FINISH_INITIAL_LOAD_REQUESTED` → `INITIAL_LOAD_FINISHED`. The `*_REQUESTED` states are async, so `enable-initial-load` and `finish-initial-load` **self-gate** — each blocks until the source reaches the state that makes the next step safe, so just run the lifecycle steps in order; no manual `source.sh status` polling is needed. `enable-initial-load` waits out the async `SOURCE_ATTACHMENT_REQUESTED` state before it acts and returns only once the source is `INITIAL_LOAD_ENABLED` (so a following upsert can't fire too early); it does two sequential waits, so it can block up to ~2 min. `finish-initial-load` returns only once the source is `INITIAL_LOAD_FINISHED` (a single wait, ≤60s).

**Only one source at a time can be in initial-load.** Calling `enable-initial-load` against a second source while another is mid-load returns HTTP 400 "Cannot perform an initial load on more than one source at a time." Run `finish-initial-load` on the active source first; because it blocks until that source reaches `INITIAL_LOAD_FINISHED`, the next source's `enable-initial-load` is safe to call immediately after.

## Field types and structures

| Aspect | Valid values |
|---|---|
| `<mdm:field type="...">` | `BOOLEAN`, `CLOB`, `DATE`, `DATETIME`, `ENUMERATION`, `FLOAT`, `INTEGER`, `REFERENCE`, `STRING`, `TIME` |
| Source `<mdm:channelUpdatesFields>` | `All`, `Changed` |

**STRING** fields have `maxLength` ≤255 (server-enforced). Use `CLOB` for longer text.

**ENUMERATION** declares allowed values via child `<mdm:value>` elements (one per value).

**REFERENCE** is a native cross-model link type. Attributes: `referenceUniverseId="<other-model-id>"`, `incomingReferenceIntegrity="true|false"`, `outgoingReferenceIntegrity="true|false"`. In batch upserts, the field element's text content is the *source-side* natural key of the target record (e.g. `<parentRef>parent-1</parentRef>`); the platform resolves it to the parent's golden-record GUID, and that's what subsequent query responses return. With `incomingReferenceIntegrity="true"`, an unresolvable target → 202 + silent quarantine with `cause=REFERENCE_UNKNOWN`. No STRING-by-convention workaround is needed. A `required="true"` REFERENCE field forces `outgoingReferenceIntegrity="true"` — the platform rejects model creation otherwise ("OutgoingReferenceIntegrity must be true when REFERENCE field … is required").

**`id` is reserved at the model root.** Defining a field with `name="id"` at the root fails with "A user-defined 'id' field exists at the root level." The platform auto-provisions the entity id (the `<id>` value sent in batch upserts). Use a different name for your natural-key field (e.g. `recordId`).

**Field groups** wrap related fields in `<mdm:fieldGroup name="..." uniqueId="..." repeatable="..." required="...">...</mdm:fieldGroup>` inside `<mdm:fields>`. `repeatable` is locked at publish.

- **Non-repeating** (`repeatable="false"`): one instance. The group's `name` is the wrapper element in batch upserts (`<address>…</address>`). Sending the subfields flat, or sending a second instance, → silent quarantine `PARSE_FAILURE`.
- **Repeating** (`repeatable="true"`) is a **collection**. Model-create fails ("Missing required properties for collection field") unless the `<mdm:fieldGroup>` also carries `collectionTag`, `collectionUniqueId`, `identifyBy="KEY"`, and `collectionKeys` (the key field's `uniqueId`). In batch upserts and query responses it is **double-wrapped** — the `collectionTag` element once, wrapping repeated `name` elements:

```xml
<mdm:fieldGroup name="address" uniqueId="ADDRESS" repeatable="true" required="false"
                collectionTag="addresses" collectionUniqueId="ADDRESSES" identifyBy="KEY" collectionKeys="CITY">
    <mdm:field name="city" uniqueId="CITY" type="STRING" maxLength="100" repeatable="false" required="false"/>
</mdm:fieldGroup>
<!-- batch upsert / query: <addresses><address><city>…</city></address><address>…</address></addresses> -->
```

A **repeating single field** (`<mdm:field repeatable="true">`, no surrounding group) is the same collection mechanism: it needs `collectionTag`/`collectionUniqueId`/`identifyBy="KEY"` (but not `collectionKeys` — it keys on its own value) and double-wraps identically — `<phones><phone>v1</phone><phone>v2</phone></phones>`, the inner element carrying the scalar value. Either way, exceeding a non-repeating field/group's single instance → quarantine `PARSE_FAILURE`.

**Model name normalization.** On create, the platform lowercases and strips non-alphanumerics from `<mdm:name>` (e.g. `MyModel` → `mymodel`, `Customer(Boomeus)` → `customerboomeus`). The normalized form is what batch upserts must use as the entity wrapper element. Re-fetch the model via `model.sh get` if uncertain.

## Match rules

A model needs at least one match rule to publish. Rules evaluate in document order; the first satisfied rule wins. Order most-restrictive first.

A rule (`<mdm:matchRule topLevelOperator="AND|OR|NOT">`) holds any mix of:

- `<mdm:simpleExpression>` — one `<mdm:fieldUniqueId>`; incoming-vs-existing equality on that field.
- `<mdm:advancedExpression>` — `<mdm:ruleOperator>` `EQUALS` | `STRICT_EQUALS` (case-sensitive) | `IS_SIMILAR_TO` (fuzzy; add `<mdm:similarityAlgorithm>` and `<mdm:tolerance>`), then two inputs as in the sample below. `<mdm:inputType>` is `INCOMING` | `EXISTING` | `STATIC` (`STATIC` compares a literal `<mdm:value>`); the two inputs may name different fields.
- `<mdm:expressionGroup operator="AND|OR|NOT">` — nests arbitrarily.

Algorithms (exact literals): `Jaro-Winkler`, `Levenshtein`, `Bigram`, `Trigram`, `Soundex`. Tolerance 0.0–1.0 (`Soundex`: 0–4).

```xml
<mdm:matchRules>
    <mdm:matchRule topLevelOperator="AND">
        <mdm:simpleExpression><mdm:fieldUniqueId>EMAIL</mdm:fieldUniqueId></mdm:simpleExpression>
    </mdm:matchRule>
    <mdm:matchRule topLevelOperator="AND">
        <mdm:simpleExpression><mdm:fieldUniqueId>POSTAL</mdm:fieldUniqueId></mdm:simpleExpression>
        <mdm:advancedExpression>
            <mdm:ruleOperator>IS_SIMILAR_TO</mdm:ruleOperator>
            <mdm:similarityAlgorithm>Jaro-Winkler</mdm:similarityAlgorithm>
            <mdm:tolerance>0.85</mdm:tolerance>
            <mdm:firstInput>
                <mdm:inputType>INCOMING</mdm:inputType>
                <mdm:fieldUniqueId>LASTNAME</mdm:fieldUniqueId>
            </mdm:firstInput>
            <mdm:secondInput>
                <mdm:inputType>EXISTING</mdm:inputType>
                <mdm:fieldUniqueId>LASTNAME</mdm:fieldUniqueId>
            </mdm:secondInput>
        </mdm:advancedExpression>
    </mdm:matchRule>
</mdm:matchRules>
```

- **`create` checks shape; `publish` checks semantics.** A draft holds rules that publish rejects: fuzzy expressions not grouped with an exact expression, `NOT` with more than one child, fuzzy on a non-text field.
- **`NOT` inverts its child** — a standalone NOT rule matches *dissimilar* records; only use it inside a group alongside positive expressions.
- **Pulled rules are canonicalized** — same-field EQUALS collapses to a simpleExpression, omitted tolerance becomes `0.0`, `4` → `4.0`. Re-pull after create before editing.
- **Tune with `datahub-golden-record.sh match`** — see § Match request for its diagnostic payload.

## Tags

A tag classifies golden records by a business rule. A model's tags are optional (`<mdm:tags/>` is valid); the source `sendFilter` below can reference a tag by name to gate a source's outbound channel. Each `<mdm:tag>` in the top-level `<mdm:tags>` block wraps a `<mdm:businessRule>` of keyed inputs + nested conditions:

```xml
<mdm:tags>
    <mdm:tag name="Customer">
        <mdm:businessRule name="Customer">
            <mdm:inputs>
                <mdm:input key="1" alias="Stage"    fieldUniqueId="STAGE"    type="Field"/>
                <mdm:input key="2" alias="Category" fieldUniqueId="CATEGORY" type="Field"/>
            </mdm:inputs>
            <mdm:conditions topLevelOperator="OR">
                <mdm:conditionGroup operator="AND">
                    <mdm:condition operator="EQUAL">
                        <mdm:firstInput  type="Field"  key="1"/>
                        <mdm:secondInput type="Static" value="Active" key="0"/>
                    </mdm:condition>
                    <mdm:condition operator="IS_NOT_EMPTY">
                        <mdm:firstInput type="Field" key="2"/>
                    </mdm:condition>
                </mdm:conditionGroup>
            </mdm:conditions>
        </mdm:businessRule>
    </mdm:tag>
</mdm:tags>
```

- **Omit `id` on create** (platform generates a GUID; `pull` to capture it); a supplied `id` is honored on update. Empty `<mdm:tags/>` removes all tags.
- Conditions reference inputs by `key` (need not be contiguous); `<mdm:conditionGroup operator="AND|OR">` nests arbitrarily under `<mdm:conditions topLevelOperator="AND|OR">`. Binary operators need `<mdm:secondInput>` (`type="Field" key="N"` or `type="Static" value="..." key="0"`); empty-checks take `firstInput` only.
- Operators: `EQUAL`, `NOT_EQUAL`, `LESS_THAN`, `GREATER_THAN`, `LESS_OR_EQUAL`, `GREATER_OR_EQUAL`, `CONTAINS`, `NOT_CONTAINS`, `STARTS_WITH`, `IS_EMPTY`, `IS_NOT_EMPTY`. Note the short `*_OR_EQUAL` (not `*_THAN_OR_EQUAL`) and `NOT_CONTAINS` (not `DOES_NOT_CONTAIN`).

### Outbound gating — `sendFilter`

A source's `<mdm:outbound>` references a tag by **`name`** to gate which records publish on its channel:

```xml
<mdm:sendFilter scope="All">
    <mdm:tags><mdm:tag name="Customer"/></mdm:tags>
</mdm:sendFilter>
```

- `scope` is `All` or `Creates`. Multiple tags allowed; `id` is optional (only `name` is required).
- The `name` must resolve to a defined tag (else HTTP 400 "… does not exist in the model") — define the tag first.

### Tag input functions

A tag input can be a function that transforms a field. The input wraps `<mdm:function>`, which maps fields as parameters and declares its outputs:

```xml
<mdm:input key="3" alias="String Split" type="Function">
    <mdm:function type="StringSplit" splitBy="Delimiter" delimiter="@">
        <mdm:inputs><mdm:input name="Original String" uniqueId="EMAIL"/></mdm:inputs>
        <mdm:outputs><mdm:output name="out1"/><mdm:output name="out2"/></mdm:outputs>
    </mdm:function>
</mdm:input>
```

- Each function `<mdm:input>` `uniqueId` must be a non-empty, valid field `uniqueId`; `uniqueId=""` is rejected. Multi-output functions declare `<mdm:outputs>` with named `<mdm:output>` children.
- `type` tokens differ from the UI label and aren't derivable from it (e.g. *Right Character Trim* is `RightTrim`). By category:
    - **String:** `LeftTrim`, `RightTrim`, `WhiteSpaceTrim`, `StringAppend`, `StringPrepend`, `StringConcat` (`delimiter`, `fixToLength`), `StringReplace`, `StringRemove`, `StringToLower`, `StringToUpper`, `StringSplit` (`splitBy`, `delimiter`)
    - **Numeric:** `MathAbsoluteValue`, `MathAdd`, `MathDivide`, `MathCeiling`, `MathFloor`, `MathSetPrecision`, `NumberFormat`, `RunningTotal`, `Sum`, `Count`, `LineItemIncrement`, `SequentialValue`
    - **Date:** `DateFormat`, `GetCurrentDate` (no inputs)
- A condition tests a single-output function's result with a bare reference — `<mdm:firstInput type="Function" key="N"/>`, no output attribute. A `StringSplit` output is testable only when it is the function's **only** declared output — reference it with `outputFieldName="<output name>"`; with two or more declared outputs the condition is rejected on `update`. To test multiple segments, use one single-output `StringSplit` input per segment.

**Platform API known issues — halt and raise with the user; never work around silently:**

If this instruction remains in the skill the defect has not yet been resolved and this section remains critical. Boomi is aware of these issues and a fix is in progress; no support ticket is needed. You do not need to proactively raise them to the user unless their project or model is actively affected.

- The API accepts both `MathSubtract` and `MathMultiply` but stores and executes them incorrectly — a rule authored as one function can be stored as a different one. **Never** author these.
- For the same reason, treat `MathSubtract` and `LeftTrim` tag functions in any pulled model as suspect, even when UI-authored.
- A pulled model may contain a condition on a multi-output `StringSplit`. Pushing that model back is rejected. Such tags must be edited in the UI, or restructured to single-output `StringSplit` inputs — never delete or restructure the user's condition without their explicit sign-off.

These configurations are niche, but if you encounter any of the above situations — STOP and raise it with the user.

## Quarantine

Failed ingests do not enter golden state. They land in quarantine with one of these causes:

| Cause | When it fires | Resolution |
|---|---|---|
| `PARSE_FAILURE` | XSD schema mismatch — wrong field names (`uniqueId` instead of field `name`), missing field-group wrapper, unknown elements | `delete`; fix payload, resubmit |
| `FIELD_FORMAT_ERROR` | Value not in an `ENUMERATION`'s list, malformed `DATETIME`/`FLOAT`/`INTEGER`, etc. | `delete`; fix payload, resubmit |
| `REQUIRED_FIELD` | Missing `required="true"` fields | `delete`; fix payload, resubmit |
| `REFERENCE_UNKNOWN` | A `REFERENCE` value doesn't resolve (when `incomingReferenceIntegrity="true"`) | `delete`; fix payload, resubmit |
| `POSSIBLE_DUPLICATE` | Match rules flagged a possible duplicate of an existing golden record | `reject` — discards the record, no merge |

`approve` only works on entries quarantined by a source's manual-approval settings; against any other cause it returns HTTP 400. Excessive quarantine entries mean the match rules need work, not the runtime.

## Size limits

A model has two byte budgets, both deployment-blocking (not warnings) and both excluding the id field, reference fields, and repeatable (collection) fields:

- **Total model size**: ~64 KB
- **Single row size**: ~8 KB

UTF8MB4 encoding makes STRING fields expensive (4 bytes/char), and each ENUMERATION field costs ~1 KB toward the model budget. Repeatable fields move to child tables, so they don't count toward either budget. Plan for these before publishing.

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
- `scripts/datahub-connection.sh` — `bootstrap` (creates a Boomi REST client connection wired to this workspace's DataHub creds, for use in integration processes). The stored base URL is the Hub Cloud host — integration paths must include the `/mdm/` prefix (e.g. `/mdm/universes/<id>/records`).

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

The `src` attribute is a configured contributing source. `<id>` is the source-side natural key — NOT the DataHub record ID. Response is `202 Accepted` with `Location` ending in the batch ID. The source must already be update-capable: it completes the initial-load lifecycle (enable → upsert → finish; see § Model lifecycle) before its first upsert, or the batch returns HTTP 400 "not yet marked as one that can send updates".

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

Same `<batch>` body shape as upsert; hits `POST /match` instead of `POST /records`. Preview-only — no writes. Per candidate, a hit returns the matched golden record as `<duplicate>` plus a `matchRule` attribute naming the rule logic that fired; a miss returns only the `<entity>`. Fuzzy hits include `<fuzzyMatchDetails>` with the computed `matchStrength` vs the configured `threshold` — use it to tune tolerance against real data.

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
