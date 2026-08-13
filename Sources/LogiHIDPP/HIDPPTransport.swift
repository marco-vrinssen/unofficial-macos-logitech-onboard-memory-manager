import Foundation

public enum HIDPPError: Error, CustomStringConvertible {
    case timeout
    case notSupported(feature: UInt16)
    case deviceError(code: UInt8, feature: UInt8, function: UInt8)

    public var description: String {
        switch self {
        case .timeout:
            return "device did not answer in time"
        case .notSupported(let feature):
            return String(format: "device does not support feature 0x%04X", Int(feature))
        case .deviceError(let code, let feature, let function):
            let name = HIDPPError.errorNames[code] ?? "error \(code)"
            return String(format: "device rejected feature 0x%02X function %d: ", Int(feature), Int(function)) + name
        }
    }

    private static let errorNames: [UInt8: String] = [
        1: "unknown", 2: "invalid argument", 3: "out of range", 4: "hardware error",
        5: "logitech internal", 6: "invalid feature index", 7: "invalid function id",
        8: "busy", 9: "unsupported",
    ]
}

/// HID++ 2.0 request and response framing over one physical link.
public final class HIDPPTransport {
    static let longReportId: UInt8 = 0x11
    static let longReportLength = 20
    static let softwareId: UInt8 = 0x0A

    public let interface: HIDInterface
    public let deviceIndex: UInt8

    private var featureIndexCache: [UInt16: UInt8] = [0x0000: 0x00]

    public init(interface: HIDInterface, deviceIndex: UInt8) {
        self.interface = interface
        self.deviceIndex = deviceIndex
    }

    public func call(feature: UInt16, function: UInt8, params: [UInt8] = [], timeout: TimeInterval = 2.0) throws -> [UInt8] {
        let index = try featureIndex(of: feature)
        return try rawCall(featureIndex: index, function: function, params: params, timeout: timeout)
    }

    public func featureIndex(of feature: UInt16) throws -> UInt8 {
        if let cached = featureIndexCache[feature] { return cached }

        let params = [UInt8(feature >> 8), UInt8(feature & 0xFF)]
        let reply = try rawCall(featureIndex: 0, function: 0, params: params, timeout: 1.0)

        guard let index = reply.first, index != 0 else { throw HIDPPError.notSupported(feature: feature) }

        featureIndexCache[feature] = index
        return index
    }

    public func supports(feature: UInt16) -> Bool {
        (try? featureIndex(of: feature)) != nil
    }

    /// Returns the HID++ protocol version, or nil when no device answers at this index.
    public func ping(timeout: TimeInterval = 0.4) -> (major: UInt8, minor: UInt8)? {
        let marker: UInt8 = 0x5A

        guard let reply = try? rawCall(featureIndex: 0, function: 1, params: [0, 0, marker], timeout: timeout),
              reply.count >= 3, reply[2] == marker else { return nil }

        return (reply[0], reply[1])
    }

    public func rawCall(featureIndex: UInt8, function: UInt8, params: [UInt8], timeout: TimeInterval) throws -> [UInt8] {
        let header: [UInt8] = [deviceIndex, featureIndex, (function << 4) | HIDPPTransport.softwareId]

        var report = [HIDPPTransport.longReportId] + header + params
        report += Array(repeating: 0, count: max(0, HIDPPTransport.longReportLength - report.count))
        report = Array(report.prefix(HIDPPTransport.longReportLength))

        interface.flush()
        try interface.write(report)

        let deadline = Date().addingTimeInterval(timeout)

        // Skip unsolicited notifications, which the device interleaves with replies
        while Date() < deadline {
            guard let reply = interface.read(timeout: 0.2), reply.count >= 6 else { continue }

            if reply[1] == deviceIndex, reply[2] == 0xFF, reply[3] == header[1], reply[4] == header[2] {
                throw HIDPPError.deviceError(code: reply[5], feature: featureIndex, function: function)
            }

            if reply[1] == deviceIndex, reply[2] == 0x8F, reply[3] == header[1] {
                throw HIDPPError.deviceError(code: reply[5], feature: featureIndex, function: function)
            }

            if Array(reply[1...3]) == header {
                return Array(reply.dropFirst(4))
            }
        }

        throw HIDPPError.timeout
    }
}
