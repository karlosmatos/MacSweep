import AppKit
import SwiftUI

@MainActor
@Observable
final class AppsModel {
    static let shared = AppsModel()

    struct Plan { var remove: [(path: String, size: String?)] = []; var kept: [String] = [] }
    enum Phase: Equatable { case idle, previewing, uninstalling, done(String), failed(String) }

    var apps: [InstalledApp] = []
    var lastUsed: [String: Date] = [:]
    var loadingApps = false
    var selected: InstalledApp?
    var plan: Plan?
    var phase: Phase = .idle
    var log = ""
    private var previewedApp: String?
    private var pty: PTYRunner?

    var unused: [InstalledApp] { apps.filter { lastUsed[$0.path] == nil } }

    func loadApps() async {
        if let missing = Shell.moleMissing { phase = .failed(missing); return }
        loadingApps = true
        defer { loadingApps = false }
        do {
            let json = try await ProcessRunner.output(Shell.mo, ["uninstall", "--list"])
            let start = json.firstIndex(of: "[") ?? json.startIndex
            apps = try snakeDecoder.decode([InstalledApp].self, from: Data(json[start...].utf8))
                .filter { !$0.path.contains("/Utilities/") || !$0.name.contains("Uninstaller") }
            let paths = apps.map(\.path)
            let dates = await Task.detached(priority: .utility) {
                Dictionary(paths.compactMap { path in
                    (NSMetadataItem(url: URL(fileURLWithPath: path))?.value(forAttribute: "kMDItemLastUsedDate") as? Date).map { (path, $0) }
                }, uniquingKeysWith: { a, _ in a })
            }.value
            lastUsed = dates
        } catch {
            phase = .failed(String(localized: "Seznam aplikací nejde načíst: \(error.localizedDescription)"))
        }
    }

    func select(_ app: InstalledApp) {
        selected = app
        plan = nil
        previewedApp = nil
        phase = .previewing
        Task {
            let text = (try? await ProcessRunner.output(Shell.mo, ["uninstall", "--dry-run", app.uninstallName])) ?? ""
            guard selected == app else { return }
            plan = Self.parse(text)
            previewedApp = app.uninstallName
            phase = .idle
        }
    }

    /// Reads Mole's dry-run: "✓ path , size" lines are removed, "⊙ path" lines are kept personal data.
    static func parse(_ text: String) -> Plan {
        var plan = Plan()
        for raw in Shell.stripANSI(text).components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("✓ ") {
                let parts = line.dropFirst(2).components(separatedBy: " , ")
                plan.remove.append((parts[0], parts.count > 1 ? parts[1] : nil))
            } else if line.hasPrefix("⊙ ") {
                plan.kept.append(String(line.dropFirst(2)))
            }
        }
        return plan
    }

    /// Quits the app if needed, then runs the real uninstall in a pseudo-terminal and answers Mole's
    /// final Enter prompt. Only reachable after the dry-run and our confirmation dialog.
    func uninstall(_ app: InstalledApp) {
        guard previewedApp == app.uninstallName else { return }
        NSWorkspace.shared.runningApplications.filter { $0.bundleURL?.path == app.path }.forEach { $0.terminate() }
        phase = .uninstalling
        log = ""
        let pty = PTYRunner()
        self.pty = pty
        let buffer = OutputBuffer()
        Task {
            try? await Task.sleep(for: .seconds(1))
            let status = try? await pty.run(["uninstall", app.uninstallName]) { chunk in
                let text = buffer.append(chunk)
                if buffer.shouldConfirm(text) { pty.send("\r") }
                onMain { self.log = text }
            }
            onMain {
                self.previewedApp = nil
                if status == 0 {
                    self.phase = .done(app.name)
                    self.apps.removeAll { $0 == app }
                } else {
                    self.phase = .failed(String(localized: "Odinstalace skončila s kódem \(status.map(String.init) ?? "?")."))
                }
            }
        }
    }

    static func bytes(_ size: String?) -> Int64 {
        guard let size else { return 0 }
        let units: [(String, Double)] = [("TB", 1e12), ("GB", 1e9), ("MB", 1e6), ("KB", 1e3), ("B", 1)]
        for (unit, factor) in units where size.uppercased().hasSuffix(unit) {
            return Int64((Double(size.dropLast(unit.count).trimmingCharacters(in: .whitespaces)) ?? 0) * factor)
        }
        return 0
    }
}

