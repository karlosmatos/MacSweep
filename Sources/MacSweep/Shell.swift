import AppKit
import Foundation
import ServiceManagement

enum Shell {
    static let environment: [String: String] = {
        var env = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:\(home)/.local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        env["NO_COLOR"] = "1"
        env["TERM"] = "xterm-256color"
        return env
    }()

    static func firstExecutable(_ candidates: [String]) -> String? {
        candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static let mo: String = firstExecutable(["/opt/homebrew/bin/mo", "/usr/local/bin/mo"]) ?? "/opt/homebrew/bin/mo"

    /// Disk analysis and app removal run on Mole; says how to get it when it's missing.
    static var moleMissing: String? {
        FileManager.default.isExecutableFile(atPath: mo) ? nil : String(localized: "Tahle část potřebuje Mole. Nainstaluj ho v Terminálu: brew install mole")
    }

    static let claude: String? = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return firstExecutable(["\(home)/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"])
    }()

    static func stripANSI(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[ -/]*[@-~]", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\u{1B}[()][A-Za-z0-9]", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\r", with: "")
    }

    /// Strips escapes and applies carriage returns like a terminal (spinners overwrite their line).
    static func renderTerminal(_ raw: String) -> String {
        let noEscapes = raw
            .replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[ -/]*[@-~]", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\u{1B}[()][A-Za-z0-9]", with: "", options: .regularExpression)
        return noEscapes.components(separatedBy: "\n").map { line in
            line.components(separatedBy: "\r").last { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? ""
        }.joined(separator: "\n")
    }
}

/// Runs a process with piped output, delivering complete lines as they arrive.
final class ProcessRunner: @unchecked Sendable {
    private let process = Process()
    private let lock = NSLock()
    private var pending = Data()
    private var collected = ""
    private let onLine: (@Sendable (String) -> Void)?

    init(_ executable: String, _ arguments: [String], cwd: URL? = nil, onLine: (@Sendable (String) -> Void)? = nil) {
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = Shell.environment
        process.currentDirectoryURL = cwd ?? FileManager.default.homeDirectoryForCurrentUser
        self.onLine = onLine
    }

    static func output(_ executable: String, _ arguments: [String], stdin: String? = nil) async throws -> String {
        try await ProcessRunner(executable, arguments).run(stdin: stdin).output
    }

    func run(stdin: String? = nil) async throws -> (output: String, status: Int32) {
        let out = Pipe()
        let input = Pipe()
        process.standardOutput = out
        process.standardError = out
        process.standardInput = stdin == nil ? FileHandle.nullDevice : input
        out.fileHandleForReading.readabilityHandler = { [weak self] handle in
            self?.append(handle.availableData)
        }
        return try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { [self] proc in
                out.fileHandleForReading.readabilityHandler = nil
                append(out.fileHandleForReading.readDataToEndOfFile())
                append(Data([0x0A]))
                lock.lock(); let text = collected; lock.unlock()
                continuation.resume(returning: (text, proc.terminationStatus))
            }
            do {
                try process.run()
                if let stdin {
                    input.fileHandleForWriting.write(Data(stdin.utf8))
                    try? input.fileHandleForWriting.close()
                }
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    func cancel() {
        if process.isRunning { process.terminate() }
    }

    private func append(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.lock()
        pending.append(data)
        var lines: [String] = []
        while let newline = pending.firstIndex(of: 0x0A) {
            let line = Shell.stripANSI(String(decoding: pending[pending.startIndex..<newline], as: UTF8.self))
            pending.removeSubrange(pending.startIndex...newline)
            collected += line + "\n"
            lines.append(line)
        }
        lock.unlock()
        lines.forEach { onLine?($0) }
    }
}

/// Runs Mole inside a real pseudo-terminal (via /usr/bin/script) so its TTY-only
/// confirmation prompts work. The user confirms in the GUI first; we then answer Enter.
final class PTYRunner: @unchecked Sendable {
    private let process = Process()
    private var master: Int32 = -1

    func run(_ arguments: [String], onOutput: @escaping @Sendable (String) -> Void) async throws -> Int32 {
        var masterFD: Int32 = 0
        var slaveFD: Int32 = 0
        var size = winsize(ws_row: 50, ws_col: 160, ws_xpixel: 0, ws_ypixel: 0)
        guard openpty(&masterFD, &slaveFD, nil, nil, &size) == 0 else {
            throw NSError(domain: "MacSweep", code: 1, userInfo: [NSLocalizedDescriptionKey: "openpty selhal"])
        }
        master = masterFD
        let slave = FileHandle(fileDescriptor: slaveFD, closeOnDealloc: true)
        process.executableURL = URL(fileURLWithPath: "/usr/bin/script")
        process.arguments = ["-q", "/dev/null", Shell.mo] + arguments
        process.environment = Shell.environment
        process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        process.standardInput = slave
        process.standardOutput = slave
        process.standardError = slave

        let reader = Thread {
            var buffer = [UInt8](repeating: 0, count: 8192)
            while true {
                let count = read(masterFD, &buffer, buffer.count)
                if count <= 0 { break }
                onOutput(String(decoding: buffer[0..<count], as: UTF8.self))
            }
        }

        return try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { proc in
                continuation.resume(returning: proc.terminationStatus)
            }
            do {
                try process.run()
                try? slave.close()
                reader.start()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    func send(_ text: String) {
        guard master >= 0 else { return }
        _ = text.withCString { write(master, $0, strlen($0)) }
    }

    func cancel() {
        if process.isRunning { process.terminate() }
    }
}

/// Hops to the main actor in FIFO order (unlike spawning a Task per event).
func onMain(_ work: @escaping @MainActor () -> Void) {
    DispatchQueue.main.async { MainActor.assumeIsolated(work) }
}

enum Format {
    /// "0 KB", not the formatter's "Zero KB".
    static func bytes(_ value: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowsNonnumericFormatting = false
        return formatter.string(fromByteCount: value)
    }

    /// Bytes per second, e.g. "1,2 MB/s".
    static func rate(_ bytesPerSecond: Double) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(max(bytesPerSecond, 0))) + "/s"
    }

    /// Memory in binary gigabytes, like Activity Monitor: "11,5" of "16".
    static func memoryGB(_ bytes: Int64) -> String {
        let value = Double(bytes) / 1_073_741_824
        return value.formatted(.number.precision(.fractionLength(value.rounded() == value ? 0 : 1)))
    }

    /// Compact elapsed time, e.g. "2 h 8 min", "16 dní".
    static func duration(since date: Date?) -> String {
        guard let date else { return "?" }
        let minutes = Int(Date().timeIntervalSince(date) / 60)
        if minutes < 60 { return "\(minutes) min" }
        if minutes < 48 * 60 { return "\(minutes / 60) h \(minutes % 60) min" }
        return String(localized: "\(minutes / 1440) dní")
    }

    /// Decimal gigabytes as a bare number, e.g. "45,5" (matches Finder's GB).
    static func gigabytes(_ bytes: Int64) -> String {
        let value = Double(bytes) / 1_000_000_000
        return value.formatted(.number.precision(.fractionLength(value < 100 ? 1 : 0)))
    }
}

/// Launch at login through the system's login items (shows as MacSweep in System Settings).
enum LoginItem {
    static var enabled: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                SMAppService.openSystemSettingsLoginItems()
            }
        }
    }
}
