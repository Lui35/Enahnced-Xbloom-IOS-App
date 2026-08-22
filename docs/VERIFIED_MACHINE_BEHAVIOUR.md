# Verified Machine Behaviour — XBLOOM 634033

Everything here was read out of a full Bluetooth recording of a real brew on the
owner's machine, captured with **Settings → Machine diagnostics**. It takes
precedence over both `PYBLOOM_BLUETOOTH_API.md` (reverse-engineered from another
project) and `OFFICIAL_APP_BLE_COMPARISON.md` (name table extracted from the
vendor binary), because it is the only source describing *this* machine.

## The recording

- Recipe: **Chelchele Berry Sweetness**, grinder **off**, 3 pours, 240 ml,
  15 g dose.
- Recipe payload actually sent: pours of **45 ml @ 93 °C**, **95 ml @ 92 °C**,
  **100 ml @ 91 °C**; grind size 42; water footer 240.
- 1088 frames over 118 s. The brew was stopped by hand during the rest after
  pour 2.

## What this machine sends

| ID | Vendor name | Frequency | Payload meaning |
|---:|---|---|---|
| 40523 | `brewer_volume` | ~5 Hz, continuous | float32, **microlitres** poured |
| 20501 | `weight_realTime` | ~5 Hz, continuous | float32 grams on the scale |
| 40502 | `brewer_start` | once | recipe accepted |
| 8023 | `device_current_page` | on screen change | uint32 screen id |
| 40510 | `watering_phase` | once per pour | uint32 **zero-based pour index** |
| 40522 | `watertank_volume_low` | once, mid-brew | uint32 level; `0` seen while brewing normally |
| 8108 | `device_brewer_temputer` | **never** | not sent by this machine at all |
| 8102 / 8104 / 8004 / 8002 / 40519 | command echoes | once each | acknowledgement of what the app sent |

## Findings that changed the app

### 1. Poured volume is in microlitres

The counter plateaued at exactly **45000** after the bloom and **140000** after
the second pour — the recipe's 45 ml and 45 + 95 ml. Consecutive readings 0.28 s
apart differ by 775, which is 2.77 ml/s against a requested 3.0 ml/s flow.

```
13.34  40523  00 C0 C1 43   ->      387.5 µl  =   0.3875 ml
28.15  40523  00 C8 2F 47   ->    45000.0 µl  =  45.0    ml   (pour 1 complete)
99.45  40523  00 B8 08 48   ->   140000.0 µl  = 140.0    ml   (pours 1 + 2)
```

The app previously divided the counter by ten until it fell below 750, turning
the 45 ml bloom into **450 ml**. Against a 240 ml recipe that is past the final
pour, and because the live figures only ever climb, the display latched there.
That single misreading is the "zero to the last pour in a few seconds" defect.

### 2. `watering_phase` (40510) carries the pour index

This is the reliable pour signal, and it is exact:

```
12.98  40510  00 00 00 00   -> pour 0 starting  (bloom)
69.43  40510  01 00 00 00   -> pour 1 starting
```

The vendor calls 40510 `watering_phase`, not `bloom` — it is generic, one per
pour. Extraction begins at the first of these, which is also where the chart's
time axis now starts.

### 3. None of the reference's stage events exist here

`9000`–`9010`, `40507`, `40511`, `40512`, `40513` — dripper position, grinder
begin/finish, brewer begin, brewer stop, enjoy — **none appeared**. Any logic
built on them silently never ran, which is why the phase sat on "Heating water"
through pours that had already started.

This was a grinder-off brew, so the grinder events may yet appear with the
grinder on. That still needs a capture.

### 4. There is no completion event

The machine never announced that it had finished. The only end-of-recipe signal
is `device_current_page` changing away from the brewing screen:

```
 12.39  8023  23 00 00 00   -> page 35  (brewing)
109.32  8023  01 00 00 00   -> page 1   (home)
```

The app records the page seen just after the recipe is accepted and treats a
later change away from it as completion. A time-based backstop covers firmware
that does not report its screen either.

### 5. `watertank_volume_low` (40522) is not always a fault

It arrived once at t=72.5 s with a zero payload while the machine carried on
pouring normally for another 36 s. Treating it as an error raised a false
"machine needs attention" alert mid-brew. Only a non-zero payload is now a
fault.

### 6. The machine never reports water temperature

`8108 device_brewer_temputer` did not appear once in 1088 frames. The only
measurements this machine streams are poured volume and scale weight.

The app used to render a missing temperature as the word "Heating…", which reads
as a live machine state rather than as an absent one — so "heating" stayed on
screen through every pour to the end of the brew. The temperature row now shows
the running pour's target from the recipe, labelled "Recipe target · no live
reading", and only shows a number as a measurement when one actually arrives.

### 7. The grinder-off recipe did start

