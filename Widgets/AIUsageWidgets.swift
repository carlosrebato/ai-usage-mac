import AIUsageCore
import AIUsageDesignSystem
import SwiftUI
import WidgetKit

private struct UsageWidgetEntry: TimelineEntry {
    let date: Date
    let snapshots: [ProviderUsageSnapshot]
}

private struct UsageWidgetProvider: TimelineProvider {
    func placeholder(in context: Context) -> UsageWidgetEntry {
        UsageWidgetEntry(date: .now, snapshots: Self.previewSnapshots)
    }

    func getSnapshot(in context: Context, completion: @escaping (UsageWidgetEntry) -> Void) {
        completion(entry(usePreviewIfEmpty: context.isPreview))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<UsageWidgetEntry>) -> Void) {
        let entry = entry(usePreviewIfEmpty: false)
        let nextRefresh = Calendar.current.date(byAdding: .minute, value: 15, to: entry.date)!
        completion(Timeline(entries: [entry], policy: .after(nextRefresh)))
    }

    private func entry(usePreviewIfEmpty: Bool) -> UsageWidgetEntry {
        let cached = UsageSnapshotCache().load()
        let snapshots = UsageProviderID.allCases
            .filter { ProviderVisibilityPreferences.isVisible($0) }
            .compactMap { cached[$0] }
        return UsageWidgetEntry(
            date: .now,
            snapshots: snapshots.isEmpty && usePreviewIfEmpty ? Self.previewSnapshots : snapshots
        )
    }

    private static let previewSnapshots = [
        ProviderUsageSnapshot(
            id: .claude,
            session: UsageWindow(usedPercent: 38, resetsAt: .now.addingTimeInterval(7_200)),
            weekly: UsageWindow(usedPercent: 54, resetsAt: .now.addingTimeInterval(259_200)),
            observedAt: .now,
            source: .mock,
            message: nil
        ),
        ProviderUsageSnapshot(
            id: .codex,
            session: UsageWindow(usedPercent: 21, resetsAt: .now.addingTimeInterval(10_800)),
            weekly: UsageWindow(usedPercent: 47, resetsAt: .now.addingTimeInterval(345_600)),
            observedAt: .now,
            source: .mock,
            message: nil
        )
    ]
}

private struct UsageWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: UsageWidgetEntry
    private var language: AppLanguage { .current }

    var body: some View {
        Group {
            if entry.snapshots.isEmpty {
                emptyState
            } else if family == .systemSmall {
                smallContent
            } else {
                mediumContent
            }
        }
        .containerBackground(for: .widget) {
            UsageTheme.panelGradient
        }
    }

    private var smallContent: some View {
        let snapshot = entry.snapshots.max { ($0.highestPercent ?? 0) < ($1.highestPercent ?? 0) }!
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                ProviderGlyph(provider: snapshot.id, size: 14)
                Text(snapshot.id.displayName)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(UsageTheme.secondaryText)
                Spacer()
                UsageStatusDot(severity: UsageSeverity.forPercent(snapshot.session.usedPercent))
            }
            Spacer()
            Text(percent(snapshot.session.usedPercent))
                .font(.system(size: 38, weight: .bold))
                .tracking(-1.4)
                .monospacedDigit()
                .foregroundStyle(UsageTheme.primaryText)
            UsageMeter(
                value: snapshot.session.normalizedPercent,
                severity: UsageSeverity.forPercent(snapshot.session.usedPercent)
            )
            Text("\(language.text("WK", "SEM")) \(percent(snapshot.weekly.usedPercent))")
                .font(.system(size: 9, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(UsageTheme.mutedText)
        }
    }

    private var mediumContent: some View {
        UsageCompactMetrics(
            snapshots: entry.snapshots,
            now: entry.date,
            language: language
        )
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: "chart.bar.fill")
                .foregroundStyle(UsageTheme.green)
            Text(language.text("Open AI Usage", "Abre AI Usage"))
                .font(.headline)
                .foregroundStyle(UsageTheme.primaryText)
            Text(language.text(
                "The app will update your Claude and Codex limits.",
                "La app actualizará tus límites de Claude y Codex."
            ))
                .font(.caption)
                .foregroundStyle(UsageTheme.mutedText)
        }
    }

    private func percent(_ value: Double?) -> String {
        guard let value else { return "—" }
        return "\(Int(value.rounded()))%"
    }
}

private struct AIUsageWidget: Widget {
    let kind = AIUsageWidgetKind.summary
    private var language: AppLanguage { .current }

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: UsageWidgetProvider()) { entry in
            UsageWidgetView(entry: entry)
        }
        .configurationDisplayName("AI Usage")
        .description(language.text(
            "Your Claude and Codex limits at a glance.",
            "Tus límites de Claude y Codex de un vistazo."
        ))
        .supportedFamilies([.systemSmall, .systemMedium])
        .contentMarginsDisabled()
    }
}

@main
struct AIUsageWidgetBundle: WidgetBundle {
    var body: some Widget {
        AIUsageWidget()
    }
}
