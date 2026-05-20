# Vendor plugin contract

This document is the single source of truth for what every AI-assistant
vendor integration must provide. A new connector is a set of files
implementing the protocols listed here, plus a registry registration. No
shared subsystem (logging, branding, scheduler, AppDelegate) needs to be
edited per vendor — the registry is the only seam.

The contract is compile-time. There is no runtime plugin loader, no
external dylib, no dynamic discovery. Adding a vendor is a code change
that ships with the binary.

This contract composes with — and never relaxes — the Swift quality docs:
`SWIFT-CONCURRENCY.md`, `SWIFT-ERROR-HANDLING.md`, `SWIFT-IO-ROBUSTNESS.md`,
`SWIFT-TESTABILITY.md`, `SWIFT-VALUE-OBJECTS.md`. Read those first; this
contract assumes them.

## 1. Plugin points

A vendor integration declares one `VendorBundle` value type that bundles
every plugin point. The bundle is the only public surface the registry
reads.

| Plugin point             | Type / protocol             | Required? |
|--------------------------|-----------------------------|-----------|
| Vendor identity          | `Vendor` (string-backed)    | yes       |
| Branding                 | `VendorBranding`            | yes       |
| Usage fetching           | `any UsageConnector`        | yes       |
| Credential locator       | `any CredentialLocator`     | yes (driven by the connector) |
| Payload sanitizer        | `any PayloadSanitizing`     | yes       |
| Logger                   | `FileLogger`                | yes       |
| Logging proxy            | `LoggingProxy`              | yes (composed from logger + sanitizer) |
| Status / outages         | `any StatusConnector`       | required when vendor has a public status page; otherwise `nil` |
| Active-account monitor   | `any ActiveAccountMonitoring` | optional |
| Documentation pointer    | `VendorDocumentation`       | yes       |

`status` and `activeAccountMonitor` are conditional because a vendor may
not expose either — the framework treats `nil` as "feature disabled for
this vendor", not "partial implementation". For `status` specifically,
`nil` is only acceptable when the dated vendor doc explicitly states that
no public status page exists; see §7.

## 2. Vendor identity

`Vendor` is a string-backed value type defined in the lib's `Models/`. New
vendors add a `static let` next to the existing ones. The string is the
primary key of the vendor across persisted JSON, so it is forward-compatible:
unknown vendors decode without throwing.

A vendor identifier MUST be lowercase, ASCII, and stable for the lifetime of
the connector — renaming it breaks history files written by older builds.

## 3. Branding

`VendorBranding` is a value type with these fields:

| Field         | Type    | Notes                                       |
|---------------|---------|---------------------------------------------|
| `vendor`      | `Vendor`| identity                                    |
| `displayName` | `String`| human-readable name shown in the UI         |
| `tintHex`     | `String`| 6-digit hex tint applied to the menu bar icon |
| `assetName`   | `String`| basename of the PDF mark in `App/Resources/VendorBranding/` (vector, scales without quality loss) |

Each vendor ships its mark as a `<assetName>.pdf` placed under
`App/Resources/VendorBranding/`. Vector PDF is mandatory because the menu
bar renders the icon at multiple sizes. The conversion-from-SVG flow lives
under `scripts/render-<vendor>-mark.swift`.

The registry — not a switch statement — resolves a `Vendor` to its
`VendorBranding`. Unknown vendors return `nil` and the UI falls back to a
text-only label.

## 4. Usage connector

```swift
public protocol UsageConnector: Sendable {
    var vendor: Vendor { get }
    func fetchUsages() async throws -> [VendorUsageEntry]
    func resolveActiveAccount() -> AccountEmail?
}
```

Invariants:

- Connectors are `actor`s. `vendor` is `nonisolated` so the poller can read
  it without hopping isolation.
- `resolveActiveAccount()` must be cheap and synchronous-ish — it runs on
  every poll tick and on every menu refresh.
