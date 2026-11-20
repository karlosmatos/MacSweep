import AppKit
import SwiftUI

@MainActor
@Observable
final class AnalyzeModel {
    static let shared = AnalyzeModel()

    /// nil path = Mole's machine-wide overview.
    var stack: [String?] = [nil]
    var result: AnalyzeResult?
    var modified: [String: Date] = [:]
    var selection: Set<String> = []
    var loading = false
    var error: String?
    private var cache: [String: AnalyzeResult] = [:]

    var current: String? { stack.last ?? nil }

    func load(force: Bool = false) async {
        let key = current ?? "/"
        selection = []
        if !force, let cached = cache[key] { result = cached; readDates(cached); return }
        if let missing = Shell.moleMissing { error = missing; return }
        loading = true
        error = nil
        defer { loading = false }
        do {
            let args = ["analyze", "--json"] + (current.map { [$0] } ?? [])
            let json = try await ProcessRunner.output(Shell.mo, args)
            let start = json.firstIndex(of: "{") ?? json.startIndex
            let decoded = try snakeDecoder.decode(AnalyzeResult.self, from: Data(json[start...].utf8))
            cache[key] = decoded
            if (current ?? "/") == key { result = decoded; readDates(decoded) }
        } catch {
            self.error = "Analýza selhala: \(error.localizedDescription)"
        }
    }

    private func readDates(_ result: AnalyzeResult) {
        for entry in result.entries where modified[entry.path] == nil {
            modified[entry.path] = (try? FileManager.default.attributesOfItem(atPath: entry.path))?[.modificationDate] as? Date
        }
    }

    func open(_ path: String) async { stack.append(path); await load() }

    func jump(to index: Int) async {
        guard index < stack.count - 1 else { return }
        stack = Array(stack.prefix(index + 1))
        await load()
    }

    func up() async {
        guard stack.count > 1 else { return }
        stack.removeLast()
        await load()
    }

    var selectedEntries: [AnalyzeResult.Entry] { result?.entries.filter { selection.contains($0.path) } ?? [] }

    func trashSelection() async {
        var failures: [String] = []
        for entry in selectedEntries {
            do { try FileManager.default.trashItem(at: URL(fileURLWithPath: entry.path), resultingItemURL: nil) } catch { failures.append(entry.name) }
        }
        cache.removeAll()
        await load(force: true)
        if !failures.isEmpty { error = "Do Koše nešlo přesunout: \(failures.joined(separator: ", "))." }
    }
}

struct AnalyzeView: View {
    @State private var model = AnalyzeModel.shared
    @State private var confirm = false

    private let home = FileManager.default.homeDirectoryForCurrentUser.path

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            toolbar.padding(.horizontal, 24).padding(.top, 18).padding(.bottom, 12)
            if let error = model.error {
                Text(error).font(.callout).foregroundStyle(Theme.danger).padding(.horizontal, 24).padding(.bottom, 8)
            }
            if model.result?.scanStatus == "partial" { accessBanner.padding(.horizontal, 24).padding(.bottom, 10) }
            content
            actionBar
        }
        .task { if model.result == nil { await model.load() } }
        .alert(confirmTitle, isPresented: $confirm) {
            Button("Přesunout do Koše", role: .destructive) { Task { await model.trashSelection() } }
            Button("Zrušit", role: .cancel) {}
        } message: {
            Text(model.selectedEntries.map(\.name).joined(separator: ", ") + ". Obnovíš je z Koše.")
        }
    }

    private var confirmTitle: String {
        let size = Format.bytes(model.selectedEntries.reduce(0) { $0 + $1.size })
        return "Přesunout \(model.selectedEntries.count == 1 ? "1 položku" : "\(model.selectedEntries.count) položky") (\(size)) do Koše?"
    }

    // MARK: Toolbar with breadcrumb

    private var toolbar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 2) {
                ForEach(Array(crumbs.enumerated()), id: \.offset) { index, crumb in
                    if index > 0 { Text("›").foregroundStyle(.tertiary) }
                    if index == crumbs.count - 1 {
                        Text(crumb).fontWeight(.semibold).padding(.horizontal, 6)
                    } else {
                        Button(crumb) { Task { await model.jump(to: index) } }
                            .buttonStyle(PressableStyle())
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                    }
                }
                if let total = model.result?.entries.reduce(0, { $0 + $1.size }), model.current != nil {
                    Text(Format.bytes(total)).foregroundStyle(.secondary).padding(.leading, 8)
                }
            }
            .lineLimit(1)
            Spacer()
            if model.loading { ProgressView().controlSize(.small) }
            IconButton(icon: "house", help: "Domovská složka") { Task { await model.open(home) } }
            IconButton(icon: "arrow.clockwise", help: "Znovu naskenovat") { Task { await model.load(force: true) } }
                .keyboardShortcut("r")
        }
        .font(.system(size: 13))
    }

    private var crumbs: [String] {
        model.stack.map { path in
            guard let path else { return "Celý Mac" }
            if path == home { return "Domov" }
            return (path as NSString).lastPathComponent
        }
    }

    private var accessBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "lock").foregroundStyle(Theme.warn)
            (Text("Část složek je zamčená. ").fontWeight(.semibold)
             + Text("Bez plného přístupu k disku vychází některé složky menší, než jsou.").foregroundStyle(.secondary))
                .font(.caption)
            Spacer()
            Button("Povolit přístup") {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
            }
            .buttonStyle(SecondaryButtonStyle())
        }
        .padding(10)
        .background(Theme.fill, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    // MARK: List

    @ViewBuilder
    private var content: some View {
        if model.loading && model.result == nil {
            VStack(spacing: 10) {
                ProgressView()
                Text("Procházím disk…").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let result = model.result {
            let maxSize = max(result.entries.map(\.size).max() ?? 1, 1)
            VStack(spacing: 0) {
                AnalyzeRowLayout(check: Text(""), icon: Text(""), name: Text("Název"), date: Text("Změněno"),
                                 bar: Text(""), size: Text("Velikost"), chevron: Text(""))
                    .font(.caption).foregroundStyle(.secondary).frame(height: 26)
                ScrollView {
                    LazyVStack(spacing: 1) {
                        ForEach(result.entries) { entry in
                            AnalyzeRow(entry: entry, fraction: Double(entry.size) / Double(maxSize),
                                       modified: model.modified[entry.path],
                                       selected: model.selection.contains(entry.path),
                                       toggle: { toggle(entry) },
                                       open: { Task { await model.open(entry.path) } })
                        }
                    }
                }
            }
            .padding(.horizontal, 12)
        } else {
            Spacer()
        }
    }

    private func toggle(_ entry: AnalyzeResult.Entry) {
        if model.selection.contains(entry.path) { model.selection.remove(entry.path) } else { model.selection.insert(entry.path) }
    }

    // MARK: Action bar

    private var actionBar: some View {
        let selected = model.selectedEntries
        return HStack(spacing: 10) {
            if selected.isEmpty {
                Text("Zaškrtni složky nebo soubory, které chceš smazat.").foregroundStyle(.secondary)
            } else {
                Text("\(selected.count == 1 ? "1 vybraná" : "\(selected.count) vybrané"), \(Format.bytes(selected.reduce(0) { $0 + $1.size }))")
                    .fontWeight(.semibold)
            }
            Spacer()
            Text("⌘⌫").font(.system(size: 11)).foregroundStyle(.secondary)
                .padding(.horizontal, 5).padding(.vertical, 1)
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Theme.hairline))
            Button("Ukázat ve Finderu") {
                NSWorkspace.shared.activateFileViewerSelecting(selected.map { URL(fileURLWithPath: $0.path) })
            }
            .buttonStyle(SecondaryButtonStyle())
            .disabled(selected.isEmpty)
            Button("Přesunout do Koše") { confirm = true }
                .buttonStyle(PrimaryButtonStyle(tint: Theme.danger))
                .frame(width: 160)
                .disabled(selected.isEmpty)
                .keyboardShortcut(.delete, modifiers: .command)
        }
        .font(.system(size: 13))
        .padding(.horizontal, 24).padding(.vertical, 10)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }
}