/// Accumulates PTY output and detects Mole's confirmation prompt exactly once.
private final class OutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var raw = ""
    private var confirmed = false

    func append(_ chunk: String) -> String {
        lock.lock(); defer { lock.unlock() }
        raw += chunk
        return Shell.renderTerminal(raw)
    }

    func shouldConfirm(_ text: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !confirmed, text.contains("confirm"), text.contains("ESC") else { return false }
        confirmed = true
        return true
    }
}

struct AppsView: View {
    enum Sort { case size, lastUsed }

    @State private var model = AppsModel.shared
    @State private var search = ""
    @State private var sort = Sort.size
    @State private var onlyUnused = false
    @State private var confirm = false

    private var filtered: [InstalledApp] {
        var list = onlyUnused ? model.unused : model.apps
        if !search.isEmpty { list = list.filter { $0.name.localizedCaseInsensitiveContains(search) } }
        switch sort {
        case .size: return list.sorted { AppsModel.bytes($0.size) > AppsModel.bytes($1.size) }
        case .lastUsed: return list.sorted { (model.lastUsed[$0.path] ?? .distantPast) < (model.lastUsed[$1.path] ?? .distantPast) }
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            list.frame(width: 320)
            Divider()
            detail.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .task { if model.apps.isEmpty { await model.loadApps() } }
        .alert("Odinstalovat \(model.selected?.name ?? "")?", isPresented: $confirm) {
            Button("Odinstalovat", role: .destructive) { if let app = model.selected { model.uninstall(app) } }
            Button("Zrušit", role: .cancel) {}
        } message: {
            Text("Aplikace a soubory ze seznamu půjdou do Koše. Běžící aplikace se nejdřív ukončí.")
        }
    }

    // MARK: List

    private var list: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Hledat aplikaci", text: $search).textFieldStyle(.plain)
            }
            .padding(.horizontal, 10).frame(height: 30)
            .background(Theme.fill, in: RoundedRectangle(cornerRadius: 7, style: .continuous))

