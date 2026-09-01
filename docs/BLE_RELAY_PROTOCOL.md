# CatPlay iOS BLE Relay protocol v1

The iOS app is a foreground-only BLE peripheral. Android is the BLE central.
The relay never parses or signs MFi challenges and never stores the CMFI PSK.
It transfers complete authenticated CMFI frames between Android and the
configured Raspberry Pi TCP endpoint.

## GATT service

| Role | UUID | Properties |
| --- | --- | --- |
| Service | `C47A0001-2E42-4D46-9A7B-5C8F0E6D1101` | primary |
| Android → iOS request | `C47A0002-2E42-4D46-9A7B-5C8F0E6D1101` | write |
| iOS → Android response | `C47A0003-2E42-4D46-9A7B-5C8F0E6D1101` | notify |
| Relay status | `C47A0004-2E42-4D46-9A7B-5C8F0E6D1101` | read, notify |

Android should request the largest supported ATT MTU before sending a request
and must subscribe to the response and status characteristics first.

## Fragment header

Every characteristic value containing request or response data begins with a
10-byte header. Multi-byte integers use network byte order.

| Offset | Size | Field |
| ---: | ---: | --- |
| 0 | 2 | magic `CR` (`0x43 0x52`) |
| 2 | 1 | version, currently `1` |
| 3 | 1 | high nibble: kind; low nibble: flags |
| 4 | 2 | message ID |
| 6 | 2 | total unfragmented length |
| 8 | 2 | payload offset |
| 10 | remaining | fragment payload |

Kinds are `1=request`, `2=response`, and `3=error`. Flag bit 0 marks the first
fragment and bit 1 marks the final fragment. Fragments must be contiguous and
ordered. The current safety limit is 8192 bytes.

An error payload is a short stable ASCII category such as `relay_busy`,
`invalid_cmfi_request`, or `pi_exchange_failed`. It must never contain a PSK,
CMFI payload, network exception text, or device identifier.

## CMFI forwarding

The reassembled request must be one complete authenticated `CMFI` version-1
frame. The iOS app opens one TCP connection to the configured Pi endpoint,
writes the frame unchanged, reads exactly one complete CMFI response, closes
the connection, and returns the response under the same BLE message ID.

The Android and Pi endpoints retain end-to-end HMAC authentication. BLE pairing
and the iOS application are transport helpers, not part of the MFi trust root.
