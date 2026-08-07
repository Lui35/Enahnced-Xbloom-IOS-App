# Official xBloom App vs. This App — Bluetooth Surface Comparison

Extracted from `xBloom Coffee.app` (`com.xbloom.tbdx`), version **2.2.3**, arm64, decrypted
(`cryptid 0`), minimum iOS 14.0. Compared against this project's `Sources/XBloomCore/XBloomProtocol.swift`,
`Sources/XBloomCore/XBloomNotificationFramer.swift`, `XBloomApp/Services/XBloomBLEClient.swift`, and
against `docs/PYBLOOM_BLUETOOTH_API.md` (the PyBloom reference this app was built from).

## Evidence policy

Everything below is labelled by how it was obtained:

- **Confirmed** — read directly out of the shipped binary (constant tables, Swift reflection metadata,
  disassembled instructions, `Info.plist`).
- **Inferred** — a reasonable reading of a confirmed name or code path, not proven.
- **Unverified** — asserted by the PyBloom reference and *not* corroborated by the official binary.

The official app was compiled with source paths and Swift reflection metadata intact, so type and
enum-case names are the vendor's own identifiers, not guesses:

```
/Users/stevenlin/Documents/tbdx/ios-git/xBloom/Expand/Tools/BLE/BLECentralManager.swift
/Users/stevenlin/Documents/tbdx/ios-git/xBloom/Expand/Tools/BLE/BLECommands.swift
/Users/stevenlin/Documents/tbdx/ios-git/xBloom/Expand/Tools/BLE/BLERequestAPI.swift
/Users/stevenlin/Documents/tbdx/ios-git/xBloom/Expand/Tools/BLE/BinaryConversion.swift
```

### How the command table was recovered

The 101 case names came from the Swift field descriptor in `__TEXT,__swift5_fieldmd`. The matching raw
values are a contiguous 101-entry `Int64` table at `0x1009aee88`–`0x1009af1a8` in `__TEXT,__const`.
Alignment was verified against seven consecutive independently-known anchors:

| Index | Case name | Table value | Independent confirmation |
|---:|---|---:|---|
| 41 | `recipe_send_cmd` | 8001 | PyBloom `APP_RECIPE_SEND_AUTO` |
| 42 | `tearecipe_send_cmd` | 4513 | PyBloom `APP_TEA_RECIP_CODE` |
| 43 | `recipe_send_cmd_nogrinder` | 8004 | PyBloom `APP_RECIPE_SEND_MANUAL` |
| 44 | `recipe_marking` | 8002 | PyBloom `APP_RECIPE_EXECUTE` |
| 45 | `tearecipe_marking` | 4512 | PyBloom `APP_TEA_RECIP_MAKE` |
| 46 | `spindlemove_left` | 2500 | PyBloom `SG_LEFT` |
| 47 | `spindlemove_right` | 2501 | PyBloom `SG_RIGHT` |

## What matches exactly

These are **confirmed** identical between the official app and this project. The transport layer is right.

| Element | This app | Official app |
|---|---|---|
| GATT service | `0000e0ff-3c17-d293-8e48-14fe2e4da212` | `0000E0FF-3C17-D293-8E48-14FE2E4DA212` (only BLE service UUID in the binary besides Nordic DFU) |
| Frame header | `0x58` | `0x58` (4215 `#0x58` immediates in the disassembly; framing identical) |
| CRC | reflected CRC-16, poly `0x8408`, init `0x0000`, no final XOR | identical — `mov w0, #0x0` / `mov w10, #0x8408` / `ldrb` / `eor` at `0x100193304` |
| Background mode | `UIBackgroundModes = [bluetooth-central]` | same |
| Permission key | `NSBluetoothAlwaysUsageDescription` | same |
| MTU handling | `maximumWriteValueLength(for: .withoutResponse)` | uses `maximumWriteValueLengthForType:` |
| Inbound validation | rejects frames `< 12` bytes and bad CRC-16 | same — log string: `"error frames count < 12 or crc16 check failed, frames("` |

That last row matters: **PyBloom validates neither length nor CRC on receive**, and its own docs say so
(`docs/PYBLOOM_BLUETOOTH_API.md`, "Receive path gaps"). This app added both. The official app does the
same, so on inbound validation this project is *closer to the vendor than the reference it was built from*.

The official app's framing goes further still. Its validation enum has eight outcomes, so it also checks
device ID, command ID, address, and function code:

```
data_normal, data_length_longer, data_crc_abnormal, data_id_abnormal,
data_cmd_abnormal, data_addr_abnormal, data_func_abnormal, data_length_short
```

