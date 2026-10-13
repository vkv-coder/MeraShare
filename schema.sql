-- MeraShare (merashare.in) — expense splitting PWA
-- Project: rotry_event (wrzpgultvahxbrgooibn.supabase.co), public schema, ms_ prefix.
-- Run via: supabase db query --linked -o json "$(cat schema.sql)"  (or psql)

-- ============================================================
-- TABLES
-- ============================================================

create table if not exists ms_groups (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  invite_code text not null unique,
  created_by uuid not null references auth.users(id),
  base_currency text not null default 'INR',
  created_at timestamptz not null default now()
);

create table if not exists ms_group_members (
  id uuid primary key default gen_random_uuid(),
  group_id uuid not null references ms_groups(id) on delete cascade,
  user_id uuid references auth.users(id),
  invited_email text,
  display_name text not null,
  joined_at timestamptz not null default now(),
  hidden boolean not null default false,
  constraint ms_member_identity check (user_id is not null or invited_email is not null),
  constraint ms_member_user_unique unique (group_id, user_id),
  constraint ms_member_email_unique unique (group_id, invited_email)
);

create table if not exists ms_expenses (
  id uuid primary key default gen_random_uuid(),
  group_id uuid not null references ms_groups(id) on delete cascade,
  description text not null,
  amount numeric(12,2) not null check (amount > 0),
  paid_by_member uuid not null references ms_group_members(id),
  created_by uuid not null references auth.users(id),
  category text not null default 'general',
  reference_note text,
  currency text not null default 'INR',
  fx_rate numeric not null default 1,
  foreign_amount numeric,
  receipt_path text,
  created_at timestamptz not null default now()
);

create table if not exists ms_expense_splits (
  id uuid primary key default gen_random_uuid(),
  expense_id uuid not null references ms_expenses(id) on delete cascade,
  group_id uuid not null references ms_groups(id) on delete cascade,
  member_id uuid not null references ms_group_members(id),
  share_amount numeric(12,2) not null check (share_amount >= 0)
);

create table if not exists ms_settlements (
  id uuid primary key default gen_random_uuid(),
  group_id uuid not null references ms_groups(id) on delete cascade,
  from_member uuid not null references ms_group_members(id),
  to_member uuid not null references ms_group_members(id),
  amount numeric(12,2) not null check (amount > 0),
  note text,
  created_by uuid not null references auth.users(id),
  created_at timestamptz not null default now()
);

create table if not exists ms_demo_visitors (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  phone text not null,
  created_at timestamptz not null default now()
);

create index if not exists ms_group_members_group_idx on ms_group_members(group_id);
create index if not exists ms_expenses_group_idx on ms_expenses(group_id);
create index if not exists ms_expense_splits_group_idx on ms_expense_splits(group_id);
create index if not exists ms_expense_splits_expense_idx on ms_expense_splits(expense_id);
create index if not exists ms_settlements_group_idx on ms_settlements(group_id);

-- ============================================================
-- RLS — enable on everything, direct client access is read-only
-- (all writes go through SECURITY DEFINER RPCs below)
-- ============================================================

alter table ms_groups enable row level security;
alter table ms_group_members enable row level security;
alter table ms_expenses enable row level security;
alter table ms_expense_splits enable row level security;
alter table ms_settlements enable row level security;
alter table ms_demo_visitors enable row level security;

revoke all on ms_groups, ms_group_members, ms_expenses, ms_expense_splits, ms_settlements, ms_demo_visitors
  from anon, authenticated;
grant select on ms_groups, ms_group_members, ms_expenses, ms_expense_splits, ms_settlements to authenticated;
grant insert on ms_demo_visitors to anon, authenticated;

-- Membership check as SECURITY DEFINER to avoid RLS self-recursion on ms_group_members.
create or replace function ms_is_group_member(p_group_id uuid)
returns boolean
language sql
security definer
set search_path = public
stable
as $$
  select exists (
    select 1 from ms_group_members
    where group_id = p_group_id and user_id = auth.uid()
  );
$$;

revoke all on function ms_is_group_member(uuid) from public;
grant execute on function ms_is_group_member(uuid) to authenticated;

create policy ms_groups_select on ms_groups
  for select to authenticated
  using (ms_is_group_member(id));

create policy ms_group_members_select on ms_group_members
  for select to authenticated
  using (ms_is_group_member(group_id));

