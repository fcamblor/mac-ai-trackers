---
paths: .claude/skills/**/SKILL.md, .claude/agents/**/*.md, .claude/commands/**/*.md
---

# Skill / agent / command authoring

Skills, agents, and slash commands are **operational** artifacts: they describe workflow (phases, steps, prompts). They are NOT the place to define domain conventions.

## Delegate specs to `docs/`

If the artifact implements a process that has (or deserves) a spec under `docs/`:

1. Write or extend the spec in `docs/<topic>.md` first. The spec owns: directory layout, naming conventions, file templates, list of required sections, line/format grammars.
2. In the artifact, include near the top:
   - A short "Prerequisite: read `docs/<topic>.md`" pointer, naming what the spec provides.
   - A conflict-resolution line: "If this artifact and `docs/<topic>.md` disagree, the spec wins; flag it to the user."
3. Keep the artifact focused on workflow only: phases (gather / validate / generate / confirm), questions to ask the user, duplicate checks, tool invocations.

## What NOT to copy into an artifact

- Concrete template blocks (```` ```markdown ... ``` ````) that repeat the spec's template.
- Explicit section lists that restate the spec's structure.
- Format strings (e.g. index line grammars, slug grammars) already fixed by the spec.

Reference them by pointing at the spec instead.

## When there is no spec

If the process is too small to deserve a `docs/` spec, keep everything inline in the artifact — but then no spec file should exist for that topic. Do not split a small topic across two files.
