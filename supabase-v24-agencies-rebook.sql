-- =====================================================================
-- The Ark version 24: agencies, Needs Rebooked, Agreement Submitted, deleting
--   * New lead status "Needs Rebooked": a salesperson ticks it on a deal and the deal goes back
--     to the caller who owns the lead, marked Needs Rebooked.
--   * Leads have a "Has Agency" box (leads.is_agency = this lead IS an agency). Leads made by
--     marking another lead Has Agency get it ticked, and the agency is added to the Agencies tab
--     with the client it represents (agencies.agency_for).
--   * Setting an appointment on / converting an agency lead makes one deal per client it represents,
--     all through that agency. Sending those deals back puts the leads back with their caller.
--   * New deal stage "Agreement Submitted". Only Owners and admins can mark a deal Closed Won
--     (or move it out of Closed Won).
--   * Admins and Owners can delete clients (their deals go to the Trash too) and agencies.
-- Safe to run more than once. Paste into Supabase > SQL Editor > Run.
-- =====================================================================

-- ---------- Lead status: Needs Rebooked ----------
alter table public.leads drop constraint if exists leads_status_check;
alter table public.leads add constraint leads_status_check
  check (status in ('new','needs_rebook','call1','call2','call3','on_ice','engaged','has_agency','already_opp','gatekeeper','appointment','converted','dead','bad_info'));
alter table public.leads drop column if exists status_rank;
alter table public.leads add column status_rank int generated always as (
  case status when 'needs_rebook' then 0 when 'new' then 1 when 'call1' then 2 when 'call2' then 3 when 'call3' then 4 when 'engaged' then 5 when 'has_agency' then 6
    when 'on_ice' then 7 when 'already_opp' then 8 when 'gatekeeper' then 9 when 'appointment' then 10 when 'converted' then 11
    when 'bad_info' then 12 when 'dead' then 13 else 14 end) stored;

-- ---------- Leads that are agencies ----------
alter table public.leads add column if not exists is_agency boolean not null default false;
update public.leads set is_agency = true where not is_agency and agency_for <> '';
drop trigger if exists leads_history on public.leads;
create trigger leads_history after update on public.leads for each row execute function public.log_changes(
  'first_name','last_name','title','company','phone','mobile','company_phone','email','address','city','state','zip',
  'industry','website','employees','revenue','linkedin','about','agency_name','agency_contact','agency_phone','agency_email','agency_for',
  'is_agency','status','owner_id','sales_owner_id','callback_at','appt_at','appt_rep','deleted_at');

-- Who an agency represents (company names, comma separated).
alter table public.agencies add column if not exists agency_for text not null default '';

-- Adds a company to an agency's "Client" list (once).
create or replace function public.add_agency_client(p_agency uuid, p_client text) returns void
language plpgsql security definer set search_path = public as $$
declare co text := btrim(coalesce(p_client, ''));
begin
  if not public.is_member() then raise exception 'Please sign in again.'; end if;
  if p_agency is null or co = '' then return; end if;
  update public.agencies set agency_for = case when agency_for = '' then co else agency_for || ', ' || co end
   where id = p_agency and not (lower(co) = any (string_to_array(lower(agency_for), ', ')));
  -- A client already in the Clients list with no agency gets this one.
  update public.clients set agency_id = p_agency where name_key = lower(co) and agency_id is null and deleted_at is null;
end $$;
revoke execute on function public.add_agency_client(uuid, text) from anon;

-- ---------- Clients can be deleted (soft: hidden, with their deals in the Trash) ----------
alter table public.clients add column if not exists deleted_at timestamptz;
alter table public.clients add column if not exists deleted_by uuid references public.profiles(id) on delete set null;

create or replace function public.delete_client(p_client uuid) returns int
language plpgsql security definer set search_path = public as $$
declare n int;
begin
  if not public.is_admin() then raise exception 'Only admins and Owners can delete clients.'; end if;
  update public.opportunities set deleted_at = now(), deleted_by = auth.uid()
   where client_id = p_client and deleted_at is null;
  get diagnostics n = row_count;
  update public.clients set deleted_at = now(), deleted_by = auth.uid() where id = p_client;
  return n;
