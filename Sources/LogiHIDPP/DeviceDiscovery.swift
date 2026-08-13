import Foundation

public enum Feature {
    public static let root: UInt16 = 0x0000
    public static let featureSet: UInt16 = 0x0001
    public static let deviceName: UInt16 = 0x0005
    public static let adjustableDPI: UInt16 = 0x2201
    public static let adjustableDPIExtended: UInt16 = 0x2202
    public static let reportRate: UInt16 = 0x8060
    public static let extendedReportRate: UInt16 = 0x8061
    public static let onboardProfiles: UInt16 = 0x8100
}

public enum Connection: String {
    case wired
    case receiver
    case bluetooth
}

public struct LogiDeviceInfo {
    public let name: String
    public let productId: Int
    public let deviceIndex: UInt8
    public let protocolVersion: String
    public let connection: Connection
    public let interfaceProduct: String
    public let serial: String
    public let locationId: Int

    /// Stable across reconnects of the same port and slot, so the UI can keep a selection.
    public var id: String { "\(locationId)-\(deviceIndex)" }
}

public final class LogiDevice {
    public let transport: HIDPPTransport
    public let info: LogiDeviceInfo

    init(transport: HIDPPTransport, info: LogiDeviceInfo) {
        self.transport = transport
        self.info = info
    }

    public var supportsOnboardProfiles: Bool {
        transport.supports(feature: Feature.onboardProfiles)
    }
}

public enum DeviceDiscovery {
    static let logitechVendorId = 0x046D
    static let hidppUsagePage = 0xFF00

    /// Device index 0xFF addresses a directly attached device, 1 to 6 address receiver slots.
    public static let probedIndices: [UInt8] = [0xFF, 1, 2, 3, 4, 5, 6]

    /// A sleeping wireless mouse ignores the first pings, so keep probing until it wakes.
    public static func findDevices(waitingUpTo seconds: TimeInterval = 0) -> [LogiDevice] {
        let deadline = Date().addingTimeInterval(seconds)

        while true {
            let found = probeOnce()

            if !found.isEmpty || Date() >= deadline { return found }

            Thread.sleep(forTimeInterval: 0.4)
        }
    }

    private static func probeOnce() -> [LogiDevice] {
        var devices: [LogiDevice] = []
        var seen = Set<String>()

        for interface in HIDInterface.discover(vendorId: logitechVendorId, usagePage: hidppUsagePage) {
            guard (try? interface.open()) != nil else { continue }

            for index in probedIndices {
                let transport = HIDPPTransport(interface: interface, deviceIndex: index)

                guard let version = transport.ping() else { continue }

                let key = "\(interface.info.locationId)-\(index)"
                guard seen.insert(key).inserted else { continue }

                devices.append(LogiDevice(transport: transport, info: describe(transport, interface, index, version)))
            }
        }

        return devices
    }

    private static func describe(
        _ transport: HIDPPTransport,
        _ interface: HIDInterface,
        _ index: UInt8,
        _ version: (major: UInt8, minor: UInt8)
    ) -> LogiDeviceInfo {
        let connection: Connection = {
            if interface.info.transport.lowercased().contains("bluetooth") { return .bluetooth }
            return index == 0xFF ? .wired : .receiver
        }()

        return LogiDeviceInfo(
            name: readName(transport) ?? interface.info.product,
            productId: interface.info.productId,
            deviceIndex: index,
            protocolVersion: "\(version.major).\(version.minor)",
            connection: connection,
            interfaceProduct: interface.info.product,
            serial: interface.info.serial,
            locationId: interface.info.locationId
        )
    }

    private static func readName(_ transport: HIDPPTransport) -> String? {
        guard let count = try? transport.call(feature: Feature.deviceName, function: 0).first, count > 0 else { return nil }

        var name = ""

        while name.utf8.count < Int(count) {
            guard let chunk = try? transport.call(feature: Feature.deviceName, function: 1, params: [UInt8(name.utf8.count)]) else { break }

            let text = String(decoding: chunk.prefix(16).prefix { $0 != 0 }, as: UTF8.self)
            guard !text.isEmpty else { break }

            name += text
        }

        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
