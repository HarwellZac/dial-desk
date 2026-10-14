-- =====================================================================
-- Dial Desk database setup  (version 5: editable notes, On Ice status, follow-up dates, multiple contacts)
-- Paste this whole file into Supabase > SQL Editor > New query > Run.
-- Safe to run again: it creates what is missing and updates the rest.
-- Your leads, calls and people are kept.
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

-- Version 3: salesperson role
alter table public.profiles drop constraint if exists profiles_role_check;
alter table public.profiles add constraint profiles_role_check check (role in ('owner','admin','salesperson','caller'));
alter table public.invites drop constraint if exists invites_role_check;
alter table public.invites add constraint invites_role_check check (role in ('admin','salesperson','caller'));

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

-- Version 2 additions (added to existing databases too)
alter table public.leads add column if not exists deleted_at timestamptz;
alter table public.leads add column if not exists deleted_by uuid references public.profiles(id) on delete set null;
-- Version 3 additions: conversion to an opportunity, last edited by
alter table public.leads drop constraint if exists leads_status_check;
alter table public.leads add constraint leads_status_check
  check (status in ('new','call1','call2','call3','on_ice','gatekeeper','appointment','converted','dead','bad_info'));
alter table public.leads add column if not exists sales_owner_id uuid references public.profiles(id) on delete set null;
alter table public.leads add column if not exists opportunity_id uuid;
alter table public.leads add column if not exists converted_at timestamptz;
alter table public.leads add column if not exists converted_by uuid references public.profiles(id) on delete set null;
alter table public.leads add column if not exists pre_convert_status text;
alter table public.leads add column if not exists updated_by uuid references public.profiles(id) on delete set null;
alter table public.leads drop column if exists status_rank;
alter table public.leads add column status_rank int generated always as (
  case status when 'new' then 1 when 'call1' then 2 when 'call2' then 3 when 'call3' then 4 when 'on_ice' then 5
    when 'gatekeeper' then 6 when 'appointment' then 7 when 'converted' then 8 when 'bad_info' then 9 when 'dead' then 10 else 11 end) stored;
create index if not exists leads_sales_owner_idx on public.leads (sales_owner_id) where sales_owner_id is not null;

create index if not exists leads_owner_status_idx on public.leads (owner_id, status);
create index if not exists leads_status_idx on public.leads (status);
create index if not exists leads_updated_idx on public.leads (updated_at desc);
create index if not exists leads_created_idx on public.leads (created_at);
create index if not exists leads_last_call_idx on public.leads (last_call_at desc nulls last);
create index if not exists leads_deleted_idx on public.leads (deleted_at) where deleted_at is not null;
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
alter table public.calls add column if not exists prev jsonb;  -- lead state before the call, for Undo
create index if not exists calls_lead_idx on public.calls (lead_id, created_at desc);
create index if not exists calls_created_idx on public.calls (created_at);
create index if not exists calls_caller_idx on public.calls (caller_id, created_at);

-- ---------- Notes (dated comments on a lead) ----------------------------
create table if not exists public.lead_notes (
  id bigint generated always as identity primary key,
  lead_id uuid not null references public.leads(id) on delete cascade,
  author_id uuid references public.profiles(id) on delete set null default auth.uid(),
  body text not null check (length(btrim(body)) > 0),
  created_at timestamptz not null default now()
);
create index if not exists lead_notes_lead_idx on public.lead_notes (lead_id, created_at desc);

-- ---------- Helpers ----------------------------------------------------
create or replace function public.touch_updated_at() returns trigger
language plpgsql as $$
begin
  new.updated_at := now();
  new.updated_by := coalesce(auth.uid(), new.updated_by);
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

create or replace function public.is_sales() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from profiles where id = auth.uid() and active and role = 'salesperson')
$$;

-- Salespeople, admins and the owner: see every lead and opportunity, see reports.
create or replace function public.can_sell() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from profiles where id = auth.uid() and active and role in ('owner','admin','salesperson'))
$$;

-- Only admins may move leads to or from the trash.
create or replace function public.guard_leads() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if (new.deleted_at is distinct from old.deleted_at) and auth.uid() is not null and not public.is_admin() then
    raise exception 'Only admins can delete or restore leads.';
  end if;
  if coalesce(current_setting('dialdesk.bypass', true), '') <> 'on' and auth.uid() is not null and not public.is_admin()
     and (new.sales_owner_id is distinct from old.sales_owner_id or new.opportunity_id is distinct from old.opportunity_id
          or new.converted_at is distinct from old.converted_at
          or (new.status = 'converted') is distinct from (old.status = 'converted')) then
    raise exception 'Use the Convert lead button to convert leads.';
  end if;
  return new;
end $$;
drop trigger if exists leads_guard on public.leads;
create trigger leads_guard before update on public.leads
  for each row execute function public.guard_leads();

-- Keep the lead's "latest note" (shown on the Lead board and searchable) in step with its notes.
create or replace function public.refresh_latest_note() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  lid uuid;
  n record;
