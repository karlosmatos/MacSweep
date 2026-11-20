import AppKit
import SwiftUI

struct MenuBarView: View {
    @Environment(SystemMonitor.self) private var monitor
    @Environment(Sweeper.self) private var sweeper
    @Environment(AppState.self) private var state
    @Environment(Advisor.self) private var advisor
    @Environment(\.openWindow) private var openWindow
    @State private var hovered: String?
    @State private var openVital: Vital?
    @State private var confirmTrash = false
    @State private var contentHeight: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            warnings
            FreeBar(free: monitor.diskFree, sweeper: sweeper, hovered: hovered)
            cleanup
            if monitor.trash > 0 { trashRow }
            Divider()
            VitalsGrid(open: $openVital)
            if let openVital { VitalDetail(vital: openVital) }
            Divider()
            footer
        }
        .padding(16)
        .frame(width: 380)
        .fixedSize(horizontal: false, vertical: true)
        .background(GeometryReader { geo in Color.clear.preference(key: HeightKey.self, value: geo.size.height) })
        .onPreferenceChange(HeightKey.self) { contentHeight = $0 }
        .background(TopPinnedWindow(height: contentHeight))
        .frame(maxHeight: .infinity, alignment: .top)
        .onAppear { monitor.setVisible(true); sweeper.refresh() }
        .onDisappear { monitor.setVisible(false) }
        .alert("Vysypat Koš?", isPresented: $confirmTrash) {
            Button("Vysypat", role: .destructive) { emptyTrash() }
            Button("Zrušit", role: .cancel) {}
        } message: {
            Text("\(Format.bytes(monitor.trash)) se smaže natrvalo. Tohle nejde vrátit.")
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(Format.gigabytes(monitor.diskFree))
                        .font(Theme.number(34))
                        .foregroundStyle(monitor.lowDisk ? Theme.warn : .primary)
                        .contentTransition(.numericText(value: Double(monitor.diskFree)))
                    Text("GB volno").font(.system(size: 14, weight: .medium)).foregroundStyle(.secondary)
                }
                Text("z \(Format.gigabytes(monitor.diskTotal)) GB na Macintosh HD").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            moreMenu
        }
    }

    private var moreMenu: some View {
        Menu {
            Button("Otevřít MacSweep") { open(.analyze) }.keyboardShortcut("o")
            Button("Znovu naskenovat") { sweeper.scan() }.keyboardShortcut("r")
            Divider()
            Toggle("Spouštět po přihlášení", isOn: Binding(get: { LoginItem.enabled }, set: { LoginItem.enabled = $0 }))
            Toggle("Úklid každou neděli v 10:00", isOn: Binding(get: { sweeper.autoEnabled }, set: { sweeper.setAuto($0) }))
            Picker("V menu baru ukazovat", selection: Binding(get: { monitor.readout }, set: { monitor.readout = $0 })) {
                Text("Jen ikonu").tag(SystemMonitor.Readout.none)
                Text("Teplotu").tag(SystemMonitor.Readout.temp)
                Text("Teplotu a procesor").tag(SystemMonitor.Readout.tempCPU)
            }
            if sweeper.totalReclaimed > 0, let since = sweeper.since {
                Text("Uvolněno \(Format.bytes(sweeper.totalReclaimed)) od \(since.formatted(.dateTime.day().month(.defaultDigits)))")
            }
            Divider()
            Button("Ukončit MacSweep") { NSApp.terminate(nil) }.keyboardShortcut("q")
        } label: {
            Image(systemName: "ellipsis").frame(width: 28, height: 28)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("Další volby")
    }

    // MARK: Warnings (only when something is actually wrong)

    @ViewBuilder
    private var warnings: some View {
        if monitor.overheating {
            WarningRow(icon: "thermometer.high", tint: Theme.danger, title: "Mac se přehřívá a zpomaluje",
                       detail: heatDetail, action: monitor.topCPU.first.map { top in ("Ukončit \(top.name)", { monitor.quit(top) }) })
        }
        if monitor.lowDisk {
            WarningRow(icon: "externaldrive.badge.exclamationmark", tint: Theme.warn, title: "Dochází místo",
                       detail: "Pod 25 GB macOS zpomaluje a nestihne aktualizace.",
                       action: ("Rozebrat s Poradcem", { askAdvisorAboutDisk() }))
        } else if monitor.cpuAlert, !monitor.overheating, let top = monitor.topCPU.first {
            WarningRow(icon: "cpu", tint: Theme.warn, title: "Procesor \(monitor.cpuPercent) % déle než minutu",
                       detail: "Nejvíc bere \(top.name).", action: ("Ukončit", { monitor.quit(top) }))
        }
        if let boot = monitor.bootDate, Date().timeIntervalSince(boot) > 14 * 86_400 {
            WarningRow(icon: "power", tint: Theme.warn, title: "Zapnuto \(Int(Date().timeIntervalSince(boot) / 86_400)) dní",
                       detail: (monitor.memory?.swap ?? 0) > 1_000_000_000
                           ? "Swap \(Format.bytes(monitor.memory?.swap ?? 0)). Restart uvolní paměť."
                           : "Restart uvolní paměť a dokončí čekající aktualizace.",
                       action: nil)
        }
    }

    private var heatDetail: String {
        var parts: [String] = []
        if let t = monitor.temperature { parts.append("CPU \(Int(t)) °C") }
        if let rpm = monitor.fanRPM, rpm > 0 { parts.append("ventilátor \(rpm.formatted()) ot./min") }
        if let top = monitor.topCPU.first { parts.append("nejvíc topí \(top.name)") }
        return parts.joined(separator: ", ").capitalizedFirst + "."
    }

    // MARK: Cleanup

    @ViewBuilder
    private var cleanup: some View {
        switch sweeper.phase {
        case .done(let freed, let trashed):
            ResultRow(icon: "checkmark", tint: Theme.accent,
                      title: freed > 0 ? "Uvolněno \(Format.bytes(freed))" : "Hotovo",
                      detail: trashed ? "Stažené soubory jsou v Koši. Místo se vrátí po vysypání." : "Další automatický úklid v neděli v 10:00.",
                      actionTitle: "OK", action: sweeper.dismissResult)
        case .failed(let message):
            ResultRow(icon: "exclamationmark.circle", tint: Theme.danger, title: message,
                      detail: "Co se nepovedlo, je v logu.", actionTitle: "Ukázat log", action: Sweeper.openLog)
        default:
            if sweeper.items.isEmpty && sweeper.scanning {
                SkeletonList()
            } else if sweeper.visibleItems.isEmpty {
                ResultRow(icon: "checkmark", tint: Theme.accent, title: "Není co uvolnit",
                          detail: "Víc místa najdeš v Analýze disku nebo mezi nepoužívanými aplikacemi.",
                          actionTitle: "Analýza", action: { open(.analyze) })
            } else {
                VStack(spacing: 0) {
                    ForEach(sweeper.visibleItems) { item in
                        ReclaimRow(item: item, selected: sweeper.isSelected(item), disabled: sweeper.phase == .running) {
                            sweeper.toggle(item)
                        }
                        .onHover { hovered = $0 ? item.key : (hovered == item.key ? nil : hovered) }
                    }
                }
                .padding(.horizontal, -6)
                sweepButton
            }
        }
    }

    private var sweepButton: some View {
        Button(action: sweeper.sweep) {
            HStack(spacing: 8) {
                if sweeper.phase == .running {
                    ProgressView().controlSize(.small)
                    Text("Uklízím…")
                } else if sweeper.reclaimable > 0 {
                    Text("Uvolnit \(Format.bytes(sweeper.reclaimable))").contentTransition(.numericText())
                } else {
                    Text("Vyber, co uvolnit")
                }
            }
        }
        .buttonStyle(PrimaryButtonStyle())
        .disabled(sweeper.phase == .running || sweeper.reclaimable == 0)
        .keyboardShortcut(.defaultAction)
    }

    private var trashRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "trash").foregroundStyle(.secondary).frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text("Koš \(Format.bytes(monitor.trash))").font(.system(size: 13, weight: .medium))
                Text("Místo se vrátí až po vysypání").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Vysypat…") { confirmTrash = true }.buttonStyle(SecondaryButtonStyle())
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .panel(radius: 10)
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 2) {
            ForEach(Section.allCases) { section in
                FooterLink(title: section.title) { open(section) }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, -8)
    }

    // MARK: Actions

    private func open(_ section: Section) {
        state.section = section
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }

    private func askAdvisorAboutDisk() {
        open(.advisor)
        advisor.send("Na disku zbývá jen \(Format.gigabytes(monitor.diskFree)) GB. Najdi, co zabírá nejvíc místa, a navrhni bezpečný úklid.",
                     display: "Proč mi dochází místo na disku?")
    }

    private func emptyTrash() {
        let trash = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash")
        let items = (try? FileManager.default.contentsOfDirectory(at: trash, includingPropertiesForKeys: nil)) ?? []
        var failed = false
        for item in items where (try? FileManager.default.removeItem(at: item)) == nil { failed = true }
        if failed || items.isEmpty {
            // No direct access to ~/.Trash: let Finder do it.
            _ = try? Process.run(URL(fileURLWithPath: "/usr/bin/osascript"), arguments: ["-e", "tell application \"Finder\" to empty trash"])
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { monitor.refreshTrash() }
    }
}

