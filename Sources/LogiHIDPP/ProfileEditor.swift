import Foundation

public enum ReportRateSlot: Int, CaseIterable {
    case first = 0
    case second = 1

    public var label: String { self == .first ? "wired" : "wireless" }
}

public enum ButtonAction {
    case mouse(UInt16)
    case key(modifiers: UInt8, code: UInt8)
    case consumer(UInt16)
    case special(UInt8)
    case disabled
    case raw([UInt8])

    public static let mouseNames: [String: UInt16] = [
        "left": 1, "right": 2, "middle": 4, "back": 8, "forward": 16,
    ]

    /// Special action ids, same table the decoder uses.
    public static let specialNames: [String: UInt8] = [
        "wheel-left": 1, "wheel-right": 2, "dpi-up": 3, "dpi-down": 4, "dpi-cycle": 5,
        "dpi-default": 6, "dpi-shift": 7, "g-shift": 11, "battery": 12, "scroll-down": 16, "scroll-up": 17,
    ]

    /// USB consumer control usages for the media keys a mouse can carry.
    public static let mediaNames: [String: UInt16] = [
        "play-pause": 0xCD, "next-track": 0xB5, "previous-track": 0xB6,
        "mute": 0xE2, "volume-up": 0xE9, "volume-down": 0xEA,
    ]

    public var bytes: [UInt8] {
        switch self {
        case .mouse(let mask):
            return [0x80, 0x01, UInt8(mask >> 8), UInt8(mask & 0xFF)]
        case .key(let modifiers, let code):
            return [0x80, 0x02, modifiers, code]
        case .consumer(let usage):
            return [0x80, 0x03, UInt8(usage >> 8), UInt8(usage & 0xFF)]
        case .special(let id):
            return [0x90, id, 0xFF, 0x00]
        case .disabled:
            return [0xFF, 0xFF, 0xFF, 0xFF]
        case .raw(let bytes):
            return Array((bytes + [0, 0, 0, 0]).prefix(4))
        }
    }

    /// Accepts a mouse button, a special, a media key, "disabled", or "raw:aabbccdd".
    public static func parse(_ text: String) -> ButtonAction? {
        let value = text.lowercased()

        if let mask = mouseNames[value] { return .mouse(mask) }
        if let id = specialNames[value] { return .special(id) }
        if let usage = mediaNames[value] { return .consumer(usage) }
        if value == "disabled" || value == "none" { return .disabled }

        if value.hasPrefix("raw:") {
            let hex = String(value.dropFirst(4))
            guard hex.count == 8, let bytes = hexBytes(hex) else { return nil }

            return .raw(bytes)
        }

        return nil
    }

    private static func hexBytes(_ text: String) -> [UInt8]? {
        let characters = Array(text)
        var bytes: [UInt8] = []

        for index in stride(from: 0, to: characters.count, by: 2) {
            guard let byte = UInt8(String(characters[index...index + 1]), radix: 16) else { return nil }
            bytes.append(byte)
        }

        return bytes
    }
}

public enum EditError: Error, CustomStringConvertible {
    case unsupportedFormat(UInt8)
    case stageOutOfRange(Int)
    case buttonOutOfRange(Int)
    case dpiOutOfRange(Int)
    case rateNotSupported(Int)
    case verificationFailed(String)

    public var description: String {
        switch self {
        case .unsupportedFormat(let format):
            return "editing is only implemented for profile format 6 and up, device reports \(format)"
        case .stageOutOfRange(let stage):
            return "dpi stage \(stage) does not exist, use 1 to 5"
        case .buttonOutOfRange(let index):
            return "button \(index) does not exist on this device"
        case .dpiOutOfRange(let dpi):
            return "\(dpi) dpi is outside the range the sensor reports"
        case .rateNotSupported(let hertz):
            return "\(hertz) Hz is not in the list this link supports"
        case .verificationFailed(let detail):
            return "wrote the sector but read back something different: \(detail)"
        }
    }
}

/// Mutates a profile sector in place and reseals its checksum, so edits land in onboard
/// memory rather than in a volatile setting the host would own.
public struct ProfileEditor {
    public private(set) var sector: [UInt8]

    private let capabilities: OnboardCapabilities
    private let layout: ProfileLayout

    public init(sector: [UInt8], capabilities: OnboardCapabilities) throws {
        guard capabilities.profileFormat >= 6 else { throw EditError.unsupportedFormat(capabilities.profileFormat) }

        self.sector = sector
        self.capabilities = capabilities
        self.layout = ProfileLayout.forFormat(capabilities.profileFormat)
    }

    public static let stageCount = 5
    private static let stageStride = 5
    private static let stageBase = 0x04

    public mutating func setDpi(stage: Int, x: Int, y: Int? = nil) throws {
        guard (1...ProfileEditor.stageCount).contains(stage) else { throw EditError.stageOutOfRange(stage) }
        guard x == 0 || (100...30000).contains(x) else { throw EditError.dpiOutOfRange(x) }

        let base = ProfileEditor.stageBase + (stage - 1) * ProfileEditor.stageStride

        writeLittle(base, x)
        writeLittle(base + 2, y ?? x)
    }

    public mutating func setLiftOff(stage: Int, level: Int) throws {
        guard (1...ProfileEditor.stageCount).contains(stage) else { throw EditError.stageOutOfRange(stage) }

        let base = ProfileEditor.stageBase + (stage - 1) * ProfileEditor.stageStride
        sector[base + 4] = UInt8(clamping: level)
    }

    public mutating func setReportRate(slot: ReportRateSlot, index: Int) {
        sector[slot.rawValue] = UInt8(clamping: index)
    }

    public mutating func setButton(_ index: Int, action: ButtonAction, shift: Bool = false) throws {
        guard (1...capabilities.buttonCount).contains(index) else { throw EditError.buttonOutOfRange(index) }

        let base = (shift ? layout.shiftButtons : layout.buttons) + (index - 1) * 4

        for (offset, byte) in action.bytes.enumerated() {
            sector[base + offset] = byte
        }
    }

    public mutating func setName(_ name: String) {
        let units = Array(name.utf16.prefix(layout.nameLength / 2 - 1))

        for slot in 0..<(layout.nameLength / 2) {
            let unit = slot < units.count ? units[slot] : 0

            sector[layout.name + slot * 2] = UInt8(unit & 0xFF)
            sector[layout.name + slot * 2 + 1] = UInt8(unit >> 8)
        }
    }

    /// Recomputes the trailing checksum so the device accepts the sector.
    public func sealed() -> [UInt8] {
        var output = sector
        let crc = CRC16.ccitt(output[0..<(output.count - 2)])

        output[output.count - 2] = UInt8(crc >> 8)
        output[output.count - 1] = UInt8(crc & 0xFF)

        return output
    }

    private mutating func writeLittle(_ offset: Int, _ value: Int) {
        sector[offset] = UInt8(value & 0xFF)
        sector[offset + 1] = UInt8((value >> 8) & 0xFF)
    }
}

extension OnboardProfiles {
    /// Writes a sector and reads it back, because a silent corruption here is the one failure that matters.
    public func writeVerified(_ sector: Int, content: [UInt8]) throws {
        try writeSector(sector, content: content)

        let readBack = try readSector(sector)

        guard readBack == content else {
            let differing = zip(readBack, content).enumerated().first { $0.element.0 != $0.element.1 }
            let detail = differing.map { String(format: "offset 0x%02X", $0.offset) } ?? "length differs"

            throw EditError.verificationFailed(detail)
        }
    }
}
