# CatPlay iOS MFi Relay

Foreground-only iOS relay for Android head units that can run CatPlay over USB
but cannot reach the remote Raspberry Pi MFi signer over an IP network.

~~~text
iPhone CarPlay stack
  │ USB challenge/response
  ▼
Android Carlink
  │ BLE GATT (authenticated CMFI bytes)
  ▼
This foreground iOS app
  │ TCP on the iPhone's Wi-Fi/cellular path
  ▼
Raspberry Pi CMFI server → physical MFi coprocessor
~~~

The iOS app is only a byte relay. It does not possess an MFi private key, does
not generate a signature, and does not store the Android/Pi CMFI PSK. Video,
audio, touch, microphone, GNSS, iAP2, and NCM remain on the direct USB path.

## Current PoC scope

- SwiftUI foreground UI with explicit Start/Stop;
- CoreBluetooth peripheral service for an Android central;
- bounded and ordered BLE fragmentation/reassembly;
- validation of CMFI framing without inspecting authenticated payloads;
- one TCP connection per CMFI request to a configurable Pi endpoint;
- absolute exchange timeout and one in-flight request;
- payload-redacted diagnostic events;
- GitHub Actions arm64 iPhone build and unsigned IPA artifact without code
  signing material.

The app intentionally declares no Bluetooth background mode. The user must keep
it open. Moving it to the background stops the relay and prevents stale
authentication responses from crossing session boundaries.

## User flow

1. Connect the iPhone and the Raspberry Pi to the same test LAN.
2. Open this app, configure the Pi host and CMFI port (normally `9000`), and tap
   **Start relay**.
3. Wait for the Android Carlink app to subscribe to the relay characteristics.
4. Start Android direct-USB CarPlay.
5. Keep this app in the foreground for the whole initial PoC session so a later
   CarPlay re-authentication can still reach the physical MFi chip.

Normal iOS Bluetooth and local-network privacy permission is still required.
No credential, pairing record, MFi data, certificate, challenge, signature, or
device log belongs in this repository.

## Build

On macOS with Xcode and XcodeGen:

~~~bash
brew install xcodegen
xcodegen generate
xcodebuild \
  -project CatPlayIOSRelay.xcodeproj \
  -scheme CatPlayIOSRelay \
  -configuration Debug \
  -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO \
  build
~~~

For a physical iPhone, open the generated project in Xcode, select a personal or
organization Development Team, choose a unique Bundle ID when necessary, and
run on the device. Signing certificates and provisioning profiles must remain
outside Git.

## Minimal installation without Xcode

The `iOS build` GitHub Actions workflow also produces an unsigned arm64 device
package. Open the latest successful workflow run, download the artifact named
`CatPlayIOSRelay-unsigned-<commit>`, and extract the outer artifact ZIP. It
contains:

- `CatPlayIOSRelay-unsigned.ipa`;
- `SHA256SUMS.txt` for download verification;
- `BUILD-INFO.txt` with the source commit, SDK, architecture, and signing state.

The IPA deliberately contains neither `_CodeSignature` nor
`embedded.mobileprovision`, so iOS will reject a direct installation. On a Mac
with Sideloadly:

1. connect the iPhone over USB and select it in Sideloadly;
2. drag `CatPlayIOSRelay-unsigned.ipa` into Sideloadly;
3. sign with a dedicated test Apple ID and install;
4. enable **Settings → Privacy & Security → Developer Mode** if prompted;
5. trust the developer identity under **Settings → General → VPN & Device
   Management** if prompted;
6. launch the app once, grant Bluetooth and Local Network access, then reconnect
   the iPhone to the Android OTG port for the CarPlay test.

Free personal signing normally expires after seven days. Re-sign the original
unsigned IPA when necessary. Do not commit, upload, or share the signed output,
Apple credentials, provisioning profiles, or device identifiers. This workflow
does not receive or store any Apple account credential.

## Protocol

See [`docs/BLE_RELAY_PROTOCOL.md`](docs/BLE_RELAY_PROTOCOL.md). The Android
implementation must use the same UUIDs, 10-byte fragmentation header, message
limits, and request IDs.

## Repository layout

This repository is designed to be checked out as the CatPlay parent repository
submodule at `ios/catplay-ios-relay`. Its Git history, releases, and macOS CI
remain independent from the Rust/Android CatPlay repository.
