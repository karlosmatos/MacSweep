import AppKit
import Observation

/// Drives the bundled disk-cleanup.sh: previews what it would free, runs it (on demand and weekly),
/// keeps a lifetime tally and remembers unticked categories in a skip file the script reads.
@MainActor
@Observable
final class Sweeper {
    struct Item: Identifiable, Equatable {
        let key: String
        let bytes: Int64
        var id: String { key }

        var title: String {
            switch key {
            case "caches": "Cache vývojářských nástrojů"
            case "app_caches": "Cache aplikací"
            case "xcode": "Xcode build data"
            case "homebrew": "Stažené balíčky Homebrew"
            case "logs": "Staré logy"
            case "codex": "Staré Codex konverzace"
            case "downloads": "Staré stažené soubory"
            case "node_modules": "Nepoužívané node_modules"
            default: key
            }
        }

        /// Lower-case form for "Čistím …".
        var progressName: String {
            switch key {
            case "xcode": "Xcode build data"
            case "codex": "Codex konverzace"
            default: title.prefix(1).lowercased() + title.dropFirst()
            }
        }

        var detail: String {
            switch key {
            case "caches": "npm, bun, uv, prisma, Docker build"
            case "app_caches": "Chrome, Spotify. Vytvoří se znovu."
            case "xcode": "Další build bude jednou pomalejší"
            case "homebrew": "Instalační soubory starých verzí"
            case "logs": "Starší než 30 dní"
            case "codex": "Starší než 30 dní"
            case "downloads": "Starší než 60 dní. Půjdou do Koše."
            case "node_modules": "Projekty bez změny 30+ dní"
            default: ""
            }
        }

        var icon: String {
            switch key {
            case "caches": "shippingbox"
            case "app_caches": "square.stack.3d.up"
            case "xcode": "hammer"
            case "homebrew": "mug"
            case "logs": "doc.text"
            case "codex": "bubble.left.and.text.bubble.right"
            case "downloads": "arrow.down.circle"
            case "node_modules": "folder"
            default: "doc"
            }
        }
    }

    enum Phase: Equatable { case idle, running, done(freed: Int64, trashed: Bool), failed(String) }

    private static let home = FileManager.default.homeDirectoryForCurrentUser.path
    /// Bundled with the app; the repo copy is the fallback for `swift run`.
    private static let script = Bundle.main.path(forResource: "disk-cleanup", ofType: "sh") ?? home + "/.local/bin/disk-cleanup.sh"
    private static let skipFile = home + "/.config/disk-cleanup/skip"

    var items: [Item] = []
    var scanning = false
    var phase: Phase = .idle
    var current: String?
    private(set) var autoEnabled = UserDefaults.standard.bool(forKey: "autoSweep")
    private(set) var skipped: Set<String> = Sweeper.loadSkipped()
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

    /// Rescans at most every 5 minutes; called whenever the popover opens. Old results stay visible meanwhile.
    func refresh() {
        if scanning || phase == .running { return }
        if let lastScan, Date().timeIntervalSince(lastScan) < 300 { return }
        scan()
    }

    func scan() {
        scanning = true
        Task {
            let output = (try? await ProcessRunner.output("/usr/bin/nice", ["-n", "10", "/bin/bash", Self.script, "--dry-run"])) ?? ""
            items = output.split(separator: "\n").compactMap { line in
                let parts = line.split(separator: "\t")
                guard parts.count == 2, let bytes = Int64(parts[1]) else { return nil }
                return Item(key: String(parts[0]), bytes: bytes)
            }
            lastScan = Date()
            scanning = false
        }
    }

    func sweep() {
        let before = Sensors.disk()?.free ?? 0
        let trashed = selectedItems.contains { $0.key == "downloads" }
        let progress = FileManager.default.temporaryDirectory.appendingPathComponent("macsweep-progress")
        try? "".write(to: progress, atomically: true, encoding: .utf8)
        phase = .running
        current = selectedItems.first?.key
        Task {
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
            current = nil
            let freed = max((Sensors.disk()?.free ?? before) - before, 0)
            if status == 0 {
                record(freed)
                phase = .done(freed: freed, trashed: trashed)
            } else {
                phase = .failed("Úklid skončil s chybou (kód \(status)).")
            }
            scan()
        }
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

    private static func loadSkipped() -> Set<String> {
        let text = (try? String(contentsOfFile: skipFile, encoding: .utf8)) ?? ""
        return Set(text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
    }

    private func saveSkipped() {
        let url = URL(fileURLWithPath: Self.skipFile)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? (skipped.sorted().joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
    }
}