create policy ms_expenses_select on ms_expenses
  for select to authenticated
  using (ms_is_group_member(group_id));

create policy ms_expense_splits_select on ms_expense_splits
  for select to authenticated
  using (ms_is_group_member(group_id));

create policy ms_settlements_select on ms_settlements
  for select to authenticated
  using (ms_is_group_member(group_id));

create policy ms_demo_visitors_insert on ms_demo_visitors
  for insert to anon, authenticated
  with check (true);

-- ============================================================
-- RPCs (all SECURITY DEFINER, all re-check auth.uid() membership themselves)
-- ============================================================

create or replace function ms_create_group(p_name text, p_display_name text, p_base_currency text default 'INR')
returns ms_groups
language plpgsql
security definer
set search_path = public
as $$
declare
  v_group ms_groups;
  v_code text;
begin
  if auth.uid() is null then
    raise exception 'auth required';
  end if;
  if auth.uid() = 'd4d40ce6-439e-4340-bc92-600a5c0891bb' then
    raise exception 'the shared demo account cannot create new groups';
  end if;
  if coalesce(trim(p_name), '') = '' then
    raise exception 'group name required';
  end if;

  loop
    v_code := upper(substr(md5(random()::text || clock_timestamp()::text), 1, 8));
    begin
      insert into ms_groups (name, invite_code, created_by, base_currency)
      values (trim(p_name), v_code, auth.uid(), coalesce(nullif(trim(upper(p_base_currency)), ''), 'INR'))
      returning * into v_group;
      exit;
    exception when unique_violation then
      -- invite_code collision, retry
    end;
  end loop;

  insert into ms_group_members (group_id, user_id, display_name)
  values (v_group.id, auth.uid(), coalesce(trim(p_display_name), 'Me'));

  return v_group;
end;
$$;

create or replace function ms_join_group(p_invite_code text, p_display_name text)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_group_id uuid;
  v_my_email text;
  v_untagged_email text;
begin
  if auth.uid() is null then
    raise exception 'auth required';
  end if;
  if auth.uid() = 'd4d40ce6-439e-4340-bc92-600a5c0891bb' then
    raise exception 'the shared demo account cannot join other groups';
  end if;

  select id into v_group_id from ms_groups where invite_code = upper(trim(p_invite_code));
  if v_group_id is null then
    raise exception 'invalid invite code';
  end if;

  if exists (select 1 from ms_group_members where group_id = v_group_id and user_id = auth.uid()) then
    update ms_group_members set hidden = false where group_id = v_group_id and user_id = auth.uid();
    return v_group_id;
  end if;

  select email into v_my_email from auth.users where id = auth.uid();
  v_untagged_email := regexp_replace(lower(coalesce(v_my_email, '')), '\+[^@]+@', '@');

  update ms_group_members
  set user_id = auth.uid()
  where group_id = v_group_id
    and user_id is null
    and lower(invited_email) = v_untagged_email;

  if not exists (select 1 from ms_group_members where group_id = v_group_id and user_id = auth.uid()) then
    insert into ms_group_members (group_id, user_id, display_name)
    values (v_group_id, auth.uid(), coalesce(trim(p_display_name), 'Me'));
  end if;

  return v_group_id;
end;
$$;

create or replace function ms_add_member(p_group_id uuid, p_email text, p_display_name text)
returns ms_group_members
language plpgsql
security definer
set search_path = public
as $$
declare
  v_row ms_group_members;
  v_clean_email text;
begin
  if not ms_is_group_member(p_group_id) then
    raise exception 'not a member of this group';
  end if;
  v_clean_email := lower(trim(p_email));
  if v_clean_email = '' then
    raise exception 'email required';
  end if;

  select * into v_row from ms_group_members
  where group_id = p_group_id and lower(invited_email) = v_clean_email;
  if found then
    return v_row;
  end if;

  insert into ms_group_members (group_id, invited_email, display_name)
  values (p_group_id, v_clean_email, coalesce(trim(p_display_name), split_part(v_clean_email, '@', 1)))
  returning * into v_row;

  return v_row;
end;
$$;

create or replace function ms_claim_pending_memberships()
returns int
language plpgsql
security definer
set search_path = public
as $$
declare
  v_my_email text;
  v_untagged_email text;
  v_count int;
