# Assistant onboarding and evolution workflow

This document is the single source of truth for shipping any vendor-scoped
change in AI Usages Tracker — both adding support for a new AI assistant and
evolving the integration of an already-supported one when its API drifts.

It defines the lifecycle, the artefacts (issue, PR, build, comment, label),
the gating discipline, and the phase-↔-skill mapping. Operational artefacts
(skills, workflows, issue forms, PR template, reviewer checklist) reference
this spec; if any of them disagrees with this file, the spec wins.

The workflow spans days to weeks of wall-clock time, frequently across
sessions and machines. Every artefact in it must be invocable cold — no skill
or action assumes in-memory state from a previous session. Durable state
lives on the issue (and, when one exists, on the linked PR).

## 1. Two issue types, one lifecycle

Two kinds of work share the same lifecycle, the same skill family, the same
nightly-build pipeline, and the same tester sign-off threshold:

- **`type:new-assistant`** — adding a vendor not yet supported.
- **`type:vendor-evolution`** — modifying an already-supported vendor's
  connector when the vendor's API evolves. Qualified by a sub-label:
  - `kind:enrichment` — backward-compatible additions.
  - `kind:breaking` — backward-incompatible API change requiring an app
    version bump and an explicit release-notes callout.
  - `kind:urgent-fix` — vendor unilaterally broke compat; the connector is
    currently broken in the field. **Emergency escape hatch**: a single
    non-author tester confirmation is acceptable to merge; the issue stays
    open after release for follow-up confirmations.

The skills branch on those labels where the work genuinely differs
(scaffolding vs in-place refactor; README update on first ship vs none on
evolution; release-notes wording; threshold escape hatch).

## 2. Why the issue is the system of record

A pull request is the wrong durable container for this lifecycle: it does
not exist during request and triage, it closes on merge while the work
continues into release, and its comment thread is poorly suited to a
multi-stakeholder, multi-week conversation.

A GitHub **issue** is open from the first request to the final
officialization, carries structured fields via an issue form, persists
post-merge as the historical record, and supports a state machine via
labels. The PR is one transient artefact referenced by the issue.

Two consequences flow from this:

1. **Each phase is owned by exactly one skill**, advancing exactly one
   `phase:*` label transition. Skills rebuild context every time they run.
2. **The issue body is the contract; the PR template is light** and starts
   with `Closes #<issue>` so closing the PR feeds back into the issue.

## 3. Phase-label lifecycle

A single mutex label `phase:<step>` lives on every issue carrying a `type:*`
label from §1. Exactly one phase label is set at any time. Transitions are
unidirectional except for explicit rollback (e.g. `phase:review` →
`phase:implementing` if the review demands rework).

The phase set is identical for both issue types — what branches is the
**work performed at each phase**, controlled by the issue's `type:*` and
(for vendor-evolution issues) `kind:*` labels.

| Phase label | Set when | Owning skill (runs during this phase) | Set by |
|---|---|---|---|
| `phase:proposed` | Issue created via the issue form | (none — awaiting triage) | Issue form default |
| `phase:approved` | Maintainer triages and accepts | `assistant-triage` (optional helper) | Maintainer |
| `phase:implementing` | Contributor begins work; draft PR may exist | `assistant-implement` | Maintainer |
| `phase:review` | PR is opened and ready for review | `assistant-review` | Maintainer |
| `phase:testing` | Code review passed; testers can validate | `assistant-tester-followup` (does not transition out) | Maintainer |
| `phase:merge-ready` | Tester threshold reached on the latest build SHA | `assistant-merge` | Maintainer |
| `phase:merged` | PR squash-merged; awaiting tagged release | `assistant-release` (once a release ships) | `assistant-merge` |
| `phase:released` | Tagged release ships with the change | (terminal — no skill operates after release) | `assistant-release` |

A separate concept — **vendor doc re-verification** — happens long after
`phase:released` and operates on a different artefact (the live vendor doc).
It does not transition issue labels. See `assistant-reverify`.

### 3.1 Per-phase walk-through

