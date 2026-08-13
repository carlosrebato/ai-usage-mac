import AIUsageCore
import SwiftUI

public struct ProviderCard: View {
    public let snapshot: ProviderUsageSnapshot
    public let now: Date
    public let language: AppLanguage

    public init(
        snapshot: ProviderUsageSnapshot,
        now: Date,
        language: AppLanguage = .english
    ) {
        self.snapshot = snapshot
        self.now = now
        self.language = language
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            header

            HStack(alignment: .bottom, spacing: 22) {
                metric(title: language.text("SESSION", "SESIÓN"), window: snapshot.session, prominent: true)
                metric(title: language.text("WEEK", "SEMANA"), window: snapshot.weekly, prominent: false)
                    .frame(width: 116)
            }

            Divider().overlay(UsageTheme.hairline)

            HStack(spacing: 7) {
                Image(systemName: "arrow.clockwise")
                Text(resetSummary)
                Spacer()
                Text(freshness)
            }
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(UsageTheme.mutedText)
        }
        .padding(24)
        .frame(maxWidth: .infinity, minHeight: 262, alignment: .topLeading)
        .usagePanel()
    }

    private var header: some View {
        HStack(spacing: 11) {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(UsageTheme.provider(snapshot.id).opacity(0.12))
                Image(systemName: snapshot.id.symbolName)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(UsageTheme.provider(snapshot.id))
            }
            .frame(width: 34, height: 34)

            VStack(alignment: .leading, spacing: 2) {
                Text(snapshot.id.displayName)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(UsageTheme.primaryText)
                Text(snapshot.message ?? language.text("Connected", "Conectado"))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(UsageTheme.mutedText)
            }

            Spacer()

            if snapshot.source == .mock || snapshot.source == .cached {
                Text(snapshot.source == .mock ? "DEMO" : language.text("CACHED", "CACHÉ"))
                    .font(.system(size: 9, weight: .bold))
                    .tracking(1.1)
                    .foregroundStyle(snapshot.source == .mock ? UsageTheme.mock : UsageTheme.amber)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background((snapshot.source == .mock ? UsageTheme.mock : UsageTheme.amber).opacity(0.09), in: RoundedRectangle(cornerRadius: 6))
                    .overlay {
                        RoundedRectangle(cornerRadius: 6)
                            .stroke((snapshot.source == .mock ? UsageTheme.mock : UsageTheme.amber).opacity(0.25), lineWidth: 1)
                    }
            }

            Circle()
                .fill(UsageTheme.severity(snapshot.severity))
                .frame(width: 8, height: 8)
                .shadow(color: UsageTheme.severity(snapshot.severity).opacity(0.65), radius: 5)
        }
    }

    private func metric(title: String, window: UsageWindow, prominent: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(percentText(window.usedPercent))
                    .font(.system(size: prominent ? 46 : 28, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(UsageTheme.primaryText)
                if window.usedPercent != nil {
                    Text("%")
                        .font(.system(size: prominent ? 18 : 13, weight: .semibold))
                        .foregroundStyle(UsageTheme.tertiaryText)
                }
                Spacer(minLength: 0)
            }

            UsageProgressBar(value: window.normalizedPercent, severity: UsageSeverity.forPercent(window.usedPercent))

            Text(title)
                .font(.system(size: 10, weight: .bold))
                .tracking(1.2)
                .foregroundStyle(UsageTheme.mutedText)
        }
    }

    private func percentText(_ value: Double?) -> String {
        guard let value else { return "—" }
        return String(Int(value.rounded()))
    }

    private var resetSummary: String {
        let reset: Date
        let label: String
        if let sessionReset = snapshot.session.resetsAt {
            reset = sessionReset
            label = language.text("Session", "Sesión")
        } else if let weeklyReset = snapshot.weekly.resetsAt {
            reset = weeklyReset
            label = language.text("Week", "Semana")
        } else {
            return language.text("Reset unknown", "Reinicio desconocido")
        }
        let seconds = max(0, reset.timeIntervalSince(now))
        let hours = Int(seconds / 3600)
        let minutes = Int(seconds.truncatingRemainder(dividingBy: 3600) / 60)
        return hours > 0
            ? language.text(
                "\(label) resets in \(hours)h \(minutes)m",
                "\(label) reinicia en \(hours) h \(minutes) min"
            )
            : language.text(
                "\(label) resets in \(minutes)m",
                "\(label) reinicia en \(minutes) min"
            )
    }

    private var freshness: String {
        snapshot.isStale(at: now)
            ? language.text("Stale data", "Datos antiguos")
            : language.text("Now", "Ahora")
    }
}

private struct UsageProgressBar: View {
    let value: Double
    let severity: UsageSeverity

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(UsageTheme.track)
                Capsule()
                    .fill(UsageTheme.severity(severity))
                    .frame(width: geometry.size.width * value / 100)
            }
        }
        .frame(height: 5)
        .animation(.easeOut(duration: 0.45), value: value)
    }
}
