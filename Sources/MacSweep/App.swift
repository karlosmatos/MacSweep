import AppKit
import Charts
import Sparkle
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
    @State private var growth = FolderGrowth()

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environment(monitor)
                .environment(state)
                .environment(sweeper)
                .environment(advisor)
                .environment(growth)
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
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1100, height: 720)
    }
}

/// Sparkle: checks the appcast on GitHub Releases daily and installs signed updates.
@MainActor
enum Updates {
    static let controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)

    static func check() {
        NSApp.activate(ignoringOtherApps: true)
        controller.checkForUpdates(nil)
    }
}

/// Opens the main window when MacSweep is launched or reopened from Finder, Spotlight or the Dock;
/// a launch at login stays in the menu bar only.
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Set by the menu bar label once it appears; a launch that comes first waits for it.
    @MainActor static var openMain: (() -> Void)? { didSet { if pendingOpen { pendingOpen = false; openMain?() } } }
    @MainActor private static var pendingOpen = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        _ = Updates.controller
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
        HStack(spacing: 0) {
            sidebar
            Divider()
            detail(for: state.section)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .ignoresSafeArea(.container, edges: .top)
        .onAppear { monitor.setVisible(true) }
        .onDisappear { monitor.setVisible(false) }
    }

    /// Plain rows instead of a sidebar List, which would paint the selection in the system's blue.
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Section.allCases) { section in
                SidebarRow(section: section, selected: state.section == section) { state.section = section }
            }
            Spacer()
            FreeSpaceChart(history: monitor.history).padding(.horizontal, 10).padding(.bottom, 6)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(Format.gigabytes(monitor.diskFree)) GB volno z \(Format.gigabytes(monitor.diskTotal)) GB")
                if sweeper.totalReclaimed > 0, let since = sweeper.since {
                    Text("Uvolněno \(Format.bytes(sweeper.totalReclaimed)) od \(since.formatted(.dateTime.day().month(.defaultDigits)))")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
        }
        .padding(.horizontal, 10)
        .padding(.top, 52) // clears the traffic lights
        .padding(.bottom, 14)
        .frame(width: 210)
        .background(Theme.fill)
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

/// Free space over the last 30 days, with the daily trend once there is enough data.
struct FreeSpaceChart: View {
    let history: DiskHistory

    var body: some View {
        if history.samples.count >= 2 {
            VStack(alignment: .leading, spacing: 4) {
                Chart(history.samples, id: \.date) { sample in
                    AreaMark(x: .value("Den", sample.date), y: .value("Volno", Double(sample.free) / 1e9))
                        .foregroundStyle(Theme.accent.opacity(0.15))
                    LineMark(x: .value("Den", sample.date), y: .value("Volno", Double(sample.free) / 1e9))
                        .foregroundStyle(Theme.accent)
                        .lineStyle(StrokeStyle(lineWidth: 1.5))
                }
                .chartXAxis(.hidden)
                .chartYAxis(.hidden)
                .chartYScale(domain: .automatic(includesZero: false))
                .frame(height: 36)
                .accessibilityLabel("Volné místo za posledních 30 dní")
                if let perDay = history.perDay {
                    Text(perDay < 0 ? "Ubývá \(Format.bytes(Int64(-perDay))) denně" : "Přibývá \(Format.bytes(Int64(perDay))) denně")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// Sidebar entry: neutral fill when selected or hovered, accent only on the selected icon.
struct SidebarRow: View {
    let section: Section
    let selected: Bool
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: section.icon)
                    .foregroundStyle(selected ? Theme.accent : .secondary)
                    .frame(width: 18)
                Text(section.title).fontWeight(selected ? .semibold : .regular)
                Spacer(minLength: 0)
            }
            .font(.system(size: 13))
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(selected || hovered ? Theme.fill : .clear, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(PressableStyle())
        .onHover { hovered = $0 }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
