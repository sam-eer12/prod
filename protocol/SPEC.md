# PadLink Protocol Specification

**Status:** draft revision 1. Shared codecs, key schedule, replay, edge recovery,
clock bounds, watchdog, SPAKE2 pairing, bounded TCP adapters, admission/consent,
session expiry and authenticated resumption are implemented. Android JNI and
the real consent/token UI use the same core as `padlink pair`. Suite 1 is pinned
and RFC-conformance-tested, **not independently audited**. Discovery, daemon/IPC,
automatic transport migration and native gamepad backends remain future work.
Pairing verification is available; live input and release compatibility remain
unvalidated.

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
| Max authenticated TCP frame | 258 bytes including its two-byte prefix |
| Max pre-auth handshake frame | 4096 bytes including its two-byte prefix |
| Pairing socket arrivals | 5 per rolling 60 s globally and per source IP |
| Pending pairing connections | 1; no concurrent admission while paired |
| First Request / frame progress / queued write deadline | 3 s, absolute |
| Unanswered Allow/Deny prompt | 30 s |
| Default neutral hold | 250 ms (configurable 100–250 ms) |
| Reconnecting display | 5 s after newest fresh sample |
| Session expiry | 30 s after newest fresh sample |
| Edge journal | 32 transitions; 12 per frame |

Discovery names, addresses, SSIDs, and mDNS TXT values are **not** identities.
Only a completed PAKE with mutual confirmation may create a session.

## 2. Encoding conventions

- Payload/header integers are little-endian; TCP length prefixes are big-endian.
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
| AAD | UDP: the 12-byte clear header; TCP: its BE length prefix followed by the header |
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

### 3.1 Authenticated TCP framing

TCP carries `body_length:u16 BE || header || ciphertext || tag`. The body length
excludes the prefix, ranges from 28 to 256 bytes, and must exactly equal the
received body's length. The complete TCP frame is therefore 30–258 bytes.
AEAD AAD is `prefix[2] || header[12]`. Altering a prefix, stripping it, or adding
one to a header-only envelope cannot authenticate. Invalid framing or tags do
not consume replay state. This finalizes the previously unintegrated draft TCP
wire contract; revision 1 UDP envelopes and their golden vector are unchanged.

`TrafficKey::seal_tcp_frame/open_tcp_frame` require a TCP key domain and use this
complete representation. `PairedSession::seal/open(Transport::Tcp, ...)` and the
pairing ready frame also include the authenticated prefix. UDP session calls
continue to return/consume the unprefixed envelope. Never seal a frame again for
a partial-write retry: retain its exact bytes and counter in the single write
slot until completion or connection cancellation.

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

### 4.5 Authenticated resumption

`SessionLease::resume` moves the session into one isolated candidate, whose
deadline is `min(now + 2 s, original secret expiry)`. Input must be neutralized
before entry. The transport supplies both observed SocketAddr endpoints and
rejects ordinary traffic while the candidate is pending. A wrong source is
rejected before opening and does not consume the legitimate challenge; invalid
authenticated state, proof, or deadline erases the candidate and session.

1. Desktop sends old-key encrypted ResumeChallenge A for `old_epoch + 1`.
2. Phone replies with old-key encrypted ResumeChallenge B for the same epoch.
3. Desktop sends old-key encrypted ResumeConfirm with echo B and desktop MAC.
4. Phone verifies it, sends its old-key ResumeConfirm with echo A and phone MAC,
   followed by new-key EpochConfirm (neutral baseline, sequence 0).
5. Phone commits only after both replies are fully written. Desktop commits
   only after phone proof and the exact new-key ready authenticate. `finish`
   exposes the new epoch and endpoint together. The expiry deadline is preserved.

The canonical transcript is concatenated without implicit text encodings:

```text
"padlink/v1/resume-transcript" || session_id[16] || old_epoch_le32 || new_epoch_le32
|| transport_u8 || desktop_endpoint || phone_endpoint || A[16] || B[16]
endpoint = family_u8(4 or 6) || ip_octets[4 or 16] || port_le16
```

IPv6 flow/scope IDs remain in local socket routing and source matching; they
are excluded from the shared transcript because peer interface indices differ.
Ports must be nonzero and addresses must not be unspecified.

```text
mac_key = HKDF-SHA256(old_root, salt=session_id,
                      info="padlink/v1/resume-mac", length=32)
MAC = HMAC-SHA256(mac_key, role_u8 || transcript)
role = 1 desktop; 2 phone (separate from traffic direction codes)
new_root = HKDF-SHA256(old_root, salt=SHA256(transcript),
                       info="padlink/v1/resume-root", length=32)
```

All four traffic keys derive from the new root and epoch using §5. Counters and
replay windows restart under these new keys; old packets cannot authenticate.
Resume frames, neutral ready and pings cannot refresh the 30-second secret
lease. Process restart or expiry requires fresh phone consent and a new token.
Candidate socket acquisition, UDP retransmission scheduling, and physical
input/backend rearm are responsibilities of the future session owner.

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

