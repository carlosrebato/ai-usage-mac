import AIUsageCore
import Foundation
import SwiftUI

public struct UsageCompactMetrics: View {
    public let snapshots: [ProviderUsageSnapshot]
    public let now: Date
    public let language: AppLanguage

    public init(
        snapshots: [ProviderUsageSnapshot],
        now: Date,
        language: AppLanguage = .english
    ) {
        self.snapshots = snapshots
        self.now = now
        self.language = language
    }

    public var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(ordered.enumerated()), id: \.element.id) { index, snapshot in
                if index > 0 {
                    Rectangle()
                        .fill(UsageTheme.hairline)
                        .frame(width: 1)
                        .padding(.vertical, 2)
                }
                compactColumn(snapshot)
            }
        }
    }

    private var ordered: [ProviderUsageSnapshot] {
        UsageProviderID.allCases.compactMap { provider in
            snapshots.first { $0.id == provider }
        }
    }

    private func compactColumn(_ snapshot: ProviderUsageSnapshot) -> some View {
        let primary = snapshot.primaryDisplayWindow

        return VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 8) {
                ProviderGlyph(provider: snapshot.id, size: 15)
                Text(snapshot.id.displayName)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(UsageTheme.secondaryText)
                    .lineLimit(1)
            }

            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(percentNumber(primary.usedPercent))
                    .font(.system(size: 46, weight: .bold))
                    .tracking(-1.8)
                    .monospacedDigit()
                    .foregroundStyle(UsageTheme.primaryText)
                if primary.usedPercent != nil {
                    Text("%")
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundStyle(UsageTheme.tertiaryText)
                }
                Text(primaryPeriodLabel(snapshot, language: language))
                    .font(.system(size: 9, weight: .bold))
                    .tracking(1.1)
                    .foregroundStyle(UsageTheme.mutedText)
                    .padding(.leading, 4)
            }

            UsageMeter(
                value: primary.normalizedPercent,
                severity: UsageSeverity.forPercent(primary.usedPercent)
            )

            HStack(spacing: 5) {
                microLabel(language.text("RESETS", "REINICIA"))
                Text(UsageResetFormatter.string(until: primary.resetsAt, relativeTo: now))
                    .foregroundStyle(UsageTheme.metaText)
                if snapshot.session.usedPercent != nil {
                    Text("·").foregroundStyle(UsageTheme.mutedText)
                    microLabel(language.text("WK", "SEM"))
                    Text(percent(snapshot.weekly.usedPercent))
                        .foregroundStyle(weeklyColor(snapshot.weekly.usedPercent))
                }
            }
            .font(.system(size: 9, weight: .semibold))
            .tracking(0.45)
            .monospacedDigit()
            .lineLimit(1)
        }
        .padding(.horizontal, 18)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func microLabel(_ text: String) -> Text {
        Text(text).foregroundStyle(UsageTheme.mutedText)
    }

}

public struct UsageDetailedMetrics: View {
    public let snapshots: [ProviderUsageSnapshot]
    public let now: Date
    public let history: UsageHistory
    public let language: AppLanguage

    public init(
        snapshots: [ProviderUsageSnapshot],
        now: Date,
        history: UsageHistory = UsageHistory(),
        language: AppLanguage = .english
    ) {
        self.snapshots = snapshots
        self.now = now
        self.history = history
        self.language = language
    }

    public var body: some View {
        VStack(spacing: 20) {
            ForEach(Array(ordered.enumerated()), id: \.element.id) { index, snapshot in
                if index > 0 {
                    Rectangle().fill(UsageTheme.hairline).frame(height: 1)
                }
                providerBlock(snapshot)
            }

            UsageTrendFooter(
                history: history,
                now: now,
                language: language,
                providers: Set(ordered.map(\.id))
            )
        }
    }

    private var ordered: [ProviderUsageSnapshot] {
        UsageProviderID.allCases.compactMap { provider in
            snapshots.first { $0.id == provider }
        }
    }

