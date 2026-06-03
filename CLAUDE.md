# boomi-datahub

Notes for developers working on this skill.

## Layout

- `SKILL.md` — agent entry point and navigation hub. Contains scope, API surfaces, credential contract, sample payloads, and the scripts inventory.
- `scripts/datahub-common.sh` — sourced helper library: env loading, Platform / Repository URL builders, the `datahub_api` wrapper.
- `scripts/datahub-*.sh` — per-noun CLI tools (model, source, repository, deployment, quarantine, golden-record, connection, env-check).

## API surface reference

Boomi help documentation for DataHub APIs lives under `Master Data Hub/REST APIs/`. Filename prefixes signal which API surface a given operation belongs to:

- `hub-...` — Platform API operations (account-level admin: models, sources, repositories admin, clouds, deployment)
- `r-mdm-...` — Repository API operations (per-repository data ops: golden records, quarantine, channels, batches, staging)
