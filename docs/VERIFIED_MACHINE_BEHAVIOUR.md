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
  **100 ml @ 91 °C**; grind size 42; legacy footer 240 (later proved to
  be the wrong encoding; see 18).
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
1 s apart instead of 300 ms, and preventing the then-misidentified footer from
wrapping. Which of them mattered, if any, is **not established**; the failure was
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

**The recipe footer.** The vendor's recipe totals 165 ml, carries a 22 g dose in
`8102`, and ends in byte **75**. This is exact protocol evidence for ratio in
tenths: `165 / 22 * 10 = 75`. PyBloom's `total_water` name was misleading, and
this app inherited it by writing the poured volume instead. The encoder now
writes `round(recipe ratio × 10)`; for the failed 150 ml / 16 g diagnostic that
changes the byte from 150 to 94.

### 19. Pause is byte-for-byte correct

```
official  58 01 01 46 9E 0C 00 00 00 01 80 A1   (40518, sent on pause)
official  58 01 01 47 9E 0C 00 00 00 01 55 3E   (40519, sent on stop)
```

Identical to what this app now emits for both.

## The vendor's frames, in full — 2026-08-22 13:00, PacketLogger

A second HCI trace, this time reaching the bytes. Every frame below is the
official app's own write.

```
8100  58 01 01 a4 1f 14 …  (185, 1)              once, on connect
8102  58 01 01 a6 1f 18 …  (0, 0, 22)            dose 22 g — same shape as ours
8104  58 01 01 a8 1f 14 …  (200.0, 80.0)         ← ours sent (90.0, 40.0)
8001  58 01 01 41 1f 2f …  recipe                same encoding as ours
8002  58 01 01 42 1f 0c …  bare
40518 58 01 01 46 9e 0c …  pause                 identical to ours
40524 58 01 01 4c 9e 0c …  resume                identical to ours
40519 58 01 01 47 9e 0c …  stop                  identical to ours
```

### 20. `8104` is why a grinding recipe never ground

Both floats were invented here. The vendor sends **200.0 and 80.0**; this app
sent 90.0 and 40.0 — telling a machine about to pour 168 ml that the cup tops
out at 90. The burr never moved. A grinder-off recipe keeps the pair this
machine has already been recorded brewing with.

### 21. The grinder screen used three commands the vendor never sends

```
8006  58 01 01 46 1f 14 …  (size, speed)     opens the screen *with* the setting
8006  58 01 01 46 1f 14 …  (53, 100)         re-sent whenever the size changes
3500  58 01 01 ac 0d 18 …  (1000, size, speed)   ← starts the burrs
8018  58 01 01 52 1f 0c …  bare                  ← stops them
3505  58 01 01 b1 0d 0c …  bare                  ← leaves the screen
```

`8105 device_grinder_size`, `8106 device_grinder_speed` and `3503 grind_begin`
— the three this app was built on — do not appear once. `8006` is not a bare
page-open: it carries the setting. Every `device_gears` frame follows `3500`,
so that is the start.

Confirmed on hardware 2026-08-22: the grinder screen runs, and the machine's
own display shows the grind size and the speed the app sent. The second value
in `8006` and the third in `3500` are therefore the speed, which was inferred
from the capture and is now read back off the machine.

The leading `1000` in `3500` is still copied as captured and its meaning is not
established. The amount ground has not been weighed.

### 22. `8100` is the pairing handshake

The vendor's app opens with `8100 (185, 1)` before anything else, and the
machine shows itself as paired afterwards. This app never sent it, which is the
difference visible on the machine's own display.

### 23. A grinding recipe works, and the empty grinder ends it

Confirmed on hardware 2026-08-22 10:19 with the corrected `8104`: the machine
grinds before the pours. With no beans in it:

```
11.14  40506  grinder_doing
15.38  40517  grinder_empty_abnormal
15.49  40507  device_grinder_finish
15.64   8023  page 15                ← its own alert screen
```