Each phase entry below specifies: trigger, transition, owning skill, inputs
read (always from durable state), outputs, exit condition.

#### 3.1.1 Proposed

- **Trigger**: anyone opens an issue using one of the two issue forms.
- **Transition**: none → `phase:proposed`.
- **Skill**: none. The issue form sets the labels (`type:*` +
  `phase:proposed`).
- **Outputs**: structured issue body — vendor identity, proposer, links,
  evidence (vendor-evolution: kind dropdown, drift summary).
- **Exit**: maintainer triages.

#### 3.1.2 Approved (or closed)

- **Trigger**: maintainer reviews the proposal.
- **Transition**: `phase:proposed` → `phase:approved` (or issue closed
  with `wontfix` / `duplicate`).
- **Skill**: `assistant-triage` (optional helper). For vendor-evolution
  issues, this skill applies the `kind:*` label corresponding to the
  dropdown selection — issue forms can only apply static labels from
  their frontmatter, so dynamic per-submission labels are necessarily a
  triage-time concern.
- **Outputs**: `phase:approved` applied (by the maintainer, after the
  draft), decision comment summarizing constraints.
- **Exit**: contributor can begin work.

#### 3.1.3 Implementing

- **Trigger**: contributor signals readiness.
- **Transition**: `phase:approved` → `phase:implementing`.
- **Skill**: `assistant-implement`. Branches on `type:*`.
- **Inputs**: issue body, `docs/VENDOR-PLUGIN-CONTRACT.md`,
  `docs/vendors/_TEMPLATE.md`, the existing `docs/vendors/<vendor>.md`
  (vendor-evolution only), the Swift quality docs.
- **Outputs**, by issue type:
  - **`type:new-assistant`** — connector / credential locator / status /
    monitor / branding / vector PDF mark / `VendorRegistry` entry / dated
    `docs/vendors/<vendor>.md` / tests / draft PR with `Closes #<issue>`.
  - **`type:vendor-evolution`** — targeted refactor of the existing
    connector / locator / sanitizer; bumped `Last verified` and per-section
    dates in the vendor doc; new dated samples appended (older samples kept
    and annotated `superseded by YYYY-MM-DD`); Change-log entry; updated
    leakage fixture if new fields appeared; for `kind:breaking`, a
    `Min app version: <next-version>` annotation in the doc and a `!`
    Conventional Commits marker in the title.
- **Exit**: PR moved out of draft; contributor asks the maintainer to
  advance to `phase:review`.

#### 3.1.4 Review

- **Trigger**: PR ready for review.
- **Transition**: `phase:implementing` → `phase:review`.
- **Skill**: `assistant-review`.
- **Inputs**: PR diff, vendor doc, contract spec, reviewer checklist
  (`docs/REVIEW-CHECKLIST-ASSISTANT-CHANGE.md`), issue body.
- **Outputs**: a single PR review comment grouped by checklist section.
  Documentation track is read first — the vendor doc must stand on its
  own — before opening the diff.
- **Exit**: review approves → maintainer transitions to `phase:testing`.
  Review requests changes → label may roll back to `phase:implementing`.

#### 3.1.5 Testing

- **Trigger**: review passed; CI build is fresh on the PR.
- **Transition**: `phase:review` → `phase:testing`.
- **Skill**: `assistant-tester-followup` — invoked each time a tester
  comment arrives, especially when incomplete. Does not transition.