## Divergence 1 — FFE3 is deliberately ignored by the vendor

**Confirmed.** This app subscribes to `FFE3` and feeds it into `auxiliaryNotificationFramer`
(`XBloomBLEClient.swift:532`, `:580`). The official app subscribes too, but in its
`didUpdateValueFor` handler it compares the characteristic UUID and **returns early** when it is FFE3,
logging `ble: 过滤特征 FFE3` ("filter characteristic FFE3") — disassembly at `0x1001abd64`.

Note that `FFE1` and `FFE2` appear **nowhere** in the official binary as literals — not as C strings, not as
Swift small-string immediates. Combined with the error string `"Not found write characteristic"`, the
official app appears to select the write characteristic by **property** rather than by UUID
(*inferred*), while pinning only the service UUID and the FFE3 exclusion.

**Consequence for this app:** any telemetry currently arriving on FFE3 and merged into `telemetry` is data
the vendor's own app throws away. If your `MachineTrafficLog` shows FFE3 frames, they are worth auditing —
they may be duplicates of FFE2, or a different framing entirely.

## Divergence 2 — two opcodes this app sends do not exist in the vendor's command set

**Confirmed.** `scaleVibrate = 2502` and `scaleStop = 2505` (`XBloomProtocol.swift:11-12`) are **not in the
official app's 101-command enum**. The only spindle/tray movement commands the vendor ships are
`spindlemove_left = 2500` and `spindlemove_right = 2501`. (2502–2505 do appear in the binary, but only inside
`__LLVM_COV` coverage-mapping data — not as protocol constants.)

Both values come from PyBloom's `SG_VIBRATE` / `SG_STOP` and are **unverified** against the vendor.

**Consequence:** `testConnection()` (`XBloomBLEClient.swift:193-195`) is built entirely on these two
opcodes. If the machine ignores them, the test reports "No reply arrived" and blames the official app being
open — when the real cause could be that the machine never recognised the command. A diagnostic built on a
known-good opcode (`device_current_page = 8023` or `device_sync_info = 40521`) would be more trustworthy.

## Divergence 3 — two error IDs this app parses do not exist either

**Confirmed.** `abnormalGearPosition = 8203` and `abnormalDoseOrWater = 8204`
(`BrewProgressTracker.swift:23-24`, and the `.error` branch in `XBloomProtocol.parseNotification`
`:195`) are **absent from the official enum**. Byte-scanning the binary for `8203`/`8204` as 64-bit
constants returns zero hits.

They are PyBloom-sourced and **unverified**. The vendor's two confirmed error notifications are
`grinder_empty_abnormal = 40517` and `watertank_volume_low = 40522`, both of which this app already handles
correctly.

## Divergence 4 — notification semantics this app has slightly wrong

**Confirmed** names, **inferred** consequences.

| ID | This app calls it | Vendor calls it | What to reconsider |
|---:|---|---|---|
| 9009 | `grinderPause` | `device_grinder_pass` | The vendor uses *both* spellings in one enum — `grind_pause = 8018` and `device_grinder_pass = 9009`. "Pass" is therefore deliberate, not a typo. Likely "grinder stage passed", not "paused". |
| 9010 | `brewerPause` | `device_brewer_pass` | Same. `BrewProgressTracker` advances `pourIndex` on 9010 via `awaitingNextPour`. If 9010 means "brewer stage passed" rather than "paused", the pour-boundary logic still holds, but the naming is misleading and the `.paused` state mapping in `parseNotification:189` is probably wrong. |
| 40510 | `bloom` | `watering_phase` | Not bloom-specific. It is the generic pouring phase. Mapping it to `.brewing` is correct; calling it `bloom` is not. |
| 40511 | `brewerStop` | `device_watering_finish` | Means *a watering phase finished*, not the brewer shutting down. This app maps it to `.idle` (`parseNotification:191`), which may end a session that still has pours remaining. |
| 40512 | `enjoy` | `takecup_yerno` | "Take cup" — correct as the completion cue. |
| 40513 | `enjoyAlternate` | `brewer_finish` | This is the real brewer-finished event, not an alternate "enjoy". |
| 40507 | `grinderStop` | `device_grinder_finish` | "Finished", not "stopped". Mapping to `.idle` mid-program is questionable for the same reason as 40511. |
| 3500 | *(unused)* | `grind_adjust` | PyBloom calls 3500 `APP_GRINDER_START`. The vendor calls it **adjust**. The actual start is `grind_begin = 3503`, which PyBloom does not document at all. |
| 8104 | `setCup` | `device_pod_type` | The vendor treats this as pod/cup **type**, not a weight-bounds setter. This app sends two float32 cup weights here (`brewSequence:163`). The payload shape is **unverified** against the vendor. |
| 8002 | `recipeExecute` | `recipe_marking` | Same position in the flow; name differs. No action needed. |
| 8012 / 8013 | `grinderQuit` / `brewerQuit` | `out_grinder_page` / `out_brewer_page` | UI-page exit semantics. Behaviour matches. |