end $$;
revoke execute on function public.delete_client(uuid) from anon;

-- Agencies are removed for good: their clients and deals become Direct; notes and file records go too.
create or replace function public.delete_agency(p_agency uuid) returns setof text
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'Only admins and Owners can delete agencies.'; end if;
  return query delete from public.attachments where kind = 'agency' and parent_id = p_agency returning path;
  delete from public.agencies where id = p_agency;
end $$;
revoke execute on function public.delete_agency(uuid) from anon;

-- Finding a client by name brings a deleted one back instead of failing on the duplicate name.
create or replace function public.ensure_client(p_name text, p_fields jsonb default '{}'::jsonb) returns uuid
language plpgsql security definer set search_path = public as $$
declare cid uuid; gone boolean; f jsonb := coalesce(p_fields, '{}'::jsonb);
begin
  if not public.is_member() then raise exception 'Please sign in again.'; end if;
  if coalesce(btrim(p_name), '') = '' then raise exception 'Enter a client name.'; end if;
  select id, deleted_at is not null into cid, gone from public.clients where name_key = lower(btrim(p_name));
  if cid is not null then
    if gone then update public.clients set deleted_at = null, deleted_by = null where id = cid; end if;
    return cid;
  end if;
  if not (public.can_sell() or coalesce(current_setting('dialdesk.bypass', true), '') = 'on') then
    raise exception 'Only sales can add clients.';
  end if;
  insert into public.clients (name, phone, website, industry, employees, revenue, address, city, state, zip, country, created_by,
    owner_id, agency_id, client_source, client_type)
  values (btrim(p_name), coalesce(f->>'phone',''), coalesce(f->>'website',''), coalesce(f->>'industry',''),
    coalesce(f->>'employees',''), coalesce(f->>'revenue',''), coalesce(f->>'address',''), coalesce(f->>'city',''),
    coalesce(f->>'state',''), coalesce(f->>'zip',''), coalesce(f->>'country',''), auth.uid(),
    coalesce(nullif(f->>'owner_id','')::uuid, auth.uid()), nullif(f->>'agency_id','')::uuid,
    coalesce(f->>'client_source',''), coalesce(nullif(f->>'client_type',''), 'first_deal'))
  on conflict (name_key) do nothing
  returning id into cid;
  if cid is null then select id into cid from public.clients where name_key = lower(btrim(p_name)); end if;
  return cid;
end $$;

drop policy if exists "remove agencies" on public.agencies;
create policy "remove agencies" on public.agencies for delete to authenticated using (public.is_admin());

