import AppKit
import Observation

/// Drives the bundled disk-cleanup.sh: previews what it would free, runs it (on demand and weekly),
/// keeps a lifetime tally and remembers unticked categories, unticked paths and project folders in files the script reads.
@MainActor
@Observable
final class Sweeper {
    /// One instance for the app and its Shortcuts actions.
    static let shared = Sweeper()

    struct Item: Identifiable, Equatable {
        let key: String
        let bytes: Int64
        var id: String { key }

        var title: String {
            switch key {
            case "caches": "Cache vývojářských nástrojů"
            case "app_caches": "Cache aplikací"
            case "docker": "Docker build cache"
            case "xcode": "Xcode build data"
            case "simulators": "Simulátory a symboly zařízení"
            case "homebrew": "Stažené balíčky Homebrew"
            case "logs": "Staré logy"
            case "codex": "Staré Codex konverzace"
            case "downloads": "Staré stažené soubory"
            case "node_modules": "Závislosti nečinných projektů"
            default: key
            }
        }

        /// Lower-case form for "Čistím …".
        var progressName: String {
            switch key {
            case "xcode": "Xcode build data"
            case "docker": "Docker build cache"
            case "codex": "Codex konverzace"
            case "simulators": "simulátory a symboly zařízení"
            default: title.prefix(1).lowercased() + title.dropFirst()
            }
        }

        var detail: String {
            switch key {
            case "caches": "npm, pip, yarn, Go, Gradle, Cargo…"
            case "app_caches": "Prohlížeče a aplikace. Vytvoří se znovu."
            case "docker": "Další build bude pomalejší"
            case "xcode": "Další build bude jednou pomalejší"
            case "simulators": "Staré verze iOS. Stáhnou se znovu."
            case "homebrew": "Instalační soubory starých verzí"
            case "logs": "Starší než 30 dní"
            case "codex": "Starší než 30 dní"
            case "downloads": "Starší než 60 dní. Půjdou do Koše."
            case "node_modules": "node_modules, venv… Bez změny 30+ dní"
            default: ""
            }
        }

        var icon: String {
            switch key {
            case "caches": "shippingbox"
            case "app_caches": "square.stack.3d.up"
            case "docker": "cube"
            case "xcode": "hammer"
            case "simulators": "iphone"
            case "homebrew": "mug"
            case "logs": "doc.text"
            case "codex": "bubble.left.and.text.bubble.right"
            case "downloads": "arrow.down.circle"
            case "node_modules": "folder"
            default: "doc"
            }
        }

        /// Path-based categories can list their items; Docker and Homebrew clean themselves.
        var expandable: Bool { key != "docker" && key != "homebrew" }
    }

    /// One item of a category, from the script's --list.
    struct Detail: Identifiable, Equatable {
        let path: String
        let bytes: Int64
        var id: String { path }
    }

    enum Phase: Equatable { case idle, running, done(freed: Int64, trashed: Bool), failed(String) }

    private static let home = FileManager.default.homeDirectoryForCurrentUser.path
    /// Bundled with the app; the repo copy is the fallback for `swift run`.
    private static let script = Bundle.main.path(forResource: "disk-cleanup", ofType: "sh") ?? home + "/.local/bin/disk-cleanup.sh"
    private static let skipFile = home + "/.config/disk-cleanup/skip"
    private static let projectsFile = home + "/.config/disk-cleanup/projects"
    private static let excludeFile = home + "/.config/disk-cleanup/exclude"
    /// Usual places for code; the ones that exist become the starting list of project folders.
    private static let defaultProjectFolders = ["Github", "GitHub", "Developer", "Projects", "Code", "dev", "src", "repos"]
        .map { home + "/" + $0 }

    var items: [Item] = []
    var scanning = false
    var phase: Phase = .idle
    var current: String?
    private(set) var autoEnabled = UserDefaults.standard.bool(forKey: "autoSweep")
    private(set) var skipped: Set<String> = Sweeper.loadLines(skipFile)
    /// Single paths the user unticked inside a category.
    private(set) var excluded: Set<String> = Sweeper.loadLines(excludeFile)
    /// Items per category, loaded when a category is expanded; cleared by every scan.
    private(set) var details: [String: [Detail]] = [:]
    /// Folders searched for stale node_modules.
    private(set) var projectFolders: [String] = Sweeper.loadProjectFolders()
    private(set) var totalReclaimed = Int64(UserDefaults.standard.integer(forKey: "reclaimedTotal"))
    private(set) var since = UserDefaults.standard.object(forKey: "reclaimedSince") as? Date
    private(set) var lastScan: Date?

