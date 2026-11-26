import SwiftUI

enum Vital: String, CaseIterable, Identifiable {
    case temperature, cpu, memory, battery, network, uptime
    var id: String { rawValue }
}

/// Six live readings. Each opens a detail with something to act on.
struct VitalsGrid: View {
    @Environment(SystemMonitor.self) private var monitor
    @Binding var open: Vital?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Stav Macu").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) {
                ForEach(Vital.allCases.filter(isAvailable)) { vital in
                    let reading = reading(vital)
                    Button { open = open == vital ? nil : vital } label: {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(reading.label).font(.system(size: 11)).foregroundStyle(.secondary)
                            Text(reading.value).font(Theme.number(15)).foregroundStyle(reading.tint ?? .primary)
                                .contentTransition(.numericText())
                            Text(reading.detail).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 9).padding(.vertical, 8)
                        .background(open == vital ? Theme.fill : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(open == vital ? Theme.accent : Theme.hairline))
                    }
                    .buttonStyle(PressableStyle())
                    .accessibilityLabel("\(reading.label) \(reading.value), \(reading.detail)")
                }
            }
        }
    }

    private func isAvailable(_ vital: Vital) -> Bool {
        switch vital {
        case .temperature: monitor.temperature != nil
        case .battery: monitor.battery != nil
        default: true
        }
    }

    private struct Reading { let label: String; let value: String; let detail: String; var tint: Color? = nil }

    private func reading(_ vital: Vital) -> Reading {
        switch vital {
        case .temperature:
            let t = monitor.temperature ?? 0
            let fan = monitor.fanRPM.map { $0 > 0 ? String(localized: "Ventilátor \($0.formatted())") : String(localized: "Ventilátor stojí") } ?? String(localized: "Bez ventilátoru")
            return Reading(label: String(localized: "Teplota CPU"), value: "\(Int(t.rounded())) °C", detail: fan,
                           tint: t >= 95 ? Theme.danger : t >= 85 ? Theme.warn : nil)
        case .cpu:
            return Reading(label: String(localized: "Procesor"), value: "\(monitor.cpuPercent) %",
                           detail: String(localized: "Zátěž \(monitor.load.formatted(.number.precision(.fractionLength(1)))) z \(Sensors.coreCount)"),
                           tint: monitor.cpuAlert ? Theme.warn : nil)
        case .memory:
            let mem = monitor.memory
            let swap = mem.map { $0.swap > 0 ? "swap \(Format.bytes($0.swap))" : "swap 0" } ?? ""
            return Reading(label: String(localized: "Paměť"), value: "\(Format.memoryGB(mem?.used ?? 0)) GB",
                           detail: String(localized: "z \(Format.memoryGB(mem?.total ?? 0)), \(swap)"),
                           tint: (mem?.pressure ?? 0) > 80 ? Theme.warn : nil)
        case .battery:
            let b = monitor.battery
            let detail = b.map { b in
                if b.charging { return String(localized: "Nabíjí se") }
                if b.onAC { return String(localized: "Na nabíječce") }
                return b.minutesLeft.map { String(localized: "\("\($0 / 60):\(String(format: "%02d", $0 % 60))") zbývá") } ?? String(localized: "Počítám…")
            } ?? ""
            return Reading(label: String(localized: "Baterie"), value: "\(b?.percent ?? 0) %", detail: detail,
                           tint: (b?.percent ?? 100) <= 15 && b?.onAC == false ? Theme.danger : nil)
        case .network:
            return Reading(label: String(localized: "Síť"), value: Format.rate(monitor.downRate), detail: monitor.interface ?? String(localized: "Offline"))
        case .uptime:
            return Reading(label: String(localized: "Zapnuto"), value: Format.duration(since: monitor.bootDate), detail: String(localized: "\(monitor.processCount) procesů"))
        }
    }
}

