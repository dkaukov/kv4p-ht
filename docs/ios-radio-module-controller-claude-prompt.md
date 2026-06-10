# Claude Prompt: iOS RadioModuleController

You are working in the `kv4p-ht` repository. Do not make broad refactors. Implement an iOS equivalent of Android's `RadioModuleController` while preserving current app behavior unless a change is explicitly required for state separation.

## Context

The Android reference is:

- `android-src/KV4PHT/app/src/main/java/com/vagell/kv4pht/radio/RadioModuleController.java`
- `android-src/KV4PHT/app/src/main/java/com/vagell/kv4pht/radio/Protocol.java`
- `android-src/KV4PHT/app/src/main/java/com/vagell/kv4pht/radio/RadioAudioService.java`

The iOS files to inspect first are:

- `ios-src/KV4P HT/KV4P HT/BLEManager.swift`
- `ios-src/KV4P HT/KV4P HT/KissProtocol.swift`
- `ios-src/KV4P HT/KV4P HT/RadioStore.swift`
- `docs/ios-app.md`

The desired architecture is: user actions update desired radio state; firmware `DeviceState` updates drive UI-visible applied state. The UI should not treat a requested frequency/config as active until firmware reports it. HELLO is a composed payload containing `FirmwareVersion` plus the initial `DeviceState`; both parts must be loaded into the controller and propagated to UI-visible state immediately so the UI reflects firmware state before the user changes anything.
UI writes must go through `RadioModuleController` desired-state APIs. Avoid bypassing this flow by sending DesiredState frames directly from views, `RadioStore`, or feature controllers; direct frame writes should be transport internals only.

## Implementation Plan

1. Define an iOS `RadioModuleController` equivalent whose responsibility is only radio state:
   - desired state
   - last sent desired state
   - latest firmware/device state
   - applied-state sync status
   - retry count
   - firmware feature metadata

2. Keep `BLEManager` responsible for BLE transport only:
   - scan/connect/reconnect
   - GATT characteristic discovery
   - KISS parse/dispatch
   - raw frame writes
   - audio handoff
   - transport-level flow control

3. Extend the Swift protocol model if needed so `DeviceStateFrame` carries the fields Android uses for sync checks:
   - `ctcssTx`
   - `squelch`
   - `ctcssRx`
   - `radioModuleStatus`
   - `lastError`
   - physical PTT flag constants

4. Prefer the Android shape over a generic `sendRadioState(...)` API. Expose problem-oriented `RadioModuleController` operations/properties such as:
   - `setTxFrequency(_:)`
   - `setRxFrequency(_:)`
   - `setSquelch(_:)`
   - `setBandwidth(_:)`
   - `setTxTone(_:)`
   - `setRxTone(_:)`
   - `setFilters(...)`
   - `setHighPower(_:)`
   - `pttDown()` / `pttUp()`
   - `openAudio()` / `closeAudio()`

   Avoid exposing a broad UI-level API that accepts a complete DesiredState snapshot. `RadioStore` may still provide user-intent helpers like `tune(to:)`, `startPtt()`, or `applyMemory(_:)`, but those helpers should call the controller's problem-oriented setters, ideally inside `beginUpdate()` / `endUpdate()` when multiple fields change together. Views and feature controllers should not call `BLEManager` to send DesiredState snapshots directly.

5. On HELLO:
   - parse HELLO as `FirmwareVersion` plus initial `DeviceState`
   - seed firmware metadata into the controller
   - seed both applied/device state and desired state from the initial device state
   - propagate the initial applied state to UI-visible properties immediately
   - mark transport ready
   - send an explicit RX-audio-open desired state
   - avoid blindly overwriting firmware config unless needed to preserve current iOS behavior

6. On each firmware `DEVICE_STATE` frame:
   - update the controller's latest device state
   - compare `appliedSequence`, desired flags, radio config fields, and `lastError`
   - update applied-state sync status
   - retry the last sent desired state up to Android's three-retry cap when firmware reports mismatch

7. Implement BLE write flow control parity with Android's `Protocol.Sender`:
   - initialize the send window from HELLO `windowSize`
   - decrement the window by each encoded frame's wire length when writing
   - handle firmware `COMMAND_WINDOW_UPDATE` (`0x09`) by enlarging the window
   - queue or defer writes when the window is too small instead of dropping or blindly writing
   - keep this in the transport layer, not in `RadioModuleController`

   Current iOS ignores `0x09`; fixing this is part of the desired separation because the controller should decide what to send, while BLE transport decides when it is legal to write.

8. Keep UI reads based on device/applied state:
   - `currentFreq`
   - RSSI / S-meter
   - RX/TX mode
   - squelch status
   - active memory derivation

   Keep UI writes based on desired state:
   - tune frequency
   - update squelch
   - change power/bandwidth/filter/tone settings
   - request/release PTT
   - carry `TX_ALLOWED`

   These writes should mutate `RadioModuleController.desiredState` and let the controller decide if/when a DesiredState frame is emitted.

   For now, keep `TX_ALLOWED` set to `true` in desired state. It is intended as ham-band transmit protection, but iOS can defer proper band validation until a later change. Do not build extra APRS-only `TX_ALLOWED` refresh paths unless they are still needed after making it globally true.

9. Add focused unit tests for:
   - seeding desired state from device state
   - send-on-change only
   - sequence increment
   - applied-state sync and mismatch
   - retry cap
   - flow-control window decrement/update/deferred-send behavior

Use injected send callbacks in tests so the controller can be tested without CoreBluetooth or audio.

## Constraints

- Do not rewrite the UI.
- Do not move audio logic into the controller.
- Do not collapse device/applied state into desired state for convenience.
- Do not add new direct DesiredState send paths outside the controller.
- Keep changes small and reviewable.
- Maintain Swift concurrency safety; CoreBluetooth callbacks arrive on `bleQueue`, while UI-observable state must be updated safely for SwiftUI.