- `fetchUsages()` must never throw past the boundary on a recoverable
  error. It returns an entry with `lastError` set instead so the previous
  metrics stay visible.
- Every emitted `UsageMetric` must be `.timeWindow` or `.payAsYouGo` —
  never `.unknown`. The contract conformance test enforces this.
- Every emitted `resetAt` must parse as a strict ISO 8601 datetime via
  `ISODate.parsing(_:)`. Calendar dates (e.g. a vendor field handed back
  as `yyyy-MM-dd`) are promoted to UTC midnight via
  `ISODate.parsingFlexibleDate(_:)` at the connector boundary.
- The connector emits whatever number of metrics the vendor exposes — no
  artificial cap, no "hide if zero" filter. The UI decides what to render.

## 5. Credential locator

The application **never** owns, refreshes, rotates, or persists tokens.
Each vendor's CLI (`claude`, `codex`, `gh`) keeps full lifecycle ownership.
The locator's job is purely to **read** what the vendor's CLI has already
written.

```swift
public protocol CredentialLocator: Sendable {
    associatedtype Credentials: Sendable
    /// Reads credentials from external sources owned by the vendor's CLI.
    /// MUST NOT write, refresh, rotate, or persist tokens.
    func locate() async throws -> Credentials
}
```

The associated `Credentials` type lets each vendor carry its own
domain-specific shape (OAuth token vs API key + org id vs token + login)
without lossy generalization.

### Read-only invariant

Locators MUST NOT:

- call `SecItemAdd`, `SecItemUpdate`, `SecItemDelete`;
- write to the vendor's config files;
- shell out to `<vendor> auth login`, `<vendor> auth logout`, or any
  credential-mutating subcommand.

A SwiftLint custom rule flags writes inside any `*CredentialLocator.swift`
file at build time.

### Injectability

Every external dependency is constructor-injected:

- `environment: [String: String]`
- `fileManager: FileManager`
- `processRunner: ProcessRunning`
- `keychainAccessor: KeychainReading` (when applicable)

No locator may call `ProcessInfo.processInfo`, `SecKeychain*`, or
`/usr/bin/security` directly — every such call goes through an injectable
collaborator.

### Error contract

Errors are enum cases with associated values per `SWIFT-ERROR-HANDLING.md`.
Two error classes are mandatory and distinct:

- "not logged in" — the vendor's CLI never wrote credentials. Normal user
  state, surfaced as a calm message.
- "found but unreadable" — file or keychain entry exists but is
  malformed. Bug or vendor schema change, surfaced as an actionable
  diagnostic.

## 6. Payload sanitization

Every payload (request body, response body, headers, error message)
emitted to a log MUST go through a vendor-specific sanitizer **before**
reaching the file. Sanitization is enforced at the logger boundary, not
at the call site.

```swift
public protocol PayloadSanitizing: Sendable {
    /// Returns a copy of `payload` with confidential fields stripped or masked.
    /// MUST be idempotent and side-effect free.
    func sanitize(_ payload: Data) -> Data
    func sanitize(_ headers: [String: String]) -> [String: String]
    func sanitize(_ message: String) -> String
}
```

### Default-deny header rules

Composed into every per-vendor sanitizer via `BaseHeaderSanitizer`:

| Header (case-insensitive) | Replacement   |
|---------------------------|---------------|
| `Authorization`           | `<redacted>`  |
| `Cookie`, `Set-Cookie`    | `<redacted>`  |
| `X-Api-Key`               | `<redacted>`  |
| `X-Auth-Token`            | `<redacted>`  |
| `Proxy-Authorization`     | `<redacted>`  |

### Email-pattern rule

A regex `[A-Za-z0-9._+-]+@[A-Za-z0-9.-]+` matches email-like strings in
bodies and messages and replaces them with `<email>`. The vendor doc's
`Sanitized fields` section lists any field where this default must be
suppressed (rare — only when the vendor publishes the field as part of
its public API surface).

