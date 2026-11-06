# PadLink Protocol Specification

**Status:** draft wire/pairing core, revision 1. Frame codecs, key schedule,
replay, edge recovery, freshness, watchdog, and in-memory SPAKE2 pairing state
machines are implemented and tested. Suite 1 is pinned and conformance-tested,
**not independently audited**. Pairing transport, Android consent/token UI,
request rate limits, resume MAC, discovery, sockets, daemon/IPC, and native
backends are **not implemented**. User pairing remains unavailable. The current
build is **not safe for live input** and makes no resource or gameplay claim.

Every rule below is fail-closed: a receiver that cannot establish a requirement
must reject the packet, remain neutral, and avoid advancing session state.

---

## 1. Roles, transports, and limits

| Item | Value |
| :--- | :--- |
| Roles | Android phone (controller) and desktop daemon (session owner) |
| Wire revision | `1` (header high nibble) |
| Frame magic | `0x50` |
| Default pairing TCP port | `41337` |
| Default UDP input port | `41338` |
| State rate | 120 Hz default; 60–240 Hz negotiated |
| Max encrypted frame | 256 bytes |
| Max encrypted payload | 228 bytes |
| Max pre-auth handshake frame | 4096 bytes |
| Default neutral hold | 250 ms (configurable 100–250 ms) |
| Reconnecting display | 5 s after newest fresh sample |
| Session expiry | 30 s after newest fresh sample |
| Edge journal | 32 transitions; 12 per frame |

Discovery names, addresses, SSIDs, and mDNS TXT values are **not** identities.
Only a completed PAKE with mutual confirmation may create a session.

## 2. Encoding conventions

- Integers are little-endian.
- `u64` counters are unsigned and never wrap.
- Frames have a 12-byte clear header, a bounded encrypted payload, and a
  16-byte Poly1305 tag. The header is AEAD associated data.
- Any field marked reserved **must** be zero; a nonzero value is rejected.
- Senders must reject invalid lengths before allocating or parsing.
- Unknown versions, suites, frame types, and mandatory capability bits fail
  closed. There is no plaintext downgrade.

## 3. Encrypted frame envelope

```text
offset  size  field
0       1     magic = 0x50
1       1     ver_type = (version << 4) | frame_type
2       2     session_tag (LE, routing hint only)
4       8     seq_num (LE, per directional key domain)
12      N     ciphertext (0 <= N <= 228)
12+N    16    ChaCha20-Poly1305 tag
```

| Property | Requirement |
| :--- | :--- |
| Version | `1`; reject every other nibble |
| `session_tag` | First two bytes of the 128-bit session ID, LE; not an authenticator |
| `seq_num` | Starts at `0` for each distinct key; never reset under the same key |
| AAD | The complete 12-byte clear header |
| Replay check | Only after successful AEAD verification and payload validation |
| Rekey threshold | Before `2^48`; refuse to seal at or above it |

The nonce is **not** derived from a truncated session ID:

```text
nonce[0..4]  = directional nonce prefix from HKDF
nonce[4..12] = seq_num as u64 little-endian
```

That is a 96-bit ChaCha20-Poly1305 nonce. All packet types sharing a key share
one counter. A counter is never reused after a retry, reconnect, backend switch,
or transport change.

## 4. Frame types

| Value | Type | Payload length | Use |
| ---: | :--- | ---: | :--- |
| 1 | State | 28 | Analog snapshot plus digital cursor |
| 2 | Edges | 2–218 | Ordered digital transitions |
| 3 | Ack | 8 | Highest contiguous edge ID |
| 4 | Ping | 16 | Clock/offset request |
| 5 | Pong | 32 | Clock/offset reply |
| 6 | Rumble | 4 | Bounded haptic request |
| 7 | Disconnect | 1 | Session teardown reason |
| 8 | EpochConfirm | 16 | Fresh neutral epoch baseline |
| 9 | Error | 4 | Peer protocol error |
| 10 | ResumeChallenge | 20 | Authenticated migration challenge |
| 11 | ResumeConfirm | 52 | Migration confirmation MAC |

A complete State frame is `12 + 28 + 16 = 56` bytes. A maximum Edges frame is
`12 + 218 + 16 = 246` bytes, still under the 256-byte limit.

### 4.1 State payload (28 bytes)

