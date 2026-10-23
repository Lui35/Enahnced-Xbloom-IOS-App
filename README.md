# xBloom Native

**An iPhone companion for the xBloom Studio** — reverse-engineered from
recordings of a real machine, built for the parts of brewing the official app
leaves out.

It knows what is in the hopper, what the last cup tasted like, what the machine
is about to do, and when it last had something done to it. Your library lives on
your phone; it syncs to *your* Supabase project, and AI requests go through an
authenticated Edge Function, so no provider key is ever shipped in the app.

<p align="center">
  <img src="docs/screenshots/home.png" width="30%" alt="Home screen with machine tools" />
  <img src="docs/screenshots/brew.png" width="30%" alt="Compact extraction ring and pour timeline in a simulated brew" />
  <img src="docs/screenshots/ai-designer.png" width="30%" alt="The AI recipe designer" />
</p>

<p align="center">
  <em>Swift 6 · SwiftUI · SwiftData · Core Bluetooth · Supabase · Gemini · core and app regression tests</em>
</p>

> **Unofficial.** Not affiliated with or endorsed by xBloom. The protocol was
> recovered from Bluetooth recordings of one machine and from the MIT-licensed
> [PyBloom](https://github.com/fhenwood/PyBloom) project. It can move
> mechanisms, run the grinder, and dispense near-boiling water. Test attended.

**[Installation guide →](INSTALLATION.md)**

First launch includes a guided tour, Apple/email account options, and guest access.
Share a single recipe from its menu and import a copy directly in xBloom—even
offline. See [onboarding, account setup, and recipe links](docs/onboarding-and-sharing.md).

---

## What it does that the official app does not

<img src="docs/screenshots/recipe-detail.png" width="260" align="right" alt="A recipe, pour by pour" />

### It weighs the dose before it commits to it

The recipe's dose is a target. Coffee does not come out of a bag in exact
grams, so the app opens the machine's own scale first, follows its live reading,
and lets you correct it by hand. Confirm the dose before lifting the beans. That figure —
not the recipe's rounded target — is what the machine is told, what history
records, and what comes off your bean bag.

Weighing and loading are separate steps on purpose: the beans have to leave the
scale and go into the grinder in between. Once confirmed, the dose stays fixed
while you replace the weighing container with a coffee server. The next button
explicitly starts grinding and brewing; scale changes do not toggle readiness.

### It stops a brew that is about to pour over whole beans

A machine that takes the no-grind branch of a grinding recipe soaks your dose in
hot water and reports no error at all. The app arms an interlock the moment the
recipe is executed: if water starts before any gear movement, grinder event, or
grinding screen, it sends a stop at the first pour.

The earlier version of that guard stopped on a *screen change*, which cancelled
valid brews — a display is not proof a mechanism did or did not move. The one
that shipped waits for the machine's own watering event.

### It reads the machine honestly, or says nothing

Live measurements are interpreted from Bluetooth recordings of the real
machine:

- **Poured volume** is a float in microlitres. An earlier guess at the scale
  turned a 45 ml bloom into 450 ml and pinned the display at "finished" seconds
  into every brew.
- **Cup yield** is the lowest scale reading in a 1.6 s window, because the scale
  drops to 0.0 for single frames mid-pour and reads 3.4 kg if you lean on the
  machine.
- **Temperature** is not shown as a measurement, because this machine has never
  sent one — zero readings in 2,343 recorded frames. The recipe's target is
  labelled as a target.
- **The clock** starts when the machine reaches its brewing screen and stops
  while the recipe is paused, so it agrees with the display on the machine
  rather than drifting away from it by the length of the grind.

The compact extraction header keeps its layout through preparation, pouring,
and rests. The ring shows the current pour pattern while pouring and a pause
icon while resting. Subtle ticks mark cumulative pour endpoints; longer ticks
mark programmed pauses. Ring progress follows delivered water, so it holds
through rests instead of counting down an estimated duration. Live elapsed time
comes from observed machine events; simulation time is labelled separately.
Cup yield shows measured grams without an expected-yield denominator, and a
missing scale signal is reported as **no reading**.

### It shows the burrs travelling

Ask the grinder for a new size and the machine spends up to six seconds walking
the burr carrier there before it grinds anything. The gear stream turns out to
be the dial itself, offset by thirty — so the grind-size control carries a grey
bar at the burrs' real position, stepping toward your setting as the machine
moves, and the elapsed timer starts when grinding actually begins.

<br clear="right" />

<img src="docs/screenshots/maintenance.png" width="260" align="right" alt="Maintenance counted from brew history" />

### It says when the machine next needs something done to it

A maintenance screen counts three services out of your brew history rather than
asking you to log anything:

| Service | Falls due |
|---|---|
| Brush the grinder | Weekly, but only in a week the grinder actually ran |
| Cleaning tablets & calibration | Every 1 kg of beans ground |
| Descale | 300 brews or three months |

Each carries xBloom's own published procedure — grind size 55 for the tablets,
250–300 ml of water with 80–90 ml of descaling solution, their warning about
vinegar voiding the warranty. Every service you record is a row, so the app can
tell you how often you *actually* descale, not only when you last did.

### Direct machine tools

Scale, single pour, and grinder, each on its own screen. Every control waits for
the machine to echo the command back and says so plainly when it does not —
several of these payload shapes have never been confirmed, and a control that
pretends to have worked is worse than one that admits it did not.

The single-pour screen deliberately does *not* use the vendor's direct brewer
opcodes. They would open a valve on near-boiling water with a payload nobody has
verified; a one-step recipe carries the same four settings down a path the
machine has demonstrably understood.

<br clear="right" />

---

## What the AI does

Requests run through a Supabase Edge Function against Gemini. Three things use
it, and all three now run in the background — start one, leave the screen, and
the library shows it working.

### Reads a coffee bag from photos

Photograph the front and back labels. The bag lands on your shelf as soon as it
is read, flagged **NEEDS REVIEW**: origin, producer, variety, process, altitude,
roast level and tasting notes, all filled in from the label, with a card at the
top of the bean saying a machine wrote it and asking you to confirm. A record
nobody has checked says so until somebody checks it.

### Designs a recipe

Not a template with the numbers swapped. The brief tells the model there is no
universally correct pour count and to derive the whole architecture — pours,
bloom, grind, temperature, flow, agitation, ratio — from roast development,
process, density, origin and the cup you asked for. A washed high-elevation
Ethiopian and a natural Brazilian should not come back with the same shape, and
they do not.

You choose hot or iced, one or two cups, and either "best for this bean" or a
set of flavour goals that combine (Bright ↔ Low acidity replace each other;
Sweetness and Body do not). Pours are the model's decision by default, with an
override for when the answer is simply three. A bean from your shelf is
optional — without one you describe the coffee in a sentence, and if you leave
even that blank the recipe comes back designed for a typical washed
medium-light filter coffee and says so in its own rationale.

### Improves a recipe from what actually happened

Rate a brew and the model sees the recipe, the bean, and the real extraction —
duration, machine water, scale yield, completed pours — alongside your rating
and notes, and proposes the next version.

Every recipe it returns goes through the same machine-safety validation a
hand-written one does: dose 5–30 g, grind 1–80, 1–8 pours, ≤ 500 ml, 80–96 °C,
3.0–3.5 ml/s. The AI cannot talk the machine into anything the editor could not.

---

Screenshots show simulator sample data; the brew screenshot is a preview with
no machine commands.

## Two ways to browse recipes

Use the view menu beside **+** in Recipes to switch between **List** and
**Folders**. The app remembers the choice on this device. List keeps search and
All / Favorites / Hot / Iced filters. Folders groups recipes by their linked
bean bag, with separate **General hot** and **General iced** collections for
recipes without a bean. Bags with the same name remain separate, and recipes
whose original bag is unavailable stay accessible.

<p align="center">
  <img src="docs/screenshots/recipes.png" width="30%" alt="Recipe list with search and filters" />
  <img src="docs/screenshots/recipe-folders.png" width="30%" alt="Bean collections with shared inventory bars" />
  <img src="docs/screenshots/recipe-collection.png" width="30%" alt="A bean's recipe collection with AI design and editing shortcuts" />
</p>

Each bean collection shows remaining grams, bag percentage, and a roast-date
marker against a personal 30-day brewing target. This is a preference marker,
not an expiry or food-safety assessment; a missing roast date stays unknown.
Set the roast date in the bean editor. Opening a collection uses the same bean
header and **Design with AI** action as the bean shelf. Its Edit shortcut opens
that bag's editor in the Beans tab. The **+** menu can create a recipe or move an
existing recipe into the bag's collection without changing its brewing settings.

## Water-tank reminders

A nonzero `40522` report is remembered for that machine and shown on Home,
including as a **last report** after a disconnect. Starting a new live recipe,
repeating a brew, or starting a manual pour asks you to check and reseat the
tank before continuing. You can cancel or confirm the physical check for that
attempt; confirmation does not claim the machine has verified a refill.

A zero `40522` status or an explicit water-OK machine-info report clears the
warning. The recorded zero event happened during a normal brew, so the app does
not treat the command name alone, missing data, or a guessed tank-volume
threshold as proof of an empty tank. See [the recorded behavior](docs/VERIFIED_MACHINE_BEHAVIOUR.md)
and [the implementation notes](docs/APP_BLE_IMPLEMENTATION.md).

<p align="center">
  <img src="docs/screenshots/water-warning.png" width="30%" alt="Home with a remembered low-water warning, shown using debug sample state" />
</p>

## The rest of it

<p align="center">
  <img src="docs/screenshots/beans.png" width="30%" alt="The bean shelf, with what is left in each bag" />
  <img src="docs/screenshots/settings.png" width="30%" alt="Grouped account, machine, and library settings" />
  <img src="docs/screenshots/history.png" width="30%" alt="Brew history with telemetry" />
</p>

- **Beans** — origin, process, roast date, acidity, tasting notes, bag weight
  drawn down by every brew, and refills that keep a bag's recipes and history
  connected.
- **Recipes** — a full editor over the machine's real parameter space, with
  validation that explains itself, favorites, bean collections, single-recipe
  links, and import/export of a whole library.
- **History** — every brew with its telemetry curve, rated and tagged, feeding
  both the AI and the maintenance counters. Brew summaries and feedback are retained;
  detailed telemetry is kept for the newest twenty brews.
- **Daily shortcuts** — repeat the exact recipe saved with a past brew, rate a
  completed cup quickly, and open Scale, Brewer, and Grinder from a compact Home
  screen. A shared Bluetooth button opens machine status and connection controls
  from every main tab.
- **Settings** — grouped account and sync controls, machine connection, sound,
  maintenance, diagnostics, library transfer, app guidance, and on-device storage.
- **Consistent styling** — filled bean and weight symbols, warm-brown inventory
  bars and percentages, amber actions, blue water metrics, and green live yield
  and success states use shared theme definitions.
- **Water-tank reminder** — a nonzero low-water report stays visible on Home
  for that machine, including after reconnecting. A new live brew or manual pour
  asks you to check the tank before proceeding. A zero status or explicit water-OK
  report clears it; missing data is never treated as an empty tank.
- **Live Activity** — the brew on the Lock Screen and Dynamic Island.
- **A preview mode** — watch a recipe run end to end at realistic speed with no
  machine connected, no commands sent, and no changes to inventory or brew history.
- **Machine diagnostics** — record the Bluetooth session and share the
  transcript. Every protocol finding in `docs/` came out of one of these.

Deleting a bag removes it and its recipes from the library. Deleting a recipe
leaves its bean in place. Both preserve historical brews, snapshots and feedback,
so cleaning up the library does not reset maintenance usage. Library deletions
still sync to your account. Maintenance shows due services first and keeps a log
of completed services with dates and optional notes.

---

## Getting started

Full instructions, including standing up your own Supabase project, are in
**[INSTALLATION.md](INSTALLATION.md)**. The short version:

```sh
git clone https://github.com/Lui35/Enahnced-Xbloom-IOS-App.git
cd Enahnced-Xbloom-IOS-App
cp Secrets.example.xcconfig Secrets.xcconfig
xcodegen generate && open XBloom.xcodeproj
```

Set your own signing team and bundle identifier, and run it on an iPhone — the
simulator has no Bluetooth. The app is fully usable with no account at all;
sync and AI need a Supabase project of your own, which the guide walks through.

## Tests

The domain and protocol logic lives in `Sources/XBloomCore` and runs without
Xcode:

```sh
swift test
```

Core tests also cover bag-identity grouping, unlinked and unavailable-bean
collections, calendar-based roast targets, and
low-water report/clear handling.

Those tests are written against the recordings: the verified recipe encoding,
the microlitre volume counter, the yield curve with its dropouts and its hand
on the scale, the brew clock, the grinder interlock, and the maintenance rules.

## Contributing

The protocol work is the interesting part, and it advances one recording at a
time. If you own an xBloom:

- **Record a session** in Settings → Machine diagnostics and share the
  transcript. A capture from different firmware, or of a brew this app has
  never seen — a tea recipe, an Easy Mode program, a fault — is worth more than
  any amount of guessing.
- **`docs/VERIFIED_MACHINE_BEHAVIOUR.md` is the rule**: a claim about the
  machine belongs there only once a recording shows it. Findings are numbered,
  and each says what was observed versus what was inferred.
- Domain and protocol logic lives in `Sources/XBloomCore` and is testable
  without Xcode. New behaviour comes with a test written against a real
  recording where one exists.

Open questions are listed under **Still unverified** at the end of the verified
behaviour document.

### How a change reaches main

`main` is protected: no direct pushes, from anybody, including the owner.

```sh
git checkout -b your-branch
# work, commit
git push -u origin your-branch
gh pr create
```

Two checks run on every pull request and both must be green before the merge
button unlocks:

| Check | What it runs |
|---|---|
| **Tests** | `swift test` for XBloomCore plus Deno backend fault and retry tests |
| **Build** | `xcodegen generate` then app build and SwiftData/job lifecycle tests on an iOS Simulator |

The branch must also be up to date with `main`, review conversations must be
resolved, and force-pushing or deleting `main` is refused outright.

## Documentation

- `docs/UI_DESIGN.md` — shared styling, recipe layouts, and extraction display.
- `docs/onboarding-and-sharing.md` — first launch, accounts, guest access, and recipe links.

- `docs/APP_BLE_IMPLEMENTATION.md` — what this app sends: the brew sequence with
  and without the grinder, the pre-brew scale, weighing and grinder screens, the
  grinder interlock, and how a dose comes off the bean bag.
- `docs/VERIFIED_MACHINE_BEHAVIOUR.md` — what the owner's machine actually does,
  read out of traffic recordings. Takes precedence over everything else.
- `docs/OFFICIAL_APP_BLE_COMPARISON.md` — the vendor's command table, extracted
  from its shipped binary.
- `docs/PYBLOOM_BLUETOOTH_API.md` — the third-party reference this app started
  from. Describes different firmware in places; treat as background.

The Bluetooth implementation is unofficial, derived from the MIT-licensed
PyBloom interoperability project and from recordings of one machine. It is not a
vendor-supported API and can change without notice. See `THIRD_PARTY_NOTICES.md`.

## Licence

[MIT](LICENSE) — the same terms as PyBloom, which this builds on.