// MARK: - Free-space bar

/// Free space now (neutral) plus one segment per cleanup category. Unticked categories are outlined;
/// cleaned ones turn neutral, so the bar grows as the sweep runs.
struct FreeBar: View {
    let free: Int64
    let sweeper: Sweeper
    let hovered: String?

    private static let shades: [Double] = [1, 0.72, 0.5, 0.36, 0.28, 0.22, 0.18, 0.15]

    private var cleanedKeys: Set<String> {
        guard sweeper.phase == .running, let current = sweeper.current,
              let index = sweeper.selectedItems.firstIndex(where: { $0.key == current }) else { return [] }
        return Set(sweeper.selectedItems.prefix(index).map(\.key))
    }

    var body: some View {
        let items = sweeper.visibleItems
        let cleaned = cleanedKeys
        let cleanedBytes = items.filter { cleaned.contains($0.key) }.reduce(0) { $0 + $1.bytes }
        let scale = Double(max(free + sweeper.maxReclaimable, 1))

        VStack(alignment: .leading, spacing: 7) {
            GeometryReader { geo in
                let width = geo.size.width - CGFloat(items.count) * 2
                HStack(spacing: 2) {
                    RoundedRectangle(cornerRadius: 3).fill(Theme.neutral)
                        .frame(width: max(width * CGFloat(Double(free + cleanedBytes) / scale), 4))
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        if !cleaned.contains(item.key) {
                            segment(item, shade: Self.shades[min(index, Self.shades.count - 1)])
                                .frame(width: max(width * CGFloat(Double(item.bytes) / scale), 4))
                        }
                    }
                    Spacer(minLength: 0)
                }
            }
            .frame(height: 10)
            .animation(.spring(duration: 0.45, bounce: 0), value: sweeper.skipped)
            .animation(.spring(duration: 0.45, bounce: 0), value: cleaned)
            caption
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func segment(_ item: Sweeper.Item, shade: Double) -> some View {
        let shape = RoundedRectangle(cornerRadius: 3)
        Group {
            if sweeper.isSelected(item) {
                shape.fill(Theme.accent.opacity(hovered == item.key ? 1 : shade))
            } else {
                shape.strokeBorder(Color.secondary, style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
            }
        }
        .overlay { if hovered == item.key { shape.strokeBorder(Color.primary, lineWidth: 1.5) } }
    }

    @ViewBuilder
    private var caption: some View {
        HStack {
            if sweeper.phase == .running, let key = sweeper.current, let item = sweeper.items.first(where: { $0.key == key }) {
                let index = (sweeper.selectedItems.firstIndex(of: item) ?? 0) + 1
                Text("Čistím \(item.progressName) (\(index) z \(sweeper.selectedItems.count))")
                    .foregroundStyle(.secondary)
            } else if sweeper.reclaimable > 0 {
                Text("Po úklidu \(Format.gigabytes(free + sweeper.reclaimable)) GB volno").foregroundStyle(.secondary)
                Spacer()
                Text("+\(Format.bytes(sweeper.reclaimable))").fontWeight(.semibold).foregroundStyle(Theme.accent)
            } else if sweeper.scanning {
                Text("Zjišťuji, co jde uvolnit…").foregroundStyle(.secondary)
            }
        }
        .font(.caption)
        .monospacedDigit()
    }
}

// MARK: - Rows

struct ReclaimRow: View {
    let item: Sweeper.Item
    let selected: Bool
    let disabled: Bool
    let toggle: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 10) {
                Image(systemName: selected ? "checkmark.square.fill" : "square")
                    .font(.system(size: 14))
                    .foregroundStyle(selected ? Theme.accent : .secondary)
                Image(systemName: item.icon).font(.system(size: 13)).foregroundStyle(.secondary).frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.title).font(.system(size: 13, weight: .medium))
                    Text(item.detail).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text(Format.bytes(item.bytes)).font(Theme.number(13, weight: .medium))
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(hovered ? Theme.fill : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .opacity(selected ? 1 : 0.55)
        }
        .buttonStyle(PressableStyle())
        .disabled(disabled)
        .onHover { hovered = $0 }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

struct WarningRow: View {
    let icon: String
    let tint: Color
    let title: String
    let detail: String
    let action: (String, () -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).foregroundStyle(tint).frame(width: 18).padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 4)
            if let action { Button(action.0, action: action.1).buttonStyle(SecondaryButtonStyle()) }
        }
        .padding(10)
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(tint.opacity(0.6)))
    }
}