-- ---------- Has Agency: the agency becomes a lead (ticked Has Agency) and goes on the Agencies tab ----------
-- p_client = who the agency represents (defaults to this lead's company).
drop function if exists public.link_agency_lead(uuid);
create or replace function public.link_agency_lead(p_lead uuid, p_client text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  l public.leads%rowtype; a public.leads%rowtype; made boolean := false; nm text; co text; pk text; ek text; who text; fn text; aid uuid;
begin
  if not public.is_member() then raise exception 'Please sign in again.'; end if;
  select * into l from public.leads where id = p_lead for update;
  if not found or l.deleted_at is not null then raise exception 'That lead is no longer available.'; end if;
  if not (public.is_admin() or l.owner_id = auth.uid() or (public.is_sales() and l.sales_owner_id = auth.uid())) then
    raise exception 'This lead belongs to another caller.';
  end if;
  nm := btrim(l.agency_name);
  if nm = '' then return null; end if;
  co := coalesce(nullif(btrim(coalesce(p_client, '')), ''), nullif(btrim(l.company), ''), nullif(btrim(l.first_name || ' ' || l.last_name), ''), 'a lead');
  who := coalesce((select coalesce(nullif(full_name, ''), email) from public.profiles where id = auth.uid()), 'a caller');
  if l.agency_lead_id is not null then
    select * into a from public.leads where id = l.agency_lead_id and deleted_at is null;
  end if;
  if a.id is null then
    pk := right(regexp_replace(coalesce(l.agency_phone, ''), '[^0-9]', '', 'g'), 10);
    ek := lower(btrim(coalesce(l.agency_email, '')));
    select * into a from public.leads x
     where x.deleted_at is null and x.id <> l.id
       and (lower(btrim(x.company)) = lower(nm) or (length(pk) = 10 and (x.phone_key = pk or x.mobile_key = pk)) or (ek <> '' and x.email_key = ek))
     order by (lower(btrim(x.company)) = lower(nm)) desc, x.created_at
     limit 1;
  end if;
  if a.id is null then
    fn := split_part(btrim(l.agency_contact), ' ', 1);
    insert into public.leads (company, first_name, last_name, phone, email, owner_id, source, agency_for, about, is_agency)
    values (nm, fn, btrim(substr(btrim(l.agency_contact), length(fn) + 1)), btrim(l.agency_phone), btrim(l.agency_email),
      coalesce(l.owner_id, auth.uid()), 'Agency for ' || co || ' (added by ' || who || ')', co,
      'Agency that represents ' || co || '.', true)
    returning * into a;
    made := true;
  end if;
  if made or not (lower(co) = any (string_to_array(lower(a.agency_for), ', '))) then
    if not made then
      update public.leads set agency_for = case when agency_for = '' then co else agency_for || ', ' || co end where id = a.id;
    end if;
    insert into public.lead_notes (lead_id, author_id, body)
    values (a.id, auth.uid(), 'Agency for ' || co || '. ' || who || ' marked ' || co || ' as Has Agency'
      || case when btrim(l.agency_contact) <> '' then ' (agency contact: ' || btrim(l.agency_contact) || ')' else '' end || '.');
  end if;
  if not a.is_agency then update public.leads set is_agency = true where id = a.id; end if;
  if l.agency_lead_id is distinct from a.id then
    update public.leads set agency_lead_id = a.id where id = l.id;
  end if;
  -- The agency on the Agencies tab, with what the caller collected and who it represents.
  aid := public.ensure_agency(nm);
  update public.agencies set contact_name = case when contact_name = '' then btrim(l.agency_contact) else contact_name end,
    phone = case when phone = '' then btrim(l.agency_phone) else phone end,
    email = case when email = '' then btrim(l.agency_email) else email end,
    source = case when source = '' then 'Call Center' else source end
   where id = aid;
  perform public.add_agency_client(aid, co);
  return jsonb_build_object('id', a.id, 'created', made, 'mine', a.owner_id = auth.uid(), 'agency_id', aid,
    'owner', coalesce((select coalesce(nullif(full_name, ''), email) from public.profiles where id = a.owner_id), 'nobody'));
end $$;
revoke execute on function public.link_agency_lead(uuid, text) from anon;

-- ---------- Deal stages: Agreement Submitted; only Owners/admins mark Closed Won ----------
alter table public.opportunities drop constraint if exists opportunities_stage_check;
alter table public.opportunities add constraint opportunities_stage_check
  check (stage in ('prospecting','proposal','nurturing','agreement','closed_won','closed_lost'));
create or replace function public.stage_probability(p_stage text) returns int
language sql immutable as $$
  select case p_stage when 'prospecting' then 10 when 'nurturing' then 25 when 'proposal' then 75
    when 'agreement' then 90 when 'closed_won' then 100 else 0 end
$$;

create or replace function public.guard_opps() returns trigger
language plpgsql security definer set search_path = public as $$
declare bypass boolean := coalesce(current_setting('dialdesk.bypass', true), '') = 'on';
begin
  if tg_op = 'INSERT' then
    if new.stage = 'closed_won' and auth.uid() is not null and not public.is_admin() and not bypass then
      raise exception 'Only an Owner or admin can mark a deal Closed Won.';
    end if;
    new.closed_at := case when new.stage in ('closed_won','closed_lost') then now() else null end;
    new.appt_showed_at := case when new.appt_showed then now() end;
    new.appt_showed_by := case when new.appt_showed then auth.uid() end;
    new.reverted_at := null; new.reverted_by := null;
    return new;
  end if;
  if auth.uid() is not null and not public.is_admin() and not bypass then
    if new.deleted_at is distinct from old.deleted_at then raise exception 'Only admins can delete or restore deals.'; end if;
    if new.owner_id is distinct from old.owner_id then raise exception 'Only admins can reassign deals.'; end if;
    if new.converted_by is distinct from old.converted_by then raise exception 'Only admins can change the CSR who booked an appointment.'; end if;
    if new.stage is distinct from old.stage and 'closed_won' in (new.stage, old.stage) then
      raise exception 'Only an Owner or admin can mark a deal Closed Won or change a Closed Won deal''s stage.';
    end if;
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

-- ---------- Appointment Set! / Convert ----------
-- An agency lead (Has Agency ticked) goes on the Agencies tab and makes one deal per client it represents.
create or replace function public.convert_lead(
  p_lead uuid, p_sales uuid, p_deal text, p_client text, p_agency text default '',
  p_type text default 'first_deal', p_stage text default 'prospecting', p_amount numeric default null,
  p_follow_up date default null, p_appt_at timestamptz default null, p_description text default '', p_products text[] default '{}')
returns uuid language plpgsql security definer set search_path = public as $$
declare
  l public.leads%rowtype; cl public.leads%rowtype; cid uuid; aid uuid; oid uuid; first_oid uuid;
  names text[] := '{}'; nm text; dn text; co text;
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
  if coalesce(p_stage, '') = 'closed_won' and not public.is_admin() then
    raise exception 'Only an Owner or admin can mark a deal Closed Won.';
  end if;
  perform set_config('dialdesk.bypass', 'on', true);
  co := coalesce(nullif(btrim(l.company), ''), btrim(l.first_name || ' ' || l.last_name));

  if l.is_agency then
    -- The agency itself, with this lead's details.
    aid := public.ensure_agency(coalesce(nullif(btrim(p_agency), ''), co));
    update public.agencies set contact_name = case when contact_name = '' then btrim(l.first_name || ' ' || l.last_name) else contact_name end,
      phone = case when phone = '' then coalesce(nullif(l.phone, ''), nullif(l.company_phone, ''), l.mobile) else phone end,
      email = case when email = '' then l.email else email end,
      website = case when website = '' then l.website else website end,
      source = case when source = '' then 'Call Center' else source end
     where id = aid;
    -- Its clients: the companies in its Client list (each lead marked Has Agency adds itself there).
    select coalesce(array_agg(n order by n), '{}') into names
      from (select distinct on (lower(btrim(x))) btrim(x) n from unnest(string_to_array(l.agency_for, ',')) x
             where btrim(x) <> '' order by lower(btrim(x))) d;
  end if;

  if coalesce(array_length(names, 1), 0) = 0 then
    -- An ordinary lead (or an agency with no clients named yet): one deal, as before.
    names := array[btrim(p_client)];
    if aid is null then aid := public.ensure_agency(coalesce(nullif(btrim(p_agency), ''), l.agency_name)); end if;
    if aid is not null and not l.is_agency then
      update public.agencies set contact_name = case when contact_name = '' then l.agency_contact else contact_name end,
        phone = case when phone = '' then l.agency_phone else phone end, email = case when email = '' then l.agency_email else email end
      where id = aid;
      update public.agencies set source = 'Call Center' where id = aid and source = '';
    end if;
  end if;

  foreach nm in array names loop
    cl := null;
    if l.is_agency then
      -- The client's own lead: same name, or one name starts with the other ("Acme" / "Acme Corp").
      select * into cl from public.leads c where c.agency_lead_id = l.id and c.deleted_at is null and c.status <> 'converted'
        and btrim(c.company) <> '' and (lower(nm) like lower(btrim(c.company)) || '%' or lower(btrim(c.company)) like lower(nm) || '%')
       order by (lower(btrim(c.company)) = lower(nm)) desc limit 1;
    end if;
    if cl.id is null then cl := l; end if;
    cid := public.ensure_client(nm, jsonb_build_object(
      'phone', coalesce(nullif(cl.company_phone, ''), cl.phone), 'website', cl.website, 'industry', cl.industry,
      'employees', cl.employees, 'revenue', cl.revenue, 'address', cl.address, 'city', cl.city, 'state', cl.state, 'zip', cl.zip,
      'owner_id', p_sales, 'client_source', 'Call Center'));
    if cl.about <> '' and not (cl.id = l.id and l.is_agency) then
      update public.clients set description = cl.about where id = cid and description = '';
    end if;
    if aid is not null then update public.clients set agency_id = aid where id = cid and agency_id is null; end if;
    if l.is_agency then perform public.add_agency_client(aid, nm); end if;
    -- "Agency - Nov 2026" becomes "Client - Nov 2026" for each client of an agency.
    dn := btrim(p_deal);
    if l.is_agency and lower(nm) <> lower(co) then
      dn := case when co <> '' and lower(left(dn, length(co))) = lower(co) then nm || substr(dn, length(co) + 1) else nm || ' - ' || dn end;
    end if;
    insert into public.opportunities (deal_name, client_id, agency_id, owner_id, type, stage, probability, amount,
      follow_up_date, lead_source, description, products, contact_name, contact_title, contact_email, contact_phone,
      lead_id, converted_by, created_by, appt_at, appt_company)
    values (dn, cid, aid, p_sales, coalesce(p_type, 'first_deal'), coalesce(p_stage, 'prospecting'),
      public.stage_probability(coalesce(p_stage, 'prospecting')), p_amount,
      coalesce(p_follow_up, (p_appt_at at time zone 'America/Chicago')::date),
      'Call Center', coalesce(p_description, ''), coalesce(p_products, '{}'),
      btrim(l.first_name || ' ' || l.last_name), l.title, l.email, coalesce(nullif(l.phone, ''), l.mobile),
      l.id, auth.uid(), auth.uid(), coalesce(p_appt_at, l.appt_at), nm)
    returning id into oid;
    if first_oid is null then first_oid := oid; end if;
    if btrim(l.first_name || l.last_name || l.email || l.phone || l.mobile) <> '' then
      insert into public.opp_contacts (opp_id, name, title, email, phone, created_by)
      values (oid, btrim(l.first_name || ' ' || l.last_name), l.title, l.email, coalesce(nullif(l.phone, ''), l.mobile), auth.uid());
    end if;
    -- The client's own lead (marked Has Agency) is converted along with it.
    if cl.id <> l.id then
      update public.leads set pre_convert_status = status, status = 'converted', sales_owner_id = p_sales,
        opportunity_id = oid, converted_at = now(), converted_by = auth.uid(), callback_at = null
      where id = cl.id;
    end if;
  end loop;

  update public.leads set pre_convert_status = status, status = 'converted', sales_owner_id = p_sales,
    opportunity_id = first_oid, converted_at = now(), converted_by = auth.uid(), callback_at = null,
    appt_at = coalesce(p_appt_at, appt_at), appt_booked_by = case when p_appt_at is not null then auth.uid() else appt_booked_by end
  where id = p_lead;
  perform set_config('dialdesk.bypass', 'off', true);
  return first_oid;
end $$;
revoke execute on function public.convert_lead(uuid, uuid, text, text, text, text, text, numeric, date, timestamptz, text, text[]) from anon;

-- Undo right after converting: removes every deal it made and puts the leads back.
create or replace function public.unconvert_lead(p_lead uuid) returns void
language plpgsql security definer set search_path = public as $$
declare l public.leads%rowtype; ids uuid[];
begin
  if not public.is_member() then raise exception 'Please sign in again.'; end if;
  select * into l from public.leads where id = p_lead for update;
  if not found or l.status <> 'converted' then raise exception 'This lead isn''t converted.'; end if;
  if not (public.is_admin() or l.converted_by = auth.uid()) then raise exception 'Only the person who converted it can undo this.'; end if;
  perform set_config('dialdesk.bypass', 'on', true);
  select coalesce(array_agg(id), '{}') into ids from public.opportunities
   where id = l.opportunity_id or (lead_id = p_lead and deleted_at is null and reverted_at is null and created_at >= l.converted_at);
  update public.leads set status = coalesce(nullif(pre_convert_status, 'converted'), 'appointment'), sales_owner_id = null, opportunity_id = null,
    converted_at = null, converted_by = null, pre_convert_status = null
  where opportunity_id = any (ids) or id = p_lead;
  delete from public.opportunities where id = any (ids);
  perform set_config('dialdesk.bypass', 'off', true);
end $$;

-- ---------- Send a deal back (Revert to lead / Needs Rebooked) ----------
-- p_rebook = true: the lead goes back to its caller marked "Needs Rebooked".
-- Deals made from an agency lead go back together. Leads always return to their caller.
drop function if exists public.revert_opportunity(uuid, text);
create or replace function public.revert_opportunity(p_opp uuid, p_reason text default '', p_rebook boolean default false) returns uuid
language plpgsql security definer set search_path = public as $$
declare o public.opportunities%rowtype; l public.leads%rowtype; why text := btrim(coalesce(p_reason, '')); ids uuid[];
begin
  if not public.is_member() then raise exception 'Please sign in again.'; end if;
  select * into o from public.opportunities where id = p_opp for update;
  if not found or o.deleted_at is not null then raise exception 'That deal is no longer available.'; end if;
  if not (public.is_admin() or (public.is_sales() and (o.owner_id = auth.uid() or o.created_by = auth.uid()))) then
    if p_rebook then raise exception 'Only the deal owner or an admin can mark a deal Needs Rebooked.'; end if;
    if o.converted_by is distinct from auth.uid() then
      raise exception 'Only the deal owner, an admin, or the caller who booked it can send it back.';
    end if;
    if o.stage <> 'prospecting' or o.appt_showed then
      raise exception 'The salesperson has already started on this deal, so ask them or an admin to send it back.';
    end if;
  end if;
  if p_rebook and o.stage = 'closed_won' then raise exception 'This deal is Closed Won, so it can''t be rebooked.'; end if;
  if o.lead_id is null then raise exception 'This deal didn''t start as a lead, so there is no lead to send it back to.'; end if;
  select * into l from public.leads where id = o.lead_id for update;
  if not found then raise exception 'The original lead no longer exists.'; end if;
  if l.deleted_at is not null then raise exception 'The original lead is in the Trash. Ask an admin to restore it first.'; end if;
  perform set_config('dialdesk.bypass', 'on', true);
  -- An agency's deals (one per client) go back together; Closed Won ones stay.
  select coalesce(array_agg(id), '{}') into ids from public.opportunities
   where id = o.id or (l.is_agency and lead_id = l.id and deleted_at is null and stage <> 'closed_won');
  update public.opportunities set deleted_at = now(), deleted_by = auth.uid(), reverted_at = now(), reverted_by = auth.uid()
   where id = any (ids);
  update public.leads set
      status = case when p_rebook and id = l.id then 'needs_rebook' else coalesce(nullif(pre_convert_status, 'converted'), 'appointment') end,
      owner_id = coalesce(owner_id, converted_by),
      sales_owner_id = null, opportunity_id = null, converted_at = null, converted_by = null, pre_convert_status = null
   where opportunity_id = any (ids);
  insert into public.lead_notes (lead_id, author_id, body)
  values (l.id, auth.uid(), case when p_rebook then 'Needs Rebooked: sent back from the deal "' else 'Sent back from the deal "' end
    || o.deal_name || '"' || case when cardinality(ids) > 1 then ' (and ' || (cardinality(ids) - 1) || ' more deal' || case when cardinality(ids) > 2 then 's' else '' end || ' through this agency)' else '' end
    || case when why <> '' then '. Reason: ' || why else '.' end);
  perform set_config('dialdesk.bypass', 'off', true);
  return l.id;
end $$;
revoke execute on function public.revert_opportunity(uuid, text, boolean) from anon;

select 'The Ark version 24 is ready (agencies, Needs Rebooked, Agreement Submitted, deleting)' as result;
