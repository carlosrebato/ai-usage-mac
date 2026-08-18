import Foundation

public enum ProviderVisibilityPreferences {
    public static let migrationKey = "providerVisibilityMigrated"

    // UserDefaults is documented for concurrent use; Swift has not annotated it Sendable.
    nonisolated(unsafe) public static let store =
        UserDefaults(suiteName: AIUsageAppGroup.identifier) ?? .standard

    public static func key(for provider: UsageProviderID) -> String {
        "providerVisible.\(provider.rawValue)"
    }

    public static func isVisible(
        _ provider: UsageProviderID,
        in defaults: UserDefaults = store
    ) -> Bool {
        defaults.object(forKey: key(for: provider)) as? Bool ?? false
    }

    public static func setVisible(
        _ visible: Bool,
        for provider: UsageProviderID,
        in defaults: UserDefaults = store
    ) {
        defaults.set(visible, forKey: key(for: provider))
    }

    /// Existing installations keep their current two-provider presentation.
    /// Fresh installations start with no provider selected; onboarding enables
    /// each provider only after the user explicitly chooses it.
    public static func migrateIfNeeded(
        onboardingCompleted: Bool,
        in defaults: UserDefaults = store
    ) {
        guard defaults.object(forKey: migrationKey) == nil else { return }
        for provider in UsageProviderID.allCases
        where defaults.object(forKey: key(for: provider)) == nil {
            defaults.set(onboardingCompleted, forKey: key(for: provider))
        }
        defaults.set(true, forKey: migrationKey)
    }
}
