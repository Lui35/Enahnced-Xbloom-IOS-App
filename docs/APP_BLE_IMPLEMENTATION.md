# What This App Sends — Brew, Grinder, Scale, and Beans

The other three documents in `docs/` describe *sources*: PyBloom's reverse
engineering, the vendor binary's command table, and the traffic recordings from
this machine. This one describes *this app*: the exact commands it writes, in
what order, on which screen, and what it does with the answers.

Precedence when they disagree: `VERIFIED_MACHINE_BEHAVIOUR.md` wins on what the
machine does, this document wins on what the app does, and the other two are
background.

Every claim here is checked against the code it names. Where the app rests on
something no recording has confirmed, it says so.

## Contents

1. [Transport](#1-transport)
2. [Connecting](#2-connecting)
3. [Screen ownership — the rule everything else obeys](#3-screen-ownership--the-rule-everything-else-obeys)
4. [Before the brew: weighing the dose](#4-before-the-brew-weighing-the-dose)
5. [Before the brew: the grinder screen](#5-before-the-brew-the-grinder-screen)
6. [Before the brew: the scale and manual pour screens](#6-before-the-brew-the-scale-and-manual-pour-screens)
7. [Starting a brew — the path both modes share](#7-starting-a-brew--the-path-both-modes-share)
8. [Brewing **with** the grinder](#8-brewing-with-the-grinder)
9. [Brewing **without** the grinder](#9-brewing-without-the-grinder)
10. [Reading a running brew](#10-reading-a-running-brew)
11. [Pause, resume, stop, finish](#11-pause-resume-stop-finish)
12. [Faults](#12-faults)
13. [Where the beans go — dose accounting](#13-where-the-beans-go--dose-accounting)
14. [Known gaps](#14-known-gaps)

---

## 1. Transport

| | |
|---|---|
| Service | `0000e0ff-3c17-d293-8e48-14fe2e4da212` |
| Write | `0000ffe1-…` — write **without response** only |
| Notify | `0000ffe2-…` — the status channel, the only one that drives state |
| Notify (aux) | `0000ffe3-…` — subscribed and logged, **never merged** |

Frame: `58 <deviceID> <typeCode> <cmd:u16le> <length:u32le> 01 <payload…> <crc16:u16le>`,
`length = 12 + payload bytes`, CRC-16/X.25 over everything before it
([XBloomProtocol.swift:127](Sources/XBloomCore/XBloomProtocol.swift:127)).

Notifications arrive fragmented and are reassembled per characteristic by
`XBloomNotificationFramer`. A frame that fails CRC is logged as `unparsed`
rather than dropped silently — those are the frames the references get wrong.

The vendor's own app filters FFE3 out of its receive path, so this app records
it for diagnostics and refuses to let it move brew state
([XBloomBLEClient.swift:573](XBloomApp/Services/XBloomBLEClient.swift:573)).

## 2. Connecting

Discovery accepts a peripheral whose advertised name starts with `XBLOOM` or
that advertises the service UUID; the identifier is remembered in
`UserDefaults` and reconnected directly next time.

Setup is a deliberate copy of the vendor's connection
([XBloomBLEClient.swift:487](XBloomApp/Services/XBloomBLEClient.swift:487)):

```
APP →  8100  mtuNegotiate (185, 1)
   ←  8100  echo                      ← awaited, 3 s timeout, connection fails without it
       (1 s)
   ←  8011  device_wakeup_sleep       the machine, unprompted
   ←  8023  page 29 → home
   ← 40521  device_sync_info
```

Then nothing. The app sends **no** unsolicited stop and **no** page exits on
connect. It used to, and those frames landed on top of the machine's own
pairing announcement.

`connect(resumingBrew: true)` skips the handshake entirely — attaching to a
recipe that is already running must not write anything at all.

## 3. Screen ownership — the rule everything else obeys

The machine hands out one subsystem at a time and only releases it when the app
leaves the screen that claimed it. `MachinePages`
([MachinePages.swift](Sources/XBloomCore/MachinePages.swift)) tracks which
screens this app currently holds — scale, grinder — and
`releaseOpenPages()` gives them all back, awaited, **before the first setup
command of a brew**, one second apart
([XBloomBLEClient.swift:292](XBloomApp/Services/XBloomBLEClient.swift:292)).

This exists because of a real failure. Released from a view's `onDisappear`,
`8014 out_scale_page` landed *inside* the `8102 → 8104 → 8001 → 8002` sequence,
and a recipe that was supposed to grind poured water over nothing. Two more
guards followed:

- `pendingScreenWork` — leaving the grinder takes two commands 400 ms apart, and
  `startBrew` awaits that task before writing anything.
- Screens are cleared on disconnect: an exit for a page the machine is no longer
  on is one more stray frame next to a recipe.

## 4. Before the brew: weighing the dose

`DoseWeighingView` — offered **only on recipes that grind**. With the grinder
off the coffee is already ground and measured and never touches the scale
([RecipesView.swift:374](XBloomApp/Views/RecipesView.swift:374)).

Two stages, deliberately separate, because the beans have to physically move
between them:

**Stage 1 — weighing.** Opens the machine's scale (`8003`), tares on demand
(`8500`), reads `20501 weight_realTime` live.

- The scale reading is *held*: lifting the container drops the live value to
  0.0 g, which used to put the dose under the machine's 5 g floor and kill the
  Continue button with the coffee already weighed. The last reading ≥ 0.5 g
  since the tare stands in.
- `DoseFit` ([DoseFit.swift](Sources/XBloomCore/DoseFit.swift)) classifies the
  weight against the recipe target: `onTarget` ±0.15 g, `close` ±1 g, then
  `short` / `thin` depending on whether the resulting ratio still falls inside
  `RecipeValidator.recommendedRatio`, or `over`. **Missing the target does not
  block the brew** — only the machine's own 5–30 g grinding range does.
- A dial allows a manual correction when the container and the scale disagree.

**Stage 2 — loading.** The confirmed weight is frozen (`confirmedDose`), and the
screen waits to see the scale fall back toward zero — the machine's own
confirmation that the beans have been lifted off it and can go into the grinder.
Nothing is written to the machine in this stage.

**Hand-off.** `handOffToBrew()` awaits `closeScale()` *before* the brew is
presented ([DoseWeighingView.swift:523](XBloomApp/Views/DoseWeighingView.swift:523)),
and the weighed figure replaces `recipe.dose` **for that brew only** — the saved
recipe keeps its own target. That one number is then what goes into `8102`, what
history records, and what comes off the bean bag.

## 5. Before the brew: the grinder screen

`GrinderView` grinds with no recipe behind it. The command set is the vendor's,
read off a capture of its app — **not** the `8105`/`8106`/`3503` trio this app
was originally built on, which the vendor never sends and which never turned a
burr:

```
8006  in_grinder_page  (size, speed)     opens the screen carrying the setting
3500  grind_adjust     (1000, size, speed)   starts the burrs
8018  grind_pause                            stops them
3505  grind_end                              ends the grind
8012  out_grinder_page                       ← what actually sends the machine home
```

Every one of these waits for the machine's echo (2 s) and reports honestly when
it does not arrive; the payload shapes for `8006` and `3500` are confirmed by
capture, but the leading `1000` in `3500` is copied verbatim and its meaning is
unknown.

**The echo is not the grind.** `3500` is acknowledged with the *current* gear
position, and the machine then walks the burr carrier one `40505 device_gears`
step every ~200 ms before it grinds anything — 5.5 s for a 24-step move in the
13:36 capture. The screen therefore shows "setting the burrs" from the
acknowledgement, and only starts its elapsed clock on `40506 grinder_doing`.

Gear readings are dial positions offset by thirty — every recorded travel ends
at the requested size + 30 (80 for size 50, 83 for 53, 81 for 51) — so
`XBloomProtocol.grindSize(atGear:)` puts the burrs' real position on both the
grind-size dial and the ring above it, as a grey fill that travels with them. The `3500` echo carries
where the travel starts and `40526 gear_reset_zero` where it ends; a reading
off the dial paints nothing. Closing the screen while a grind is running sends **pause, end, leave**
in that order ([GrinderView.swift:46](XBloomApp/Views/GrinderView.swift:46)).

`40506 grinder_doing` and `40505 device_gears` are displayed raw, never as
grams — their units have never been established.

## 6. Before the brew: the scale and manual pour screens

**Scale** (`ScaleView`): `8003` in, `8500` tare, `8014` out, live weight from
`20501`. Payloads are empty, so there is little to get wrong, and the live
weight is verified.

**Manual pour** (`ManualPourView`): a single pour, sent as a **one-step,
grinder-off recipe** rather than through the vendor's direct brewer opcodes
(`4506`, `4510`, `4504/4505`). Those exist in the command table but nobody has
confirmed their payloads, and they open a valve on near-boiling water. The
recipe path carries the same four settings down a route the machine has
demonstrably understood ([ManualPour.swift](Sources/XBloomCore/ManualPour.swift)).
It sends a fixed 15 g bypass dose, matching a capture that brewed correctly.

## 7. Starting a brew — the path both modes share

`startBrew(_:)` ([XBloomBLEClient.swift:139](XBloomApp/Services/XBloomBLEClient.swift:139)):

1. await `pendingScreenWork` — no screen change may still be in flight;
2. `RecipeValidator.requireSafe` — dose 5–30 g, grind 1–80, 1–8 pours,
   ≤ 500 ml total, per-pour 0–240 ml / 80–96 °C / 3.0–3.5 ml/s / 0–120 s pauses;
3. `releaseOpenPages()` — every held screen given back, 1 s apart;
4. the four setup commands, **1 s apart**, from `BrewCommandPlan`
   ([BrewWorkflow.swift:30](Sources/XBloomCore/BrewWorkflow.swift:30));
5. arm the grinder interlock at step 4 (grinding recipes only);
6. wait up to 10 s for a brew-side frame (`brewerStart`, `wateringPhase`,
   `grinderDoing`, `deviceGears`, …). Silence is reported as a failure — but the
   brew screen deliberately keeps watching anyway, because the execute may have
   landed while its acknowledgement was missed.

The four commands:

| # | Cmd | Payload | With grinder | Without |
|---|---|---|---|---|
| 1 | `8102 recipe_bypass` | `(f32 0, f32 0, u32 dose)` | dose in whole grams | **same** — a zero dose here looks invalid to the machine |
| 2 | `8104 device_pod_type` | `(f32, f32)` | **(200.0, 80.0)** | **(90.0, 0.0)** |
| 3 | `8001` / `8004` | recipe payload | `8001 recipe_send_cmd` | `8004 recipe_send_cmd_nogrinder` |
| 4 | `8002 recipe_marking` | bare | | |

`8104` is the field that decided everything. Both floats were invented (90.0 /
40.0) until an HCI trace of the vendor's app showed `(200.0, 80.0)`, and with
the invented pair a grinding recipe was accepted and then poured without ever
moving a burr. The grinder-off branch keeps the pair this machine has already
been recorded brewing with.

### The recipe payload

`recipePayload(for:)` ([XBloomProtocol.swift:178](Sources/XBloomCore/XBloomProtocol.swift:178)),
verified field-by-field against the vendor's own `8001` frame:

```
[body length : 1 byte]
  per pour, 8 bytes:
    0  volume ml         (chunked at 127; a larger pour becomes several blocks)
    1  temperature °C
    2  pattern           0 center · 1 circular · 2 spiral
    3  vibration         bit0 before, bit1 after
    4  pause             this pour's pauseAfter + the next pour's pauseBefore,
                         written as a NEGATIVE byte, capped at 255
    5  0
    6  RPM               first pour only, 0 in every later block
    7  flow × 10
[grind size : 1 byte]
[ratio      : 1 byte]    round(totalWater / dose × 10)
```

The last byte was the other invented field. PyBloom calls it `total_water` and
this app wrote the poured volume into it; the vendor's frame pours 165 ml on a
22 g dose and ends in **75**, which is `165 / 22 × 10`. For a 150 ml / 16 g
recipe that changes the byte from 150 to 94.

The RPM byte is what turns the burrs, so `Recipe.programRPM` substitutes 80 RPM
when a grinding recipe arrives (from an import, sync, or an AI draft) with its
speed set to off — the editor cannot produce that pairing, but the file formats
can, and grinding is the whole point of such a recipe.

## 8. Brewing **with** the grinder

Opcode `8001`, cup pair `(200.0, 80.0)`, dose and RPM as above.

What a working grind looks like on the wire — captured on hardware
2026-08-22 10:19 with the corrected `8104`:

```
   40502  brewer_start
   40505  device_gears  92, 91, 90 …      burr carrier walking to the setting
   40526  gear_reset_zero
    8023  page 34                          the grinding screen
   40506  grinder_doing
   40507  device_grinder_finish
   40527  pour_first_vibration_before      ← the brew clock starts here
   40510  watering_phase 0                 first pour
```

### The grinder interlock

A machine that takes the no-grind branch pours hot water over whole beans and
reports no error at all. `BrewGrinderInterlock`
([BrewWorkflow.swift:55](Sources/XBloomCore/BrewWorkflow.swift:55)) is armed the
moment `8002` goes out, for grinding recipes only, and it watches:

- **Grinding evidence** — `deviceGears`, `grinderDoing`, `deviceBeginGrinder`,
  `grindBegin`, `deviceGrinderFinish`, or `deviceCurrentPage == 34`.
- **The first pour** — `40510 watering_phase`. If it arrives with no grinding
  evidence behind it, the app writes `40519 recipeStop` immediately and says
  why. Otherwise the interlock disarms and never fires again.

It deliberately ignores page 35. An earlier version treated that page as proof
the grind had been skipped and stopped the machine on it — which made Start Brew
stop the machine on valid starts. A screen report is not strong enough evidence
to cancel a physical program; a `watering_phase` is.

The core type takes the decision, the BLE client only transports it
([XBloomBLEClient.swift:641](XBloomApp/Services/XBloomBLEClient.swift:641)), so
recordings can be replayed against it in tests.

### Empty grinder

With no beans in the hopper the machine gives up on its own — `40517
grinder_empty_abnormal`, `40507`, and its own alert screen (page 15). There is
nothing left to stop, so the session ends rather than offering Pause and Stop
for a brew that is over. The fault arrives exactly once and `errorCommand` never
changes again until the next brew, so it has to be dismissible: re-reading the
same value on the next telemetry frame put the alert straight back on screen.

## 9. Brewing **without** the grinder

Opcode `8004`, cup pair `(90.0, 0.0)`, the real dose still in `8102`, and the
interlock **not armed** — there is no grind to miss.

This is the best-recorded path in the project: two full recordings, 2343 frames.

```
   40502  brewer_start
   40527  pour_first_vibration_before
    8023  page 35
   40510  watering_phase 0        bloom
   40523  brewer_volume …         ~5 Hz throughout
   20501  weight_realTime …       ~5 Hz throughout
   40510  watering_phase 1
   40511  device_watering_finish
   40512  take_cup                ← the real completion event
```

No grinder events, no gears, no page 34. It is otherwise identical: same frame
format, same four setup commands, same encoding, same live telemetry.

## 10. Reading a running brew

Two continuous streams, and nothing else:

- **`40523 brewer_volume`** — float32 in **microlitres**. Divided by 1000;
  anything over 750 ml is rejected as implausible. (An earlier version divided
  by ten until the value fell below a ceiling, which turned a 45 ml bloom into
  450 ml and latched the display on the final pour.)
- **`20501 weight_realTime`** — grams on the scale, a genuine yield curve. It
  drops to exactly 0.0 for single frames during the first pour, and a hand
  resting on the machine reads 3471.9 g. The app takes the **lowest value in a
  1.6 s trailing window**, which ignores both.

The app's brew clock starts when the machine reaches its brewing screen
(page 35), falling back to `40527 pour_first_vibration_before` and then to the
first `watering_phase`. It used to start at the `8002` echo, which on a
grinder-off recipe is within a second — but a grinding recipe spends the whole
grind on pages 30 and 34 first, and the app counted all of it. No frame carries
the machine's own clock, so this anchor is the closest observable to it.

There is **no temperature**. `8108 device_brewer_temputer` has never appeared in
any recording of this machine, and the phase machine has no heating state — the
UI shows the running pour's recipe target, labelled as such.

Both streams go through trackers that turn lifetime counters into
session-relative figures: `BrewDeliveryTracker` rebases when the machine zeroes
the counter and caps each step at what the recipe's fastest pour could physically
deliver; `ScaleYieldTracker` treats the scale as an absolute measurement rather
than a monotonic counter, which is why the yield curve now moves at all.

Phase comes from `BrewProgressTracker`
([BrewProgressTracker.swift](Sources/XBloomCore/BrewProgressTracker.swift)) —
machine events only, never inferred from elapsed time. `40510 watering_phase`
carries the **zero-based pour index** in its payload and is the one reliable pour
signal; the pour index only ever clamps forward.

## 11. Pause, resume, stop, finish

| Action | Frame | Notes |
|---|---|---|
| Pause | `40518 brew_flow_pause` | Byte-identical to the vendor's. The machine moves to page 31 and answers `40515` carrying the scale reading. Paused time is subtracted from both app clocks — the machine's program is stopped, and a wall-clock delta drifts by the length of every pause. |
| Resume | `40524 brew_flow_resume` | |
| Stop | `40519 brew_flow_stop` | Also what the interlock sends. |

Completion, in order of trust:

1. `40512 take_cup` / `40513 brewer_finish` — the machine says so;
2. `8023` reporting **page 1, home** — and only home. Any-screen-change was the
   old rule and it was wrong: this machine moves between screens constantly
   (30/34 grinding, 2 after a grind, 15 on a fault, 31 on pause), and a 12:43
   recording ends a session one frame after a pause because 35 became 31;
3. a drain backstop — the last pour fully delivered and the volume counter still
   for longer than any rest in the recipe.

A completion signal arriving before any pour has happened belongs to the
machine's previous cycle and is ignored.

## 12. Faults

| Frame | Treatment |
|---|---|
| `40517 grinder_empty_abnormal` | Named in plain language, session ends, dismissible |
| `40522 watertank_volume_low` | **Only a non-zero payload is a fault.** It arrived once mid-brew with a zero payload while the machine poured normally for another 36 s. A non-zero level shows an inline banner, not an alert — the machine keeps brewing |
| anything else | Reported with its numeric identifier, so a one-off is identifiable next time |

## 13. Where the beans go — dose accounting

Two different things get called "wasting beans". Both are covered here.

### The bag ledger

`BeanProfile.remainingWeightGrams` is the app's inventory. It is debited in
exactly one place: `LocalLibrary.recordCompletedBrew` calls
`Brewing.deductDose(recipe.dose, from:)` when a session is recorded
([PersistenceModels.swift:361](XBloomApp/Models/PersistenceModels.swift:361)),
clamped at zero, and only for the bean the recipe is linked to (`recipe.beanID`).

What that means in practice:

- The figure deducted is **the dose on the recipe used for this brew**. After
  the weighing sheet that is the weighed amount, not the recipe's target — the
  hand-off replaces `dose` on a copy of the recipe before the brew is presented.
- Nothing is deducted when a brew is *started*. It happens once, at the point
  the session is recorded.
- A **stopped** brew still records and still debits the full dose. Beans that
  were ground are gone whether or not the water finished, which is right when
  the stop came after grinding and an over-count when it came before.
- A **simulated preview** also records — and therefore also debits the bag,
  even though no machine was involved. That is a defect, not a design: the
  `wasSimulated` flag reaches history but is not consulted before the deduction.

Elsewhere the ledger is only read: Home and Recipes hide or flag a recipe whose
bean has less left than the dose and show how many doses remain.

### Beans genuinely wasted at the machine

Three failure modes destroy coffee, and each has a specific guard:

| Failure | What it costs | Guard |
|---|---|---|
| A grinding recipe takes the no-grind branch | The whole dose, soaked whole | The interlock stops at the first `watering_phase` with no grinding evidence (§8) |
| Grinder runs with an empty hopper | Nothing ground; the water would follow | The machine reports `40517` and ends its own program; the app closes the session instead of pretending it can be resumed |
| A page exit lands inside the recipe upload | The whole dose | Screens are released *before* the first setup command, awaited (§3) |

The weighing flow's own contribution is that the beans are weighed **before**
they are loaded, and the dose the machine is told is the one that actually went
in — so a short bag brews a knowingly weaker cup instead of a failed one.

## 14. Known gaps

- Whether the corrected ratio byte is sufficient to make *every* grinder-on
  recipe take the grinding branch. One attended hardware brew still needed.
- `8104 device_pod_type` — the vendor's values are copied, but what the two
  floats actually mean is not established.
- The leading `1000` in `3500 grind_adjust`, and how much a direct grind
  actually delivers. Never weighed.
- Simulated previews debit the bean bag (§13).
- `8023` page numbers beyond 1, 2, 15, 29–31, 34, 35.
