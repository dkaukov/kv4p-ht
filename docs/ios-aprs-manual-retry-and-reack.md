# iOS APRS: manual resend + reliable duplicate re-ACK

## Context

Two related gaps in the directed-message path:

1. **Duplicate messages aren't reliably re-ACKed.** APRS is best-effort: when a
   sender's ACK is lost they retransmit the same message (same msgNum). The spec
   requires the receiver to ACK *every* copy it hears, otherwise the sender keeps
   retrying forever and eventually gives up — making their retry logic useless.
2. **No way to manually resend** a message that's still awaiting an ACK or has
   exhausted its automatic retry budget (undelivered).

## Part A — Reliable duplicate re-ACK (bug fix)

### Root cause

`handleAx25Frame` dedupes directed messages on exact `payload` bytes via
`recentIncomingFrameExists(source:payload:)`, and only re-ACKs inside the
`isDuplicate` branch. The payload key drifts between retries:

- **Third-party (`}`) relays** (the aprs.fi → iGate path): the dedupe key is the
  *outer* `}SRC>DEST,PATH,qAR,IGATE:...` blob. The iGate path / `qAR` construct
  changes between retransmissions, so two copies of the *same* inner message have
  different outer payloads → not flagged duplicate → the copy lands as a new
  visible entry and the identity-based re-ack never matches.
- Any digipeat path change that alters info-field framing has the same effect.

Result: retries from the other side don't reliably re-ACK.

### Fix

Dedupe **and** re-ACK directed messages on **(originator callsign, msgNum)**
instead of raw payload bytes — message *identity*, which is stable across paths
and third-party header drift.

- `APRSPersistence`: add
  `recentIncomingMessageExists(source:msgNum:since:)` —
  predicate `direction == "in" AND source == ? AND kind == "message" AND
  msgNum == ? AND timestamp >= ?`. `source`, `kind`, `msgNum` are already stored
  on the `Frame` entity; the `source,timestamp` index already covers it.
- `APRSController.handleAx25Frame`: for directed messages (carrying a msgNum) use
  the identity-based check with `from` = the unwrapped inner source. Non-message
  frames keep `recentIncomingFrameExists` (payload) for digipeat suppression.
- **Always re-ACK** a directed message addressed to us that carries a msgNum —
  first copy *or* duplicate. Only the visible *entry* is suppressed on a
  duplicate; the ACK is never gated by the dedupe decision.

## Part B — Manual "Resend now"

Decision (confirmed with user): manual resend **resets the full retry budget** —
transmit immediately, `retryCount = 0`, `nextRetryAt = now + retryInterval(0)`
(8 s). Works for both awaiting-ack and undelivered messages; gives an exhausted
message a fresh 7-retry decay cycle.

- `APRSController.resendNow(_ id: UUID)` — guard `isOutgoing && kind == .message
  && !wasAcknowledged`; `transmitPayload(messagePayload(...))`; reset budget;
  persist via `updateEntryRetry`.
- `APRSDetailView`: "Resend now" button (mirrors the Reply button) shown when
  `isOutgoing && kind == .message && !wasAcknowledged`. Undelivered gets a
  revive-style treatment.
- `APRSRow`: `.swipeActions` "Resend" for the same predicate.

## Part C — Tests

- `duplicateDirectedMessageReAcks` — same directed message twice → one entry,
  identity dedupe flagged.
- `thirdPartyRetryDedupesByIdentity` — two `}`-wrapped copies, differing outer
  header but same inner src+msgNum → appends once.
- `resendNowResetsBudget` — undelivered entry → `resendNow` → `retryCount == 0`,
  `nextRetryAt ≈ now + 8`, `isUndelivered == false`.

Transmit needs `store` (nil in tests), so assertions are on dedupe/identity
decisions and entry state, not wire output — same pattern as the existing retry
tests.

## Verification

- `xcodebuild -scheme "KV4P HT" -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:"KV4P HTTests"`
- Device: an aprs.fi-relayed message that retries → each copy re-ACKs, one entry
  shown. Force a message to undelivered → tap Resend → fresh decay cycle.
