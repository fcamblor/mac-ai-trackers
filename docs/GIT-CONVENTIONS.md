# Git conventions

## Commit message format

This project uses [Conventional Commits](https://www.conventionalcommits.org/). Every commit subject must follow:

```
type(scope): short imperative description   ← ≤72 chars
<blank line>
Why this change exists — motivation,
constraint, or problem solved.              ← optional body, only if subject isn't enough
```

### Types

| Type       | When to use                                              |
|------------|----------------------------------------------------------|
| `feat`     | New capability or behaviour                              |
| `fix`      | Bug correction                                           |
| `refactor` | Code restructuring with no behaviour change              |
| `test`     | Adding or fixing tests                                   |
| `docs`     | Documentation only                                       |
| `chore`    | Tooling, deps, config, housekeeping                      |
| `perf`     | Performance improvement                                  |
| `ci`       | CI/CD pipeline changes                                   |
| `build`    | Build system or compilation changes                      |

### Scope

Use the component or layer being changed: `connector`, `poller`, `models`, `io`, `harness`, `logger`, etc.

## Language

All commit messages must be written in **English**.

## Message rules

- **Explain WHY, not WHAT.** The diff already shows what changed. The message explains why.
- Subject ≤72 characters, imperative mood ("add", "fix", "remove" — not "added", "fixes").
- No file or function names in the subject — the diff has that detail.
- Body only when the subject alone doesn't convey the motivation. No filler bodies.
- Never: "update code", "various fixes", "WIP", "misc".

## Fixup commits

When correcting a mistake introduced by a recent unpushed commit, prefer a fixup:

```bash
git commit --fixup=<sha-of-original-commit>
```

The fixup can later be squashed by the author with `git rebase --autosquash`. Do not rebase autosquash automatically — leave that to the author.

Only use fixup if:
- The target commit is **not yet pushed** to the shared upstream (`git log @{u}..HEAD`).
- There is a single, unambiguous original commit to fix.

## Staging

- Stage files **by name** — never `git add -A` or `git add .`.
- Never commit `.env`, `credentials*`, private keys, or large binary dumps.
- Each commit should represent one logical unit of change. If a diff mixes unrelated changes, split them into separate commits.

## Hooks and safety

- Never bypass hooks with `--no-verify`.
- Never amend a commit that has already been pushed to a shared branch.
- When a pre-commit hook fails: fix the cause, re-stage, and create a **new** commit (not `--amend`).