> **Phase labels are signals, not triggers.** Applying `phase:testing` (or
> any other `phase:*` label) does **not** start any GitHub Actions
> workflow. The label only tells humans — testers, maintainers, the
> follow-up skill — what stage the issue is at. The DMG build workflow
> reacts to **pull request events** (`opened`, `reopened`,
> `synchronize`, `ready_for_review`), and additionally requires:
>
> - the PR is **not a draft** (the workflow gates every job on
>   `github.event.pull_request.draft != true`, so draft PRs produce no
>   sticky build comment and no DMG artifact);
> - the PR is **not in conflict** with the base branch (a conflicting PR
>   may build but cannot be merged, and reviewers should not ask testers
>   to validate a build that will need to be rebuilt after rebase).
>
> Before transitioning to `phase:testing`, the maintainer must therefore
> confirm: PR is ready-for-review (`gh pr ready <n>`), `mergeable` is not
> `CONFLICTING` (`gh pr view <n> --json isDraft,mergeable`), and a fresh
> sticky build comment exists on the PR for the latest head SHA. If any
> of these is missing, the workflow run that produces the DMG either has
> not fired or has been skipped — push a new commit (or run the
> `workflow_dispatch` fallback with the PR number) once the prerequisites
> are met to re-trigger it.
- **Inputs**: tester sign-off comments on the issue (each ideally with
  attached connector log), latest sticky build comment (also posted on the
  issue), the build SHA, the vendor doc's `Sanitized fields` section.
- **Outputs**: a running tally on the issue (sticky tally comment),
  follow-up questions for incomplete confirmations, audit notes on
  attached logs (any sanitization gap blocks the count and the merge
  until a fresh DMG is built), an explicit ready/not-yet verdict.
- **Exit**: tester threshold reached + every attached log audited clean →
  maintainer transitions to `phase:merge-ready`.

The DMG attached during this phase is built with the **tester-debug flag**
set to the vendor under test (cf. §6) **and** the **in-app feedback
banner** wired to the right issue. Testers have two paths to submit
feedback:

- **Path A — recommended, in-app.** Click the tester banner in the app's
  popover; the feedback sheet pre-fills everything (build SHA from the
  bundle, vendor slug, macOS version, checklist). On submit, the app
  copies the comment body to the system pasteboard, opens the issue URL
  in the browser, and reveals the connector log file in Finder so the
  tester drag-drops it into the GitHub composer.
- **Path B — fallback, manual.** Tester downloads the connector log,
  copies the sign-off template from the issue's sticky build comment,
  fills it manually, attaches the log file, posts.

The follow-up skill audits the resulting comment regardless of path
against the vendor doc's `Sanitized fields` list before counting.

##### Sign-off comment template

Posted by testers on the **issue**, as a single comment per tester. The
follow-up skill scans for the `✅ tester-confirm` sentinel.

```
✅ tester-confirm

Plan: <Free | Pro | Team | Enterprise | Other: …>
macOS: <14.x | 15.x | 26.x>
Build SHA: <8 chars> (full: <40 chars>)
Submission path: <in-app | manual>
Verified:
- [x] Active account is detected correctly
- [x] At least one usage metric matches the vendor's own dashboard within reasonable tolerance
- [x] Reset date displayed in the popover matches the vendor's reported reset
- [ ] Optional: outage banner appears when the vendor reports an incident
Connector log attached: yes — <attached file in this comment>
Notes: <free-form>
```

Both SHA forms are required so the maintainer can `git checkout` the
exact build at audit time without ambiguity. Path A pre-fills both forms
from the bundle's `AITrackerBuildCommit` Info.plist key; Path B testers
copy them from the sticky build comment.

##### Counting rules

- The author of the sign-off must differ from the PR author.
- The build SHA must match the latest sticky build comment (a rebase
  invalidates older confirmations; testers re-confirm on the new build).
- A sign-off without an attached connector log is **incomplete** —
  follow-up is requested before counting. Exception: a tester explicitly
  states the verbose mode is producing no output (itself a bug to
  investigate before merge).
- A sanitization gap detected in the attached log blocks the count
  regardless of how many other confirmations exist; the connector must be
  fixed and a fresh DMG built first.

##### Threshold for merge

- **`type:new-assistant`** / **`kind:enrichment`** / **`kind:breaking`**:
  ≥ 2 distinct non-author testers with valid sign-offs on the latest
  build SHA, with audited-clean attached logs.
- **`kind:urgent-fix`**: ≥ 1 non-author tester. The issue stays open
  after release for follow-up confirmations.

#### 3.1.6 Merge-ready

