# xBloom Bluetooth API — PyBloom Source Reference

This document consolidates the Bluetooth Low Energy (BLE) behavior implemented by [fhenwood/PyBloom](https://github.com/fhenwood/PyBloom). It is intended as an implementation reference for developers building an xBloom integration in another language or application.

> **Project status and disclaimer**
>
> PyBloom is an unofficial, clean-room reverse-engineering project. It is not affiliated with or endorsed by xBloom. The protocol is not a vendor-supported public API, may vary by machine or firmware, and can change without notice. Commands can move mechanisms, run the grinder, and dispense hot water. Test conservatively with the machine attended.

## Source baseline and evidence policy

This reference was prepared from PyBloom commit [`a4438abe2b2f428a397ff6150dd43d0a420a3555`](https://github.com/fhenwood/PyBloom/tree/a4438abe2b2f428a397ff6150dd43d0a420a3555), dated 2026-03-28.

The following labels distinguish evidence levels:

- **Implemented** — behavior present in executable PyBloom source.
- **Documented** — asserted in PyBloom's protocol documentation or README, but not necessarily enforced or handled by code.
- **Tested with mock** — covered only by the repository's software mock, not necessarily physical hardware.
- **Hardware-dependent** — requires verification against the target machine and firmware.

When prose and code disagree, this document describes the executable implementation first and flags the conflict.

## Contents

1. [Architecture](#architecture)
2. [Installation and prerequisites](#installation-and-prerequisites)
3. [BLE discovery and connection](#ble-discovery-and-connection)
4. [GATT service and characteristics](#gatt-service-and-characteristics)
5. [Binary frame format](#binary-frame-format)
6. [CRC-16](#crc-16)
7. [Commands](#commands)
8. [Notifications and state mapping](#notifications-and-state-mapping)
9. [Recipe data model](#recipe-data-model)
10. [Recipe payload encoding](#recipe-payload-encoding)
11. [Full brew workflows](#full-brew-workflows)
12. [Direct component control](#direct-component-control)
13. [High-level Python API](#high-level-python-api)
14. [Monitoring](#monitoring)
15. [Raw implementation example](#raw-implementation-example)
16. [Reliability, safety, and lifecycle](#reliability-safety-and-lifecycle)
17. [Known inconsistencies and limitations](#known-inconsistencies-and-limitations)
18. [Porting checklist](#porting-checklist)
19. [Source map](#source-map)

## Architecture

PyBloom is asynchronous and layered as follows:

```text
Application / CLI
        |
        v
XBloomClient
  |-- high-level brew workflows
  |-- notification parsing and DeviceStatus
  |-- GrinderController
  |-- BrewerController
  `-- ScaleController
        |
        v
Packet builder / constants / CRC
        |
        v
XBloomConnection abstraction
        |
        v
BleakConnection -> Bleak -> OS Bluetooth stack -> xBloom
```

The library uses [Bleak](https://bleak.readthedocs.io/) for cross-platform BLE operations. All API calls that communicate with the machine are `async`.

## Installation and prerequisites

PyBloom declares:

- Python 3.9 or later
- `bleak>=0.21.0`
- `typer>=0.9.0`
- `rich>=13.0.0`
- A BLE-capable host and an xBloom machine, described by the project as xBloom Studio

Install from a clone:

```bash
git clone https://github.com/fhenwood/PyBloom.git
cd PyBloom
python -m pip install -e .
```

The package installs the `xbloom` CLI.

## BLE discovery and connection

### Discovery

`discover_devices(timeout=5.0)` performs two scans:

1. Scan with the main service UUID as a filter.
2. If that returns no devices, scan all advertisements and retain devices whose advertised name contains `XBLOOM`, case-insensitively.

CLI usage:

```bash
xbloom scan
xbloom scan --timeout 10
```

Python usage:

```python
from xbloom.scanner import discover_devices

devices = await discover_devices(timeout=5.0)
for device in devices:
    print(device.name, device.address)
```

The value called a `mac_address` by PyBloom is passed directly to `BleakClient`. Depending on the operating system, Bleak's device address may not be a literal MAC address; use the address returned by discovery on that host.

### Connection sequence

`XBloomClient.connect(timeout=20.0)` does the following:

1. Returns immediately if already connected.
2. Creates/connects a `BleakClient` using the supplied address.
3. Subscribes to the main notify characteristic (`FFE2`).
4. Best-effort subscribes to an additional read/notify characteristic (`FFE3`); all errors are ignored.
5. Sets `status.connected = True`.
6. Resets machine state by sending recipe stop, brewer quit, and grinder quit commands.
7. Waits 0.5 seconds and returns `True`.

The reset performed during connection is significant: connecting through `XBloomClient` can abort an already running operation.

Recommended connection pattern:

```python
import asyncio
import os
from xbloom import XBloomClient

async def main():
    address = os.environ["XBLOOM_MAC"]

    async with XBloomClient(mac_address=address) as client:
        if not client.is_connected:
            raise RuntimeError("Could not connect to xBloom")
        print(client.status)

asyncio.run(main())
```

`connect()` converts connection exceptions into `False`; it does not re-raise them. Always check the return value or `client.is_connected`.

## GATT service and characteristics

| Role | UUID | PyBloom behavior |
|---|---|---|
| Main service | `0000e0ff-3c17-d293-8e48-14fe2e4da212` | Used as the preferred discovery filter |
| Command write | `0000ffe1-0000-1000-8000-00805f9b34fb` | Every command is written here with `response=False` |
| Main notifications | `0000ffe2-0000-1000-8000-00805f9b34fb` | Required subscription for telemetry and state |
| Additional read/notify | `0000ffe3-0000-1000-8000-00805f9b34fb` | Subscription attempted by `XBloomClient`; failure is ignored |

No pairing, bonding, authentication, or encryption flow is implemented by PyBloom itself. OS- or firmware-level requirements remain hardware-dependent.

## Binary frame format

### Frame actually emitted by PyBloom

Both `build_command()` and `build_command_raw()` emit this layout:

| Offset | Size | Field | Encoding / value |
|---:|---:|---|---|
| 0 | 1 | Header | `0x58` |
| 1 | 1 | Device ID | Default `0x01`; caller-overridable |
| 2 | 1 | Type code | Default `0x01`; Studio mode switch uses `0x02` |
| 3 | 2 | Command ID | Unsigned 16-bit little-endian |
| 5 | 4 | Total length | Unsigned 32-bit little-endian; includes the entire frame and CRC |
| 9 | 1 | Fixed byte | Always `0x01` in the builders; purpose unnamed |
| 10 | N | Payload | Command-specific bytes |
| 10 + N | 2 | CRC | Unsigned 16-bit little-endian |

Thus:

```text
total_length = 12 + payload_length
```

A no-payload command is exactly 12 bytes.

> PyBloom's prose protocol document omits the fixed byte at offset 9 even though its builders, tests, mocks, and examples depend on it. A compatible port should include it.

### Two payload builder modes

`build_command(command, data)` treats `data` as a list of unsigned 32-bit integers and packs each element little-endian:

```python
for value in data:
    packet.extend(struct.pack("<I", value))
```

`build_command_raw(command, data)` appends an already encoded byte string unchanged. Recipe payloads and direct brewer-start payloads use this form.

### Device ID and type code

- The client default device ID is `0x01`.
- Both send helpers allow a per-call `device_id` override.
- The default type code is `0x01`, called “Standard” by the repository documentation.
- `set_easy_mode()` uses type code `0x02`, described as Studio mode.
- PyBloom's notification splitter accepts either `0x58` or `0x02` as the first byte of an incoming frame. The exact alternate Studio notification framing is not fully documented or validated in the repository.

## CRC-16

### Algorithm used by executable code

PyBloom implements a reflected CRC using polynomial `0x8408`, initial value `0x0000`, and no final XOR:

```python
def crc16(data: bytes) -> int:
    crc = 0
    for byte in data:
        crc ^= byte
        for _ in range(8):
            if crc & 1:
                crc = (crc >> 1) ^ 0x8408
            else:
                crc >>= 1
    return crc
```

The CRC is calculated over every frame byte before the CRC field and appended little-endian.

Known vector from the implementation:

```text
Input:  58 01 01 9A 11 0C 00 00 00 01
CRC:    0xDCE3
On wire (little-endian): E3 DC
Frame:  58 01 01 9A 11 0C 00 00 00 01 E3 DC
```

> The prose `PROTOCOL_DOCUMENTATION.md` shows a different initialization/final-XOR variant (`0xFFFF` and a final `^ 0xFFFF`). That does **not** match `src/xbloom/protocol/constants.py`. Use the executable implementation unless hardware testing proves otherwise.

## Commands

Command IDs are shown in decimal, matching the Python enum, with their hexadecimal/on-wire little-endian representation.

### Recipe and workflow commands

| Decimal | Hex | Wire bytes | PyBloom name | Purpose |
|---:|---:|---|---|---|
| 8001 | `0x1F41` | `41 1F` | `APP_RECIPE_SEND_AUTO` | Upload coffee recipe with grinding |
| 8002 | `0x1F42` | `42 1F` | `APP_RECIPE_EXECUTE` | Execute the uploaded coffee recipe |
| 8004 | `0x1F44` | `44 1F` | `APP_RECIPE_SEND_MANUAL` / `APP_RECIPE_SEND` | Upload coffee recipe without grinding |
| 40519 | `0x9E47` | `47 9E` | `APP_RECIPE_STOP` | Stop/abort a recipe |
| 8017 | `0x1F51` | `51 1F` | `APP_RECIPE_START_QUIT` | Legacy recipe stop helper uses this command |
| 4513 | `0x11A1` | `A1 11` | `APP_TEA_RECIP_CODE` | Upload recipe through the tea protocol |
| 4512 | `0x11A0` | `A0 11` | `APP_TEA_RECIP_MAKE` | Execute a tea-protocol recipe; PyBloom sends the recipe again as payload |

### Setup and mode commands

| Decimal | Hex | PyBloom name | Payload |
|---:|---:|---|---|
| 8102 | `0x1FA6` | `APP_SET_BYPASS` | 3 × 32-bit fields: bypass volume float bits, `(temp × 10)` float bits, integer dose |
| 8104 | `0x1FA8` | `APP_SET_CUP` | 2 × float32 bit patterns: maximum and minimum accepted cup weight |
| 4510 | `0x119E` | `APP_BREWER_SET_TEMPERATURE` | One uint32 containing `int(temp_celsius × 10)` |
| 11511 | `0x2CF7` | hard-coded by `set_easy_mode()` | Raw one-byte payload: `01` for EASY, `02` for PRO; type code `0x02` |
| 40516 | `0x9E44` | hard-coded by `confirm_next()` | No payload; confirm/advance next step |

#### Bypass payload (`8102`)

`set_bypass(volume, temp, dose)` encodes:

```text
bytes 0..3   IEEE-754 float32 little-endian bits for volume
bytes 4..7   IEEE-754 float32 little-endian bits for temp * 10
bytes 8..11  uint32 little-endian dose
```

For a grind-and-brew workflow, PyBloom sends volume `0.0`, temperature `0.0`, and `int(recipe.bean_weight)`. The project identifies the dose as critical: a zero dose can cause grinding to be skipped even when bypass water is disabled.

#### Cup payload (`8104`)

Both bounds are encoded as IEEE-754 float32 values, passed through their 32-bit integer bit patterns:

| Cup type | Enum | Maximum | Minimum used by `brew()` |
|---|---:|---:|---:|
| `X_POD` | 1 | 80.0 g | 40.0 g |
| `OMNI_DRIPPER` | 2 | 90.0 g | 40.0 g |
| `OTHER` | 3 | 90.0 g | 40.0 g |

`brew_without_grinding()` instead uses a `0.0 g` minimum for types 1–3, explicitly bypassing the lower safety check because of a reported zero-weight telemetry issue. The `TEA = 4` enum falls back to `(90.0, 40.0)` in both workflows.

### Grinder commands

| Decimal | Hex | PyBloom name | Usage |
|---:|---:|---|---|
| 8006 | `0x1F46` | `APP_GRINDER_IN` | Enter/configure grinder mode with `[size, speed]` as uint32 values |
| 3500 | `0x0DAC` | `APP_GRINDER_START` | Start grinding; controller sends no payload |
| 3505 | `0x0DB1` | `APP_GRINDER_STOP` | Stop grinding |
| 8018 | `0x1F52` | `APP_GRINDER_PAUSE` | Pause grinding |
| 8020 | `0x1F54` | `APP_GRINDER_RESTART` | Restart grinding |
| 8012 | `0x1F4C` | `APP_GRINDER_QUIT` | Exit grinder mode; used during reset |

`GrinderController.start(size, speed, timeout_ms)` first sends `APP_GRINDER_IN`, waits 2 seconds, then sends a no-payload `APP_GRINDER_START`. Its `timeout_ms` argument is currently unused.

### Brewer commands

| Decimal | Hex | PyBloom name | Usage |
|---:|---:|---|---|
| 4506 | `0x119A` | `APP_BREWER_START` | Direct pour with five 32-bit fields |
| 4507 | `0x119B` | `APP_BREWER_STOP` | Stop brewing/pouring |
| 8019 | `0x1F53` | `APP_BREWER_PAUSE` | Pause brewer |
| 8021 | `0x1F55` | `APP_BREWER_RESTART` | Restart brewer |
| 8016 | `0x1F50` | `APP_BREWER_SET_PATTERN` | Set pattern as one uint32 |
| 8013 | `0x1F4D` | `APP_BREWER_QUIT` | Exit brewer mode; used during reset |

Direct `APP_BREWER_START` payload:

| Offset | Size | Value |
|---:|---:|---|
| 0 | 4 | IEEE-754 float32 bits for `flow_rate × 10` |
| 4 | 4 | IEEE-754 float32 bits for `volume × 10` |
| 8 | 4 | IEEE-754 float32 bits for `temperature × 10` |
| 12 | 4 | `water_source` uint32; default `0` |
| 16 | 4 | `pattern` uint32 |

### Scale/tray movement commands

| Decimal | Hex | PyBloom name | Usage |
|---:|---:|---|---|
| 2500 | `0x09C4` | `SG_LEFT` | Continuous/general left command; exposed by packet helper |
| 2501 | `0x09C5` | `SG_RIGHT` | Continuous/general right command; exposed by packet helper |
| 2502 | `0x09C6` | `SG_VIBRATE` | Vibrate/agitate |
| 2503 | `0x09C7` | `SG_LEFT_SINGLE` | Used by `ScaleController.move_left()` |
| 2504 | `0x09C8` | `SG_RIGHT_SINGLE` | Used by `ScaleController.move_right()` |
| 2505 | `0x09C9` | `SG_STOP` | Stop motion |

The controller describes left as the grinder position and right as the brewer position for its tested setup.

## Notifications and state mapping

### Receive path

PyBloom subscribes the same callback to `FFE2` and, if available, `FFE3`. The callback:

1. Scans incoming bytes until it finds a byte equal to `0x58` or `0x02`.
2. Requires at least 10 remaining bytes.
3. Reads a little-endian total length from offsets 5–8.
4. Extracts that many bytes and parses the command at offsets 3–4.
5. Repeats, allowing multiple complete frames in one notification.

For `XBloomClient`, response payload is `frame[10:-2]`.

The receive path does **not** currently:

- validate notification CRCs;
- validate that declared length is at least 12;
- retain a partial frame for completion by a later BLE notification;
- expose unknown command frames to a generic callback;
- track which characteristic produced a parsed status update.

If a frame is split across BLE notifications, it is logged as partial and discarded rather than buffered. A production port should use a persistent stream/framing buffer.

### Known response IDs

#### Position, operation, and lifecycle

| Decimal | Hex | PyBloom name | Meaning / client effect |
|---:|---:|---|---|
| 9000 | `0x2328` | `RD_IN_GRINDER` | Dripper at grinder; documented only |
| 9001 | `0x2329` | `RD_IN_BREWER` | If 12-byte payload exists, reads volume/temp/pattern as uint32 and marks brewing |
| 9002 | `0x232A` | `RD_IN_SCALE` | At scale; enum only |
| 9003 | `0x232B` | `RD_GRINDER_BEGIN` | `grinder.is_running=True`, state `GRINDING` |
| 9004 | `0x232C` | `RD_OUT_GRINDER` | Leaving grinder; enum only |
| 9005 | `0x232D` | `RD_BREWER_BEGIN` | `brewer.is_running=True`, state `BREWING` |
| 9006 | `0x232E` | `RD_OUT_BREWER` | Leaving brewer; enum only |
| 9008 | `0x2330` | `RD_OUT_SCALE` | Leaving scale; enum only |
| 9009 | `0x2331` | `RD_GRINDER_PAUSE` | Enum only |
| 9010 | `0x2332` | `RD_BREWER_PAUSE` | State `PAUSED` |
| 9011 | `0x2333` | `RD_TEA_RECIP_RESTART` | Enum only |
| 9012 | `0x2334` | `RD_TEA_RECIP_SOAK` | Enum only |
| 40502 | `0x9E36` | `RD_BREWER_COFFEE_START` | Marks brewer running and state `BREWING` |
| 40507 | `0x9E3B` | `RD_Grinder_Stop` | Marks grinder stopped and state `IDLE` |
| 40510 | `0x9E3E` | `RD_BLOOM` | State `BREWING` |
| 40511 | `0x9E3F` | `RD_Brewer_Stop` | Marks brewer stopped and state `IDLE` |
| 40512 | `0x9E40` | `RD_ENJOY` | Documented as recipe complete; enum only, no dedicated handler |
| 40513 | `0x9E41` | `RD_ENJOY2` | Enum only |
| 40515 | `0x9E43` | `RD_TEA_RECIP_PAUSE` | Enum only |

#### Telemetry and machine information

| Decimal | Hex | PyBloom name | Payload interpretation in `XBloomClient` |
|---:|---:|---|---|
| 20501 | `0x5015` | `RD_CURRENT_WEIGHT2` | First 4 bytes: little-endian float32 grams |
| 10507 | `0x290B` | `RD_CURRENT_WEIGHT` | Enum only; not handled |
| 8108 | `0x1FAC` | `RD_BREWER_TEMPERATURE` | First 4 bytes: uint32 divided by 10 → °C |
| 40505 | `0x9E39` | `RD_GearReport` | First 4 bytes: uint32 grinder/gear position |
| 40523 | `0x9E4B` | `RD_WATER_VOLUME` | First 4 bytes: float32, truncated to Python `int` |
| 40521 | `0x9E49` | `RD_MachineInfo` | Fixed-width serial/model/version plus water fields, described below |
| 8023 | `0x1F57` | `RD_MachineActivity` | Enum only; not handled |

Machine info parsing uses these payload slices:

| Payload offset | Interpretation |
|---:|---|
| 0–12 | UTF-8 serial number, null-stripped |
| 13–18 | UTF-8 model, null-stripped |
| 19–28 | UTF-8 version, null-stripped |
| 33 | `1` means `water_level_ok=True` |
| 34 | System status, only logged |
| 36 | Water volume byte |

There is an off-by-one guard bug: the code checks `len(payload) >= 34` and then reads offset 34, which actually requires at least 35 bytes. Exceptions are swallowed.

#### Errors and other enumerated responses

| Decimal | PyBloom name | Documented meaning |
|---:|---|---|
| 40517 | `RD_ErrorIdling` | Empty grinding / no beans detected |
| 40522 | `RD_ErrorLackOfWater` | Water tank empty |
| 8204 | `RD_AbnormalDoseOrWater` | Invalid dose or water parameters |
| 8203 | `RD_AbnormalGearPosition` | Dripper/gear position error |
| 40520 | `RD_BYPASS` | Bypass response |
| 40526 | `RD_CurrentGrinder` | Current grinder report |
| 40527 | `RD_BeforeVibration` | Before-vibration event |
| 8007 | `RD_BREWER_IN` | Brewer-in state |
| 8107 | `RD_BREWER_MODE` | Brewer mode |
| 8105 | `RD_GRINDER_SIZE` | Grinder size report |
| 8106 | `RD_GRINDER_SPEED` | Grinder speed report |
| 8009 | `RD_MachineSleeping` | Machine sleeping |
| 8011 | `RD_MachineNotSleeping` | Machine awake |
| 8022 | `RD_BackToHome` | Returned home |
| 8103 | `RD_LedType` | LED type/state |
| 8015 | `RD_UNIT_CHANGE` | Unit change |
| 4508 | `RD_WaterSource` | Water source |
| 40501 | `RD_Pods` | Pod-related report |
| 50038 | `RD_CalibrateStart` | Calibration start |
| 50039 | `RD_Calibrating` | Calibrating |
| 8111 | `RD_EASYMODE_BEGIN` | Easy mode began |
| 40525 | `RD_EASYMODE_RECIPE_NUM` | Easy mode recipe number |
| 11512 | `RD_EASYMODE_RECIPE_ORDER` | Easy mode recipe order |
| 11510 | `RD_EASYMODE_RECIPE_SEND` | Easy mode recipe send |
| 11518 | `RD_EASYMODE_RECIPE_STATE` | Easy mode recipe state |
| 11511 | `RD_EASYMODE_TYPE` | Easy/pro mode type |
| 8113 | `RD_TEA_RECIP_CHANGE_SOAK_TIME` | Tea soak-time change |

These errors and most other enum values are recognized by name but have no state-handling branch. In particular, PyBloom does not set `DeviceState.ERROR`, surface an error object, or automatically stop in response to these error notifications.

### Device state object

`client.status` is a mutable `DeviceStatus` containing:

```text
state: UNKNOWN | IDLE | GRINDING | BREWING | PAUSED | ERROR | SLEEPING
connected: bool
grinder: is_running, speed, size, position
brewer: is_running, temperature, target_temperature, mode
scale: weight, is_tared
serial_number, model, version
water_level_ok, water_volume
last_update
```

Not every field is populated by the current handlers. For example, grinder speed/size, brewer target/mode, and scale tare state are defined but not updated from notifications.

After every recognized or unknown well-formed command passed to `_parse_response`, PyBloom updates `last_update` and invokes all registered status callbacks. Callbacks are synchronous functions and run on the BLE notification callback path; they should return quickly.

## Recipe data model

### Enums

```python
class PourPattern(IntEnum):
    CENTER = 0
    CIRCULAR = 1
    SPIRAL = 2

class VibrationPattern(IntEnum):
    NONE = 0
    BEFORE = 1
    AFTER = 2
    BOTH = 3

class CupType(IntEnum):
    X_POD = 1
    OMNI_DRIPPER = 2
    OTHER = 3
    TEA = 4

class MachineModel(IntEnum):
    UNKNOWN = 0
    ORIGINAL = 1
    STUDIO = 2
```

Use `CupType.OMNI_DRIPPER`. Some PyBloom README/protocol examples incorrectly refer to `CupType.X_DRIPPER`, which does not exist at the pinned commit.

### `PourStep`

| Field | Type | Default | Runtime validation |
|---|---|---:|---|
| `volume` | `int` | required | Must be non-negative; no upper bound |
| `temperature` | `int` | required | `0`, or 40–100 inclusive |
| `flow_rate` | `float` | 3.0 | `0`, or 3.0–3.5 inclusive |
| `pausing` | `int` | 0 | Must be non-negative; no upper bound |
| `pattern` | `PourPattern` | `SPIRAL` | No explicit runtime type/range check |
| `vibration` | `VibrationPattern` | `NONE` | No explicit runtime type/range check |

### `XBloomRecipe`

| Field | Type | Default | Runtime validation / wire role |
|---|---|---:|---|
| `grind_size` | `int` | 60 | 0–150; low byte stored in recipe footer |
| `total_water` | `int` | 0 | Not validated; multiplied by 10 and reduced to one byte |
| `rpm` | `int` | 60 | One of 0, 60, 70, 80, 90, 100, 110, 120 |
| `cup_type` | `int` | 0 | Selects cup-bound presets; not embedded in recipe payload |
| `name` | `str` | `Unknown` | Local metadata only |
| `bean_weight` | `float` | 15.0 | 0–100; truncated to integer dose by `brew()` |
| `id` | `int` | 0 | Local/imported metadata only |
| `adapted_model` | `str` | `Original` | Metadata only |
| `machine_type` | `MachineModel` | `ORIGINAL` | Metadata only in this implementation |
| `pours` | list | empty | Maximum 20; an empty recipe is allowed by validation |

`total_water` is semantically confusing: examples set it to `24` to represent 240 ml, and the builder writes `total_water × 10` to one byte. Values above 25 wrap modulo 256, so a documented README range up to 50 is not safely representable by the implementation.

### JSON recipe import

`parse_recipe_json(data)` accepts a direct object or a nested `recipeVo`. Supported aliases include:

| Destination | Accepted keys, in priority order |
|---|---|
| pours | `pourList`, `pours`, `steps` |
| grind size | `grinderSize`, `grind_size` |
| total water | `grandWater`, `total_water` |
| recipe name | `theName`, `name` |
| recipe ID | `tableId`, `id` |
| pause | `pausing`, `pause` |
| flow | `flowRate`, `flow_rate` |

Dose strings such as `"15g"` are parsed. Vibration flags use `1 = enabled` and `2 = disabled`, combining before/after into the enum.

Important parser caveats:

- Many aliases use Python `or`, so meaningful zero values are replaced by defaults.
- String cup type `X_DRIPPER` attempts to access nonexistent `CupType.X_DRIPPER` and raises `AttributeError`.
- The mixed-case comparison for `XDripper` cannot match because the input is uppercased first.
- Missing pour flow defaults through `... or 0`; `0` is accepted by `PourStep`.
- Pattern values are passed directly to `PourPattern(...)`; invalid values raise.

## Recipe payload encoding

Coffee commands 8001/8004 and the tea recipe helpers use a compact, byte-oriented recipe payload:

```text
+----------------+-------------------------+----------------------+
| body length    | per-pour body           | footer               |
| 1 byte         | N bytes                 | 2 bytes              |
+----------------+-------------------------+----------------------+
```

### Body length

The first byte is only the length of the combined per-pour body. It excludes the length byte itself and the two-byte footer.

Because it is encoded with `struct.pack('B', body_len)`, body length must fit in 0–255. The model's 20-pour limit usually fits when pours need one sub-step each, but sufficiently large volumes can generate enough chunks to exceed 255 and cause a packing error.

### Per-pour data

Each pour is encoded as one or more four-byte volume sub-steps followed by one four-byte metadata record.

#### Volume sub-step

| Byte | Field | Encoding |
|---:|---|---|
| 0 | Volume | 0–127 ml chunk |
| 1 | Temperature | Raw °C byte |
| 2 | Pattern | `0` center, `1` circular, `2` spiral |
| 3 | Vibration | `0` none, `1` before, `2` after, `3` both |

Volumes larger than 127 ml are split into multiple sub-steps. For example, 300 ml becomes `127 + 127 + 46`; every chunk repeats temperature, pattern, and vibration.

A zero-volume pour still produces one `[0, temperature, pattern, vibration]` sub-step.

#### Pour metadata

| Byte | Field | Encoding |
|---:|---|---|
| 0 | Pause | `(-pausing) & 0xFF`, equivalent to two's-complement modulo 256 |
| 1 | Reserved | `0x00` |
| 2 | RPM | Recipe RPM on the first pour only; `0` on later pours |
| 3 | Flow | `int(flow_rate × 10) & 0xFF` |

Pause has no 255-second validation. Values above 255 wrap modulo 256. Flow rate is truncated, not rounded; for example `3.25 × 10 = 32.5` becomes `32`.

### Two-byte footer

| Byte | Field | Encoding |
|---:|---|---|
| 0 | Grind size | `recipe.grind_size & 0xFF` |
| 1 | Total water | `(recipe.total_water × 10) & 0xFF` |

Bean dose and cup type are not present in this payload; they are sent separately with commands 8102 and 8104.

### Encoding example

For one 100 ml pour at 92 °C, spiral, no vibration, no pause, 80 RPM, 3.0 flow, grind size 50, and `total_water=10`:

```text
08                    body length: 8 bytes
64 5C 02 00           pour: 100 ml, 92 °C, spiral, no vibration
00 00 50 1E           metadata: no pause, reserved, 80 RPM, flow 30
32 64                 footer: grind size 50, total-water byte 100
```

Payload:

```text
08 64 5C 02 00 00 00 50 1E 32 64
```

Wrapped in command 8001, the complete frame produced by the PyBloom CRC implementation is:

```text
58 01 01 41 1F 17 00 00 00 01
08 64 5C 02 00 00 00 50 1E 32 64
65 35
```

The declared length is 23 (`0x17`), and the CRC value is `0x3565`, transmitted as `65 35`.

## Full brew workflows

### Grind and brew (`client.brew`)

Required command sequence implemented by PyBloom:

```text
8102 APP_SET_BYPASS
      volume=0.0, temp=0.0, dose=int(bean_weight)
      |
      | wait 1.0 s
      v
8104 APP_SET_CUP
      float32 maximum and minimum cup weights
      |
      | wait 1.0 s
      v
8001 APP_RECIPE_SEND_AUTO
      encoded recipe payload
      |
      | wait 1.0 s
      v
8002 APP_RECIPE_EXECUTE
      no payload
```

PyBloom's documented expected response progression is:

```text
9000  in grinder
9003  grinder begins
40507 grinder stops
9004  leaves grinder
9001  in brewer
9005  brewer begins
40510 bloom, when applicable
40511 brewer stops
40512 enjoy / recipe complete
```

When `wait_for_completion=True`, `brew()` does not explicitly await `RD_ENJOY`. It polls every 0.5 seconds, waits until brewer running has first been observed, then treats a stable transition to not-running as success after a 2-second settle time. It times out after 600 seconds by default and returns `False` if disconnected.

Complete example:

```python
import asyncio
import os
from xbloom import (
    CupType,
    PourPattern,
    PourStep,
    VibrationPattern,
    XBloomClient,
    XBloomRecipe,
)

async def main():
    recipe = XBloomRecipe(
        name="240 ml pour-over",
        grind_size=50,
        rpm=80,
        bean_weight=15.0,
        total_water=24,  # PyBloom encodes this as byte 240
        cup_type=CupType.OMNI_DRIPPER,
        pours=[
            PourStep(
                volume=50,
                temperature=93,
                flow_rate=3.0,
                pausing=30,
                pattern=PourPattern.SPIRAL,
                vibration=VibrationPattern.NONE,
            ),
            PourStep(
                volume=95,
                temperature=93,
                flow_rate=3.5,
                pausing=15,
                pattern=PourPattern.SPIRAL,
            ),
            PourStep(
                volume=95,
                temperature=93,
                flow_rate=3.5,
                pausing=0,
                pattern=PourPattern.SPIRAL,
            ),
        ],
    )

    async with XBloomClient(os.environ["XBLOOM_MAC"]) as client:
        if not client.is_connected:
            raise RuntimeError("Connection failed")

        success = await client.brew(
            recipe,
            wait_for_completion=True,
            timeout=600.0,
        )
        if not success:
            raise RuntimeError("Brew disconnected or timed out")

asyncio.run(main())
```

### Brew with pre-ground coffee (`client.brew_without_grinding`)

Sequence:

1. `8102` with zero bypass and zero dose.
2. Wait 0.3 seconds.
3. `8104` cup bounds, using a zero minimum for known cup types.
4. Wait 0.3 seconds.
5. `8004` manual/no-grind recipe upload.
6. Wait 0.3 seconds.
7. `8002` execute.

Default completion timeout is 300 seconds. Completion detection is the same brewer-running then brewer-stopped polling strategy.

### Tea helpers

- `send_recipe(recipe)` builds a recipe payload and sends command `4513`.
- `execute_recipe(recipe)` rebuilds the payload and sends command `4512` with that payload.

These names are easy to confuse with coffee workflow methods. For the documented grind-and-brew flow, use `send_coffee_recipe()` plus `execute_coffee_recipe()`, or simply `brew()`.

### Stop and advance

```python
await client.stop_recipe()       # 40519
await client.set_easy_mode(True) # 11511, raw 01, type 02
await client.set_easy_mode(False)# 11511, raw 02, type 02
await client.confirm_next()      # 40516
```

## Direct component control

### Grinder

```python
await client.grinder.enter_mode(size=50, speed=80)
await client.grinder.start(size=50, speed=80)
await client.grinder.pause()
await client.grinder.restart()
await client.grinder.stop()

print(client.grinder.size)
print(client.grinder.speed)
print(client.grinder.is_running)
print(client.grinder.position)
```

Calling `start()` automatically enters mode and waits two seconds. Avoid calling `enter_mode()` immediately before `start()` unless sending it twice is intended.

### Brewer / manual pour

```python
from xbloom import PourPattern

await client.brewer.start(
    volume=100.0,
    temperature=93.0,
    flow_rate=3.0,
    pattern=PourPattern.SPIRAL,
    water_source=0,
)
await client.brewer.pause()
await client.brewer.restart()
await client.brewer.stop()

await client.brewer.set_temperature(93.0)
await client.brewer.set_pattern(PourPattern.SPIRAL)
```

The comment in `BrewerController.set_pattern()` says `1=Spiral, 2=Circle`, conflicting with `PourPattern` and recipe encoding (`1=Circular, 2=Spiral`). The enum/recipe mapping is internally consistent and should be preferred, but direct pattern behavior remains hardware-dependent.

### Scale/tray

```python
await client.scale.move_left()   # single move toward grinder
await client.scale.move_right()  # single move toward brewer
await client.scale.vibrate()
await client.scale.stop()

print(client.scale.weight)
```

There is no tare command in the current API.

### `XBloomManualRecipe`

This helper composes direct component commands rather than the compact recipe protocol:

```python
from xbloom.models.manual import XBloomManualRecipe

pour = XBloomManualRecipe.pour_only(volume=100, temperature=85)
ground = XBloomManualRecipe.grind_only(grind_size=50, grind_speed_rpm=80)

await pour.execute(client)
await ground.execute(client)
```

For grinding it moves left, waits 2 seconds, starts the grinder, polls state for up to 120 seconds, and stops. For pours it moves right, waits 2 seconds, starts each direct pour, estimates duration as `volume / flow_rate + 2`, applies local pause sleeps, and stops after the last pour.

This helper has timing and state assumptions rather than protocol acknowledgements. In particular, its grinder loop may observe `is_running=False` before the start notification arrives and exit early. Treat it as an example-level convenience, not a robust state machine.

## High-level Python API

### `XBloomClient`

Constructor:

```python
XBloomClient(mac_address: str, connection: XBloomConnection | None = None)
```

`mac_address` is mandatory even when injecting a custom connection at this commit.

#### Lifecycle and state

| Member | Behavior |
|---|---|
| `await connect(timeout=20.0)` | Connects, subscribes, resets machine, returns bool |
| `await disconnect()` | Optionally resets, stops FFE2 notify, disconnects |
| `is_connected` | Reads underlying connection state |
| `status` | Current mutable `DeviceStatus` |
| `on_status_update(callback)` | Registers synchronous callback; no removal API |
| `async with client` | Connects on entry, disconnects on exit |

#### Recipes and brewing

| Method | Command behavior |
|---|---|
| `brew(recipe, wait_for_completion=True, timeout=600)` | Full 8102 → 8104 → 8001 → 8002 workflow |
| `brew_without_grinding(recipe, wait_for_completion=True, timeout=300)` | Full 8102 → 8104 → 8004 → 8002 workflow |
| `send_coffee_recipe(recipe, type_code=1, device_id=None)` | Upload via 8001 |
| `execute_coffee_recipe(device_id=None)` | Execute via 8002 |
| `send_recipe(recipe, type_code=1, device_id=None)` | Upload via tea command 4513 |
| `execute_recipe(recipe, type_code=1, device_id=None)` | Execute via tea command 4512 with recipe payload |
| `stop_recipe(type_code=1, device_id=None)` | Send 40519 |
| `run_recipe_workflow(recipe)` | Deprecated alias for non-waiting `brew()` |

#### Setup/mode methods

| Method | Behavior |
|---|---|
| `set_bypass(volume, temp, dose, ...)` | Float-bit/uint payload to 8102 |
| `set_cup(f1, f2, ...)` | Two float-bit fields to 8104 |
| `set_temperature(temp_celsius, ...)` | `int(temp × 10)` uint32 to 4510 |
| `set_easy_mode(enabled=True, ...)` | Type 2 command 11511 with one raw byte |
| `confirm_next(...)` | No-payload command 40516 |

The private `_send_command()` and `_send_command_raw()` helpers expose arbitrary command transmission but are not stable public API.

### Connection abstraction

To test or port transport independently, implement:

```python
class XBloomConnection(ABC):
    async def connect(self, address, timeout=20.0) -> bool: ...
    async def disconnect(self) -> None: ...
    @property
    def is_connected(self) -> bool: ...
    async def write_command(self, char_uuid, data, response=False) -> None: ...
    async def start_notify(self, char_uuid, callback) -> None: ...
    async def stop_notify(self, char_uuid) -> None: ...
```

PyBloom's tests include a mock transport/device, but several tests instantiate `XBloomClient(connection=...)` without the now-required address and therefore do not match the constructor at the pinned commit.

## Monitoring

### CLI monitor

```bash
xbloom monitor YOUR_DEVICE_ADDRESS
```

It displays connection, brewer state/temperature, grinder state/position, weight, and water-level state.

### Callback monitoring

```python
def status_changed(status):
    print(
        status.state,
        status.scale.weight,
        status.brewer.temperature,
        status.grinder.is_running,
        status.brewer.is_running,
    )

client.on_status_update(status_changed)
```

Because callbacks are synchronous, dispatch expensive work to a queue/task rather than blocking notification handling.

### Polling

```python
while client.is_connected:
    status = client.status
    print(f"{status.scale.weight:.1f} g, {status.brewer.temperature:.1f} °C")
    await asyncio.sleep(0.2)
```

Values are cached; reading `status` does not perform a GATT read or request fresh telemetry.

## Raw implementation example

The following minimal code mirrors the executable PyBloom frame format without using PyBloom's private client methods:

```python
import struct
from bleak import BleakClient

WRITE_UUID = "0000ffe1-0000-1000-8000-00805f9b34fb"
NOTIFY_UUID = "0000ffe2-0000-1000-8000-00805f9b34fb"

def crc16(data: bytes) -> int:
    crc = 0
    for byte in data:
        crc ^= byte
        for _ in range(8):
            crc = (crc >> 1) ^ 0x8408 if crc & 1 else crc >> 1
    return crc

def frame(command: int, payload: bytes = b"", *, device_id=1, type_code=1):
    packet = bytearray((0x58, device_id, type_code))
    packet += struct.pack("<H", command)
    packet += struct.pack("<I", 12 + len(payload))
    packet += b"\x01"
    packet += payload
    packet += struct.pack("<H", crc16(packet))
    return bytes(packet)

def notification(sender, value: bytearray):
    data = bytes(value)
    if len(data) < 12:
        return
    declared_length = struct.unpack_from("<I", data, 5)[0]
    command = struct.unpack_from("<H", data, 3)[0]
    received_crc = struct.unpack_from("<H", data, declared_length - 2)[0]
    expected_crc = crc16(data[:declared_length - 2])
    if received_crc != expected_crc:
        print("bad CRC")
        return
    payload = data[10:declared_length - 2]
    print(command, payload.hex())

async def send_stop(address: str):
    async with BleakClient(address) as ble:
        await ble.start_notify(NOTIFY_UUID, notification)
        await ble.write_gatt_char(WRITE_UUID, frame(40519), response=False)
```

For production use, add a persistent receive buffer, bounds checks before indexing, serialized command writes, timeouts, explicit acknowledgement/state waits, and disconnect handling.

## Reliability, safety, and lifecycle

### Timing

PyBloom's full `brew()` deliberately waits one second between setup/upload commands. The README says commands need approximately one second between them for reliable operation. The no-grind workflow uses shorter 0.3-second waits. These are timing heuristics, not acknowledgement-driven sequencing.

### Reset and disconnect behavior

`_reset_state()` sends:

1. `APP_RECIPE_STOP` (40519)
2. wait 0.5 s
3. `APP_BREWER_QUIT` (8013)
4. `APP_GRINDER_QUIT` (8012)
5. wait 0.5 s

It runs after connecting and, by default, before disconnecting. Consequently:

- Connecting can abort an operation already running on the machine.
- Leaving an `async with` block can abort the brew.
- To let a started brew continue after client disconnect, PyBloom examples set the private field `client._cleanup_on_disconnect = False`.
- That flag affects disconnect cleanup only; it does not disable reset-on-connect.

Relying on a private field is fragile. A port should expose an explicit lifecycle policy such as `reset_on_connect` and `abort_on_disconnect`.

### Cancellation and emergency stop

Ctrl+C or coroutine cancellation does not inherently stop hardware. The async context manager will call `disconnect()`, which normally sends abort/quit commands, but this is best-effort and exceptions are swallowed. Applications should provide a visible, explicit stop action and remain connected until its result is confirmed when safety matters.

### Connection ownership

A BLE peripheral commonly permits only one active central connection. PyBloom includes an optional Linux-oriented “robust” connection module that can:

- retry connection attempts;
- call `bluetoothctl disconnect`;
- scan host processes and kill Python processes whose command lines match broad terms such as `xbloom`, `bleak`, `brew`, or the device address.

This process-killing behavior is invasive, Linux-specific, and not used by the default `XBloomClient`. Do not enable it in a general-purpose application without narrowing the ownership model and obtaining explicit user consent.

### Hot water and moving mechanisms

Before testing direct commands:

- Keep hands clear of the moving dripper/tray and grinder.
- Ensure the water path terminates in a suitable vessel.
- Verify the reservoir, cup placement, and cup capacity.
- Start with low water volumes and known-safe temperatures.
- Do not leave reverse-engineered automation unattended.
- Keep a hardware stop mechanism accessible.

## Known inconsistencies and limitations

These are especially relevant when porting the protocol:

1. **CRC prose vs code:** documentation shows init `0xFFFF`/final XOR; executable code uses init `0`/no final XOR.
2. **Missing fixed byte in prose:** builders include `0x01` at frame offset 9; the prose packet table does not.
3. **Generic parser offset:** `parse_response()` returns `data[8:-2]`, which begins inside the length field. `XBloomClient` correctly uses `data[10:-2]`.
4. **No fragmented-frame reassembly:** partial BLE frames are discarded.
5. **No notification CRC check:** the client state handler accepts frames without validating their CRC.
6. **Alternate header uncertainty:** incoming `0x02` is accepted, but the alternate Studio frame shape is not established by tests/documentation.
7. **Nonexistent enum in examples:** `CupType.X_DRIPPER` should be `CupType.OMNI_DRIPPER`.
8. **Pattern comment conflict:** direct brewer comment differs from the enum and recipe format.
9. **`total_water` wraparound:** multiplying by 10 into one byte silently wraps values above 25.
10. **Pause wraparound:** pauses above 255 silently wrap.
11. **Fractional dose truncation:** `brew()` converts bean weight using `int()`.
12. **Fractional flow truncation:** `int(flow_rate * 10)` turns 3.25 into 32, not 33.
13. **Completion is inferred:** `brew()` uses brewer stop, not `RD_ENJOY`.
14. **Errors are not surfaced:** error response enums do not alter state or raise exceptions.
15. **No request/response correlation:** send methods return after the GATT write and do not await acknowledgements.
16. **Reset is destructive to current state:** connect and default disconnect send stop/quit commands.
17. **Machine info bounds bug:** the code can read byte 34 after only checking for 34 bytes.
18. **Only FFE2 is unsubscribed:** disconnect does not explicitly stop FFE3 notifications before disconnecting.
19. **Status fields are partial:** many declared status properties are never updated.
20. **No callback removal:** registered callbacks persist for the client's lifetime.
21. **Injected transport still needs address:** constructor rejects `mac_address=None`, conflicting with repository mocks.
22. **Mock coverage is not hardware proof:** numerous tests are skipped as requiring hardware; some active tests also contradict current enums or constructor behavior.
23. **README parameter ranges drift from code:** README claims grind 1–100 and RPM 60–100, while model validation accepts grind 0–150 and RPM 0 or 60–120 in tens.
24. **Model support is not branched:** `machine_type` exists but does not select different UUIDs, packet formats, or command behavior.
25. **No OTA/NFC BLE implementation:** NFC format is documented separately, but PyBloom does not provide NFC writing or firmware-update APIs.

## Porting checklist

For a robust Swift, Kotlin, Rust, or other implementation:

- [ ] Discover by service UUID, with name fallback if the platform permits it.
- [ ] Preserve the platform-specific peripheral identifier rather than assuming a MAC address.
- [ ] Connect and discover the service/characteristics.
- [ ] Subscribe to FFE2; treat FFE3 as optional pending hardware verification.
- [ ] Serialize writes to FFE1 and use write-without-response only if the characteristic supports it.
- [ ] Emit the offset-9 fixed `0x01` byte.
- [ ] Use little-endian command, length, integer, float-bit, and CRC fields.
- [ ] Use the code's CRC variant and verify with known vectors.
- [ ] Maintain a persistent notification buffer and parse zero, one, or many frames per callback.
- [ ] Validate declared lengths and CRC before updating state.
- [ ] Keep unknown responses observable for protocol research.
- [ ] Model command acknowledgements/events explicitly and correlate workflow state.
- [ ] Treat error responses as first-class typed events.
- [ ] Make reset-on-connect and abort-on-disconnect explicit user choices.
- [ ] Use the exact full-brew setup order: 8102, 8104, 8001/8004, 8002.
- [ ] Preserve approximately one-second spacing unless acknowledgements provide a safer gate.
- [ ] Encode recipe body length and footer exactly as described.
- [ ] Reject values that would wrap one-byte fields.
- [ ] Test actual firmware for device ID, type code, alternate headers, patterns, cup bounds, and all safety behavior.
- [ ] Add captured-frame fixtures from real hardware before relying on mocks.

## NFC note

PyBloom's protocol document also describes xBloom recipe cards as ISO 15693, 128-byte NFC tags with hash, recipe ID, pour records, settings, and CRC-8. That format is not transported over the BLE API and the library contains no NFC reader/writer implementation, so it is outside this Bluetooth reference. It may still be useful for comparing recipe semantics; see PyBloom's own protocol document linked below.

## Source map

Primary source files at the pinned commit:

- [Project README and usage examples](https://github.com/fhenwood/PyBloom/blob/a4438abe2b2f428a397ff6150dd43d0a420a3555/README.md)
- [Project protocol documentation](https://github.com/fhenwood/PyBloom/blob/a4438abe2b2f428a397ff6150dd43d0a420a3555/docs/PROTOCOL_DOCUMENTATION.md)
- [BLE UUIDs, commands, responses, and CRC](https://github.com/fhenwood/PyBloom/blob/a4438abe2b2f428a397ff6150dd43d0a420a3555/src/xbloom/protocol/constants.py)
- [Packet builders](https://github.com/fhenwood/PyBloom/blob/a4438abe2b2f428a397ff6150dd43d0a420a3555/src/xbloom/protocol/builder.py)
- [Generic response parser](https://github.com/fhenwood/PyBloom/blob/a4438abe2b2f428a397ff6150dd43d0a420a3555/src/xbloom/protocol/parser.py)
- [Main client, lifecycle, notifications, and brew workflows](https://github.com/fhenwood/PyBloom/blob/a4438abe2b2f428a397ff6150dd43d0a420a3555/src/xbloom/core/client.py)
- [Bleak transport](https://github.com/fhenwood/PyBloom/blob/a4438abe2b2f428a397ff6150dd43d0a420a3555/src/xbloom/connection/bleak_impl.py)
- [Connection abstraction](https://github.com/fhenwood/PyBloom/blob/a4438abe2b2f428a397ff6150dd43d0a420a3555/src/xbloom/connection/base.py)
- [Optional robust/Linux connection behavior](https://github.com/fhenwood/PyBloom/blob/a4438abe2b2f428a397ff6150dd43d0a420a3555/src/xbloom/connection/robust.py)
- [Device discovery](https://github.com/fhenwood/PyBloom/blob/a4438abe2b2f428a397ff6150dd43d0a420a3555/src/xbloom/scanner.py)
- [Recipe and status types](https://github.com/fhenwood/PyBloom/blob/a4438abe2b2f428a397ff6150dd43d0a420a3555/src/xbloom/models/types.py)
- [Recipe payload builder and JSON parser](https://github.com/fhenwood/PyBloom/blob/a4438abe2b2f428a397ff6150dd43d0a420a3555/src/xbloom/models/recipes.py)
- [Manual recipe helper](https://github.com/fhenwood/PyBloom/blob/a4438abe2b2f428a397ff6150dd43d0a420a3555/src/xbloom/models/manual.py)
- [Grinder controller](https://github.com/fhenwood/PyBloom/blob/a4438abe2b2f428a397ff6150dd43d0a420a3555/src/xbloom/components/grinder.py)
- [Brewer controller](https://github.com/fhenwood/PyBloom/blob/a4438abe2b2f428a397ff6150dd43d0a420a3555/src/xbloom/components/brewer.py)
- [Scale/tray controller](https://github.com/fhenwood/PyBloom/blob/a4438abe2b2f428a397ff6150dd43d0a420a3555/src/xbloom/components/scale.py)
- [Protocol tests](https://github.com/fhenwood/PyBloom/blob/a4438abe2b2f428a397ff6150dd43d0a420a3555/tests/test_protocol.py)
- [Workflow mock and BLE tests](https://github.com/fhenwood/PyBloom/blob/a4438abe2b2f428a397ff6150dd43d0a420a3555/tests/test_spec_5_workflows_ble.py)

---

This document describes PyBloom's behavior at the pinned source revision; it does not claim to be an official xBloom protocol specification.
