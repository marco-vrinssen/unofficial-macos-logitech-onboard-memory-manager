import Foundation

public struct ButtonBinding {
    public let index: Int
    public let raw: [UInt8]
    public let action: String
}

public struct DpiStage {
    public let index: Int
    public let dpiX: Int
    public let dpiY: Int
    public let liftOffDistance: Int

    public var isUsed: Bool { dpiX > 0 }
}

public struct DecodedProfile {
    public let name: String
    public let buttons: [ButtonBinding]
    public let shiftButtons: [ButtonBinding]
    public let dpiStages: [DpiStage]
    public let reportRateIndex: Int?
}

/// Byte offsets of the parts of a profile sector, which moved between profile formats.
struct ProfileLayout {
    let buttons: Int
    let shiftButtons: Int
    let name: Int
    let nameLength: Int

    /// Verified against a PRO X 2 DEX on format 7; formats 4 and 5 follow the libratbag layout.
    static func forFormat(_ format: UInt8) -> ProfileLayout {
        if format >= 6 {
            return ProfileLayout(buttons: 0x30, shiftButtons: 0x70, name: 0xA0, nameLength: 48)
        }

        return ProfileLayout(buttons: 0x23, shiftButtons: 0x63, name: 0xA3, nameLength: 48)
    }
}

public enum ProfileDecoder {
    public static func decode(sector: [UInt8], capabilities: OnboardCapabilities) -> DecodedProfile {
        let layout = ProfileLayout.forFormat(capabilities.profileFormat)

        return DecodedProfile(
            name: readName(sector, at: layout.name, length: layout.nameLength),
            buttons: readButtons(sector, at: layout.buttons, count: capabilities.buttonCount),
            shiftButtons: readButtons(sector, at: layout.shiftButtons, count: capabilities.buttonCount),
            dpiStages: readDpiStages(sector, format: capabilities.profileFormat),
            reportRateIndex: sector.isEmpty ? nil : Int(sector[0])
        )
    }

    /// Format 7 stores five stages of little endian dpiX, dpiY and lift off distance from 0x04.
    private static func readDpiStages(_ sector: [UInt8], format: UInt8) -> [DpiStage] {
        guard format >= 6 else { return legacyDpiStages(sector) }

        return (0..<5).compactMap { index in
            let base = 0x04 + index * 5
            guard base + 5 <= sector.count else { return nil }

            return DpiStage(
                index: index + 1,
                dpiX: little(sector, base),
                dpiY: little(sector, base + 2),
                liftOffDistance: Int(sector[base + 4])
            )
        }
    }

    private static func legacyDpiStages(_ sector: [UInt8]) -> [DpiStage] {
        (0..<5).compactMap { index in
            let base = 3 + index * 2
            guard base + 2 <= sector.count else { return nil }

            let dpi = little(sector, base)
            return DpiStage(index: index + 1, dpiX: dpi, dpiY: dpi, liftOffDistance: 0)
        }
    }

    private static func little(_ bytes: [UInt8], _ offset: Int) -> Int {
        guard offset + 1 < bytes.count else { return 0 }
        return Int(bytes[offset]) | Int(bytes[offset + 1]) << 8
    }

    private static func readName(_ sector: [UInt8], at offset: Int, length: Int) -> String {
        guard offset + length <= sector.count else { return "" }

        var units: [UInt16] = []

        for position in stride(from: offset, to: offset + length, by: 2) {
            let unit = UInt16(sector[position]) | UInt16(sector[position + 1]) << 8
            guard unit != 0 else { break }

            units.append(unit)
        }

        return String(decoding: units, as: UTF16.self)
    }

    private static func readButtons(_ sector: [UInt8], at offset: Int, count: Int) -> [ButtonBinding] {
        (0..<count).compactMap { index in
            let base = offset + index * 4
            guard base + 4 <= sector.count else { return nil }

            let raw = Array(sector[base..<base + 4])
            return ButtonBinding(index: index + 1, raw: raw, action: describe(raw))
        }
    }

    private static func describe(_ raw: [UInt8]) -> String {
        let value = UInt16(raw[2]) << 8 | UInt16(raw[3])

        switch (raw[0], raw[1]) {
        case (0xFF, _):
            return "disabled"
        case (0x80, 0x01):
            return mouseButton(value)
        case (0x80, 0x02):
            return "key \(modifiers(raw[2]))0x\(String(raw[3], radix: 16))"
        case (0x80, 0x03):
            return String(format: "consumer control 0x%04X", Int(value))
        case (0x90, _):
            return specialAction(raw)
        case (0x00, _):
            return "macro at sector \(raw[1]) offset \(value & 0xFF)"
        default:
            return "unknown"
        }
    }

    private static func mouseButton(_ mask: UInt16) -> String {
        let names = [1: "left click", 2: "right click", 4: "middle click", 8: "back", 16: "forward"]

        if let name = names[Int(mask)] { return name }

        return "mouse button mask 0x\(String(mask, radix: 16))"
    }

    private static func modifiers(_ flags: UInt8) -> String {
        let names = [(0x01, "ctrl"), (0x02, "shift"), (0x04, "alt"), (0x08, "cmd")]
        let active = names.filter { flags & UInt8($0.0) != 0 }.map(\.1)

        return active.isEmpty ? "" : active.joined(separator: "+") + "+"
    }

    /// Special action ids per libratbag and omm.py, byte 1 of a 0x90 binding.
    static let specialNames: [UInt8: String] = [
        0: "no action", 1: "wheel left", 2: "wheel right", 3: "dpi up", 4: "dpi down",
        5: "dpi cycle", 6: "default dpi", 7: "dpi shift", 8: "next profile", 9: "previous profile",
        10: "cycle profile", 11: "g-shift", 12: "battery indicator", 13: "enable profile",
        14: "performance mode", 15: "host switch", 16: "scroll down", 17: "scroll up",
    ]

    private static func specialAction(_ raw: [UInt8]) -> String {
        if let action = specialNames[raw[1]] { return action }

        return "special 0x" + raw.map { String(format: "%02x", $0) }.joined()
    }
}
