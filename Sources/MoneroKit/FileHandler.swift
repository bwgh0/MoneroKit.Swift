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
        try excludeFromBackup(url)
        return url
    }

    /// Keep wallet data out of iCloud/Finder backups.
    ///
    /// This directory holds wallet2's `wallet.keys` (which contains the private
    /// spend key) plus the transaction cache. An *unencrypted* Finder/iTunes
    /// backup copies it verbatim, so anyone who can make one off a trusted
    /// computer walks away with the wallet files. Keychain items are
    /// `…ThisDeviceOnly` and never leave the device, so excluding this tree
    /// closes the matching gap on the filesystem side.
    ///
    /// Best-effort and idempotent: a failure here must not stop a wallet from
    /// opening.
    private static func excludeFromBackup(_ url: URL) throws {
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableURL = url
        try? mutableURL.setResourceValues(values)
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