The machine gives up on its own — it reports the fault, finishes the grind and
leaves the brewing screen. There is nothing for the app to stop, so the session
ends rather than sitting there offering Pause and Stop for a brew that is over.

The fault also has to be dismissible. It arrives once and `errorCommand` never
changes again until the next brew, so clearing the alert and then reading the
same value on the next telemetry frame put it straight back on screen.

### 24. The vendor sends nothing else on connect

```
15.381  8100  (185, 1)
15.480  8100  echo
15.616  8011  device_wakeup_sleep     ← the machine, unprompted
16.059  8023  page 29
16.103 40521  device_sync_info        "J15B01G634033 … V12.0D.500"
```

Then silence until the brew. This app followed `8100` with a stop and two page
exits over the top of the machine's own pairing announcement. It now mirrors
the vendor connection: await the `8100` echo, let the machine return home, and
send no unsolicited stop or page-exit commands.

### 25. Leaving the grinder takes two commands, not one

Captured from the vendor's app on 2026-08-22:

```
APP →   3500  grind_adjust  (1000, 15, 100)
←       8023  page 34                        grinding
←      40506  grinder_doing
APP →   8018  grind_pause                    the user stops it
←      40507  device_grinder_finish
←       8023  page 2
APP →   3505  grind_end
←      40507  device_grinder_finish
APP →   8012  out_grinder_page
←       8023  page 1                         ← home
```

`3505` ends the grind; **`8012` is what sends the machine home**. This app sent
only `3505`, so the phone left the screen and the machine stayed on its
grinding page. Both go now, and walking away from a running grinder stops it
first — pause, end, leave, in that order.

Screens seen so far: **1** home, **2** after a grind ends, **15** the fault
alert, **34** grinding, **35** brewing, **29–31** around a brew starting.

### 26. The machine changes screens constantly, so a screen change is not the end

2026-08-22 12:43, pressing pause mid-pour:

```
 7.89   8023  page 35        brewing
 8.50  40510  watering_phase 0
12.27  40518  pause sent
12.70  40515  brewer_start_stop
13.09   8023  page 31        ← the machine's paused screen
13.10   note  App ended the session
```

The backstop treated any change away from the recorded brewing screen as the
end of the recipe. Watched properly, this machine moves screens all the time:
**30** and **34** while it grinds, **2** after a grind, **15** on a fault, and
**31** the instant a brew pauses. Only **1**, home, has ever been seen at the
end of one — and only for a brew stopped by hand, since a natural finish sends
`take_cup` and needs no backstop at all.

### 27. A correct grinding recipe was refused

Same recording. Everything the app sent matches the run that ground an hour
earlier: `8001`, cup `(200.0, 80.0)`, dose 16, grind size 36, RPM 90 in the
first pour's seventh byte, the four setup commands a second apart.

```
worked 10:19   brewer_start → page 30 → page 34 → grinder_doing
failed 12:43   brewer_start → page 35 → watering_phase
```

The machine picked its no-grind program within 400 ms of accepting the recipe.
The later 13:43 diagnostic reproduced it and exposed a remaining bad field—the
strongest protocol-level cause found so far:
the app sent footer 150 for a 150 ml / 16 g recipe, while the vendor's formula
requires ratio byte 94. The command opcode, dose, cup pair, RPM, grind size and
one-second cadence were otherwise correct.

An attempted safety gate treated page 35 as proof that grinding had been
skipped and immediately sent `40519`. That was wrong: a page report is not
strong enough evidence to cancel a physical program, and it caused Start Brew
to stop the machine itself. The replacement interlock ignores page 35. It sends
`40519` only if the machine emits an actual `40510 watering_phase` before any
page-34, gear, or grinder evidence. This limits wasted water without cancelling
a program merely because its display changed.

## Two more PacketLogger traces — 2026-08-22 12:59 and 13:36

