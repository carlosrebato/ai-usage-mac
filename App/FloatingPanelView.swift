import AIUsageCore
import AIUsageDesignSystem
import AIUsageMacServices
import AppKit
import SwiftUI

struct FloatingPanelView: View {
    @EnvironmentObject private var store: UsageStore
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
            HStack {
                Button {
                    if let onDock {
                        onDock()
                    } else {
                        dismissWindow(id: "floating")
                    }
                } label: {
                    Label(
                        language.text("Dock", "Acoplar"),
                        systemImage: "chevron.left"
                    )
                }
                .buttonStyle(UsagePillButtonStyle())

                Spacer()

                HStack(spacing: 6) {
                    ForEach(0..<3, id: \.self) { _ in
                        Circle()
                            .fill(UsageTheme.mutedText)
                            .frame(width: 5, height: 5)
                    }
                }
            }
            .padding(14)

            Rectangle().fill(UsageTheme.hairline).frame(height: 1)

            UsageFloatingMetrics(
                snapshots: store.snapshots,
                now: now,
                language: language
            )
                .padding(16)

            Spacer(minLength: 0)
        }
        .frame(width: 256, height: 256)
        .usagePanel(cornerRadius: 18)
        .background(FloatingWindowConfigurator())
        .onReceive(timer) { now = $0 }
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
            let squareSize = NSSize(width: 256, height: 256)

            window.styleMask = [.borderless]
            window.backgroundColor = .clear
            window.isOpaque = false
            window.hasShadow = true
            window.isMovableByWindowBackground = true
            window.level = .floating
            window.minSize = squareSize
            window.maxSize = squareSize
            window.setContentSize(squareSize)
        }
    }
}
