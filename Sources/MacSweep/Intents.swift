import AppIntents

/// Shortcuts actions. They run inside MacSweep (launched in the background if needed), so a sweep
/// started here shows its progress in the menu bar like any other.
struct SweepIntent: AppIntent {
    static let title: LocalizedStringResource = "Uklidit Mac"
    static let description = IntentDescription("Uvolní místo v kategoriích zaškrtnutých v MacSweepu a vrátí, kolik uvolnil.")

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<Int> & ProvidesDialog {
        guard let freed = await Sweeper.shared.sweepAndWait() else {
            throw SweepError.failed
        }
        return .result(value: Int(freed), dialog: "Uvolněno \(Format.bytes(freed)).")
    }

    enum SweepError: Error, CustomLocalizedStringResourceConvertible {
        case failed
        var localizedStringResource: LocalizedStringResource { "Úklid neproběhl. Buď už běží, nebo skončil chybou; podrobnosti jsou v MacSweepu." }
    }
}

struct FreeSpaceIntent: AppIntent {
    static let title: LocalizedStringResource = "Volné místo na disku"
    static let description = IntentDescription("Vrátí volné místo na systémovém disku v bajtech.")

    func perform() async throws -> some IntentResult & ReturnsValue<Int> & ProvidesDialog {
        let free = Sensors.disk()?.free ?? 0
        return .result(value: Int(free), dialog: "Volno \(Format.bytes(free)).")
    }
}

struct MacSweepShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: SweepIntent(), phrases: ["Uklidit Mac v \(.applicationName)", "Clean up with \(.applicationName)"],
                    shortTitle: "Uklidit Mac", systemImageName: "sparkle")
        AppShortcut(intent: FreeSpaceIntent(), phrases: ["Kolik je volného místa v \(.applicationName)", "Free space in \(.applicationName)"],
                    shortTitle: "Volné místo", systemImageName: "internaldrive")
    }
}
