import Foundation

public struct DpiRange {
    public let from: Int
    public let step: Int
}

public struct SensorReading {
    public let currentDpi: Int
    public let defaultDpi: Int
    public let currentDpiY: Int
    public let defaultDpiY: Int
    public let liftOffDistance: Int
    public let ranges: [DpiRange]

    public var isSquare: Bool { currentDpi == currentDpiY }
}

public struct ReportRateReading {
    public let wired: [Int]
    public let wireless: [Int]
}

/// Feature 0x2202, the sensor resolution a user calls sensitivity.
public enum AdjustableDPI {
    public static func read(_ transport: HIDPPTransport) -> SensorReading? {
        guard let dpi = try? transport.call(feature: Feature.adjustableDPIExtended, function: 5, params: [0, 0]),
              dpi.count >= 10 else { return nil }

        let ranges = (try? transport.call(feature: Feature.adjustableDPIExtended, function: 2, params: [0, 0, 0]))
            .map(parseRanges) ?? []

        return SensorReading(
            currentDpi: big(dpi, 1),
            defaultDpi: big(dpi, 3),
            currentDpiY: big(dpi, 5),
            defaultDpiY: big(dpi, 7),
            liftOffDistance: Int(dpi[9]),
            ranges: ranges
        )
    }

    /// The table alternates a starting resolution with a 0xE0xx marker carrying its step.
    private static func parseRanges(_ payload: [UInt8]) -> [DpiRange] {
        var ranges: [DpiRange] = []
        var pending: Int?
        var offset = 3

        while offset + 1 < payload.count {
            let value = big(payload, offset)
            offset += 2

            guard value != 0 else { break }

            if value & 0xE000 == 0xE000 {
                if let start = pending { ranges.append(DpiRange(from: start, step: value & 0x1FFF)) }
                pending = nil
            } else {
                pending = value
            }
        }

        return ranges
    }

    private static func big(_ bytes: [UInt8], _ offset: Int) -> Int {
        guard offset + 1 < bytes.count else { return 0 }
        return Int(bytes[offset]) << 8 | Int(bytes[offset + 1])
    }
}

/// Feature 0x8061, which reports rates per link because wireless supports more than wired.
public enum ExtendedReportRate {
    public static let hertz = [125, 250, 500, 1000, 2000, 4000, 8000]

    public static func read(_ transport: HIDPPTransport) -> ReportRateReading? {
        guard let wired = capabilities(transport, connection: 0),
              let wireless = capabilities(transport, connection: 1) else { return nil }

        return ReportRateReading(wired: wired, wireless: wireless)
    }

    public static func label(forIndex index: Int) -> String {
        index < hertz.count ? "\(hertz[index]) Hz" : "index \(index)"
    }

    private static func capabilities(_ transport: HIDPPTransport, connection: UInt8) -> [Int]? {
        guard let reply = try? transport.call(feature: Feature.extendedReportRate, function: 0, params: [connection]),
              reply.count >= 2 else { return nil }

        let bitmap = reply[1]

        return hertz.indices.filter { bitmap & (1 << $0) != 0 }.map { hertz[$0] }
    }
}
