# Reliability and structure changes

The app now keeps compact brew history, treats preview as a read-only experience,
and collects AI results through durable local receipts. The native app remains
responsible for machine control and recipe validation.

## AI recipes

- A generation request ID is also the resulting recipe ID. Collection on different
  devices therefore converges on the same cloud recipe instead of creating fresh IDs.
- The recipe and a local receipt are saved together before the cloud result is
  acknowledged. Receipts survive recipe deletion and failed acknowledgements.
- Invalid results receive a persisted rejection before acknowledgement. Their raw
  responses remain on the server for diagnosis.
- Startup, foreground and polling refreshes are serialized. Work is scoped to the
  current account; stale account results cannot be collected after a switch.
- Cancellation intent is saved per account, held while submission is in flight,
  and retried during refresh. Offline cancellation is retried on the next foreground
  refresh even when there are no other jobs to poll.
- Polling filters recipe jobs on the server and reads every page. Cards for jobs
  consumed elsewhere disappear on reconciliation.
- A stale unfinished job is not consumed. Its late result can still be collected
  on a subsequent foreground refresh.
- The Edge Function retries transient result-write failures using the existing
  response; it does not call Gemini again to retry a database save. A cancelled row
  cannot be overwritten by the finishing worker.
- Feedback enhancement uses the same background job flow as recipe design. The
  history screen saves feedback, opens Recipes, and shows a purple enhancement
  animation. Leaving the screen does not cancel the request.
- Job context preserves the original bean snapshot, parent recipe and source brew.
  Collection saves the new recipe and the brew's enhancement link atomically. The
  recipe description explains what changed and why in response to the feedback.
- Import and legacy requests without a job ID still return inline without waiting
  for best-effort usage logging. Background design and enhancement jobs require
  successful result persistence.

## History and maintenance

Detailed samples are retained for the newest 20 brews. Older summaries, recipe and
bean snapshots, ratings and notes remain available for maintenance and feedback.
Library synchronization now pages through all records. The first brew is included
in usage when no service has yet been recorded.

Deleting a recipe or bag now preserves historical brews, ratings, notes and
snapshots. A bag still removes its active recipes; the historical records remain
independent of that library cleanup. Existing snapshots are never replaced with an
edited library recipe. Older records missing snapshots retain the available recipe
and bean details before deletion; those are the best available details, not a
reconstruction of earlier edits.

Maintenance lists due services first, shows recorded brew and grinder totals, and
includes recent service history. Record service accepts a completion date and notes.
Failed saves show an error; imported legacy service dates are removed from device
preferences only after their database records save successfully.

Preview completion does not create a real history record or deduct beans. Previously
recorded previews are still distinguishable through their simulation flag and do not
contribute to maintenance. Existing inventory deductions cannot be reversed safely
without knowing whether the user has already corrected them.

New stopped sessions have an explicit outcome. An unknown completed-pour count is
sent to AI as unknown, rather than labeling the planned count as completed. Feedback
and enhancement controls are available for manual recipes as well as AI recipes;
saving feedback works without an AI account.

## Dose weighing and loading

The weighing screen follows live scale readings, including zero and negative
readings after a physical tare or container removal. It no longer substitutes the
last nonzero dose. A `weightCleared` notification clears the phone's reading and
manual adjustment; a separate event counter handles repeated tares at zero.

Confirm the dose before lifting the beans. The next screen keeps that dose fixed,
asks you to load the grinder and place the coffee server, and explicitly starts
grinding followed by brewing. It does not infer readiness from changing scale
weight or switch a bean ring between gray and green. Hardware testing is still
needed to confirm the physical button's notification behavior on this firmware.

## Daily brewing shortcuts

- History's **Brew again** and Home's **Review & repeat** use the saved recipe
  snapshot, including its measured dose and every pour. Library edits do not
  change it, and no duplicate library recipe is created. A missing or invalid
  snapshot cannot be repeated. Connecting does not automatically start a brew;
  the user reviews the setup and explicitly starts it.
