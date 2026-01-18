import Foundation

class FileHandler {
    static func _url(for directoryName: String) throws -> URL {
        let fileManager = FileManager.default

        return try fileManager
            .url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent(directoryName, isDirectory: true)
    }

    static func directoryURL(for directoryName: String) throws -> URL {
        let url = try _url(for: directoryName)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func removeAll(except excludedFiles: [String]) throws {
        let fileManager = FileManager.default
        let fileUrls = try fileManager.contentsOfDirectory(at: directoryURL(for: "MoneroKit"), includingPropertiesForKeys: nil)

        for filename in fileUrls {
            if !excludedFiles.contains(where: { filename.lastPathComponent.contains($0) }) {
                try fileManager.removeItem(at: filename)
            }
        }
    }

    static func remove(for directoryName: String) throws {
        let fileManager = FileManager.default
        let url = try _url(for: directoryName)
        if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
    }
}