/// Shared column layout for the header and rows.
struct AnalyzeRowLayout<A: View, B: View, C: View, D: View, E: View, F: View, G: View>: View {
    let check: A, icon: B, name: C, date: D, bar: E, size: F, chevron: G

    var body: some View {
        HStack(spacing: 12) {
            check.frame(width: 16)
            icon.frame(width: 20)
            name.frame(maxWidth: .infinity, alignment: .leading)
            date.frame(width: 120, alignment: .leading)
            bar.frame(width: 120, alignment: .leading)
            size.frame(width: 76, alignment: .trailing)
            chevron.frame(width: 12)
        }
        .padding(.horizontal, 12)
    }
}

struct AnalyzeRow: View {
    let entry: AnalyzeResult.Entry
    let fraction: Double
    let modified: Date?
    let selected: Bool
    let toggle: () -> Void
    let open: () -> Void
    @State private var hovered = false

    private var handledByMenuBar: Bool { entry.path.hasSuffix("/Library/Caches") }

    var body: some View {
        AnalyzeRowLayout(
            check: Button(action: toggle) {
                Image(systemName: selected ? "checkmark.square.fill" : "square").foregroundStyle(selected ? Theme.accent : .secondary)
            }.buttonStyle(PressableStyle()).accessibilityLabel("Vybrat \(entry.name)"),
            icon: Image(nsImage: NSWorkspace.shared.icon(forFile: entry.path)).resizable().frame(width: 20, height: 20),
            name: HStack(spacing: 8) {
                Text(entry.name).fontWeight(.medium).lineLimit(1).truncationMode(.middle)
                if handledByMenuBar { Text("Uklízí menu bar").font(.caption).foregroundStyle(Theme.accent) }
                else if entry.insight == true { Text("Kandidát na smazání").font(.caption).foregroundStyle(Theme.warn) }
            },
            date: Text(modified.map { $0.formatted(.relative(presentation: .named)) } ?? "").font(.caption).foregroundStyle(.secondary),
            bar: GeometryReader { geo in
                RoundedRectangle(cornerRadius: 3).fill(Theme.accent.opacity(0.75))
                    .frame(width: max(geo.size.width * fraction, 3), height: 6)
                    .frame(maxHeight: .infinity)
            },
            size: Text(Format.bytes(entry.size)).font(Theme.number(13, weight: .medium)),
            chevron: Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.tertiary).opacity(entry.isDir ? 1 : 0)
        )
        .font(.system(size: 13))
        .frame(height: 38)
        .background(selected ? Theme.accent.opacity(0.12) : hovered ? Theme.fill : .clear,
                    in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture { if entry.isDir { open() } else { toggle() } }
        .onHover { hovered = $0 }
        .contextMenu {
            Button("Ukázat ve Finderu") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: entry.path)]) }
            Button(selected ? "Zrušit výběr" : "Vybrat", action: toggle)
        }
    }
}