- Completed real brews show optional stars, taste tags and notes before the
  detailed graphs. Feedback updates the existing history record and preserves
  usage, snapshots and enhancement links. Detailed feedback and enhancement
  remain available; previews never create feedback records.
- Recipe favorites are an optional field in the existing recipe payload. The
  detail screen, library context menu and Home favorites support toggling them.
  Recipes has a favorites filter. Home prioritizes favorites when recommending
  available coffee; archived or missing bags and insufficient inventory are not
  recommended. Favorites use existing library sync, with no schema change.
- Home separates Bluetooth connection from cloud sync. Local-only, waiting,
  uploading, failed and synced states are distinct. A save during an upload
  remains pending until a subsequent upload completes. Sync failures offer Retry,
  and foregrounding the app retries library sync. The app starts conservatively
  as pending after relaunch until it has confirmed a successful sync.

## File responsibilities

- `Views/BeansView.swift`: bean list. Detail, refill, editor, photo import and AI
  designer each have their own view file.
- `Views/RecipesView.swift`: recipe list and filters. Row, detail and editor are
  separate views.
- `Views/BrewView.swift`: recipe browser for starting a brew.
- `Views/BrewSessionView.swift`: session state and screen composition. Presentation
  components and runtime handling are grouped in two extensions of this internal view.
- `Services/BrewSessionCoordinator.swift`: session presentation and restoration.
- `Services/LocalLibrary.swift`: library writes, inventory and telemetry compaction.
  Debug seeding lives in `LocalLibrary+PreviewFixtures.swift`.
- `Services/RecipeJobStore.swift`: injectable job interfaces.
- `Services/RecipeJobPersistence.swift`: atomic local collection and receipts.
- Shared controls are grouped by their purpose: dials, pour controls, choices and
  AI processing views.
- `supabase/functions/coffee-ai/index.ts`: runtime entry point. `handler.ts` contains
  the injectable HTTP handler and persistence logic; `handler_test.ts` exercises
  failures without network access or provider charges.

## Verification

Verified on September 10, 2026: 74 core tests, 20 iOS simulator app tests, and 10
backend tests passed. The simulator build, Deno type check and lint, and Git
whitespace check also passed. The deployed `coffee-ai` version 7 is active with JWT
verification enabled; both deployed source files exactly match this branch.

Run core and backend tests:

```sh
swift test
deno check supabase/functions/coffee-ai/index.ts
deno test supabase/functions/coffee-ai/handler_test.ts
```

Run app tests using an available iPhone simulator:

```sh
xcodegen generate
xcodebuild test -project XBloom.xcodeproj -scheme XBloom \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  CODE_SIGNING_ALLOWED=NO
```

The app tests use in-memory SwiftData stores and fake cloud/provider services. CI
runs core and backend tests in the existing Tests check, and simulator app tests in
the existing Build check. Tests cover maintenance retention, preview inventory,
repeated brew recording, durable collection, save and acknowledgement failures,
concurrent refresh, cancellation, account switching, rejection and deletion replay.

## Rollout and remaining limits

The updated `coffee-ai` function is deployed with JWT verification enabled. No live
table data or schema was changed. The maintenance migration filename now matches
its already-deployed version, `20260829193827`; its SQL is unchanged. A fork that
previously applied the old local timestamp must reconcile its own migration history
before applying future migrations.

Rebuild/install the app to receive the local changes, and update other copies that
sync this account: older app versions still delete history after 20 brews. Previously
deleted history cannot be reconstructed by this change. Older builds also remove
related history when deleting bags or recipes, so update every synced copy before
cleaning up the library. This update uses existing brew and service records and
requires no Supabase schema change.

`waitUntil` still runs within an Edge Function worker's lifetime. Surviving a worker
termination or a prolonged database outage requires a durable queue and recovery
worker; bounded retries do not provide that guarantee. The quota lookup now fails
closed, but atomic concurrent admission and daily/token budgets remain future work.
The pre-existing leaked-password-protection advisory is unchanged. Physical machine
behavior should be checked on hardware; the regression suite does not transmit
Bluetooth commands.
