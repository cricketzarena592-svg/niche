create table if not exists public.chat_conversations (
  id uuid primary key default gen_random_uuid(),
  kind text not null check (kind in ('direct', 'group')),
  title text,
  created_by uuid not null references auth.users(id) on delete cascade,
  direct_user_a uuid references auth.users(id) on delete cascade,
  direct_user_b uuid references auth.users(id) on delete cascade,
  created_at timestamptz not null default now(),
  constraint chat_conversations_shape check (
    (kind = 'direct'
      and title is null
      and direct_user_a is not null
      and direct_user_b is not null
      and direct_user_a < direct_user_b)
    or
    (kind = 'group'
      and title is not null
      and char_length(btrim(title)) between 1 and 80
      and direct_user_a is null
      and direct_user_b is null)
  )
);

create unique index if not exists chat_conversations_direct_pair_uidx
  on public.chat_conversations (direct_user_a, direct_user_b)
  where kind = 'direct';

create table if not exists public.chat_members (
  conversation_id uuid not null
    references public.chat_conversations(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  role text not null default 'member' check (role in ('admin', 'member')),
  joined_at timestamptz not null default now(),
  primary key (conversation_id, user_id)
);

create index if not exists chat_members_user_idx
  on public.chat_members (user_id, conversation_id);

create table if not exists public.chat_messages (
  id uuid primary key default gen_random_uuid(),
  conversation_id uuid not null
    references public.chat_conversations(id) on delete cascade,
  sender_id uuid not null references auth.users(id) on delete cascade,
  body text not null check (
    char_length(btrim(body)) between 1 and 4000
  ),
  created_at timestamptz not null default now()
);

create index if not exists chat_messages_conversation_created_idx
  on public.chat_messages (conversation_id, created_at desc);

create table if not exists public.chat_requests (
  id uuid primary key default gen_random_uuid(),
  sender_id uuid not null references auth.users(id) on delete cascade,
  recipient_id uuid not null references auth.users(id) on delete cascade,
  status text not null default 'pending'
    check (status in ('pending', 'accepted', 'declined')),
  conversation_id uuid references public.chat_conversations(id) on delete cascade,
  created_at timestamptz not null default now(),
  constraint chat_requests_not_self check (sender_id <> recipient_id),
  constraint chat_requests_conversation_state check (
    (status = 'accepted' and conversation_id is not null)
    or (status in ('pending', 'declined') and conversation_id is null)
  )
);

create unique index if not exists chat_requests_pending_pair_uidx
  on public.chat_requests (
    (least(sender_id, recipient_id)),
    (greatest(sender_id, recipient_id))
  )
  where status = 'pending';

create index if not exists chat_requests_recipient_status_idx
  on public.chat_requests (recipient_id, status, created_at desc);

create or replace function public.is_chat_member(
  p_conversation_id uuid,
  p_user_id uuid default auth.uid()
)
returns boolean
language sql
stable
security definer
set search_path = public
set row_security = off
as $$
  select exists (
    select 1
    from public.chat_members m
    where m.conversation_id = p_conversation_id
      and m.user_id = auth.uid()
  );
$$;

create or replace function public.is_chat_manager(
  p_conversation_id uuid,
  p_user_id uuid default auth.uid()
)
returns boolean
language sql
stable
security definer
set search_path = public
set row_security = off
as $$
  select exists (
    select 1
    from public.chat_conversations c
    left join public.chat_members m
      on m.conversation_id = c.id
      and m.user_id = auth.uid()
    where c.id = p_conversation_id
      and c.kind = 'group'
      and m.user_id is not null
      and (c.created_by = auth.uid() or m.role = 'admin')
  );
$$;

alter table public.chat_conversations enable row level security;
alter table public.chat_members enable row level security;
alter table public.chat_messages enable row level security;
alter table public.chat_requests enable row level security;

drop policy if exists chat_conversations_select_member
  on public.chat_conversations;
create policy chat_conversations_select_member
  on public.chat_conversations for select to authenticated
  using (public.is_chat_member(id));

drop policy if exists chat_members_select_member
  on public.chat_members;
create policy chat_members_select_member
  on public.chat_members for select to authenticated
  using (public.is_chat_member(conversation_id));

drop policy if exists chat_members_delete_self_or_manager
  on public.chat_members;
create policy chat_members_delete_self_or_manager
  on public.chat_members for delete to authenticated
  using (
    user_id = auth.uid()
    or public.is_chat_manager(conversation_id)
  );

drop policy if exists chat_messages_select_member
  on public.chat_messages;
create policy chat_messages_select_member
  on public.chat_messages for select to authenticated
  using (public.is_chat_member(conversation_id));

drop policy if exists chat_messages_insert_member
  on public.chat_messages;
create policy chat_messages_insert_member
  on public.chat_messages for insert to authenticated
  with check (
    sender_id = auth.uid()
    and public.is_chat_member(conversation_id)
  );

drop policy if exists chat_messages_update_own
  on public.chat_messages;
create policy chat_messages_update_own
  on public.chat_messages for update to authenticated
  using (
    sender_id = auth.uid()
    and public.is_chat_member(conversation_id)
  )
  with check (
    sender_id = auth.uid()
    and public.is_chat_member(conversation_id)
  );

drop policy if exists chat_messages_delete_own
  on public.chat_messages;
create policy chat_messages_delete_own
  on public.chat_messages for delete to authenticated
  using (sender_id = auth.uid());

drop policy if exists chat_requests_select_participant
  on public.chat_requests;
create policy chat_requests_select_participant
  on public.chat_requests for select to authenticated
  using (sender_id = auth.uid() or recipient_id = auth.uid());

create or replace function public.request_direct_chat(p_recipient_id uuid)
returns uuid
language plpgsql
security definer
set search_path = public
set row_security = off
as $$
declare
  v_user_id uuid := auth.uid();
  v_request_id uuid;
begin
  if v_user_id is null then
    raise exception 'You must be signed in';
  end if;

  if p_recipient_id is null or p_recipient_id = v_user_id then
    raise exception 'Choose another user';
  end if;

  if exists (
    select 1
    from public.chat_conversations c
    where c.kind = 'direct'
      and c.direct_user_a = least(v_user_id, p_recipient_id)
      and c.direct_user_b = greatest(v_user_id, p_recipient_id)
      and exists (
        select 1 from public.chat_members m
        where m.conversation_id = c.id and m.user_id = v_user_id
      )
      and exists (
        select 1 from public.chat_members m
        where m.conversation_id = c.id and m.user_id = p_recipient_id
      )
  ) then
    raise exception 'A chat is already available';
  end if;

  select r.id into v_request_id
  from public.chat_requests r
  where r.status = 'pending'
    and least(r.sender_id, r.recipient_id) = least(v_user_id, p_recipient_id)
    and greatest(r.sender_id, r.recipient_id) = greatest(v_user_id, p_recipient_id);

  if v_request_id is not null then
    return v_request_id;
  end if;

  insert into public.chat_requests (sender_id, recipient_id)
  values (v_user_id, p_recipient_id)
  on conflict (
    (least(sender_id, recipient_id)),
    (greatest(sender_id, recipient_id))
  ) where status = 'pending'
  do nothing
  returning id into v_request_id;

  if v_request_id is null then
    select r.id into v_request_id
    from public.chat_requests r
    where r.status = 'pending'
      and least(r.sender_id, r.recipient_id) = least(v_user_id, p_recipient_id)
      and greatest(r.sender_id, r.recipient_id) = greatest(v_user_id, p_recipient_id);
  end if;

  return v_request_id;
end;
$$;

create or replace function public.accept_chat_request(p_request_id uuid)
returns uuid
language plpgsql
security definer
set search_path = public
set row_security = off
as $$
declare
  v_user_id uuid := auth.uid();
  v_request public.chat_requests%rowtype;
  v_conversation_id uuid;
begin
  if v_user_id is null then
    raise exception 'You must be signed in';
  end if;

  select r.* into v_request
  from public.chat_requests r
  where r.id = p_request_id
    and r.recipient_id = v_user_id
    and r.status = 'pending'
  for update;

  if not found then
    raise exception 'This chat request is no longer available';
  end if;

  insert into public.chat_conversations (
    kind,
    created_by,
    direct_user_a,
    direct_user_b
  )
  values (
    'direct',
    v_user_id,
    least(v_user_id, v_request.sender_id),
    greatest(v_user_id, v_request.sender_id)
  )
  on conflict (direct_user_a, direct_user_b) where kind = 'direct'
  do nothing
  returning id into v_conversation_id;

  if v_conversation_id is null then
    select c.id into v_conversation_id
    from public.chat_conversations c
    where c.kind = 'direct'
      and c.direct_user_a = least(v_user_id, v_request.sender_id)
      and c.direct_user_b = greatest(v_user_id, v_request.sender_id);
  end if;

  insert into public.chat_members (conversation_id, user_id, role)
  values
    (v_conversation_id, v_user_id, 'admin'),
    (v_conversation_id, v_request.sender_id, 'member')
  on conflict (conversation_id, user_id) do nothing;

  update public.chat_requests
  set status = 'accepted', conversation_id = v_conversation_id
  where id = v_request.id;

  return v_conversation_id;
end;
$$;

create or replace function public.decline_chat_request(p_request_id uuid)
returns void
language plpgsql
security definer
set search_path = public
set row_security = off
as $$
declare
  v_user_id uuid := auth.uid();
begin
  if v_user_id is null then
    raise exception 'You must be signed in';
  end if;

  update public.chat_requests
  set status = 'declined'
  where id = p_request_id
    and recipient_id = v_user_id
    and status = 'pending';

  if not found then
    raise exception 'This chat request is no longer available';
  end if;
end;
$$;

create or replace function public.create_direct_chat(p_other_user_id uuid)
returns uuid
language sql
security definer
set search_path = public
set row_security = off
as $$
  select public.request_direct_chat(p_other_user_id);
$$;

create or replace function public.create_group_chat(
  p_title text,
  p_member_ids uuid[] default '{}'::uuid[]
)
returns uuid
language plpgsql
security definer
set search_path = public
set row_security = off
as $$
declare
  v_user_id uuid := auth.uid();
  v_conversation_id uuid;
  v_invite_count integer;
begin
  if v_user_id is null then
    raise exception 'You must be signed in';
  end if;

  if p_title is null or char_length(btrim(p_title)) not between 1 and 80 then
    raise exception 'Group name must be between 1 and 80 characters';
  end if;

  select count(distinct requested.user_id)
  into v_invite_count
  from unnest(coalesce(p_member_ids, '{}'::uuid[]))
    as requested(user_id)
  where requested.user_id is not null
    and requested.user_id <> v_user_id;

  if v_invite_count > 99 then
    raise exception 'A group can have at most 100 members';
  end if;

  insert into public.chat_conversations (kind, title, created_by)
  values ('group', btrim(p_title), v_user_id)
  returning id into v_conversation_id;

  insert into public.chat_members (conversation_id, user_id, role)
  values (v_conversation_id, v_user_id, 'admin');

  insert into public.chat_members (conversation_id, user_id, role)
  select v_conversation_id, requested.user_id, 'member'
  from (
    select distinct requested.user_id
    from unnest(coalesce(p_member_ids, '{}'::uuid[]))
      as requested(user_id)
    where requested.user_id is not null
      and requested.user_id <> v_user_id
  ) requested
  on conflict (conversation_id, user_id) do nothing;

  return v_conversation_id;
end;
$$;

create or replace function public.add_chat_group_members(
  p_conversation_id uuid,
  p_member_ids uuid[]
)
returns void
language plpgsql
security definer
set search_path = public
set row_security = off
as $$
declare
  v_kind text;
  v_existing_count integer;
  v_new_count integer;
begin
  if auth.uid() is null then
    raise exception 'You must be signed in';
  end if;

  if not public.is_chat_manager(p_conversation_id) then
    raise exception 'Only group admins can add members';
  end if;

  select c.kind into v_kind
  from public.chat_conversations c
  where c.id = p_conversation_id;

  if v_kind <> 'group' then
    raise exception 'Members can only be added to groups';
  end if;

  select count(*) into v_existing_count
  from public.chat_members m
  where m.conversation_id = p_conversation_id;

  select count(distinct requested.user_id) into v_new_count
  from unnest(coalesce(p_member_ids, '{}'::uuid[]))
    as requested(user_id)
  where requested.user_id is not null
    and not exists (
      select 1
      from public.chat_members m
      where m.conversation_id = p_conversation_id
        and m.user_id = requested.user_id
    );

  if v_existing_count + v_new_count > 100 then
    raise exception 'A group can have at most 100 members';
  end if;

  insert into public.chat_members (conversation_id, user_id, role)
  select p_conversation_id, requested.user_id, 'member'
  from (
    select distinct requested.user_id
    from unnest(coalesce(p_member_ids, '{}'::uuid[]))
      as requested(user_id)
    where requested.user_id is not null
  ) requested
  on conflict (conversation_id, user_id) do nothing;
end;
$$;

grant select, insert, update, delete
  on public.chat_conversations to authenticated;
grant select, insert, update, delete
  on public.chat_members to authenticated;
grant select, insert, delete
  on public.chat_messages to authenticated;
grant update (body)
  on public.chat_messages to authenticated;
grant select on public.chat_requests to authenticated;

revoke all on function public.is_chat_member(uuid, uuid) from public;
revoke all on function public.is_chat_manager(uuid, uuid) from public;
revoke all on function public.request_direct_chat(uuid) from public;
revoke all on function public.accept_chat_request(uuid) from public;
revoke all on function public.decline_chat_request(uuid) from public;
revoke all on function public.create_direct_chat(uuid) from public;
revoke all on function public.create_group_chat(text, uuid[]) from public;
revoke all on function public.add_chat_group_members(uuid, uuid[]) from public;

grant execute on function public.is_chat_member(uuid, uuid) to authenticated;
grant execute on function public.is_chat_manager(uuid, uuid) to authenticated;
grant execute on function public.request_direct_chat(uuid) to authenticated;
grant execute on function public.accept_chat_request(uuid) to authenticated;
grant execute on function public.decline_chat_request(uuid) to authenticated;
grant execute on function public.create_direct_chat(uuid) to authenticated;
grant execute on function public.create_group_chat(text, uuid[]) to authenticated;
grant execute on function public.add_chat_group_members(uuid, uuid[]) to authenticated;