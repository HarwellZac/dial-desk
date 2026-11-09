-- =====================================================================
-- Dial Desk update: Deals & Agencies, new caller statuses, About company (version 10)
-- Paste into Supabase > SQL Editor > New query > Run.
-- Run versions 7, 8 and 9 first if you haven't yet.
-- Safe to run more than once. Nothing is deleted.
-- (The same SQL is also in supabase-setup.sql.)
-- =====================================================================

alter table public.leads drop constraint if exists leads_status_check;
alter table public.leads add constraint leads_status_check
  check (status in ('new','call1','call2','call3','on_ice','engaged','has_agency','already_opp','gatekeeper','appointment','converted','dead','bad_info'));
alter table public.leads drop column if exists status_rank;
alter table public.leads add column status_rank int generated always as (
  case status when 'new' then 1 when 'call1' then 2 when 'call2' then 3 when 'call3' then 4 when 'engaged' then 5 when 'has_agency' then 6
    when 'on_ice' then 7 when 'already_opp' then 8 when 'gatekeeper' then 9 when 'appointment' then 10 when 'converted' then 11
    when 'bad_info' then 12 when 'dead' then 13 else 14 end) stored;

-- =====================================================================
-- Version 10: Deals & Agencies, caller statuses Engaged / Has Agency / Already Opportunity,
--             About company, Call Center deal source, Qualifying -> Proposal marks the appointment showed
-- =====================================================================
alter table public.leads add column if not exists about text not null default '';
alter table public.leads add column if not exists agency_name text not null default '';
alter table public.leads add column if not exists agency_contact text not null default '';
alter table public.leads add column if not exists agency_phone text not null default '';
alter table public.leads add column if not exists agency_email text not null default '';

drop trigger if exists leads_history on public.leads;
create trigger leads_history after update on public.leads for each row execute function public.log_changes(
  'first_name','last_name','title','company','phone','mobile','company_phone','email','address','city','state','zip',
  'industry','website','employees','revenue','linkedin','about','agency_name','agency_contact','agency_phone','agency_email',
  'status','owner_id','sales_owner_id','callback_at','appt_at','appt_rep','deleted_at');

-- Deals that came from the call center are "Call Center" (was "Cold Calling"). Done quietly, without filling the history.
alter table public.opportunities disable trigger opps_history;
update public.opportunities set lead_source = 'Call Center' where lead_source = 'Cold Calling';
alter table public.opportunities enable trigger opps_history;

-- Logging a call. New: Engaged and Has Agency (stay with the caller, can have a callback); Already Opportunity.
-- Leads marked Already Opportunity, Dead or Bad Information, and leads after the 3rd call, go back to the Owner.
create or replace function public.log_call(
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
  if l.status = 'converted' then raise exception 'This lead was converted to a deal.'; end if;
  if not (public.is_admin() or l.owner_id = auth.uid() or l.owner_id is null) then
    raise exception 'This lead belongs to another caller.';
  end if;
  if p_status not in ('call1','call2','call3','engaged','has_agency','already_opp','appointment','dead','bad_info') then
    raise exception 'Unknown status.';
  end if;
  if p_status = 'appointment' and p_appt_at is null then
    raise exception 'Set the appointment date and time.';
  end if;
  if p_status in ('call3','already_opp','dead','bad_info') then
    select id into boss from public.profiles where role = 'owner' and active order by created_at limit 1;
  end if;
  update public.leads set
    status = case when p_status = 'call3' then 'on_ice' else p_status end,
    attempts = attempts + 1,
    last_call_at = now(),
    callback_at = case when p_status in ('call1','call2','engaged','has_agency') then p_callback else null end,
    appt_at = case when p_status = 'appointment' then p_appt_at else appt_at end,
    appt_rep = case when p_status = 'appointment' then coalesce(p_appt_rep, '') else appt_rep end,
    appt_booked_by = case when p_status = 'appointment' then auth.uid() else appt_booked_by end,
    owner_id = case when p_status in ('call3','already_opp','dead','bad_info') then coalesce(boss, owner_id, auth.uid()) else coalesce(owner_id, auth.uid()) end
  where id = p_lead;
  insert into public.calls (lead_id, caller_id, status, note, prev)
  values (p_lead, auth.uid(), p_status, coalesce(p_note, ''), jsonb_build_object(
    'status', l.status, 'attempts', l.attempts, 'last_call_at', l.last_call_at, 'callback_at', l.callback_at,
    'appt_at', l.appt_at, 'appt_rep', l.appt_rep, 'appt_booked_by', l.appt_booked_by, 'owner_id', l.owner_id))
  returning id into cid;
  return cid;
end $$;

drop function if exists public.team_stats(timestamptz);
create function public.team_stats(p_since timestamptz)
returns table (caller_id uuid, calls bigint, engaged bigint, has_agency bigint, already_opp bigint, appointments bigint, dead bigint, bad_info bigint)
language sql stable set search_path = public as $$
  select c.caller_id, count(*),
    count(*) filter (where c.status = 'engaged'),
    count(*) filter (where c.status = 'has_agency'),
    count(*) filter (where c.status in ('already_opp','gatekeeper')),
    count(*) filter (where c.status = 'appointment'),
    count(*) filter (where c.status = 'dead'),
    count(*) filter (where c.status = 'bad_info')
  from public.calls c where c.created_at >= p_since group by c.caller_id
$$;

create or replace function public.lead_status_report()
returns table (owner_id uuid, status text, n bigint, never_called bigint, callbacks_due bigint, stale30 bigint)
language sql stable security definer set search_path = public as $$
  select l.owner_id, l.status, count(*),
    count(*) filter (where l.last_call_at is null),
    count(*) filter (where l.callback_at <= now() and l.status in ('new','call1','call2','call3','engaged','has_agency','gatekeeper')),
    count(*) filter (where l.last_call_at < now() - interval '30 days' and l.status in ('new','call1','call2','call3','engaged','has_agency','gatekeeper'))
  from public.leads l
  where public.is_admin() and l.deleted_at is null
  group by l.owner_id, l.status
$$;

-- Imports also take an "About company" column.
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
      address, city, state, zip, industry, website, employees, revenue, linkedin, zoominfo_id, about, extra, owner_id, source)
    values (coalesce(r->>'first_name',''), coalesce(r->>'last_name',''), coalesce(r->>'title',''), coalesce(r->>'company',''),
      coalesce(r->>'phone',''), coalesce(r->>'mobile',''), coalesce(r->>'company_phone',''), coalesce(r->>'email',''),
      coalesce(r->>'address',''), coalesce(r->>'city',''), coalesce(r->>'state',''), coalesce(r->>'zip',''),
      coalesce(r->>'industry',''), coalesce(r->>'website',''), coalesce(r->>'employees',''), coalesce(r->>'revenue',''),
      coalesce(r->>'linkedin',''), zk, left(coalesce(r->>'about',''), 2000), coalesce(r->'extra', '{}'::jsonb), p_owner, coalesce(p_source, ''));
    ins := ins + 1;
  end loop;
  return jsonb_build_object('inserted', ins, 'duplicates', dup);