struct ResultRow: View {
    let icon: String
    let tint: Color
    let title: String
    let detail: String
    let actionTitle: String
    let action: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).foregroundStyle(tint).frame(width: 18).padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 4)
            Button(actionTitle, action: action).buttonStyle(PressableStyle()).font(.caption.weight(.medium)).foregroundStyle(.secondary)
        }
        .padding(12)
        .background(Theme.fill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

/// Placeholder shown only on the very first scan; later scans keep the previous result on screen.
struct SkeletonList: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach([0.46, 0.62, 0.38], id: \.self) { width in
                HStack(spacing: 12) {
                    RoundedRectangle(cornerRadius: 3).fill(Theme.fill).frame(width: 14, height: 14)
                    GeometryReader { geo in
                        VStack(alignment: .leading, spacing: 6) {
                            RoundedRectangle(cornerRadius: 3).fill(Theme.fill).frame(width: geo.size.width * width, height: 9)
                            RoundedRectangle(cornerRadius: 3).fill(Theme.fill).frame(width: geo.size.width * (width + 0.2), height: 7)
                        }
                    }
                    .frame(height: 22)
                    RoundedRectangle(cornerRadius: 3).fill(Theme.fill).frame(width: 40, height: 9)
                }
            }
        }
        .padding(.horizontal, 4)
        .accessibilityLabel("Hledám, co jde uvolnit")
    }
}

struct FooterLink: View {
    let title: String
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Text(title).font(.system(size: 12)).lineLimit(1).fixedSize()
                .padding(.horizontal, 8).padding(.vertical, 5)
                .background(hovered ? Theme.fill : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(PressableStyle())
        .foregroundStyle(hovered ? .primary : .secondary)
        .onHover { hovered = $0 }
    }
}

extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}

private struct HeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}
