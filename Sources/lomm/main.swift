import Foundation
import LogiHIDPP

let usage = """
lomm - Logitech onboard memory manager for macOS

Usage:
  lomm list                      list connected Logitech HID++ devices
  lomm info                      show onboard memory capabilities
  lomm mode [onboard|host]       show or set which side owns the settings
  lomm sensor                    resolution, lift off and report rate
  lomm profile [n]               decoded profile name and button bindings
  lomm dump [sector]             hex dump a sector, defaults to the directory
  lomm backup <file.json>        save every readable sector byte for byte
  lomm restore <file.json>       write a backup back to the mouse
  lomm set dpi <stage> <dpi>     write a resolution stage into onboard memory
  lomm set lod <stage> <level>   write the lift off level of a stage
  lomm set rate wired|wireless <hz>
  lomm set button <n> <action>   left right middle back forward disabled raw:aabbccdd
  lomm set name <text>           rename the profile
  lomm raw <feature> <fn> [args] call any HID++ feature, for exploring new models
  lomm hid                       interface and device index diagnostics

Options:
  --device <n>                   pick a device from "lomm list", defaults to the first with onboard memory
  --profile <n>                  which profile to edit, defaults to 1
  --shift                        target the G-Shift layer of "set button"
  --y <dpi>                      separate vertical resolution for "set dpi"
"""

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(1)
}

func column(_ text: String, _ width: Int) -> String {
    text.count >= width ? text : text + String(repeating: " ", count: width - text.count)
}

func spacedHex(_ bytes: [UInt8]) -> String {
    bytes.map { String(format: "%02x", $0) }.joined(separator: " ")
}

var arguments = Array(CommandLine.arguments.dropFirst())
var deviceChoice: Int?
var profileChoice = 1
var yOverride: Int?
var shiftLayer = false

func takeFlag(_ name: String) -> String? {
    guard let flag = arguments.firstIndex(of: name), flag + 1 < arguments.count else { return nil }

    let value = arguments[flag + 1]
    arguments.removeSubrange(flag...flag + 1)

    return value
}

if let index = arguments.firstIndex(of: "--shift") {
    shiftLayer = true
    arguments.remove(at: index)
}

if let value = takeFlag("--profile"), let parsed = Int(value) { profileChoice = parsed }
if let value = takeFlag("--y"), let parsed = Int(value) { yOverride = parsed }

if let flag = arguments.firstIndex(of: "--device") {
    guard flag + 1 < arguments.count, let value = Int(arguments[flag + 1]) else { fail("--device needs a number") }
    deviceChoice = value
    arguments.removeSubrange(flag...flag + 1)
}

guard let command = arguments.first else {
    print(usage)
    exit(0)
}

if command == "hid" {
    let interfaces = HIDInterface.discover(vendorId: 0x046D, usagePage: 0xFF00)
    print("matched \(interfaces.count) Logitech HID++ interfaces")

    for interface in interfaces {
        let info = interface.info
        let opened = (try? interface.open()) != nil

        print(String(format: "  pid 0x%04X usage %d/%d loc 0x%08X %@ open=%@",
                     info.productId, info.usagePage, info.usage, info.locationId,
                     info.transport, opened ? "yes" : "no"))

        guard opened else { continue }

        for index in DeviceDiscovery.probedIndices {
            let transport = HIDPPTransport(interface: interface, deviceIndex: index)

            do {
                let reply = try transport.rawCall(featureIndex: 0, function: 1, params: [0, 0, 0x5A], timeout: 0.4)
                print(String(format: "    index 0x%02X -> %@", index, reply.map { String(format: "%02x", $0) }.joined(separator: " ")))
            } catch {
                print(String(format: "    index 0x%02X -> %@", index, "\(error)"))
            }
        }
    }

    exit(0)
}

let devices = DeviceDiscovery.findDevices(waitingUpTo: 12)

if command == "list" {
    guard !devices.isEmpty else { fail("no Logitech HID++ devices found") }

    for (index, device) in devices.enumerated() {
        let onboard = device.supportsOnboardProfiles ? "onboard memory" : "no onboard memory"

        print("[\(index)] \(device.info.name)")
        print(String(format: "     pid 0x%04X  index 0x%02X  %@  hid++ %@  %@",
                     device.info.productId, device.info.deviceIndex, device.info.connection.rawValue,
                     device.info.protocolVersion, onboard))
    }

    exit(0)
}

func selectedDevice() -> LogiDevice {
    if let choice = deviceChoice {
        guard choice >= 0, choice < devices.count else { fail("no device at index \(choice)") }
        return devices[choice]
    }

    guard let device = devices.first(where: { $0.supportsOnboardProfiles }) else {
        fail("no connected device exposes onboard memory")
    }

    return device
}

let device = selectedDevice()

guard let profiles = try? OnboardProfiles(transport: device.transport) else {
    fail("\(device.info.name) does not expose onboard memory")
}

let capabilities = profiles.capabilities