`ClockSync` retains one outstanding probe and one estimate. A Pong must be
authenticated and match its ping ID and exact timestamp. Given local send/receive
times t1/t4 and peer receive/send times t2/t3, offset is bounded by
`[t3-t4, t2-t1]`, without assuming symmetric one-way delay. Invalid timestamps,
processing time beyond RTT, clock regression, a 3-second probe timeout or more
than 500 ms uncertainty fail. The half-width includes 1000 ppm relative drift
during the measurement and estimate age. Estimates expire after 5 seconds and
must be discarded on endpoint/epoch changes. This drift ceiling is a model
assumption to validate on supported hardware, not a measured device guarantee.

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
conformance-tested rather than independently audited. The real UI and socket
flow are integrated and tested. G3 remains open pending independent security
review and the complete release device/ABI failure matrix.

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

The desktop initiates TCP to the phone's actual pairing endpoint. The shared
socket adapters power the foreground Android listener and CLI check. The core
codecs encode complete frames:

```text
length: u16 BE   # counts magic + ver_type + payload, excludes the prefix
magic: u8       # 0x50
ver_type: u8    # (1 << 4) | pairing_message_type
payload
```

The total bound is 4096 bytes, **including** the two-byte prefix; the body is
2–4094 bytes. `FrameReader` validates the prefix before reading any body bytes
into its fixed buffer, and never reads beyond the current frame. Coalesced next
frames remain in the socket. Each framer has one 4096-byte slot. Frame codecs
reject truncation/trailing bytes within an individual frame.
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
2. User enters the phone's token in hidden CLI input (`padlink pair`).
   Desktop sends fresh PakeA.
3. Phone reserves an attempt and replies with fresh PakeB and `cB`.
4. Desktop verifies `cB` and sends `cA`. Its session remains private/pending.
5. Phone verifies `cA`, derives the root/traffic keys, invalidates the token,
   and seals `EpochConfirm(epoch=1, baseline_edge_id=0, neutral flag=1)` under
   phone→desktop/TCP with sequence 0.
6. Desktop releases its pairing session only after this exact ready frame
   authenticates. Wrong type/epoch/sequence/flags, tag failure, or expiry cannot
   release a desktop session. Its TCP replay window already includes ready.
   Ready is a complete length-prefixed authenticated TCP frame (§3.1).

The core returns traffic ownership; it does not mount a controller or authorize
live input. Path probing, neutral physical touch state, permissions, backend
readiness, and watchdog integration are additional gates. `PhonePairingHost`
keeps its session private while SendingReady, then accepts `ready_written` only
after the caller's `FrameWriter` has completed that exact frame. Disconnect or
timeout during this write drops the pending session. The transport must close
the socket and cancel pending state on every framing/IO/lifecycle failure.

### 7.5 Attempt ownership and expiry

`begin_attempt(now_ms)` decrements once when a valid PakeA is accepted. A return
of zero permits the third attempt to finish. `fail_attempt()` does not decrement
again; it invalidates the token only when no attempts remain. Confirmed success,
expiry, cancellation, replacement, or deny invalidates it immediately.

Same-connection retries retain the consented request, session ID, token, and
original phone-side 60 s deadline, while using new PAKE ephemerals. A new valid
PakeA abandons an unfinished previous attempt. The phone checks its deadline
before key-share processing and confirmation. The host bounds the wait after
PakeB to three seconds, clipped by token expiry. A stalled exchange or connection
loss cancels and erases the token; another socket requires a new Request and
fresh explicit consent charged to the same request limiter. Neither reconnect
nor listener restart revives a token or silently generates a replacement.
Desktop retries discard pending PAKE/session material.

Pre-auth Retry (type 7, common header/request ID, empty payload) lets the desktop
abandon a failed PakeB confirmation. The phone releases the reserved attempt
and returns to the original token deadline; no attempt or time is replenished.
Retry is accepted only while waiting for confirmation. The third failed attempt
cannot retry. This control is unauthenticated and grants no trust or session.

Malformed local code input is rejected and counted by the local token checker.
Malformed pre-auth wire data and invalid points are rejected before PAKE; they
must be covered by the transport's read/connection/request limits. Invalid
points do not consume a password-verification attempt in the handshake core;
the host cancels their connection. `PhonePairingHost::begin_connection` charges
socket arrivals before parsing, using the OS peer IP, never a supplied label,
request ID, or source port. It enforces five arrivals per rolling 60 s globally
and per source, with at most five fixed history records. IPv4-mapped IPv6 is
canonicalized. Busy, malformed, denied, expired, and disconnected admissions are
not refunded; source churn cannot bypass the global limit. Already rate-limited
arrivals do not extend the window. Keep one host across listener stop/start.

Only one pending request exists and another cannot be admitted while paired.
Process-local connection IDs prevent a stale UI/socket callback from allowing,
denying, or cancelling a newer prompt. Request receipt never issues a token.
Only `allow` on the current consent prompt calls `PhoneHandshake::consent`.
Android keeps this owner across activity/listener restarts and calls Allow only
from the current consent UI action.