### Per-vendor field list

Every connector's `docs/vendors/<vendor>.md` carries an exhaustive
`Sanitized fields` section. That list drives the leakage test (see §8) and
is the contract: a field added upstream that isn't on the list is by
default a sanitization gap.

### LoggingProxy

`LoggingProxy` wraps a `FileLogger` and a `PayloadSanitizing`. Connectors
log payload-bearing entries through the proxy only — no direct
`logger.log(.debug, "...payload...")` allowed. A SwiftLint custom rule
enforces this at build time on `*Connector.swift` and
`*CredentialLocator.swift` files.

Proxy entry format (one log line per HTTP exchange):

```
<method> <url> -> HTTP <status> in <latency>ms
  request headers: <sanitized headers JSON>
  request body: <sanitized body or "<empty>">
  response headers: <sanitized headers JSON>
  response body: <sanitized body or "<truncated, N bytes>">
```

Deterministic line shape because testers attach raw log files; structured
lines make triage feasible.

## 7. Status connector

```swift
public protocol StatusConnector: Sendable {
    var vendor: Vendor { get }
    func fetchOutages() async throws -> [Outage]
}
```

Required when the vendor has a public status page documented in its
`docs/vendors/<slug>.md` Status page section. A vendor without a public
status page omits this slot — the registry threads `nil` through to the
poller, which skips status calls for that vendor — and the dated vendor
doc must explicitly state "No public status page" so future contributors
can tell the difference between "missing" and "intentionally absent".

If the status page is shared across multiple products (e.g. GitHub's
status page covers Copilot alongside Actions, Pages, etc.), the connector
must filter incidents down to the components that actually affect this
vendor; the filter rule belongs in the dated vendor doc.

## 8. Active-account monitor

```swift
public protocol ActiveAccountMonitoring: Sendable {
    var vendor: Vendor { get }
    func start() async
    func stop() async
}
```

Optional. A monitor watches the local source the vendor's CLI writes
(JSON config, YAML hosts file, keychain entry, …) and fires a callback
when the active identity changes. The callback signature stays
vendor-specific — the protocol only formalizes the lifecycle so the
registry can drive `start()` / `stop()` uniformly.

`start()` must be idempotent — calling it twice is a no-op.

## 9. Logger registration

Every `VendorBundle` carries its own `FileLogger`. The default file path
is `~/.cache/ai-usages-tracker/<vendor>-usages-connector.log`. Adding a
vendor does not require editing `Loggers` or any cross-cutting subsystem;
the bundle owns the logger declaration.

`LogCleaner` discovers loggers via the registry, so retention applies
automatically to any newly added vendor.

## 10. Verbose vendor mode

The framework supports a debug mode where a single vendor's connector
emits, at `.debug` level, the **sanitized** payloads of every API
exchange. Production builds with neither activation source set
**never** ship verbose logging — it requires either an explicit
environment variable or a build-time Info.plist key.

Resolution order, first match wins:

1. Environment variable `AI_TRACKER_VENDOR_DEBUG=<vendor-slug>` —
   power-user override on standard builds.
2. Info.plist key `AITrackerVendorDebug` — set by nightly tester builds
   attached to a `type:new-assistant` PR. Scoped to the vendor under test.

The wiring layer reads this at startup, identifies "the verbose vendor",
and constructs that vendor's `LoggingProxy` at `.debug` level. All other
vendors retain their normal proxy. Bundle declarations are unaware of the
setting.

## 11. Vendor documentation

Every vendor ships a `docs/vendors/<vendor>.md` whose template is
`docs/vendors/_TEMPLATE.md`. The doc is treated as a **dated snapshot** of
how the vendor's API behaves at a given moment, not as a forever-true
reference — vendor APIs drift silently, and the historical baseline is
the only artifact that lets a future contributor compare what the API
used to look like against what it does now.

