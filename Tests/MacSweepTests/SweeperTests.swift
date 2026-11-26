import Testing
@testable import MacSweep

@MainActor
struct SweeperTests {
    @Test func parsesDryRunAndSkipsMalformedLines() {
        let items = Sweeper.parseScan("caches\t585728\nbroken line\napp_caches\tabc\nxcode\t0\n")
        #expect(items == [Sweeper.Item(key: "caches", bytes: 585_728), Sweeper.Item(key: "xcode", bytes: 0)])
    }

    @Test func freedCountsOnlySweptCategoriesThatShrank() {
        let before = [Sweeper.Item(key: "caches", bytes: 1_000), Sweeper.Item(key: "logs", bytes: 500),
                      Sweeper.Item(key: "xcode", bytes: 300)]
        let after = [Sweeper.Item(key: "caches", bytes: 100), Sweeper.Item(key: "logs", bytes: 900)]
        // xcode wasn't swept; logs grew meanwhile, which must not go negative.
        #expect(Sweeper.freed(before: before, after: after, swept: ["caches", "logs"]) == 900)
    }

    @Test func freedTreatsMissingCategoryAsFullyCleaned() {
        let before = [Sweeper.Item(key: "node_modules", bytes: 2_000)]
        #expect(Sweeper.freed(before: before, after: [], swept: ["node_modules"]) == 2_000)
    }

    @Test func trashedDownloadsFreeNothing() {
        let before = [Sweeper.Item(key: "downloads", bytes: 5_000)]
        #expect(Sweeper.freed(before: before, after: [], swept: ["downloads"]) == 0)
    }
}
