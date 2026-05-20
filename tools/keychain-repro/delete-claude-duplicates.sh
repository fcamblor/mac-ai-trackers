#!/usr/bin/env bash
#
# Remove the fake "Claude Code-credentials" entries created by
# create-claude-duplicates.sh. Never touches your real CLI-written entry —
# only deletes by the fixed test accounts.

set -euo pipefail

SERVICE="Claude Code-credentials"
FAKE_ACCOUNTS=("unknown" "claude-repro-user")

for account in "${FAKE_ACCOUNTS[@]}"; do
  if security find-generic-password -s "$SERVICE" -a "$account" >/dev/null 2>&1; then
    echo "→ Deleting entry (service='$SERVICE', account='$account')"
    security delete-generic-password -s "$SERVICE" -a "$account" >/dev/null
  else
    echo "✓ No entry for account='$account' — nothing to delete"
  fi
done

echo
echo "Done."