Mandatory sections (the template enforces order and headings):

- **Last verified header.** A machine-parseable `> **Last verified:**
  YYYY-MM-DD by @handle on <plan>` directly under the H1.
- **Endpoints.** Full URL, method, headers, timeout, response
  content-type. Each entry dated (`_verified: YYYY-MM-DD_`).
- **Credential sources.** Cascade order, exact paths and keys, names of
  the vendor CLIs that own each source. Dated.
- **Sanitized fields.** Exhaustive list of fields stripped from logs:
  tokens, keys, refresh tokens, raw cookies, secret account ids,
  email-like patterns. Each entry includes its location in the payload
  and the redaction style. This list drives the leakage test. **A field
  added upstream that isn't on this list is by default a sanitization
  gap.**
- **Plan variants observed.** Free / Pro / Team / Enterprise — each with a
  representative dated sanitized payload and the fields the connector
  reads. Variants assumed but not yet **verified by a tester** are marked
  explicitly as such.
- **Metric semantics.** Per `UsageMetric` emitted by the connector,
  mapping from raw payload fields to the Swift case. Includes reset
  cadence (rolling vs calendar boundary), unit, edge cases (free-tier
  overage, "unlimited" flags). Dated.
- **Time semantics.** Whether the API returns ISO 8601 datetimes or
  calendar dates, and whether the connector promotes calendar dates to
  UTC midnight.
- **Error catalog.** HTTP status codes seen in the wild and the
  connector's response (degrade, retry, surface). Dated.
- **Known unknowns.** Behaviors the contributor could not verify directly
  (e.g. enterprise plans without a tester). Filled in over time by the
  tester gate workflow.
- **Source references.** Community write-ups, official docs — every link
  followed by `(retrieved YYYY-MM-DD)`.
- **Change log.** Append-only `YYYY-MM-DD — what changed`. The first entry
  is "initial capture". Subsequent entries fill in as drift is discovered.

### Sample payload format

Captured payloads are fenced JSON blocks prefixed with a comment:

```markdown
<!-- captured: 2026-05-07, plan: Pro, login: redacted -->
```

Sensitive fields are redacted but the structure, types, and field
presence are preserved. Multiple snapshots over time can coexist — older
ones get a `(superseded by YYYY-MM-DD)` annotation rather than being
deleted, so the drift trail is visible.

### Re-verification discipline

The reviewer checklist for any PR touching a connector requires bumping
`Last verified` and appending a Change log entry. A stale doc is a
contract violation.

## 12. Registry and AppDelegate

```swift
public enum VendorRegistry {
    public static let bundles: [VendorBundle] = [
        ClaudeCodePlugin.bundle,
        CodexPlugin.bundle,
    ]
}
```

`AppDelegate` composes assistants from `VendorRegistry.bundles` only — no
named per-vendor properties. Adding a vendor means adding one line to the
registry; nothing else above the registry edits.

## 13. Conformance test

A single `VendorRegistryConformanceTests` walks `VendorRegistry.bundles`
and asserts:

- Every emitted `MetricKind` is `.timeWindow` or `.payAsYouGo` (no
  `.unknown`).
- Every `resetAt` parses as a strict ISO 8601 datetime via
  `ISODate.parsing(_:)`.
- Every branding entry resolves to an existing PDF asset under
  `App/Resources/VendorBranding/`.
- Every `documentation` pointer points at an existing
  `docs/vendors/<vendor>.md` carrying a parseable `Last verified:` line.
- The leakage test fixture for each vendor exists and produces no
  surviving secret after sanitization.

## 14. Onboarding scaffolding

Scaffolding is **skill-only** — there is no shell script. The skill
defined in the `new-assistant-onboarding-workflow` epic creates every
required file directly via `Write` / `Edit`, using this contract as its
template source. This contract specifies the shape; the skill specifies
the procedure.
