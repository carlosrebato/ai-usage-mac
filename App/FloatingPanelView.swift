import AIUsageCore
import AIUsageDesignSystem
import AIUsageMacServices
import AppKit
import SwiftUI

struct FloatingPanelView: View {
    static let size = NSSize(width: 256, height: 166)

    @EnvironmentObject private var store: UsageStore
    @EnvironmentObject private var providerSelection: ProviderSelectionStore
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var now = Date.now
    @AppStorage(AppPreferenceKey.language) private var language: AppLanguage = .english
    private let onDock: (() -> Void)?

    private let timer = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    init(onDock: (() -> Void)? = nil) {
        self.onDock = onDock
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            UsageFloatingMetrics(
                snapshots: visibleSnapshots,
                now: now,
                language: language
            )
            .padding(.horizontal, 16)
            .padding(.top, 34)
            .padding(.bottom, 14)

            Button {
                if let onDock {
                    onDock()
                } else {
                    dismissWindow(id: "floating")
                }
            } label: {
                Image(systemName: "arrow.down.right.and.arrow.up.left")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(UsageTheme.secondaryText)
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.top, 7)
            .padding(.trailing, 8)
            .help(language.text("Attach", "Acoplar"))
            .accessibilityLabel(language.text("Attach", "Acoplar"))
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .background(UsageTheme.panelGradient)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(UsageTheme.hairline, lineWidth: 1)
        }
        .background(FloatingWindowConfigurator())
        .onReceive(timer) { now = $0 }
    }

    private var visibleSnapshots: [ProviderUsageSnapshot] {
        providerSelection.filtering(store.snapshots)
    }
}

private struct FloatingWindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        configureWindow(for: view)
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        configureWindow(for: view)
    }

    private func configureWindow(for view: NSView) {
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            let panelSize = FloatingPanelView.size

            window.styleMask = [.borderless]
            window.backgroundColor = .clear
            window.isOpaque = false
            window.hasShadow = true
            window.isMovableByWindowBackground = true
            window.level = .floating
            window.minSize = panelSize
            window.maxSize = panelSize
            window.setContentSize(panelSize)
        }
    }
}