    private func providerBlock(_ snapshot: ProviderUsageSnapshot) -> some View {
        let primary = snapshot.primaryDisplayWindow

        return VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 10) {
                ProviderGlyph(provider: snapshot.id, size: 16)
                Text(snapshot.id.displayName)
                    .font(.system(size: 16.5, weight: .semibold))
                    .foregroundStyle(UsageTheme.primaryText)
                Spacer()
                UsageStatusDot(severity: UsageSeverity.forPercent(primary.usedPercent), size: 8)
            }

            HStack(alignment: .bottom, spacing: 16) {
                VStack(alignment: .leading, spacing: 9) {
                    HStack(alignment: .firstTextBaseline, spacing: 2) {
                        Text(percentNumber(primary.usedPercent))
                            .font(.system(size: 46, weight: .bold))
                            .tracking(-1.8)
                            .monospacedDigit()
                            .foregroundStyle(UsageTheme.primaryText)
                        if primary.usedPercent != nil {
                            Text("%")
                                .font(.system(size: 19, weight: .semibold))
                                .foregroundStyle(UsageTheme.tertiaryText)
                        }
                        Text(primaryPeriodLabel(snapshot, language: language))
                            .font(.system(size: 9, weight: .semibold))
                            .tracking(1.15)
                            .foregroundStyle(UsageTheme.mutedText)
                            .padding(.leading, 4)
                    }
                    UsageMeter(
                        value: primary.normalizedPercent,
                        severity: UsageSeverity.forPercent(primary.usedPercent)
                    )
                }

                if snapshot.session.usedPercent != nil {
                    VStack(alignment: .leading, spacing: 9) {
                        HStack(alignment: .firstTextBaseline, spacing: 5) {
                            Text(percentNumber(snapshot.weekly.usedPercent))
                                .font(.system(size: 26, weight: .bold))
                                .tracking(-0.7)
                                .monospacedDigit()
                                .foregroundStyle(weeklyColor(snapshot.weekly.usedPercent))
                                .fixedSize()
                            if snapshot.weekly.usedPercent != nil {
                                Text("%")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(UsageTheme.tertiaryText)
                            }
                            Text(language.text("WK", "SEM"))
                                .font(.system(size: 9, weight: .semibold))
                                .tracking(1.1)
                                .foregroundStyle(UsageTheme.mutedText)
                        }
                        .fixedSize(horizontal: true, vertical: false)
                        UsageMeter(value: snapshot.weekly.normalizedPercent, severity: UsageSeverity.forPercent(snapshot.weekly.usedPercent))
                    }
                    .frame(width: 78)
                }
            }

