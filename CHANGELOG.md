# Changelog

## 0.2.8

- Keep credentials off the command line
- Keep credentials out of child process environments
- Keep credentials out of shell traces
- Stop `.env` from overriding the skill's User-Agent header


## 0.2.7

- Ship `CHANGELOG.md` inside the skill directory


## 0.2.6

- Full pass to ensure correctly formatted Data Hub name in prose


## 0.2.5

- golden-record.sh: fail fast on missing --universe


## 0.2.4

- Distinguish missing-arg from missing-file in model.sh create


## 0.2.3

- Fix publish --notes rejecting XML special characters


## 0.2.2

- Clarify that published models accept new fields


## 0.2.1

- Added support for model tags


## 0.2.0

- Final pre-release pass to streamline and tidy README.md and script comments

## 0.1.15

- Pre-release streamline and tidy pass on skill.md content

## 0.1.14

- Improved handling of the --help flag on cli tools

## 0.1.13

- Enhanced match rule support
- Improved quarantine handling

## 0.1.12

- Remove the `ALLOW_GR_ACTIONS` gate

## 0.1.11

- Fixed /unlink method bug


## 0.1.10

- Improved `datahub_api` error messages


## 0.1.9

- `datahub-deployment.sh`: unify deploy/undeploy argument order
- `datahub-connection.sh`: fix silent componentId parse failure


## 0.1.8

- Modified `datahub-golden-record.sh get-by-source` to use the Repository API instead of the platform API.

## 0.1.7

- `datahub-source.sh` `enable-initial-load` / `finish-initial-load` now wait for the async transition to settle before returning.

## 0.1.6

- Improved model liveness check logic


## 0.1.5

- Added support for repeating field groups and repeating single fields


## 0.1.4

- `datahub_api` disables xtrace while the auth token is in scope


## 0.1.3

- Refined instructions for draft model handling and initial load


## 0.1.2

- Fixed an "unbound variable" issue with older bash versions
- `datahub-model.sh get`/`pull` now hints to retry with `--draft` when a model exists only as a draft
- Removed the non-functional `--accept` flag from `datahub-golden-record.sh` `get`/`history`/`meta` read sub-commands


## 0.1.1

- Improved .env check logic
- Refined `boomi-datahub` scope to currently shipped capability.

## 0.1.0

- Minor bump: first published release of bc-datahub.
- Initial work on `bc-datahub` — a new bc-* plugin shipping the `boomi-datahub` skill for Boomi DataHub (MDM) configuration and operations. Covers model / source / repository / deployment / quarantine / golden-record verbs via sub-commanded bash scripts, with Platform API and Repository API auth sourced from `.env`. Golden-record operations gated behind `ALLOW_GR_ACTIONS=true`.
