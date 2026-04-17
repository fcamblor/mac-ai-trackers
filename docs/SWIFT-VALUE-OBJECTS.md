# Swift value objects

## Prefer value objects over primitive types for domain concepts

Representing domain concepts as plain `String` or `Int` makes APIs ambiguous and allows values to be accidentally swapped. Introduce a value object (a struct wrapping a primitive) whenever a field has a distinct identity or constrained meaning.

Typical candidates in this codebase:
- Email addresses, vendor names, ISO dates — wrap `String`
- Percentages, durations in a fixed unit — wrap `Int`
- Type discriminators with a closed set — use a `String` enum

```swift
// BAD — impossible to tell which String is which at the call site
func updateIsActive(vendor: String, activeAccount: String?) { ... }
updateIsActive(vendor: "claude", activeAccount: "user@example.com")

// GOOD — self-documenting, type-checked
func updateIsActive(vendor: Vendor, activeAccount: AccountEmail?) { ... }
updateIsActive(vendor: .claude, activeAccount: "user@example.com")
```

## Use a struct, not an enum, for open-ended string domains

Use a `struct` when new values can appear without a code change (e.g., vendor names, error codes). Name each known value as a `static let` constant. Unknown values decode transparently without throwing.

```swift
public struct Vendor: RawRepresentable, Codable, Equatable, Hashable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    public static let claude = Vendor(rawValue: "claude")
}
```

Use a `enum` only when the set is closed and an unknown value must be a decode error (e.g., a JSON discriminator).

## Implement Codable manually — the default synthesis does not work for RawRepresentable structs

`JSONEncoder`/`JSONDecoder` do not synthesise `Codable` conformance for custom structs that are `RawRepresentable`. Implement the two methods explicitly:

```swift
public init(from decoder: Decoder) throws {
    rawValue = try decoder.singleValueContainer().decode(String.self)
}

public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(rawValue)
}
```

## Add ExpressibleByXxxLiteral for ergonomic call sites

String-based value objects should conform to `ExpressibleByStringLiteral`; integer-based ones to `ExpressibleByIntegerLiteral`. This keeps call sites and tests readable without sacrificing type safety.

```swift
extension AccountEmail: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) { rawValue = value }
}

// Callers and tests look the same as before
let entry = VendorUsageEntry(vendor: "claude", account: "user@example.com")
dict["user@example.com"]  // subscript resolves to AccountEmail via ExpressibleByStringLiteral
```

Without this conformance, every call site needs an explicit `AccountEmail(rawValue: "...")` constructor — correct but noisy.

## Add CustomStringConvertible for clean logging

Value objects used in log messages should implement `CustomStringConvertible` and return `rawValue` as their description. Without this, string interpolation would print the struct's default representation (`Vendor(rawValue: "claude")` instead of `claude`).

```swift
extension Vendor: CustomStringConvertible {
    public var description: String { rawValue }
}
```

## Add domain behaviour as computed properties

When a value object stores a string that needs parsing (e.g., an ISO date), expose a computed property rather than requiring callers to parse it themselves. This centralises the parsing logic.

```swift
public struct ISODate: RawRepresentable, ... {
    public let rawValue: String

    /// Returns nil if the stored string is not a parseable ISO 8601 date.
    public var date: Date? {
        // New formatter per call — ISO8601DateFormatter is not thread-safe; acceptable for this cold path
        ISO8601DateFormatter().date(from: rawValue)
    }

    public init(date: Date) {
        // New formatter per call — acceptable for this cold path
        rawValue = ISO8601DateFormatter().string(from: date)
    }
}
```

Do not share a static `ISO8601DateFormatter` from inside a value-type method; value types have no isolation boundary. Creating one per call is thread-safe and acceptable for cold paths (see `docs/SWIFT-CONCURRENCY.md`).

## Add Comparable where ordering makes sense

For quantity wrappers (`UsagePercent`, `DurationMinutes`), add `Comparable` by delegating to `rawValue`. This enables `min`, `max`, `sort`, and `<` comparisons in business logic.

```swift
public static func < (lhs: UsagePercent, rhs: UsagePercent) -> Bool {
    lhs.rawValue < rhs.rawValue
}
```

## Value object checklist

When introducing a new domain field, ask:

| Question | If yes |
|---|---|
| Can two fields of this type be accidentally swapped? | Wrap in a value object |
| Can new values appear at runtime without a code change? | Use a `struct`, not an `enum` |
| Is the raw value compared frequently in tests? | Add `ExpressibleByXxxLiteral` |
| Is the value used in log messages? | Add `CustomStringConvertible` |
| Does the raw value need parsing into another type? | Add a computed property |
| Does ordering between values make sense? | Conform to `Comparable` |
