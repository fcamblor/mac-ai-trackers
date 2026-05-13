import Foundation

/// Bridges the cache (known components) and the preferences (per-ID toggle)
/// to produce the `Set<StatusComponentID>` the status connector should
/// retain. Default behaviour for a known component without an explicit
/// preference entry is "subscribed", per the roadmap.
public enum StatusSubscriptionResolver {
    /// Builds a `SubscribedComponentIDsResolver` closure suitable for
    /// injection into a status connector. Returns `nil` when the registry
    /// has no cached components — in that "first run / parser broken"
    /// state, the connector drops every incident, which is the explicit
    /// design choice from the roadmap.
    public static func makeResolver(
        registry: StatusComponentRegistry,
        preferences: any AppPreferences
    ) -> SubscribedComponentIDsResolver {
        return { @Sendable in
            // The connector treats `nil` as "no filter wired" (legacy path);
            // we never return nil from production here. A registry without
            // a cached entry yet returns an empty set, which the connector
            // treats as "drop everything" — the roadmap-mandated behaviour
            // before the first successful discovery refresh.
            guard let entry = await registry.cachedEntry() else { return Set<StatusComponentID>() }
            let overrides = await MainActor.run { preferences.statusComponentSubscriptions }
            let subscribed: Set<StatusComponentID> = Set(
                entry.components
                    .filter { component in
                        // Missing override → default ON; explicit `false` → opted out.
                        overrides[component.id.rawValue] ?? true
                    }
                    .map(\.id)
            )
            return subscribed
        }
    }
}
