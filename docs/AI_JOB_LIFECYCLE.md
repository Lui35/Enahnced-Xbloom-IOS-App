# Recipe and bean import jobs

Recipe design, feedback enhancement, and importing a new bag from photos use the same server job lifecycle. The app submits a stable request ID and recovery context to `coffee-ai`. Supabase records the job before returning HTTP 202, then runs Gemini with `EdgeRuntime.waitUntil` and persists the response in `ai_request_usage`.

## Closing the app

- Before acceptance: uploading photos or submitting a recipe still needs the app and a connection. Force-quitting at this point can interrupt submission. A lost HTTP acknowledgement is reconciled against the server; the app does not assume it failed and automatically bill for another generation.
- After acceptance: closing, locking, or backgrounding the phone does not cancel server processing. The saved response stays on the account's job row until collected.
- Returning: launch, sign-in, and foreground refresh restore pending cards or collect completed responses. The app needs a connection and the same account. A still-running job resumes its animation; a successful import becomes a bag marked for review.
- Collection: decoding and creation of the SwiftData recipe or bean happen on the phone when it returns. The backend stores the AI result while the phone is closed; it does not directly insert a cloud-library bean or recipe. Local saving triggers the existing cloud sync.
- Duplicates: the request ID becomes the recipe/bean ID. The local object and a durable receipt are saved before acknowledging the server. A lost acknowledgement or later deletion cannot replay the result on that device. A second device collecting concurrently uses the same object ID.
- Cancellation: the app persists an account-scoped cancellation intent, retries it after reconnecting, and ignores cancelled results. Cancelling discards the result; it does not guarantee an already-running provider request stops or avoids charges.

## Runtime limits

This is recoverable result storage with background execution, not an indefinitely durable execution queue. Supabase Edge Function wall-clock, CPU, memory limits or worker termination can still stop unfinished work. Provider calls and result writes have bounded retries. Stale jobs display a delay message; a result saved later can still be recovered on foreground/launch. Unfinished jobs are not automatically resubmitted because their original images/prompts are not persisted for replay.

Supabase reference: https://supabase.com/docs/guides/functions/background-tasks

## Compatibility and privacy

Old app builds and the refill label preview omit a job ID and continue to receive synchronous results. Refill is a review step before updating an existing bag, not a new-bag import. Old synchronous imports have no saved response and cannot be recovered retroactively.

New bag jobs store a photo count in context, not the source photos. Photos are sent to the existing AI provider for extraction. Existing account ownership policies and column permissions protect job access. No new database schema or grants are needed.

## Verification

The app tests cover cold-coordinator recovery, reopening a disk store, save-before-acknowledgement, failed writes, replay after deletion, action separation, cancelled uploads across relaunch, invalid results, and account changes during fetch. Backend tests hold the provider open, return 202, disconnect the client, then verify the job result is persisted. A physical-phone force-quit with real photos is still a useful final integration check; these automated tests do not simulate a Supabase worker crash.

## Legacy context date compatibility (September 13)

An older feedback job encoded `beanSnapshot.roastDate` as Foundation seconds since January 1, 2001. Supabase's default decoder expects date strings. Because the app decoded a full page before filtering by action, that failed feedback job blocked retrieval of later successful recipes and bean imports. The poller previously swallowed the decoding error, making processing appear to continue indefinitely.

Job responses now use a dedicated decoder accepting legacy numeric dates and ISO 8601 dates, including fractional database timestamps. New contexts encode dates as ISO 8601. Retrieval failures are shown and retried, including when a cold-launch fetch failed before any pending cards were loaded. A regression test confirms that the default Supabase decoder rejects a synthetic mixed page and the job decoder recovers all three job types.

The one affected unconsumed production feedback context was converted to an equivalent ISO date in place, without changing its job status, recipe data, or AI response. This unblocks existing app builds; installing the updated build prevents recurrence. No provider request was rerun.
