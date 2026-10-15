-- =====================================================================
-- Dial Desk update: "Appointment showed" checkbox and Revert to lead (version 8)
-- Paste into Supabase > SQL Editor > New query > Run.
-- Run the version 7 time clock SQL first if you haven't yet.
-- Safe to run more than once. Your leads, deals, calls and time are kept.
-- (The same SQL is also in supabase-setup.sql.)
-- =====================================================================

-- =====================================================================
-- Version 8: "Appointment showed" checkbox (pays the caller on the appointment date)
--            and sending a deal back to a lead
-- =====================================================================
alter table public.opportunities add column if not exists appt_at timestamptz;
alter table public.opportunities add column if not exists appt_showed boolean not null default false;
alter table public.opportunities add column if not exists appt_showed_at timestamptz;
alter table public.opportunities add column if not exists appt_showed_by uuid references public.profiles(id) on delete set null;
alter table public.opportunities add column if not exists reverted_at timestamptz;
alter table public.opportunities add column if not exists reverted_by uuid references public.profiles(id) on delete set null;
create index if not exists opps_showed_idx on public.opportunities (converted_by) where appt_showed;

-- Deals made before version 8: copy the appointment time over from the lead (only where nobody has set or cleared it on the deal).
update public.opportunities o set appt_at = l.appt_at
  from public.leads l
 where o.lead_id = l.id and o.appt_at is null and l.appt_at is not null
   and not exists (select 1 from public.change_log c where c.row_id = o.id and c.changes ? 'appt_at');

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
    lead_id, converted_by, created_by, appt_at)
  values (btrim(p_deal), cid, aid, p_sales, coalesce(p_type, 'first_deal'), coalesce(p_stage, 'prospecting'),
    public.stage_probability(coalesce(p_stage, 'prospecting')), p_amount,
    coalesce(p_follow_up, (p_appt_at at time zone 'America/Chicago')::date),
    'Cold Calling', coalesce(p_description, ''), coalesce(p_products, '{}'),
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

-- Deal rules: only admins delete/restore or reassign; who marked "showed" and when is filled in automatically;
-- a deal sent back to a lead can't be restored (convert the lead again instead).
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
    if new.deleted_at is distinct from old.deleted_at then raise exception 'Only admins can delete or restore opportunities.'; end if;
    if new.owner_id is distinct from old.owner_id then raise exception 'Only admins can reassign opportunities.'; end if;
  end if;
  if not bypass then
    if new.reverted_at is distinct from old.reverted_at or new.reverted_by is distinct from old.reverted_by then
      raise exception 'Use the Revert to lead button to send a deal back.';
    end if;
    if old.reverted_at is not null and new.deleted_at is null then
      raise exception 'This deal was sent back to a lead. Convert the lead again instead of restoring the deal.';
    end if;
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

drop trigger if exists opps_history on public.opportunities;
create trigger opps_history after insert or update on public.opportunities for each row execute function public.log_changes(
  'deal_name','client_id','agency_id','owner_id','type','stage','probability','amount','follow_up_date','lead_source',
  'description','products','appt_at','appt_showed','reverted_at','deleted_at');

-- Send a deal back to its lead. The deal is kept (hidden, in the history) and the lead returns to the caller
-- with the status it had before it was converted. A note on the lead says who sent it back and why.
create or replace function public.revert_opportunity(p_opp uuid, p_reason text default '') returns uuid
language plpgsql security definer set search_path = public as $$
declare o public.opportunities%rowtype; l public.leads%rowtype; why text := btrim(coalesce(p_reason, ''));
begin
  if not public.is_member() then raise exception 'Please sign in again.'; end if;
  select * into o from public.opportunities where id = p_opp for update;
  if not found or o.deleted_at is not null then raise exception 'That opportunity is no longer available.'; end if;
  if not (public.is_admin() or (public.is_sales() and (o.owner_id = auth.uid() or o.created_by = auth.uid()))) then
    raise exception 'Only the deal owner or an admin can send a deal back to a lead.';
  end if;
  if o.lead_id is null then raise exception 'This deal didn''t start as a lead, so there is no lead to send it back to.'; end if;
  select * into l from public.leads where id = o.lead_id for update;
  if not found then raise exception 'The original lead no longer exists.'; end if;
  if l.deleted_at is not null then raise exception 'The original lead is in the Trash. Ask an admin to restore it first.'; end if;
  perform set_config('dialdesk.bypass', 'on', true);
  update public.opportunities set deleted_at = now(), deleted_by = auth.uid(), reverted_at = now(), reverted_by = auth.uid()
   where id = o.id;
  if l.opportunity_id = o.id then
    update public.leads set status = coalesce(nullif(l.pre_convert_status, 'converted'), 'appointment'), sales_owner_id = null,
      opportunity_id = null, converted_at = null, converted_by = null, pre_convert_status = null
     where id = l.id;
  end if;
  insert into public.lead_notes (lead_id, author_id, body)
  values (l.id, auth.uid(), 'Sent back from the deal "' || o.deal_name || '"' || case when why <> '' then '. Reason: ' || why else '.' end);
  perform set_config('dialdesk.bypass', 'off', true);
  return l.id;
end $$;

-- Appointments that showed, per caller per day of the appointment (Central time). This is what the $50 bonus pays on.
-- Admins get everyone; others only themselves. Deals sent back to a lead still count if they were marked showed.
create or replace function public.appt_pay_report(p_from date, p_to date)
returns table (caller_id uuid, day date, showed bigint)
language sql stable security definer set search_path = public as $$
  select x.caller_id, x.d, count(*)
  from (select o.converted_by as caller_id, (coalesce(o.appt_at, o.appt_showed_at) at time zone 'America/Chicago')::date as d
          from public.opportunities o
         where public.is_member() and o.appt_showed and o.converted_by is not null
           and (o.deleted_at is null or o.reverted_at is not null)
           and (public.is_admin() or o.converted_by = auth.uid())) x
  where x.d between p_from and p_to
  group by 1, 2
$$;

-- ---------- Access (row level security still decides who sees what) ----------
grant execute on function public.revert_opportunity(uuid, text), public.appt_pay_report(date, date) to authenticated;
grant execute on function public.convert_lead(uuid, uuid, text, text, text, text, text, numeric, date, timestamptz, text, text[]) to authenticated;
revoke execute on function public.revert_opportunity(uuid, text) from anon;
revoke execute on function public.appt_pay_report(date, date) from anon;
revoke execute on function public.convert_lead(uuid, uuid, text, text, text, text, text, numeric, date, timestamptz, text, text[]) from anon;

select 'Dial Desk version 8 is ready' as result;
