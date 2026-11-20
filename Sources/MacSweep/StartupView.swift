import AppKit
import SwiftUI

/// Everything that starts on its own: login items, background agents (user-switchable via launchctl)
/// and privileged helpers (read-only). Data comes from System Events and the Background Task
/// Management database (`sfltool dumpbtm`, readable without admin rights).
struct StartupItem: Identifiable, Equatable {
    enum Kind { case loginItem, helper, agent, daemon }

    let id: String
    let kind: Kind
    let name: String
    let detail: String
    let appPath: String?
    let plistPath: String?
    var enabled: Bool

    var switchable: Bool { kind == .loginItem || kind == .agent }
}

@MainActor
@Observable
final class StartupModel {
    static let shared = StartupModel()

    var items: [StartupItem] = []
    var loading = false
    var error: String?

    private static let uid = getuid()
    private static let home = FileManager.default.homeDirectoryForCurrentUser.path
    private static let removedKey = "removedLoginItems" // name -> path, so a switched-off login item can come back

    func load() async {
        loading = true
        defer { loading = false }
        async let btm = ProcessRunner.output("/usr/bin/sfltool", ["dumpbtm"])
        async let disabled = ProcessRunner.output("/bin/launchctl", ["print-disabled", "gui/\(Self.uid)"])
        // One "name<TAB>path" line per item, so names with commas or quotes parse correctly.
        async let logins = ProcessRunner.output("/usr/bin/osascript", [
            "-e", "set out to \"\"",
            "-e", "tell application \"System Events\" to repeat with i in every login item",
            "-e", "set out to out & (name of i) & tab & (path of i) & linefeed",
            "-e", "end repeat",
            "-e", "return out"])
        let (btmText, disabledText, loginText) = (try? await btm, try? await disabled, try? await logins)

        var result: [StartupItem] = []
        result += Self.loginItems(from: loginText ?? "")
        result += Self.btmItems(from: btmText ?? "", disabled: Self.disabledLabels(from: disabledText ?? ""))
        items = result
        if loginText == nil || loginText?.contains("execution error") == true {
            error = "Položky po přihlášení nejde načíst. Povol MacSweep ovládání System Events v Nastavení, Soukromí, Automatizace."
        }
    }

    func toggle(_ item: StartupItem) {
        guard let index = items.firstIndex(of: item) else { return }
        let enable = !item.enabled
        items[index].enabled = enable
        Task {
            switch item.kind {
            case .loginItem: await setLoginItem(item, enabled: enable)
            case .agent: await setAgent(item, enabled: enable)
            default: break
            }
        }
    }

    // MARK: Login items (System Events)

    private static func loginItems(from text: String) -> [StartupItem] {
        var items: [StartupItem] = text.components(separatedBy: "\n").compactMap { line in
            let parts = line.components(separatedBy: "\t")
            guard parts.count == 2, !parts[0].isEmpty else { return nil }
            return StartupItem(id: "login:" + parts[0], kind: .loginItem, name: parts[0], detail: description(forApp: parts[1]),
                               appPath: parts[1], plistPath: nil, enabled: true)
        }
        let removed = UserDefaults.standard.dictionary(forKey: removedKey) as? [String: String] ?? [:]
        for (name, path) in removed.sorted(by: { $0.key < $1.key }) where !items.contains(where: { $0.name == name }) {
            items.append(StartupItem(id: "login:" + name, kind: .loginItem, name: name, detail: "Vypnuto v MacSweep",
                                     appPath: path, plistPath: nil, enabled: false))
        }
        return items
    }

    private static func description(forApp path: String) -> String {
        (path as NSString).deletingLastPathComponent.replacingOccurrences(of: home, with: "~")
    }

