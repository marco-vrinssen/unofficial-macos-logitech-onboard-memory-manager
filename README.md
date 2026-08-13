# Unofficial Logitech Onboard Memory Manager for macOS

**This is not official Logitech software.** It is an independent community tool with
no affiliation to, endorsement by or support from Logitech. "Logitech", "G HUB" and
related marks belong to Logitech and are used here only to describe compatibility.

Edit the settings stored inside a Logitech gaming mouse, natively on macOS. No G HUB,
no drivers, no background services.

> **Disclaimer**
>
> This tool has only been tested with a single mouse, the Logitech G PRO X 2 DEX
> connected through its Lightspeed receiver. It should work with other HID++ 2.0 mice
> that use onboard profile format 6 or newer, but nobody has verified that yet. Writes
> to unverified models are at your own risk. Take a backup first, the tool makes that
> easy.

---

## For Users

### What it does

Gaming mice from Logitech carry a small memory chip that stores their settings. Once
written, the mouse behaves the same on every computer, with no software running. This
app reads and edits that memory directly.

![App](Assets/icon-1024.png)

### Features

- **Sensitivity**: up to five DPI presets, each with its own lift-off distance, the
  height at which tracking stops when you raise the mouse off the pad.
- **Report rate**: how often the mouse talks to the computer, set separately for
  wireless and wired use, up to 8000 Hz on supported mice.
- **Buttons**: assign clicks, DPI switching, media keys or G-Shift to every button,
  including a second G-Shift layer.
- **Transparency**: see the exact bytes stored in the mouse and a check that confirms
  they are undamaged.

Everything is written into the mouse itself and verified by reading it back. The app
never installs anything on your Mac.

### Installing

1. Install Apple's command line tools if you have not: `xcode-select --install`
2. Download this repository.
3. Run `./bundle.sh` in the repository folder. The app appears in `~/Applications`.

### Using it

Open the app. Your mouse appears in the sidebar, its settings load automatically, and
every change saves to the mouse the moment you make it. The status bar at the bottom
tells you what is happening in plain language.

Before experimenting, save a backup from the terminal:

```sh
lomm backup my-mouse-backup.json
```

`lomm` is the command line companion, installed with `./install.sh`.

---

## For Developers

### Architecture

Three SwiftPM targets, no external dependencies:

| Target | Role |
| --- | --- |
| `LogiHIDPP` | Library: IOKit HID transport, HID++ 2.0 protocol, onboard memory access |
| `LogiOnboardApp` | SwiftUI app over the library |
| `lomm` | CLI over the same library, plus raw protocol access for exploring new devices |

### How it talks to the mouse

Logitech mice expose a vendor HID interface on usage page `0xFF00` speaking HID++ 2.0.
`HIDInterface` wraps one such interface via `IOHIDManager`. `HIDPPTransport` frames
20-byte long reports: device index, feature index, function, software id, parameters.
Feature indices are resolved at runtime through feature `0x0000` (root), so nothing is
hardcoded per model.

Discovery pings device indices `0xFF` (wired) and `1` to `6` (receiver slots) on every
Logitech HID++ interface, so wired, Lightspeed and Bluetooth links resolve identically.
A sleeping wireless mouse ignores the first pings, discovery polls until it wakes.

### Onboard memory

Feature `0x8100` exposes the profile memory as sectors. All capabilities are read from
the device at runtime: sector count, sector size, button count, profile format. Writes
go through `ProfileEditor`, which mutates the sector bytes, reseals the trailing
CRC-16/CCITT-FALSE checksum and flashes the sector. Every write is read back and
compared byte for byte before it is reported as done.

The app treats the mouse as a single permanent configuration: onboard mode is enforced
on sight and profile 1 is the editing target.

### Profile format 7 layout

Documented nowhere else at the time of writing, derived from a real device and
corroborated by live feature reads:

| Offset | Content |
| --- | --- |
| `0x00` | Wired report rate index into [125, 250, 500, 1000, 2000, 4000, 8000] |
| `0x01` | Wireless report rate index, verified via feature `0x8061` |
| `0x04` | Five DPI stages, 5 bytes each: dpiX u16le, dpiY u16le, lift-off level |
| `0x2C` | Sleep and power-off timeouts in seconds, u16le each |
| `0x30` | 16 button bindings, 4 bytes each |
| `0x70` | G-Shift layer bindings |
| `0xA0` | Profile name, UTF-16LE, 48 bytes |
| `0xD0` | Lighting effect records, 11 bytes each, vestigial on mice without RGB |
| last 2 | CRC-16/CCITT-FALSE over the preceding bytes |

Button binding encodings follow libratbag: `80 01` mouse mask, `80 02` modifier and
HID key code, `80 03` consumer control, `90 xx` special actions (DPI cycle, G-Shift
and friends), `FF FF FF FF` disabled.

### Hardware quirks worth knowing

- **255-byte sectors are real.** The device reports 255 and means it. A 16-byte read
  crossing that boundary is rejected, the tail must be read as an overlapping chunk.
  Other tools assume the reported 255 means 256 and fail on this hardware.
- **macOS wants the report id in the buffer.** `IOHIDDeviceSetReport` expects the
  report id byte kept in the payload. Stripping it, as Linux and Windows conventions
  suggest, makes every write fail with `kIOReturnBadArgument`.
- **Replies are interleaved with notifications.** Responses are matched against the
  request header, never read positionally.
- **The mouse sleeps after 60 seconds idle** and drops off the receiver. Discovery
  retries until it re-links, around 8 seconds.

### Extending to other mice

`lomm` is the exploration tool:

```sh
lomm list            # what is connected
lomm info            # what the device declares about its memory
lomm dump 1          # hex dump with checksum verdict
lomm raw 2202 5 00 00   # call any HID++ feature function directly
```

Reading is safe everywhere, capabilities come from the device. Editing is gated to
profile format 6 and up. For an older or unknown format, dump the sectors, map the
offsets, then extend `ProfileLayout.forFormat` and `ProfileDecoder`.

### License

MIT, see [LICENSE](LICENSE).
