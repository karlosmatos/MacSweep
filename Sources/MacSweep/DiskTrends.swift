import AppKit
import Observation
@preconcurrency import UserNotifications

/// Free space once an hour for 30 days. Feeds the sidebar graph and the "runs out in N days" forecast.
@MainActor
@Observable
final class DiskHistory {
    struct Sample: Codable, Equatable {
        let date: Date
        let free: Int64
    }

    private static let key = "diskHistory"
    private static let keep: TimeInterval = 30 * 86_400

    private(set) var samples: [Sample] = {
        guard let data = UserDefaults.standard.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([Sample].self, from: data)) ?? []
    }()

    func record(_ free: Int64, at now: Date = Date()) {
        if let last = samples.last, now.timeIntervalSince(last.date) < 3_600 { return }
        samples = (samples + [Sample(date: now, free: free)]).filter { now.timeIntervalSince($0.date) < Self.keep }
        UserDefaults.standard.set(try? JSONEncoder().encode(samples), forKey: Self.key)
    }

    /// Change of free space in bytes per day over the last 14 days (least squares);
    /// nil until there are 3 days of data.
    static func trend(_ samples: [Sample], now: Date = Date()) -> Double? {
        let recent = samples.filter { now.timeIntervalSince($0.date) < 14 * 86_400 }
        guard let first = recent.first, let last = recent.last,
              last.date.timeIntervalSince(first.date) >= 3 * 86_400 else { return nil }
        let xs = recent.map { $0.date.timeIntervalSince(first.date) / 86_400 }
        let ys = recent.map { Double($0.free) }
        let mx = xs.reduce(0, +) / Double(xs.count), my = ys.reduce(0, +) / Double(ys.count)
        let sxx = zip(xs, xs).reduce(0) { $0 + ($1.0 - mx) * ($1.1 - mx) }
        let sxy = zip(xs, ys).reduce(0) { $0 + ($1.0 - mx) * ($1.1 - my) }
        return sxx > 0 ? sxy / sxx : nil
    }

    /// Whole days until free space reaches zero, when it shrinks by at least 0.5 GB a day.
    static func daysLeft(free: Int64, perDay: Double?) -> Int? {
        guard let perDay, perDay <= -500_000_000 else { return nil }
        return Int(Double(free) / -perDay)
    }

    var perDay: Double? { Self.trend(samples) }
}

/// Once a day measures the folders two levels under the home folder and flags the ones that grew
/// by 5 GB or more since the day before: a runaway log, a VM image, a sync gone wrong.
@MainActor
@Observable
final class FolderGrowth {
    struct Growth: Identifiable, Equatable {
        let path: String
        let bytes: Int64
        var id: String { path }
    }

    nonisolated static let threshold: Int64 = 5_000_000_000
    private static let home = FileManager.default.homeDirectoryForCurrentUser.path
    private static let file = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("MacSweep/folders.json")

    private struct Snapshot: Codable {
        let date: Date
        let sizes: [String: Int64]
    }

    private(set) var grown: [Growth] = []
    private var measuring = false

    init() {
        Task { [weak self] in
            while true {
                try? await Task.sleep(for: .seconds(300))
                await self?.measureIfDue()
                try? await Task.sleep(for: .seconds(3_300))
            }
        }
    }

    func dismiss() { grown = [] }

    private func measureIfDue() async {
        let previous = Self.load()
        guard !measuring, Date().timeIntervalSince(previous?.date ?? .distantPast) > 20 * 3_600 else { return }
        measuring = true
        defer { measuring = false }
        let output = (try? await ProcessRunner.output("/usr/bin/nice", ["-n", "20", "/usr/bin/du", "-k", "-d", "2", Self.home])) ?? ""
        let sizes = Self.parse(output)
        guard !sizes.isEmpty else { return }
        Self.save(Snapshot(date: Date(), sizes: sizes))
        guard let previous else { return }
        grown = Self.growth(from: previous.sizes, to: sizes)
        if let top = grown.first { notify(top) }
    }

    /// `du -k` lines ("<KiB>\t<path>") as bytes per path.
    static func parse(_ output: String) -> [String: Int64] {
        var sizes: [String: Int64] = [:]
        for line in output.split(separator: "\n") {
            let parts = line.split(separator: "\t", maxSplits: 1)
            guard parts.count == 2, let kib = Int64(parts[0]) else { continue }
            sizes[String(parts[1])] = kib * 1024
        }
        return sizes
    }

    /// Folders that grew past the threshold, biggest first. A parent is left out when a folder
    /// inside it already explains the growth, so the most specific folder is named.
    static func growth(from old: [String: Int64], to new: [String: Int64], threshold: Int64 = threshold) -> [Growth] {
        let grown = new.compactMap { path, size -> Growth? in
            let delta = size - (old[path] ?? 0)
            return delta >= threshold ? Growth(path: path, bytes: delta) : nil
        }
        return grown
            .filter { parent in !grown.contains { $0.path.hasPrefix(parent.path + "/") } }
            .sorted { $0.bytes > $1.bytes }
    }

    private func notify(_ growth: Growth) {
        let name = (growth.path as NSString).abbreviatingWithTildeInPath
        let title = String(localized: "\(name) narostla o \(Format.bytes(growth.bytes))")
        let body = String(localized: "Za poslední den. Klikni na MacSweep v menu baru.")
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "folderGrowth", content: content, trigger: nil))
        }
    }

    private static func load() -> Snapshot? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        return try? JSONDecoder().decode(Snapshot.self, from: data)
    }

    private static func save(_ snapshot: Snapshot) {
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(snapshot).write(to: file, options: .atomic)
    }
}
