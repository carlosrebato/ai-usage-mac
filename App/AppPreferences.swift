import AIUsageCore
import Combine

enum AssistantSetupMode {
    case onboarding
    case management
}

@MainActor
final class AssistantSetupContext: ObservableObject {
    @Published var mode: AssistantSetupMode = .onboarding
}

enum AppPreferenceKey {
    static let automaticRefresh = "automaticRefresh"
    static let showPercentageInMenuBar = "showPercentageInMenuBar"
    static let showResetTimesInMenuBar = "showResetTimesInMenuBar"
    static let onboardingCompleted = "onboardingCompleted"
    static let language = AppLanguage.preferenceKey
}
