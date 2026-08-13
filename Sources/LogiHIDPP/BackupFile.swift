import Foundation

/// Byte-exact snapshot of onboard memory, readable on any model whatever its profile format.
public struct BackupFile: Codable {
    public struct Device: Codable {
        public let name: String
        public let productId: Int
        public let profileFormat: Int
        public let sectorCount: Int
        public let sectorSize: Int
    }

    public let tool: String
    public let version: Int
    public let createdAt: String
    public let device: Device
    public let sectors: [String: String]

    public var sectorCount: Int { sectors.count }

    public static func capture(from device: LogiDevice, profiles: OnboardProfiles) throws -> BackupFile {
        let capabilities = profiles.capabilities
        var captured: [String: String] = [:]

        for sector in 0..<capabilities.sectorCount {
            guard let content = try? profiles.readSector(sector) else { continue }
            captured[String(sector)] = content.map { String(format: "%02x", $0) }.joined()
        }

        guard !captured.isEmpty else { throw BackupError.nothingReadable }

        return BackupFile(
            tool: "lomm",
            version: 1,
            createdAt: ISO8601DateFormatter().string(from: Date()),
            device: Device(
                name: device.info.name,
                productId: device.info.productId,
                profileFormat: Int(capabilities.profileFormat),
                sectorCount: capabilities.sectorCount,
                sectorSize: capabilities.sectorSize
            ),
            sectors: captured
        )
    }

    public func write(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        try encoder.encode(self).write(to: url)
    }

    public static func read(from url: URL) throws -> BackupFile {
        try JSONDecoder().decode(BackupFile.self, from: Data(contentsOf: url))
    }

    /// Sectors in ascending order, decoded back to bytes.
    public func decodedSectors() throws -> [(sector: Int, content: [UInt8])] {
        try sectors
            .sorted { (Int($0.key) ?? 0) < (Int($1.key) ?? 0) }
            .map { key, value in
                guard let sector = Int(key), let content = BackupFile.unhex(value) else {
                    throw BackupError.corruptSector(key)
                }

                return (sector, content)
            }
    }

    public func check(against device: LogiDevice, profiles: OnboardProfiles) throws {
        guard device.info.productId == self.device.productId else {
            throw BackupError.productMismatch(expected: self.device.productId, found: device.info.productId)
        }

        guard profiles.capabilities.sectorSize == self.device.sectorSize else {
            throw BackupError.sectorSizeMismatch(expected: self.device.sectorSize, found: profiles.capabilities.sectorSize)
        }
    }

    private static func unhex(_ text: String) -> [UInt8]? {
        let characters = Array(text)
        guard characters.count % 2 == 0 else { return nil }

        var bytes: [UInt8] = []

        for index in stride(from: 0, to: characters.count, by: 2) {
            guard let byte = UInt8(String(characters[index...index + 1]), radix: 16) else { return nil }
            bytes.append(byte)
        }

        return bytes
    }
}

public enum BackupError: Error, CustomStringConvertible {
    case nothingReadable
    case corruptSector(String)
    case productMismatch(expected: Int, found: Int)
    case sectorSizeMismatch(expected: Int, found: Int)

    public var description: String {
        switch self {
        case .nothingReadable:
            return "no sector could be read"
        case .corruptSector(let key):
            return "sector \(key) is not valid hex"
        case .productMismatch(let expected, let found):
            return String(format: "backup is for product 0x%04X, connected device is 0x%04X", expected, found)
        case .sectorSizeMismatch(let expected, let found):
            return "backup sector size \(expected) does not match device \(found)"
        }
    }
}