| Payload offset | Wire offset | Field | Type | Meaning |
| ---: | ---: | :--- | :--- | :--- |
| 0 | 12 | `latest_edge_id` | u64 | Newest transition incorporated into this snapshot |
| 8 | 20 | `sample_time_us` | u64 | Sender monotonic sample time |
| 16 | 28 | `buttons` | u16 | Button bitmap; bit 15 reserved |
| 18 | 30 | `left_trigger` | u8 | 0–255, neutral 0 |
| 19 | 31 | `right_trigger` | u8 | 0–255, neutral 0 |
| 20 | 32 | `lx` | i16 | Left stick X |
| 22 | 34 | `ly` | i16 | Left stick Y |
| 24 | 36 | `rx` | i16 | Right stick X |
| 26 | 38 | `ry` | i16 | Right stick Y |
| 28 | 40 | tag | 16 B | AEAD tag |

Axis convention: X grows right, Y grows **down**. Neutral is `(0, 0)`;
`i16::MIN`/`i16::MAX` are valid mechanical extremes. Backends that use up-positive
axes must negate Y. Deadzones are applied by the phone before transmission; the
protocol carries the final value.

### 4.2 Button bitmap

| Bit | Control | Bit | Control |
| ---: | :--- | ---: | :--- |
| 0 | A | 8 | Guide/Home |
| 1 | B | 9 | L3 (left stick click) |
| 2 | X | 10 | R3 (right stick click) |
| 3 | Y | 11 | D-pad up |
| 4 | LB | 12 | D-pad down |
| 5 | RB | 13 | D-pad left |
| 6 | Back/View | 14 | D-pad right |
| 7 | Start/Menu | 15 | Reserved, must be zero |

The Android UI places Y top, X left, B right, A bottom. That visual arrangement
does not change the bit assignment above.

### 4.3 Edges payload

```text
offset  size  field
0       1     count (1..=12)
1       1     reserved (0)
2       18*n  entries, strictly increasing edge_id
```

Each entry:

| Offset | Size | Field |
| ---: | ---: | :--- |
| 0 | 8 | `edge_id` (nonzero, increasing within the frame) |
| 8 | 2 | `buttons` bitmap |
| 10 | 8 | `event_time_us` (sender monotonic) |

Edge IDs are independent of packet sequence numbers. A State snapshot's digital
bitmap may be applied only when `latest_edge_id == receiver_cursor`. A snapshot
ahead of the cursor requests retransmission; a snapshot behind the cursor cannot
roll buttons back. Axes and triggers may update immediately.

The sender retains at most 32 unacknowledged transitions. The receiver buffers
at most 32 future transitions and applies only the contiguous prefix. Delivery
acknowledgment does not prove that a game's polling loop observed an edge.

### 4.4 Control payloads

| Frame | Layout |
| :--- | :--- |
| Ack | `highest_contiguous_edge_id: u64` |
| Ping | `ping_id: u64`, `sent_time_us: u64` |
| Pong | `ping_id: u64`, `echo_time_us: u64`, `received_time_us: u64`, `sent_time_us: u64` |
| Rumble | `left: u8`, `right: u8`, `duration_ms: u16` (max 1000) |
| Disconnect | `reason: u8` (1 user, 2 phone paused, 3 desktop locked, 4 backend lost, 5 expired, 6 memory pressure, 7 protocol violation; others informational) |
| EpochConfirm | `epoch: u32`, `baseline_edge_id: u64` (must be 0), `flags: u16` (only bit 0 = neutral baseline), `reserved: u16` (0) |
| Error | `code: u16`, `detail: u16` (informational only) |
| ResumeChallenge | `epoch: u32`, `challenge: [u8; 16]` |
| ResumeConfirm | `epoch: u32`, `challenge_echo: [u8; 16]`, `mac: [u8; 32]` |

Ping/Pong establish clock-offset bounds. They do **not** refresh input
freshness. Rumble is capped so a missing stop packet cannot vibrate forever.

### 4.5 Resume handshake status

The frame schemas above are frozen, but the resume key/MAC and endpoint
challenge flow are not implemented. Until they are:

- no resume frame may rearm a controller;
- a transport or endpoint change requires a fresh epoch and neutral baseline;
- after 30 s, or after either process restarts, a new six-character pairing is
  required.

The planned MAC is HMAC-SHA256 over a transcript binding the session ID, old and
new epochs, transport, role, and both 128-bit challenges, under a key derived
from the session root with the label `padlink/v1/resume-confirm`. The transcript
must not rely on a short session tag or source address.

## 5. Session key schedule

The PAKE must produce:

- a 32-byte session root secret;
- a 128-bit random session ID;
- a confirmed protocol version and capability set.

For each direction, transport, and epoch:

```text
salt = "padlink/v1" || session_id[16]
info = "padlink/v1/traffic" || direction || transport || epoch_le32
okm  = HKDF-SHA256(ikm = root, salt, info, length = 36)
key       = okm[0..32]
nonce_prfx= okm[32..36]
```