            HStack(spacing: 14) {
                metric(
                    label: language.text("RESETS", "REINICIA"),
                    value: UsageResetFormatter.string(until: primary.resetsAt, relativeTo: now)
                )
                if let totals = snapshot.weeklyTotals {
                    metric(
                        label: language.text("EST. COST", "COSTE EST."),
                        value: equivalentCost(totals, language: language)
                    )
                        .help(equivalentCostHelp(totals, language: language))
                    metric(label: "TOKENS", value: compactTokens(totals.totalTokens))
                        .help(tokenBreakdown(totals, language: language))
                }
                Spacer()
                if snapshot.source == .cached {
                    Text(language.text("CACHED", "CACHÉ"))
                        .font(.system(size: 9, weight: .semibold))
                        .tracking(1.1)
                        .foregroundStyle(UsageTheme.amber)
                } else if snapshot.source == .unavailable {
                    Text(language.text("OFFLINE", "SIN CONEXIÓN"))
                        .font(.system(size: 9, weight: .semibold))
                        .tracking(1.1)
                        .foregroundStyle(UsageTheme.red)
                }
            }
        }
    }

    private func metric(label: String, value: String) -> some View {
        HStack(spacing: 5) {
            Text(label)
                .font(.system(size: 9, weight: .semibold))
                .tracking(1.1)
                .foregroundStyle(UsageTheme.mutedText)
            Text(value)
                .font(.system(size: 12, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(UsageTheme.metaText)
        }
        .lineLimit(1)
    }

}

public struct UsageTrendFooter: View {
    public let history: UsageHistory
    public let now: Date
    public let language: AppLanguage
    public let providers: Set<UsageProviderID>

    public init(
        history: UsageHistory,
        now: Date,
        language: AppLanguage = .english,
        providers: Set<UsageProviderID> = Set(UsageProviderID.allCases)
    ) {
        self.history = history
        self.now = now
        self.language = language
        self.providers = providers
    }

    public var body: some View {
        VStack(spacing: 14) {
            HStack {
                Text(language.text("USAGE · LAST 7 DAYS", "USO · ÚLTIMOS 7 DÍAS"))
                    .font(.system(size: 9, weight: .semibold))
                    .tracking(1.15)
                    .foregroundStyle(UsageTheme.mutedText)

                Spacer()

                if providers.contains(.claude) {
                    legend("Claude", color: UsageTheme.claude)
                }
                if providers.contains(.codex) {
                    legend("Codex", color: UsageTheme.codex)
                }
            }

            UsageTrendChart(
                days: history.lastSevenDays(relativeTo: now),
                language: language,
                providers: providers
            )
            .frame(height: 100)

            streak
                .padding(.top, 6)
        }
        .padding(.top, 16)
        .overlay(alignment: .top) {
            Rectangle().fill(UsageTheme.hairline).frame(height: 1)
        }
    }

    private func legend(_ title: String, color: Color) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(UsageTheme.tertiaryText)
        }
    }

    private var streak: some View {
        let count = history.currentStreak(relativeTo: now)
        let visibleCount = min(max(count, 1), 15)

        return VStack(spacing: 11) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(String(count))
                    .font(.system(size: 28, weight: .bold))
                    .tracking(-0.8)
                    .monospacedDigit()
                    .foregroundStyle(UsageTheme.green)
                Text(language.text("DAY STREAK", "RACHA DIARIA"))
                    .font(.system(size: 9, weight: .semibold))
                    .tracking(1.15)
                    .foregroundStyle(Color(red: 90 / 255, green: 143 / 255, blue: 119 / 255))
            }

            HStack(spacing: 7) {
                ForEach(0..<visibleCount, id: \.self) { index in
                    let progress = visibleCount == 1
                        ? 1
                        : Double(index) / Double(visibleCount - 1)
                    Circle()
                        .fill(streakColor(progress))
                        .frame(
                            width: index == visibleCount - 1 ? 8 : 7,
                            height: index == visibleCount - 1 ? 8 : 7
                        )
                        .shadow(
                            color: index == visibleCount - 1
                                ? UsageTheme.green.opacity(0.9)
                                : .clear,
                            radius: 10
                        )
                }
            }
        }
    }

    private func streakColor(_ progress: Double) -> Color {
        let start = (r: 18.0, g: 59.0, b: 48.0)
        let end = (r: 62.0, g: 207.0, b: 142.0)
        return Color(
            red: (start.r + (end.r - start.r) * progress) / 255,
            green: (start.g + (end.g - start.g) * progress) / 255,
            blue: (start.b + (end.b - start.b) * progress) / 255
        )
    }
}

private struct UsageTrendChart: View {
    let days: [UsageHistoryDay]
    let language: AppLanguage
    let providers: Set<UsageProviderID>

