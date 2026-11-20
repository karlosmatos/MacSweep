import SwiftUI

/// Read-only Claude Code session that inspects the Mac and recommends cleanup.
/// Each recommendation ends with a tag that becomes a button into the right MacSweep section.
@MainActor
@Observable
final class Advisor {
    struct Message: Identifiable {
        let id = UUID()
        let fromUser: Bool
        let text: String
        var seconds: Int?
    }

    var messages: [Message] = []
    var busy = false
    var startedAt: Date?
    private var sessionID: String?
    private var runner: ProcessRunner?

    private static let systemPrompt = """
    Jsi poradce pro úklid a výkon macOS uvnitř aplikace MacSweep. Odpovídej česky a stručně, bez tabulek a nadpisů.
    Máš jen nástroje ke čtení: mo status/analyze/clean --dry-run/purge --dry-run/uninstall --list/--dry-run, du, ls, Read, Glob, Grep.
    Nikdy nic nemaž. Najdi největší a nejbezpečnější úspory místa a vysvětli rizika. U výkonu komentuj RAM, swap, CPU, procesy a spouštěné položky.
    Formát: jedna úvodní věta, pak každé doporučení na samostatném řádku ve tvaru
    "- <velikost nebo 'výkon'> | <co a proč, max 2 krátké věty> [[cil]]"
    kde cil je jedno z: uklid (cache a staré soubory, tlačítko Uvolnit v menu baru), analyza (konkrétní složky),
    aplikace (odinstalace), spousteni (položky po startu a na pozadí). Seřaď podle uvolněného místa.
    Na konec můžeš přidat jednu větu o tom, co jsi nemohl zkontrolovat.
    """

    private static let allowedTools = [
        "Read", "Glob", "Grep", "Bash(du:*)", "Bash(ls:*)",
        "Bash(mo status:*)", "Bash(mo analyze:*)", "Bash(mo clean --dry-run:*)", "Bash(mo purge --dry-run:*)",
        "Bash(mo installer --dry-run:*)", "Bash(mo slim --dry-run:*)", "Bash(mo uninstall --list:*)",
        "Bash(mo uninstall --dry-run:*)", "Bash(docker system df:*)", "Bash(brew list:*)", "Bash(sfltool dumpbtm:*)",
    ]

    func runFullAudit() {
        send("Udělej kompletní audit mého Macu: disk (mo analyze --json, mo clean --dry-run, mo purge --dry-run), aplikace, které nepoužívám, a co se spouští po startu (sfltool dumpbtm).",
             display: "Projdi celý Mac.")
    }

    func send(_ prompt: String, display: String? = nil) {
        guard let claude = Shell.claude else {
            messages.append(Message(fromUser: false, text: "Nenašel jsem příkaz `claude` (~/.local/bin/claude). Poradce ho potřebuje."))
            return
        }
        guard !busy else { return }
        messages.append(Message(fromUser: true, text: display ?? prompt))
        busy = true
        startedAt = Date()
        // --strict-mcp-config without --mcp-config skips the user's MCP servers: faster and cheaper.
        var args = ["-p", "--output-format", "json", "--strict-mcp-config", "--append-system-prompt", Self.systemPrompt]
        if let sessionID { args += ["--resume", sessionID] }
        args += ["--allowedTools"] + Self.allowedTools
        let runner = ProcessRunner(claude, args)
        self.runner = runner
        Task {
            let reply: String
            do {
                let (output, status) = try await runner.run(stdin: prompt)
                reply = parse(output, status: status)
            } catch {
                reply = "Claude nejde spustit: \(error.localizedDescription)"
            }
            let seconds = startedAt.map { Int(Date().timeIntervalSince($0)) }
            messages.append(Message(fromUser: false, text: reply, seconds: seconds))
            busy = false
            startedAt = nil
        }
    }

    func cancel() { runner?.cancel() }

    func reset() {
        messages = []
        sessionID = nil
    }

    private func parse(_ output: String, status: Int32) -> String {
        struct Result: Decodable { let result: String?; let sessionId: String?; let isError: Bool? }
        guard let start = output.firstIndex(of: "{"),
              let result = try? snakeDecoder.decode(Result.self, from: Data(output[start...].utf8)) else {
            return status == 15 ? "Zastaveno." : "Neočekávaná odpověď (kód \(status)):\n\(output)"
        }
        if let id = result.sessionId { sessionID = id }
        return result.result ?? "(prázdná odpověď)"
    }
}

struct AdvisorView: View {
    @Environment(Advisor.self) private var advisor
    @Environment(AppState.self) private var state
    @State private var input = ""

    private let suggestions = [
        "Co zabírá místo v ~/Library?",
        "Proč je Mac pomalý?",
        "Které aplikace skoro nepoužívám?",
    ]