end $$;

-- Deal rules (as in version 8), plus: moving a deal from Qualifying to Proposal/Quote marks the appointment as showed.
create or replace function public.guard_opps() returns trigger
language plpgsql security definer set search_path = public as $$
declare bypass boolean := coalesce(current_setting('dialdesk.bypass', true), '') = 'on';
begin
  if tg_op = 'INSERT' then
    new.closed_at := case when new.stage in ('closed_won','closed_lost') then now() else null end;
    new.appt_showed_at := case when new.appt_showed then now() end;
    new.appt_showed_by := case when new.appt_showed then auth.uid() end;
    new.reverted_at := null; new.reverted_by := null;
    return new;
  end if;
  if auth.uid() is not null and not public.is_admin() and not bypass then
    if new.deleted_at is distinct from old.deleted_at then raise exception 'Only admins can delete or restore deals.'; end if;
    if new.owner_id is distinct from old.owner_id then raise exception 'Only admins can reassign deals.'; end if;
  end if;
  if not bypass then
    if new.reverted_at is distinct from old.reverted_at or new.reverted_by is distinct from old.reverted_by then
      raise exception 'Use the Revert to lead button to send a deal back.';
    end if;
    if old.reverted_at is not null and new.deleted_at is null then
      raise exception 'This deal was sent back to a lead. Convert the lead again instead of restoring the deal.';
    end if;
  end if;
  if old.stage = 'prospecting' and new.stage = 'proposal' and not old.appt_showed then
    new.appt_showed := true;
  end if;
  if new.appt_showed is distinct from old.appt_showed then
    new.appt_showed_at := case when new.appt_showed then now() end;
    new.appt_showed_by := case when new.appt_showed then auth.uid() end;
  else
    new.appt_showed_at := old.appt_showed_at; new.appt_showed_by := old.appt_showed_by;
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

-- Converting a lead (updated: agency details carry over, About company fills the client's description, source = Call Center)
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
  aid := public.ensure_agency(coalesce(nullif(btrim(p_agency), ''), l.agency_name));
  -- Agency details the caller collected fill in any blanks on the agency.
  if aid is not null then
    update public.agencies set contact_name = case when contact_name = '' then l.agency_contact else contact_name end,
      phone = case when phone = '' then l.agency_phone else phone end, email = case when email = '' then l.agency_email else email end
    where id = aid;
  end if;
  if l.about <> '' then update public.clients set description = l.about where id = cid and description = ''; end if;
  insert into public.opportunities (deal_name, client_id, agency_id, owner_id, type, stage, probability, amount,
    follow_up_date, lead_source, description, products, contact_name, contact_title, contact_email, contact_phone,
    lead_id, converted_by, created_by, appt_at)
  values (btrim(p_deal), cid, aid, p_sales, coalesce(p_type, 'first_deal'), coalesce(p_stage, 'prospecting'),
    public.stage_probability(coalesce(p_stage, 'prospecting')), p_amount,
    coalesce(p_follow_up, (p_appt_at at time zone 'America/Chicago')::date),
    'Call Center', coalesce(p_description, ''), coalesce(p_products, '{}'),
    btrim(l.first_name || ' ' || l.last_name), l.title, l.email, coalesce(nullif(l.phone, ''), l.mobile),
    l.id, auth.uid(), auth.uid(), coalesce(p_appt_at, l.appt_at))
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

-- ---------- Access ----------
grant execute on function public.log_call(uuid, text, text, timestamptz, timestamptz, text), public.team_stats(timestamptz),
  public.lead_status_report(), public.import_leads(jsonb, uuid, text),
  public.convert_lead(uuid, uuid, text, text, text, text, text, numeric, date, timestamptz, text, text[]) to authenticated;
revoke execute on function public.team_stats(timestamptz) from anon;
revoke execute on function public.convert_lead(uuid, uuid, text, text, text, text, text, numeric, date, timestamptz, text, text[]) from anon;

select 'Dial Desk version 10 is ready' as result;
