#!/usr/bin/env bash
#
# Idempotently create the GitHub labels the assistant onboarding and
# evolution workflow relies on (see docs/ASSISTANT-ONBOARDING.md §8).
# Run once per repository — re-running is safe; existing labels are
# left untouched.
#
# Requirements: `gh` authenticated against the target repo.
#
set -euo pipefail

REPO="${1:-}"
if [ -z "$REPO" ]; then
  REPO=$(gh repo view --json nameWithOwner --jq '.nameWithOwner')
fi

create_or_skip() {
  local name="$1"
  local color="$2"
  local description="$3"
  if gh label list --repo "$REPO" --json name --jq '.[].name' | grep -qx "$name"; then
    echo "  ✓ ${name} already exists"
  else
    gh label create "$name" --repo "$REPO" --color "$color" --description "$description"
  fi
}

echo "→ Type labels"
create_or_skip "type:new-assistant"     "0E8A16" "Adding support for a new AI assistant"
create_or_skip "type:vendor-evolution"  "1D76DB" "Evolving an already-supported assistant connector"

echo "→ Kind labels (vendor-evolution only)"
create_or_skip "kind:enrichment"  "C5DEF5" "Backward-compatible additive change"
create_or_skip "kind:breaking"    "B60205" "Backward-incompatible API change requiring an app version bump"
create_or_skip "kind:urgent-fix"  "E99695" "Vendor unilaterally broke compat — connector currently broken in the field"

echo "→ Phase labels"
create_or_skip "phase:proposed"      "FBCA04" "Awaiting maintainer triage"
create_or_skip "phase:approved"      "FBCA04" "Triaged; contributor can begin work"
create_or_skip "phase:implementing"  "FBCA04" "Contributor is implementing"
create_or_skip "phase:review"        "FBCA04" "PR ready for code review"
create_or_skip "phase:testing"       "FBCA04" "Awaiting tester sign-off on the latest build"
create_or_skip "phase:merge-ready"   "0E8A16" "Tester threshold met; ready to merge"
create_or_skip "phase:merged"        "0E8A16" "Merged; awaiting tagged release"
create_or_skip "phase:released"      "5319E7" "Released; terminal state"

echo "✓ Labels bootstrapped"
