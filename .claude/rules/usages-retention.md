---
paths: AIUsagesTrackers/Sources/**/*.swift, AIUsagesTrackers/Tests/**/*.swift
---

# Usage account retention

`usages.json` is an append-and-merge state file, not a source of truth for whether
an account still exists upstream. Production code must preserve known accounts in
that file unless the user explicitly chooses an account-visibility action.

Non-negotiable rules:

1. Never delete, filter out, or overwrite a known `VendorUsageEntry` account from
   `usages.json` just because a connector stops returning it, authentication
   fails, a token expires, or an account cannot be resolved during a refresh.
2. When new connector results are merged into existing file contents, merge by
   stable account identity and preserve prior entries that are absent from the
   current tick.
3. Hiding an account from UI must go through `ignoredAccounts` and must be caused
   by an explicit user action. Do not infer ignored accounts from connector
   failures, stale credentials, logout/login churn, or missing API payloads.
4. Add or update tests for any merge, migration, cleanup, or connector change
   that could remove accounts from `usages.json`. Tests should prove that stale
   or temporarily missing accounts are retained and only hidden through explicit
   ignore preferences.
