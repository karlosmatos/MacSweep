import AppKit
import Observation
@preconcurrency import UserNotifications

/// Samples the Mac natively. Fast (2 s) while a MacSweep surface is visible, otherwise one cheap
/// tick per minute that only feeds the temperature graph, the low-disk check and the menu bar label.
@MainActor
@Observable
final class SystemMonitor {
    struct AppUsage: Identifiable {
        let group: String
        let name: String
        let value: Double // percent of one core, bytes, or share of energy
        var id: String { group }
    }

    enum Readout: String, CaseIterable { case none, temp, tempCPU }

    static let lowDiskBytes: Int64 = 25_000_000_000

    // Disk
    private(set) var diskFree: Int64 = 0
    private(set) var diskTotal: Int64 = 0
    private(set) var trash: Int64 = 0
    // CPU and heat
    private(set) var cpuPercent = 0
    private(set) var load = 0.0
    private(set) var temperature: Double?
    private(set) var temperatureHistory: [Double] = []
    private(set) var fanRPM: Int?
    private(set) var thermalState = ProcessInfo.processInfo.thermalState
    private(set) var cpuHighSince: Date?
    // Memory
    private(set) var memory: Sensors.Memory?
    // Battery
    private(set) var battery: Sensors.Battery?
    private(set) var drainSince: Date?
    // Network
    private(set) var downRate = 0.0
    private(set) var upRate = 0.0
    private(set) var ip: String?
    private(set) var interface: String?
    private(set) var vpn = false
    // System
    private(set) var bootDate = Sensors.bootDate()
    private(set) var processCount = 0
    // Per-app rankings (only computed while visible)
    private(set) var topCPU: [AppUsage] = []
    private(set) var topMemory: [AppUsage] = []
    private(set) var topDrain: [AppUsage] = []

    var readout: Readout = Readout(rawValue: UserDefaults.standard.string(forKey: "readout") ?? "") ?? .none {
        didSet { UserDefaults.standard.set(readout.rawValue, forKey: "readout"); reschedule() }
    }

    var lowDisk: Bool { diskTotal > 0 && diskFree < Self.lowDiskBytes }
    var overheating: Bool { thermalState == .serious || thermalState == .critical }
    var cpuAlert: Bool { cpuHighSince.map { Date().timeIntervalSince($0) > 60 } ?? false }

    private var visibleSurfaces = 0
    private var timer: Timer?
    private var lastTicks: Sensors.CPUTicks?
    private var lastNet: (date: Date, info: Sensors.NetworkInfo)?
    private var lastCPUByPID: [pid_t: UInt64] = [:]
    private var lastProcessSample: Date?
    private var energyBaseline: [pid_t: UInt64] = [:]
    private var pidsByGroup: [String: [pid_t]] = [:]
    private var lastHistoryAppend: Date?
    private var wasOnAC: Bool?

