import AppKit
import CryptoKit
import SwiftUI

/// Big files and duplicate files in the home folder, found through Spotlight.
/// ~/Library, hidden folders and the inside of packages are left out: removing those breaks apps.
@MainActor
@Observable
final class FilesModel {
    enum Mode: Hashable { case large, duplicates }

    struct File: Identifiable, Hashable, Sendable {
        let path: String
        let size: Int64
        let lastUsed: Date?
        let inode: UInt64
        var id: String { path }
        var name: String { (path as NSString).lastPathComponent }
    }

    struct Group: Identifiable {
        let files: [File]
        var id: String { files[0].path }
        /// What removing all but one copy frees.
        var wasted: Int64 { files.dropFirst().reduce(0) { $0 + $1.size } }
    }

    static let largeMinimum: Int64 = 250_000_000
    static let duplicateMinimum: Int64 = 10_000_000
    private static let home = FileManager.default.homeDirectoryForCurrentUser.path

    /// Switching lists clears the selection, so the Trash button never acts on files that are not on screen.
    var mode: Mode = .large { didSet { if mode != oldValue { selection = [] } } }
    private(set) var large: [File]?
    private(set) var groups: [Group]?
    var selection: Set<String> = []
    private(set) var loading = false
    var error: String?

    var selectedFiles: [File] {
        let shown = mode == .large ? large ?? [] : (groups ?? []).flatMap(\.files)
        return shown.filter { selection.contains($0.path) }
    }

    func load(force: Bool = false) async {
        switch mode {
        case .large where large == nil || force:
            loading = true
            large = await Self.find(minimum: Self.largeMinimum).sorted { $0.size > $1.size }
            loading = false
        case .duplicates where groups == nil || force:
            loading = true
            let files = await Self.find(minimum: Self.duplicateMinimum)
            groups = await Task.detached(priority: .userInitiated) { Self.duplicates(files) }.value
            loading = false
        default: break
        }
    }

    /// Ticks every copy but the oldest in each group.
    func selectCopies() {
        for group in groups ?? [] { group.files.dropFirst().forEach { selection.insert($0.path) } }
    }

    func trashSelection() async {
        var failures: [String] = []
        for file in selectedFiles {
            do { try FileManager.default.trashItem(at: URL(fileURLWithPath: file.path), resultingItemURL: nil) } catch { failures.append(file.name) }
        }
        selection = []
        large = nil
        groups = nil
        await load()
        error = failures.isEmpty ? nil : String(localized: "Do Koše nešlo přesunout: \(failures.joined(separator: ", ")).")
    }

    // MARK: Finding

    private static func find(minimum: Int64) async -> [File] {
        let query = "kMDItemFSSize > \(minimum)"
        let output = (try? await ProcessRunner.output("/usr/bin/mdfind", ["-onlyin", home, query])) ?? ""
        let paths = output.split(separator: "\n").map(String.init).filter { isCandidate($0, home: home) }
        return await Task.detached(priority: .userInitiated) { paths.compactMap(file(at:)) }.value
    }

    /// User files only: not in ~/Library, hidden folders or packages.
    nonisolated static func isCandidate(_ path: String, home: String) -> Bool {
        guard path.hasPrefix(home + "/") else { return false }
        let parts = path.dropFirst(home.count + 1).split(separator: "/")
        if parts.first == "Library" { return false }
        // Every folder on the way, not the file itself, must be a plain folder.
        return !parts.dropLast().contains { $0.hasPrefix(".") || packageExtensions.contains(($0 as NSString).pathExtension.lowercased()) }
    }

    private nonisolated static let packageExtensions: Set<String> = [
        "app", "photoslibrary", "musiclibrary", "tvlibrary", "fcpbundle", "logicx", "band", "bundle", "framework",
        "xcodeproj", "xcworkspace", "imovielibrary", "lrdata", "lrlibrary", "sparsebundle",
    ]