switch command {
case "info":
    print("device:           \(device.info.name)")
    print(String(format: "product id:       0x%04X", device.info.productId))
    print("connection:       \(device.info.connection.rawValue)")
    print("hid++ version:    \(device.info.protocolVersion)")
    print("")
    print("profile format:   \(capabilities.profileFormat)")
    print("macro format:     \(capabilities.macroFormat)")
    print("profiles:         \(capabilities.profileCount) (\(capabilities.profileCountOutOfBox) out of box)")
    print("buttons:          \(capabilities.buttonCount)")
    print("sectors:          \(capabilities.sectorCount) x \(capabilities.sectorSize) bytes")

    if let mode = try? profiles.mode {
        print("mode:             \(mode.label)")

        if mode == .host {
            print("")
            print("onboard profiles are inactive. run \"lomm mode onboard\" to hand control to the mouse.")
        }
    }

    if let slots = try? profiles.profileDirectory(), !slots.isEmpty {
        print("")
        print("profile  sector  state")

        for slot in slots {
            print(String(format: "%7d  %6d  %@", slot.index, slot.sector, slot.enabled ? "enabled" : "disabled"))
        }
    }

case "mode":
    if arguments.count == 1 {
        guard let mode = try? profiles.mode else { fail("could not read onboard mode") }
        print(mode.label)
        exit(0)
    }

    guard let mode = OnboardMode(rawValue: arguments[1] == "onboard" ? 1 : arguments[1] == "host" ? 2 : 0) else {
        fail("mode must be \"onboard\" or \"host\"")
    }

    do {
        try profiles.setMode(mode)
        print("mode set to \(mode.label)")
    } catch {
        fail("\(error)")
    }

case "dump":
    let sector = arguments.count > 1 ? Int(arguments[1]) ?? 0 : 0

    do {
        let content = try profiles.readSector(sector)

        for offset in stride(from: 0, to: content.count, by: 16) {
            let row = content[offset..<min(offset + 16, content.count)]
            print(String(format: "%04x  ", offset) + row.map { String(format: "%02x", $0) }.joined(separator: " "))
        }

        let stored = UInt16(content[content.count - 2]) << 8 | UInt16(content[content.count - 1])
        let computed = CRC16.ccitt(content[0..<(content.count - 2)])

        print("")
        print(String(format: "crc stored 0x%04X  computed 0x%04X  %@",
                     stored, computed, stored == computed ? "match" : "MISMATCH"))
    } catch {
        fail("\(error)")
    }

case "sensor":
    if let sensor = AdjustableDPI.read(device.transport) {
        print("resolution:       \(sensor.currentDpi) dpi")
        print("default:          \(sensor.defaultDpi) dpi")
        print("vertical:         \(sensor.isSquare ? "linked" : "\(sensor.currentDpiY) dpi")")
        print("lift off:         level \(sensor.liftOffDistance)")

        if !sensor.ranges.isEmpty {
            print("adjustable:       " + sensor.ranges.map { "from \($0.from) in steps of \($0.step)" }.joined(separator: ", "))
        }
    } else {
        print("device does not expose adjustable dpi")
    }

    if let rates = ExtendedReportRate.read(device.transport) {
        print("rates wired:      " + rates.wired.map { "\($0)" }.joined(separator: " "))
        print("rates wireless:   " + rates.wireless.map { "\($0)" }.joined(separator: " "))
    }

    if let slots = try? profiles.profileDirectory(), let slot = slots.first(where: \.enabled),
       let sector = try? profiles.readSector(slot.sector) {
        let decoded = ProfileDecoder.decode(sector: sector, capabilities: capabilities)

        if let index = decoded.reportRateIndex {
            print("profile rate:     \(ExtendedReportRate.label(forIndex: index))")
        }

        print("")
        print("stage  resolution        lift off")

        for stage in decoded.dpiStages {
            let resolution = stage.isUsed
                ? (stage.dpiX == stage.dpiY ? "\(stage.dpiX) dpi" : "\(stage.dpiX) x \(stage.dpiY) dpi")
                : "unset"

            print("\(column(String(stage.index), 7))\(column(resolution, 18))level \(stage.liftOffDistance)")
        }
    }

case "set":
    guard arguments.count > 2 else { fail("usage: lomm set <dpi|lod|rate|button|name> ...") }

    guard let slots = try? profiles.profileDirectory(),
          let slot = slots.first(where: { $0.index == profileChoice }) else {
        fail("profile \(profileChoice) is not in the directory")
    }

    do {
        var editor = try ProfileEditor(sector: try profiles.readSector(slot.sector), capabilities: capabilities)
        let summary: String

        switch arguments[1] {
        case "dpi":
            guard arguments.count > 3, let stage = Int(arguments[2]), let value = Int(arguments[3]) else {
                fail("usage: lomm set dpi <stage> <dpi>")
            }

            try editor.setDpi(stage: stage, x: value, y: yOverride)
            summary = "profile \(profileChoice) stage \(stage) resolution \(value) dpi"

        case "lod":
            guard arguments.count > 3, let stage = Int(arguments[2]), let level = Int(arguments[3]) else {
                fail("usage: lomm set lod <stage> <level>")
            }

            try editor.setLiftOff(stage: stage, level: level)
            summary = "profile \(profileChoice) stage \(stage) lift off level \(level)"

        case "rate":
            guard arguments.count > 3, let hertz = Int(arguments[3]),
                  let slotChoice = ReportRateSlot.allCases.first(where: { $0.label == arguments[2] }) else {
                fail("usage: lomm set rate wired|wireless <hz>")
            }

            guard let index = ExtendedReportRate.hertz.firstIndex(of: hertz) else {
                fail("\(hertz) Hz is not a rate this protocol defines")
            }

            let supported = ExtendedReportRate.read(device.transport)
            let allowed = slotChoice == .first ? supported?.wired : supported?.wireless

            if let allowed, !allowed.contains(hertz) {
                fail("this link supports " + allowed.map { "\($0)" }.joined(separator: " ") + " Hz")
            }

            editor.setReportRate(slot: slotChoice, index: index)
            summary = "profile \(profileChoice) \(slotChoice.label) report rate \(hertz) Hz"

        case "button":
            guard arguments.count > 3, let index = Int(arguments[2]),
                  let action = ButtonAction.parse(arguments[3]) else {
                fail("usage: lomm set button <n> <left|right|middle|back|forward|disabled|raw:aabbccdd>")
            }

            try editor.setButton(index, action: action, shift: shiftLayer)
            summary = "profile \(profileChoice) \(shiftLayer ? "g-shift " : "")button \(index) -> \(arguments[3])"

        case "name":
            editor.setName(arguments[2])
            summary = "profile \(profileChoice) renamed to \(arguments[2])"

        default:
            fail("unknown field \(arguments[1])")
        }

        try profiles.writeVerified(slot.sector, content: editor.sealed())
        print("wrote \(summary)")
    } catch {
        fail("\(error)")
    }

case "profile":
    let requested = arguments.count > 1 ? Int(arguments[1]) ?? 1 : 1

    guard let slots = try? profiles.profileDirectory(), let slot = slots.first(where: { $0.index == requested }) else {
        fail("profile \(requested) is not in the directory")
    }

    do {
        let decoded = ProfileDecoder.decode(sector: try profiles.readSector(slot.sector), capabilities: capabilities)

        print("profile \(slot.index) \(slot.enabled ? "" : "(disabled) ")in sector \(slot.sector)")
        print("name:  \(decoded.name.isEmpty ? "unnamed" : decoded.name)")
        print("")
        print("button  action                    raw")

        for button in decoded.buttons {
            print("\(column(String(button.index), 6))  \(column(button.action, 26))\(spacedHex(button.raw))")
        }

        let shifted = decoded.shiftButtons.filter { $0.action != "disabled" }

        if !shifted.isEmpty {
            print("")
            print("g-shift action                    raw")

            for button in shifted {
                print("\(column(String(button.index), 6))  \(column(button.action, 26))\(spacedHex(button.raw))")
            }
        }
    } catch {
        fail("\(error)")
    }

case "raw":
    guard arguments.count > 2, let feature = UInt16(arguments[1].replacingOccurrences(of: "0x", with: ""), radix: 16),
          let function = UInt8(arguments[2]) else {
        fail("usage: lomm raw <feature-hex> <function> [param-hex ...]")
    }

    let params = arguments.dropFirst(3).compactMap { UInt8($0.replacingOccurrences(of: "0x", with: ""), radix: 16) }

    do {
        let reply = try device.transport.call(feature: feature, function: function, params: params)
        print(reply.map { String(format: "%02x", $0) }.joined(separator: " "))
    } catch {
        fail("\(error)")
    }

case "backup":
    guard arguments.count > 1 else { fail("backup needs a target file") }

    do {
        let file = try BackupFile.capture(from: device, profiles: profiles)
        try file.write(to: URL(fileURLWithPath: arguments[1]))

        print("saved \(file.sectorCount) sectors from \(device.info.name) to \(arguments[1])")
    } catch {
        fail("\(error)")
    }

case "restore":
    guard arguments.count > 1 else { fail("restore needs a source file") }

    do {
        let file = try BackupFile.read(from: URL(fileURLWithPath: arguments[1]))
        try file.check(against: device, profiles: profiles)

        print("about to overwrite \(file.sectorCount) sectors on \(device.info.name).")
        print("type \"yes\" to continue: ", terminator: "")

        guard readLine()?.trimmingCharacters(in: .whitespacesAndNewlines) == "yes" else {
            print("cancelled")
            exit(0)
        }

        for (sector, content) in try file.decodedSectors() {
            try profiles.writeSector(sector, content: content)
            print("wrote sector \(sector)")
        }

        print("restore complete")
    } catch {
        fail("\(error)")
    }

default:
    print(usage)
    exit(1)
}
