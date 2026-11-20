import AppKit
import CoreWLAN
import Darwin
import IOKit
import IOKit.ps

/// Low-level, allocation-light system readers. Every call is cheap (microseconds to a few ms)
/// and safe to run off the main thread.
enum Sensors {
    // MARK: Disk

    static func disk() -> (free: Int64, total: Int64)? {
        let keys: Set<URLResourceKey> = [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey]
        guard let values = try? URL(fileURLWithPath: "/").resourceValues(forKeys: keys),
              let free = values.volumeAvailableCapacityForImportantUsage,
              let total = values.volumeTotalCapacity else { return nil }
        return (free, Int64(total))
    }

    // MARK: Memory

    struct Memory { let used: Int64; let total: Int64; let swap: Int64; let pressure: Int }

    static func memory() -> Memory? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        let page = Int64(vm_kernel_page_size)
        // Matches Activity Monitor's "Memory Used": app memory + wired + compressed.
        let app = Int64(stats.internal_page_count) - Int64(stats.purgeable_count)
        let used = (app + Int64(stats.wire_count) + Int64(stats.compressor_page_count)) * page

        var swap = xsw_usage()
        var swapSize = MemoryLayout<xsw_usage>.size
        sysctlbyname("vm.swapusage", &swap, &swapSize, nil, 0)

        var level: Int32 = 0
        var levelSize = MemoryLayout<Int32>.size
        sysctlbyname("kern.memorystatus_level", &level, &levelSize, nil, 0)