- **Trigger**: tester threshold reached + reviewer checklist green.
- **Transition**: `phase:testing` → `phase:merge-ready`.
- **Skill**: `assistant-merge` — re-verifies gates before acting.
- **Outputs**: PR squash-merged with the standard commit convention; for
  `kind:breaking`, the title carries the `!` Conventional Commits marker.
- **Exit**: PR merged.

#### 3.1.7 Merged

- **Trigger**: PR squash-merged.
- **Transition**: `phase:merge-ready` → `phase:merged` (set by
  `assistant-merge` immediately after the merge).
- **Outputs**: PR closed; the `Closes #<issue>` link still resolved (issue
  stays open until `phase:released`).
- **Exit**: a tagged release `v*.*.*` ships including the merged commit.

#### 3.1.8 Released (and issue closes)

- **Trigger**: a tagged release ships including the merge commit.
- **Transition**: `phase:merged` → `phase:released`.
- **Skill**: `assistant-release`. Branches on `type:*` and `kind:*`.
- **Outputs**:
  - **`type:new-assistant`** — append the new vendor to README's
    "Supported assistants" section; add a row to `docs/vendors/index.md`
    if it exists.
  - **`type:vendor-evolution`** — no README change. For `kind:breaking`,
    ensure the README's compatibility note (or the `Min app version`
    annotation in the vendor doc) is reflected wherever users decide
    which version to install.
  - All types — credit testers in the GitHub release notes by handle.
  - `kind:breaking` — prefix release notes with
    `BREAKING: <vendor> connector requires <next-version>+` and explain
    what users on older versions will see.
  - `kind:urgent-fix` — call out the urgent context: which subset of users
    was affected, since when, what the fix does. The issue may stay open
    a few days at `phase:released` for follow-up confirmations before the
    maintainer closes it manually.
- **Exit**: issue closed; serves as the historical record.

#### 3.1.9 Re-verify (long after, on demand)

Decoupled from the original issue lifecycle — that issue is closed by
this point. The `assistant-reverify` skill itself does not transition any
phase label.

- **Trigger**: contributor or maintainer suspects API drift.
- **Outputs**, depending on what the re-verification finds:
  - **Doc-only refresh** — the live API still matches the connector;
    only the doc was stale. Bumped `Last verified`, fresh dated samples,
    older samples annotated `superseded by <today>`, Change-log entry.
    Lands as a small standalone doc PR.
  - **Drift requiring connector changes** — the skill stops short of
    writing connector code. It files (or instructs the maintainer to
    file) a `type:vendor-evolution` issue, pre-filled with the drift
    summary and evidence, and proposes the appropriate `kind:*`. The
    change then re-enters the normal workflow at `phase:proposed`.

Routing all connector-affecting drift back through `type:vendor-evolution`
keeps a single path for code changes that touch a vendor.

## 4. Skill family

`.claude/rules/skill-authoring.md` mandates that operational artefacts
reference specs rather than duplicating them. Every skill below points at
this spec and at `docs/VENDOR-PLUGIN-CONTRACT.md`, and includes the
conflict-resolution clause.

Common shape every skill follows:

1. Argument: an issue number (or `--vendor <slug>` for `reverify`).
2. Read durable state: `gh issue view`, `gh pr view` (when a PR is linked),
   the contract spec, the vendor doc.
3. Verify the current `phase:*` label matches what the skill expects. If
   it doesn't, refuse and tell the user which skill should run instead.
4. Perform the work.
5. Apply the next `phase:*` label (or, for skills that don't transition,
   post a tally / report comment).
6. Hand off explicitly: name the next skill the user should invoke when
   the next event happens.

Skills never poll, never run in the background. They run when the
maintainer invokes them in response to an event.

