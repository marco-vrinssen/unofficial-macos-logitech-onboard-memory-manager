import Foundation
import LogiHIDPP

struct DeviceRow: Identifiable, Equatable {
    let id: String
    let name: String
    let productId: Int
    let connection: String
    let protocolVersion: String
    let hasOnboard: Bool
}

struct OnboardState {
    let capabilities: OnboardCapabilities
    let mode: OnboardMode
    let currentProfile: Int
    let slots: [ProfileSlot]
    let sensor: SensorReading?
    let rates: ReportRateReading?
}

struct ProfileState {
    let slot: ProfileSlot
    let decoded: DecodedProfile
    let sector: [UInt8]
    let crcValid: Bool
}

enum ServiceError: Error, CustomStringConvertible {
    case noDevice

    var description: String { "no Logitech device with onboard memory is connected" }
}

/// Owns every HID conversation. Each operation reopens the device on the worker thread,
/// because IOKit delivers input reports to the run loop of whichever thread scheduled it.
final class MouseService: ObservableObject {
    @Published private(set) var devices: [DeviceRow] = []
    @Published private(set) var onboard: OnboardState?
    @Published private(set) var profile: ProfileState?
    @Published private(set) var status = "Ready"
    @Published private(set) var busy = false
    @Published private(set) var selectedDeviceId: String?
    @Published private(set) var selectedProfile = 1

    private let queue = DispatchQueue(label: "logionboard.hid")

    func refresh() {
        perform("Looking for your mouse…") { [weak self] in
            let found = DeviceDiscovery.findDevices(waitingUpTo: 12)
            let rows = found.map { device in
                DeviceRow(
                    id: device.info.id,
                    name: device.info.name,
                    productId: device.info.productId,
                    connection: device.info.connection.rawValue,
                    protocolVersion: device.info.protocolVersion,
                    hasOnboard: device.supportsOnboardProfiles
                )
            }

            guard let self else { return }

            let wanted = self.currentSelection(in: rows)

            guard let device = found.first(where: { $0.info.id == wanted }),
                  let profiles = try? OnboardProfiles(transport: device.transport) else {
                self.publish {
                    self.devices = rows
                    self.selectedDeviceId = wanted
                    self.onboard = nil
                    self.profile = nil
                    self.status = rows.isEmpty ? "No Logitech mouse found" : "This device cannot store settings"
                }
                return
            }

            let index = self.readOnMain { $0.selectedProfile }
            let (state, profileState) = try self.readState(device, profiles, profileIndex: index)

            self.publish {
                self.devices = rows
                self.selectedDeviceId = wanted
                self.onboard = state
                self.profile = profileState
                self.selectedProfile = profileState?.slot.index ?? index
                self.status = "Connected to \(device.info.name)"
            }
        }
    }

    func select(device id: String) {
        publish { self.selectedDeviceId = id }
        refresh()
    }

    func select(profile index: Int) {
        publish { self.selectedProfile = index }

        perform("Reading settings…") { [weak self] in
            guard let self else { return }

            try self.withDevice { device, profiles in
                let (state, profileState) = try self.readState(device, profiles, profileIndex: index)

                self.publish {
                    self.onboard = state
                    self.profile = profileState
                    self.status = "Settings loaded"
                }
            }
        }
    }

    func setMode(_ mode: OnboardMode) {
        perform("Switching storage mode…") { [weak self] in
            guard let self else { return }

            try self.withDevice { device, profiles in
                try profiles.setMode(mode)

                let index = self.readOnMain { $0.selectedProfile }
                let (state, profileState) = try self.readState(device, profiles, profileIndex: index)

                self.publish {
                    self.onboard = state
                    self.profile = profileState
                    self.status = mode == .onboard ? "The mouse now stores its own settings" : "The computer now controls the settings"
                }
            }
        }
    }

    func activate(profile index: Int) {
        perform("Activating profile \(index)…") { [weak self] in
            guard let self else { return }

            try self.withDevice { device, profiles in
                // The host owns the active profile in host mode, so the device rejects the change
                guard (try? profiles.mode) == .onboard else {
                    self.publish { self.status = "Switch to onboard mode first" }
                    return
                }

                try profiles.setCurrentProfile(index)

                let (state, profileState) = try self.readState(device, profiles, profileIndex: index)

                self.publish {
                    self.onboard = state
                    self.profile = profileState
                    self.selectedProfile = index
                    self.status = "Profile \(index) is now active"
                }
            }
        }
    }

    func backup(to url: URL) {
        perform("Saving a backup…") { [weak self] in
            guard let self else { return }

            try self.withDevice { device, profiles in
                let file = try BackupFile.capture(from: device, profiles: profiles)
                try file.write(to: url)

                self.publish { self.status = "Backup saved as \(url.lastPathComponent)" }
            }
        }
    }

    func restore(from url: URL) {
        perform("Writing the backup to the mouse…") { [weak self] in
            guard let self else { return }

            try self.withDevice { device, profiles in
                let file = try BackupFile.read(from: url)
                try file.check(against: device, profiles: profiles)

                for (sector, content) in try file.decodedSectors() {
                    try profiles.writeSector(sector, content: content)
                }

                let index = self.readOnMain { $0.selectedProfile }
                let (state, profileState) = try self.readState(device, profiles, profileIndex: index)

                self.publish {
                    self.onboard = state
                    self.profile = profileState
                    self.status = "Backup restored to the mouse"
                }
            }
        }
    }

