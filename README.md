# Unofficial Logitech Onboard Memory Manager for macOS

**This is not official Logitech software.** It is an independent community tool with
no affiliation to, endorsement by or support from Logitech. "Logitech", "G HUB" and
related marks belong to Logitech and are used here only to describe compatibility.

Edit the settings stored inside a Logitech gaming mouse, natively on macOS. No G HUB,
no drivers, no background services.

> **Tested on one mouse so far, the Logitech G PRO X 2 DEX**
>
> Every feature in this project was built and verified against that single device, over
> its Lightspeed receiver and over cable. No other model has been confirmed working by
> anyone yet. Reading is safe on any Logitech HID++ mouse. Writing to an untested model
> is at your own risk, so take a backup first. The app makes one for you automatically.

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
- **Safety net**: the app snapshots your mouse's settings the first time it connects,
  so one click puts everything back the way it was. Settings can also be exported to a
  file and imported on any Mac.

Everything is written into the mouse itself and verified by reading it back. The app
never installs anything on your Mac.

### Will it work with my mouse?

| Hardware | Status |
| --- | --- |
| Logitech G PRO X 2 DEX, Lightspeed or wired | Verified, the whole tool was developed on it |
| Other Logitech HID++ 2.0 mice, profile format 6 or newer | Untested. Reading is safe, writing is at your own risk |
| Logitech mice with profile format 5 or older | Reading works, editing is blocked on purpose |
| Logitech keyboards, headsets, non-Logitech devices | Not supported |

Nothing is hardcoded for the DEX. The tool asks the mouse what it can do and works from
that answer, which is why other models have a fair chance of working. That is still a
prediction and not a test result. Before your first write on any other model, run
`lomm info` to see what your device reports, then take a backup. Please open an issue
with that output either way, working or not, so this table can grow.

### Requirements

- macOS 14 Sonoma or newer
- Apple's command line tools, for building. Install with `xcode-select --install`
- A Logitech mouse connected by cable, Lightspeed receiver or Bluetooth

There is no signed download to grab. You build it yourself, which takes about a minute.
G HUB does not need to be installed, and it should be quit if it is.

### Installing

**1. Get the code**

```sh
git clone https://github.com/marco-vrinssen/Logitech-Onboard-Memory-Manager-macOS-Unofficial.git
cd Logitech-Onboard-Memory-Manager-macOS-Unofficial
```

**2. Build the app**

```sh
./bundle.sh
```

That compiles a release build and puts **Logitech Onboard Memory Manager.app** into
`/Applications`. It is signed ad hoc so macOS runs it locally without complaint. To
install elsewhere, set `DEST`, for example `DEST=~/Applications ./bundle.sh`.

**3. Install the command line tool, optional**

```sh
./install.sh
```

`lomm` goes into `/opt/homebrew/bin` when that folder is writable, otherwise into
`~/.local/bin`. Override with `PREFIX=/usr/local/bin ./install.sh`. The script lists
your connected devices when it finishes, so you see immediately whether the mouse was
found.

**Uninstalling**

Delete the app from `/Applications`, delete the `lomm` binary, and delete
`~/Library/Application Support/Logitech Onboard Memory Manager` if you also want the
automatic restore points gone. Nothing else is ever written to your Mac.

### Using the app

Open the app with the mouse connected. It appears under **Devices** in the sidebar and
its settings load by themselves. Every change is written into the mouse the moment you
make it, so there is no save button. The status line at the bottom says what just
happened.

The first time the app sees a mouse, it stores a copy of the untouched settings in
`~/Library/Application Support/Logitech Onboard Memory Manager`. That restore point is
made before anything is changed, so there is always a way back.

| Section | What you do there |
| --- | --- |
| **Sensitivity** | Up to five DPI stages. Each has its own lift sensitivity, meaning how high the mouse can leave the pad before tracking stops |
| **Report Rate** | How often the mouse reports to the Mac, set separately for wireless and wired, up to 8000 Hz where the mouse allows it |
| **Buttons** | Assign clicks, DPI switching or media keys per button. Switch to the **G-Shift** tab for the second layer, which applies while a button bound to G-Shift is held |
| **Backup** | **Restore…** puts the original settings back. **Export…** writes the current settings to a file, **Import…** loads such a file onto this mouse |
| **Stored Data** | Confirms the stored copy is undamaged and shows the raw bytes. Informational only, you never need it |

Moving to another Mac needs nothing at all. The settings live in the mouse, so they
follow the hardware. Export and Import exist for keeping copies, not for syncing.

### Using the command line tool

`lomm` does everything the app does, plus raw protocol access for exploring a new
model. Run it with no arguments for the full usage text.

**Look before you write**

```sh
lomm list          # which Logitech devices are connected
lomm info          # what the mouse reports about its own memory
lomm sensor        # current dpi stages, lift off and report rates
lomm profile       # decoded profile name and every button binding
```

**Back up, always do this first**

```sh
lomm backup ~/mouse-original.json
lomm restore ~/mouse-original.json   # asks you to type "yes" before it writes
```

**Change settings**

```sh
lomm set dpi 1 1600            # stage 1 to 1600 dpi
lomm set lod 1 2               # stage 1 lift off to level 2
lomm set rate wireless 2000    # 2000 Hz over the receiver
lomm set button 4 back         # button 4 becomes Back
lomm set button 4 forward --shift   # same button on the G-Shift layer
lomm set name "Daily"          # rename the profile
```

Useful flags: `--device <n>` picks a device from `lomm list` when several are
connected, `--profile <n>` chooses which profile to edit and defaults to 1, `--y <dpi>`
sets a separate vertical resolution for `set dpi`.

Every write is read back and compared byte for byte before `lomm` reports success.

### If something goes wrong

- **No device found.** Wireless mice sleep after about 60 seconds idle. Move the mouse
  and run the command again. Discovery already waits and retries for roughly 12
  seconds.
- **`lomm info` says the mode is host.** The computer owns the settings, so the onboard
  profile is inactive. Run `lomm mode onboard` to hand control back to the mouse. The
  app does this by itself.
- **G HUB is running.** Quit it. Two programs writing the same memory is asking for
  trouble.
- **Editing is refused.** Profile formats older than 6 are read only here, on purpose.
  `lomm info` prints the format your mouse uses.
- **Something looks wrong after a change.** Use **Restore…** in the app, or
  `lomm restore` with your backup file.

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