`8004 recipe_send_cmd_nogrinder` was acknowledged and the machine brewed. This
capture was taken after three changes that were made on suspicion — sending the
real dose with `recipe_bypass` instead of zero, spacing all four setup commands
1 s apart instead of 300 ms, and clamping the water footer instead of letting it
wrap. Which of them mattered, if any, is **not established**; the failure was
intermittent and has not been reproduced since.

### 8. A brew started from the weighing sheet did not grind

Reported from a real session, not read out of a capture: weighing a dose, tapping
through to the brew, and watching the machine pour water without grinding first.
The recipe had the grinder on, and the payload for it is correct — `8001` with a
non-zero grind size and RPM, which the protocol tests cover.

What was different about that path is the scale screen. The weighing sheet opens
it with `8003` and used to give it back from `onDisappear`, which is unordered
with respect to the brew starting. With a second between each setup command, the
`8014 out_scale_page` landed **inside** the `8102 → 8104 → 8001 → 8002`
sequence — the machine was told to leave the scale halfway through being handed
a recipe.

The app now releases every screen it holds before the first setup command and
waits a second afterwards, the same gap the sequence itself uses. That the page
exit is what cost the grind is **inferred, not captured**; what is certain is
that an unrelated command no longer arrives in the middle of a recipe upload.

## Direct machine tools — what each one rests on

The Scale, Brewer, and Grinder screens reach the machine by different routes,
and they are not equally trustworthy.

| Screen | Commands | Standing |
|---|---|---|
| Brewer (single pour) | `8102` → `8104` → `8004` → `8002`, stop `40519` | **Verified.** Identical to the captured brew, with one pour instead of three. |
| Scale | `8003 in_scale_page`, `8500 weight_cleared`, `8014 out_scale_page` | Command IDs confirmed in the vendor table; payloads are empty, so there is little to get wrong. Live weight via `20501` is verified. |
| Grinder | `8006`, `8105 size`, `8106 speed`, `3503 begin`, `3505 end`, `8012` | **Unverified payloads.** IDs confirmed in the vendor table; the argument encoding is a guess (single little-endian uint32, matching `recipe_bypass`). |

Because of that gap, every scale and grinder control waits for the machine to
echo the command back — the acknowledgement pattern seen throughout the capture,
where `8102`, `8104`, `8004`, `8002`, and `40519` each came back with the same
identifier and an empty payload. A control that is sent but never acknowledged
says so rather than pretending to have worked.

The Brewer screen deliberately does **not** use the vendor's direct brewer
opcodes (`4506 brewer_begin`, `4510 brewer_temperature`, `4504`/`4505` pattern).
They would open a valve on near-boiling water with a payload shape nobody has
confirmed. The single-pour recipe carries the same four settings down a path the
machine has already demonstrably understood.

`40506 grinder_doing` and `40505 device_gears` are parsed and displayed raw. Their
units are unknown, so neither is presented as grams.

## Second recording — 2026-08-21, iced, grinder off

Recipe: **Chelchele Berry & Cream Iced Brew**, grinder off, 3 pours, 168 ml,
16 g dose. 1255 frames over 138 s, brewed to completion.

Three things in it contradict the first recording, and one confirms it.

### 9. The scale measures the cup, and it is good

`20501 weight_realTime` is not a dead stream. It tracked the cup from 0 g to
**155.8 g** across the three pours, holding steady at 36.9 g through the bloom
rest and 101.6 g through the second. This is a real yield curve.

Two hazards in it:

- It **drops to exactly 0.0** several times during the first pour — at 19.18,
  20.94 — between readings that are climbing normally. Last zero is 20.94; it
  never does it again.
- A hand resting on the machine reads **3471.9 g for four frames** (125.16 to
  125.77) and then returns. Anything that latches on the maximum keeps that
  number forever.

The app reads it as the lowest value in a 1.6 s trailing window, which ignores
both.

### 10. `device_watering_finish` and `take_cup` do exist

The first recording was stopped by hand, so the end of the recipe was never
seen. Brewed to completion, this machine sends both:

```
122.80  40511  device_watering_finish
131.06  40512  take_cup
135.50   8023  page 36
```

`take_cup` is a real completion event. The page-change backstop is no longer
the only end-of-recipe signal, though it still covers a brew that is stopped
early.

### 11. `pour_first_vibration_before` (40527) marks the machine getting to work

```
  6.45  40502  brewer_start
  7.45  40527  pour_first_vibration_before
 14.45  40510  watering_phase 0
```

One second after accepting the recipe and seven seconds before the first pour.
On a grinding recipe it can only come after the grinder has stopped, so the
brew clock starts here.

### 12. Still no temperature, still no heating

`8108` did not appear in these 1255 frames either. Two recordings, 2343 frames,
zero temperature readings. The heating phase is gone from the app.

## What a real grind looks like — 2026-08-22, official app

Captured by leaving this app connected and recording in the background while
the brew was started from the vendor's own app. Only its *echoes* are visible,
never its payloads, but the echoes carry the identifiers.

