-- Recipe generation stops being something the phone waits for.
--
-- `coffee-ai` used to hold the HTTP request open for the whole Gemini call, so
-- a backgrounded app, a locked phone, or a tunnel threw away work that had
-- already been run and paid for: the row said `succeeded` but nothing recorded
-- what Gemini actually returned. The function now answers immediately and
-- finishes in the background, which makes this row the only place the result
-- lives.
--
-- `response` is the raw Gemini body rather than a parsed recipe, deliberately.
-- Turning that JSON into a `Recipe` means clamping every field and running
-- `RecipeValidator`, which is the same check `XBloomProtocol` runs before
-- writing bytes to the machine. A second copy of those limits in TypeScript
-- would eventually disagree with the Swift one, and the machine is the side
-- that cannot afford the disagreement. Text, not jsonb: nothing queries into
-- it, and the phone wants the bytes back exactly as Gemini wrote them.
alter table public.ai_request_usage
  add column context jsonb,
  add column response text,
  add column consumed_at timestamptz;

-- A request the user walks away from has usually already reached Gemini, so
-- cancelling marks the row instead of deleting it — a deleted row would also
-- hand the rate limiter a way to be reset on demand.
alter table public.ai_request_usage drop constraint ai_request_usage_status_check;
alter table public.ai_request_usage add constraint ai_request_usage_status_check
  check (status in ('started', 'succeeded', 'failed', 'cancelled'));

-- What the poll asks for: everything not yet accounted for, newest last.
create index ai_request_usage_open_idx on public.ai_request_usage (user_id, created_at)
  where consumed_at is null;

-- The phone marks a row consumed once the recipe is in its library, and
-- cancels one it no longer wants. It still may not insert, and may not write
-- `response`: only the function, holding the secret key, says that a request
-- happened or what came back.
create policy ai_request_usage_owner_update on public.ai_request_usage for update to authenticated
using ((select auth.uid()) = user_id) with check ((select auth.uid()) = user_id);

grant update (status, consumed_at) on table public.ai_request_usage to authenticated;