    private func setLoginItem(_ item: StartupItem, enabled: Bool) async {
        var removed = UserDefaults.standard.dictionary(forKey: Self.removedKey) as? [String: String] ?? [:]
        // Values go in as arguments, never into the script source.
        let args: [String]
        if enabled, let path = item.appPath {
            args = ["-e", "on run argv",
                    "-e", "tell application \"System Events\" to make login item at end with properties {path:(item 1 of argv), hidden:false}",
                    "-e", "end run", path]
            removed[item.name] = nil
        } else {
            args = ["-e", "on run argv",
                    "-e", "tell application \"System Events\" to delete login item (item 1 of argv)",
                    "-e", "end run", item.name]
            removed[item.name] = item.appPath
        }
        UserDefaults.standard.set(removed, forKey: Self.removedKey)
        _ = try? await ProcessRunner.output("/usr/bin/osascript", args)
    }

    // MARK: Agents and helpers (BTM + launchctl)

    private static func disabledLabels(from text: String) -> Set<String> {
        // "com.valvesoftware.steamclean" => disabled
        Set(text.components(separatedBy: "\n").compactMap { line in
            guard line.contains("=> disabled"), let first = line.firstIndex(of: "\""), let last = line.lastIndex(of: "\""), first < last else { return nil }
            return String(line[line.index(after: first)..<last])
        })
    }