    func setDpi(stage: Int, dpi: Int) {
        edit("Saving sensitivity…", done: "Stage \(stage) is now \(dpi) dpi") { try $0.setDpi(stage: stage, x: dpi) }
    }

    func setLiftOff(stage: Int, level: Int) {
        edit("Saving lift-off…", done: "Stage \(stage) lift-off is now level \(level)") {
            try $0.setLiftOff(stage: stage, level: level)
        }
    }

    func setReportRate(slot: ReportRateSlot, hertz: Int) {
        guard let index = ExtendedReportRate.hertz.firstIndex(of: hertz) else { return }

        edit("Saving report rate…", done: "\(slot.label.capitalized) report rate is now \(hertz) Hz") {
            $0.setReportRate(slot: slot, index: index)
        }
    }

    func setButton(_ index: Int, action: ButtonAction, describedAs label: String, shift: Bool) {
        edit("Saving button \(index)…", done: "Button \(index) is now \(label)") {
            try $0.setButton(index, action: action, shift: shift)
        }
    }

    func setName(_ name: String) {
        edit("Renaming…", done: "Renamed to \(name)") { $0.setName(name) }
    }

    /// Read, mutate, reseal and flash the selected profile, then reload from the device.
    private func edit(_ doing: String, done: String, _ mutate: @escaping (inout ProfileEditor) throws -> Void) {
        perform(doing) { [weak self] in
            guard let self else { return }

            try self.withDevice { device, profiles in
                let index = self.readOnMain { $0.selectedProfile }

                guard let slot = (try profiles.profileDirectory()).first(where: { $0.index == index }) else {
                    throw ServiceError.noDevice
                }

                var editor = try ProfileEditor(
                    sector: try profiles.readSector(slot.sector),
                    capabilities: profiles.capabilities
                )

                try mutate(&editor)
                try profiles.writeVerified(slot.sector, content: editor.sealed())

                let (state, profileState) = try self.readState(device, profiles, profileIndex: index)

                self.publish {
                    self.onboard = state
                    self.profile = profileState
                    self.status = done
                }
            }
        }
    }

    private func currentSelection(in rows: [DeviceRow]) -> String? {
        let wanted = readOnMain { $0.selectedDeviceId }

        if let wanted, rows.contains(where: { $0.id == wanted }) { return wanted }

        return rows.first(where: \.hasOnboard)?.id ?? rows.first?.id
    }

    private func withDevice<T>(_ body: (LogiDevice, OnboardProfiles) throws -> T) throws -> T {
        let found = DeviceDiscovery.findDevices(waitingUpTo: 12)
        let wanted = readOnMain { $0.selectedDeviceId }

        guard let device = found.first(where: { $0.info.id == wanted }) ?? found.first(where: \.supportsOnboardProfiles),
              let profiles = try? OnboardProfiles(transport: device.transport) else {
            throw ServiceError.noDevice
        }

        return try body(device, profiles)
    }

    private func readState(_ device: LogiDevice, _ profiles: OnboardProfiles, profileIndex: Int) throws -> (OnboardState, ProfileState?) {
        // The mouse must own its settings permanently, so host mode is corrected on sight
        if (try? profiles.mode) == .host {
            try? profiles.setMode(.onboard)
        }

        let capabilities = profiles.capabilities
        let slots = (try? profiles.profileDirectory()) ?? []

        let state = OnboardState(
            capabilities: capabilities,
            mode: (try? profiles.mode) ?? .host,
            currentProfile: (try? profiles.currentProfile) ?? 0,
            slots: slots,
            sensor: AdjustableDPI.read(device.transport),
            rates: ExtendedReportRate.read(device.transport)
        )

        guard let slot = slots.first(where: { $0.index == profileIndex }) ?? slots.first else { return (state, nil) }

        let sector = try profiles.readSector(slot.sector)
        let stored = UInt16(sector[sector.count - 2]) << 8 | UInt16(sector[sector.count - 1])

        let profileState = ProfileState(
            slot: slot,
            decoded: ProfileDecoder.decode(sector: sector, capabilities: capabilities),
            sector: sector,
            crcValid: stored == CRC16.ccitt(sector[0..<(sector.count - 2)])
        )

        return (state, profileState)
    }

    private func perform(_ label: String, _ work: @escaping () throws -> Void) {
        publish {
            self.busy = true
            self.status = label
        }

        queue.async {
            do {
                try work()
            } catch {
                self.publish { self.status = "Problem: \(error)" }
            }

            self.publish { self.busy = false }
        }
    }

    private func publish(_ block: @escaping () -> Void) {
        if Thread.isMainThread {
            block()
        } else {
            DispatchQueue.main.async(execute: block)
        }
    }

    private func readOnMain<T>(_ block: @escaping (MouseService) -> T) -> T {
        if Thread.isMainThread { return block(self) }

        return DispatchQueue.main.sync { block(self) }
    }
}