begin
  if auth.uid() is null then
    raise exception 'auth required';
  end if;

  select email into v_my_email from auth.users where id = auth.uid();
  v_untagged_email := regexp_replace(lower(coalesce(v_my_email, '')), '\+[^@]+@', '@');

  update ms_group_members
  set user_id = auth.uid()
  where user_id is null
    and lower(invited_email) = v_untagged_email
    and not exists (
      select 1 from ms_group_members m2
      where m2.group_id = ms_group_members.group_id and m2.user_id = auth.uid()
    );

  get diagnostics v_count = row_count;
  return v_count;
end;
$$;

create or replace function ms_add_expense(
  p_group_id uuid,
  p_description text,
  p_amount numeric,
  p_paid_by_member uuid,
  p_category text,
  p_splits jsonb,
  p_reference_note text default null,
  p_currency text default 'INR',
  p_fx_rate numeric default 1,
  p_foreign_amount numeric default null,
  p_receipt_path text default null
)
returns ms_expenses
language plpgsql
security definer
set search_path = public
as $$
declare
  v_expense ms_expenses;
  v_split jsonb;
  v_sum numeric := 0;
  v_member_id uuid;
  v_share numeric;
begin
  if not ms_is_group_member(p_group_id) then
    raise exception 'not a member of this group';
  end if;
  if coalesce(trim(p_description), '') = '' then
    raise exception 'description required';
  end if;
  if p_amount is null or p_amount <= 0 then
    raise exception 'amount must be positive';
  end if;
  if not exists (select 1 from ms_group_members where id = p_paid_by_member and group_id = p_group_id) then
    raise exception 'paid_by member not in this group';
  end if;
  if jsonb_array_length(p_splits) = 0 then
    raise exception 'at least one split required';
  end if;

  for v_split in select * from jsonb_array_elements(p_splits) loop
    v_member_id := (v_split->>'member_id')::uuid;
    v_share := (v_split->>'share_amount')::numeric;
    if v_share is null or v_share < 0 then
      raise exception 'invalid share amount';
    end if;
    if not exists (select 1 from ms_group_members where id = v_member_id and group_id = p_group_id) then
      raise exception 'split member not in this group';
    end if;
    v_sum := v_sum + v_share;
  end loop;

  if abs(v_sum - p_amount) > 0.05 then
    raise exception 'splits (%) do not add up to amount (%)', v_sum, p_amount;
  end if;

  insert into ms_expenses (group_id, description, amount, paid_by_member, created_by, category, reference_note, currency, fx_rate, foreign_amount, receipt_path)
  values (p_group_id, trim(p_description), p_amount, p_paid_by_member, auth.uid(), coalesce(trim(p_category), 'general'), nullif(trim(p_reference_note), ''),
          coalesce(nullif(trim(p_currency), ''), 'INR'), coalesce(p_fx_rate, 1), p_foreign_amount, p_receipt_path)
  returning * into v_expense;

  for v_split in select * from jsonb_array_elements(p_splits) loop
    insert into ms_expense_splits (expense_id, group_id, member_id, share_amount)
    values (
      v_expense.id,
      p_group_id,
      (v_split->>'member_id')::uuid,
      (v_split->>'share_amount')::numeric
    );
  end loop;

  return v_expense;
end;
$$;

create or replace function ms_update_expense(
  p_expense_id uuid,
  p_description text,
  p_amount numeric,
  p_paid_by_member uuid,
  p_category text,
  p_splits jsonb,
  p_reference_note text default null,
  p_currency text default 'INR',
  p_fx_rate numeric default 1,
  p_foreign_amount numeric default null,
  p_receipt_path text default null
)
returns ms_expenses
language plpgsql
security definer
set search_path = public
as $$
declare
  v_expense ms_expenses;
  v_group_id uuid;
  v_split jsonb;
  v_sum numeric := 0;
  v_member_id uuid;
  v_share numeric;
