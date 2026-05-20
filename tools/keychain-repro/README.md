# Claude Keychain duplicate-entry reproduction

These scripts reproduce the multi-entry Keychain scenario where unrelated
Claude CLI state can share the same `Claude Code-credentials` service, so you
can exercise the **Coding Assistants → Claude Code credentials** diagnostic in
Settings.

The `claude` CLI normally writes a single entry under the generic-password
service `Claude Code-credentials` (with `kSecAttrAccount` set to your macOS
username). MCP plugin OAuth state can land in the same service under an
"unknown" account, which then competes with the real OAuth bearer the first
time the app runs `security find-generic-password -s "Claude Code-credentials"`.

## What the scripts do

- `create-claude-duplicates.sh` — adds **fake** entries under the
  `Claude Code-credentials` service. By default it only adds an
  `mcpOAuth`-shaped entry with `kSecAttrAccount = unknown` so it can shadow
  your real `claude` CLI entry. Pass `--with-fake-oauth` to also add a
  second `claudeAiOauth`-shaped entry under `kSecAttrAccount = claude-repro-user`
  for environments where the real CLI is not installed.
- `delete-claude-duplicates.sh` — removes only the fake entries the create
  script wrote, identified by their fixed accounts (`unknown` and, if
  added, `claude-repro-user`). Your real CLI-written entry is never touched.

Both scripts use `-A` so the test entries do not raise extra ACL prompts —
they're test artefacts, not credentials worth protecting.

## Usage

```bash
# Inject a duplicate that shadows the real entry
./tools/keychain-repro/create-claude-duplicates.sh

# Optional: also inject a fake OAuth entry for envs without `claude` installed
./tools/keychain-repro/create-claude-duplicates.sh --with-fake-oauth

# Clean up the fake entries
./tools/keychain-repro/delete-claude-duplicates.sh
```

After running the create script, open AI Usages Trackers, expand a Claude
row in the popover, then click **Open Coding Assistants diagnostic** and
**Run diagnostic** in the Settings tab.
