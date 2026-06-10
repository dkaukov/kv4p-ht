# KV4P-HT iOS App

**Source:** `ios-src/KV4P HT/`
**Goal:** Native SwiftUI client for the KV4P-HT over BLE — voice RX/TX, APRS, memories — replacing the need for the Android/USB path on iPhone.
**Status:** Core voice path working. Background audio + PTT-only mic indicator implemented 2026-06-09; both need on-device verification. Full APRS (RX parse + message TX/ack + position beacon + map pins + settings) implemented 2026-06-09; needs on-air verification.

The firmware this app talks to is **dkaukov's fork, branch `feature/ble`**
(https://github.com/dkaukov/kv4p-ht/tree/feature/ble), *not* this repo's
`microcontroller-src/`. Always check that fork for protocol ground truth.

---

## Architecture

| File | Role |
|------|------|
| `BLEManager.swift` | `CBCentralManager` + `CBPeripheralDelegate` on a dedicated `bleQueue`. Scans/connects, KISS framing in/out, owns the `AudioManager`. |
| `AudioManager.swift` | Swift `actor`. AVAudioEngine playback via `AVAudioSourceNode` fed from a lock-free SPSC ring buffer; inline IMA ADPCM decode (RX) and encode (TX mic tap). |
| `KissProtocol.swift` | KISS framing + KV4P vendor frame build/parse. Also builds raw KISS DATA frames (cmd 0x00) carrying AX.25 bytes for APRS. |
| `RadioStore.swift` | `@Observable` app state: frequency, squelch, PTT, memories, APRS settings, scene-phase hooks. |
| `AX25.swift` | AX.25 UI-frame codec: callsign encode/decode, frame encode/decode (no FCS — firmware appends it). |
| `APRS.swift` | APRS payload parse/build by DTI: position (compressed + uncompressed), message/ack, object, weather. |
| `APRSController.swift` | `@Observable` APRS state: `APRSEntry` model, persistence (UserDefaults JSON), RX dedupe, auto-ack, message TX, position beacon (incl. frequency-switch beacon). |
| `ContentView.swift` / `VoiceView` / `APRSView` / `MapView` / `MemoriesView` / `MoreView` | SwiftUI UI, custom tab bar. |
| `SpeechManager.swift` | Live-caption speech recognition fed from decoded RX samples. |
| `LocationManager.swift` | CoreLocation + MapKit reverse geocoding (locality for memory groups). |

### Protocol facts (must match dkaukov `feature/ble` firmware)

- BLE GATT: custom service `00000001-ba2a-46c9-ae49-01b0961f68bb`, TX char `...0003` (notify, radio→phone), RX char `...0002` (write-without-response, phone→radio).
- KISS framing over GATT; vendor frames carry 4-byte prefix + protocol version + command byte.
- Audio command **0x0C** both directions. DesiredState is **0x0D**.
- Audio codec: **IMA ADPCM (WAV layout), 249 samples / 128 bytes per frame, 16 kHz wire rate** (firmware hardware stays 48 kHz internally).
- ESP32 streams RX audio only after a DesiredState with `RX_AUDIO_OPEN`.

### RX audio path

BLE notify → KISS parse → `feedAdpcmFrame` (decode + soft-clip) → ring buffer →
`AVAudioSourceNode` render callback. Jitter handling is a hysteresis gate in the
render thread: silence until 400 ms buffered (`startThreshold`), re-arm if it
drains below 100 ms. Sized for A2DP/BLE radio contention when AirPods are
connected (delivery gaps can reach ~1 s).

### TX audio path (PTT)

`inputNode` tap → linear resample to 16 kHz → accumulate 249-sample frames →
ADPCM encode → vendor frame 0x0C → GATT write. Tap is installed only while PTT
is held (see mic indicator section).

---

## Background Audio (implemented 2026-06-09)

**Problem:** audio stopped when the app was backgrounded or the screen locked —
no `UIBackgroundModes`, no session/engine background hardening.

**Scope decision:** backgrounded-only. CBCentralManager *state restoration*
(system-kill recovery) deliberately deferred — the window is small once the
session stays active while connected.

### What was done

1. **`UIBackgroundModes` = `audio`, `bluetooth-central`.** Array keys have no
   `INFOPLIST_KEY_*` build setting, so a partial `Info.plist` is merged with the
   generated one (`GENERATE_INFOPLIST_FILE = YES` + `INFOPLIST_FILE`). A
   `PBXFileSystemSynchronizedBuildFileExceptionSet` in the pbxproj excludes the
   plist from Copy Bundle Resources — without it the build fails with
   "Multiple commands produce Info.plist" (Xcode synced folders auto-include
   every file).
2. **Engine restart retry** — `startEngineWithRetry()`: `setActive(true)` +
   `engine.start()` with 0.25/0.5/1 s backoff. Background restarts can fail
   transiently with `'!pla'` while another app holds the hardware.
3. **Interruption handling** — `.began` clears the buffer and re-arms the gate;
   `.ended` resumes even without `.shouldResume` (backgrounded resumes often
   omit it), with a 0.5 s grace delay. Failure sets `needsRestart`, recovered by
   `recoverIfNeeded()` on next foreground.
4. **Media-services reset** — observer rebuilds session *and* engine (old engine
   references dead AU instances after a server crash).
5. **BLE auto-reconnect** — on unexpected disconnect, `central.connect()` is
   re-issued for the same peripheral. Pending connects never time out; with
   `bluetooth-central` the system wakes the app when the radio reappears.
   `userInitiatedDisconnect` flag suppresses this for manual disconnects.
   Disconnect sequencing: `audio.stop()` completes before any reconnect's
   `audio.start()` (serialized through the actor).
6. **scenePhase** (`ContentView` → `RadioStore.enterBackground/enterForeground`)
   pauses UI-only work in background: waveform sample hook and live captions.
   The audio path itself is deliberately untouched by backgrounding.

Contract: **session active ⇔ radio connected.** `stop()` deactivates the
session so iOS can suspend the app when the radio is gone (battery).

---

## Mic Indicator Only During PTT (implemented 2026-06-09)

**Problem:** orange mic indicator showed the entire time the radio was
connected. Cause: session category `.playAndRecord` plus an `engine.inputNode`
poke at session start — mic hardware allocated for the whole session. iOS shows
the indicator whenever input IO is active, regardless of tap installation.

### Design: mode-switching session

| Mode | Category | Notes |
|------|----------|-------|
| RX (default) | `.playback` | No mic hardware, no indicator. Bluetooth output uses **A2DP** (better quality than HFP). |
| TX (PTT held) | `.playAndRecord` + `.defaultToSpeaker`, `.allowBluetoothHFP` | Mic tap installed; indicator on — correct, mic is in use. |

**Key constraint:** once `AVAudioEngine.inputNode` is accessed, the engine's AU
graph permanently enables input IO and can no longer start under `.playback`
(input format reads 0 Hz). So the TX→RX transition **rebuilds the engine** via
a factory (`makeEngine` / `rebuildEngine` in `AudioManager`). The
`AVAudioEngineConfigurationChange` observer is bound to the engine instance and
is re-registered after every rebuild.

- TX entry (`installMicTap`): stop engine → `.playAndRecord` → first
  `inputNode` access (mic allocates here) → install tap → start with retry.
  Failure falls back to RX mode cleanly (`fallBackToRxMode`).
- TX exit (`stopMicCapture`): remove tap → rebuild engine → `.playback` →
  re-register observers → start with retry.
- Media-services reset also rebuilds the engine.

`.playback` still satisfies the `audio` background mode; background PTT
(`.playAndRecord` activation while backgrounded) is also permitted under it.

---

## Memory Edit/Delete + Per-Memory Scan Toggle (implemented 2026-06-09)

`Memory` (`RadioStore.swift`) gained `scanEnabled: Bool = true`. A custom
`init(from decoder:)` decodes it via `decodeIfPresent(...) ?? true` so memories
saved before this field existed (UserDefaults JSON, key `savedMemories`) still
load correctly.

- **Edit/delete**: long-press a row in `MemoriesView` for a context menu
  (Edit / Delete). `AddMemoryView` now serves both add and edit — an optional
  `editing: Memory?` pre-fills fields and switches the title/save behavior.
  Edit preserves the memory's `id`/`notes`/`squelch`. `RadioStore.updateMemory`
  and `.deleteMemory` mutate `memories` (auto-persisted via existing `didSet`).
- **Scan toggle**: edit form has an "Include in Scan" row (`ListRow` +
  `KVToggle`, matching the Settings style). New `RadioStore.scanList` is
  `memories.filter(\.scanEnabled)`; scan tick/index logic and the Scan tab
  (`VoiceView` `ScanBody`) iterate `scanList` instead of `memories`.

Mirrors Android's `skipDuringScan` (inverted to a positive "include" toggle).

---

## RX Audio Soft Limiter Fix (implemented 2026-06-09)

`AudioManager.softClip` had a discontinuity at its 0.8 knee — output jumped
0.80 → 0.61 as input crossed it. With FM voice regularly peaking 0.7–1.0, this
modulated loud audio with audible crackle/distortion baked into the PCM before
the volume control (lowering volume didn't help). Fixed: identity below the
knee, tanh-compressed into `[0.8, 1.0)` above it, continuous in value and
slope at the knee.

---

## APRS (implemented 2026-06-09)

Full parity port of Android's APRS feature: RX parse, message TX with acks,
position beacon, map pins, settings. Deferred (matches Android's own deferred
extras): digipeat, MIC-E decode.

**Architecture:** the firmware is a full AFSK 1200-baud (Bell 202) modem — the
host does zero DSP. Host sends a raw AX.25 UI-frame (without FCS, firmware's
AfskModulator appends it) as a KISS DATA frame (cmd 0x00). Firmware self-keys
PTT (`handleAx25Data`, gated only on `HOST_STATE_TX_ALLOWED`), modulates,
transmits, un-keys, and returns to RX. RX direction: firmware demodulates and
sends decoded AX.25 bytes back as KISS DATA, which `BLEManager` now forwards
via `onAx25Frame` instead of dropping.

- **`AX25.swift`** — `AX25Callsign` (7-byte wire encode/decode: chars `<<1`,
  SSID byte `0x60 | (ssid<<1)`, last-address bit `0x01`, repeated bit `0x80`),
  `AX25Frame` (dest/src/digipeaters + payload, `encodedWithoutFCS()` /
  `init?(decoding:)`). Outgoing frames default dest to `APKVPA` (vendor
  TOCALL) and digipeaters to `[WIDE1-1, WIDE2-1]`.
- **`APRS.swift`** — `parseAPRSPayload` dispatches on the DTI (`!`/`=`/`/`/`@`
  position, `:` message/ack/rej, `;` object, `_`/`#`/`*` weather, else
  `.raw`). Builders `compressedPositionString` (base-91, mirrors
  `Position.toCompressedString`) and `messagePayload` (`:TO    :body{num`,
  67-char limit).
- **`APRSController.swift`** — `entries: [APRSEntry]` persisted to
  UserDefaults (`aprsEntries`, JSON, cap 500). RX dedupe by
  `source|dest|payload` key with 28 s TTL. Directed messages to my
  callsign-SSID get auto-acked; incoming `ackN`/`rejN` flip
  `wasAcknowledged` on the matching outgoing entry. `sendMessage(to:text:)`
  sanitizes `| ~ {`, defaults empty "to" to `BLN1CQ`, persists a wrapping
  message-number counter (max 99999). `sendPositionBeacon()` builds a
  compressed-position payload from `LocationManager`, with optional 0.01°
  rounding (`aprsPositionApprox`) and an optional frequency-switch beacon
  (tune to 144.390, send, wait, restore — mirrors Android's
  `performPositionBeacon`). Beacon timer driven by `aprsBeaconEnabled` /
  `aprsBeaconIntervalMin`, paused during scan.
- **TX gating** — every AX.25 send is preceded by a fresh
  `DesiredState(txAllowed: true)`, since the post-HELLO auto-state sends
  `txAllowed: false` and scan can also clear it. No PTT / mic involved —
  firmware handles PTT itself.
- **Settings** (RadioStore, persisted UserDefaults `aprsSettings`):
  `aprsSymbol` (default `[`/table `/`), `aprsBeaconEnabled`,
  `aprsBeaconIntervalMin` (default 15), `aprsBeaconFrequency`
  (`Current`/`144.390`), `aprsPositionApprox`. `callsign` / `aprsSSID` feed
  `AX25Callsign`.
- **UI** — `APRSView` (list + filters + compose/reply sheets, ack
  badges), `MapView` (`APRSMapView` shows live station pins from latest
  position/object entry per callsign, tap → detail), `MoreView` →
  `BeaconSettingsView` (beacon toggle, interval, frequency, approx-position,
  symbol picker, "Beacon now").
- **Tests** — `APRSTests.swift`, 16 tests: AX.25 round-trip vs known frame
  bytes, callsign parse/encode, compressed/uncompressed position parse +
  round-trip (incl. pole/date-line extremes), message/ack parse, weather
  parse, message payload builder.

Needs on-air verification at 144.390 MHz: RX decode + map pins, beacon visible
on aprs.fi via igate, message+ack round trip with a second station,
frequency-switch beacon restores original frequency, voice PTT unaffected.

---

## Concurrency / project gotchas

- The Xcode project uses **MainActor default isolation** (Swift 6.2 default for
  new projects). Any type used off the main actor must be explicitly
  `nonisolated` — e.g. `PCMRingBuffer` (lock-protected, called from the RT
  render thread and BLE queue). Symptom otherwise: a wall of
  "main actor-isolated X cannot be referenced from a nonisolated context"
  warnings that become errors in Swift 6 language mode.
- `@preconcurrency import CoreBluetooth` — CoreBluetooth types aren't Sendable.
- CBCentralManager methods are thread-safe; callbacks arrive on `bleQueue`.
  Don't hop through `@Sendable` dispatch closures just to call `connect()`.
- Deployment target is iOS 26.5 — use current APIs (`AVAudioApplication`
  record permission, `Map(position:)` + `Annotation`, `MKReverseGeocodingRequest`).
  Build is warning-clean as of `4c4aacd`; keep it that way.

---

## On-device verification checklist (pending)

Background audio:

1. RX playing → lock screen / home → audio continues.
2. Squelch closed 10+ min backgrounded → open squelch from second radio → audio
   resumes without foregrounding (validates gated-silence no-suspend assumption).
3. Phone call while backgrounded → end call → audio resumes (retry logs).
4. AirPods connect/disconnect while locked → engine restarts, audio resumes
   after ~400 ms gate fill.
5. PTT, lock screen mid-TX → TX frames keep flowing (`TX audio #` logs).
6. Radio power-cycle while backgrounded → session deactivates, app wakes on
   radio return, reconnects, audio resumes.
7. Xcode Energy gauge, 30 min backgrounded squelch-closed → near-idle CPU.

Mic indicator:

8. Plain RX (foreground + background): **no** orange dot.
9. PTT: dot on while held, off ~1 s after release; RX resumes after gate refill.
10. 5× rapid PTT cycles: no `-10868` / `'!pla'` errors.
11. Bluetooth audio: RX via A2DP, switches to HFP during PTT, returns after.
12. Locality string (MapKit reverse geocode) still reads "City, ST".

## Deferred / future

- CBCentralManager state restoration (`CBCentralManagerOptionRestoreIdentifierKey`)
  for system-kill recovery.
- `.mixWithOthers` user toggle (would trade away `.shouldResume` semantics).
- APRS digipeat and MIC-E decode (matches Android's own deferred extras).
