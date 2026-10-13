-- =====================================================================
-- Dial Desk database setup
-- Paste this whole file into Supabase > SQL Editor > New query > Run.
-- Safe to run again later: it updates what is already there.
-- =====================================================================

create extension if not exists pgcrypto;
create extension if not exists pg_trgm;

-- ---------- People ----------------------------------------------------
create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  email text not null,
  full_name text not null default '',
  role text not null default 'caller' check (role in ('owner','admin','caller')),
  active boolean not null default true,
  created_at timestamptz not null default now()
);

-- Only invited emails can create an account (the very first account becomes the owner).
create table if not exists public.invites (
  email text primary key,
  role text not null default 'caller' check (role in ('admin','caller')),
  invited_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now()
);

-- ---------- Leads ------------------------------------------------------
create table if not exists public.leads (
  id uuid primary key default gen_random_uuid(),
  first_name text not null default '',
  last_name text not null default '',
  title text not null default '',
  company text not null default '',
  phone text not null default '',
  mobile text not null default '',
  company_phone text not null default '',
  email text not null default '',
  address text not null default '',
  city text not null default '',
  state text not null default '',
  zip text not null default '',
  industry text not null default '',
  website text not null default '',
  employees text not null default '',
  revenue text not null default '',
  linkedin text not null default '',
  zoominfo_id text not null default '',
  extra jsonb not null default '{}'::jsonb,
  status text not null default 'new'
    check (status in ('new','call1','call2','call3','gatekeeper','appointment','dead','bad_info')),
  owner_id uuid references public.profiles(id) on delete set null,
  attempts int not null default 0,
  last_call_at timestamptz,
  callback_at timestamptz,
  appt_at timestamptz,
  appt_rep text not null default '',
  appt_booked_by uuid references public.profiles(id) on delete set null,
  notes text not null default '',
  notes_by uuid references public.profiles(id) on delete set null,
  notes_at timestamptz,
  source text not null default '',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  phone_key text generated always as (right(regexp_replace(phone, '[^0-9]', '', 'g'), 10)) stored,
  mobile_key text generated always as (right(regexp_replace(mobile, '[^0-9]', '', 'g'), 10)) stored,
  email_key text generated always as (lower(btrim(email))) stored,
  search_text text generated always as (lower(
    company || ' ' || first_name || ' ' || last_name || ' ' || email || ' ' || title || ' ' || notes || ' ' ||
    regexp_replace(phone || ' ' || mobile || ' ' || company_phone, '[^0-9 ]', '', 'g'))) stored
);

create index if not exists leads_owner_status_idx on public.leads (owner_id, status);
create index if not exists leads_status_idx on public.leads (status);
create index if not exists leads_updated_idx on public.leads (updated_at desc);
create index if not exists leads_created_idx on public.leads (created_at);
create index if not exists leads_appt_idx on public.leads (appt_at) where status = 'appointment';
create index if not exists leads_phone_key_idx on public.leads (phone_key) where phone_key <> '';
create index if not exists leads_mobile_key_idx on public.leads (mobile_key) where mobile_key <> '';
create index if not exists leads_email_key_idx on public.leads (email_key) where email_key <> '';
create index if not exists leads_zoominfo_idx on public.leads (zoominfo_id) where zoominfo_id <> '';
create index if not exists leads_search_idx on public.leads using gin (search_text gin_trgm_ops);

-- ---------- Call log ---------------------------------------------------
create table if not exists public.calls (
  id bigint generated always as identity primary key,
  lead_id uuid references public.leads(id) on delete set null,
  caller_id uuid references public.profiles(id) on delete set null,
  status text not null,
  note text not null default '',
  created_at timestamptz not null default now()
);
create index if not exists calls_lead_idx on public.calls (lead_id, created_at desc);
create index if not exists calls_created_idx on public.calls (created_at);
create index if not exists calls_caller_idx on public.calls (caller_id, created_at);

-- ---------- Helpers ----------------------------------------------------
create or replace function public.touch_updated_at() returns trigger
language plpgsql as $$
begin
  new.updated_at := now();
  return new;
end $$;
drop trigger if exists leads_touch on public.leads;
create trigger leads_touch before update on public.leads
  for each row execute function public.touch_updated_at();

create or replace function public.is_member() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from profiles where id = auth.uid() and active)
$$;

create or replace function public.is_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from profiles where id = auth.uid() and active and role in ('owner','admin'))
$$;

create or replace function public.is_owner() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from profiles where id = auth.uid() and active and role = 'owner')
$$;

