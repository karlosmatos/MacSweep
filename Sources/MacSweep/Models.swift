import Foundation

let snakeDecoder: JSONDecoder = {
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    return decoder
}()

struct AnalyzeResult: Decodable {
    struct Entry: Decodable, Identifiable, Hashable {
        let name: String
        let path: String
        let size: Int64
        let isDir: Bool
        let lastAccess: String?
        let insight: Bool?
        var id: String { path }
    }
    let scanStatus: String?
    let path: String
    let overview: Bool?
    let entries: [Entry]
}

struct InstalledApp: Decodable, Identifiable, Hashable {
    let name: String
    let bundleId: String?
    let source: String?
    let uninstallName: String
    let path: String
    let size: String?
    var id: String { path }
}