### 7.6 Nonblocking transport and timer integration

`FrameReader`/`FrameWriter` work with nonblocking `Read`/`Write` sockets. Each poll
makes at most one IO call and copies at most one bounded frame, so callers can
interleave watchdog/cleanup work. WouldBlock and Interrupted yield Pending
without spinning or extending deadlines. A queued write has an absolute three-
second deadline. A read uses its caller-supplied stage deadline; the first byte
also starts a three-second frame deadline that later bytes cannot extend. All
deadlines use the same caller-supplied monotonic millisecond clock. Expiry at the
exact deadline, clock regression, overflow, EOF, and fatal IO errors fail closed.

The application/native adapter must:

1. Retain one host, admit the OS peer IP before parsing, bound accepted sockets,
   set nonblocking/TCP_NODELAY, and close rejected sockets without spawning work
   or logging each flood packet.
2. Arm the initial read with the host's three-second Request deadline. Decode
   one complete frame, then call `receive` with its current local connection ID.
3. Show the unverified label/address for at most 30 seconds. Monitor socket loss,
   cancellation, permissions, and app lifecycle while waiting for Allow/Deny.
4. Queue each reply once and rearm the reader for the next phase with the host's
   deadline. Never replace a partial receive or an occupied write slot. Complete
   Accept before reading PakeA, and PakeB before reading ConfirmA/a retry.
5. Use Authenticated mode for ready and subsequent encrypted TCP frames. Call
   `ready_written` only after the ready writer returns Complete. The desktop
   must authenticate ready through `DesktopHandshake::finish` before session use.
6. Poll both host and framer deadlines from timers even without socket activity.
   Close the ID returned by `poll_deadline` before accepting its replacement.
   Every error/EOF/permission loss/background/cancel closes the socket, clears
   frame slots, and calls `close_connection`; retain the host's rate history.

The adapters implement the phone listener and diagnostic desktop client; JNI
uses bounded registry IDs and serialized calls/close. The core does not configure
OS socket buffers/backlog, run a Tokio executor or daemon, or drive real input backends.
Fixed frame slots are not evidence for the desktop aggregate 75 MB cap. Physical
device LAN/permission/ABI tests and application event-loop starvation tests are
still required.

### 7.8 Android binding and memory lifetime

See [android-native/README.md](../android-native/README.md) for the bounded JNI
contract, operation layouts, transfer/resume lifetime and build targets.
The app stops its listener and clears token/session state on background, Stop,
cancel, network loss/route change or native fatal failure. Android 17 LAN
permission is requested before listening; grant/deny/revoke needs API 37 runtime
coverage. Tokens are excluded from saved state and screenshots/task previews.

The shared `BudgetedAllocator` reserves atomically, rolls back failed allocation,
and conservatively accounts old+new transient realloc storage. Fixed journals
and frame slots bound retained protocol data; fallible wire-batch reservations
propagate exhaustion. CLI/native Rust heap metrics do not include all process
RSS, ART/JNI/OS allocations or stacks, and infallible OOM may abort. Aggregate
pressure callbacks/OS containment and the strict product memory gate remain open.

### 7.7 Conformance evidence and limitations

`protocol/tests/rfc9382.rs` matches RFC 9382 Appendix B's pA, pB, Ke, cA and cB
exactly, including `Ke=0e0672dc86f8e45565d338b0540abe69`. The deterministic
vector also checks both peer confirmations and rejects reflected/truncated
MACs. `pairing_flow.rs` tests the PadLink wrapper's fresh exchanges, wrong-code
retries, third-attempt behavior, expiry, metadata/confirmation/ready tampering,
codecs, and bidirectional encrypted traffic. `pairing_transport.rs` adds a real
fragmented loopback exchange with wrong-code retry, mid-frame socket loss,
absolute IO/stage deadlines, admission limits/source churn, stale callbacks,
denial/expiry/ready-write cleanup, and TCP prefix tampering. This is not an audit or proof of
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
- RFC 9382 Appendix B and the pairing/ready failure cases in §7.7;
- fixed-buffer fragmented/coalesced IO, single-call poll budgets, slow-drip/stall
  deadlines, EOF/errors/clock failures, and authenticated TCP length prefixes;
- phone-wide/per-source rolling request limits, busy/denied/malformed arrivals,
  stale callbacks, explicit consent, retry budgets, and ready-write cleanup;
- real loopback TCP pairing, wrong-code retry, and mid-frame connection loss;
- packet/timer races, expiry-preserving rearm, atomic rejected edge batches,
  replay preservation on malformed authenticated payloads, and separate reports
  for recovered press/release transitions.

Still required before live-input use: security and Android ABI validation,
application pairing transport and consent UI, resume handshake,
authenticated path probes, streaming TCP freshness/backpressure integration,
daemon/IPC ownership, native backends, and the failure-injection matrix in
`IMPLEMENTATION_PLAN.md`.
