create table if not exists public.todo_items (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  title text not null check (char_length(btrim(title)) between 1 and 120),
  is_complete boolean not null default false,
  completed_at timestamptz,
  created_at timestamptz not null default now(),
  constraint todo_items_completion_state check (
    (is_complete and completed_at is not null)
    or (not is_complete and completed_at is null)
  )
);

create index if not exists todo_items_user_created_idx
  on public.todo_items (user_id, created_at);

create index if not exists todo_items_completed_idx
  on public.todo_items (is_complete, user_id);

alter table public.todo_items enable row level security;

drop policy if exists todo_items_select_public
  on public.todo_items;
create policy todo_items_select_public
  on public.todo_items for select to anon, authenticated
  using (true);

drop policy if exists todo_items_insert_own
  on public.todo_items;
create policy todo_items_insert_own
  on public.todo_items for insert to authenticated
  with check (user_id = auth.uid());

drop policy if exists todo_items_update_own
  on public.todo_items;
create policy todo_items_update_own
  on public.todo_items for update to authenticated
  using (user_id = auth.uid())
  with check (user_id = auth.uid());

drop policy if exists todo_items_delete_own
  on public.todo_items;
create policy todo_items_delete_own
  on public.todo_items for delete to authenticated
  using (user_id = auth.uid());

revoke all on table public.todo_items from anon, authenticated;
grant select on table public.todo_items to anon, authenticated;
grant insert, update, delete on table public.todo_items to authenticated;

create or replace view public.todo_leaderboard
  with (security_invoker = true)
as
  select
    user_id,
    count(*) filter (where is_complete)::bigint as completed_count
  from public.todo_items
  group by user_id;

grant select on public.todo_leaderboard to anon, authenticated;
