# Vendored pstack

Upstream: https://github.com/cursor/plugins
Path: `pstack/`
Commit: `df581122cde17e6e27686b5a448bde23e4ad4318`
Commit date: 2026-10-05 18:05:41 -0700
Subject: `feat(pstack): drop Sol, default to Opus xhigh and Grok (#511)`
Plugin version at that commit: 0.15.15 (`pstack/.cursor-plugin/plugin.json`)
License: MIT, Copyright (c) 2026 Lauren Tan. Full text: `.cursor/PSTACK-LICENSE`.

Fetched 2026-10-10. The plugins repo HEAD at fetch time was `d73344bee8cf22e53b9d5f4cf5749d38ba38c174` (unrelated marketplace merge). `git diff df581122 HEAD -- pstack` was empty, so this pin is the pstack tree at that HEAD. Files were copied from a checkout of `df581122`.

## What is in this repo

| Upstream | Here | Why |
| --- | --- | --- |
| `pstack/skills/<name>/` (51 skills, including `poteto-mode` playbooks, references, and scripts, every `principle-*` skill, and the helper skills those files link) | `.cursor/skills/<name>/` | Project skill discovery |
| `pstack/agents/poteto-agent.md`, `pstack/agents/comment-sicko.md` | `.cursor/agents/` | Project subagent discovery. Frontmatter names stay `poteto-agent` and `Comment Sicko`. |
| `pstack/LICENSE` | `.cursor/PSTACK-LICENSE` | MIT attribution |
| `pstack/README.md` | `.cursor/README.md` | `poteto-help` links `../../README.md` |
| `pstack/docs/guide/` | `.cursor/docs/guide/` | `poteto-help` links `../../docs/guide/` |

Skill and agent files are unmodified upstream bytes. This file and `.cursor/rules/pstack-models.mdc` are local.

## Not vendored

- `pstack/automations/benny/` (not a slash skill; not referenced by `poteto-mode`)
- `pstack/assets/`, `pstack/.cursor-plugin/plugin.json` (plugin manifest). This checkout is project skills and project subagents, not a marketplace plugin install.
- `cursor-team-kit` skills that `poteto-mode` names but does not bundle: `deslop`, `control-cli`, `control-ui`
- Cursor built-in `create-skill` (referenced by the authoring playbook; already provided by Cursor)

## Paths that still say `pstack/skills/`

Several playbooks re-read themselves with `git show origin/main:pstack/skills/...` and `node pstack/skills/poteto-mode/scripts/check-plan.mjs`. Those paths are the upstream plugin layout. In this repo the same files are under `.cursor/skills/`. The bytes were not rewritten.

## Frontmatter names

`poteto-mode/SKILL.md` sets `name: Poteto Mode`. `make-bot-ui/SKILL.md` sets `name: Make Bot UI`. Cursor's skill docs say `name` must be lowercase hyphenated and must match the parent folder. Both were left as upstream wrote them. Slash identity is documented as the folder that contains `SKILL.md`, so `/poteto-mode` is the folder `poteto-mode`.
