import SwiftUI
import LogiHIDPP

struct ContentView: View {
    @StateObject private var service = MouseService()

    var body: some View {
        VStack(spacing: 0) {
            NavigationSplitView {
                DeviceList(service: service)
            } detail: {
                SettingsForm(service: service)
            }

            statusBar
        }
        .navigationTitle("Logitech Onboard Memory Manager")
        .onAppear { service.refresh() }
    }


    private var statusBar: some View {
        HStack(spacing: 10) {
            if service.busy {
                ProgressView()
                    .controlSize(.small)
            } else {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }

            Text(service.status)
                .foregroundStyle(service.busy ? .primary : .secondary)
                .lineLimit(1)

            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(.quaternary.opacity(0.5), in: statusShape)
        .padding(12)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    /// Corner radius derived from the window shape, applied uniformly to all four corners.
    private var statusShape: AnyShape {
        if #available(macOS 26.0, *) {
            return AnyShape(ConcentricRectangle(corners: .concentric(minimum: 8), isUniform: true))
        }

        return AnyShape(RoundedRectangle(cornerRadius: 10))
    }


}

// MARK: - Sidebar

private struct DeviceList: View {
    @ObservedObject var service: MouseService

    var body: some View {
        List(selection: Binding(
            get: { service.selectedDeviceId },
            set: { if let id = $0 { service.select(device: id) } }
        )) {
            Section("Devices") {
                ForEach(service.devices) { device in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(device.name)

                        Text(String(format: "0x%04X · %@ · HID++ %@",
                                    device.productId, device.connection, device.protocolVersion))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .tag(device.id)
                }
            }
        }
        .navigationSplitViewColumnWidth(min: 190, ideal: 220)
    }
}

// MARK: - Detail

private struct SettingsForm: View {
    @ObservedObject var service: MouseService

    var body: some View {
        if let onboard = service.onboard {
            Form {
                statusSection(onboard)
                sensitivitySection(onboard)
                reportRateSection(onboard)
                buttonSection
                memorySection
            }
            .formStyle(.grouped)
            .disabled(service.busy)
        } else {
            ContentUnavailableView(
                "No Onboard Memory",
                systemImage: "computermouse",
                description: Text("Connect a Logitech mouse with onboard profiles.")
            )
        }
    }

    private func statusSection(_ onboard: OnboardState) -> some View {
        Section {
            if let sensor = onboard.sensor {
                LabeledContent("Live resolution", value: "\(sensor.currentDpi) dpi")
            }
        } footer: {
            Text("Settings are written into the mouse and work on any computer without software.")
        }
    }

    private func sensitivitySection(_ onboard: OnboardState) -> some View {
        Section {
            ForEach(service.profile?.decoded.dpiStages ?? [], id: \.index) { stage in
                DpiStageRow(stage: stage, isLive: stage.isUsed && stage.dpiX == onboard.sensor?.currentDpi) {
                    service.setDpi(stage: stage.index, dpi: $0)
                } commitLiftOff: {
                    service.setLiftOff(stage: stage.index, level: $0)
                }
            }
        } header: {
            Text("Sensitivity")
        } footer: {
            Text("DPI sets how far the pointer moves per centimeter of mouse movement, higher is faster. Lift sensitivity sets how high you can raise the mouse off the pad before it stops tracking, low stops closest to the pad.")
        }
    }

    private func reportRateSection(_ onboard: OnboardState) -> some View {
        Section("Report Rate") {
            ratePicker("Wireless", slot: .second, options: onboard.rates?.wireless ?? [], byte: 1)
            ratePicker("Wired", slot: .first, options: onboard.rates?.wired ?? [], byte: 0)
        }
    }

    private func ratePicker(_ label: String, slot: ReportRateSlot, options: [Int], byte: Int) -> some View {
        Picker(label, selection: Binding(
            get: {
                guard let index = service.profile.map({ Int($0.sector[byte]) }),
                      index < ExtendedReportRate.hertz.count else { return 0 }

                return ExtendedReportRate.hertz[index]
            },
            set: { service.setReportRate(slot: slot, hertz: $0) }
        )) {
            ForEach(options, id: \.self) { hertz in
                Text("\(hertz) Hz").tag(hertz)
            }
        }
        .pickerStyle(.segmented)
    }

    private var buttonSection: some View {
        Section {
            if let profile = service.profile {
                ForEach(Array(profile.decoded.buttons.enumerated()), id: \.offset) { offset, button in
                    LabeledContent("Button \(button.index)") {
                        HStack(alignment: .center, spacing: 12) {
                            ActionPicker(raw: button.raw) {
                                service.setButton(button.index, action: $0, describedAs: $1, shift: false)
                            }

                            ActionPicker(raw: offset < profile.decoded.shiftButtons.count
                                         ? profile.decoded.shiftButtons[offset].raw : []) {
                                service.setButton(button.index, action: $0, describedAs: $1, shift: true)
                            }
                        }
                    }
                }
            }
        } header: {
            HStack {
                Text("Buttons")

                Spacer()

                HStack(spacing: 12) {
                    Text("Primary")
                        .frame(width: 148, alignment: .leading)

                    Text("G-Shift")
                        .frame(width: 148, alignment: .leading)
                }
            }
        } footer: {
            Text("G-Shift assignments apply while a button bound to G-Shift is held.")
        }
    }

