import AIUsageCore
import Combine
import WidgetKit

enum AssistantSetupMode {
    case onboarding
    case management
}

@MainActor
final class AssistantSetupContext: ObservableObject {
    @Published var mode: AssistantSetupMode = .onboarding
}

@MainActor
final class ProviderSelectionStore: ObservableObject {
    @Published private(set) var activeProviders: Set<UsageProviderID>

    init() {
        ProviderVisibilityPreferences.migrateIfNeeded(
            onboardingCompleted: UserDefaults.standard.bool(
                forKey: AppPreferenceKey.onboardingCompleted
            )
        )
        activeProviders = Set(
            UsageProviderID.allCases.filter {
                ProviderVisibilityPreferences.isVisible($0)
            }
        )
    }

    func isActive(_ provider: UsageProviderID) -> Bool {
        activeProviders.contains(provider)
    }

    func setActive(_ active: Bool, for provider: UsageProviderID) {
        if active {
            activeProviders.insert(provider)
        } else {
            activeProviders.remove(provider)
        }
        ProviderVisibilityPreferences.setVisible(active, for: provider)
        WidgetCenter.shared.reloadAllTimelines()
    }

    var hasActiveProvider: Bool { !activeProviders.isEmpty }

    func filtering(_ snapshots: [ProviderUsageSnapshot]) -> [ProviderUsageSnapshot] {
        snapshots.filter { activeProviders.contains($0.id) }
    }
}

enum AppPreferenceKey {
    static let automaticRefresh = "automaticRefresh"
    static let showPercentageInMenuBar = "showPercentageInMenuBar"
    static let showResetTimesInMenuBar = "showResetTimesInMenuBar"
    static let onboardingCompleted = "onboardingCompleted"
    static let language = AppLanguage.preferenceKey
}