| Field | Values |
| :--- | :--- |
| direction | `1` phone→desktop, `2` desktop→phone |
| transport | `1` UDP, `2` TCP |
| epoch | u32, incremented on a confirmed fresh epoch |

There are separate keys for each direction and each transport. A TCP fallback
does not reuse a UDP key. Old epochs are retired when the new epoch is
confirmed. Process restart loses the root and counters and requires new pairing.

## 6. Replay and freshness

### 6.1 Replay

Each directional key keeps a 64-packet sliding replay window. A counter is
accepted once. Duplicates are dropped; counters more than 64 behind the highest
accepted value are dropped. The window advances only after AEAD verification
and successful payload decoding, including length and reserved-bit checks.
A forged high sequence number in a header that fails authentication has no
effect.

### 6.2 Clock bounds

Ping/Pong yields `offset_us` and an uncertainty half-width for the peers'
monotonic clocks. The uncertainty must include measured drift and must not
exceed 500 ms; larger uncertainty means freshness cannot be established and
output stays neutral.

```text
offset_us       = peer_clock - local_clock
earliest_sample = sample_time - offset - uncertainty
latest_sample   = sample_time - offset + uncertainty
```

If `earliest_sample > now`, the sample is implausibly in the future and is
rejected. Otherwise the conservative sample time is
`clamp(earliest_sample, 0, now)`, and the age upper bound is `now - conservative`.
Use the earliest possible time: uncertainty increases maximum age rather than
making delayed input appear newer.
A previously unseen sequence number can still carry stale input.

### 6.3 Input watchdog

| Trigger | Action |
| :--- | :--- |
| `reference = newest conservative sample` | Hold deadline = `reference + neutral_ms` |
| `now >= deadline` | Neutralize all controls and rumble; latch output off |
| `now >= reference + 5 s` | Report `RECONNECTING` |
| `now >= reference + 30 s` | Expire: remove device, erase keys, require new pairing |
| Fresh input while latched off | Rejected; explicit epoch rearm is required |
| A sample older than the current reference | Rejected; it cannot extend or rewind the deadline |
| Ping, Pong, Ack, Rumble, Resume, duplicate | Cannot refresh input freshness |

A fresh epoch rearm requires a confirmed neutral baseline and a new
`EpochConfirm` before the next State sample can enable output. Explicit
disconnect, desktop lock/suspend, phone pause, and backend removal neutralize
immediately. An explicit stop is never undone by a supervisor.

`on_fresh_input` and `rearm` check existing deadlines before accepting an update;
they cannot rely on a timer callback winning a race with a packet. Rearm grants
a bounded neutral hold window for the new epoch's first State, but preserves the
last fresh sample's 5 s/30 s deadlines. Only a newly accepted fresh State moves
those deadlines. A stale State after rearm never advances the reference.

## 7. Pairing token rules

- Six characters from `23456789ABCDEFGHJKLMNPQRSTUVWXYZ` (32 symbols, 30 bits).
- Generated with the OS CSPRNG after phone consent only.
- Valid for 60 seconds.
- At most three failed verification attempts globally; malformed input counts.
- Success, expiry, cancellation, replacement, or the third failure invalidates
  the token.
- Input is case-insensitive; ASCII whitespace, `-`, and `_` are ignored.
- The token, traffic keys, root secret, and pairing transcript must never appear
  in logs, arguments, QR payloads, or saved configuration.

A six-character token is a 30-bit password, not a 256-bit secret. Suite 1 uses
the pinned RFC 9382 implementation below with fresh ephemeral state,
transcript/role binding, explicit mutual confirmation, and attempt limits. No
X25519-plus-HMAC or commit-reveal substitute is approved. The implementation is
conformance-tested rather than independently audited. G3 remains open; user
pairing stays blocked until the real consent UI, transport and rate limits are
implemented and tested, and the required security/ABI validation is complete.

### 7.1 Selected suite and password mapping

`PAKE_SUITE = 1` pins `pakery-spake2 = 0.6.2`, `pakery-crypto = 0.6.2`, and
`pakery-core = 0.6.2`, with P-256, SHA-256, HKDF-SHA256, and HMAC-SHA256. The
workspace requires Rust 1.88 or newer. Desktop is SPAKE2 Party A; phone is Party
B. P-256 shares use canonical 65-byte SEC1 uncompressed encoding (`04 || x ||
y`); invalid/noncanonical/off-curve/identity points fail closed.

```text
w = P256Group::scalar_from_wide_bytes(
      SHA512("padlink/v1/pair-password" || normalized_code))
```

