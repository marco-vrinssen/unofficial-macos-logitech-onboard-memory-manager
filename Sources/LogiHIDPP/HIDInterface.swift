import Foundation
import IOKit
import IOKit.hid

public enum HIDError: Error, CustomStringConvertible {
    case openFailed(IOReturn)
    case writeFailed(IOReturn)
    case emptyReport

    public var description: String {
        switch self {
        case .openFailed(let code): return "could not open HID interface (0x\(String(code, radix: 16)))"
        case .writeFailed(let code): return String(format: "could not write HID report (0x%08X)", UInt32(bitPattern: code))
        case .emptyReport: return "refused to write an empty report"
        }
    }
}

public struct HIDInterfaceInfo {
    public let vendorId: Int
    public let productId: Int
    public let usagePage: Int
    public let usage: Int
    public let product: String
    public let serial: String
    public let locationId: Int
    public let transport: String
}

/// Thread-safe inbox because input reports arrive on the run loop, not the caller.
private final class ReportInbox {
    private var reports: [[UInt8]] = []
    private let lock = NSLock()

    func push(_ report: [UInt8]) {
        lock.lock()
        reports.append(report)
        lock.unlock()
    }

    func pop() -> [UInt8]? {
        lock.lock()
        defer { lock.unlock() }
        return reports.isEmpty ? nil : reports.removeFirst()
    }

    func drain() {
        lock.lock()
        reports.removeAll()
        lock.unlock()
    }
}

/// One HID interface of a physical device, addressed by usage page and usage.
public final class HIDInterface {
    private static let bufferSize = 64

    let device: IOHIDDevice
    public let info: HIDInterfaceInfo

    private let inbox = ReportInbox()
    private let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: HIDInterface.bufferSize)
    private var isOpen = false

    init(device: IOHIDDevice, info: HIDInterfaceInfo) {
        self.device = device
        self.info = info
    }

    deinit {
        close()
        buffer.deallocate()
    }

    public func open() throws {
        guard !isOpen else { return }

        let result = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
        guard result == kIOReturnSuccess else { throw HIDError.openFailed(result) }

        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDDeviceRegisterInputReportCallback(device, buffer, HIDInterface.bufferSize, inputReportCallback, context)
        IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)

        isOpen = true
    }

    public func close() {
        guard isOpen else { return }

        IOHIDDeviceUnscheduleFromRunLoop(device, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))

        isOpen = false
    }

    /// Discard stale replies so a fresh request is not matched against an old one.
    public func flush() {
        while CFRunLoopRunInMode(.defaultMode, 0, true) == .handledSource {}
        inbox.drain()
    }

    public func write(_ report: [UInt8]) throws {
        guard let reportId = report.first else { throw HIDError.emptyReport }

        // Keep the report id in the buffer because IOKit expects it for numbered reports
        let result = report.withUnsafeBufferPointer { pointer in
            IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, CFIndex(reportId), pointer.baseAddress!, report.count)
        }

        guard result == kIOReturnSuccess else { throw HIDError.writeFailed(result) }
    }

    public func read(timeout: TimeInterval) -> [UInt8]? {
        if let report = inbox.pop() { return report }

        let deadline = Date().addingTimeInterval(timeout)

        while Date() < deadline {
            CFRunLoopRunInMode(.defaultMode, 0.005, true)

            if let report = inbox.pop() { return report }
        }

        return nil
    }

    fileprivate func receive(reportId: UInt32, bytes: UnsafePointer<UInt8>, length: Int) {
        var report = [UInt8](UnsafeBufferPointer(start: bytes, count: length))
        let identifier = UInt8(truncatingIfNeeded: reportId)

        // Prepend the report id because IOKit may deliver it out of band
        if report.first != identifier {
            report.insert(identifier, at: 0)
        }

        inbox.push(report)
    }
}

private let inputReportCallback: IOHIDReportCallback = { context, _, _, _, reportId, report, reportLength in
    guard let context else { return }

    let interface = Unmanaged<HIDInterface>.fromOpaque(context).takeUnretainedValue()
    interface.receive(reportId: reportId, bytes: report, length: Int(reportLength))
}

extension HIDInterface {
    public static func discover(vendorId: Int, usagePage: Int) -> [HIDInterface] {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let matching: [String: Any] = [kIOHIDVendorIDKey: vendorId, kIOHIDPrimaryUsagePageKey: usagePage]

        IOHIDManagerSetDeviceMatching(manager, matching as CFDictionary)
        IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))

        guard let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> else { return [] }

        return devices.map { device in
            let info = HIDInterfaceInfo(
                vendorId: intProperty(device, kIOHIDVendorIDKey) ?? 0,
                productId: intProperty(device, kIOHIDProductIDKey) ?? 0,
                usagePage: intProperty(device, kIOHIDPrimaryUsagePageKey) ?? 0,
                usage: intProperty(device, kIOHIDPrimaryUsageKey) ?? 0,
                product: stringProperty(device, kIOHIDProductKey) ?? "Unknown",
                serial: stringProperty(device, kIOHIDSerialNumberKey) ?? "",
                locationId: intProperty(device, kIOHIDLocationIDKey) ?? 0,
                transport: stringProperty(device, kIOHIDTransportKey) ?? ""
            )

            return HIDInterface(device: device, info: info)
        }
    }

    private static func intProperty(_ device: IOHIDDevice, _ key: String) -> Int? {
        IOHIDDeviceGetProperty(device, key as CFString) as? Int
    }

    private static func stringProperty(_ device: IOHIDDevice, _ key: String) -> String? {
        IOHIDDeviceGetProperty(device, key as CFString) as? String
    }
}