-- New sign-ups: first account is the owner; everyone else must be invited.
create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  inv public.invites%rowtype;
begin
  if not exists (select 1 from public.profiles) then
    insert into public.profiles (id, email, full_name, role)
    values (new.id, lower(new.email), coalesce(new.raw_user_meta_data->>'full_name', ''), 'owner');
    return new;
  end if;
  select * into inv from public.invites where email = lower(new.email);
  if not found then
    raise exception 'NOT_INVITED: % has not been invited to Dial Desk', new.email;
  end if;
  insert into public.profiles (id, email, full_name, role)
  values (new.id, lower(new.email), coalesce(new.raw_user_meta_data->>'full_name', ''), inv.role);
  delete from public.invites where email = lower(new.email);
  return new;
end $$;
drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users
  for each row execute function public.handle_new_user();

-- ---------- Security rules (row level security) ------------------------
alter table public.profiles enable row level security;
alter table public.invites enable row level security;
alter table public.leads enable row level security;
alter table public.calls enable row level security;

drop policy if exists "team reads profiles" on public.profiles;
create policy "team reads profiles" on public.profiles for select to authenticated using (public.is_member());

drop policy if exists "admins read invites" on public.invites;
create policy "admins read invites" on public.invites for select to authenticated using (public.is_admin());
drop policy if exists "admins create invites" on public.invites;
create policy "admins create invites" on public.invites for insert to authenticated
  with check (public.is_admin() and (role = 'caller' or public.is_owner()));
drop policy if exists "admins remove invites" on public.invites;
create policy "admins remove invites" on public.invites for delete to authenticated using (public.is_admin());

drop policy if exists "read leads" on public.leads;
create policy "read leads" on public.leads for select to authenticated
  using (public.is_admin() or (public.is_member() and owner_id = auth.uid()));
drop policy if exists "admins add leads" on public.leads;
create policy "admins add leads" on public.leads for insert to authenticated with check (public.is_admin());
drop policy if exists "update leads" on public.leads;
create policy "update leads" on public.leads for update to authenticated
  using (public.is_admin() or (public.is_member() and owner_id = auth.uid()))
  with check (public.is_admin() or (public.is_member() and owner_id = auth.uid()));
drop policy if exists "admins delete leads" on public.leads;
create policy "admins delete leads" on public.leads for delete to authenticated using (public.is_admin());

drop policy if exists "read calls" on public.calls;
create policy "read calls" on public.calls for select to authenticated
  using (public.is_admin() or (public.is_member() and (caller_id = auth.uid()
    or exists (select 1 from public.leads l where l.id = calls.lead_id and l.owner_id = auth.uid()))));
-- Calls are only written through log_call() below.

-- ---------- Actions ------------------------------------------------------
create or replace function public.log_call(
  p_lead uuid, p_status text, p_note text default '',
  p_callback timestamptz default null, p_appt_at timestamptz default null, p_appt_rep text default '')
returns void language plpgsql security definer set search_path = public as $$
declare
  l public.leads%rowtype;
begin
  if not public.is_member() then raise exception 'Please sign in again.'; end if;
  select * into l from public.leads where id = p_lead for update;
  if not found then raise exception 'That lead no longer exists.'; end if;
  if not (public.is_admin() or l.owner_id = auth.uid() or l.owner_id is null) then
    raise exception 'This lead belongs to another caller.';
  end if;
  if p_status not in ('call1','call2','call3','gatekeeper','appointment','dead','bad_info') then
    raise exception 'Unknown status.';
  end if;
  if p_status = 'appointment' and p_appt_at is null then
    raise exception 'Set the appointment date and time.';
  end if;
  update public.leads set
    status = p_status,
    attempts = attempts + 1,
    last_call_at = now(),
    callback_at = case when p_status in ('call1','call2','call3','gatekeeper') then p_callback else null end,
    appt_at = case when p_status = 'appointment' then p_appt_at else appt_at end,
    appt_rep = case when p_status = 'appointment' then coalesce(p_appt_rep, '') else appt_rep end,
    appt_booked_by = case when p_status = 'appointment' then auth.uid() else appt_booked_by end,
    owner_id = coalesce(owner_id, auth.uid())
  where id = p_lead;
  insert into public.calls (lead_id, caller_id, status, note)
  values (p_lead, auth.uid(), p_status, coalesce(p_note, ''));
end $$;

create or replace function public.pull_leads(p_n int default 25) returns int
language plpgsql security definer set search_path = public as $$
declare
  n int;
begin
  if not public.is_member() then raise exception 'Please sign in again.'; end if;
  with picked as (
    select id from public.leads
    where owner_id is null and status = 'new'
    order by created_at, id
    limit least(greatest(coalesce(p_n, 25), 1), 100)
    for update skip locked)
  update public.leads set owner_id = auth.uid() where id in (select id from picked);
  get diagnostics n = row_count;
  return n;
end $$;

