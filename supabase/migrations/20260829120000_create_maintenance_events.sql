-- Machine maintenance, as a log rather than a set of dates.
--
-- The app kept the last-done date for each service in UserDefaults, which never
-- left the phone and told you nothing about how often you actually do them.
-- One row per service performed answers both: the newest row per task is the
-- "last done" the maintenance screen counts from, and the rows behind it are
-- the cadence.

create table public.maintenance_events (
  user_id uuid not null references auth.users(id) on delete cascade,
  id uuid not null,
  task text not null check (task in ('grinderBrush', 'grinderTablets', 'descale')),
  performed_at timestamptz not null,
  note text,
  client_updated_at timestamptz not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz,
  primary key (user_id, id)
);

create index maintenance_events_task_idx
  on public.maintenance_events (user_id, task, performed_at desc)
  where deleted_at is null;

alter table public.maintenance_events enable row level security;

create policy maintenance_events_owner_all on public.maintenance_events for all to authenticated
using ((select auth.uid()) = user_id) with check ((select auth.uid()) = user_id);

revoke all on table public.maintenance_events from anon, authenticated;
grant select, insert, update, delete on table public.maintenance_events to authenticated;