begin
  if tg_op = 'DELETE' then lid := old.lead_id; else lid := new.lead_id; end if;
  select body, author_id, created_at into n from public.lead_notes
    where lead_id = lid and deleted_at is null order by created_at desc, id desc limit 1;
  update public.leads set notes = coalesce(n.body, ''), notes_by = n.author_id, notes_at = n.created_at
    where id = lid and (notes, notes_by, notes_at) is distinct from (coalesce(n.body, ''), n.author_id, n.created_at);
  return null;
end $$;
drop trigger if exists lead_notes_latest on public.lead_notes;
create trigger lead_notes_latest after insert or update or delete on public.lead_notes
  for each row execute function public.refresh_latest_note();

-- Move notes written in version 1 into the dated notes timeline (runs once per lead).
insert into public.lead_notes (lead_id, author_id, body, created_at)
select l.id, l.notes_by, l.notes, coalesce(l.notes_at, l.updated_at)
from public.leads l
where btrim(l.notes) <> '' and not exists (select 1 from public.lead_notes n where n.lead_id = l.id);

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
alter table public.lead_notes enable row level security;

drop policy if exists "team reads profiles" on public.profiles;
create policy "team reads profiles" on public.profiles for select to authenticated using (public.is_member());

drop policy if exists "admins read invites" on public.invites;
create policy "admins read invites" on public.invites for select to authenticated using (public.is_admin());
drop policy if exists "admins create invites" on public.invites;
create policy "admins create invites" on public.invites for insert to authenticated
  with check (public.is_admin() and (role in ('caller','salesperson') or public.is_owner()));
drop policy if exists "admins remove invites" on public.invites;
create policy "admins remove invites" on public.invites for delete to authenticated using (public.is_admin());

-- Callers see and edit only their own leads that are not in the trash; admins see everything.
drop policy if exists "read leads" on public.leads;
create policy "read leads" on public.leads for select to authenticated
  using (public.is_admin() or (public.can_sell() and deleted_at is null)
    or (public.is_member() and owner_id = auth.uid() and deleted_at is null));
drop policy if exists "admins add leads" on public.leads;
create policy "admins add leads" on public.leads for insert to authenticated with check (public.is_admin());
drop policy if exists "update leads" on public.leads;
create policy "update leads" on public.leads for update to authenticated
  using (public.is_admin() or (public.is_member() and deleted_at is null
    and (owner_id = auth.uid() or (public.is_sales() and sales_owner_id = auth.uid()))))
  with check (public.is_admin() or (public.is_member()
    and (owner_id = auth.uid() or (public.is_sales() and sales_owner_id = auth.uid()))));
drop policy if exists "admins delete leads" on public.leads;
create policy "admins delete leads" on public.leads for delete to authenticated using (public.is_admin());

drop policy if exists "read calls" on public.calls;
create policy "read calls" on public.calls for select to authenticated
  using (public.can_sell() or (public.is_member() and (caller_id = auth.uid()
    or exists (select 1 from public.leads l where l.id = calls.lead_id and l.owner_id = auth.uid()))));
-- Calls are only written through log_call() / undo_call() below.

drop policy if exists "read notes" on public.lead_notes;
create policy "read notes" on public.lead_notes for select to authenticated
  using (public.can_sell() or (public.is_member() and exists (
    select 1 from public.leads l where l.id = lead_notes.lead_id and l.owner_id = auth.uid() and l.deleted_at is null)));
drop policy if exists "add notes" on public.lead_notes;
create policy "add notes" on public.lead_notes for insert to authenticated
  with check (public.is_admin() or (public.is_member() and author_id = auth.uid() and exists (
    select 1 from public.leads l where l.id = lead_notes.lead_id and l.deleted_at is null
      and (l.owner_id = auth.uid() or (public.is_sales() and l.sales_owner_id = auth.uid())))));
drop policy if exists "remove notes" on public.lead_notes;
create policy "remove notes" on public.lead_notes for delete to authenticated
  using (public.is_admin() or (public.is_member() and author_id = auth.uid()));

-- ---------- Actions ------------------------------------------------------
drop function if exists public.log_call(uuid, text, text, timestamptz, timestamptz, text);
create function public.log_call(
  p_lead uuid, p_status text, p_note text default '',
  p_callback timestamptz default null, p_appt_at timestamptz default null, p_appt_rep text default '')
returns bigint language plpgsql security definer set search_path = public as $$
declare
  l public.leads%rowtype;
  cid bigint;
  boss uuid;
