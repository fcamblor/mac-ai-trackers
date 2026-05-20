#!/usr/bin/env bash
#
# Inject fake "Claude Code-credentials" entries to reproduce the duplicate
# Keychain service scenario handled by the Coding Assistants diagnostic.
# See ./README.md for context.
#
# Idempotent: re-running updates the same entries (security add-generic-password -U).

set -euo pipefail

SERVICE="Claude Code-credentials"
MCP_ACCOUNT="unknown"
FAKE_OAUTH_ACCOUNT="claude-repro-user"

# mcpOAuth-only payload — matches the entry shape that shadows the real
# OAuth bearer when ClaudeCredentialLocator runs `security … -s <svc> -w`
# without an account scope (the unscoped lookup picks the first match).
MCP_PAYLOAD='{"mcpOAuth":{"state":"pending","clientId":"repro-mcp-client","redirectUri":"http://localhost:54321/callback"}}'

# claudeAiOauth payload with an expiry far in the future so the locator's
# pre-check considers it usable. accessToken is intentionally fake — the
# Anthropic API will 401, which is fine for testing the diagnostic path.
EXPIRES_AT_MS=$((($(date +%s) + 30 * 86400) * 1000))
FAKE_OAUTH_PAYLOAD=$(cat <<EOF
{"claudeAiOauth":{"accessToken":"sk-ant-repro-FAKE","refreshToken":"sk-ant-refresh-FAKE","expiresAt":${EXPIRES_AT_MS},"scopes":["user:profile"]}}
EOF
)

want_fake_oauth=false
for arg in "$@"; do
  case "$arg" in
    --with-fake-oauth) want_fake_oauth=true ;;
    -h|--help)
      sed -n '2,8p' "$0"
      exit 0
      ;;
    *)
      echo "unknown arg: $arg" >&2
      exit 64
      ;;
  esac
done

echo "→ Adding mcpOAuth-shaped entry (service='$SERVICE', account='$MCP_ACCOUNT')"
security add-generic-password \
  -U \
  -A \
  -s "$SERVICE" \
  -a "$MCP_ACCOUNT" \
  -j "ai-trackers repro: MCP OAuth state placeholder" \
  -w "$MCP_PAYLOAD"

if $want_fake_oauth; then
  echo "→ Adding claudeAiOauth-shaped entry (service='$SERVICE', account='$FAKE_OAUTH_ACCOUNT')"
  security add-generic-password \
    -U \
    -A \
    -s "$SERVICE" \
    -a "$FAKE_OAUTH_ACCOUNT" \
    -j "ai-trackers repro: fake claudeAiOauth bearer" \
    -w "$FAKE_OAUTH_PAYLOAD"
fi

echo
echo "Done. Run the Coding Assistants diagnostic in Settings to inspect the entries."
echo "Use ./delete-claude-duplicates.sh to clean up."
