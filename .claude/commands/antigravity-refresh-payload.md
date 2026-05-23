# Refresh Antigravity golden fixture

Read `docs/vendors/google-antigravity.md` first; it defines the 4-endpoint API chain, credential sources, cohorting logic, and sanitization rules. If this command disagrees with that spec, the spec wins.

## Purpose

Re-capture and sanitize payloads from a real Antigravity Workspace account to verify:
- Endpoint parsing logic (userinfo, loadCodeAssist, fetchAvailableModels, retrieveUserQuota)
- Cohorting algorithm (resetTime grouping, remainingFraction split, window duration classification)
- Subtitle deduplication (model display names, reverse order, ellipsis handling)
- Plan detection (currentTier.id + userinfo.hd → Workspace/Free/Paid/Legacy)
- Account identity resolution (userinfo refresh as the signal)

Updates `Tests/Fixtures/google-antigravity-anonymized-golden.json` with fresh, sanitized captures.

## Prerequisites

1. Active Antigravity Workspace account with OAuth token (run `antigravity auth status` first)
2. `.context/antigravity-probe.sh` script with Steps 1–5 configured
3. User has confirmed the payload before committing (prevents PII leakage)

## Steps

### 1. Capture fresh payloads

```bash
cd /Users/fcamblor/conductor/workspaces/mac-ai-trackers/doha
bash .context/antigravity-probe.sh 2>&1 | tee /tmp/antigravity-capture-$(date +%Y%m%d-%H%M%S).log
```

Steps 1–5 in the probe script will:
- Refresh OAuth token (if expired)
- Call userinfo endpoint (identity resolution)
- Call loadCodeAssist endpoint (tier detection, cloudaicompanionProject)
- Call fetchAvailableModels endpoint (model catalogue)
- Call retrieveUserQuota endpoint (quota buckets, resetTime, remainingFraction)

### 2. Sanitize and extract

From the captured log, extract all 4 endpoint responses and apply the sanitization rules from `docs/vendors/google-antigravity.md` Sanitized fields section:

- **Header Authorization**: full removal (`<redacted>`)
- **userinfo**: redact sub, name, given_name, family_name, picture, email, hd
- **loadCodeAssist**: redact cloudaicompanionProject
- **fetchAvailableModels**: redact modelExperiments, supportedMimeTypes, all *email* keys, all *token*/*key*/*secret* keys
- **retrieveUserQuota**: preserve bucket structure and modelId (public), redact all PII and secrets in message context
- **Regex**: replace email patterns, token patterns (ya29\.*, GOCSPX-*) with placeholders

### 3. Update fixture

Create a minimal fixture with:

```json
{
  "metadata": {
    "captured": "ISO8601_TIMESTAMP",
    "plan": "Workspace|Free|Paid|Legacy",
    "sanitized": true,
    "note": "..."
  },
  "userinfo": {...},
  "loadCodeAssist": {...},
  "fetchAvailableModels": {...},
  "retrieveUserQuota": {...}
}
```

Save to `Tests/Fixtures/google-antigravity-anonymized-golden.json`.

### 4. Verify parsing

Run the fixture through the connector's parsing logic (once Swift code exists):

```bash
swift test --filter "AntigravityConnectorTests/testGoldenFixture" 2>&1 | grep -E "(PASS|FAIL|error:)"
```

Checks:
- All 4 endpoints parse without error
- Cohorting groups buckets correctly (by resetTime + remainingFraction)
- Subtitle deduplication removes duplicates in reverse order
- Window duration computed once and cached (delta < 6h → 5h, else weekly)
- Plan detection: currentTier.id="free-tier" + hd non-empty → Workspace
- Account email extracted from userinfo.email (or omitted if null)

### 5. Manual review (safety gate)

Before committing, print the sanitized fixture and confirm:

```bash
cat Tests/Fixtures/google-antigravity-anonymized-golden.json | jq . | less
```

Ensure:
- No email addresses remain (only `<redacted>`)
- No API tokens remain (only `<redacted>`)
- No Google Cloud project IDs remain (cloudaicompanionProject is redacted)
- modelExperiments and supportedMimeTypes are stripped
- Bucket structure is intact for cohorting validation

## Edge cases to validate

- **Cold-start classification**: A bucket captured early in its window (delta < 6h from resetTime) will be classified as 5h; at next reset it will re-classify as weekly. Acceptable: ~3.5% misclassification self-heals.
- **Subtitle with duplicates**: Gemini models often share displayName (e.g., "Gemini 2.5 Flash" appears in multiple buckets). Verify deduplication in reverse payload order and that ellipsis is applied by the UI, not baked into the fixture.
- **Account switch detection**: If you switch Google accounts before running this command, the userinfo endpoint will return a new identity. The connector will create a new VendorUsageEntry in usages.json and preserve the old one. Verify this works as expected (no silent metric drops, no duplicate coalescence).

## Known limitations

- **displayName parser fragility**: If a model's displayName contains a literal `", "` (comma-space), the subtitle split may fragment incorrectly. Current tooling assumes displayNames use parenthesized qualifiers (e.g., "Gemini 2.5 (Preview)", not "Gemini, 2.5 Flash"). File an issue if you observe a breakage.
- **5h cadence unobserved**: Workspace captures to date show only weekly buckets (no 5h windows). The window classification logic remains (delta < 6h → 5h cadence) but is untested in practice. If a real 5h bucket appears, cohorting will treat it independently from weekly buckets (which is correct).