begin
  if not public.is_member() then raise exception 'Please sign in again.'; end if;
  select * into l from public.leads where id = p_lead for update;
  if not found then raise exception 'That lead no longer exists.'; end if;
  if l.deleted_at is not null then raise exception 'This lead is in the trash.'; end if;
  if l.status = 'converted' then raise exception 'This lead was converted to an opportunity.'; end if;
  if not (public.is_admin() or l.owner_id = auth.uid() or l.owner_id is null) then
    raise exception 'This lead belongs to another caller.';
  end if;
  if p_status not in ('call1','call2','call3','gatekeeper','appointment','dead','bad_info') then
    raise exception 'Unknown status.';
  end if;
  if p_status = 'appointment' and p_appt_at is null then
    raise exception 'Set the appointment date and time.';
  end if;
  -- After the 3rd call the lead goes On Ice and back to the Owner.
  if p_status = 'call3' then
    select id into boss from public.profiles where role = 'owner' and active order by created_at limit 1;
  end if;
  update public.leads set
    status = case when p_status = 'call3' then 'on_ice' else p_status end,
    attempts = attempts + 1,
    last_call_at = now(),
    callback_at = case when p_status in ('call1','call2','gatekeeper') then p_callback else null end,
    appt_at = case when p_status = 'appointment' then p_appt_at else appt_at end,
    appt_rep = case when p_status = 'appointment' then coalesce(p_appt_rep, '') else appt_rep end,
    appt_booked_by = case when p_status = 'appointment' then auth.uid() else appt_booked_by end,
    owner_id = case when p_status = 'call3' then coalesce(boss, owner_id, auth.uid()) else coalesce(owner_id, auth.uid()) end
  where id = p_lead;
  insert into public.calls (lead_id, caller_id, status, note, prev)
  values (p_lead, auth.uid(), p_status, coalesce(p_note, ''), jsonb_build_object(
    'status', l.status, 'attempts', l.attempts, 'last_call_at', l.last_call_at, 'callback_at', l.callback_at,
    'appt_at', l.appt_at, 'appt_rep', l.appt_rep, 'appt_booked_by', l.appt_booked_by, 'owner_id', l.owner_id))
  returning id into cid;
  return cid;
end $$;

-- Undo a logged call: puts the lead back exactly as it was and removes the call.
create or replace function public.undo_call(p_call bigint) returns void
language plpgsql security definer set search_path = public as $$
declare
  c public.calls%rowtype;
begin
  if not public.is_member() then raise exception 'Please sign in again.'; end if;
  select * into c from public.calls where id = p_call;
  if not found then raise exception 'That call was already undone.'; end if;
  if c.caller_id is distinct from auth.uid() and not public.is_admin() then
    raise exception 'You can only undo your own calls.';
  end if;
  if c.prev is null or c.lead_id is null then raise exception 'This call can''t be undone.'; end if;
  if exists (select 1 from public.calls where lead_id = c.lead_id and id > c.id) then
    raise exception 'A newer call was logged on this lead, so this one can''t be undone.';
  end if;
  update public.leads set
    status = c.prev->>'status',
    attempts = coalesce((c.prev->>'attempts')::int, 0),
    last_call_at = (c.prev->>'last_call_at')::timestamptz,
    callback_at = (c.prev->>'callback_at')::timestamptz,
    appt_at = (c.prev->>'appt_at')::timestamptz,
    appt_rep = coalesce(c.prev->>'appt_rep', ''),
    appt_booked_by = (c.prev->>'appt_booked_by')::uuid,
    owner_id = (c.prev->>'owner_id')::uuid
  where id = c.lead_id;
  delete from public.calls where id = p_call;
end $$;

create or replace function public.pull_leads(p_n int default 25) returns int
language plpgsql security definer set search_path = public as $$
declare
  n int;
