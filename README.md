# xBloom Native

A local-first iPhone companion for xBloom Studio. The app uses SwiftUI,
SwiftData, Core Bluetooth, and a private Supabase account for durable sync.
Gemini requests run through an authenticated Supabase Edge Function so the
provider key is never shipped in the mobile app.

## Current implementation

- Native five-tab SwiftUI interface.
- Offline-first beans, inventory, recipes, and brew history using SwiftData.
- Authenticated Supabase backup and multi-device synchronization.
- Row Level Security that isolates every user's cloud records.
- Recipe editor and deterministic machine-safety validation.
- Direct Core Bluetooth discovery, connection, telemetry, recipe transmission,
  execution, and stop commands.
- PyBloom-compatible CRC, packet framing, recipe encoding, pour chunking, and
  brew command ordering.
- Server-side Gemini coffee-bag import and structured recipe generation.
- Swift Charts brew telemetry views.

## Requirements

- A Mac with the full Xcode application installed.
- iOS 17 or later on the target iPhone.
- An Apple ID configured in Xcode for device signing.
- Bluetooth enabled on the iPhone.
- A Supabase account created from the app for cloud sync and AI features.

The app continues to provide its on-device library, history, recipe editor, and
Bluetooth features without an internet connection. Sync and AI resume when the
device reconnects.

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

## Bluetooth documentation

- `docs/APP_BLE_IMPLEMENTATION.md` — what this app sends: the brew sequence with
  and without the grinder, the pre-brew scale, weighing and grinder screens, the
  grinder interlock, and how a dose comes off the bean bag.
- `docs/VERIFIED_MACHINE_BEHAVIOUR.md` — what the owner's machine actually does,
  read out of traffic recordings. Takes precedence over everything else.
- `docs/OFFICIAL_APP_BLE_COMPARISON.md` — the vendor's command table, extracted
  from its shipped binary.
- `docs/PYBLOOM_BLUETOOTH_API.md` — the third-party reference this app started
  from. Describes different firmware in places; treat as background.