`~/22.08.2026 12.59.09 PM.pklg` (644 frames, the vendor's app) and
`~/22.08.2026 1.36.15 PM.pklg` (27 197 frames, ~3 hours of this app).

### 28. A grind starts several seconds after the command is acknowledged

The burr carrier has to travel to the setting first, and every step of it is on
the wire:

```
10541.241 APP→  3500  grind_adjust (1000, 50, 80)
10541.645 ←     3500  echo → 56                 ← the CURRENT gear position
10541.848 ←    40505  device_gears 57
   …                  one frame per ~200 ms, 57 … 79
10546.573 ←    40526  gear_reset_zero 80
10547.115 ←     8023  page 34
10547.181 ←    40506  grinder_doing             ← the burrs are turning NOW
```

**5.5 seconds** between the acknowledgement and any coffee being ground, for a
24-step move. A move of one or two steps takes under a second — the vendor's own
capture walks 81 → 83 and grinds 0.9 s after the command.

So `3500` being acknowledged means *accepted*, not *grinding*. The echo's
payload is the position the carrier is starting from; `40505` counts it toward
a reference (80 in both traces, whether it started at 57 or 92), `40526` zeroes
it there, and `40506 grinder_doing` is the only frame that means the grind has
begun. The app timed from the acknowledgement, so a 2 s grind read as 8 s.

### 28a. The gear stream *is* the dial, offset by thirty

The gear numbers looked unrelated to grind size until the endpoints were lined
up. Every travel ends at **the requested size plus 30**:

| Trace | Size asked for | Travel | `gear_reset_zero` |
|---|---:|---|---:|
| 13:36 | 50 | 57 → 79 | **80** |
| 12:59 | 53 | 82 | **83** |
| vendor recipe (finding 14) | 51 | 92 → 82 | **81** |

So a `device_gears` frame is the dial position the burrs are passing through,
`gear + 30`. The app reads them back with `XBloomProtocol.grindSize(atGear:)`
and draws the real position on the grind-size dial as a second, grey bar, which
moves because the machine moved. Readings outside 31–110 are refused rather
than painted, since nothing has been recorded outside that span.

The `3500` echo and `40526 gear_reset_zero` carry positions in the same units —
the first the travel's start, the second its end — and are parsed alongside
`40505`.

### 29. Nothing on the wire carries the machine's clock

`40515 brewer_start_stop` arrives on every pause with a four-byte payload, which
looked like a candidate. It is the scale:

```
11092.932  40515  98 6e a6 40  → 5.201   scale reads 5.201 g
11224.514  40515  b1 72 94 40  → 4.639   scale reads 4.639 g
```

Both match the `20501` reading of the same instant exactly. There is no timer
frame in 27 197 frames, so the app's clock can only be anchored on a machine
*event*. The one it uses is the machine reaching its brewing screen — page 35,
which on a grinding recipe comes after pages 30 and 34, i.e. after the grind.

### 30. The stop-on-page-35 gate is visible in this trace, doing harm

```
10483.999  ←   8023  page 35
10484.027  APP→ 40519 stop          ← 28 ms later
10484.584  ←  40510  watering_phase 0
```

Three brews in a row are cancelled by the app within 30 ms of the page report.
This is the interlock defect finding 27 describes, recorded from the outside.

## Still unverified

- Whether the corrected ratio footer is sufficient to make every grinder-on
  recipe choose the grinding branch. This needs one attended hardware brew.
- Whether `40511 device_watering_finish` appears on any firmware. It did not
  here, so the end of a pour is inferred from the volume counter going still.
- `device_pod_type` (8104) payload shape. The app sends two float32 cup weights;
  the vendor treats this as a pod/cup type.
- `8023` page numbers beyond 35 (brewing) and 1 (home).
- Whether any firmware omits all page-34, gear, and grinder notifications after
  physically grinding; the captured successful run reported them.
- **What the machine's own display counts from on a grinding recipe.** Nothing
  on the wire says. The app now starts its brew clock when the machine reaches
  page 35, which excludes the grind; if the machine's display turns out to
  include it, the anchor moves back to `recipeAcceptedAt`.

## How to add to this document

Record another brew from **Settings → Machine diagnostics**, then compare the
identifiers, their payloads, and their timing against the tables above. A claim
belongs here only once a recording shows it.
