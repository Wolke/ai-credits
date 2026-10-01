import Foundation

struct PersistenceService: Sendable {
    let fileURL: URL

    init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            self.fileURL = base.appending(path: "AICredits", directoryHint: .isDirectory)
                .appending(path: "credits.json")
        }
    }

    func load() throws -> AppData {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return AppData() }
        return try JSONDecoder.app.decode(AppData.self, from: Data(contentsOf: fileURL))
    }

    func save(_ data: AppData) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoded = try JSONEncoder.app.encode(data)
        try encoded.write(to: fileURL, options: [.atomic, .completeFileProtection])
    }
}

private extension JSONEncoder {
    static var app: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

private extension JSONDecoder {
    static var app: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
