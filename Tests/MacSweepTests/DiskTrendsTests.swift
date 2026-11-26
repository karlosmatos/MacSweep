import Foundation
import Testing
@testable import MacSweep

@MainActor
struct DiskTrendsTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func samples(days: Int, start: Int64, perDay: Int64) -> [DiskHistory.Sample] {
        (0...days * 24).map { hour in
            DiskHistory.Sample(date: now.addingTimeInterval(Double(hour - days * 24) * 3_600),
                               free: start + perDay * Int64(hour) / 24)
        }
    }

    @Test func trendFollowsSteadyLoss() throws {
        let perDay = try #require(DiskHistory.trend(samples(days: 10, start: 100_000_000_000, perDay: -2_000_000_000), now: now))
        #expect(abs(perDay + 2_000_000_000) < 1_000_000)
    }

    @Test func noTrendUnderThreeDays() {
        #expect(DiskHistory.trend(samples(days: 2, start: 50_000_000_000, perDay: -1_000_000_000), now: now) == nil)
    }

    @Test func daysLeftOnlyWhenShrinkingNoticeably() {
        #expect(DiskHistory.daysLeft(free: 40_000_000_000, perDay: -2_000_000_000) == 20)
        #expect(DiskHistory.daysLeft(free: 40_000_000_000, perDay: -100_000_000) == nil)
        #expect(DiskHistory.daysLeft(free: 40_000_000_000, perDay: 1_000_000_000) == nil)
        #expect(DiskHistory.daysLeft(free: 40_000_000_000, perDay: nil) == nil)
    }

    @Test func parsesDuOutput() {
        let sizes = FolderGrowth.parse("4\t/Users/me/a b\nbad\n1024\t/Users/me\n")
        #expect(sizes == ["/Users/me/a b": 4_096, "/Users/me": 1_048_576])
    }

    @Test func growthNamesTheMostSpecificFolder() {
        let old: [String: Int64] = ["/h": 100_000_000_000, "/h/Library": 50_000_000_000, "/h/Library/Containers": 10_000_000_000,
                                    "/h/Movies": 1_000_000_000]
        let new: [String: Int64] = ["/h": 115_000_000_000, "/h/Library": 62_000_000_000, "/h/Library/Containers": 22_000_000_000,
                                    "/h/Movies": 2_000_000_000, "/h/Big": 6_000_000_000]
        let grown = FolderGrowth.growth(from: old, to: new)
        #expect(grown == [FolderGrowth.Growth(path: "/h/Library/Containers", bytes: 12_000_000_000),
                          FolderGrowth.Growth(path: "/h/Big", bytes: 6_000_000_000)])
    }
}
