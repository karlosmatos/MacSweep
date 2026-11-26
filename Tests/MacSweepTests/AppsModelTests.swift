import Testing
@testable import MacSweep

@MainActor
struct AppsModelTests {
    @Test func parsesMoleDryRun() {
        let text = """
        \u{1B}[32m✓ /Applications/Foo.app , 120MB\u{1B}[0m
          ✓ ~/Library/Caches/com.foo
          ⊙ ~/Documents/Foo
        Some other line
        """
        let plan = AppsModel.parse(text)
        #expect(plan.remove.map(\.path) == ["/Applications/Foo.app", "~/Library/Caches/com.foo"])
        #expect(plan.remove.map(\.size) == ["120MB", nil])
        #expect(plan.kept == ["~/Documents/Foo"])
    }

    @Test(arguments: [("1.5GB", 1_500_000_000), ("120 MB", 120_000_000), ("4KB", 4_000), ("12B", 12), ("weird", 0)] as [(String, Int64)])
    func parsesSizes(size: String, bytes: Int64) {
        #expect(AppsModel.bytes(size) == bytes)
    }

    @Test func missingSizeIsZero() {
        #expect(AppsModel.bytes(nil) == 0)
    }
}
