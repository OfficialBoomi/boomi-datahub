# boomi-datahub

A Boomi Companion skill for Boomi DataHub (master data management).

> **Important:** Boomi Companion is a publicly available developer offering, not an officially supported Boomi product. It is provided as-is and is not covered by Boomi support agreements or SLAs. Boomi curates and maintains this tool on a best-effort basis — treat it as a self-service resource. Boomi reserves the right to modify or discontinue it at any time without notice.

## Setup

`bc-datahub` plugin and `boomi-datahub` skill read credentials from the workspace `.env`. If `bc-integration` plugin or `boomi-integration` skill is already setup, some of those Platform details are re-used by this skill/plugin.

| Key | Used by | Notes |
|---|---|---|
| `BOOMI_USERNAME` | Platform API | Your Boomi platform username (email) |
| `BOOMI_API_TOKEN` | Platform API | Settings → My User Settings → Platform API Tokens |
| `BOOMI_ACCOUNT_ID` | Platform API | Settings → Account Information |
| `BOOMI_API_URL` | Platform API | Typically `https://api.boomi.com` |
| `DATAHUB_REPO_URI` | Repository API | Repository's **Configure** tab; `/mdm` suffix optional |
| `DATAHUB_REPO_USERNAME` | Repository API | From the repository's **Configure** tab |
| `DATAHUB_REPO_AUTH_TOKEN` | Repository API | Hub Authentication Token from the repository's **Configure** tab |
| `ALLOW_GR_ACTIONS` | Golden-record gate | Set `true` to enable `datahub-golden-record.sh` sub-commands (off by default) |

Allowlist the skill and its scripts in the workspace's `.claude/settings.json` under `permissions.allow`:

- `Skill(bc-datahub:boomi-datahub)`
- `Bash(bash */skills/boomi-datahub/scripts/*)`

This project is licensed under the [BSD-2-Clause License](LICENSE). If you fork or modify this code, you should not use the name "Boomi" for your version.