            Picker("Řadit podle", selection: $sort) {
                Text("Velikost").tag(Sort.size)
                Text("Naposledy použito").tag(Sort.lastUsed)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            let unused = model.unused
            if !unused.isEmpty {
                Button { onlyUnused.toggle() } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "clock.badge.questionmark").foregroundStyle(Theme.accent)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Bez záznamu o spuštění").fontWeight(.semibold)
                            Text("\(unused.count) aplikací, \(Format.bytes(unused.reduce(0) { $0 + AppsModel.bytes($1.size) }))")
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .font(.caption)
                    .padding(8)
                    .background(onlyUnused ? Theme.accent.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(onlyUnused ? Theme.accent : Theme.hairline))
                }
                .buttonStyle(PressableStyle())
                .accessibilityAddTraits(onlyUnused ? .isSelected : [])
            }

            ScrollView {
                LazyVStack(spacing: 1) {
                    ForEach(filtered) { app in
                        AppRow(app: app, lastUsed: model.lastUsed[app.path], selected: model.selected == app) { model.select(app) }
                    }
                }
            }
            .overlay { if model.loadingApps { ProgressView() } }
        }
        .padding(14)
    }

    // MARK: Detail

    @ViewBuilder
    private var detail: some View {
        if let app = model.selected {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(spacing: 14) {
                        AppIcon(path: app.path, name: app.name, size: 52)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(app.name).font(.system(size: 20, weight: .semibold))
                            Text("\(app.size ?? "") celkem. Naposledy použito: \(lastUsedText(app))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    phaseContent(app)
                }
                .padding(24)
            }
        } else if case .failed(let message) = model.phase {
            Text(message).font(.callout).foregroundStyle(Theme.danger).textSelection(.enabled)
                .padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 8) {
                Image(systemName: "square.grid.2x2").font(.system(size: 30, weight: .light)).foregroundStyle(.tertiary)
                Text("Vyber aplikaci").font(.headline)
                Text("Ukážu přesně, které soubory zmizí, ještě než cokoli smažeš.").font(.callout).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private func phaseContent(_ app: InstalledApp) -> some View {
        switch model.phase {
        case .done(let name):
            ResultRow(icon: "checkmark", tint: Theme.accent, title: String(localized: "\(name) odinstalována"),
                      detail: String(localized: "Soubory jsou v Koši, odtud je obnovíš."), actionTitle: String(localized: "Otevřít Koš")) {
                NSWorkspace.shared.open(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash"))
            }
        case .failed(let message):
            ResultRow(icon: "exclamationmark.circle", tint: Theme.danger, title: message,
                      detail: String(localized: "Nic dalšího se nesmazalo."), actionTitle: String(localized: "Zkusit znovu")) { model.select(app) }
        case .uninstalling:
            HStack(spacing: 10) { ProgressView().controlSize(.small); Text("Odinstalovávám \(app.name)…") }
            Text(model.log).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
        case .previewing:
            HStack(spacing: 10) { ProgressView().controlSize(.small); Text("Zjišťuji, co k aplikaci patří…").foregroundStyle(.secondary) }
        case .idle:
            if let plan = model.plan { planView(app, plan) }
        }
    }

    @ViewBuilder
    private func planView(_ app: InstalledApp, _ plan: AppsModel.Plan) -> some View {
        if NSWorkspace.shared.runningApplications.contains(where: { $0.bundleURL?.path == app.path }) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.circle").foregroundStyle(Theme.warn)
                Text("\(app.name) právě běží. Před odinstalací se ukončí.").font(.caption)
            }
            .padding(10)
            .background(Theme.fill, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        VStack(alignment: .leading, spacing: 0) {
            Text("Smaže se").fontWeight(.semibold).padding(.bottom, 4)
            ForEach(plan.remove, id: \.path) { file in
                HStack {
                    Text(file.path).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Text(file.size ?? "").foregroundStyle(.secondary)
                }
                .font(.system(size: 12))
                .padding(.vertical, 6)
                .overlay(alignment: .bottom) { Divider() }
            }
        }
        if !plan.kept.isEmpty {
            DisclosureGroup("Osobní data zůstanou (\(plan.kept.count))") {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(plan.kept, id: \.self) { Text($0).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle) }
                }
                .padding(.top, 4)
            }
            .font(.system(size: 12))
        }
        HStack(spacing: 12) {
            Button("Odinstalovat \(app.name)") { confirm = true }
                .buttonStyle(PrimaryButtonStyle(tint: Theme.danger))
                .fixedSize()
            Text("Všechno jde do Koše.").font(.caption).foregroundStyle(.secondary)
        }
    }

    private func lastUsedText(_ app: InstalledApp) -> String {
        model.lastUsed[app.path].map { $0.formatted(.relative(presentation: .named)) } ?? String(localized: "bez záznamu")
    }
}

struct AppRow: View {
    let app: InstalledApp
    let lastUsed: Date?
    let selected: Bool
    let select: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: select) {
            HStack(spacing: 10) {
                AppIcon(path: app.path, name: app.name, size: 26)
                VStack(alignment: .leading, spacing: 1) {
                    Text(app.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                    Text(lastUsed.map { String(localized: "Použito \($0.formatted(.relative(presentation: .named)))") } ?? String(localized: "Bez záznamu o spuštění"))
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                Text(app.size ?? "").font(Theme.number(11, weight: .medium)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8)
            .frame(height: 42)
            .background(selected ? Theme.accent.opacity(0.12) : hovered ? Theme.fill : .clear,
                        in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(PressableStyle())
        .onHover { hovered = $0 }
    }
}