    var body: some View {
        VStack(spacing: 0) {
            if advisor.messages.isEmpty { emptyState } else { conversation }
            composer
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Zeptej se na svůj Mac").font(.system(size: 22, weight: .semibold))
            Text("Claude projde disk, aplikace a procesy. Jen čte, nic nemaže. Každé doporučení má tlačítko, které otevře správné místo v MacSweep.")
                .foregroundStyle(.secondary).frame(maxWidth: 480, alignment: .leading)
            HStack(spacing: 12) {
                Button("Projít celý Mac") { advisor.runFullAudit() }
                    .buttonStyle(PrimaryButtonStyle()).fixedSize()
                Text("Trvá 1 až 3 minuty.").font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                ForEach(suggestions, id: \.self) { text in
                    Button(text) { advisor.send(text) }.buttonStyle(SecondaryButtonStyle())
                }
            }
            .padding(.top, 4)
        }
        .padding(.horizontal, 56)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private var conversation: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    ForEach(advisor.messages) { message in
                        MessageView(message: message) { state.section = $0 }.id(message.id)
                    }
                    if advisor.busy {
                        TimelineView(.periodic(from: .now, by: 1)) { _ in
                            HStack(spacing: 10) {
                                ProgressView().controlSize(.small)
                                Text("Claude čte Mac… \(Format.duration(since: advisor.startedAt))").foregroundStyle(.secondary)
                                Button("Zastavit") { advisor.cancel() }.buttonStyle(SecondaryButtonStyle())
                            }
                            .font(.callout)
                        }
                        .id("busy")
                    }
                }
                .padding(.horizontal, 40).padding(.vertical, 24)
            }
            .onChange(of: advisor.messages.count) {
                if let last = advisor.messages.last { withAnimation { proxy.scrollTo(last.id, anchor: .top) } }
            }
        }
    }

    private var composer: some View {
        HStack(spacing: 8) {
            TextField("Zeptej se na cokoli o svém Macu", text: $input, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...4)
                .onSubmit(submit)
            if !advisor.messages.isEmpty {
                IconButton(icon: "arrow.counterclockwise", help: "Nová konverzace") { advisor.reset() }
                    .disabled(advisor.busy)
            }
            Button(action: submit) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 12, weight: .bold))
                    .frame(width: 28, height: 28)
                    .background(Theme.accent, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .foregroundStyle(.white)
            }
            .buttonStyle(PressableStyle())
            .disabled(input.isEmpty || advisor.busy)
            .opacity(input.isEmpty || advisor.busy ? 0.4 : 1)
            .accessibilityLabel("Odeslat")
        }
        .padding(.leading, 14).padding(.trailing, 8).padding(.vertical, 8)
        .panel(radius: 12)
        .padding(.horizontal, 40).padding(.bottom, 22)
    }

    private func submit() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !advisor.busy else { return }
        input = ""
        advisor.send(text)
    }
}

/// Renders a reply: plain lines as text, "- size | text [[target]]" lines as actionable rows.
private struct MessageView: View {
    let message: Advisor.Message
    let navigate: (Section) -> Void
    @Environment(Sweeper.self) private var sweeper
    @State private var confirmSweep = false

    var body: some View {
        content.alert("Uvolnit \(Format.bytes(sweeper.reclaimable))?", isPresented: $confirmSweep) {
            Button("Uvolnit") { sweeper.sweep() }
            Button("Zrušit", role: .cancel) {}
        } message: {
            Text(sweeper.selectedItems.map(\.title).joined(separator: ", ") + ". Stejné jako tlačítko v menu baru.")
        }
    }

    @ViewBuilder
    private var content: some View {
        if message.fromUser {
            HStack {
                Spacer(minLength: 120)
                Text(message.text)
                    .padding(.horizontal, 13).padding(.vertical, 9)
                    .background(Theme.accent.opacity(0.14), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        } else {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    if let rec = Recommendation(line) {
                        HStack(alignment: .firstTextBaseline, spacing: 14) {
                            Text(rec.amount).fontWeight(.semibold).frame(width: 72, alignment: .trailing)
                                .foregroundStyle(rec.amount == "výkon" ? .secondary : .primary)
                            Text(markdown(rec.text)).frame(maxWidth: .infinity, alignment: .leading)
                            if let target = rec.target {
                                Button(target.title) { go(target) }.buttonStyle(SecondaryButtonStyle())
                            }
                        }
                        .padding(.vertical, 10)
                        .overlay(alignment: .top) { Divider() }
                    } else if !line.trimmingCharacters(in: .whitespaces).isEmpty {
                        Text(markdown(line)).padding(.vertical, 4).foregroundStyle(lines.first == line ? .primary : .secondary)
                    }
                }
                if let seconds = message.seconds {
                    Text("Odpověď za \(seconds / 60) min \(seconds % 60) s").font(.caption).foregroundStyle(.tertiary).padding(.top, 8)
                }
            }
            .font(.system(size: 13))
            .lineSpacing(2)
            .textSelection(.enabled)
            .frame(maxWidth: 720, alignment: .leading)
        }
    }

    private var lines: [String] { message.text.components(separatedBy: "\n") }

    private func markdown(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
    }

    private func go(_ target: Recommendation.Target) {
        switch target {
        case .sweep: confirmSweep = true
        case .analyze: navigate(.analyze)
        case .apps: navigate(.apps)
        case .startup: navigate(.startup)
        }
    }
}

private struct Recommendation {
    enum Target {
        case sweep, analyze, apps, startup
        var title: String {
            switch self {
            case .sweep: "Uvolnit"
            case .analyze: "Otevřít Analýzu"
            case .apps: "Otevřít Aplikace"
            case .startup: "Otevřít Spouštění"
            }
        }
    }

    let amount: String
    let text: String
    let target: Target?

    init?(_ line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("- "), let bar = trimmed.firstIndex(of: "|") else { return nil }
        amount = trimmed[trimmed.index(trimmed.startIndex, offsetBy: 2)..<bar].trimmingCharacters(in: .whitespaces)
        var body = String(trimmed[trimmed.index(after: bar)...]).trimmingCharacters(in: .whitespaces)
        var target: Target?
        if let open = body.range(of: "[["), let close = body.range(of: "]]"), open.upperBound <= close.lowerBound {
            switch body[open.upperBound..<close.lowerBound] {
            case "uklid": target = .sweep
            case "analyza": target = .analyze
            case "aplikace": target = .apps
            case "spousteni": target = .startup
            default: break
            }
            body.removeSubrange(open.lowerBound..<close.upperBound)
        }
        text = body.trimmingCharacters(in: .whitespaces)
        self.target = target
    }
}
