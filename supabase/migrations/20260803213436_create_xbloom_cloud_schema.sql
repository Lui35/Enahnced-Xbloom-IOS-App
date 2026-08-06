-- xBloom cloud persistence: authenticated, user-owned, local-first records.
create schema if not exists private;
revoke all on schema private from public, anon, authenticated;

create or replace function private.set_updated_at()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;
revoke all on function private.set_updated_at() from public, anon, authenticated;

create table public.profiles (
  user_id uuid primary key references auth.users(id) on delete cascade,
  display_name text,
  initial_sync_completed_at timestamptz,
  last_client_sync_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.beans (
  user_id uuid not null references auth.users(id) on delete cascade,
  id uuid not null,
  name text not null,
  roaster text not null default '',
  remaining_weight_grams numeric not null default 0 check (remaining_weight_grams >= 0),
  archived boolean not null default false,
  payload_json text not null check (jsonb_typeof(payload_json::jsonb) = 'object'),
  client_updated_at timestamptz not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz,
  primary key (user_id, id)
);

create table public.recipes (
  user_id uuid not null references auth.users(id) on delete cascade,
  id uuid not null,
  name text not null,
  roaster text not null default '',
  origin text not null default '',
  brew_style text check (brew_style in ('hot', 'iced', 'cold')),
  generated_by_ai boolean not null default false,
  servings integer check (servings between 1 and 3),
  bean_id uuid,
  payload_json text not null check (jsonb_typeof(payload_json::jsonb) = 'object'),
  client_updated_at timestamptz not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz,
  primary key (user_id, id),
  foreign key (user_id, bean_id) references public.beans(user_id, id)
    on update cascade on delete set null
);

create table public.brews (
  user_id uuid not null references auth.users(id) on delete cascade,
  id uuid not null,
  recipe_id uuid,
  bean_id uuid,
  recipe_name text not null,
  bean_name text,
  completed_at timestamptz not null,
  duration_seconds double precision not null check (duration_seconds >= 0),
  rating integer check (rating between 1 and 5),
  brew_style text check (brew_style in ('hot', 'iced', 'cold')),
  generated_by_ai boolean not null default false,
  was_simulated boolean not null default false,
  servings integer check (servings between 1 and 3),
  water_ml double precision check (water_ml is null or water_ml >= 0),
  coffee_weight_grams double precision check (coffee_weight_grams is null or coffee_weight_grams >= 0),
  step_count integer check (step_count is null or step_count between 0 and 8),
  payload_json text not null check (jsonb_typeof(payload_json::jsonb) = 'object'),
  client_updated_at timestamptz not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz,
  primary key (user_id, id),
  foreign key (user_id, recipe_id) references public.recipes(user_id, id)
    on update cascade on delete set null,
  foreign key (user_id, bean_id) references public.beans(user_id, id)
    on update cascade on delete set null
);

create table public.inventory_events (
  user_id uuid not null references auth.users(id) on delete cascade,
  id uuid not null,
  bean_id uuid not null,
  brew_id uuid,
  kind text not null check (kind in ('initial', 'brew', 'refill', 'adjustment')),
  delta_grams numeric not null,
  occurred_at timestamptz not null,
  note text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz,
  primary key (user_id, id),
  foreign key (user_id, bean_id) references public.beans(user_id, id)
    on update cascade on delete cascade,
  foreign key (user_id, brew_id) references public.brews(user_id, id)
    on update cascade on delete set null
);

create table public.user_settings (
  user_id uuid primary key references auth.users(id) on delete cascade,
  preferred_ai_model text,
  telemetry_retention_days integer check (telemetry_retention_days is null or telemetry_retention_days >= 0),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.ai_request_usage (
  user_id uuid not null references auth.users(id) on delete cascade,
  id uuid not null default gen_random_uuid(),
  request_id uuid not null default gen_random_uuid(),
  action text not null check (action in ('testConnection', 'importBean', 'generateRecipe', 'enhanceRecipe')),
  model text not null,
  status text not null check (status in ('started', 'succeeded', 'failed')),
  input_bytes integer not null default 0 check (input_bytes >= 0),
  error_code text,
  created_at timestamptz not null default now(),
  primary key (user_id, id),
  unique (user_id, request_id)
);

create index beans_active_updated_idx on public.beans (user_id, client_updated_at desc) where deleted_at is null;
create index recipes_active_updated_idx on public.recipes (user_id, client_updated_at desc) where deleted_at is null;
create index recipes_bean_idx on public.recipes (user_id, bean_id) where deleted_at is null;
create index brews_completed_idx on public.brews (user_id, completed_at desc) where deleted_at is null;
create index brews_recipe_idx on public.brews (user_id, recipe_id) where deleted_at is null;
create index brews_bean_idx on public.brews (user_id, bean_id) where deleted_at is null;
create index inventory_events_bean_idx on public.inventory_events (user_id, bean_id, occurred_at desc) where deleted_at is null;
create index inventory_events_brew_idx on public.inventory_events (user_id, brew_id) where brew_id is not null and deleted_at is null;
create index ai_request_usage_recent_idx on public.ai_request_usage (user_id, created_at desc);

create trigger profiles_set_updated_at before update on public.profiles
for each row execute function private.set_updated_at();
create trigger beans_set_updated_at before update on public.beans
for each row execute function private.set_updated_at();
create trigger recipes_set_updated_at before update on public.recipes
for each row execute function private.set_updated_at();
create trigger brews_set_updated_at before update on public.brews
for each row execute function private.set_updated_at();
create trigger inventory_events_set_updated_at before update on public.inventory_events
for each row execute function private.set_updated_at();
create trigger user_settings_set_updated_at before update on public.user_settings
for each row execute function private.set_updated_at();

alter table public.profiles enable row level security;
alter table public.beans enable row level security;
alter table public.recipes enable row level security;
alter table public.brews enable row level security;
alter table public.inventory_events enable row level security;
alter table public.user_settings enable row level security;
alter table public.ai_request_usage enable row level security;

create policy profiles_owner_all on public.profiles for all to authenticated
using ((select auth.uid()) = user_id) with check ((select auth.uid()) = user_id);
create policy beans_owner_all on public.beans for all to authenticated
using ((select auth.uid()) = user_id) with check ((select auth.uid()) = user_id);
create policy recipes_owner_all on public.recipes for all to authenticated
using ((select auth.uid()) = user_id) with check ((select auth.uid()) = user_id);
create policy brews_owner_all on public.brews for all to authenticated
using ((select auth.uid()) = user_id) with check ((select auth.uid()) = user_id);
create policy inventory_events_owner_all on public.inventory_events for all to authenticated
using ((select auth.uid()) = user_id) with check ((select auth.uid()) = user_id);
create policy user_settings_owner_all on public.user_settings for all to authenticated
using ((select auth.uid()) = user_id) with check ((select auth.uid()) = user_id);
create policy ai_request_usage_owner_select on public.ai_request_usage for select to authenticated
using ((select auth.uid()) = user_id);

revoke all on table public.profiles, public.beans, public.recipes, public.brews,
  public.inventory_events, public.user_settings, public.ai_request_usage from anon, authenticated;
grant select, insert, update, delete on table public.profiles, public.beans, public.recipes,
  public.brews, public.inventory_events, public.user_settings to authenticated;
grant select on table public.ai_request_usage to authenticated;

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('bean-labels', 'bean-labels', false, 10000000, array['image/jpeg', 'image/png', 'image/heic'])
on conflict (id) do update
set public = excluded.public,
    file_size_limit = excluded.file_size_limit,
    allowed_mime_types = excluded.allowed_mime_types;

create policy bean_labels_owner_select on storage.objects for select to authenticated
using (bucket_id = 'bean-labels' and (storage.foldername(name))[1] = (select auth.uid())::text);
create policy bean_labels_owner_insert on storage.objects for insert to authenticated
with check (bucket_id = 'bean-labels' and (storage.foldername(name))[1] = (select auth.uid())::text);
create policy bean_labels_owner_update on storage.objects for update to authenticated
using (bucket_id = 'bean-labels' and (storage.foldername(name))[1] = (select auth.uid())::text)
with check (bucket_id = 'bean-labels' and (storage.foldername(name))[1] = (select auth.uid())::text);
create policy bean_labels_owner_delete on storage.objects for delete to authenticated
using (bucket_id = 'bean-labels' and (storage.foldername(name))[1] = (select auth.uid())::text);