    var body: some View {
        Canvas { context, size in
            let left: CGFloat = 10
            let right = max(left, size.width - 12)
            let top: CGFloat = 16
            let baseline: CGFloat = 78
            let plotHeight = baseline - top
            let step = (right - left) / CGFloat(max(days.count - 1, 1))
            let xPositions = days.indices.map { left + CGFloat($0) * step }
            let scaleMaximum = max(
                days.compactMap(\.claudeTokens).max() ?? 0,
                days.compactMap(\.codexTokens).max() ?? 0
            )
            let calloutProvider = UsageProviderID.allCases
                .filter(providers.contains)
                .filter { hasSeries(for: $0) && currentValue(for: $0) > 0 }
                .max {
                    normalizedCurrentValue(for: $0, tokenScaleMaximum: scaleMaximum)
                        < normalizedCurrentValue(for: $1, tokenScaleMaximum: scaleMaximum)
                }

            drawDottedGuide(in: &context, from: left, to: right, y: top, opacity: 0.13)
            drawDottedGuide(
                in: &context,
                from: left,
                to: right,
                y: top + plotHeight / 2,
                opacity: 0.09
            )

            if providers.contains(.claude) {
                drawSeries(
                    provider: .claude,
                    color: UsageTheme.claude,
                    areaOpacity: 0.22,
                    xPositions: xPositions,
                    baseline: baseline,
                    plotHeight: plotHeight,
                    scaleMaximum: scaleMaximum,
                    showsCallout: calloutProvider == .claude,
                    context: &context
                )
            }
            if providers.contains(.codex) {
                drawSeries(
                    provider: .codex,
                    color: UsageTheme.codex,
                    areaOpacity: 0.18,
                    xPositions: xPositions,
                    baseline: baseline,
                    plotHeight: plotHeight,
                    scaleMaximum: scaleMaximum,
                    showsCallout: calloutProvider == .codex,
                    context: &context
                )
            }

            for index in days.indices {
                let dotRect = CGRect(
                    x: xPositions[index] - 2,
                    y: baseline - 2,
                    width: 4,
                    height: 4
                )
                context.fill(
                    Path(ellipseIn: dotRect),
                    with: .color(Color.white.opacity(0.2))
                )

                let label = weekdayInitial(days[index].date)
                context.draw(
                    Text(label)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(UsageTheme.mutedText),
                    at: CGPoint(x: xPositions[index], y: 93),
                    anchor: .center
                )
            }
        }
    }

    private func drawDottedGuide(
        in context: inout GraphicsContext,
        from start: CGFloat,
        to end: CGFloat,
        y: CGFloat,
        opacity: Double
    ) {
        var x = start
        while x <= end {
            context.fill(
                Path(ellipseIn: CGRect(x: x - 1.1, y: y - 1.1, width: 2.2, height: 2.2)),
                with: .color(Color.white.opacity(opacity))
            )
            x += 8
        }
    }

    private func drawSeries(
        provider: UsageProviderID,
        color: Color,
        areaOpacity: Double,
        xPositions: [CGFloat],
        baseline: CGFloat,
        plotHeight: CGFloat,
        scaleMaximum: Int,
        showsCallout: Bool,
        context: inout GraphicsContext
    ) {
        guard hasSeries(for: provider) else { return }

        let points = days.indices.map { index -> CGPoint in
            let normalized = normalizedValue(
                for: days[index],
                provider: provider,
                tokenScaleMaximum: scaleMaximum
            )
            return CGPoint(x: xPositions[index], y: baseline - plotHeight * normalized)
        }

        if points.count > 1 {
            var line = Path()
            line.move(to: points[0])
            for point in points.dropFirst() { line.addLine(to: point) }

            var area = line
            area.addLine(to: CGPoint(x: points.last!.x, y: baseline))
            area.addLine(to: CGPoint(x: points[0].x, y: baseline))
            area.closeSubpath()
            context.fill(
                area,
                with: .linearGradient(
                    Gradient(colors: [color.opacity(areaOpacity), color.opacity(0)]),
                    startPoint: CGPoint(x: 0, y: 16),
                    endPoint: CGPoint(x: 0, y: baseline)
                )
            )
            context.stroke(
                line,
                with: .color(provider == .codex ? color.opacity(0.85) : color),
                style: StrokeStyle(lineWidth: 2.25, lineCap: .round, lineJoin: .round)
            )
        }

        for (index, point) in points.enumerated() {
            let value = rawValue(for: days[index], provider: provider)
            let isToday = index == days.count - 1 && value > 0
            if isToday {
                let ringRadius: CGFloat = provider == .claude ? 7.5 : 6.8
                context.stroke(
                    Path(ellipseIn: CGRect(
                        x: point.x - ringRadius,
                        y: point.y - ringRadius,
                        width: ringRadius * 2,
                        height: ringRadius * 2
                    )),
                    with: .color(color.opacity(0.35)),
                    lineWidth: 2
                )
            }
            let radius: CGFloat = isToday ? (provider == .claude ? 4 : 3.6) : 2.3
            context.fill(
                Path(ellipseIn: CGRect(
                    x: point.x - radius,
                    y: point.y - radius,
                    width: radius * 2,
                    height: radius * 2
                )),
                with: .color(color)
            )

            if showsCallout, isToday {
                drawCallout(
                    text: calloutText(for: days[index], provider: provider),
                    point: point,
                    color: color,
                    context: &context
                )
            }
        }
    }