## Divergence 5 — capability gap

This app implements **10 commands and 24 notifications**. The vendor's single `BLECommands` enum has **101
entries** covering both directions. Everything below is confirmed present in the vendor binary and absent
from this project.

**Directly actionable:**

| ID | Vendor name | Why it matters here |
|---:|---|---|
| 8100 | `device_mtu_negotiate` | The vendor explicitly negotiates MTU. This app only *reads* `maximumWriteValueLength` and throws `packetTooLarge` when a recipe exceeds it (`XBloomBLEClient.swift:307`). Negotiating would remove that failure mode. |
| 8008 | `device_nosleep` | An explicit keep-awake command. This app currently tells the *user* to "keep the machine awake" in three separate error strings. This is the real fix. |
| 8009 / 8011 / 40514 | `device_into_sleep` / `device_wakeup_sleep` / `device_sleep` | Sleep lifecycle, including a device→app sleep notification. |
| 8500 | `weight_cleared` | Tare. PyBloom states "There is no tare command in the current API" — that is wrong. |
| 10507 | `weight_current` | A second weight channel alongside `weight_realTime = 20501`. |
| 40518 / 40524 | `brew_flow_pause` / `brew_flow_resume` | Pause and resume a running recipe. This app can only stop (`40519`). |
| 8017 | `recipe_marking_cancel` | Cancel a queued recipe without the full stop path. |
| 8023 / 8022 | `device_current_page` / `device_backto_home` | Query machine UI state — a safe connection probe (see Divergence 2). |
| 40520 | `bypass_begin` | Confirms the bypass command took effect. |
| 40506 | `grinder_doing` | Grinder-progress notification. |
| 40527 | `pour_first_vibration_before` | Agitation event for the first pour. |
| 40505 / 40526 / 50038 / 50039 | `device_gears`, `gear_reset_zero`, `gear_start_reset_zero`, `gear_resetting_zero` | Grinder gear position and zero calibration. |

**Whole subsystems not modelled here:**

- **Direct brewer control** — `4503` `brewer_stop_rotation`, `4504` `brewer_circular`, `4505` `brewer_spiral`,
  `4506` `brewer_begin`, `4507` `brewer_stop`, `4508` `brewer_water_source`, `4510` `brewer_temperature`,
  `8016` `brewer_pour_mode`, `8019` `brewer_pause`, `8021` `brewer_restart`, `8107` `device_brewer_mode`.
- **Direct grinder control** — `3500` `grind_adjust`, `3502` `grind_zero`, `3503` `grind_begin`,
  `3505` `grind_end`, `8006` `in_grinder_page`, `8018` `grind_pause`, `8020` `grind_restart`,
  `8105` `device_grinder_size`, `8106` `device_grinder_speed`.
- **Spindle/tray** — `2500`/`2501` move, `40503`/`40504` moving-left/left-stop,
  `40508`/`40509` moving-right/right-stop.
- **Easy/Pro mode** — `8111` `device_easymode_begin`, `11510` `easymode_recipe_send`,
  `11511` `easymode_type`, `11512` `easymode_recipe_order`, `11518` `device_easymode_change`,
  `40525` `easymode_recipe_num`.
- **Tea protocol** — `4512` `tearecipe_marking`, `4513` `tearecipe_send_cmd`,
  `8113` `tea_change_waittime`, `9011` `device_tea_unpass`, `9012` `device_tea_wait`.
- **Pour geometry** — `11506`/`11507` read/write pour radius, `11508`/`11509` read/write shake PPS.
- **OTA** — `8101` `device_ota_update`, plus the Nordic legacy DFU service
  `258EAFA5-E914-47DA-95CA-C5AB0DC85B11` in the binary and a separate CRC-CCITT (`0x1021`) routine at
  `0x100111b14` for firmware images.
- **NFC pods** — `40501` `tag_nfc_xid`, backed by `NFCReaderUsageDescription` in the vendor `Info.plist`.
- **Misc device** — `8005` `weight_switch_unit`, `8010` `device_temperature`, `8015` `device_unit_change`,
  `8103` `device_light_brightness`, `8007` `in_brewer_page`, `8003` `in_scale_page`, `8014` `out_scale_page`,
  `40515` `brewer_start_stop`, `40516` `brewer_stop_start`.