    /// nil for folders, missing files and cloud files that are not downloaded (they take no space).
    private nonisolated static func file(at path: String) -> File? {
        let url = URL(fileURLWithPath: path)
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .totalFileAllocatedSizeKey,
                                                              .contentModificationDateKey]),
              values.isRegularFile == true, let size = values.fileSize,
              let allocated = values.totalFileAllocatedSize, allocated >= size / 2,
              let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let inode = attributes[.systemFileNumber] as? UInt64 else { return nil }
        let lastUsed = MDItemCreate(nil, path as CFString)
            .flatMap { MDItemCopyAttribute($0, kMDItemLastUsedDate) as? Date } ?? values.contentModificationDate
        return File(path: path, size: Int64(allocated), lastUsed: lastUsed, inode: inode)
    }

    /// Files with identical content, biggest waste first. Same size first, then a hash of the first
    /// megabyte, then of the whole file, so most files are never read in full. Hard links count once.
    nonisolated static func duplicates(_ files: [File]) -> [Group] {
        var uniqueInodes = Set<UInt64>()
        let files = files.filter { uniqueInodes.insert($0.inode).inserted }
        let bySize = Dictionary(grouping: files, by: \.size).values.filter { $0.count > 1 }
        var groups: [Group] = []
        for sameSize in bySize {
            let byHead = Dictionary(grouping: sameSize) { hash($0.path, limit: 1 << 20) }.filter { $0.key != nil && $0.value.count > 1 }
            for candidates in byHead.values {
                let byContent = Dictionary(grouping: candidates) { hash($0.path, limit: nil) }.filter { $0.key != nil && $0.value.count > 1 }
                for copies in byContent.values {
                    groups.append(Group(files: copies.sorted { ($0.lastUsed ?? .distantPast) < ($1.lastUsed ?? .distantPast) }))
                }
            }
        }
        return groups.sorted { $0.wasted > $1.wasted }
    }

    private nonisolated static func hash(_ path: String, limit: Int?) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        var remaining = limit ?? .max
        while remaining > 0 {
            guard let chunk = try? handle.read(upToCount: min(1 << 20, remaining)), !chunk.isEmpty else { break }
            hasher.update(data: chunk)
            remaining -= chunk.count
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

struct FilesView: View {
    @State private var model = FilesModel()
    @State private var confirm = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                PageHeader(title: String(localized: "Velké soubory a duplicity"), subtitle: subtitle) {
                    HStack(spacing: 8) {
                        if model.loading { ProgressView().controlSize(.small) }
                        IconButton(icon: "arrow.clockwise", help: String(localized: "Znovu hledat")) { Task { await model.load(force: true) } }
                            .keyboardShortcut("r")
                    }
                }
                Picker("", selection: $model.mode) {
                    Text("Velké soubory").tag(FilesModel.Mode.large)
                    Text("Duplicity").tag(FilesModel.Mode.duplicates)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                if let error = model.error { Text(error).font(.callout).foregroundStyle(Theme.danger) }
            }
            .padding(.horizontal, 24).padding(.top, 24).padding(.bottom, 12)
            content
            actionBar
        }
        .task(id: model.mode) { await model.load() }
        .alert(String(localized: "Přesunout \(Format.bytes(model.selectedFiles.reduce(0) { $0 + $1.size })) do Koše?"),
               isPresented: $confirm) {
            Button("Přesunout do Koše", role: .destructive) { Task { await model.trashSelection() } }
            Button("Zrušit", role: .cancel) {}
        } message: {
            Text("Obnovíš je z Koše.")
        }
    }

    private var subtitle: String {
        switch model.mode {
        case .large: String(localized: "Soubory nad 250 MB ve tvé domovské složce, podle Spotlightu.")
        case .duplicates: String(localized: "Stejné soubory nad 10 MB. Kopie z Finderu můžou sdílet místo, pak uvolní méně.")
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.mode {
        case .large:
            if let files = model.large {
                if files.isEmpty {
                    empty("Žádné velké soubory")
                } else {
                    ScrollView {
                        LazyVStack(spacing: 1) { ForEach(files) { row($0) } }.padding(.horizontal, 12)
                    }
                }
            } else {
                searching
            }
        case .duplicates:
            if let groups = model.groups {
                if groups.isEmpty {
                    empty("Žádné duplicity")
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 1) {
                            ForEach(groups) { group in
                                Text("Kopií: \(group.files.count), navíc \(Format.bytes(group.wasted))")
                                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                                    .padding(.horizontal, 12).padding(.top, 14).padding(.bottom, 4)
                                ForEach(group.files) { row($0) }
                            }
                        }
                        .padding(.horizontal, 12)
                    }
                }
            } else {
                searching
            }
        }
    }

    private var searching: some View {
        VStack(spacing: 10) {
            ProgressView()
            Text(model.mode == .duplicates ? String(localized: "Porovnávám obsah souborů…") : String(localized: "Hledám…")).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func empty(_ title: LocalizedStringKey) -> some View {
        Text(title).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func row(_ file: FilesModel.File) -> some View {
        FileRow(file: file, selected: model.selection.contains(file.path)) {
            if model.selection.contains(file.path) { model.selection.remove(file.path) } else { model.selection.insert(file.path) }
        }
    }

    private var actionBar: some View {
        let selected = model.selectedFiles
        return HStack(spacing: 10) {
            if selected.isEmpty {
                Text("Zaškrtni soubory, které chceš smazat.").foregroundStyle(.secondary)
            } else {
                Text("Vybráno: \(selected.count), \(Format.bytes(selected.reduce(0) { $0 + $1.size }))").fontWeight(.semibold)
            }
            Spacer()
            if model.mode == .duplicates, !(model.groups ?? []).isEmpty {
                Button("Vybrat kopie") { model.selectCopies() }.buttonStyle(SecondaryButtonStyle())
                    .help("Zaškrtne všechny kopie kromě nejstarší v každé skupině")
            }
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

struct FileRow: View {
    let file: FilesModel.File
    let selected: Bool
    let toggle: () -> Void
    @State private var hovered = false

    private var unused: Bool { file.lastUsed.map { Date().timeIntervalSince($0) > 365 * 86_400 } ?? false }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: selected ? "checkmark.square.fill" : "square")
                .foregroundStyle(selected ? Theme.accent : .secondary).frame(width: 16)
            Image(nsImage: NSWorkspace.shared.icon(forFile: file.path)).resizable().frame(width: 20, height: 20)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 8) {
                    Text(file.name).fontWeight(.medium).lineLimit(1).truncationMode(.middle)
                    if unused { Text("Rok neotevřeno").font(.caption).foregroundStyle(Theme.warn) }
                }
                Text(((file.path as NSString).deletingLastPathComponent as NSString).abbreviatingWithTildeInPath)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(file.lastUsed.map { $0.formatted(.relative(presentation: .named)) } ?? "")
                .font(.caption).foregroundStyle(.secondary).frame(width: 120, alignment: .leading)
            Text(Format.bytes(file.size)).font(Theme.number(13, weight: .medium)).frame(width: 76, alignment: .trailing)
        }
        .font(.system(size: 13))
        .padding(.horizontal, 12)
        .frame(height: 42)
        .background(selected ? Theme.accent.opacity(0.12) : hovered ? Theme.fill : .clear,
                    in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture(perform: toggle)
        .onHover { hovered = $0 }
        .contextMenu {
            Button("Ukázat ve Finderu") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: file.path)]) }
            Button("Otevřít") { NSWorkspace.shared.open(URL(fileURLWithPath: file.path)) }
        }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
