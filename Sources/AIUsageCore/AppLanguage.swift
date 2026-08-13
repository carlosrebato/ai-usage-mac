import Foundation

public enum AppLanguage: String, CaseIterable, Codable, Identifiable, Sendable {
    case english = "en"
    case spanish = "es"

    public static let preferenceKey = "appLanguage"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .english: "English"
        case .spanish: "Español"
        }
    }

    public var locale: Locale {
        Locale(identifier: rawValue)
    }

    public func text(_ english: String, _ spanish: String) -> String {
        self == .english ? english : spanish
    }

    public static var current: AppLanguage {
        let standardValue = UserDefaults.standard.string(forKey: preferenceKey)
        let sharedValue = UserDefaults(
            suiteName: AIUsageAppGroup.identifier
        )?.string(forKey: preferenceKey)
        return AppLanguage(rawValue: standardValue ?? sharedValue ?? "") ?? .english
    }

    public func persistForExtensions() {
        UserDefaults.standard.set(rawValue, forKey: Self.preferenceKey)
        UserDefaults(suiteName: AIUsageAppGroup.identifier)?
            .set(rawValue, forKey: Self.preferenceKey)
    }
}