begin
  select group_id into v_group_id from ms_expenses where id = p_expense_id and created_by = auth.uid();
  if v_group_id is null then
    raise exception 'expense not found or not yours to edit';
  end if;
  if coalesce(trim(p_description), '') = '' then
    raise exception 'description required';
  end if;
  if p_amount is null or p_amount <= 0 then
    raise exception 'amount must be positive';
  end if;
  if not exists (select 1 from ms_group_members where id = p_paid_by_member and group_id = v_group_id) then
    raise exception 'paid_by member not in this group';
  end if;
  if jsonb_array_length(p_splits) = 0 then
    raise exception 'at least one split required';
  end if;

  for v_split in select * from jsonb_array_elements(p_splits) loop
    v_member_id := (v_split->>'member_id')::uuid;
    v_share := (v_split->>'share_amount')::numeric;
    if v_share is null or v_share < 0 then
      raise exception 'invalid share amount';
    end if;
    if not exists (select 1 from ms_group_members where id = v_member_id and group_id = v_group_id) then
      raise exception 'split member not in this group';
    end if;
    v_sum := v_sum + v_share;
  end loop;

  if abs(v_sum - p_amount) > 0.05 then
    raise exception 'splits (%) do not add up to amount (%)', v_sum, p_amount;
  end if;

  update ms_expenses
  set description = trim(p_description),
      amount = p_amount,
      paid_by_member = p_paid_by_member,
      category = coalesce(trim(p_category), 'general'),
      reference_note = nullif(trim(p_reference_note), ''),
      currency = coalesce(nullif(trim(p_currency), ''), 'INR'),
      fx_rate = coalesce(p_fx_rate, 1),
      foreign_amount = p_foreign_amount,
      receipt_path = p_receipt_path
  where id = p_expense_id
  returning * into v_expense;

  delete from ms_expense_splits where expense_id = p_expense_id;

  for v_split in select * from jsonb_array_elements(p_splits) loop
    insert into ms_expense_splits (expense_id, group_id, member_id, share_amount)
    values (
      p_expense_id,
      v_group_id,
      (v_split->>'member_id')::uuid,
      (v_split->>'share_amount')::numeric
    );
  end loop;

  return v_expense;
end;
$$;