Note `40516`: PyBloom documents it as `confirm_next()` ("confirm/advance next step"). The vendor calls it
`brewer_stop_start`. These are not obviously the same thing.

## Complete vendor command table (confirmed)

101 entries, sorted by ID. Direction (app→device vs device→app) is **not** encoded in the enum; the
vendor mixes both. Direction assignments below are **inferred** from name and from PyBloom's split.

| ID | Hex | Vendor name | ID | Hex | Vendor name |
|---:|---|---|---:|---|---|
| 2500 | `0x09C4` | `spindlemove_left` | 8500 | `0x2134` | `weight_cleared` |
| 2501 | `0x09C5` | `spindlemove_right` | 9000 | `0x2328` | `device_in_grinder` |
| 3500 | `0x0DAC` | `grind_adjust` | 9001 | `0x2329` | `device_in_brewer` |
| 3502 | `0x0DAE` | `grind_zero` | 9002 | `0x232A` | `device_in_scale` |
| 3503 | `0x0DAF` | `grind_begin` | 9003 | `0x232B` | `device_begin_grinder` |
| 3505 | `0x0DB1` | `grind_end` | 9004 | `0x232C` | `device_out_grinder` |
| 4503 | `0x1197` | `brewer_stop_rotation` | 9005 | `0x232D` | `device_begin_brewer` |
| 4504 | `0x1198` | `brewer_circular` | 9006 | `0x232E` | `device_out_brewer` |
| 4505 | `0x1199` | `brewer_spiral` | 9008 | `0x2330` | `device_out_scale` |
| 4506 | `0x119A` | `brewer_begin` | 9009 | `0x2331` | `device_grinder_pass` |
| 4507 | `0x119B` | `brewer_stop` | 9010 | `0x2332` | `device_brewer_pass` |
| 4508 | `0x119C` | `brewer_water_source` | 9011 | `0x2333` | `device_tea_unpass` |
| 4510 | `0x119E` | `brewer_temperature` | 9012 | `0x2334` | `device_tea_wait` |
| 4512 | `0x11A0` | `tearecipe_marking` | 10507 | `0x290B` | `weight_current` |
| 4513 | `0x11A1` | `tearecipe_send_cmd` | 11506 | `0x2CF2` | `device_read_pour_radius` |
| 8001 | `0x1F41` | `recipe_send_cmd` | 11507 | `0x2CF3` | `device_write_pour_radius` |
| 8002 | `0x1F42` | `recipe_marking` | 11508 | `0x2CF4` | `device_read_shake_pps` |
| 8003 | `0x1F43` | `in_scale_page` | 11509 | `0x2CF5` | `device_write_shake_pps` |
| 8004 | `0x1F44` | `recipe_send_cmd_nogrinder` | 11510 | `0x2CF6` | `easymode_recipe_send` |
| 8005 | `0x1F45` | `weight_switch_unit` | 11511 | `0x2CF7` | `easymode_type` |
| 8006 | `0x1F46` | `in_grinder_page` | 11512 | `0x2CF8` | `easymode_recipe_order` |
| 8007 | `0x1F47` | `in_brewer_page` | 11518 | `0x2CFE` | `device_easymode_change` |
| 8008 | `0x1F48` | `device_nosleep` | 20501 | `0x5015` | `weight_realTime` |
| 8009 | `0x1F49` | `device_into_sleep` | 40501 | `0x9E35` | `tag_nfc_xid` |
| 8010 | `0x1F4A` | `device_temperature` | 40502 | `0x9E36` | `brewer_start` |
| 8011 | `0x1F4B` | `device_wakeup_sleep` | 40503 | `0x9E37` | `spindle_moving_left` |
| 8012 | `0x1F4C` | `out_grinder_page` | 40504 | `0x9E38` | `spindle_moving_lstop` |
| 8013 | `0x1F4D` | `out_brewer_page` | 40505 | `0x9E39` | `device_gears` |
| 8014 | `0x1F4E` | `out_scale_page` | 40506 | `0x9E3A` | `grinder_doing` |
| 8015 | `0x1F4F` | `device_unit_change` | 40507 | `0x9E3B` | `device_grinder_finish` |
| 8016 | `0x1F50` | `brewer_pour_mode` | 40508 | `0x9E3C` | `spindle_moving_right` |
| 8017 | `0x1F51` | `recipe_marking_cancel` | 40509 | `0x9E3D` | `spindle_moving_rstop` |
| 8018 | `0x1F52` | `grind_pause` | 40510 | `0x9E3E` | `watering_phase` |
| 8019 | `0x1F53` | `brewer_pause` | 40511 | `0x9E3F` | `device_watering_finish` |
| 8020 | `0x1F54` | `grind_restart` | 40512 | `0x9E40` | `takecup_yerno` |
| 8021 | `0x1F55` | `brewer_restart` | 40513 | `0x9E41` | `brewer_finish` |
| 8022 | `0x1F56` | `device_backto_home` | 40514 | `0x9E42` | `device_sleep` |
| 8023 | `0x1F57` | `device_current_page` | 40515 | `0x9E43` | `brewer_start_stop` |
| 8100 | `0x1FA4` | `device_mtu_negotiate` | 40516 | `0x9E44` | `brewer_stop_start` |
| 8101 | `0x1FA5` | `device_ota_update` | 40517 | `0x9E45` | `grinder_empty_abnormal` |
| 8102 | `0x1FA6` | `recipe_bypass` | 40518 | `0x9E46` | `brew_flow_pause` |
| 8103 | `0x1FA7` | `device_light_brightness` | 40519 | `0x9E47` | `brew_flow_stop` |
| 8104 | `0x1FA8` | `device_pod_type` | 40520 | `0x9E48` | `bypass_begin` |
| 8105 | `0x1FA9` | `device_grinder_size` | 40521 | `0x9E49` | `device_sync_info` |
| 8106 | `0x1FAA` | `device_grinder_speed` | 40522 | `0x9E4A` | `watertank_volume_low` |
| 8107 | `0x1FAB` | `device_brewer_mode` | 40523 | `0x9E4B` | `brewer_volume` |
| 8108 | `0x1FAC` | `device_brewer_temputer` | 40524 | `0x9E4C` | `brew_flow_resume` |
| 8111 | `0x1FAF` | `device_easymode_begin` | 40525 | `0x9E4D` | `easymode_recipe_num` |
| 8113 | `0x1FB1` | `tea_change_waittime` | 40526 | `0x9E4E` | `gear_reset_zero` |
| | | | 40527 | `0x9E4F` | `pour_first_vibration_before` |
| | | | 50038 | `0xC376` | `gear_start_reset_zero` |
| | | | 50039 | `0xC377` | `gear_resetting_zero` |