| Skill | Phases owned | Notes |
|---|---|---|
| `assistant` | (router) | Reads `type:*` + `phase:*`; routes to the matching sub-skill. Stops; does not perform work itself. |
| `assistant-triage` | 3.1.2 | Optional helper. Applies `kind:*` for vendor-evolution. Drafts decision comment. |
| `assistant-implement` | 3.1.3 → 3.1.4 readiness | Branches on `type:*`. Scaffolds (new-assistant) or refactors (vendor-evolution). |
| `assistant-review` | 3.1.4 | Documentation-first review. Refuses to apply `phase:testing` itself. |
| `assistant-tester-followup` | 3.1.5 | Tally + log audit. Knows the `kind:urgent-fix` threshold escape. Does not transition. |
| `assistant-merge` | 3.1.6 → 3.1.7 | Re-verifies gates. Squash-merges. Applies `phase:merged`. |
| `assistant-release` | 3.1.8 | Branches on `type:*` and `kind:*` for README / release-notes treatment. |
| `assistant-reverify` | (decoupled) | Doc-only refresh PR or files a `type:vendor-evolution` issue. |

## 5. Issue forms, PR template, gating action

### 5.1 Issue forms

Two issue forms under `.github/ISSUE_TEMPLATE/`:

- `new-assistant-request.yml` applies `type:new-assistant` +
  `phase:proposed` and gathers vendor identity, credential sources, plan
  variants, API references, branding asset.
- `vendor-evolution-request.yml` applies `type:vendor-evolution` +
  `phase:proposed` and gathers vendor slug, kind dropdown, drift
  summary, evidence, app-version impact, affected-since timestamp.

`config.yml` disables blank issues and routes other concerns away from
these forms.

### 5.2 PR template

`.github/PULL_REQUEST_TEMPLATE/assistant-change.md` is light — most of the
structured information lives on the issue. The template carries
technical-review checkboxes and a `Closes #<issue>` link.

### 5.3 Maintainer-only gating action

`.github/workflows/phase-label-gate.yml` validates every `phase:*` label
change on issues carrying `type:new-assistant` or `type:vendor-evolution`
against a maintainers list. Unauthorized changes are reverted automatically
and called out publicly on the issue. The action also enforces the
mutex invariant — at most one `phase:*` label at a time.

The action skips events triggered by its own revert (sender type `Bot`)
to avoid an infinite loop.

## 6. Build pipeline

The build pipeline is CI-driven and skill-free — no skill manages it. The
DMG is the only prebuilt artefact; the trust escape hatch for skeptical
readers is "clone the branch and build it yourself"
(`docs/CHECKOUT-AND-BUILD.md`).

### 6.1 Workflow

`.github/workflows/assistant-build.yml` fires on PRs whose linked issue
carries `type:new-assistant` or `type:vendor-evolution`. It:

1. Detects the linked issue (`Closes #<n>` in the PR body) and reads its
   labels + the vendor slug from the issue body.
2. Selects Xcode 26 and strips the SwiftLint plugin (same prep as
   `release.yml`).
3. Invokes `./scripts/build-app-bundle.sh` with these env vars:
   - `VENDOR_DEBUG=<vendor-slug>`
   - `BUILD_COMMIT=<full SHA>`
   - `ONBOARDING_ISSUE_URL=https://github.com/<repo>/issues/<n>`
   The build script bakes them into the produced bundle's Info.plist as
   `AITrackerVendorDebug`, `AITrackerBuildCommit`,
   `AITrackerOnboardingIssueURL`.
4. Packages the `.app` into a DMG named
   `AI-Usages-Tracker-<slug>-<sha8>.dmg`. Computes SHA-256.
5. Uploads as a workflow artifact.
6. Posts (or updates) a sticky comment on **both** the PR (reviewer
   audience) and the linked issue (tester audience), sentinel
   `<!-- assistant-build:sticky -->`.

### 6.2 Sticky comment shape

Issue-side body (full version, includes the in-app feedback path and the
log file location). PR-side body (lighter — reviewer-oriented, links to
the issue for tester instructions). Both carry the short SHA in the
filename and the full SHA in the body.

### 6.3 Tester-debug build mode

Active only on builds produced by the assistant-build CI workflow (and
reproducible locally with `VENDOR_DEBUG=<slug> ./scripts/build-app-bundle.sh`).

What it does:

