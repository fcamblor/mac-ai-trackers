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