    private static func btmItems(from text: String, disabled: Set<String>) -> [StartupItem] {
        var records: [(uid: String, fields: [String: String])] = []
        var uid = ""
        var current: [String: String]?
        for line in text.components(separatedBy: "\n") {
            if line.contains("Records for UID") {
                uid = line.components(separatedBy: "UID ").last?.components(separatedBy: " ").first ?? ""
            } else if line.trimmingCharacters(in: .whitespaces).range(of: #"^#\d+:$"#, options: .regularExpression) != nil {
                if let current { records.append((uid, current)) }
                current = [:]
            } else if let colon = line.firstIndex(of: ":"), current != nil {
                let key = line[..<colon].trimmingCharacters(in: .whitespaces)
                let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                if current?[key] == nil { current?[key] = value }
            }
        }
        if let current { records.append((uid, current)) }

        let appURLs = Dictionary(records.compactMap { r -> (String, String)? in
            guard let id = r.fields["Identifier"], let url = r.fields["URL"], url.hasSuffix(".app") else { return nil }
            return (id, url)
        }, uniquingKeysWith: { a, _ in a })

        var items: [StartupItem] = []
        var seen = Set<String>()
        for record in records {
            let f = record.fields
            guard let type = f["Type"], let identifier = f["Identifier"], let rawURL = f["URL"], rawURL != "(null)" else { continue }
            let label = identifier.replacingOccurrences(of: #"^\d+\."#, with: "", options: .regularExpression)
            let parentApp = f["Parent Identifier"].flatMap { appURLs[$0] }
            let path: String
            if rawURL.hasPrefix("/") {
                path = rawURL.replacingOccurrences(of: "/Users/\(uid)", with: home)
            } else if let parentApp {
                path = parentApp + "/" + rawURL
            } else { continue }
            guard FileManager.default.fileExists(atPath: path), seen.insert(label).inserted else { continue }

            let kind: StartupItem.Kind
            if type.hasPrefix("legacy daemon") || type.hasPrefix("daemon") { kind = .daemon }
            else if record.uid != String(Self.uid) { continue }
            else if type.hasPrefix("legacy agent") || type.hasPrefix("agent") { kind = .agent }
            else if type.hasPrefix("login item") { kind = .helper }
            else { continue }

            let developer = f["Developer Name"].flatMap { $0 == "(null)" ? nil : $0 }
            let name = friendlyName(label: label, btmName: f["Name"] ?? label, parentApp: parentApp)
            items.append(StartupItem(
                id: "btm:" + label, kind: kind, name: name,
                detail: [developer, label].compactMap { $0 }.joined(separator: ", "),
                appPath: parentApp, plistPath: path.hasSuffix(".plist") ? path : nil,
                enabled: !disabled.contains(label) && !(f["Disposition"] ?? "").hasPrefix("[disabled")))
        }
        return items
    }

    private static func friendlyName(label: String, btmName: String, parentApp: String?) -> String {
        if label == "com.karel.disk-cleanup" { return "MacSweep týdenní úklid" }
        let executableLike = ["bash", "sh", "python3", "node"].contains(btmName) || btmName.contains(".")
        if let parentApp {
            let app = FileManager.default.displayName(atPath: parentApp).replacingOccurrences(of: ".app", with: "")
            return btmName == app || executableLike ? app : btmName
        }
        return executableLike ? label : btmName
    }

    private func setAgent(_ item: StartupItem, enabled: Bool) async {
        let label = String(item.id.dropFirst(4))
        let target = "gui/\(Self.uid)/\(label)"
        if enabled {
            _ = try? await ProcessRunner.output("/bin/launchctl", ["enable", target])
            if let plist = item.plistPath, item.appPath == nil {
                _ = try? await ProcessRunner.output("/bin/launchctl", ["bootstrap", "gui/\(Self.uid)", plist])
            }
        } else {
            _ = try? await ProcessRunner.output("/bin/launchctl", ["disable", target])
            _ = try? await ProcessRunner.output("/bin/launchctl", ["bootout", target])
        }
    }
}

struct StartupView: View {
    @State private var model = StartupModel.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                PageHeader(title: "Spouštění", subtitle: summary) {
                    HStack(spacing: 6) {
                        if model.loading { ProgressView().controlSize(.small) }
                        IconButton(icon: "arrow.clockwise", help: "Načíst znovu") { Task { await model.load() } }
                    }
                }
                if let error = model.error {
                    Text(error).font(.caption).foregroundStyle(Theme.warn)
                }
                group("Otevře se po přihlášení", "Aplikace s oknem nebo ikonou v menu baru. Vypnutím se jen přestanou spouštět samy.", kinds: [.loginItem])
                group("Běží na pozadí", "Pomocné procesy, které si aplikace zaregistrovaly. Vypnutí jde kdykoli vrátit.", kinds: [.agent])
                group("Pomocníci aplikací", "Zapínají se v nastavení dané aplikace nebo v Nastavení systému.", kinds: [.helper, .daemon])
                Button("Otevřít Nastavení systému, Položky při přihlášení") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!)
                }
                .buttonStyle(PressableStyle())
                .font(.caption.weight(.medium))
                .foregroundStyle(Theme.accent)
            }
            .padding(24)
        }
        .task { if model.items.isEmpty { await model.load() } }
    }

    private var summary: String {
        let switchable = model.items.filter(\.switchable)
        guard !switchable.isEmpty else { return "Co se samo zapne při startu Macu." }
        return "Po startu se spustí \(switchable.filter(\.enabled).count) z \(switchable.count) položek a \(model.items.count - switchable.count) pomocníků."
    }

    @ViewBuilder
    private func group(_ title: String, _ subtitle: String, kinds: [StartupItem.Kind]) -> some View {
        let items = model.items.filter { kinds.contains($0.kind) }
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(subtitle).font(.caption).foregroundStyle(.secondary).padding(.bottom, 6)
                VStack(spacing: 0) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        if index > 0 { Divider() }
                        StartupRow(item: item) { model.toggle(item) }
                    }
                }
                .panel(radius: 10)
            }
        }
    }
}

struct StartupRow: View {
    let item: StartupItem
    let toggle: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            AppIcon(path: item.appPath, name: item.name, size: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.name).font(.system(size: 13, weight: .medium))
                Text(item.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            if item.switchable {
                Toggle("", isOn: Binding(get: { item.enabled }, set: { _ in toggle() }))
                    .toggleStyle(.switch).controlSize(.small).labelsHidden().tint(Theme.accent)
                    .accessibilityLabel("Spouštět \(item.name)")
            } else {
                Text(item.enabled ? "Zapnuto" : "Vypnuto").font(.caption).foregroundStyle(.secondary)
                Image(systemName: "lock").font(.caption).foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
    }
}