create or replace function public.unassigned_count() returns int
language sql stable security definer set search_path = public as $$
  select case when public.is_member()
    then (select count(*)::int from public.leads where owner_id is null and status = 'new') else 0 end
$$;

-- Runs with the caller's own permissions, so callers only count their own leads.
create or replace function public.status_counts(p_owner uuid default null, p_unassigned boolean default false, p_search text default '')
returns table (status text, n bigint) language sql stable set search_path = public as $$
  select l.status, count(*) from public.leads l
  where (p_owner is null or l.owner_id = p_owner)
    and (not coalesce(p_unassigned, false) or l.owner_id is null)
    and (coalesce(p_search, '') = '' or l.search_text like '%' || p_search || '%')
  group by l.status
$$;

create or replace function public.team_stats(p_since timestamptz)
returns table (caller_id uuid, calls bigint, gatekeeper bigint, appointments bigint, dead bigint, bad_info bigint)
language sql stable set search_path = public as $$
  select c.caller_id, count(*),
    count(*) filter (where c.status = 'gatekeeper'),
    count(*) filter (where c.status = 'appointment'),
    count(*) filter (where c.status = 'dead'),
    count(*) filter (where c.status = 'bad_info')
  from public.calls c where c.created_at >= p_since group by c.caller_id
$$;

create or replace function public.import_leads(p_rows jsonb, p_owner uuid default null, p_source text default '')
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  r jsonb; ins int := 0; dup int := 0;
  pk text; mk text; ek text; zk text;
begin
  if not public.is_admin() then raise exception 'Only admins can import leads.'; end if;
  for r in select * from jsonb_array_elements(p_rows) loop
    pk := right(regexp_replace(coalesce(r->>'phone', ''), '[^0-9]', '', 'g'), 10);
    mk := right(regexp_replace(coalesce(r->>'mobile', ''), '[^0-9]', '', 'g'), 10);
    ek := lower(btrim(coalesce(r->>'email', '')));
    zk := btrim(coalesce(r->>'zoominfo_id', ''));
    if exists (select 1 from public.leads l where
         (length(pk) = 10 and (l.phone_key = pk or l.mobile_key = pk))
      or (length(mk) = 10 and (l.phone_key = mk or l.mobile_key = mk))
      or (ek <> '' and l.email_key = ek)
      or (zk <> '' and l.zoominfo_id = zk)) then
      dup := dup + 1;
      continue;
    end if;
    insert into public.leads (first_name, last_name, title, company, phone, mobile, company_phone, email,
      address, city, state, zip, industry, website, employees, revenue, linkedin, zoominfo_id, extra, owner_id, source)
    values (coalesce(r->>'first_name',''), coalesce(r->>'last_name',''), coalesce(r->>'title',''), coalesce(r->>'company',''),
      coalesce(r->>'phone',''), coalesce(r->>'mobile',''), coalesce(r->>'company_phone',''), coalesce(r->>'email',''),
      coalesce(r->>'address',''), coalesce(r->>'city',''), coalesce(r->>'state',''), coalesce(r->>'zip',''),
      coalesce(r->>'industry',''), coalesce(r->>'website',''), coalesce(r->>'employees',''), coalesce(r->>'revenue',''),
      coalesce(r->>'linkedin',''), zk, coalesce(r->'extra', '{}'::jsonb), p_owner, coalesce(p_source, ''));
    ins := ins + 1;
  end loop;
  return jsonb_build_object('inserted', ins, 'duplicates', dup);
end $$;

create or replace function public.set_member(p_user uuid, p_role text, p_active boolean) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_owner() then raise exception 'Only the owner can change roles.'; end if;
  if p_user = auth.uid() then raise exception 'You can''t change your own role.'; end if;
  if p_role not in ('admin','caller') then raise exception 'Unknown role.'; end if;
  update public.profiles set role = p_role, active = coalesce(p_active, true) where id = p_user;
end $$;

create or replace function public.set_my_name(p_name text) returns void
language plpgsql security definer set search_path = public as $$
begin
  update public.profiles set full_name = left(btrim(coalesce(p_name, '')), 80) where id = auth.uid();
end $$;

create or replace function public.storage_used() returns bigint
language sql stable security definer set search_path = public as $$
  select case when public.is_admin() then pg_database_size(current_database()) else 0 end
$$;

-- Lock the helper actions to signed-in users.
revoke execute on function public.log_call(uuid, text, text, timestamptz, timestamptz, text) from anon;
revoke execute on function public.pull_leads(int) from anon;
revoke execute on function public.import_leads(jsonb, uuid, text) from anon;
revoke execute on function public.set_member(uuid, text, boolean) from anon;
revoke execute on function public.set_my_name(text) from anon;
revoke execute on function public.storage_used() from anon;