Wide scalar reduction is big-endian, as implemented by the pinned P-256 group.
Each attempt uses a new ChaCha20 CSPRNG seeded by a fallible OS random read.
OS entropy failure returns an error; no weak fallback or panic-prone OS RNG
adapter is used. Deterministic scalars are enabled only by the dev test-utils
feature for RFC vectors.

### 7.2 Pre-authentication framing

The desktop will initiate TCP to the phone's actual pairing endpoint. The
socket implementation is still absent. The core codecs encode complete frames:

```text
length: u16 BE   # counts magic + ver_type + payload, excludes the prefix
magic: u8       # 0x50
ver_type: u8    # (1 << 4) | pairing_message_type
payload
```

The total bound is 4096 bytes, **including** the two-byte prefix; the body is
2–4094 bytes. A transport must validate the prefix before allocating/reading its
body, use a short bounded read deadline, and reject truncation/trailing bytes.
All payload integers below are LE. Pairing message nibbles are independent of
the post-auth encrypted frame types.

| Type | Message | Payload fields, in order | Payload bytes |
| ---: | :--- | :--- | ---: |
| 1 | Request | `version:u16`, `suite:u16`, `request_id:[u8;16]`, `desktop_nonce:[u8;16]`, `label_len:u16`, `label:UTF-8` | 39–102 |
| 2 | Accept | `version:u16`, `suite:u16`, `request_id:[u8;16]`, `phone_nonce:[u8;16]`, `session_id:[u8;16]` | 52 |
| 3 | PakeA | `request_id:[u8;16]`, `pA:[u8;65]` | 81 |
| 4 | PakeB | `request_id:[u8;16]`, `pB:[u8;65]`, `cB:[u8;32]` | 113 |
| 5 | ConfirmA | `request_id:[u8;16]`, `cA:[u8;32]` | 48 |
| 6 | Abort | `request_id:[u8;16]`, `reason:u8` | 17 |

The label is nonempty, at most 64 UTF-8 bytes, and rejects control/terminal and
bidirectional override/isolate characters. It must be displayed as unverified.
Only version 1/suite 1 are offered or selected: there is no downgrade
negotiation. Capabilities and endpoints are not negotiated in this revision;
live input stays blocked pending their authenticated integration. A Request's
codec does not generate a token or imply Allow. Accept is generated only by
the explicit `PhoneHandshake::consent` operation after the user's Allow action.

### 7.3 Identity, transcript, and root binding

```text
identity_A = "padlink/v1/pair-desktop" || request_id || desktop_nonce
identity_B = "padlink/v1/pair-phone"   || request_id || phone_nonce

AAD = "padlink/v1/pair-aad" || version_le16 || suite_le16 || request_id
      || desktop_nonce || phone_nonce || session_id || label_len_le16 || label

salt = SHA256("padlink/v1/pair-transcript" || AAD || pA || pB)
root = HKDF-SHA256(ikm=Ke, salt=salt,
                  info="padlink/v1/session-root", length=32)
```

The library produces a 16-byte `Ke` and two 32-byte confirmation MACs. Expanding
Ke to a 32-byte root does not increase the suite's 128-bit security strength.
SPAKE2's RFC key schedule and MACs are supplied by the pinned implementation;
PadLink does not replace their mutual confirmation with a custom authenticator.
Changing roles, label, nonces, session ID, version, suite, or key shares fails
confirmation. Password, root, and ephemeral state are never wire fields; debug
output for handshake/session/messages redacts transcript and secret material.

### 7.4 Confirmation and neutral ready

1. Desktop sends Request; phone displays the unverified label/address and waits
   for consent. Only Allow issues a six-character token and sends Accept.
2. User enters the phone's token in hidden CLI input (not implemented yet).
   Desktop sends fresh PakeA.
3. Phone reserves an attempt and replies with fresh PakeB and `cB`.
4. Desktop verifies `cB` and sends `cA`. Its session remains private/pending.
5. Phone verifies `cA`, derives the root/traffic keys, invalidates the token,
   and seals `EpochConfirm(epoch=1, baseline_edge_id=0, neutral flag=1)` under
   phone→desktop/TCP with sequence 0.
6. Desktop releases its pairing session only after this exact ready frame
   authenticates. Wrong type/epoch/sequence/flags, tag failure, or expiry cannot
   release a desktop session. Its TCP replay window already includes ready.

The core returns traffic ownership; it does not mount a controller or authorize
live input. Path probing, neutral physical touch state, permissions, backend
readiness, and watchdog integration are additional gates. The transport must
cancel incomplete requests and erase pending state on disconnect/timeout.

### 7.5 Attempt ownership and expiry

