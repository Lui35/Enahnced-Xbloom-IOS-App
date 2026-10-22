# Studio interface

The app uses neutral slate surfaces, solid warm identity headers, and shared
SwiftUI components. Recipe rows retain the HOT/ICED tile, pour pattern, pour
count, AI badge, dose, ratio, and origin summary.

## Shared visual roles

- `StudioSymbol.bean` and `StudioSymbol.weight` select the same filled symbols
  throughout the app, including tabs, cards, onboarding, and history.
- `StudioTheme.accent` identifies actions, including Settings, layout switching,
  recipe creation, and editing.
- `StudioTheme.inventory` is the warm-brown stock color. `BagInventorySummary`
  is shared by the bean shelf and recipe collections; `BagInventoryProgress`
  also renders the bean detail inventory bar.
- `StudioTheme.water` colors water metrics and flow controls consistently in
  editors, live charts, and recorded history. Green remains available for live
  cup yield, connection, completion, and success states.
- Hot/iced colors, warnings, and destructive actions retain their distinct roles.

## Home and navigation

Home keeps Scale, Brewer, and Grinder near the top, followed by a recipe chooser
and the last saved brew. It fits without a scrolling dashboard. Connection is
available through the same leading Bluetooth button on every main tab. Settings
uses grouped account, machine, library, and app sections.

## Recipe layouts

The toolbar view menu selects List or Folders and remembers the choice locally.
List includes search and All/Favorites/Hot/Iced filters. Folders groups by bean
identity, with general hot/iced collections and an unavailable-bean fallback.
Active bags can appear before they have a linked recipe.

Collections reuse `BeanLibraryHeader` and `BeanRecipeDesignButton`. Editing
routes to the selected bag's editor in the Beans tab. Creating manually or with
AI attaches the bean; adding an existing recipe updates its bean relationship.
Roast dates can be entered in the bean editor. Days-to-target uses a personal
30-day default and does not claim an expiry or infer missing dates.

## Extraction

The ring and elapsed timer stay side by side across brew phases at normal text
sizes. Accessibility text sizes consistently use a vertical arrangement. Pouring
shows the step's pattern; rests show a pause icon. Fine ticks mark cumulative
water endpoints, and longer ticks mark programmed rests. They represent recipe
structure, not estimated times. The active rest marker highlights while the
water-based progress arc holds.

The timing display has no estimated-duration tile. Live elapsed time follows
observed machine events and excludes pauses; simulation is explicitly labelled.
Cup yield is measured grams only, with a separate no-reading state. Recipe
parameters and planned graph markers remain distinguishable from telemetry.

## Verification

The current app builds for the iPhone 17 Pro simulator, and all 83 core tests
pass. Local preview checks cover recipe layouts, bean edit routing, shared stock
styling, and the extraction preparation/pour/rest states. README images are
simulator examples; the brew image shows simulation, not hardware verification.
Physical brewing still requires device verification.

## Water-tank warning

A nonzero `40522` status sets a per-machine remembered warning. Zero clears it,
as does an explicit water-OK flag in machine info. Malformed, missing, unrelated,
and auxiliary-channel data cannot set or clear it. The numeric reservoir field
is not interpreted as litres or an empty threshold.

Home shows the warning, labelled as a last report while disconnected. New live
sessions ask for a tank check before starting timers, Live Activities, or sending
recipe commands. Repeat/history brews use that same session gate; manual pours
have the same confirmation. Resuming an existing session and simulation do not
ask to restart a brew. Confirming a physical check permits that attempt but does
not erase the warning or claim the machine has verified a refill.
