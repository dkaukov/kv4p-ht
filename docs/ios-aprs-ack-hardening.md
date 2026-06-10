# iOS APRS ACK Hardening

## Context

Secondhand Discord report: iOS app (1) doesn't send its own ACKs, (2) "gets confused" when receiving ACKs from the other party, (3) received messages don't get logged at all.

Code review shows ACK send/receive **already exists** (`APRSController.swift`, `APRS.swift`, commit 5cf9340), but has four concrete defects that together produce exactly these symptoms. The reporter's symptoms are secondhand and vague, so the plan fixes the identified defects and adds a verification path.

## Identified defects

### 1. Dedupe cache swallows sender retries → no ACK ever sent
[APRSController.swift:121-131](ios-src/KV4P HT/KV4P HT/APRSController.swift) — duplicate frame within 28s TTL returns **before** parsing/acking. APRS senders retry unacked messages every ~10–30s with the identical payload → identical dedupe key → iOS silently drops every retry without acking. If the first ACK is lost (very likely, see #2), the message is never acked. This is the primary "doesn't send ACKs" bug.

### 2. ACK transmitted instantly, collides with digipeats
[APRSController.swift:159-161](ios-src/KV4P HT/KV4P HT/APRSController.swift) — `sendAck` fires the moment the message decodes, while digipeated copies of the original are still on air. Android delays 1s (`MainActivity.java:770-777`). Instant TX → collision → remote never hears the ACK.

### 3. ACK/REJ parse too greedy, no msgNum validation
[APRS.swift:191-197](ios-src/KV4P HT/KV4P HT/APRS.swift) — any body starting with "ack"/"rej" is consumed as an ACK and **silently dropped from the UI** (e.g. a message "acknowledged, see you at 7" vanishes and triggers a bogus `markAcknowledged` with msgNum "nowledged, see you at 7"). Spec: ACK is exactly `ack` + 1–5 alphanumeric chars. Also no handling for reply-ack suffix (`ack3}45`).

### 4. ACK matching is brittle
[APRSController.swift:183-191](ios-src/KV4P HT/KV4P HT/APRSController.swift) — requires exact `toCallsign == frame.source.display` (SSID-sensitive) and exact msgNum string equality (whitespace/leading-zero sensitive). Any mismatch → ACK silently ignored, message stuck on "Awaiting ack" forever. This is the likely "gets confused" symptom.

### Possible 5th (verify first): FCS bytes in RX payload
Firmware (`microcontroller-src/.../rxAudio.h:69-74` → `sendAx25Packet`) forwards whatever the `AfskDemodulator` library emits. iOS assumes no FCS (`AX25.swift` header comment). If the lib includes the 2 FCS bytes, every message body ends with 2 garbage bytes, breaking `{msgnum` parsing and ack bodies. Verify during testing before changing code; if present, strip 2 trailing bytes (after validating) in `handleAx25Frame` or `AX25Frame(decoding:)`.

Note: "nothing gets logged" — `BLEManager.swift:299` logs `← AX.25 nB` for every received cmd-0 KISS frame. If that line never appears, frames aren't reaching the app (firmware build lacking AFSK RX, squelch, etc.) — that's a hardware/firmware verification step, not an iOS code fix. The working-tree BLEManager change (console `print` in `log()`) helps here; keep it.

## Changes

All in `ios-src/KV4P HT/KV4P HT/`:

### APRS.swift — `parseMessagePayload`
- Treat as ACK/REJ only when remainder after "ack"/"rej" is 1–5 chars, alphanumeric (after stripping optional reply-ack `}suffix` — keep the part before `}` as the msgNum).
- Trim whitespace from extracted msgNum.
- Anything else falls through to a normal message (visible in UI).

### APRSController.swift — `handleAx25Frame`
- Restructure: parse the frame **before** the dedupe early-return. On dedupe hit for a directed message addressed to me with msgNum → still `sendAck` (re-ack retries), skip the `append`. All other dedupe hits return as today.
- Delay auto-ack ~1s (match Android): `Task { @MainActor in try? await Task.sleep(for: .seconds(1)); self.sendAck(...) }`.

### APRSController.swift — `markAcknowledged`
- Callsign match: accept exact display match OR base-callsign match (strip `-SSID` from both sides before comparing).
- msgNum match: compare trimmed strings; also match numerically when both parse as Int (handles `ack012` vs stored `12`).

### Out of scope (note in PR, don't implement)
- TX retry/timeout for our own unacked messages (missing on Android too — parity).

## Verification

Hardware loop with a second station (Android kv4p app or APRSdroid):
1. Build/run in Xcode on device, radio connected via BLE.
2. Other station → iOS directed message with msgNum: confirm `← AX.25` log appears, message displays, and other station receives the ACK (shows acked) ~1s later. If `← AX.25` never logs, problem is firmware/RF — capture that finding.
3. Re-send the same message within 28s (simulate retry): iOS must re-ack without duplicating the entry.
4. iOS → other station: confirm entry flips clock → green checkmark when the ACK comes back, including when the other station's callsign carries an SSID.
5. Send a normal message starting with "ack..." text (e.g. "acknowledged"): must appear as a regular message, not vanish.
6. Inspect a received payload hex dump (add temporary log if needed) to confirm presence/absence of trailing FCS bytes; apply defect-5 fix only if confirmed.