        return Memory(used: used, total: Int64(ProcessInfo.processInfo.physicalMemory),
                      swap: Int64(swap.xsu_used), pressure: 100 - Int(level))
    }

    // MARK: CPU

    struct CPUTicks { let busy: UInt64; let total: UInt64 }

    static func cpuTicks() -> CPUTicks? {
        var count: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &count, &info, &infoCount) == KERN_SUCCESS,
              let info else { return nil }
        defer { vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info), vm_size_t(infoCount) * vm_size_t(MemoryLayout<integer_t>.stride)) }
        var busy: UInt64 = 0, total: UInt64 = 0
        for cpu in 0..<Int(count) {
            let base = cpu * Int(CPU_STATE_MAX)
            let user = UInt64(info[base + Int(CPU_STATE_USER)]), system = UInt64(info[base + Int(CPU_STATE_SYSTEM)])
            let nice = UInt64(info[base + Int(CPU_STATE_NICE)]), idle = UInt64(info[base + Int(CPU_STATE_IDLE)])
            busy += user + system + nice
            total += user + system + nice + idle
        }
        return CPUTicks(busy: busy, total: total)
    }

    static func load() -> Double {
        var loads = [Double](repeating: 0, count: 3)
        return getloadavg(&loads, 3) > 0 ? loads[0] : 0
    }

    static let coreCount = ProcessInfo.processInfo.activeProcessorCount

    // MARK: Uptime

    static func bootDate() -> Date? {
        var boot = timeval()
        var size = MemoryLayout<timeval>.size
        guard sysctlbyname("kern.boottime", &boot, &size, nil, 0) == 0 else { return nil }
        return Date(timeIntervalSince1970: Double(boot.tv_sec))
    }

    // MARK: Temperature (Apple Silicon HID sensors, private but stable since M1)

    private typealias ClientCreate = @convention(c) (CFAllocator?) -> Unmanaged<AnyObject>?
    private typealias ClientSetMatching = @convention(c) (AnyObject, CFDictionary) -> Int32
    private typealias ClientCopyServices = @convention(c) (AnyObject) -> Unmanaged<CFArray>?
    private typealias ServiceCopyEvent = @convention(c) (AnyObject, Int64, Int32, Int64) -> Unmanaged<AnyObject>?
    private typealias ServiceCopyProperty = @convention(c) (AnyObject, CFString) -> Unmanaged<CFString>?
    private typealias EventGetFloat = @convention(c) (AnyObject, Int32) -> Double

    private struct HID {
        let copyEvent: ServiceCopyEvent
        let getFloat: EventGetFloat
        let client: AnyObject // services stay valid only while their client lives
        let cpuSensors: [AnyObject]
    }

    private static let hid: HID? = {
        guard let handle = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW) else { return nil }
        func sym<T>(_ name: String) -> T? { dlsym(handle, name).map { unsafeBitCast($0, to: T.self) } }
        guard let create: ClientCreate = sym("IOHIDEventSystemClientCreate"),
              let setMatching: ClientSetMatching = sym("IOHIDEventSystemClientSetMatching"),
              let copyServices: ClientCopyServices = sym("IOHIDEventSystemClientCopyServices"),
              let copyEvent: ServiceCopyEvent = sym("IOHIDServiceClientCopyEvent"),
              let copyProperty: ServiceCopyProperty = sym("IOHIDServiceClientCopyProperty"),
              let getFloat: EventGetFloat = sym("IOHIDEventGetFloatValue"),
              let client = create(kCFAllocatorDefault)?.takeRetainedValue() else { return nil }
        _ = setMatching(client, ["PrimaryUsagePage": 0xff00, "PrimaryUsage": 5] as CFDictionary)
        let services = (copyServices(client)?.takeRetainedValue() as? [AnyObject]) ?? []
        // Performance and efficiency core clusters.
        let cpu = services.filter { service in
            let name = copyProperty(service, "Product" as CFString)?.takeRetainedValue() as String? ?? ""
            return name.hasPrefix("pACC MTR") || name.hasPrefix("eACC MTR")
        }
        return cpu.isEmpty ? nil : HID(copyEvent: copyEvent, getFloat: getFloat, client: client, cpuSensors: cpu)
    }()

    /// Hottest CPU core cluster sensor in °C.
    static func cpuTemperature() -> Double? {
        guard let hid else { return nil }
        let typeTemperature: Int64 = 15
        let values = hid.cpuSensors.compactMap { sensor -> Double? in
            guard let event = hid.copyEvent(sensor, typeTemperature, 0, 0)?.takeRetainedValue() else { return nil }
            let value = hid.getFloat(event, Int32(typeTemperature << 16))
            return value > 0 && value < 130 ? value : nil
        }
        return values.max()
    }

    // MARK: Fan (SMC)

    private struct SMCKeyData {
        struct Version { var major: UInt8 = 0, minor: UInt8 = 0, build: UInt8 = 0, reserved: UInt8 = 0; var release: UInt16 = 0 }
        struct PLimit { var version: UInt16 = 0, length: UInt16 = 0; var cpu: UInt32 = 0, gpu: UInt32 = 0, mem: UInt32 = 0 }
        struct KeyInfo { var dataSize: UInt32 = 0, dataType: UInt32 = 0; var attributes: UInt8 = 0 }
        var key: UInt32 = 0
        var version = Version()
        var pLimit = PLimit()
        var keyInfo = KeyInfo()
        var padding: UInt16 = 0
        var result: UInt8 = 0
        var status: UInt8 = 0
        var data8: UInt8 = 0
        var data32: UInt32 = 0
        var bytes: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8)
            = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
    }

    private static let smc: io_connect_t? = {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        var connection: io_connect_t = 0
        return IOServiceOpen(service, mach_task_self_, 0, &connection) == KERN_SUCCESS ? connection : nil
    }()

    private static func fourCC(_ key: String) -> UInt32 { key.utf8.reduce(0) { $0 << 8 | UInt32($1) } }

    private static func smcCall(_ input: inout SMCKeyData) -> SMCKeyData? {
        guard let smc else { return nil }
        var output = SMCKeyData()
        var size = MemoryLayout<SMCKeyData>.stride
        let result = IOConnectCallStructMethod(smc, 2, &input, MemoryLayout<SMCKeyData>.stride, &output, &size)
        return result == KERN_SUCCESS && output.result == 0 ? output : nil
    }

    private static func smcFloat(_ key: String) -> Double? {
        var input = SMCKeyData()
        input.key = fourCC(key)
        input.data8 = 9 // get key info
        guard let info = smcCall(&input) else { return nil }
        input.keyInfo = info.keyInfo
        input.data8 = 5 // read key
        guard let output = smcCall(&input) else { return nil }
        let raw = withUnsafeBytes(of: output.bytes) { Array($0.prefix(Int(info.keyInfo.dataSize))) }
        switch info.keyInfo.dataType {
        case fourCC("flt ") where raw.count == 4:
            return Double(raw.withUnsafeBytes { $0.load(as: Float.self) })
        case fourCC("fpe2") where raw.count == 2:
            return Double((Int(raw[0]) << 6) + (Int(raw[1]) >> 2))
        case fourCC("ui8 ") where raw.count == 1:
            return Double(raw[0])
        default:
            return nil
        }
    }

    /// RPM of the first fan; nil when the Mac has none.
    static func fanRPM() -> Int? {
        guard let count = smcFloat("FNum"), count > 0 else { return nil }
        return smcFloat("F0Ac").map { Int($0.rounded()) }
    }

    // MARK: Battery

    struct Battery {
        let percent: Int
        let charging: Bool
        let onAC: Bool
        let minutesLeft: Int?
        let healthPercent: Int?
        let cycles: Int?
        let watts: Double?
        let temperature: Double?
    }

    static func battery() -> Battery? {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef],
              let source = list.first,
              let desc = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue() as? [String: Any],
              desc[kIOPSTypeKey] as? String == kIOPSInternalBatteryType else { return nil }
        let percent = desc[kIOPSCurrentCapacityKey] as? Int ?? 0
        let charging = desc[kIOPSIsChargingKey] as? Bool ?? false
        let onAC = desc[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue
        let toEmpty = desc[kIOPSTimeToEmptyKey] as? Int ?? -1

        var health: Int?, cycles: Int?, watts: Double?, temperature: Double?
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        if service != 0 {
            defer { IOObjectRelease(service) }
            func prop(_ key: String) -> Int? {
                IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Int
            }
            cycles = prop("CycleCount")
            // Same figure as System Settings > Battery > Maximum Capacity.
            let data = IORegistryEntryCreateCFProperty(service, "BatteryData" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? [String: Any]
            if let nominal = data?["NominalChargeCapacity"] as? Int, let design = data?["DesignCapacity"] as? Int, design > 0 {
                health = Int((Double(nominal) / Double(design) * 100).rounded())
            }
            if let amperage = prop("InstantAmperage") ?? prop("Amperage"), let voltage = prop("Voltage") {
                watts = abs(Double(amperage) * Double(voltage)) / 1_000_000
            }
            if let raw = prop("Temperature") { temperature = Double(raw) / 100 }
        }
        return Battery(percent: percent, charging: charging, onAC: onAC,
                       minutesLeft: !onAC && toEmpty > 0 ? toEmpty : nil,
                       healthPercent: health, cycles: cycles, watts: watts, temperature: temperature)
    }

    // MARK: Network

    struct NetworkInfo { let bytesIn: UInt64; let bytesOut: UInt64; let ip: String?; let interface: String?; let vpn: Bool }

    static func network() -> NetworkInfo {
        var bytesIn: UInt64 = 0, bytesOut: UInt64 = 0
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var length = 0
        if sysctl(&mib, 6, nil, &length, nil, 0) == 0, length > 0 {
            var buffer = [UInt8](repeating: 0, count: length)
            if sysctl(&mib, 6, &buffer, &length, nil, 0) == 0 {
                var offset = 0
                while offset + MemoryLayout<if_msghdr>.size <= length {
                    let header = buffer.withUnsafeBytes { $0.load(fromByteOffset: offset, as: if_msghdr.self) }
                    if header.ifm_type == UInt8(RTM_IFINFO2) {
                        let msg = buffer.withUnsafeBytes { $0.load(fromByteOffset: offset, as: if_msghdr2.self) }
                        var name = [CChar](repeating: 0, count: Int(IF_NAMESIZE))
                        if if_indextoname(UInt32(msg.ifm_index), &name) != nil, String(cString: name).hasPrefix("en") {
                            bytesIn += msg.ifm_data.ifi_ibytes
                            bytesOut += msg.ifm_data.ifi_obytes
                        }
                    }
                    offset += Int(header.ifm_msglen)
                    if header.ifm_msglen == 0 { break }
                }
            }
        }

        var ip: String?, interface: String?, vpn = false
        var addrs: UnsafeMutablePointer<ifaddrs>?
        if getifaddrs(&addrs) == 0, let first = addrs {
            defer { freeifaddrs(addrs) }
            for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
                let entry = ptr.pointee
                guard let addr = entry.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) else { continue }
                let name = String(cString: entry.ifa_name)
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
                let address = String(cString: host)
                if name.hasPrefix("utun") || name.hasPrefix("ipsec") || name.hasPrefix("ppp") { vpn = true }
                if ip == nil, name.hasPrefix("en"), !address.hasPrefix("169.254") {
                    ip = address
                    interface = name == CWWiFiClient.shared().interface()?.interfaceName ? "Wi-Fi" : "Ethernet"
                }
            }
        }
        return NetworkInfo(bytesIn: bytesIn, bytesOut: bytesOut, ip: ip, interface: interface, vpn: vpn)
    }

    // MARK: Processes

    struct ProcessSample {
        let pid: pid_t
        let group: String      // app bundle path, or executable path
        let cpuNanos: UInt64
        let energyNanojoules: UInt64
        let footprint: UInt64
    }

    private static let timebase: (numer: UInt64, denom: UInt64) = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return (UInt64(info.numer), UInt64(max(info.denom, 1)))
    }()

    /// One pass over every process this user can inspect (system daemons owned by root are skipped by the kernel).
    static func processes() -> [ProcessSample] {
        let capacity = Int(proc_listallpids(nil, 0)) + 64
        var pids = [pid_t](repeating: 0, count: capacity)
        let count = Int(proc_listallpids(&pids, Int32(capacity * MemoryLayout<pid_t>.size)))
        var path = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        var samples: [ProcessSample] = []
        samples.reserveCapacity(count)
        for pid in pids.prefix(max(count, 0)) where pid > 0 {
            var info = rusage_info_v6()
            let ok = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V6, $0) }
            }
            guard ok == 0, proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { continue }
            let ticks = info.ri_user_time + info.ri_system_time
            samples.append(ProcessSample(
                pid: pid, group: appGroup(String(cString: path)),
                cpuNanos: ticks * timebase.numer / timebase.denom,
                energyNanojoules: info.ri_energy_nj,
                footprint: info.ri_phys_footprint))
        }
        return samples
    }

    /// Outermost .app bundle in the path, so helpers count toward their app.
    static func appGroup(_ path: String) -> String {
        if let range = path.range(of: ".app/") { return String(path[..<range.lowerBound]) + ".app" }
        return path
    }

    static func displayName(forGroup group: String) -> String {
        if group.hasSuffix(".app") { return FileManager.default.displayName(atPath: group).replacingOccurrences(of: ".app", with: "") }
        return (group as NSString).lastPathComponent
    }

    // MARK: Trash

    static func trashSize() -> Int64 {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash")
        guard let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in walker {
            total += Int64((try? file.resourceValues(forKeys: [.totalFileAllocatedSizeKey]))?.totalFileAllocatedSize ?? 0)
        }
        return total
    }
}
