# iOS APRS ACK Hardening

## Context

Secondhand Discord report: iOS app (1) doesn't send its own ACKs, (2) "gets confused" when receiving ACKs from the other party, (3) received messages don't get logged at all.

Code review shows ACK send/receive **already exists** (`APRSController.swift`, `APRS.swift`, commit 5cf9340), but has four concrete defects that together produce exactly these symptoms. The reporter's symptoms are secondhand and vague, so the plan fixes the identified defects and adds a verification path. The target design should be persistence-first: ingest and persist incoming frames before deciding whether to display, re-ack, notify, or suppress them.

## Identified defects

### 1. Dedupe happens before durable ingest and ACK handling
[APRSController.swift:121-131](ios-src/KV4P HT/KV4P HT/APRSController.swift) — duplicate frame within 28s TTL returns **before** parsing/acking. APRS senders retry unacked messages every ~10–30s with the identical payload → identical dedupe key → iOS silently drops every retry without acking. If the first ACK is lost (very likely, see #2), the message is never acked. This is the primary "doesn't send ACKs" bug.

The fix should not be a larger in-memory cache. Drop the current in-memory
`dedupeCache` as the source of truth. Incoming AX.25/APRS frames should be
persisted first, then higher-level processing should decide whether to append a
visible entry, re-ack, notify, update ACK state, or suppress a duplicate.

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

### APRS RX pipeline — persistence first

Implement or prepare the RX path around this ordering:

`RX AX.25 frame → decode minimal identity → persist raw/normalized frame → classify APRS → process side effects`

Treat this persistence layer as Core Data-backed storage, not another
UserDefaults-only cache. Use separate entities for raw frame ingest and
message/UI state so packet-level dedupe evidence does not get conflated with
visible history. Prefer Core Data lightweight migrations for additive schema
changes, and introduce explicit model versions for relationship or semantic
changes.

Recommended shape:

- `APRSFrame`: durable frame ingest. Stores direction, timestamp,
  `frameHash`, raw/normalized AX.25 bytes, source, destination, payload, parsed
  kind, message number when present, and enough metadata for replay/debug.
- `APRSMessage` or `APRSEntryRecord`: user-visible APRS/message state. Stores
  display text, station identity, conversation/message metadata, ACK state,
  notification state, map/display fields, and references back to one or more
  frame records where useful.

Add Core Data indexes/constraints where useful for `frameHash`, timestamp,
callsigns, direction, and message number lookups.

Persist enough identity to use the store as the dedupe and ACK source of truth:

- source callsign
- destination callsign
- raw AX.25 bytes and/or stable `frameHash`
- APRS payload/body
- APRS kind
- message number, when present
- timestamp
- direction (`incoming` / `outgoing`)
- ACK state, when applicable

Use identity at the right layer:

- Use `frameHash` with a time window for exact raw-frame dedupe. Compute it
  from normalized raw AX.25 bytes after any confirmed FCS stripping; do not
  rely on the 16-bit AX.25 FCS/CRC as a database identity. The same exact
  frame received outside the dedupe window should be eligible for processing
  again.
- Use parsed keys like `source + destination + messageNumber + payload` for
  APRS message dedupe and re-ACK logic.
- Use `source`/base-callsign + `messageNumber` for ACK matching.

Separate packet/frame history from visible APRS entries. The frame/message store is durable ingest and dedupe evidence; visible `APRSEntry` history is user-facing presentation and may be capped, filtered, or transformed.

Duplicate handling should be based on the persistent store, with a `frameHash`
window measured in minutes or hours and surviving app restart. For a duplicate
directed message addressed to us inside the window, re-send the ACK but do not
append a duplicate visible entry. Remove the separate short-lived `dedupeCache`
unless profiling later proves a narrow performance need for a non-authoritative
read-through cache.

### APRS.swift — `parseMessagePayload`
- Treat as ACK/REJ only when remainder after "ack"/"rej" is 1–5 chars, alphanumeric (after stripping optional reply-ack `}suffix` — keep the part before `}` as the msgNum).
- Trim whitespace from extracted msgNum.
- Anything else falls through to a normal message (visible in UI).

### APRSController.swift — `handleAx25Frame`
- Restructure around the persistence-first RX pipeline. Persist the incoming frame before dedupe/side effects. On duplicate persisted frame for a directed message addressed to me with msgNum → still `sendAck` (re-ack retries), skip the visible `append`. Other duplicate handling should be based on persisted history, not the current 28s in-memory cache.
- Delay auto-ack ~1s (match Android): `Task { @MainActor in try? await Task.sleep(for: .seconds(1)); self.sendAck(...) }`.

### APRSController.swift — `markAcknowledged`
- Callsign match: accept exact display match OR base-callsign match (strip `-SSID` from both sides before comparing).
- msgNum match: compare trimmed strings; also match numerically when both parse as Int (handles `ack012` vs stored `12`).
- Persist ACK state so outgoing message acknowledgement survives app restart. Incoming ACKs should match persisted outgoing messages by counterpart callsign, normalized/base callsign, and message number.

### Out of scope (note in PR, don't implement)
- TX retry/timeout for our own unacked messages (missing on Android too — parity).

## Verification

Hardware loop with a second station (Android kv4p app or APRSdroid):
1. Build/run in Xcode on device, radio connected via BLE.
2. Other station → iOS directed message with msgNum: confirm `← AX.25` log appears, message displays, and other station receives the ACK (shows acked) ~1s later. If `← AX.25` never logs, problem is firmware/RF — capture that finding.
3. Re-send the same message within 28s (simulate retry): iOS must re-ack without duplicating the entry.
4. iOS → other station: confirm entry flips clock → green checkmark when the ACK comes back, including when the other station's callsign carries an SSID.
5. Send a normal message starting with "ack..." text (e.g. "acknowledged"): must appear as a regular message, not vanish.
6. Restart the app after receiving a directed message, then receive the same retried message: iOS must re-ack without duplicating the visible entry.
7. Restart the app after sending a message, then receive its ACK: the persisted outgoing message must be marked acknowledged.
8. Inspect a received payload hex dump (add temporary log if needed) to confirm presence/absence of trailing FCS bytes; apply defect-5 fix only if confirmed.