    private func hasTokenSeries(for provider: UsageProviderID) -> Bool {
        days.contains { ($0.tokens(for: provider) ?? 0) > 0 }
    }

    private func hasSeries(for provider: UsageProviderID) -> Bool {
        hasTokenSeries(for: provider)
            || days.contains { ($0.percent(for: provider) ?? 0) > 0 }
    }

    private func rawValue(for day: UsageHistoryDay, provider: UsageProviderID) -> Double {
        if hasTokenSeries(for: provider) {
            return Double(max(day.tokens(for: provider) ?? 0, 0))
        }
        return max(day.percent(for: provider) ?? 0, 0)
    }

    private func normalizedValue(
        for day: UsageHistoryDay,
        provider: UsageProviderID,
        tokenScaleMaximum: Int
    ) -> Double {
        if hasTokenSeries(for: provider) {
            guard tokenScaleMaximum > 0 else { return 0 }
            return rawValue(for: day, provider: provider) / Double(tokenScaleMaximum)
        }
        return min(rawValue(for: day, provider: provider) / 100, 1)
    }

    private func currentValue(for provider: UsageProviderID) -> Double {
        guard let last = days.last else { return 0 }
        return rawValue(for: last, provider: provider)
    }

    private func normalizedCurrentValue(
        for provider: UsageProviderID,
        tokenScaleMaximum: Int
    ) -> Double {
        guard let last = days.last else { return 0 }
        return normalizedValue(
            for: last,
            provider: provider,
            tokenScaleMaximum: tokenScaleMaximum
        )
    }

    private func calloutText(for day: UsageHistoryDay, provider: UsageProviderID) -> String {
        if hasTokenSeries(for: provider) {
            return compactTokens(day.tokens(for: provider) ?? 0)
        }
        return "\(Int((day.percent(for: provider) ?? 0).rounded()))%"
    }

    private func drawCallout(
        text: String,
        point: CGPoint,
        color: Color,
        context: inout GraphicsContext
    ) {
        let width = max(44, CGFloat(text.count) * 7 + 14)
        let rect = CGRect(x: point.x - width + 6, y: max(1, point.y - 27), width: width, height: 17)
        var pill = Path()
        pill.addRoundedRect(in: rect, cornerSize: CGSize(width: 8.5, height: 8.5))
        context.fill(pill, with: .color(color.opacity(0.1)))
        context.stroke(pill, with: .color(color.opacity(0.32)), lineWidth: 1)
        context.draw(
            Text(text)
                .font(.system(size: 10.5, weight: .bold))
                .foregroundStyle(color),
            at: CGPoint(x: rect.midX, y: rect.midY),
            anchor: .center
        )
    }

    private func weekdayInitial(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = language.locale
        formatter.dateFormat = "EEEEE"
        return String(formatter.string(from: date).prefix(1)).uppercased(with: language.locale)
    }
}

public struct UsageFloatingMetrics: View {
    public let snapshots: [ProviderUsageSnapshot]
    public let now: Date
    public let language: AppLanguage

    public init(
        snapshots: [ProviderUsageSnapshot],
        now: Date,
        language: AppLanguage = .english
    ) {
        self.snapshots = snapshots
        self.now = now
        self.language = language
    }