    init() {
        sampleCheap()
        NotificationCenter.default.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.thermalState = ProcessInfo.processInfo.thermalState }
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.sampleCheap() }
        }
        reschedule()
    }

    /// Call from onAppear / onDisappear of the popover and the main window.
    func setVisible(_ visible: Bool) {
        visibleSurfaces = max(visibleSurfaces + (visible ? 1 : -1), 0)
        if visible {
            sampleCheap()
            sampleProcesses()
            Task.detached(priority: .utility) {
                let size = Sensors.trashSize()
                await MainActor.run { self.trash = size }
            }
        }
        reschedule()
    }

    func refreshTrash() {
        Task.detached(priority: .utility) {
            let size = Sensors.trashSize()
            await MainActor.run { self.trash = size }
        }
    }

    /// Quits every process of an app (or the single executable) in a ranking.
    func quit(_ usage: AppUsage) {
        if usage.group.hasSuffix(".app"),
           let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleURL?.path == usage.group }) {
            app.terminate()
        } else {
            pidsByGroup[usage.group]?.forEach { kill($0, SIGTERM) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.sampleProcesses() }
    }

    // MARK: Scheduling

    private func reschedule() {
        timer?.invalidate()
        let interval: TimeInterval = visibleSurfaces > 0 ? 2 : readout != .none ? 5 : 60
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer?.tolerance = interval * 0.2
    }

    private func tick() {
        sampleCheap()
        if visibleSurfaces > 0 { sampleProcesses() }
    }

    // MARK: Sampling

    /// Microsecond-scale reads only.
    private func sampleCheap() {
        let now = Date()
        if let disk = Sensors.disk() {
            diskFree = disk.free
            diskTotal = disk.total
            notifyIfLowDisk()
        }
        if let ticks = Sensors.cpuTicks() {
            if let last = lastTicks, ticks.total > last.total {
                cpuPercent = Int((Double(ticks.busy - last.busy) / Double(ticks.total - last.total) * 100).rounded())
            }
            lastTicks = ticks
            cpuHighSince = cpuPercent >= 80 ? (cpuHighSince ?? now) : nil
        }
        load = Sensors.load()
        temperature = Sensors.cpuTemperature()
        if let temperature, now.timeIntervalSince(lastHistoryAppend ?? .distantPast) >= 59 {
            temperatureHistory = Array((temperatureHistory + [temperature]).suffix(30))
            lastHistoryAppend = now
        }
        memory = Sensors.memory()
        battery = Sensors.battery()
        trackUnplug(now)

        guard visibleSurfaces > 0 else { return }
        fanRPM = Sensors.fanRPM()
        let net = Sensors.network()
        if let last = lastNet {
            let seconds = max(now.timeIntervalSince(last.date), 0.5)
            downRate = Double(net.bytesIn &- last.info.bytesIn) / seconds
            upRate = Double(net.bytesOut &- last.info.bytesOut) / seconds
        }
        lastNet = (now, net)
        ip = net.ip
        interface = net.interface
        vpn = net.vpn
        bootDate = Sensors.bootDate()
    }

    /// One pass over all processes (~10 ms). Rankings are grouped per app bundle.
    private func sampleProcesses() {
        let now = Date()
        let samples = Sensors.processes()
        let elapsed = lastProcessSample.map { now.timeIntervalSince($0) } ?? 0
        processCount = samples.count

        var cpu: [String: Double] = [:], mem: [String: Double] = [:], energy: [String: Double] = [:]
        var pids: [String: [pid_t]] = [:]
        var cpuByPID: [pid_t: UInt64] = [:]
        for s in samples {
            pids[s.group, default: []].append(s.pid)
            cpuByPID[s.pid] = s.cpuNanos
            mem[s.group, default: 0] += Double(s.footprint)
            if elapsed > 0, let previous = lastCPUByPID[s.pid], s.cpuNanos >= previous {
                cpu[s.group, default: 0] += Double(s.cpuNanos - previous) / (elapsed * 1e9) * 100
            }
            if drainSince != nil {
                let base = energyBaseline[s.pid] ?? 0
                if s.energyNanojoules > base { energy[s.group, default: 0] += Double(s.energyNanojoules - base) }
            }
        }
        lastCPUByPID = cpuByPID
        lastProcessSample = now
        pidsByGroup = pids

        let me = Bundle.main.bundlePath
        func rank(_ values: [String: Double], limit: Int = 5, minimum: Double) -> [AppUsage] {
            values.filter { $0.value >= minimum && $0.key != me }
                .sorted { $0.value > $1.value }
                .prefix(limit)
                .map { AppUsage(group: $0.key, name: Sensors.displayName(forGroup: $0.key), value: $0.value) }
        }
        if elapsed > 0 { topCPU = rank(cpu, minimum: 0.5) }
        topMemory = rank(mem, minimum: 50_000_000)
        let totalEnergy = energy.values.reduce(0, +)
        topDrain = totalEnergy > 0 ? rank(energy.mapValues { $0 / totalEnergy * 100 }, limit: 4, minimum: 1) : []
    }

    /// Snapshots per-process energy when the Mac leaves the charger, so "what drains most"
    /// covers the whole time on battery, not just the last few seconds.
    private func trackUnplug(_ now: Date) {
        guard let battery else { return }
        defer { wasOnAC = battery.onAC }
        if battery.onAC {
            drainSince = nil
            energyBaseline = [:]
        } else if wasOnAC != false {
            // Just unplugged, or MacSweep started on battery.
            drainSince = now
            energyBaseline = Dictionary(Sensors.processes().map { ($0.pid, $0.energyNanojoules) }, uniquingKeysWith: { a, _ in a })
        }
    }

    // MARK: Notifications

    private func notifyIfLowDisk() {
        guard lowDisk else { return }
        let today = Calendar.current.startOfDay(for: Date())
        if let last = UserDefaults.standard.object(forKey: "lowDiskNotified") as? Date, last >= today { return }
        UserDefaults.standard.set(Date(), forKey: "lowDiskNotified")
        let free = diskFree
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = "Zbývá \(Format.gigabytes(free)) GB"
            content.body = "Klikni na MacSweep v menu baru a uvolni místo."
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "lowDisk", content: content, trigger: nil))
        }
    }
}
