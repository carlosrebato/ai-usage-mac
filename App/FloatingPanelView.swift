import AIUsageCore
import AIUsageDesignSystem
import AIUsageMacServices
import AppKit
import SwiftUI

struct FloatingPanelView: View {
    static let size = NSSize(width: 256, height: 204)

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
        VStack(spacing: 0) {
            UsageFloatingMetrics(
                snapshots: visibleSnapshots,
                now: now,
                language: language
            )
                .padding(16)

            Rectangle().fill(UsageTheme.hairline).frame(height: 1)

            Button {
                if let onDock {
                    onDock()
                } else {
                    dismissWindow(id: "floating")
                }
            } label: {
                Label(
                    language.text("Attach", "Acoplar"),
                    systemImage: "arrow.down.left.and.arrow.up.right"
                )
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(UsagePillButtonStyle())
            .padding(12)
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .usagePanel(cornerRadius: 18)
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
