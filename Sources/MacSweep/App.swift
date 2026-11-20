import AppKit
import SwiftUI

enum Section: String, CaseIterable, Identifiable {
    case analyze, apps, startup, advisor
    var id: String { rawValue }

    var title: String {
        switch self {
        case .analyze: "Analýza disku"
        case .apps: "Aplikace"
        case .startup: "Spouštění"
        case .advisor: "Poradce"
        }
    }

    var icon: String {
        switch self {
        case .analyze: "chart.pie"
        case .apps: "square.grid.2x2"
        case .startup: "power"
        case .advisor: "text.bubble"
        }
    }
}

@MainActor
@Observable
final class AppState {
    var section: Section = .analyze
}

@main
struct MacSweepApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate
    @State private var monitor = SystemMonitor()
    @State private var state = AppState()
    @State private var advisor = Advisor()
    @State private var sweeper = Sweeper()

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environment(monitor)
                .environment(state)
                .environment(sweeper)
                .environment(advisor)
        } label: {
            MenuBarLabel(monitor: monitor)
        }
        .menuBarExtraStyle(.window)

        Window("MacSweep", id: "main") {
            MainView()
                .environment(monitor)
                .environment(state)
                .environment(advisor)
                .environment(sweeper)
                .frame(minWidth: 900, minHeight: 600)
        }
        .defaultSize(width: 1100, height: 720)
    }
}

/// Opens the main window when MacSweep is launched or reopened from Finder, Spotlight or the Dock;
/// a launch at login stays in the menu bar only.
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Set by the menu bar label once it appears; a launch that comes first waits for it.
    @MainActor static var openMain: (() -> Void)? { didSet { if pendingOpen { pendingOpen = false; openMain?() } } }
    @MainActor private static var pendingOpen = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        let event = NSAppleEventManager.shared().currentAppleEvent
        let atLogin = event?.eventID == kAEOpenApplication
            && event?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
        guard !atLogin else { return }
        if let open = Self.openMain { open() } else { Self.pendingOpen = true }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        Self.openMain?()
        return false
    }
}

/// Icon only by default. Shows free space when it runs low, temperature when the Mac overheats,
/// and the reading the user picked otherwise.
struct MenuBarLabel: View {
    let monitor: SystemMonitor
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: monitor.overheating ? "thermometer.high" : "sparkle")
            if let text { Text(text).monospacedDigit() }
        }
        // The label is the one view that always exists, so it lends the delegate a way to open the window.
        .onAppear { AppDelegate.openMain = { openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true) } }
    }

    private var text: String? {
        let temp = monitor.temperature.map { "\(Int($0.rounded()))°" }
        if monitor.overheating { return temp }
        if monitor.lowDisk { return "\(Int(Double(monitor.diskFree) / 1e9)) GB" }
        switch monitor.readout {
        case .none: return nil
        case .temp: return temp
        case .tempCPU: return [temp, "\(monitor.cpuPercent) %"].compactMap { $0 }.joined(separator: "  ")
        }
    }
}

struct MainView: View {
    @Environment(AppState.self) private var state
    @Environment(SystemMonitor.self) private var monitor
    @Environment(Sweeper.self) private var sweeper

    var body: some View {
        @Bindable var state = state
        NavigationSplitView {
            List(Section.allCases, selection: Binding(get: { state.section }, set: { if let s = $0 { state.section = s } })) { section in
                Label(section.title, systemImage: section.icon).tag(section)
            }
            .navigationSplitViewColumnWidth(200)
            .safeAreaInset(edge: .bottom) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(Format.gigabytes(monitor.diskFree)) GB volno z \(Format.gigabytes(monitor.diskTotal)) GB")
                    if sweeper.totalReclaimed > 0, let since = sweeper.since {
                        Text("Uvolněno \(Format.bytes(sweeper.totalReclaimed)) od \(since.formatted(.dateTime.day().month(.defaultDigits)))")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
            }
        } detail: {
            detail(for: state.section)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear { monitor.setVisible(true) }
        .onDisappear { monitor.setVisible(false) }
    }

    @ViewBuilder
    private func detail(for section: Section) -> some View {
        switch section {
        case .analyze: AnalyzeView()
        case .apps: AppsView()
        case .startup: StartupView()
        case .advisor: AdvisorView()
        }
    }
}
