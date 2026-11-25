import Foundation
import Testing
@testable import MacSweep

struct FilesModelTests {
    @Test(arguments: [
        ("/Users/me/Movies/a.mov", true),
        ("/Users/me/Library/Application Support/x.db", false),
        ("/Users/me/.docker/disk.raw", false),
        ("/Users/me/Pictures/Photos Library.photoslibrary/originals/a.heic", false),
        ("/Users/me/Applications/Foo.app/Contents/x", false),
        ("/Users/me/.hidden-file.zip", true),
        ("/Users/other/a.mov", false),
    ])
    func candidates(path: String, expected: Bool) {
        #expect(FilesModel.isCandidate(path, home: "/Users/me") == expected)
    }

    @Test func findsDuplicatesByContentNotJustSize() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        // Same size, same first megabyte, different tail: must not count as duplicates.
        var a = Data(repeating: 1, count: 3 << 20), b = a, c = a
        c[c.count - 1] = 2
        try a.write(to: dir.appendingPathComponent("a"))
        try b.write(to: dir.appendingPathComponent("b"))
        try c.write(to: dir.appendingPathComponent("c"))
        try FileManager.default.linkItem(at: dir.appendingPathComponent("a"), to: dir.appendingPathComponent("a-hardlink"))
        a = Data(); b = Data()

        let files = try ["a", "b", "c", "a-hardlink"].map { name in
            let path = dir.appendingPathComponent(name).path
            let inode = try #require(FileManager.default.attributesOfItem(atPath: path)[.systemFileNumber] as? UInt64)
            return FilesModel.File(path: path, size: 3 << 20, lastUsed: nil, inode: inode)
        }
        let groups = FilesModel.duplicates(files)
        #expect(groups.count == 1)
        #expect(Set(groups[0].files.map(\.name)) == ["a", "b"])
        #expect(groups[0].wasted == 3 << 20)
    }
}