    private var memorySection: some View {
        Section {
            if let profile = service.profile {
                LabeledContent("Data check") {
                    Label(
                        profile.crcValid ? "Intact" : "Damaged",
                        systemImage: profile.crcValid ? "checkmark.seal.fill" : "exclamationmark.triangle.fill"
                    )
                    .foregroundStyle(profile.crcValid ? Color.green : Color.red)
                }

                DisclosureGroup("Show the raw stored data") {
                    HexDump(bytes: profile.sector)
                }
            }
        } header: {
            Text("Stored Data")
        } footer: {
            Text("Your settings live on a small memory chip inside the mouse, which is why they work on any computer. The data check confirms the stored copy is undamaged. The raw view shows the exact bytes, you never need it, it is here for transparency.")
        }
    }
}

// MARK: - Rows

private struct DpiStageRow: View {
    let stage: DpiStage
    let isLive: Bool
    let commitDpi: (Int) -> Void
    let commitLiftOff: (Int) -> Void

    @State private var dpi: Int = 0

    var body: some View {
        LabeledContent {
            HStack(spacing: 36) {
                HStack(spacing: 8) {
                    Text("DPI")
                        .foregroundStyle(.secondary)

                    TextField("dpi", value: $dpi, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 70)
                        .onSubmit { if dpi != stage.dpiX { commitDpi(dpi) } }
                }

                HStack(spacing: 8) {
                    Text("Lift Sensitivity")
                        .foregroundStyle(.secondary)

                Picker("Lift-off", selection: Binding(
                    get: { stage.liftOffDistance },
                    set: { commitLiftOff($0) }
                )) {
                    Text("Low").tag(1)
                    Text("Medium").tag(2)
                    Text("High").tag(3)

                    if !(1...3).contains(stage.liftOffDistance) {
                        Text("Level \(stage.liftOffDistance)").tag(stage.liftOffDistance)
                    }
                }
                    .labelsHidden()
                    .frame(width: 110)
                    .help("How high the mouse can be lifted off the pad before the pointer stops moving")
                }
            }
        } label: {
            HStack(spacing: 6) {
                Text("Sensitivity \(stage.index)")

                if isLive {
                    Image(systemName: "circle.fill")
                        .font(.system(size: 6))
                        .foregroundStyle(.tint)
                        .help("Currently active resolution")
                }

                if !stage.isUsed {
                    Text("unset")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .onAppear { dpi = stage.dpiX }
        .onChange(of: stage.dpiX) { newValue in dpi = newValue }
    }
}

/// Native menu picker over the byte-level button binding.
private struct ActionPicker: View {
    let raw: [UInt8]
    let commit: (ButtonAction, String) -> Void

    private static let groups: [(String, [(String, String)])] = [
        ("Mouse", [("Left Click", "left"), ("Right Click", "right"), ("Middle Click", "middle"),
                   ("Back", "back"), ("Forward", "forward")]),
        ("Sensitivity", [("Cycle DPI", "dpi-cycle"), ("DPI Up", "dpi-up"), ("DPI Down", "dpi-down"),
                         ("DPI Shift", "dpi-shift"), ("Default DPI", "dpi-default")]),
        ("Layer", [("G-Shift", "g-shift")]),
        ("Media", [("Play / Pause", "play-pause"), ("Next Track", "next-track"),
                   ("Previous Track", "previous-track"), ("Mute", "mute"),
                   ("Volume Up", "volume-up"), ("Volume Down", "volume-down")]),
        ("Other", [("Scroll Up", "scroll-up"), ("Scroll Down", "scroll-down"),
                   ("Battery Indicator", "battery"), ("Disabled", "disabled")]),
    ]

    /// Reverse map from stored bytes to a menu tag, nil when the binding is something richer.
    private var currentTag: String? {
        guard raw.count == 4 else { return nil }

        switch (raw[0], raw[1]) {
        case (0x80, 0x01):
            let mask = UInt16(raw[2]) << 8 | UInt16(raw[3])
            return ButtonAction.mouseNames.first { $0.value == mask }?.key
        case (0x80, 0x03):
            let usage = UInt16(raw[2]) << 8 | UInt16(raw[3])
            return ButtonAction.mediaNames.first { $0.value == usage }?.key
        case (0x90, _):
            return raw[1] == 0 ? "unassigned" : ButtonAction.specialNames.first { $0.value == raw[1] }?.key
        case (0xFF, 0xFF):
            return "disabled"
        default:
            return nil
        }
    }

    var body: some View {
        Picker("", selection: Binding(
            get: { currentTag ?? "custom" },
            set: { tag in
                guard let action = ButtonAction.parse(tag) else { return }

                let title = ActionPicker.groups.flatMap(\.1).first { $0.1 == tag }?.0 ?? tag
                commit(action, title)
            }
        )) {
            ForEach(ActionPicker.groups, id: \.0) { group in
                Section(group.0) {
                    ForEach(group.1, id: \.1) { entry in
                        Text(entry.0).tag(entry.1)
                    }
                }
            }

            if currentTag == nil {
                Text("Custom").tag("custom")
            } else if currentTag == "unassigned" {
                Text("Unassigned").tag("unassigned")
            }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .frame(width: 148, alignment: .leading)
    }
}

private struct HexDump: View {
    let bytes: [UInt8]

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(stride(from: 0, to: bytes.count, by: 16)), id: \.self) { offset in
                Text(String(format: "%04x  ", offset)
                     + bytes[offset..<min(offset + 16, bytes.count)]
                        .map { String(format: "%02x", $0) }.joined(separator: " "))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
        .textSelection(.enabled)
        .padding(.vertical, 4)
    }
}
