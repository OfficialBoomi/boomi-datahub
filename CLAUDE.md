# boomi-datahub

Notes for developers working on this skill.

## Layout

- `SKILL.md` — agent entry point and navigation hub. Contains scope, API surfaces, credential contract, sample payloads, and the scripts inventory.
- `references/` — detail `SKILL.md` routes to rather than carrying inline. Each file is reachable from the `## References` tree in one hop, with a `Use when:` annotation.
- `scripts/datahub-common.sh` — sourced helper library: env loading, Platform / Repository URL builders, the `datahub_api` wrapper.
- `scripts/datahub-*.sh` — per-noun CLI tools (model, source, repository, deployment, quarantine, golden-record, connection, env-check).

## Credential handling

Credentials must not reach the command line, a child process environment, or a shell trace. Three guardrails enforce that:

- **Auth reaches curl in a config file on stdin** (`-K -`). Stdin is therefore reserved in `datahub_api` — never `@-`, `-T -`, or piping into it (inline `-d` and `--data-binary @file` are fine).
- **`load_env` does not export `.env` values.** Do not re-add `set -a`, however idiomatic it looks for sourcing a `.env`.
- **`load_env` sources `./.env`, never `.env`.** Do not drop the `./`, however redundant it looks: `source` searches `$PATH` before the current directory for any name containing no slash, so a bare `.env` loads one planted on `$PATH` instead of the workspace's.
- **`datahub-connection.sh` disables xtrace for the whole script.** Its response echoes back the repo credentials and the script expands `RESPONSE_BODY` after `datahub_api` returns, past the per-call fence. The whole-script fence is also what protects the request body: heredoc text itself is not traced, but a `$(...)` inside a heredoc is, and the trace line prints the expanded argument before the called function can fence itself.

## API surface reference

Boomi help documentation for Data Hub APIs lives under `Master Data Hub/REST APIs/`. Filename prefixes signal which API surface a given operation belongs to:

- `hub-...` — Platform API operations (account-level admin: models, sources, repositories admin, clouds, deployment)
- `r-mdm-...` — Repository API operations (per-repository data ops: golden records, quarantine, channels, batches, staging)
