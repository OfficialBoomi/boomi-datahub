# Data quality step

`<mdm:dataQualitySteps>` holds `<mdm:step>` children that validate and enrich incoming entities before incorporation. A failing entity quarantines instead of becoming a golden record.

Steps are additive and ordered — each step's output is the next step's input.

## Contents

- [Step kinds](#step-kinds)
- [Reading and editing](#reading-and-editing)
- [Business rule steps](#business-rule-steps)
- [Activation](#activation)
- [Failure behavior](#failure-behavior)
- [Ordinary (quality-service) steps](#ordinary-quality-service-steps)
- [Integration process call steps](#integration-process-call-steps)

## Step kinds

`type` takes exactly two values; a step with neither is ordinary.

| Kind | `type` | API-authorable |
|---|---|---|
| Business rule | `BUSINESS_RULE` | Yes |
| Integration process call | `PROCESS` | Yes — needs a deployed Hub listener process |
| Ordinary (third-party quality service) | *absent* | No — UI only |

Any other `type` value is treated as untyped and rejected with `Missing required properties for data quality step <name>` — check `type` spelling before chasing missing children.

`id` may be omitted on `<mdm:step>`; the platform generates one. `<mdm:businessRule>` takes only `name`.

A rejected update is atomic: no draft is created, published version untouched.

## Reading and editing

| Command | Effect |
|---|---|
| `datahub-model.sh quality-steps <model-id>` | Print the block alone |
| `datahub-model.sh add-quality-step <model-id> <step-file>` | Append a `<mdm:step>` |
| `datahub-model.sh remove-quality-step <model-id> --name <n>` | Remove by `name` |
| `datahub-model.sh remove-quality-step <model-id> --id <i>` | Remove by `id` |

`quality-steps` takes `--draft` and `--version`. The writes take `--draft` and `--dry-run`.

Every write submits the whole model document, so **neither write works on a model carrying an ordinary step** except to remove that step — see § Ordinary. Run `quality-steps` first.

Writes always produce a **draft** — the published version is never modified in place. A draft reports `<mdm:version>Draft</mdm:version>` (literal string).

`--draft` selects the version the edit builds from, so **every edit after the first needs it**. Without it, a write that would discard an existing draft refuses:

```
ERROR: model <id> has an unpublished draft.
```

A never-published model is draft-only, so its first edit needs `--draft` too.

`remove-quality-step` also refuses an unmatched selector, and a `--name` matching several steps (names need not be unique) — use `--id`.

Order is document order, preserved through add, remove, and publish. `add-quality-step` appends; reorder by editing a pulled model.

A step file holds one `<mdm:step>`. Its own `xmlns:mdm` is dropped on splice; whitespace between tags is collapsed.

A step naming a nonexistent field is refused: `Invalid Unique id <uniqueId> for the BusinessRule`.

## Business rule steps

Same inputs/conditions structure as tags (SKILL.md § Tags), plus `<mdm:errorMessage>`.

**Conditions state what must be TRUE to pass.** Steps apply to every entity regardless of whether input fields are present; omitted and empty fields evaluate as empty strings.

```xml
<mdm:step name="Price Rule" type="BUSINESS_RULE">
    <mdm:businessRule name="Price Rule">
        <mdm:inputs>
            <mdm:input key="1" alias="price" fieldUniqueId="PRICE" type="Field"/>
        </mdm:inputs>
        <mdm:conditions topLevelOperator="AND">
            <mdm:condition operator="NOT_CONTAINS">
                <mdm:firstInput type="Field" key="1"/>
                <mdm:secondInput type="Static" value="$" key="0"/>
            </mdm:condition>
        </mdm:conditions>
        <mdm:errorMessage>Price must contain only decimal numerals</mdm:errorMessage>
    </mdm:businessRule>
</mdm:step>
```

Authoring uses `type="BUSINESS_RULE"`; the runtime descriptor reports `stepType="BUSINESS_RULES"` and operators in prose (`does not contain`). Never carry runtime spelling into a model document.

## Activation

Deploy activates a step, not publish.

| Model state | Enforced |
|---|---|
| Draft only | No |
| Published, repository deployed at earlier version | No |
| Republished version deployed | Yes |

`datahub-deployment.sh list` returns each deployed universe's runtime descriptor. Its `<dataquality>` element is what is enforced now; empty alongside a model defining steps means a redeploy is outstanding. The response covers every universe — narrow with `grep`.

## Failure behavior

A failing entity still returns `202`. Check `datahub-quarantine.sh query` after every batch.

```xml
<QuarantineEntry sourceId="Manual" sourceEntityId="P3-FAIL">
    <cause>ENRICH_ERROR</cause>
    <reason>At data quality step 'Price Rule': Price must contain only decimal numerals</reason>
</QuarantineEntry>
```

`<reason>` is `At data quality step '<step name>': <errorMessage>` — write error messages as steward-actionable text.

Resolution via API is `delete`; `approve` and `reject` both return HTTP 400. Fix the payload or rule, resend from source.

The UI additionally offers **Retry Enrichment Step** and **Ignore Enrichment Failure**, requiring the *Resubmit Quarantine* entitlement and the same deployed model version as at quarantine time. Redeploying to fix a rule forecloses retrying entities already quarantined — sequence accordingly, and route retry requests to the UI.

## Ordinary (quality-service) steps

Services: Dun & Bradstreet (*Validate Company*), Loqate (*Verify Address*, *Verify and Geocode Address*). Enable a service on the model's Data Quality Steps tab before use.

```xml
<mdm:step id="0b6dd41c-53a0-4e90-a3ce-1525dd2c1918" name="Verify Address"/>
```

All configuration — service, credentials, input/output field mappings, gating conditions — is server-side, outside the model document. Inputs cannot span collections; if any input maps to a collection field, all outputs must map into that same collection.

**A model update carrying an ordinary step is always rejected**, even when the step is real, UI-configured, and pushed back byte-identical:

```
HTTP 400 — Missing required properties for data quality step <name>
```

The rejection keys on the step's presence in the submitted document, not on anything being wrong with it, and **the error names the ordinary step rather than the edit that was attempted** — adding a business rule to such a model reports the quality service's name. Consequences:

- Ordinary steps cannot be created through the API.
- **A model carrying one cannot be updated through the API at all** — not its fields, sources, match rules, or tags — because every update submits the whole document. Such models are UI-only for every edit.
- Dropping the step from the block *is* accepted, so `remove-quality-step` works on an ordinary step — provided none remains in the pushed document. It is the only API edit such a model accepts, and it discards the service configuration with it.

The rejection is atomic: no draft is created and the published version is untouched.

**Check for ordinary steps before planning any model edit.** Run `quality-steps` first; a `<mdm:step>` with no `type` means route the user to the Data Quality Steps tab rather than attempting an API edit.

## Integration process call steps

The called process must start with a Boomi Master Data Hub Listener connector operation, return results as documents, and be deployed to a repository the model is deployed to.

`processId`, `sourceCondition`, and `fieldCondition` are attributes on `<mdm:step>`, not children; `<mdm:fields/>` is a direct child.

```xml
<mdm:step name="Address Enrichment" type="PROCESS"
          processId="a1b2c3d4-0000-0000-0000-000000000000" sourceCondition="false" fieldCondition="false">
    <mdm:fields/>
</mdm:step>
```

Two optional gating conditions exist — one on contributing source, one on whether field values would be populated or changed. Both flags `false` runs the step on every entity.

Placing these on a `<mdm:process>` child instead: the wrapper is ignored, `processId` is never read, and the update reports `Missing required property in Integration process data quality step <name>`.

`processId` resolves at `update`, not publish or deploy. An unresolvable GUID returns an authorization message, not a not-found one:

```
HTTP 400 — User is not authorized to access process having ID <guid>
```

Check the ID before investigating role assignments.

Process component IDs come from `boomi-integration` or the user; this skill does not list processes.
