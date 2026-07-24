# xBloom Native

A local-first iPhone companion for xBloom Studio. The app uses SwiftUI,
SwiftData, Core Bluetooth, and a user-supplied Gemini API key. It does not run
or connect to an xBloom application server.

## Current implementation

- Native five-tab SwiftUI interface.
- Local beans, inventory, recipes, and brew history using SwiftData.
- Recipe editor and deterministic machine-safety validation.
- Direct Core Bluetooth discovery, connection, telemetry, recipe transmission,
  execution, and stop commands.
- PyBloom-compatible CRC, packet framing, recipe encoding, pour chunking, and
  brew command ordering.
- Gemini API key storage in iOS Keychain.
- Gemini coffee-bag photo import and structured recipe generation service.
- Swift Charts brew telemetry views.

## Requirements

- A Mac with the full Xcode application installed.
- iOS 17 or later on the target iPhone.
- An Apple ID configured in Xcode for device signing.
- Bluetooth enabled on the iPhone.
- A Gemini API key for AI features only.

The app continues to provide its library, history, recipe editor, and Bluetooth
features without Gemini or an internet connection.

## Open and run

1. Launch Xcode once, accept its license, and allow it to install required components.
2. If command-line tools still point at the standalone Command Line Tools, run
   `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer`.
3. Open `XBloom.xcodeproj`.
4. Select the `XBloom` scheme.
5. In Signing & Capabilities, select your Apple development team.
6. Connect and trust your iPhone.
7. Select the iPhone as the run destination and press Run.

The iOS simulator can verify the interface and database, but it cannot test the
real xBloom Bluetooth connection. Use a physical iPhone for BLE testing.

## Tests

The platform-independent domain and protocol tests can run without Xcode:

```sh
swift test
```

The Bluetooth implementation is unofficial and derived from the MIT-licensed
PyBloom interoperability project. See `THIRD_PARTY_NOTICES.md`.