create or replace function ms_delete_expense(p_expense_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  delete from ms_expenses
  where id = p_expense_id and created_by = auth.uid();

  if not found then
    raise exception 'expense not found or not yours to delete';
  end if;
end;
$$;

create or replace function ms_record_settlement(
  p_group_id uuid,
  p_from_member uuid,
  p_to_member uuid,
  p_amount numeric,
  p_note text
)
returns ms_settlements
language plpgsql
security definer
set search_path = public
as $$
declare
  v_row ms_settlements;
begin
  if not ms_is_group_member(p_group_id) then
    raise exception 'not a member of this group';
  end if;
  if p_amount is null or p_amount <= 0 then
    raise exception 'amount must be positive';
  end if;
  if p_from_member = p_to_member then
    raise exception 'from and to must differ';
  end if;
  if not exists (select 1 from ms_group_members where id = p_from_member and group_id = p_group_id) then
    raise exception 'from_member not in this group';
  end if;
  if not exists (select 1 from ms_group_members where id = p_to_member and group_id = p_group_id) then
    raise exception 'to_member not in this group';
  end if;

  insert into ms_settlements (group_id, from_member, to_member, amount, note, created_by)
  values (p_group_id, p_from_member, p_to_member, p_amount, p_note, auth.uid())
  returning * into v_row;

  return v_row;
end;
$$;

create or replace function ms_group_balances(p_group_id uuid)
returns table (member_id uuid, display_name text, net_balance numeric)
language sql
security definer
set search_path = public
stable
as $$
  select
    m.id as member_id,
    m.display_name,
    round(
      coalesce((select sum(e.amount) from ms_expenses e where e.paid_by_member = m.id), 0)
      - coalesce((select sum(s.share_amount) from ms_expense_splits s where s.member_id = m.id), 0)
      - coalesce((select sum(t.amount) from ms_settlements t where t.to_member = m.id), 0)
      + coalesce((select sum(t.amount) from ms_settlements t where t.from_member = m.id), 0)
    , 2) as net_balance
  from ms_group_members m
  where m.group_id = p_group_id
    and ms_is_group_member(p_group_id);
$$;

create or replace function ms_my_groups_summary()
returns table (group_id uuid, name text, invite_code text, my_net_balance numeric, base_currency text)
language sql
security definer
set search_path = public
stable
as $$
  select
    g.id as group_id,
    g.name,
    g.invite_code,
    coalesce((
      select net_balance from ms_group_balances(g.id) b
      join ms_group_members me on me.id = b.member_id
      where me.user_id = auth.uid()
    ), 0) as my_net_balance,
    g.base_currency
  from ms_groups g
  join ms_group_members me2 on me2.group_id = g.id and me2.user_id = auth.uid()
  where ms_is_group_member(g.id)
    and coalesce(me2.hidden, false) = false
  order by g.created_at desc;
$$;

-- Hides a group from the caller's own lists only (dashboard/trip/activity) --
-- does not touch shared data, other members keep seeing everything normally.
-- Rejoining via the invite code (ms_join_group) clears this back to visible.
create or replace function ms_hide_group(p_group_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  update ms_group_members
  set hidden = true
  where group_id = p_group_id and user_id = auth.uid();

  if not found then
    raise exception 'not a member of this group';
  end if;
end;
$$;

-- Derived activity feed (no separate log table) -- unions group-creation,
-- expense, and settlement events across every non-hidden group the caller
-- belongs to, newest first.
create or replace function ms_my_activity()
returns table (occurred_at timestamptz, group_id uuid, group_name text, kind text, detail text, amount numeric)
language sql
security definer
set search_path = public
stable
as $$
  select * from (
    select g.created_at as occurred_at, g.id as group_id, g.name as group_name,
      'group_created'::text as kind,
      'Created the trip "' || g.name || '"' as detail,
      null::numeric as amount
    from ms_groups g
    join ms_group_members me on me.group_id = g.id and me.user_id = auth.uid()
    where coalesce(me.hidden, false) = false

    union all

    select e.created_at, g.id, g.name,
      'expense_added',
      pm.display_name || ' paid ' || to_char(e.amount, 'FM999999999.00') || ' for "' || e.description || '"',
      e.amount
    from ms_expenses e
    join ms_groups g on g.id = e.group_id
    join ms_group_members me on me.group_id = g.id and me.user_id = auth.uid()
    join ms_group_members pm on pm.id = e.paid_by_member
    where coalesce(me.hidden, false) = false

    union all

    select t.created_at, g.id, g.name,
      'settlement',
      fm.display_name || ' paid ' || tm.display_name || ' ' || to_char(t.amount, 'FM999999999.00'),
      t.amount
    from ms_settlements t
    join ms_groups g on g.id = t.group_id
    join ms_group_members me on me.group_id = g.id and me.user_id = auth.uid()
    join ms_group_members fm on fm.id = t.from_member
    join ms_group_members tm on tm.id = t.to_member
    where coalesce(me.hidden, false) = false
  ) u
  order by occurred_at desc
  limit 200;
$$;

-- Per-counterparty balances from the caller's own point of view within a group:
-- positive amount = other_member owes the caller; negative = caller owes other_member.
-- This is what a Splitwise-style "X owes you / you owe Y" breakdown needs -- a single
-- aggregate net_balance (ms_group_balances) correctly nets everyone together, but
-- can't answer "does Rahul specifically still owe me the same amount" once Rahul
-- also has an unrelated debt with a third member.
create or replace function ms_pairwise_balances(p_group_id uuid)
returns table (other_member_id uuid, other_display_name text, amount numeric)
language sql
security definer
set search_path = public
stable
as $$
  select
    o.id as other_member_id,
    o.display_name as other_display_name,
    round(
      coalesce((select sum(s.share_amount) from ms_expense_splits s
                join ms_expenses e on e.id = s.expense_id
                where s.member_id = o.id and e.paid_by_member = c.id), 0)
      - coalesce((select sum(s.share_amount) from ms_expense_splits s
                  join ms_expenses e on e.id = s.expense_id
                  where s.member_id = c.id and e.paid_by_member = o.id), 0)
      + coalesce((select sum(t.amount) from ms_settlements t where t.from_member = c.id and t.to_member = o.id), 0)
      - coalesce((select sum(t.amount) from ms_settlements t where t.from_member = o.id and t.to_member = c.id), 0)
    , 2) as amount
  from ms_group_members c
  cross join ms_group_members o
  where c.group_id = p_group_id and o.group_id = p_group_id
    and c.user_id = auth.uid()
    and o.id != c.id
    and ms_is_group_member(p_group_id);
$$;

revoke all on function
  ms_create_group(text, text, text),
  ms_join_group(text, text),
  ms_add_member(uuid, text, text),
  ms_claim_pending_memberships(),
  ms_add_expense(uuid, text, numeric, uuid, text, jsonb, text, text, numeric, numeric, text),
  ms_update_expense(uuid, text, numeric, uuid, text, jsonb, text, text, numeric, numeric, text),
  ms_delete_expense(uuid),
  ms_record_settlement(uuid, uuid, uuid, numeric, text),
  ms_group_balances(uuid),
  ms_pairwise_balances(uuid),
  ms_my_groups_summary(),
  ms_hide_group(uuid),
  ms_my_activity()
from public;

grant execute on function
  ms_create_group(text, text, text),
  ms_join_group(text, text),
  ms_add_member(uuid, text, text),
  ms_claim_pending_memberships(),
  ms_add_expense(uuid, text, numeric, uuid, text, jsonb, text, text, numeric, numeric, text),
  ms_update_expense(uuid, text, numeric, uuid, text, jsonb, text, text, numeric, numeric, text),
  ms_delete_expense(uuid),
  ms_record_settlement(uuid, uuid, uuid, numeric, text),
  ms_group_balances(uuid),
  ms_pairwise_balances(uuid),
  ms_my_groups_summary(),
  ms_hide_group(uuid),
  ms_my_activity()
to authenticated;

-- ============================================================
-- Trip photo gallery (storage bucket + metadata table + RPCs)
-- ============================================================

insert into storage.buckets (id, name, public)
values ('ms-trip-photos', 'ms-trip-photos', true)
on conflict (id) do nothing;

drop policy if exists "ms_trip_photos_select_public" on storage.objects;
create policy "ms_trip_photos_select_public" on storage.objects
  for select using (bucket_id = 'ms-trip-photos');

-- Upload path convention: {group_id}/{uuid}.{ext} -- this policy checks the
-- first path segment against the group the uploader is actually a member of.
drop policy if exists "ms_trip_photos_insert_members" on storage.objects;
create policy "ms_trip_photos_insert_members" on storage.objects
  for insert with check (
    bucket_id = 'ms-trip-photos'
    and auth.role() = 'authenticated'
    and exists (
      select 1 from ms_group_members gm
      where gm.user_id = auth.uid()
        and gm.group_id::text = (storage.foldername(name))[1]
    )
  );

drop policy if exists "ms_trip_photos_delete_own" on storage.objects;
create policy "ms_trip_photos_delete_own" on storage.objects
  for delete using (
    bucket_id = 'ms-trip-photos'
    and owner = auth.uid()
  );

create table if not exists ms_trip_photos (
  id uuid primary key default gen_random_uuid(),
  group_id uuid not null references ms_groups(id) on delete cascade,
  uploaded_by uuid not null references auth.users(id),
  storage_path text not null,
  caption text,
  created_at timestamptz not null default now()
);

alter table ms_trip_photos enable row level security;
revoke all on ms_trip_photos from anon, authenticated;
grant select on ms_trip_photos to authenticated;

drop policy if exists ms_trip_photos_select on ms_trip_photos;
create policy ms_trip_photos_select on ms_trip_photos
  for select to authenticated using (ms_is_group_member(group_id));

create or replace function ms_add_trip_photo(p_group_id uuid, p_storage_path text, p_caption text default null)
returns ms_trip_photos
language plpgsql
security definer
set search_path = public
as $$
declare
  v_row ms_trip_photos;
begin
  if not ms_is_group_member(p_group_id) then
    raise exception 'not a member of this group';
  end if;
  insert into ms_trip_photos (group_id, uploaded_by, storage_path, caption)
  values (p_group_id, auth.uid(), p_storage_path, nullif(trim(p_caption), ''))
  returning * into v_row;
  return v_row;
end;
$$;

-- Deletes the metadata row only; the client removes the storage object
-- itself first (storage's own delete-own policy covers that call).
create or replace function ms_delete_trip_photo(p_photo_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  delete from ms_trip_photos where id = p_photo_id and uploaded_by = auth.uid();
  if not found then
    raise exception 'photo not found or not yours to delete';
  end if;
end;
$$;

revoke all on function ms_add_trip_photo(uuid, text, text), ms_delete_trip_photo(uuid) from public;
grant execute on function ms_add_trip_photo(uuid, text, text), ms_delete_trip_photo(uuid) to authenticated;