## Other vendor details worth knowing

- **Cup types.** The vendor enum is `xPod, xDripper, Other, Tea`. PyBloom's docs claim `X_DRIPPER` "does not
  exist" — that is a PyBloom-side naming problem, not a protocol fact. A second vendor enum combines cup and
  pattern: `xPod, xDripper, Other, center, spiral, circular`.
- **Two machine generations.** The binary distinguishes `J15` and `J20` throughout (separate view
  controllers, separate `DeviceDocumentData.json` / `DeviceDocumentDataJ20.json`, separate progress state
  machines). This project models one machine. If your hardware is J20, some J15 paths may not apply.
- **Not just BLE.** The official app also runs WebSocket (`Starscream`), AWS Cognito/S3, and an HTTP recipe
  API. Machine state can arrive over the network as well as over Bluetooth — `wssConnectChange`,
  `isOnline`, `requestShadow` appear in a device-state enum. A machine reachable only over BLE may behave
  differently from one the vendor app has also bound to the cloud.
- **Connection resets.** This app's `finishConnectionSetup()` sends `recipeStop` → `brewerQuit` →
  `grinderQuit` on connect, matching PyBloom. The vendor's connect path was not disassembled far enough to
  confirm whether it does the same. **Unverified.**

## Recommended follow-ups, in order

1. Drop `scaleVibrate`/`scaleStop` from `testConnection()` and probe with `device_current_page = 8023` or
   `device_sync_info = 40521` instead. Removes an unverified opcode from the one code path whose whole job
   is to tell you whether the link works.
2. Remove `8203`/`8204` from `XBloomNotification` and from `parseNotification`'s `.error` branch, or mark
   them explicitly as unverified. They cannot fire.
3. Re-check the `.idle` mappings for `40507` and `40511`. Both are "finished a stage", not "machine idle".
4. Rename `9009`/`9010` to `grinderPass`/`brewerPass` and re-derive the `.paused` mapping from your own
   `MachineTrafficLog` recordings rather than from the PyBloom names.
5. Send `device_nosleep = 8008` after connect, and delete the "keep the machine awake" user-facing advice.
6. Stop subscribing to FFE3, or keep the subscription but route it to the traffic log only — never into
   `telemetry`.
7. Consider `brew_flow_pause = 40518` / `brew_flow_resume = 40524` as a real pause/resume feature.
