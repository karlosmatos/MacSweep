import AppKit
import SwiftUI

/// Native, quiet look: system materials and text colors, one green accent, no gradients or glows.
/// Corner radii: containers 12, controls 8, small chips 6.
enum Theme {
    static let accent = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(red: 0.247, green: 0.761, blue: 0.557, alpha: 1)
            : NSColor(red: 0.078, green: 0.502, blue: 0.369, alpha: 1)
    })
    static let warn = Color(nsColor: .systemOrange)
    static let danger = Color(nsColor: .systemRed)
    static let fill = Color.primary.opacity(0.06)
    static let fillStrong = Color.primary.opacity(0.1)
    static let hairline = Color(nsColor: .separatorColor)
    static let neutral = Color.primary.opacity(0.32)

    static func number(_ size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight).monospacedDigit()
    }
}

extension View {
    /// Hairline-bordered container.
    func panel(radius: CGFloat = 12, filled: Bool = false) -> some View {
        background(filled ? Theme.fill : .clear, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Theme.hairline))
    }
}

/// Tactile press for custom buttons.
struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .contentShape(Rectangle())
            .opacity(configuration.isPressed ? 0.7 : 1)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// Full-width solid accent call to action.
struct PrimaryButtonStyle: ButtonStyle {
    var tint: Color = Theme.accent
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorScheme) private var scheme

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(isEnabled ? (scheme == .dark && tint == Theme.accent ? Color.black.opacity(0.85) : .white) : .secondary)
            .frame(maxWidth: .infinity, minHeight: 36)
            .background(isEnabled ? AnyShapeStyle(tint) : AnyShapeStyle(Theme.fill),
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// Small bordered button for secondary actions.
struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(Theme.fill, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Theme.hairline))
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

/// Text-only destructive action that appears on row hover.
struct QuitButton: View {
    let title: String
    let action: () -> Void

    init(_ title: String = "Ukončit", action: @escaping () -> Void) {
        self.title = title
        self.action = action
    }

    var body: some View {
        Button(title, action: action)
            .buttonStyle(PressableStyle())
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Theme.danger)
    }
}

/// Square icon button for toolbars.
struct IconButton: View {
    let icon: String
    let help: String
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 28, height: 28)
                .background(hovered ? Theme.fill : .clear, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(PressableStyle())
        .foregroundStyle(.secondary)
        .opacity(isEnabled ? 1 : 0.35)
        .help(help)
        .accessibilityLabel(help)
        .onHover { hovered = $0 }
    }
}

/// Page header used in the main window.
struct PageHeader<Trailing: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 20, weight: .semibold))
                Text(subtitle).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            trailing
        }
    }
}

extension PageHeader where Trailing == EmptyView {
    init(title: String, subtitle: String) {
        self.init(title: title, subtitle: subtitle) { EmptyView() }
    }
}

/// Neutral rounded square with an app's real icon, or its initial as a fallback.
struct AppIcon: View {
    let path: String?
    let name: String
    var size: CGFloat = 22

    var body: some View {
        if let path, FileManager.default.fileExists(atPath: path) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: path)).resizable().frame(width: size, height: size)
        } else {
            Text(name.prefix(1).uppercased())
                .font(.system(size: size * 0.45, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: size, height: size)
                .background(Theme.fill, in: RoundedRectangle(cornerRadius: size * 0.25, style: .continuous))
        }
    }
}

/// Sizes the menu bar window to its content and keeps the top edge right under the menu bar.
/// MenuBarExtra grows its window but never shrinks it, and re-positions it on every resize,
/// so without this the popover drifts down after a section collapses.
struct TopPinnedWindow: NSViewRepresentable {
    let height: CGFloat

    func makeNSView(context: Context) -> PinView { PinView() }
    func updateNSView(_ view: PinView, context: Context) { view.height = height }

    final class PinView: NSView {
        var height: CGFloat = 0 { didSet { if height != oldValue { pin() } } }
        private var observers: [NSObjectProtocol] = []

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            guard let window else { return }
            let names: [Notification.Name] = [NSWindow.didResizeNotification, NSWindow.didMoveNotification, NSWindow.didBecomeKeyNotification]
            observers = names.map { name in
                NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.pin() }
                }
            }
            pin()
        }

        private func pin() {
            guard let window, height > 0, let top = menuBarBottom(for: window) else { return }
            let width = window.contentRect(forFrameRect: window.frame).width
            var frame = window.frameRect(forContentRect: NSRect(x: 0, y: 0, width: width, height: height))
            frame.origin = CGPoint(x: window.frame.minX, y: top - frame.height)
            guard abs(window.frame.minY - frame.minY) > 0.5 || abs(window.frame.height - frame.height) > 0.5 else { return }
            window.setFrame(frame, display: true, animate: false)
        }

        /// Bottom edge of the menu bar on the screen that holds our status item.
        private func menuBarBottom(for window: NSWindow) -> CGFloat? {
            let statusWindow = NSApp.windows.first { String(describing: type(of: $0)).contains("StatusBarWindow") && $0.isVisible && $0.frame.minY >= 0 }
            return statusWindow?.frame.minY ?? (window.screen ?? NSScreen.main)?.visibleFrame.maxY
        }
    }
}