    public var body: some View {
        VStack(spacing: 15) {
            ForEach(ordered) { snapshot in
                let primary = snapshot.primaryDisplayWindow

                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 8) {
                        ProviderGlyph(provider: snapshot.id, size: 13)
                        Text(snapshot.id == .claude ? "Claude" : "Codex")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(UsageTheme.secondaryText)
                        Spacer()
                        Text(percent(primary.usedPercent))
                            .font(.system(size: 14, weight: .bold))
                            .monospacedDigit()
                            .foregroundStyle(UsageTheme.primaryText)
                    }
                    UsageMeter(
                        value: primary.normalizedPercent,
                        severity: UsageSeverity.forPercent(primary.usedPercent),
                        height: 5
                    )
                    Text(
                        "\(language.text("RESETS", "REINICIA")) \(UsageResetFormatter.string(until: primary.resetsAt, relativeTo: now))"
                    )
                        .font(.system(size: 9, weight: .semibold))
                        .tracking(0.7)
                        .monospacedDigit()
                        .foregroundStyle(UsageTheme.mutedText)
                }
            }
        }
    }

    private var ordered: [ProviderUsageSnapshot] {
        UsageProviderID.allCases.compactMap { provider in snapshots.first { $0.id == provider } }
    }

}

public struct UsageMeter: View {
    public let value: Double
    public let severity: UsageSeverity
    public let height: CGFloat

    public init(value: Double, severity: UsageSeverity, height: CGFloat = 6) {
        self.value = value
        self.severity = severity
        self.height = height
    }

    public var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(UsageTheme.track)
                Capsule()
                    .fill(UsageTheme.severity(severity))
                    .frame(width: geometry.size.width * min(max(value, 0), 100) / 100)
            }
        }
        .frame(height: height)
        .animation(.timingCurve(0.4, 0, 0.2, 1, duration: 0.5), value: value)
    }
}

public struct UsageStatusDot: View {
    public let severity: UsageSeverity
    public let size: CGFloat

    public init(severity: UsageSeverity, size: CGFloat = 7) {
        self.severity = severity
        self.size = size
    }

    public var body: some View {
        TimelineView(.animation(minimumInterval: severity == .critical ? 0.05 : 1, paused: severity != .critical)) { timeline in
            let pulse = (sin(timeline.date.timeIntervalSinceReferenceDate * .pi * 2) + 1) / 2
            Circle()
                .fill(UsageTheme.severity(severity))
                .frame(width: size, height: size)
                .opacity(severity == .critical ? 0.45 + pulse * 0.55 : 1)
                .shadow(color: UsageTheme.severity(severity).opacity(0.65), radius: severity == .critical ? pulse * 6 : 4)
        }
    }
}

public struct ProviderGlyph: View {
    public let provider: UsageProviderID
    public let size: CGFloat
    public let color: Color

    public init(
        provider: UsageProviderID,
        size: CGFloat,
        color: Color = UsageTheme.secondaryText
    ) {
        self.provider = provider
        self.size = size
        self.color = color
    }

    public var body: some View {
        Image(provider == .claude ? "ClaudeLogo" : "CodexLogo", bundle: .module)
            .resizable()
            .renderingMode(.template)
            .scaledToFit()
            .foregroundStyle(color)
            .frame(width: size, height: size)
            .accessibilityLabel(provider.displayName)
    }
}

public struct UsagePillButtonStyle: ButtonStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .lineLimit(1)
            .minimumScaleFactor(0.85)
            .allowsTightening(true)
            .foregroundStyle(UsageTheme.primaryText.opacity(configuration.isPressed ? 0.7 : 0.88))
            .padding(.horizontal, 10)
            .frame(minHeight: 32)
            .background(
                configuration.isPressed ? Color.white.opacity(0.08) : UsageTheme.buttonFill,
                in: Capsule()
            )
            .overlay {
                Capsule().stroke(
                    configuration.isPressed ? Color.white.opacity(0.14) : UsageTheme.buttonBorder,
                    lineWidth: 1
                )
            }
    }
}