    /// Items worth showing (1 MB+), biggest first.
    var visibleItems: [Item] { items.filter { $0.bytes >= 1_000_000 }.sorted { $0.bytes > $1.bytes } }
    var selectedItems: [Item] { visibleItems.filter { !skipped.contains($0.key) } }
    var reclaimable: Int64 { selectedItems.reduce(0) { $0 + $1.bytes } }
    var maxReclaimable: Int64 { visibleItems.reduce(0) { $0 + $1.bytes } }

    func isSelected(_ item: Item) -> Bool { !skipped.contains(item.key) }

    func toggle(_ item: Item) {
        if skipped.contains(item.key) { skipped.remove(item.key) } else { skipped.insert(item.key) }
        saveSkipped()
    }

    func isExcluded(_ detail: Detail) -> Bool { excluded.contains(detail.path) }

    /// Ticks or unticks one path, then rescans so the category total follows.
    func toggleExcluded(_ detail: Detail) {
        if excluded.contains(detail.path) { excluded.remove(detail.path) } else { excluded.insert(detail.path) }
        Self.writeLines(excluded.sorted(), to: Self.excludeFile)
        lastScan = nil
        scan()
    }

    func loadDetails(_ key: String) async {
        let output = (try? await ProcessRunner.output("/usr/bin/nice", ["-n", "10", "/bin/bash", Self.script, "--list", key])) ?? ""
        details[key] = Self.parseList(output)
    }