struct VitalDetail: View {
    @Environment(SystemMonitor.self) private var monitor
    let vital: Vital

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            switch vital {
            case .temperature: temperature
            case .cpu: UsageList(items: monitor.topCPU, empty: "Nic teď procesor nezatěžuje.") { "\(Int($0.rounded())) %" }
            case .memory:
                UsageList(items: monitor.topMemory, empty: "Žádná aplikace nebere přes 50 MB.") { Format.bytes(Int64($0)) }
                KeyValue("Tlak na paměť", pressureText)
            case .battery: battery
            case .network: network
            case .uptime: uptime
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(Theme.fill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    @ViewBuilder
    private var temperature: some View {
        let history = monitor.temperatureHistory
        HStack {
            Text("Posledních \(max(history.count, 1)) min").font(.caption.weight(.semibold))
            Spacer()
            if let max = history.max() { Text("max \(Int(max.rounded())) °C").font(.caption).foregroundStyle(.secondary) }
        }
        Sparkline(values: history, ceiling: 100).frame(height: 56)
        if let rpm = monitor.fanRPM { KeyValue("Ventilátor", rpm > 0 ? String(localized: "\(rpm.formatted()) ot./min") : String(localized: "Stojí")) }
        KeyValue("Omezení výkonu", throttleText)
        if let top = monitor.topCPU.first { KeyValue("Nejvíc topí", top.name) }
    }

    @ViewBuilder
    private var battery: some View {
        if let b = monitor.battery {
            if let since = monitor.drainSince {
                HStack {
                    Text("Nejvíc vybíjí").font(.caption.weight(.semibold))
                    Spacer()
                    Text("od odpojení před \(Format.duration(since: since))").font(.caption).foregroundStyle(.secondary)
                }
                UsageList(items: monitor.topDrain, empty: "Zatím málo dat, zkus to za pár minut.") { "\(Int($0.rounded())) %" }
                    .padding(.bottom, 4)
            } else {
                Text("Pořadí aplikací podle spotřeby se začne počítat po odpojení nabíječky.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if let health = b.healthPercent { KeyValue("Kapacita", String(localized: "\(health) % původní")) }
            if let cycles = b.cycles { KeyValue("Cykly nabití", String(localized: "\(cycles) z 1000")) }
            if let watts = b.watts, !b.onAC { KeyValue("Odběr teď", "\(watts.formatted(.number.precision(.fractionLength(1)))) W") }
            if let temp = b.temperature { KeyValue("Teplota baterie", "\(Int(temp.rounded())) °C") }
        }
    }

    @ViewBuilder
    private var network: some View {
        KeyValue("Stahování", Format.rate(monitor.downRate))
        KeyValue("Odesílání", Format.rate(monitor.upRate))
        KeyValue("Připojení", monitor.interface ?? String(localized: "Žádné"))
        if let ip = monitor.ip { KeyValue("Lokální IP", ip) }
        KeyValue("VPN nebo tunel", monitor.vpn ? String(localized: "Zapnuto") : String(localized: "Vypnuto"))
    }

    @ViewBuilder
    private var uptime: some View {
        if let boot = monitor.bootDate {
            KeyValue("Poslední restart", boot.formatted(.relative(presentation: .named)))
        }
        KeyValue("Procesy", "\(monitor.processCount)")
        Text("Po 14 dnech bez restartu tady MacSweep restart doporučí.")
            .font(.caption).foregroundStyle(.secondary)
    }

    private var pressureText: String {
        let p = monitor.memory?.pressure ?? 0
        return p > 80 ? String(localized: "Vysoký") : p > 60 ? String(localized: "Střední") : String(localized: "Nízký")
    }

    private var throttleText: String {
        switch monitor.thermalState {
        case .nominal: String(localized: "Žádné")
        case .fair: String(localized: "Mírné")
        case .serious: String(localized: "Výkon je snížený")
        case .critical: String(localized: "Silné")
        @unknown default: String(localized: "Neznámé")
        }
    }
}

/// Ranked apps with a hover-revealed quit button.
struct UsageList: View {
    @Environment(SystemMonitor.self) private var monitor
    let items: [SystemMonitor.AppUsage]
    let empty: LocalizedStringKey
    let format: (Double) -> String

    var body: some View {
        if items.isEmpty {
            Text(empty).font(.caption).foregroundStyle(.secondary)
        } else {
            VStack(spacing: 0) {
                ForEach(items) { item in UsageRow(item: item, value: format(item.value)) { monitor.quit(item) } }
            }
        }
    }
}

private struct UsageRow: View {
    let item: SystemMonitor.AppUsage
    let value: String
    let quit: () -> Void
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 8) {
            AppIcon(path: item.group.hasSuffix(".app") ? item.group : nil, name: item.name, size: 16)
            Text(item.name).font(.system(size: 12)).lineLimit(1)
            Spacer()
            if hovered { QuitButton(action: quit) }
            Text(value).font(Theme.number(12, weight: .regular)).foregroundStyle(.secondary)
        }
        .frame(height: 26)
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
    }
}

struct KeyValue: View {
    let key: LocalizedStringKey
    let value: String
    init(_ key: LocalizedStringKey, _ value: String) { self.key = key; self.value = value }

    var body: some View {
        HStack {
            Text(key).foregroundStyle(.secondary)
            Spacer()
            Text(value).fontWeight(.medium)
        }
        .font(.system(size: 12))
        .monospacedDigit()
    }
}

/// Minimal line chart with an 80 °C reference line.
struct Sparkline: View {
    let values: [Double]
    let ceiling: Double

    var body: some View {
        GeometryReader { geo in
            let floor = min(values.min() ?? 30, 30)
            let span = max(ceiling - floor, 1)
            let y = { (v: Double) in geo.size.height * (1 - CGFloat((v - floor) / span)) }
            ZStack(alignment: .topTrailing) {
                Path { p in
                    p.move(to: CGPoint(x: 0, y: y(80)))
                    p.addLine(to: CGPoint(x: geo.size.width, y: y(80)))
                }
                .stroke(Theme.hairline, style: StrokeStyle(lineWidth: 1, dash: [3, 4]))
                Text("80 °C").font(.system(size: 9)).foregroundStyle(.secondary).offset(y: y(80) - 12)
                if values.count > 1 {
                    Path { p in
                        for (i, v) in values.enumerated() {
                            let point = CGPoint(x: geo.size.width * CGFloat(i) / CGFloat(values.count - 1), y: y(v))
                            i == 0 ? p.move(to: point) : p.addLine(to: point)
                        }
                    }
                    .stroke(Theme.accent, style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
                } else {
                    Text("Graf se plní jednou za minutu.").font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .accessibilityLabel("Teplota CPU za posledních \(values.count) minut")
    }
}