`begin_attempt(now_ms)` decrements once when a valid PakeA is accepted. A return
of zero permits the third attempt to finish. `fail_attempt()` does not decrement
again; it invalidates the token only when no attempts remain. Confirmed success,
expiry, cancellation, replacement, or deny invalidates it immediately.

Retries retain the same consented request, session ID, token, and original
phone-side 60 s deadline, while using new PAKE ephemerals. A new valid PakeA
abandons any unfinished previous attempt. The phone checks its deadline both
before key-share processing and before confirmation. An expired token cannot be
revived by a reconnect. Desktop retries discard pending PAKE/session material.

Malformed local code input is rejected and counted by the local token checker.
Malformed pre-auth wire data and invalid points are rejected before PAKE; they
must be covered by the transport's read/connection/request limits. Invalid
points do not consume a password-verification attempt in this core. Before
exposing a server, enforce one pending request and phone-wide/per-source
five-requests/minute limits; new sockets or source addresses must not reset the
global limiter. These limits and the actual phone consent UI are not present.

### 7.6 Conformance evidence and limitations

`protocol/tests/rfc9382.rs` matches RFC 9382 Appendix B's pA, pB, Ke, cA and cB
exactly, including `Ke=0e0672dc86f8e45565d338b0540abe69`. The deterministic
vector also checks both peer confirmations and rejects reflected/truncated
MACs. `pairing_flow.rs` tests the PadLink wrapper's fresh exchanges, wrong-code
retries, third-attempt behavior, expiry, metadata/confirmation/ready tampering,
codecs, and bidirectional encrypted traffic. This is not an audit or proof of
transport security, Android interoperability, live-input safety, resource
containment, or gameplay compatibility.

## 8. Error handling

- Wrong magic, version, type, length, reserved bits, or session tag: reject.
- AEAD failure: reject without advancing replay, endpoint, or watchdog state.
- Replay: drop silently; do not log secrets.
- Edge gap: hold buttons, request retransmission, and never skip the missing ID.
- Counter at/above the rekey threshold: refuse to seal and renegotiate.
- Clock uncertainty too large or sample future/stale: stay neutral.
- Watchdog expiry: destroy the device and require new pairing.
- Protocol errors sent by a peer are informational; the receiver still enforces
  its own checks.

## 9. Golden vector

Inputs:

```text
root       = 000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f
session_id = a0a1a2a3a4a5a6a7a8a9aaabacadaeaf
domain     = phone->desktop (1), UDP (1), epoch 1
seq        = 0
state      = latest_edge_id 0, sample_time 0,
             buttons A|D-pad-up (0x0801), LT 0, RT 255,
             left stick (-32768, 32767), right stick neutral
```

Derived material:

```text
key       = a7b680ea8892eae8ffe74eebbc15a8caf64ab9b6f2140edba6fe36a0d141bb89
prefix    = 72df32e2
header    = 5011a0a10000000000000000
payload   = 00000000000000000000000000000000010800ff0080ff7f00000000
frame     = 5011a0a10000000000000000
            d29058eb1bef0edde72c3a87714c0a7089382e2008c707fb383ade991b90b6
            88cb5a088577b119e9cfa33684
```

The frame is 56 bytes. The vector was reproduced independently with a second
ChaCha20-Poly1305/HKDF implementation.

## 10. Test coverage in this revision

`cargo test -p padlink-protocol` covers:

- pairing-code shape, generation, normalization, expiry, and attempt locking;
- exact State/Edges/control round trips and reserved-bit rejection;
- parser behavior over every payload length 0–320 with deterministic random bytes;
- an RFC 8439 ChaCha20-Poly1305 vector;
- directional/transport/epoch key separation;
- tampered headers, payloads, tags, wrong keys, and wrong session tags;
- replay, reordering, window boundaries, and counter exhaustion;
- short taps between state ticks, gaps, duplicates, and bounded journal behavior;
- snapshot/edge cursor semantics;
- clock offset, uncertainty, future samples, and stale samples;
- 250 ms neutral, 5 s reconnect, 30 s expiry, rearm, and explicit neutralization.
- RFC 9382 Appendix B and the pairing/ready failure cases in §7.6;
- packet/timer races, expiry-preserving rearm, atomic rejected edge batches,
  replay preservation on malformed authenticated payloads, and separate reports
  for recovered press/release transitions.

Still required before live-input use: security and Android ABI validation,
pairing transport and consent UI, request rate limits, resume handshake,
authenticated path probes, streaming TCP transport framing,
daemon/IPC ownership, native backends, and the failure-injection matrix in
`IMPLEMENTATION_PLAN.md`.
