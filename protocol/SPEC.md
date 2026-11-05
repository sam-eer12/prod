# PadLink Protocol Specification

**Status: draft scaffold. Not normative and not implemented.**

This file will define the wire contract shared by the Android app and the
desktop CLI/daemon. Until it is completed and reviewed, no compatibility,
security, or latency claim should be made from this document.

## Planned sections

1. Roles, version negotiation, and capability exchange
2. Pairing request, consent, six-character code, and PAKE suite
3. Key schedule and nonce construction per direction, transport, and epoch
4. Authentication, replay protection, and clock-offset bounds
5. State packet and bounded digital-edge journal encoding
6. UDP probes, framed TCP fallback, and migration rules
7. Input watchdog, neutral state, and fresh-epoch rearm
8. Error handling and fail-closed behavior
9. Golden vectors and fuzzing requirements

## Baseline constants

| Name | Value |
| :--- | :--- |
| Protocol version | `0` (unstable scaffold) |
| Pairing code length | 6 characters |
| Pairing code alphabet | `23456789ABCDEFGHJKLMNPQRSTUVWXYZ` |