### 13. The official app sends the same four commands, in the same order

```
13.44  8102  recipe_bypass       echo
13.85  8104  device_pod_type     echo
14.25  8001  recipe_send_cmd     echo   ← the grinding opcode, same as ours
15.42  8002  recipe_marking      echo
15.44 40502  brewer_start
```

So the opcode is not the difference, and neither is the order or the count.
Whatever makes the machine grind is **inside the payload bytes**, which an
echo does not carry.

One visible difference: its four setup commands are ~0.4 s apart. This app
waits a full second between them.

### 14. Grinding announces itself loudly, and we have never seen any of it

```
15.58 40505  device_gears  92     ← burr carrier moving, one frame per step
15.83 40505  device_gears  91
 ...                       ...    counting down to 82
17.90 40526  gear_reset_zero  81
18.52  8023  device_current_page  34
18.57 40506  grinder_doing
19.43 40507  device_grinder_finish
```

The machine walks the burr gear to the recipe's setting, zeroes it, switches to
screen 34, grinds, and reports finishing. **Not one `40505` has appeared in any
recording of a brew this app started** — it never begins positioning the
grinder at all.

Screens also differ: a brew from the official app sits on 31, 30, then 34 while
grinding. A brew from this app goes to 35 and pours.

### 15. `40518 brew_flow_pause` is real

It arrived mid-brew when the recipe was paused from the official app. The
vendor's table pairs it with `40524 brew_flow_resume`. Both are now sent by
this app.

### 16. The prime suspect is `8104 device_pod_type`

The vendor calls it *pod type*. This app sends two float32 cup weights into it
(90.0, and 40.0 or 0.0 depending on the grinder switch), which was always a
guess — it sits under "Still unverified" below. A machine told the coffee is
already ground has no reason to move a burr, whatever the recipe opcode says.
Its real payload is one of the three still missing.

## The official app's own frames — 2026-08-22, PacketLogger

An HCI trace of the vendor's app running a grinding recipe, captured with the
Bluetooth logging profile. These are its real writes, not echoes.

### 17. The recipe encoding is right

```
official  58 01 01 41 1F 2F 00 00 00 01 | 20 [32B body] 33 4B | ED C1
ours      58 01 01 41 1F 27 00 00 00 01 | 18 [24B body] 26 AA | 2F 8E
```

Same opcode, same shape: a length byte, 8-byte pour blocks, then grind size,
then one footer byte. Decoding its body against this app's own reader gives
four clean pours — 40 ml/90 °C/spiral/30 s rest, RPM 60 in the first pour's
seventh byte, flow 3.0 — and grind size 51. Every field lands where this app
puts it. The pour encoding, the RPM slot, the negative pause byte and the grind
size are now verified against the vendor rather than inferred from PyBloom.

### 18. Two fields do not match, and one of them is why nothing grinds

**`8104 device_pod_type`.** The vendor sends `00 00 48 43` as its first
float32 — **200.0**. This app sends 90.0, with a second float of 40.0 or 0.0
depending on the grinder switch. Those numbers were invented; the vendor's name
for the command is *pod type*, and a machine told what kind of coffee is loaded
is exactly what would decide whether a burr needs to turn.

**The recipe footer.** The vendor's recipe totals 165 ml and its footer byte is
**75**. This app writes `round(total/10)*10`, which for a 168 ml recipe is 170.
75 is not 165, nor 165/10, nor anything derived from it — but 240 − 165 = 75,
and the vendor's editor has a bypass control (`addBypassLabel`,
`bypassInfoView`). The footer is more likely **bypass water** than total water,
which would mean this app has been asking for 170 ml of bypass on every brew.

Both need the untruncated frames to settle.

### 19. Pause is byte-for-byte correct

```
official  58 01 01 46 9E 0C 00 00 00 01 80 A1   (40518, sent on pause)
official  58 01 01 47 9E 0C 00 00 00 01 55 3E   (40519, sent on stop)
```

Identical to what this app now emits for both.

## Still unverified

- Grinder-on behaviour. Needs a capture with the grinder enabled — and that
  capture is now the way to settle whether the scale-page exit was what skipped
  the grind (see 8 above).
- Whether `40511 device_watering_finish` appears on any firmware. It did not
  here, so the end of a pour is inferred from the volume counter going still.
- `device_pod_type` (8104) payload shape. The app sends two float32 cup weights;
  the vendor treats this as a pod/cup type.
- `8023` page numbers beyond 35 (brewing) and 1 (home).
- Whether the `recipeStop` → `brewerQuit` → `grinderQuit` sequence the app sends
  on connect matches what the vendor does.

## How to add to this document

Record another brew from **Settings → Machine diagnostics**, then compare the
identifiers, their payloads, and their timing against the tables above. A claim
belongs here only once a recording shows it.
