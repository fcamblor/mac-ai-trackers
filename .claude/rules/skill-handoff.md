# Skill handoff conventions

Every `assistant-*` skill ends a phase by transitioning a GitHub label
and (often) posting a comment. To remove copy-paste friction from the
maintainer, follow these conventions uniformly.

## 1. Phase-A self-check: detect label drift before doing anything

At the start of every `assistant-*` skill (Phase A), after reading the
issue:

- Detect a **mutex violation** (more than one `phase:*` label
  simultaneously). The CI workflow `phase-label-gate.yml` enforces the
  invariant, but the workflow may not have caught up yet (concurrency
  serialisation, GitHub event lag). When the local read sees more than
  one `phase:*` label, propose to remove the stale ones in a single
  `gh issue edit` and confirm Y/n before proceeding.
- Detect a **scope mismatch** (issue is not at the expected phase for
  this skill). Refuse explicitly and name the right skill instead of
  silently working anyway.

## 2. HITL decisions vs mechanical execution

The decision belongs to the maintainer (approve vs reject, merge vs
hold, count a tester vs ask for follow-up). The mechanical execution of
that decision — `gh issue edit --add-label`, `gh issue comment`,
`gh pr ready`, `gh release edit` — does NOT belong to the maintainer.

Pattern to follow at the end of each phase:

1. Surface the decision the maintainer must make.
2. Once they confirm the verdict (in plain text or by selecting an
   option), show the exact `gh` commands you intend to run.
3. Ask for a single Y/n confirmation covering the whole block.
4. Execute. Do not split into multiple confirmation rounds for what is
   logically one transition.

Never end a phase with "now please run `gh issue edit ...`" expecting
the maintainer to copy-paste. The skill is the operator; the maintainer
is the deciding party.

## 3. Per-skill PR pre-flight (review-and-onward skills)

Skills that touch a PR (`assistant-review`, `assistant-merge`) must
check, in Phase A, before doing any work:

- `gh pr view <pr> --json isDraft,mergeable,author,headRefOid`
- Refuse with a concrete instruction if `isDraft=true` (suggest
  `gh pr ready <pr>`) or `mergeable=CONFLICTING` (suggest a rebase).
- For `assistant-review`, when `author.login` equals the current
  `gh api user` login, use `gh pr review --comment` instead of
  `--approve` (GitHub forbids self-approval).

## 4. Phase-label transition table

When a skill needs to flip `phase:*`, the canonical one-liner is:

```sh
gh issue edit <n> --remove-label "phase:<from>" --add-label "phase:<to>"
```

Always include both `--remove-label` and `--add-label` so the
mutex-violation auto-revert in `phase-label-gate.yml` never fires.