    /// Lines of "<bytes>\t<path>" from the script's --list, biggest first.
    static func parseList(_ output: String) -> [Detail] {
        output.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "\t", maxSplits: 1)
            guard parts.count == 2, let bytes = Int64(parts[0]) else { return nil }
            return Detail(path: String(parts[1]), bytes: bytes)
        }
        .sorted { $0.bytes > $1.bytes }
    }

    func addProjectFolders(_ urls: [URL]) {
        projectFolders = Array(Set(projectFolders + urls.map(\.path))).sorted()
        saveProjectFolders()
    }

    func removeProjectFolder(_ path: String) {
        projectFolders.removeAll { $0 == path }
        saveProjectFolders()
    }

    /// Rescans at most every 5 minutes; called whenever the popover opens. Old results stay visible meanwhile.
    func refresh() {
        if scanning || phase == .running { return }
        if let lastScan, Date().timeIntervalSince(lastScan) < 300 { return }
        scan()
    }

    func scan() {
        Task { await scanNow() }
    }

    private func scanNow() async {
        scanning = true
        let output = (try? await ProcessRunner.output("/usr/bin/nice", ["-n", "10", "/bin/bash", Self.script, "--dry-run"])) ?? ""
        items = Self.parseScan(output)
        details = [:]
        lastScan = Date()
        scanning = false
    }

    /// Lines of "<category>\t<bytes>" from the script's --dry-run.
    static func parseScan(_ output: String) -> [Item] {
        output.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "\t")
            guard parts.count == 2, let bytes = Int64(parts[1]) else { return nil }
            return Item(key: String(parts[0]), bytes: bytes)
        }
    }

    /// What the swept categories shrank by. Downloads only move to the Trash, so they free nothing yet.
    static func freed(before: [Item], after: [Item], swept: Set<String>) -> Int64 {
        let remaining = Dictionary(after.map { ($0.key, $0.bytes) }, uniquingKeysWith: { $1 })
        return before.filter { swept.contains($0.key) && $0.key != "downloads" }
            .reduce(0) { $0 + max($1.bytes - (remaining[$1.key] ?? 0), 0) }
    }

    func sweep() {
        Task { await sweepAndWait() }
    }

    /// Sweeps the ticked categories and returns the bytes freed; nil when it failed or one was already running.
    /// Scans first when nothing has been scanned yet (a Shortcuts run right after launch).
    @discardableResult
    func sweepAndWait() async -> Int64? {
        guard phase != .running else { return nil }
        if lastScan == nil { await scanNow() }
        let before = items
        let swept = Set(selectedItems.map(\.key))
        let trashed = swept.contains("downloads")
        let progress = FileManager.default.temporaryDirectory.appendingPathComponent("macsweep-progress")
        try? "".write(to: progress, atomically: true, encoding: .utf8)
        phase = .running
        current = selectedItems.first?.key
        let poll = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(300))
                let key = (try? String(contentsOf: progress, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
                if let key, !key.isEmpty { current = key }
            }
        }
        let runner = ProcessRunner("/usr/bin/env", ["DISK_CLEANUP_NO_REPORT=1", "DISK_CLEANUP_PROGRESS=\(progress.path)", "/bin/bash", Self.script])
        let status = (try? await runner.run().status) ?? -1
        poll.cancel()
        await scanNow()
        current = nil
        guard status == 0 else {
            phase = .failed(String(localized: "Úklid skončil s chybou (kód \(status))."))
            return nil
        }
        let freed = Self.freed(before: before, after: items, swept: swept)
        record(freed)
        phase = .done(freed: freed, trashed: trashed)
        return freed
    }

    func dismissResult() { phase = .idle }

    // MARK: Weekly run (Sunday 10:00), kept in the app so there is no LaunchAgent to install.

    init() {
        migrateLegacyAgent()
        Task { [weak self] in
            while true {
                try? await Task.sleep(for: .seconds(60))
                self?.sweepIfDue()
                try? await Task.sleep(for: .seconds(3540))
            }
        }
    }

    func setAuto(_ enabled: Bool) {
        autoEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "autoSweep")
        // Counting from now, so switching it on midweek doesn't start a sweep right away.
        if enabled { UserDefaults.standard.set(Date(), forKey: "lastAutoSweep") }
    }

    /// Catches up after sleep or a day the app wasn't running, like launchd's calendar jobs.
    private func sweepIfDue() {
        guard autoEnabled, phase != .running,
              let due = Calendar.current.nextDate(after: Date(), matching: DateComponents(hour: 10, minute: 0, weekday: 1),
                                                  matchingPolicy: .nextTime, direction: .backward)
        else { return }
        let last = UserDefaults.standard.object(forKey: "lastAutoSweep") as? Date ?? .distantPast
        guard last < due else { return }
        UserDefaults.standard.set(Date(), forKey: "lastAutoSweep")
        sweep()
    }

    /// Earlier builds ran the weekly job from ~/Library/LaunchAgents; carry its on/off state over and remove it.
    private func migrateLegacyAgent() {
        let label = "com.karel.disk-cleanup"
        let plist = URL(fileURLWithPath: Self.home + "/Library/LaunchAgents/\(label).plist")
        guard FileManager.default.fileExists(atPath: plist.path) else { return }
        Task {
            let target = "gui/\(getuid())/\(label)"
            let loaded = (try? await ProcessRunner("/bin/launchctl", ["print", target]).run().status) == 0
            setAuto(loaded)
            if loaded { _ = try? await ProcessRunner("/bin/launchctl", ["bootout", target]).run() }
            try? FileManager.default.trashItem(at: plist, resultingItemURL: nil)
        }
    }

    static func openLog() {
        NSWorkspace.shared.open(URL(fileURLWithPath: home + "/Library/Logs/disk-cleanup/cleanup.log"))
    }

    private func record(_ freed: Int64) {
        totalReclaimed += freed
        if since == nil { since = Date() }
        UserDefaults.standard.set(Int(totalReclaimed), forKey: "reclaimedTotal")
        UserDefaults.standard.set(since, forKey: "reclaimedSince")
    }

    private static func loadLines(_ path: String) -> Set<String> {
        let text = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        return Set(text.split(separator: "\n").map(String.init).filter { !$0.isEmpty })
    }

    private func saveSkipped() {
        Self.writeLines(skipped.sorted(), to: Self.skipFile)
    }

    /// The saved list; on first launch the default folders that exist, saved so the script sees them too.
    private static func loadProjectFolders() -> [String] {
        if let text = try? String(contentsOfFile: projectsFile, encoding: .utf8) {
            return text.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
        }
        // Compare canonical paths: on a case-insensitive disk ~/Github and ~/GitHub are the same folder.
        var seen = Set<String>()
        let found = defaultProjectFolders.filter { path in
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else { return false }
            return seen.insert(URL(fileURLWithPath: path).resolvingSymlinksInPath().standardized.path.lowercased()).inserted
        }
        writeLines(found, to: projectsFile)
        return found
    }

    private func saveProjectFolders() {
        Self.writeLines(projectFolders, to: Self.projectsFile)
        lastScan = nil
        scan()
    }

    private static func writeLines(_ lines: [String], to path: String) {
        let url = URL(fileURLWithPath: path)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? (lines.map { $0 + "\n" }.joined()).write(to: url, atomically: true, encoding: .utf8)
    }
}