begin
  if not public.is_member() then raise exception 'Please sign in again.'; end if;
  with picked as (
    select id from public.leads
    where owner_id is null and status = 'new' and deleted_at is null
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
    then (select count(*)::int from public.leads where owner_id is null and status = 'new' and deleted_at is null) else 0 end
$$;

-- Runs with the caller's own permissions, so callers only count their own leads.
drop function if exists public.status_counts(uuid, boolean, text);
create or replace function public.status_counts(p_owner uuid default null, p_unassigned boolean default false,
  p_search text default '', p_trash boolean default false)
returns table (status text, n bigint) language sql stable set search_path = public as $$
  select l.status, count(*) from public.leads l
  where (l.deleted_at is not null) = coalesce(p_trash, false)
    and (p_owner is null or l.owner_id = p_owner)
    and (not coalesce(p_unassigned, false) or l.owner_id is null)
    and (coalesce(p_search, '') = '' or l.search_text like '%' || p_search || '%')
  group by l.status
$$;

create or replace function public.trash_count() returns bigint
language sql stable set search_path = public as $$
  select count(*) from public.leads where deleted_at is not null
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
    if exists (select 1 from public.leads l where l.deleted_at is null and (
         (length(pk) = 10 and (l.phone_key = pk or l.mobile_key = pk))
      or (length(mk) = 10 and (l.phone_key = mk or l.mobile_key = mk))
      or (ek <> '' and l.email_key = ek)
      or (zk <> '' and l.zoominfo_id = zk))) then
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
  if p_role not in ('admin','salesperson','caller') then raise exception 'Unknown role.'; end if;
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

-- =====================================================================
-- Version 3: clients, agencies, opportunities, reports, edit history
-- =====================================================================

-- ---------- Clients (the company a deal is with) ----------
create table if not exists public.clients (
  id uuid primary key default gen_random_uuid(),
  name text not null check (length(btrim(name)) > 0),
  name_key text generated always as (lower(btrim(name))) stored,
  phone text not null default '',
  website text not null default '',
  industry text not null default '',
  employees text not null default '',
  revenue text not null default '',
  address text not null default '',
  city text not null default '',
  state text not null default '',
  zip text not null default '',
  country text not null default '',
  description text not null default '',
  created_by uuid references public.profiles(id) on delete set null default auth.uid(),
  updated_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create unique index if not exists clients_name_key_idx on public.clients (name_key);

-- ---------- Agencies (who some clients buy through) ----------
create table if not exists public.agencies (
  id uuid primary key default gen_random_uuid(),
  name text not null check (length(btrim(name)) > 0),
  name_key text generated always as (lower(btrim(name))) stored,
  contact_name text not null default '',
  phone text not null default '',
  email text not null default '',
  website text not null default '',
  created_by uuid references public.profiles(id) on delete set null default auth.uid(),
  created_at timestamptz not null default now()
);
create unique index if not exists agencies_name_key_idx on public.agencies (name_key);

-- ---------- Opportunities (deals) ----------
create table if not exists public.opportunities (
  id uuid primary key default gen_random_uuid(),
  deal_name text not null check (length(btrim(deal_name)) > 0),
  client_id uuid not null references public.clients(id),
  agency_id uuid references public.agencies(id) on delete set null,
  owner_id uuid references public.profiles(id) on delete set null,
  type text not null default 'first_deal' check (type in ('first_deal','returning')),
  stage text not null default 'prospecting'
    check (stage in ('prospecting','proposal','nurturing','closed_won','closed_lost')),
  probability int not null default 10 check (probability between 0 and 100),
  amount numeric(14,2),
  close_date date not null default (current_date + 30),
  lead_source text not null default '',
  next_step text not null default '',
  description text not null default '',
  products text[] not null default '{}',
  contact_name text not null default '',
  contact_title text not null default '',
  contact_email text not null default '',
  contact_phone text not null default '',
  lead_id uuid references public.leads(id) on delete set null,
  converted_by uuid references public.profiles(id) on delete set null,
  created_by uuid references public.profiles(id) on delete set null default auth.uid(),
  updated_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  closed_at timestamptz,
  deleted_at timestamptz,
  deleted_by uuid references public.profiles(id) on delete set null
);
create index if not exists opps_owner_idx on public.opportunities (owner_id);
create index if not exists opps_stage_idx on public.opportunities (stage);
create index if not exists opps_close_idx on public.opportunities (close_date);
create index if not exists opps_client_idx on public.opportunities (client_id);
create index if not exists opps_lead_idx on public.opportunities (lead_id);

create table if not exists public.opp_notes (
  id bigint generated always as identity primary key,
  opp_id uuid not null references public.opportunities(id) on delete cascade,
  author_id uuid references public.profiles(id) on delete set null default auth.uid(),
  body text not null check (length(btrim(body)) > 0),
  created_at timestamptz not null default now()
);
create index if not exists opp_notes_opp_idx on public.opp_notes (opp_id, created_at desc);

-- ---------- Edit history ----------
create table if not exists public.change_log (
  id bigint generated always as identity primary key,
  table_name text not null,
  row_id uuid not null,
  action text not null default 'update',
  changed_by uuid references public.profiles(id) on delete set null,
  changes jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);
create index if not exists change_log_row_idx on public.change_log (row_id, created_at desc);

-- Records which tracked fields changed (old -> new) and who changed them.
create or replace function public.log_changes() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  o jsonb; n jsonb; ch jsonb := '{}'::jsonb; i int; k text;
begin
  if tg_op = 'INSERT' then
    insert into public.change_log (table_name, row_id, action, changed_by)
    values (tg_table_name, new.id, case when tg_table_name = 'opportunities' and new.lead_id is not null then 'converted' else 'created' end, auth.uid());
    return null;
  end if;
  o := to_jsonb(old); n := to_jsonb(new);
  for i in 0 .. tg_nargs - 1 loop
    k := tg_argv[i];
    if (o -> k) is distinct from (n -> k) then
      ch := ch || jsonb_build_object(k, jsonb_build_array(o -> k, n -> k));
    end if;
  end loop;
  if ch <> '{}'::jsonb then
    insert into public.change_log (table_name, row_id, action, changed_by, changes) values (tg_table_name, new.id, 'update', auth.uid(), ch);
  end if;
  return null;
end $$;

drop trigger if exists leads_history on public.leads;
create trigger leads_history after update on public.leads for each row execute function public.log_changes(
  'first_name','last_name','title','company','phone','mobile','company_phone','email','address','city','state','zip',
  'industry','website','employees','revenue','linkedin','status','owner_id','sales_owner_id','callback_at','appt_at','appt_rep','deleted_at');

drop trigger if exists opps_history on public.opportunities;
create trigger opps_history after insert or update on public.opportunities for each row execute function public.log_changes(
  'deal_name','client_id','agency_id','owner_id','type','stage','probability','amount','close_date','lead_source','next_step',
  'description','products','contact_name','contact_title','contact_email','contact_phone','deleted_at');

drop trigger if exists clients_history on public.clients;
create trigger clients_history after update on public.clients for each row execute function public.log_changes(
  'name','phone','website','industry','employees','revenue','address','city','state','zip','country','description');

-- ---------- Opportunity rules ----------
create or replace function public.stage_probability(p_stage text) returns int
language sql immutable as $$
  select case p_stage when 'prospecting' then 10 when 'nurturing' then 25 when 'proposal' then 75
    when 'closed_won' then 100 else 0 end
$$;

drop trigger if exists opps_touch on public.opportunities;
create trigger opps_touch before update on public.opportunities for each row execute function public.touch_updated_at();
drop trigger if exists clients_touch on public.clients;
create trigger clients_touch before update on public.clients for each row execute function public.touch_updated_at();

create or replace function public.guard_opps() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' then
    new.closed_at := case when new.stage in ('closed_won','closed_lost') then now() else null end;
    return new;
  end if;
  if auth.uid() is not null and not public.is_admin() then
    if new.deleted_at is distinct from old.deleted_at then raise exception 'Only admins can delete or restore opportunities.'; end if;
    if new.owner_id is distinct from old.owner_id then raise exception 'Only admins can reassign opportunities.'; end if;
  end if;
  new.created_by := old.created_by;
  new.created_at := old.created_at;
  if new.stage in ('closed_won','closed_lost') then
    if old.stage not in ('closed_won','closed_lost') or old.closed_at is null then new.closed_at := now(); end if;
  else
    new.closed_at := null;
  end if;
  return new;
end $$;
drop trigger if exists opps_guard on public.opportunities;
create trigger opps_guard before insert or update on public.opportunities for each row execute function public.guard_opps();

-- ---------- Security rules ----------
alter table public.clients enable row level security;
alter table public.agencies enable row level security;
alter table public.opportunities enable row level security;
alter table public.opp_notes enable row level security;
alter table public.change_log enable row level security;

drop policy if exists "read clients" on public.clients;
create policy "read clients" on public.clients for select to authenticated using (public.is_member());
drop policy if exists "add clients" on public.clients;
create policy "add clients" on public.clients for insert to authenticated with check (public.can_sell());
drop policy if exists "edit clients" on public.clients;
create policy "edit clients" on public.clients for update to authenticated using (public.can_sell()) with check (public.can_sell());

drop policy if exists "read agencies" on public.agencies;
create policy "read agencies" on public.agencies for select to authenticated using (public.is_member());
drop policy if exists "add agencies" on public.agencies;
create policy "add agencies" on public.agencies for insert to authenticated with check (public.can_sell());
drop policy if exists "edit agencies" on public.agencies;
create policy "edit agencies" on public.agencies for update to authenticated using (public.can_sell()) with check (public.can_sell());

-- Everyone in sales sees every deal; a salesperson edits the deals they own or created.
drop policy if exists "read opps" on public.opportunities;
create policy "read opps" on public.opportunities for select to authenticated using (public.can_sell());
drop policy if exists "add opps" on public.opportunities;
create policy "add opps" on public.opportunities for insert to authenticated
  with check (public.is_admin() or (public.is_sales() and created_by = auth.uid()));
drop policy if exists "edit opps" on public.opportunities;
create policy "edit opps" on public.opportunities for update to authenticated
  using (public.is_admin() or (public.is_sales() and deleted_at is null and (owner_id = auth.uid() or created_by = auth.uid())))
  with check (public.is_admin() or (public.is_sales() and (owner_id = auth.uid() or created_by = auth.uid())));
drop policy if exists "remove opps" on public.opportunities;
create policy "remove opps" on public.opportunities for delete to authenticated using (public.is_admin());

drop policy if exists "read opp notes" on public.opp_notes;
create policy "read opp notes" on public.opp_notes for select to authenticated using (public.can_sell());
drop policy if exists "add opp notes" on public.opp_notes;
create policy "add opp notes" on public.opp_notes for insert to authenticated
  with check (public.is_admin() or (public.is_sales() and author_id = auth.uid() and exists (
    select 1 from public.opportunities o where o.id = opp_notes.opp_id and o.deleted_at is null
      and (o.owner_id = auth.uid() or o.created_by = auth.uid()))));
drop policy if exists "remove opp notes" on public.opp_notes;
create policy "remove opp notes" on public.opp_notes for delete to authenticated
  using (public.is_admin() or (public.is_member() and author_id = auth.uid()));

drop policy if exists "read history" on public.change_log;
create policy "read history" on public.change_log for select to authenticated
  using (public.can_sell() or (public.is_member() and table_name = 'leads' and exists (
    select 1 from public.leads l where l.id = change_log.row_id and l.owner_id = auth.uid())));

-- ---------- Actions ----------
create or replace function public.ensure_client(p_name text, p_fields jsonb default '{}'::jsonb) returns uuid
language plpgsql security definer set search_path = public as $$
declare cid uuid; f jsonb := coalesce(p_fields, '{}'::jsonb);
begin
  if not public.is_member() then raise exception 'Please sign in again.'; end if;
  if coalesce(btrim(p_name), '') = '' then raise exception 'Enter a client name.'; end if;
  select id into cid from public.clients where name_key = lower(btrim(p_name));
  if cid is not null then return cid; end if;
  if not (public.can_sell() or coalesce(current_setting('dialdesk.bypass', true), '') = 'on') then
    raise exception 'Only sales can add clients.';
  end if;
  insert into public.clients (name, phone, website, industry, employees, revenue, address, city, state, zip, country, created_by)
  values (btrim(p_name), coalesce(f->>'phone',''), coalesce(f->>'website',''), coalesce(f->>'industry',''),
    coalesce(f->>'employees',''), coalesce(f->>'revenue',''), coalesce(f->>'address',''), coalesce(f->>'city',''),
    coalesce(f->>'state',''), coalesce(f->>'zip',''), coalesce(f->>'country',''), auth.uid())
  on conflict (name_key) do nothing
  returning id into cid;
  if cid is null then select id into cid from public.clients where name_key = lower(btrim(p_name)); end if;
  return cid;
end $$;

create or replace function public.ensure_agency(p_name text) returns uuid
language plpgsql security definer set search_path = public as $$
declare aid uuid;
begin
  if not public.is_member() then raise exception 'Please sign in again.'; end if;
  if coalesce(btrim(p_name), '') = '' then return null; end if;
  select id into aid from public.agencies where name_key = lower(btrim(p_name));
  if aid is not null then return aid; end if;
  insert into public.agencies (name, created_by) values (btrim(p_name), auth.uid())
  on conflict (name_key) do nothing returning id into aid;
  if aid is null then select id into aid from public.agencies where name_key = lower(btrim(p_name)); end if;
  return aid;
end $$;

-- Convert a lead into an opportunity owned by a salesperson ("Appointment Set!" for callers).
drop function if exists public.convert_lead(uuid, uuid, text, text, text, text, text, numeric, date, text, text, text[]);
drop function if exists public.convert_lead(uuid, uuid, text, text, text, text, text, numeric, date, timestamptz, text, text[]);
create function public.convert_lead(
  p_lead uuid, p_sales uuid, p_deal text, p_client text, p_agency text default '',
  p_type text default 'first_deal', p_stage text default 'prospecting', p_amount numeric default null,
  p_follow_up date default null, p_appt_at timestamptz default null, p_description text default '', p_products text[] default '{}')
returns uuid language plpgsql security definer set search_path = public as $$
declare
  l public.leads%rowtype; cid uuid; aid uuid; oid uuid;
begin
  if not public.is_member() then raise exception 'Please sign in again.'; end if;
  select * into l from public.leads where id = p_lead for update;
  if not found or l.deleted_at is not null then raise exception 'That lead is no longer available.'; end if;
  if l.status = 'converted' then raise exception 'This lead was already converted.'; end if;
  if not (public.can_sell() or l.owner_id = auth.uid()) then raise exception 'This lead belongs to another caller.'; end if;
  if not exists (select 1 from public.profiles where id = p_sales and active and role in ('salesperson','admin','owner')) then
    raise exception 'Choose a salesperson.';
  end if;
  if coalesce(btrim(p_deal), '') = '' then raise exception 'Enter a deal name.'; end if;
  perform set_config('dialdesk.bypass', 'on', true);
  cid := public.ensure_client(p_client, jsonb_build_object(
    'phone', coalesce(nullif(l.company_phone, ''), l.phone), 'website', l.website, 'industry', l.industry,
    'employees', l.employees, 'revenue', l.revenue, 'address', l.address, 'city', l.city, 'state', l.state, 'zip', l.zip));
  aid := public.ensure_agency(p_agency);
  insert into public.opportunities (deal_name, client_id, agency_id, owner_id, type, stage, probability, amount,
    follow_up_date, lead_source, description, products, contact_name, contact_title, contact_email, contact_phone,
    lead_id, converted_by, created_by)
  values (btrim(p_deal), cid, aid, p_sales, coalesce(p_type, 'first_deal'), coalesce(p_stage, 'prospecting'),
    public.stage_probability(coalesce(p_stage, 'prospecting')), p_amount,
    coalesce(p_follow_up, (p_appt_at at time zone 'America/Chicago')::date),
    'Cold Calling', coalesce(p_description, ''), coalesce(p_products, '{}'),
    btrim(l.first_name || ' ' || l.last_name), l.title, l.email, coalesce(nullif(l.phone, ''), l.mobile),
    l.id, auth.uid(), auth.uid())
  returning id into oid;
  if btrim(l.first_name || l.last_name || l.email || l.phone || l.mobile) <> '' then
    insert into public.opp_contacts (opp_id, name, title, email, phone, created_by)
    values (oid, btrim(l.first_name || ' ' || l.last_name), l.title, l.email, coalesce(nullif(l.phone, ''), l.mobile), auth.uid());
  end if;
  update public.leads set pre_convert_status = status, status = 'converted', sales_owner_id = p_sales,
    opportunity_id = oid, converted_at = now(), converted_by = auth.uid(), callback_at = null,
    appt_at = coalesce(p_appt_at, appt_at), appt_booked_by = case when p_appt_at is not null then auth.uid() else appt_booked_by end
  where id = p_lead;
  perform set_config('dialdesk.bypass', 'off', true);
  return oid;
end $$;

-- Undo a conversion (right after it happens): removes the deal and puts the lead back.
create or replace function public.unconvert_lead(p_lead uuid) returns void
language plpgsql security definer set search_path = public as $$
declare l public.leads%rowtype;
begin
  if not public.is_member() then raise exception 'Please sign in again.'; end if;
  select * into l from public.leads where id = p_lead for update;
  if not found or l.status <> 'converted' then raise exception 'This lead isn''t converted.'; end if;
  if not (public.is_admin() or l.converted_by = auth.uid()) then raise exception 'Only the person who converted it can undo this.'; end if;
  perform set_config('dialdesk.bypass', 'on', true);
  delete from public.opportunities where id = l.opportunity_id;
  update public.leads set status = coalesce(l.pre_convert_status, 'appointment'), sales_owner_id = null, opportunity_id = null,
    converted_at = null, converted_by = null, pre_convert_status = null
  where id = p_lead;
  perform set_config('dialdesk.bypass', 'off', true);
end $$;

-- =====================================================================
-- Version 4: follow-up dates, multiple contacts per deal, notes kept when deleted
-- =====================================================================

-- Stages: Negotiation/Review removed (existing deals move to Proposal/Price Quote).
alter table public.opportunities drop constraint if exists opportunities_stage_check;
update public.opportunities set stage = 'proposal' where stage = 'negotiation';
alter table public.opportunities add constraint opportunities_stage_check
  check (stage in ('prospecting','proposal','nurturing','closed_won','closed_lost'));
alter table public.opportunities add column if not exists follow_up_date date;
alter table public.opportunities alter column close_date drop not null;
create index if not exists opps_follow_idx on public.opportunities (follow_up_date);
drop trigger if exists opps_history on public.opportunities;
create trigger opps_history after insert or update on public.opportunities for each row execute function public.log_changes(
  'deal_name','client_id','agency_id','owner_id','type','stage','probability','amount','follow_up_date','lead_source',
  'description','products','deleted_at');

-- Notes are never erased: deleting hides them but keeps them in the history, and they can be restored.
alter table public.lead_notes add column if not exists deleted_at timestamptz;
alter table public.lead_notes add column if not exists deleted_by uuid references public.profiles(id) on delete set null;
alter table public.opp_notes add column if not exists deleted_at timestamptz;
alter table public.opp_notes add column if not exists deleted_by uuid references public.profiles(id) on delete set null;
drop policy if exists "remove notes" on public.lead_notes;
drop policy if exists "remove opp notes" on public.opp_notes;

create or replace function public.set_note_deleted(p_kind text, p_id bigint, p_deleted boolean) returns void
language plpgsql security definer set search_path = public as $$
declare a uuid;
begin
  if not public.is_member() then raise exception 'Please sign in again.'; end if;
  if p_kind = 'lead' then select author_id into a from public.lead_notes where id = p_id;
  elsif p_kind = 'opp' then select author_id into a from public.opp_notes where id = p_id;
  else raise exception 'Unknown note.'; end if;
  if not found then raise exception 'That note no longer exists.'; end if;
  if not (public.is_admin() or a = auth.uid()) then raise exception 'You can only delete your own notes.'; end if;
  if p_kind = 'lead' then
    update public.lead_notes set deleted_at = case when p_deleted then now() end, deleted_by = case when p_deleted then auth.uid() end where id = p_id;
  else
    update public.opp_notes set deleted_at = case when p_deleted then now() end, deleted_by = case when p_deleted then auth.uid() end where id = p_id;
  end if;
end $$;

-- Contacts on a deal (any number).
create table if not exists public.opp_contacts (
  id uuid primary key default gen_random_uuid(),
  opp_id uuid not null references public.opportunities(id) on delete cascade,
  name text not null default '',
  title text not null default '',
  email text not null default '',
  phone text not null default '',
  created_by uuid references public.profiles(id) on delete set null default auth.uid(),
  created_at timestamptz not null default now(),
  deleted_at timestamptz,
  deleted_by uuid references public.profiles(id) on delete set null
);
create index if not exists opp_contacts_opp_idx on public.opp_contacts (opp_id, created_at);

-- Bring each deal's original contact into the contacts list (runs once per deal).
insert into public.opp_contacts (opp_id, name, title, email, phone, created_by, created_at)
select o.id, o.contact_name, o.contact_title, o.contact_email, o.contact_phone, o.created_by, o.created_at
from public.opportunities o
where btrim(o.contact_name || o.contact_email || o.contact_phone) <> ''
  and not exists (select 1 from public.opp_contacts c where c.opp_id = o.id);

-- Contact changes show in the deal's history.
create or replace function public.log_contact() returns trigger
language plpgsql security definer set search_path = public as $$
declare act text; ch jsonb := '{}'::jsonb; k text;
begin
  if tg_op = 'INSERT' then act := 'contact_added'; ch := jsonb_build_object('name', jsonb_build_array(null, new.name));
  elsif new.deleted_at is not null and old.deleted_at is null then act := 'contact_removed'; ch := jsonb_build_object('name', jsonb_build_array(old.name, null));
  elsif new.deleted_at is null and old.deleted_at is not null then act := 'contact_restored'; ch := jsonb_build_object('name', jsonb_build_array(null, new.name));
  else
    act := 'contact_edited';
    foreach k in array array['name','title','email','phone'] loop
      if (to_jsonb(old) -> k) is distinct from (to_jsonb(new) -> k) then
        ch := ch || jsonb_build_object(k, jsonb_build_array(to_jsonb(old) -> k, to_jsonb(new) -> k));
      end if;
    end loop;
    if ch = '{}'::jsonb then return null; end if;
    ch := ch || jsonb_build_object('contact', jsonb_build_array(null, new.name));
  end if;
  insert into public.change_log (table_name, row_id, action, changed_by, changes) values ('opportunities', new.opp_id, act, auth.uid(), ch);
  return null;
end $$;
drop trigger if exists opp_contacts_history on public.opp_contacts;
create trigger opp_contacts_history after insert or update on public.opp_contacts for each row execute function public.log_contact();

alter table public.opp_contacts enable row level security;
drop policy if exists "read contacts" on public.opp_contacts;
create policy "read contacts" on public.opp_contacts for select to authenticated using (public.can_sell());
drop policy if exists "add contacts" on public.opp_contacts;
create policy "add contacts" on public.opp_contacts for insert to authenticated
  with check (public.is_admin() or (public.is_sales() and exists (select 1 from public.opportunities o
    where o.id = opp_contacts.opp_id and o.deleted_at is null and (o.owner_id = auth.uid() or o.created_by = auth.uid()))));
drop policy if exists "edit contacts" on public.opp_contacts;
create policy "edit contacts" on public.opp_contacts for update to authenticated
  using (public.is_admin() or (public.is_sales() and exists (select 1 from public.opportunities o
    where o.id = opp_contacts.opp_id and o.deleted_at is null and (o.owner_id = auth.uid() or o.created_by = auth.uid()))))
  with check (public.is_admin() or (public.is_sales() and exists (select 1 from public.opportunities o
    where o.id = opp_contacts.opp_id and (o.owner_id = auth.uid() or o.created_by = auth.uid()))));

-- =====================================================================
-- Version 5: editable notes (old wording kept in history), On Ice status
-- =====================================================================
alter table public.lead_notes add column if not exists edited_at timestamptz;
alter table public.lead_notes add column if not exists edited_by uuid references public.profiles(id) on delete set null;
alter table public.opp_notes add column if not exists edited_at timestamptz;
alter table public.opp_notes add column if not exists edited_by uuid references public.profiles(id) on delete set null;
alter table public.calls add column if not exists edited_at timestamptz;
alter table public.calls add column if not exists edited_by uuid references public.profiles(id) on delete set null;

-- Edit a note (or the note saved with a call). The author or an admin can edit; the old wording goes into the history.
create or replace function public.edit_note(p_kind text, p_id bigint, p_body text) returns void
language plpgsql security definer set search_path = public as $$
declare a uuid; old_body text; rid uuid; tbl text;
begin
  if not public.is_member() then raise exception 'Please sign in again.'; end if;
  if p_kind = 'lead' then
    select author_id, body, lead_id into a, old_body, rid from public.lead_notes where id = p_id; tbl := 'leads';
  elsif p_kind = 'opp' then
    select author_id, body, opp_id into a, old_body, rid from public.opp_notes where id = p_id; tbl := 'opportunities';
  elsif p_kind = 'call' then
    select caller_id, note, lead_id into a, old_body, rid from public.calls where id = p_id; tbl := 'leads';
  else raise exception 'Unknown note.'; end if;
  if not found then raise exception 'That note no longer exists.'; end if;
  if not (public.is_admin() or a = auth.uid()) then raise exception 'You can only edit your own notes.'; end if;
  if p_kind <> 'call' and coalesce(btrim(p_body), '') = '' then raise exception 'A note can''t be empty. Use Delete instead.'; end if;
  if coalesce(old_body, '') = coalesce(p_body, '') then return; end if;
  if p_kind = 'lead' then
    update public.lead_notes set body = p_body, edited_at = now(), edited_by = auth.uid() where id = p_id;
  elsif p_kind = 'opp' then
    update public.opp_notes set body = p_body, edited_at = now(), edited_by = auth.uid() where id = p_id;
  else
    update public.calls set note = coalesce(p_body, ''), edited_at = now(), edited_by = auth.uid() where id = p_id;
  end if;
  if rid is not null then
    insert into public.change_log (table_name, row_id, action, changed_by, changes)
    values (tbl, rid, case when p_kind = 'call' then 'call_note_edited' else 'note_edited' end, auth.uid(),
      jsonb_build_object('body', jsonb_build_array(old_body, p_body), 'note_id', jsonb_build_array(null, p_id)));
  end if;
end $$;

-- ---------- Access for signed-in users (row level security still applies) ----------
grant usage on schema public to anon, authenticated;
grant select, insert, update, delete on all tables in schema public to authenticated;
grant usage, select on all sequences in schema public to authenticated;
grant execute on all functions in schema public to authenticated;
revoke execute on function public.log_call(uuid, text, text, timestamptz, timestamptz, text) from anon;
revoke execute on function public.undo_call(bigint) from anon;
revoke execute on function public.pull_leads(int) from anon;
revoke execute on function public.import_leads(jsonb, uuid, text) from anon;
revoke execute on function public.set_member(uuid, text, boolean) from anon;
revoke execute on function public.set_my_name(text) from anon;
revoke execute on function public.storage_used() from anon;
revoke execute on function public.convert_lead(uuid, uuid, text, text, text, text, text, numeric, date, timestamptz, text, text[]) from anon;
revoke execute on function public.unconvert_lead(uuid) from anon;
revoke execute on function public.set_note_deleted(text, bigint, boolean) from anon;
revoke execute on function public.edit_note(text, bigint, text) from anon;
revoke execute on function public.ensure_client(text, jsonb) from anon;
revoke execute on function public.ensure_agency(text) from anon;

select 'Dial Desk database is up to date' as result;
