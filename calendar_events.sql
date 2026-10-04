create table if not exists public.calendar_events (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  title text not null check (char_length(btrim(title)) between 1 and 100),
  event_date date not null,
  details text check (details is null or char_length(details) <= 1000),
  created_at timestamptz not null default now()
);

create index if not exists calendar_events_user_date_idx
  on public.calendar_events (user_id, event_date, created_at);

alter table public.calendar_events enable row level security;

drop policy if exists calendar_events_select_own
  on public.calendar_events;
create policy calendar_events_select_own
  on public.calendar_events for select to authenticated
  using (user_id = auth.uid());

drop policy if exists calendar_events_insert_own
  on public.calendar_events;
create policy calendar_events_insert_own
  on public.calendar_events for insert to authenticated
  with check (user_id = auth.uid());

drop policy if exists calendar_events_update_own
  on public.calendar_events;
create policy calendar_events_update_own
  on public.calendar_events for update to authenticated
  using (user_id = auth.uid())
  with check (user_id = auth.uid());

drop policy if exists calendar_events_delete_own
  on public.calendar_events;
create policy calendar_events_delete_own
  on public.calendar_events for delete to authenticated
  using (user_id = auth.uid());

revoke all on table public.calendar_events from anon;
grant select, insert, update, delete
  on table public.calendar_events to authenticated;