- Bakes the vendor slug into the produced `.app`'s Info.plist as
  `AITrackerVendorDebug`.
- At runtime, the logging subsystem reads that key (with
  `AI_TRACKER_VENDOR_DEBUG` env var as override) and routes the named
  vendor's connector through a `LoggingProxy` configured for `.debug`
  level + payload logging. Every other vendor stays at the regular level.
- Every payload flows through the connector's `PayloadSanitizing`
  implementation before reaching the log file. Sanitization is enforced
  at the proxy boundary per `docs/VENDOR-PLUGIN-CONTRACT.md`.
- Logs land in the existing per-vendor connector log
  (`~/.cache/ai-usages-tracker/<vendor-slug>-usages-connector.log`),
  subject to the existing 5 MB rotation.

What it does NOT do:

- Enable verbose logging for any other vendor.
- Bypass sanitization.
- Ship in stable releases. The release workflow MUST NOT pass any of the
  three env vars; a CI-side check (or a runtime smoke test) MUST assert
  the three Info.plist keys are absent on a tagged build.

### 6.4 In-app tester feedback

Active under the same conditions as tester-debug mode. The feedback UI is
visible **iff all three** Info.plist keys are present in the running
bundle:

- `AITrackerVendorDebug`
- `AITrackerBuildCommit`
- `AITrackerOnboardingIssueURL`

If any is missing, the feedback UI does not exist in the running app —
no toggle, no settings entry, nothing. This guarantees stable releases
cannot expose the feature.

The banner sits in the popover, just above the vendor cards. Clicking it
opens a sheet with a pre-filled form (build read-only, plan dropdown,
macOS auto-detected, verified checklist, connector-log path with a
"Reveal in Finder" button, optional notes, live Markdown preview).

The "Submit" button performs three actions in sequence:

1. Generates the comment body and copies it to `NSPasteboard`. GitHub
   does not honor `?body=` on existing-issue URLs, so the clipboard
   hand-off is the simplest reliable bridge that does not require a
   GitHub token.
2. `NSWorkspace.shared.open(url)` opens the user's default browser at the
   issue URL (with `#issuecomment-new` fragment for logged-in sessions).
3. `NSWorkspace.shared.activateFileViewerSelecting([logFileURL])` reveals
   the log file in Finder for drag-attach.

A confirmation panel then explains the next step in plain language. The
app does not track whether the comment was actually posted; the issue
and `assistant-tester-followup` are the system of record.

The free-form Notes field is character-capped (~2 KB) so the resulting
comment cannot bump into GitHub's URL or comment-size limits.

## 7. Reviewer checklist

`docs/REVIEW-CHECKLIST-ASSISTANT-CHANGE.md` is the audit grid the
`assistant-review` skill walks and that the PR template references. It
covers issue linkage, contract conformance, dated documentation, tests,
sanitization, build / validation gates, and per-issue-type addenda.

## 8. Repository labels

Created once per repo. Run `./scripts/bootstrap-onboarding-labels.sh`
to materialize them idempotently via `gh label create`:

- Type labels: `type:new-assistant`, `type:vendor-evolution`.
- Kind labels (vendor-evolution only): `kind:enrichment`, `kind:breaking`,
  `kind:urgent-fix`.
- Phase labels: `phase:proposed`, `phase:approved`, `phase:implementing`,
  `phase:review`, `phase:testing`, `phase:merge-ready`, `phase:merged`,
  `phase:released`.

## 9. Out of scope

- Apple Developer ID signing or notarization. Builds remain ad-hoc signed.
- Shipping a ZIP alongside the DMG. The DMG is the only prebuilt artefact.
- A scaffold shell script. Skills do the scaffolding directly.
- Custom GitHub issue types (Enterprise feature). The form + `type:*`
  label cover the same need.
- Automated payment-tier detection. Testers self-declare in their
  feedback comment.
- A merge bot. Merge stays manual; the workflow surfaces readiness.
- An in-app GitHub-API submission path (PAT in Keychain, gist upload).
  Browser hand-off is sufficient for v1.
