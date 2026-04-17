---
paths: **/*.md
---

# Markdown authoring rules

## Language: English only

All Markdown files in this repository MUST be written in English, regardless of the conversation language. This includes `CLAUDE.md`, every file under `docs/`, `README.md`, and any new `*.md`.

- When creating a new Markdown file, write it in English from the start even if the user's prompt is in another language.
- When editing an existing Markdown file that contains non-English prose, translate the edited sections to English instead of preserving mixed languages.
- Code blocks, file paths, commands, and identifiers keep their original form — this rule applies to natural-language prose only.

## Write for longevity

Markdown in this repository is long-lived context. Optimize each file so it does not need to be rewritten as the code evolves. Avoid anything that ties documentation to a specific moment in time or to renamable artifacts:

- Do NOT reference specific commit SHAs, PR numbers, or branch names.
- Do NOT describe the project as being in a transient state ("currently a Hello World", "not yet implemented", "WIP"). If a feature does not exist, simply do not document it.
- Do NOT speculate about intent or future direction ("the name suggests…", "will eventually…"). Document what the code actually does today in terms that remain true tomorrow.
- Do NOT list every file, symbol, or dependency when a structural description is enough — exhaustive lists drift out of date quickly.
- Avoid naming specific files, types, or symbols that could be renamed or moved. Prefer describing roles and responsibilities ("the SwiftUI entry point", "the package manifest") over fixed identifiers. When a path is truly stable because a tool mandates it (e.g. `Package.swift` for Swift Package Manager, `.claude/rules/` for Claude Code), it is fine to use it.
- Do NOT duplicate information that already lives authoritatively in code or tool manifests (version numbers, platform minimums, target lists). Point readers at the source of truth instead of mirroring it.

When in doubt, ask: "Will this sentence still be accurate after the next three features ship, or after a plausible rename?" If not, rephrase or remove it.

## Single source of truth across Markdown files

When two Markdown files cover the same topic, exactly one is the authoritative spec; the other references it and adds only what is genuinely its own (workflow steps, scaffolding procedure, agent phases, etc.).

This applies in particular to these pairs:

- `docs/<topic>.md` (spec) ↔ `.claude/skills/<name>/SKILL.md` (skill that implements it)
- `docs/<topic>.md` (spec) ↔ `.claude/agents/<name>.md` (agent prompt that uses it)
- `docs/<topic>.md` (spec) ↔ `.claude/commands/<name>.md` (slash command that triggers it)

Rules:

- Templates, file formats, naming conventions, and directory layouts belong in the spec, NOT in the operational artifact.
- The operational artifact MUST start with a one-line pointer ("Read `docs/<topic>.md` first; it defines X, Y, Z.") and MUST include a conflict-resolution line ("If this artifact disagrees with `docs/<topic>.md`, the spec wins.").
- Before adding concrete content (a template block, a format string, a list of sections) to an operational artifact, check whether that content already exists in a `docs/` spec. If it does, reference it instead of copying it.

## Exception: `roadmap/`

Files under `roadmap/` intentionally describe planned, not-yet-implemented work. The "Write for longevity" rules above (no transient state, no speculation about future direction) do NOT apply there — a roadmap is precisely a record of intent and ordering that will evolve as features ship. The English-only rule still applies. See `docs/ROADMAP.md` for the roadmap file conventions.
