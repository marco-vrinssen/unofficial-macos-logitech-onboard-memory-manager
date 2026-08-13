import Foundation

public enum OnboardMode: UInt8 {
    case onboard = 0x01
    case host = 0x02

    public var label: String { self == .onboard ? "onboard" : "host" }
}

public struct OnboardCapabilities {
    public let memoryModel: UInt8
    public let profileFormat: UInt8
    public let macroFormat: UInt8
    public let profileCount: Int
    public let profileCountOutOfBox: Int
    public let buttonCount: Int
    public let sectorCount: Int
    public let sectorSize: Int
    public let mechanicalLayout: UInt8
    public let variousInfo: UInt8
}

public struct ProfileSlot {
    public let index: Int
    public let sector: Int
    public let enabled: Bool
}

/// Feature 0x8100, the onboard profile memory of a Logitech mouse.
public final class OnboardProfiles {
    private enum Function: UInt8 {
        case info = 0
        case setMode = 1
        case getMode = 2
        case setCurrentProfile = 3
        case getCurrentProfile = 4
        case memoryRead = 5
        case memoryAddressWrite = 6
        case memoryWrite = 7
        case memoryWriteEnd = 8
    }

    private static let chunkSize = 16

    private let transport: HIDPPTransport
    public let capabilities: OnboardCapabilities

    public init(transport: HIDPPTransport) throws {
        self.transport = transport

        let reply = try transport.call(feature: Feature.onboardProfiles, function: Function.info.rawValue)
        guard reply.count >= 11 else { throw HIDPPError.timeout }

        capabilities = OnboardCapabilities(
            memoryModel: reply[0],
            profileFormat: reply[1],
            macroFormat: reply[2],
            profileCount: Int(reply[3]),
            profileCountOutOfBox: Int(reply[4]),
            buttonCount: Int(reply[5]),
            sectorCount: Int(reply[6]),
            sectorSize: Int(reply[7]) << 8 | Int(reply[8]),
            mechanicalLayout: reply[9],
            variousInfo: reply[10]
        )
    }

    public var mode: OnboardMode {
        get throws {
            let reply = try transport.call(feature: Feature.onboardProfiles, function: Function.getMode.rawValue)
            return OnboardMode(rawValue: reply.first ?? 0) ?? .host
        }
    }

    public func setMode(_ mode: OnboardMode) throws {
        _ = try transport.call(feature: Feature.onboardProfiles, function: Function.setMode.rawValue, params: [mode.rawValue])
    }

    public var currentProfile: Int {
        get throws {
            let reply = try transport.call(feature: Feature.onboardProfiles, function: Function.getCurrentProfile.rawValue)
            return reply.count >= 2 ? Int(reply[1]) : 0
        }
    }

    public func setCurrentProfile(_ index: Int) throws {
        _ = try transport.call(
            feature: Feature.onboardProfiles,
            function: Function.setCurrentProfile.rawValue,
            params: [0, UInt8(index)]
        )
    }

    public func readSector(_ sector: Int) throws -> [UInt8] {
        let size = capabilities.sectorSize
        var content: [UInt8] = []

        while content.count + OnboardProfiles.chunkSize <= size {
            content += try readChunk(sector: sector, offset: content.count)
        }

        // Re-read the tail overlapping the last aligned chunk because the device rejects a short read
        let remaining = size - content.count

        if remaining > 0 {
            let tail = try readChunk(sector: sector, offset: size - OnboardProfiles.chunkSize)
            content += tail.suffix(remaining)
        }

        return content
    }

    public func writeSector(_ sector: Int, content: [UInt8]) throws {
        let size = capabilities.sectorSize
        guard content.count == size else {
            throw OnboardError.sectorSizeMismatch(expected: size, got: content.count)
        }

        _ = try transport.call(
            feature: Feature.onboardProfiles,
            function: Function.memoryAddressWrite.rawValue,
            params: bePair(sector) + bePair(0) + bePair(size)
        )

        var offset = 0

        while offset < size {
            var chunk = Array(content[offset..<min(offset + OnboardProfiles.chunkSize, size)])
            chunk += Array(repeating: 0, count: OnboardProfiles.chunkSize - chunk.count)

            _ = try transport.call(
                feature: Feature.onboardProfiles,
                function: Function.memoryWrite.rawValue,
                params: chunk
            )

            offset += OnboardProfiles.chunkSize
        }

        _ = try transport.call(feature: Feature.onboardProfiles, function: Function.memoryWriteEnd.rawValue)
    }

    public func profileDirectory() throws -> [ProfileSlot] {
        let sector = try readSector(0)
        var slots: [ProfileSlot] = []

        for index in 0..<capabilities.profileCount {
            let base = index * 4
            guard base + 3 < sector.count else { break }

            let target = Int(sector[base]) << 8 | Int(sector[base + 1])
            guard target != 0xFFFF, target != 0 else { continue }

            slots.append(ProfileSlot(index: index + 1, sector: target, enabled: sector[base + 2] == 1))
        }

        return slots
    }

    private func readChunk(sector: Int, offset: Int) throws -> [UInt8] {
        let reply = try transport.call(
            feature: Feature.onboardProfiles,
            function: Function.memoryRead.rawValue,
            params: bePair(sector) + bePair(offset)
        )

        return Array(reply.prefix(OnboardProfiles.chunkSize))
    }

    private func bePair(_ value: Int) -> [UInt8] {
        [UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)]
    }
}

public enum OnboardError: Error, CustomStringConvertible {
    case sectorSizeMismatch(expected: Int, got: Int)
    case checksumMismatch(sector: Int)

    public var description: String {
        switch self {
        case .sectorSizeMismatch(let expected, let got):
            return "sector must be exactly \(expected) bytes, got \(got)"
        case .checksumMismatch(let sector):
            return "checksum mismatch in sector \(sector)"
        }
    }
}

public enum CRC16 {
    /// CRC-16/CCITT-FALSE, the checksum Logitech stores in the last two bytes of a sector.
    public static func ccitt(_ bytes: ArraySlice<UInt8>) -> UInt16 {
        var crc: UInt16 = 0xFFFF

        for byte in bytes {
            crc ^= UInt16(byte) << 8

            for _ in 0..<8 {
                crc = (crc & 0x8000) != 0 ? (crc << 1) ^ 0x1021 : crc << 1
            }
        }

        return crc
    }

    public static func ccitt(_ bytes: [UInt8]) -> UInt16 {
        ccitt(bytes[...])
    }
}