private func percentNumber(_ value: Double?) -> String {
    guard let value else { return "—" }
    return String(Int(value.rounded()))
}

private func percent(_ value: Double?) -> String {
    guard let value else { return "—" }
    return "\(Int(value.rounded()))%"
}

private func weeklyColor(_ value: Double?) -> Color {
    guard let value else { return UsageTheme.mutedText }
    if value >= 85 { return UsageTheme.red }
    if value >= 70 { return UsageTheme.amber }
    return UsageTheme.weeklyText
}

private func primaryPeriodLabel(
    _ snapshot: ProviderUsageSnapshot,
    language: AppLanguage
) -> String {
    if snapshot.id == .codex,
       snapshot.session.usedPercent == nil,
       snapshot.weekly.usedPercent != nil {
        return language.text("WEEK", "SEMANA")
    }
    return language.text("SESSION", "SESIÓN")
}

private func compactTokens(_ value: Int) -> String {
    switch value {
    case 1_000_000_000...:
        return compactNumber(Double(value) / 1_000_000_000, suffix: "B")
    case 1_000_000...:
        return compactNumber(Double(value) / 1_000_000, suffix: "M")
    case 1_000...:
        return compactNumber(Double(value) / 1_000, suffix: "K")
    default:
        return String(value)
    }
}

private func compactNumber(_ value: Double, suffix: String) -> String {
    let digits = value >= 100 ? 0 : 1
    return value.formatted(
        .number
            .precision(.fractionLength(0...digits))
            .locale(Locale(identifier: "en_US"))
    ) + suffix
}

private func equivalentCost(
    _ totals: WeeklyUsageTotals,
    language: AppLanguage
) -> String {
    guard let cost = totals.equivalentCostUSD else {
        return totals.hasUnpricedModels ? language.text("N/A", "N/D") : "—"
    }
    let formatted = cost.formatted(
        .currency(code: "USD")
            .precision(.fractionLength(cost >= 100 ? 0 : 2))
            .locale(Locale(identifier: "en_US"))
    )
    return "~\(formatted)"
}

private func equivalentCostHelp(
    _ totals: WeeklyUsageTotals,
    language: AppLanguage
) -> String {
    if totals.equivalentCostUSD == nil, totals.hasUnpricedModels {
        return language.text(
            "There is not enough public pricing or model detail to estimate this period. This is not an actual charge.",
            "No hay desglose o tarifa pública suficiente para estimar este periodo. No representa un cargo real."
        )
    }
    if totals.hasUnpricedModels {
        return language.text(
            "Minimum estimate using public API pricing; some usage has no public price or model breakdown. This is not an actual charge.",
            "Estimación mínima con tarifas API públicas; parte del uso no tiene tarifa o desglose disponible. No representa un cargo real."
        )
    }
    return language.text(
        "Estimated equivalent cost using public API pricing; this is not an actual charge.",
        "Coste equivalente estimado con las tarifas API públicas; no representa un cargo real."
    )
}

private func tokenBreakdown(
    _ totals: WeeklyUsageTotals,
    language: AppLanguage
) -> String {
    var lines = [
        "\(language.text("Weekly total", "Total semanal")): \(compactTokens(totals.totalTokens))",
        "\(language.text("Input", "Entrada")): \(compactTokens(totals.inputTokens))",
        "\(language.text("Cached input", "Entrada en caché")): \(compactTokens(totals.cachedInputTokens))",
        "\(language.text("Cache writes", "Escritura de caché")): \(compactTokens(totals.cacheWriteTokens))",
        "\(language.text("Output", "Salida")): \(compactTokens(totals.outputTokens))",
        "\(language.text("Reasoning (included in output)", "Razonamiento (incluido en salida)")): \(compactTokens(totals.reasoningTokens))"
    ]
    if let unclassified = totals.unclassifiedTokens, unclassified > 0 {
        lines.append("\(language.text("Unclassified", "Sin desglose")): \(compactTokens(unclassified))")
    }
    return lines.joined(separator: "\n")
}
