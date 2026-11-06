# Shared Android native core

Gradle runs `build_android.py` with NDK 28.2.13676358/API 28 and packages
`libpadlink_core.so` for arm64-v8a, armeabi-v7a, x86 and x86_64. Every ELF uses
16 KiB load-segment alignment. Install the corresponding Rust targets first.

`NativeCore` exposes `create(role, bytes, monotonic_ms)`,
`call(handle, operation, connection, bytes, monotonic_ms)` and `close(handle)`.
Arguments are checked before copying and limited to 4096 bytes. IDs are opaque
registry keys, never pointers; four handles and one phone-server owner are
allowed. Calls and close serialize under the registry mutex. Invalid/closed
handles, input, time, or state throw `IllegalStateException`. A contained panic
clears all registry slots and secrets, including a poisoned mutex; existing
handles become stale. This cannot recover an infallible allocation abort.
Errors/debug omit secrets.

Roles: 0 phone server, 1 desktop in-memory handshake (UTF-8 label), 2 diagnostic
desktop socket client (`endpoint + newline + label`). Time uses elapsed realtime
milliseconds; clock regression or expired leases fail closed.

| Owner | Operations |
| --- | --- |
| Phone | 0 state; 1 start endpoint → actual endpoint; 2 stop; 3 poll; 4 Allow; 5 Deny; 6 code; 7 deadline; 8 disconnect |
| Handshake | 10 Request; 11 Accept; 12 code → PakeA; 13 PakeB → ConfirmA; 14 ready → same handle becomes Session |
| Desktop socket | 20 poll; 21 enter code; 22 send typed payload; 23 code deadline |
| Transfer | 30 phone connection → new Session handle; 31 desktop client → new Session handle (both close old sockets; phone history retained) |
| Session | 15 seal `[transport,type,payload]`; 16 open `[transport,packet]` → `[type,payload]`; 17 check live/expiry; 18 validated local sample time LE u64; 19 epoch LE u32 |
| Resume | 40 start candidate (`transport + newline + desktop + newline + phone`); 41 desktop begin; 42 receive; 43 phone ready fully written; 44 finish → same handle becomes Session; 45 check live/deadline |
| Metrics | 90 Rust heap used, peak, limit, rejection count (four LE u64; valid handle required) |

Transfer reserves a free registry slot before moving the lease. The old owner
handle remains valid until closed. A failed consumed resume/finish erases its
session; close still releases the handle. Ordinary seal/open are unavailable
while resuming. JNI 18 is a trusted integration hook: callers must first verify
authenticated State freshness using conservative clock bounds; it must never
be called for pings, replays, retries or neutral ready.

Resume receive input is `[source_utf8_len:LE u16, source_utf8, encrypted_frame]`;
source text is at most 128 bytes. Output is `[ready:u8, count:u8, repeated
(frame_len:LE u16, frame)]`, with at most two frames of at most 258 bytes each.
Transport codes are 1 UDP / 2 TCP. TCP packets include their authenticated BE
length prefix. Kotlin `NativeSession` supplies the typed wrapper. Socket/path
selection, read/write progress, retransmission and neutral backend ownership
remain caller responsibilities; a successful JNI result cannot authorize input.

The native allocator's 24,000,000-byte Rust heap budget excludes ART/Java, JNI
and OS allocations and stacks. It is accounting with a last-resort guard,
not the desktop product's aggregate 75 MB RSS guarantee.
