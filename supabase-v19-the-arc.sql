-- =====================================================================
-- The Arc, version 19 (was Dial Desk)
--   * More than one Owner: Dan Newman becomes an Owner. The first Owner account (the main Owner) can't be changed by anyone else.
--   * Leads that callers mark 3rd Call, Already Opportunity, Dead or Bad Information still go back to the main Owner.
--   * Has Agency: the agency becomes its own lead for the same caller, noting the company it represents.
--   * Salespeople can add leads (they own them).
--   * Clients: owner, agency, client source, deal type, follow-up date, billing and content contacts.
--     Salespeople edit only the clients they own or created; everyone in sales can see them all.
--   * Agencies: agency source, billing and content contacts.
--   * Deals: billing and content contacts, new deal type "New Client, Returning Agency".
--   * File attachments on deals, clients and agencies.
-- Paste this whole file into Supabase > SQL Editor > New query and click Run. It is safe to run more than once.
-- =====================================================================

-- ---------- Owners --------------------------------------------------------
-- The main Owner is the first Owner account ever made.
create or replace function public.main_owner() returns uuid
language sql stable security definer set search_path = public as $$
  select id from public.profiles where role = 'owner' order by created_at limit 1
$$;

create or replace function public.set_member(p_user uuid, p_role text, p_active boolean) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_owner() then raise exception 'Only an Owner can change roles.'; end if;
  if p_user = auth.uid() then raise exception 'You can''t change your own role.'; end if;
  if p_user = public.main_owner() then raise exception 'The main Owner account can''t be changed.'; end if;
  if p_role not in ('owner','admin','salesperson','caller') then raise exception 'Unknown role.'; end if;
  update public.profiles set role = p_role, active = coalesce(p_active, true) where id = p_user;
end $$;

-- Dan Newman gets Owner access (only if exactly one Dan Newman is on the team, and never the main Owner).
update public.profiles set role = 'owner'
where lower(btrim(full_name)) like 'dan newman%' and role <> 'owner' and active
  and (select count(*) from public.profiles where lower(btrim(full_name)) like 'dan newman%') = 1;

-- ---------- Calls: callers' dead-end leads go back to the main Owner ---------
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
  -- Callers' leads go back to the main Owner (the first Owner account). Salespeople keep their own leads.
  if p_status in ('call3','already_opp','dead','bad_info') and not public.is_sales() then
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

-- ---------- Has Agency: the agency becomes a lead for the same caller ----------
alter table public.leads add column if not exists agency_for text not null default '';
alter table public.leads add column if not exists agency_lead_id uuid;

drop trigger if exists leads_history on public.leads;
create trigger leads_history after update on public.leads for each row execute function public.log_changes(
  'first_name','last_name','title','company','phone','mobile','company_phone','email','address','city','state','zip',
  'industry','website','employees','revenue','linkedin','about','agency_name','agency_contact','agency_phone','agency_email','agency_for',
  'status','owner_id','sales_owner_id','callback_at','appt_at','appt_rep','deleted_at');

-- Finds the agency's lead (same name, phone or email) or makes a new one for the caller who has this lead,
-- and notes on it which company the agency represents. Returns {id, created, owner, mine}.
create or replace function public.link_agency_lead(p_lead uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  l public.leads%rowtype; a public.leads%rowtype; made boolean := false; nm text; co text; pk text; ek text; who text; fn text;
begin
  if not public.is_member() then raise exception 'Please sign in again.'; end if;
  select * into l from public.leads where id = p_lead for update;
  if not found or l.deleted_at is not null then raise exception 'That lead is no longer available.'; end if;
  if not (public.is_admin() or l.owner_id = auth.uid() or (public.is_sales() and l.sales_owner_id = auth.uid())) then
    raise exception 'This lead belongs to another caller.';
  end if;
  nm := btrim(l.agency_name);
  if nm = '' then return null; end if;
  co := coalesce(nullif(btrim(l.company), ''), nullif(btrim(l.first_name || ' ' || l.last_name), ''), 'a lead');
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
    insert into public.leads (company, first_name, last_name, phone, email, owner_id, source, agency_for, about)
    values (nm, fn, btrim(substr(btrim(l.agency_contact), length(fn) + 1)), btrim(l.agency_phone), btrim(l.agency_email),
      coalesce(l.owner_id, auth.uid()), 'Agency for ' || co || ' (added by ' || who || ')', co,
      'Agency that represents ' || co || '.')
    returning * into a;
    made := true;
  end if;
  if made or position(lower(co) in lower(a.agency_for)) = 0 then
    if not made then
      update public.leads set agency_for = case when agency_for = '' then co else agency_for || ', ' || co end where id = a.id;
    end if;
    insert into public.lead_notes (lead_id, author_id, body)
    values (a.id, auth.uid(), 'Agency for ' || co || '. ' || who || ' marked ' || co || ' as Has Agency'
      || case when btrim(l.agency_contact) <> '' then ' (agency contact: ' || btrim(l.agency_contact) || ')' else '' end || '.');
  end if;
  if l.agency_lead_id is distinct from a.id then
    update public.leads set agency_lead_id = a.id where id = l.id;
  end if;
  return jsonb_build_object('id', a.id, 'created', made, 'mine', a.owner_id = auth.uid(),
    'owner', coalesce((select coalesce(nullif(full_name, ''), email) from public.profiles where id = a.owner_id), 'nobody'));
end $$;

-- Undo for link_agency_lead(): unlinks, and removes the agency lead again if it was just made and nobody has worked it.
create or replace function public.unlink_agency_lead(p_lead uuid, p_agency uuid, p_created boolean default false) returns void
language plpgsql security definer set search_path = public as $$
declare l public.leads%rowtype; a public.leads%rowtype; co text;
begin
  if not public.is_member() then raise exception 'Please sign in again.'; end if;
  select * into l from public.leads where id = p_lead for update;
  if not found then return; end if;
  if not (public.is_admin() or l.owner_id = auth.uid() or (public.is_sales() and l.sales_owner_id = auth.uid())) then
    raise exception 'This lead belongs to another caller.';
  end if;
  co := coalesce(nullif(btrim(l.company), ''), nullif(btrim(l.first_name || ' ' || l.last_name), ''), 'a lead');
  update public.leads set agency_lead_id = null where id = p_lead and agency_lead_id = p_agency;
  select * into a from public.leads where id = p_agency for update;
  if not found then return; end if;
  if p_created and a.attempts = 0 and a.status = 'new' and not exists (select 1 from public.calls where lead_id = a.id) then
    delete from public.leads where id = a.id;
  else
    update public.leads set agency_for = array_to_string(array_remove(string_to_array(agency_for, ', '), co), ', ') where id = a.id;
    delete from public.lead_notes where id = (select id from public.lead_notes where lead_id = a.id and author_id = auth.uid()
      and body like 'Agency for ' || co || '.%' and created_at > now() - interval '1 day' order by created_at desc limit 1);
  end if;
end $$;

-- ---------- Salespeople can add leads (owned by them) ----------
create or replace function public.create_lead(p jsonb, p_owner uuid default null)
returns uuid language plpgsql security definer set search_path = public as $$
declare
  pk text; mk text; ek text; own uuid; new_id uuid; hit public.leads%rowtype;
begin
  if not public.is_member() then raise exception 'Please sign in again.'; end if;
  own := case when public.is_admin() then p_owner else auth.uid() end;
  if btrim(coalesce(p->>'company','')) = '' and btrim(coalesce(p->>'first_name','')) = ''
     and btrim(coalesce(p->>'last_name','')) = '' then
    raise exception 'Add a company or a contact name.';
  end if;
  pk := right(regexp_replace(coalesce(p->>'phone', ''), '[^0-9]', '', 'g'), 10);
  mk := right(regexp_replace(coalesce(p->>'mobile', ''), '[^0-9]', '', 'g'), 10);
  ek := lower(btrim(coalesce(p->>'email', '')));
  select * into hit from public.leads l where l.deleted_at is null and (
       (length(pk) = 10 and (l.phone_key = pk or l.mobile_key = pk))
    or (length(mk) = 10 and (l.phone_key = mk or l.mobile_key = mk))
    or (ek <> '' and l.email_key = ek)) limit 1;
  if found then
    raise exception 'This lead is already in The Arc (% · %). Ask an admin if you need it.',
      coalesce(nullif(hit.company,''), btrim(hit.first_name || ' ' || hit.last_name)),
      coalesce((select coalesce(nullif(full_name,''), email) from public.profiles where id = hit.owner_id), 'unassigned');
  end if;
  insert into public.leads (first_name, last_name, title, company, phone, mobile, company_phone, email,
    address, city, state, zip, industry, website, employees, revenue, linkedin, about, owner_id, source)
  values (btrim(coalesce(p->>'first_name','')), btrim(coalesce(p->>'last_name','')), btrim(coalesce(p->>'title','')),
    btrim(coalesce(p->>'company','')), btrim(coalesce(p->>'phone','')), btrim(coalesce(p->>'mobile','')),
    btrim(coalesce(p->>'company_phone','')), btrim(coalesce(p->>'email','')), btrim(coalesce(p->>'address','')),
    btrim(coalesce(p->>'city','')), btrim(coalesce(p->>'state','')), btrim(coalesce(p->>'zip','')),
    btrim(coalesce(p->>'industry','')), btrim(coalesce(p->>'website','')), btrim(coalesce(p->>'employees','')),
    btrim(coalesce(p->>'revenue','')), btrim(coalesce(p->>'linkedin','')), left(btrim(coalesce(p->>'about','')), 2000),
    own, 'Added by ' || coalesce((select coalesce(nullif(full_name,''), email) from public.profiles where id = auth.uid()), 'hand'))
  returning id into new_id;
  return new_id;
end $$;

-- ---------- Agencies: source, billing and content contacts ----------
alter table public.agencies add column if not exists source text not null default '';
alter table public.agencies add column if not exists billing_contact jsonb not null default '{}'::jsonb;
alter table public.agencies add column if not exists content_contact jsonb not null default '{}'::jsonb;

-- ---------- Deals: billing and content contacts, new deal type ----------
alter table public.opportunities add column if not exists billing_contact jsonb not null default '{}'::jsonb;
alter table public.opportunities add column if not exists content_contact jsonb not null default '{}'::jsonb;
alter table public.opportunities drop constraint if exists opportunities_type_check;
alter table public.opportunities add constraint opportunities_type_check check (type in ('first_deal','returning','new_returning_agency'));

drop trigger if exists opps_history on public.opportunities;
create trigger opps_history after insert or update on public.opportunities for each row execute function public.log_changes(
  'deal_name','client_id','agency_id','owner_id','type','stage','probability','amount','follow_up_date','lead_source',
  'description','products','appt_at','appt_showed','appt_company','appt_notes','contact_name','converted_by','reverted_at','deleted_at',
  'billing_contact','content_contact');

-- ---------- Clients: owner, agency, source, deal type, follow up, contacts ----------
alter table public.clients add column if not exists owner_id uuid references public.profiles(id) on delete set null;
alter table public.clients alter column owner_id set default auth.uid();
alter table public.clients add column if not exists agency_id uuid references public.agencies(id) on delete set null;
alter table public.clients add column if not exists client_source text not null default '';
alter table public.clients add column if not exists client_type text not null default 'first_deal';
alter table public.clients drop constraint if exists clients_type_check;
alter table public.clients add constraint clients_type_check check (client_type in ('first_deal','returning','new_returning_agency'));
alter table public.clients add column if not exists follow_up_date date;
alter table public.clients add column if not exists billing_contact jsonb not null default '{}'::jsonb;
alter table public.clients add column if not exists content_contact jsonb not null default '{}'::jsonb;
create index if not exists clients_owner_idx on public.clients (owner_id);
create index if not exists clients_agency_idx on public.clients (agency_id);

-- Fill in clients made before version 19 from their deals (quietly, without filling the history).
alter table public.clients disable trigger clients_history;
update public.clients c set owner_id = coalesce(
    (select o.owner_id from public.opportunities o where o.client_id = c.id and o.deleted_at is null and o.owner_id is not null order by o.created_at limit 1),
    c.created_by)
 where c.owner_id is null;
update public.clients c set agency_id =
    (select o.agency_id from public.opportunities o where o.client_id = c.id and o.deleted_at is null and o.agency_id is not null order by o.created_at desc limit 1)
 where c.agency_id is null;
update public.clients c set client_source = coalesce(
    (select o.lead_source from public.opportunities o where o.client_id = c.id and o.deleted_at is null and o.lead_source <> '' order by o.created_at limit 1), '')
 where c.client_source = '';
alter table public.clients enable trigger clients_history;

drop trigger if exists clients_history on public.clients;
create trigger clients_history after update on public.clients for each row execute function public.log_changes(
  'name','phone','website','industry','employees','revenue','address','city','state','zip','country','description',
  'owner_id','agency_id','client_source','client_type','follow_up_date','billing_contact','content_contact');

-- Only admins and Owners change who owns a client; who made it never changes.
create or replace function public.guard_clients() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'UPDATE' then
    new.created_by := old.created_by;
    new.created_at := old.created_at;
    if auth.uid() is not null and not public.is_admin() and coalesce(current_setting('dialdesk.bypass', true), '') <> 'on'
       and new.owner_id is distinct from old.owner_id then
      raise exception 'Only admins can change who owns a client.';
    end if;
  end if;
  return new;
end $$;
drop trigger if exists clients_guard on public.clients;
create trigger clients_guard before update on public.clients for each row execute function public.guard_clients();

-- Everyone in sales sees every client; salespeople edit the clients they own or created.
drop policy if exists "edit clients" on public.clients;
create policy "edit clients" on public.clients for update to authenticated
  using (public.is_admin() or (public.is_sales() and (owner_id = auth.uid() or created_by = auth.uid())))
  with check (public.is_admin() or (public.is_sales() and (owner_id = auth.uid() or created_by = auth.uid())));

-- Find or make a client. New: owner_id, agency_id, client_source and client_type can be passed in p_fields.
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

-- Appointment Set!: the new client belongs to the salesperson, gets the agency, and its source is Call Center.
create or replace function public.convert_lead(
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
    'employees', l.employees, 'revenue', l.revenue, 'address', l.address, 'city', l.city, 'state', l.state, 'zip', l.zip,
    'owner_id', p_sales, 'client_source', 'Call Center'));
  aid := public.ensure_agency(coalesce(nullif(btrim(p_agency), ''), l.agency_name));
  -- Agency details the caller collected fill in any blanks on the agency.
  if aid is not null then
    update public.agencies set contact_name = case when contact_name = '' then l.agency_contact else contact_name end,
      phone = case when phone = '' then l.agency_phone else phone end, email = case when email = '' then l.agency_email else email end
    where id = aid;
    update public.agencies set source = 'Call Center' where id = aid and source = '';
  end if;
  if l.about <> '' then update public.clients set description = l.about where id = cid and description = ''; end if;
  if aid is not null then update public.clients set agency_id = aid where id = cid and agency_id is null; end if;
  insert into public.opportunities (deal_name, client_id, agency_id, owner_id, type, stage, probability, amount,
    follow_up_date, lead_source, description, products, contact_name, contact_title, contact_email, contact_phone,
    lead_id, converted_by, created_by, appt_at, appt_company)
  values (btrim(p_deal), cid, aid, p_sales, coalesce(p_type, 'first_deal'), coalesce(p_stage, 'prospecting'),
    public.stage_probability(coalesce(p_stage, 'prospecting')), p_amount,
    coalesce(p_follow_up, (p_appt_at at time zone 'America/Chicago')::date),
    'Call Center', coalesce(p_description, ''), coalesce(p_products, '{}'),
    btrim(l.first_name || ' ' || l.last_name), l.title, l.email, coalesce(nullif(l.phone, ''), l.mobile),
    l.id, auth.uid(), auth.uid(), coalesce(p_appt_at, l.appt_at), btrim(p_client))
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

-- ---------- File attachments on deals, clients and agencies ----------
create table if not exists public.attachments (
  id uuid primary key default gen_random_uuid(),
  kind text not null check (kind in ('opp','client','agency')),
  parent_id uuid not null,
  name text not null check (length(btrim(name)) > 0),
  path text not null unique,
  size bigint not null default 0,
  mime text not null default '',
  uploaded_by uuid references public.profiles(id) on delete set null default auth.uid(),
  created_at timestamptz not null default now()
);
create index if not exists attachments_parent_idx on public.attachments (parent_id, created_at desc);

-- Who may add files: admins and Owners anywhere; salespeople on deals and clients they own or created, and on any agency.
create or replace function public.can_attach(p_kind text, p_id uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select public.is_admin() or (public.can_sell() and case p_kind
    when 'agency' then true
    when 'opp' then exists (select 1 from public.opportunities o where o.id = p_id and o.deleted_at is null and (o.owner_id = auth.uid() or o.created_by = auth.uid()))
    when 'client' then exists (select 1 from public.clients c where c.id = p_id and (c.owner_id = auth.uid() or c.created_by = auth.uid()))
    else false end)
$$;

alter table public.attachments enable row level security;
drop policy if exists "read attachments" on public.attachments;
create policy "read attachments" on public.attachments for select to authenticated using (public.can_sell());
drop policy if exists "add attachments" on public.attachments;
create policy "add attachments" on public.attachments for insert to authenticated
  with check (uploaded_by = auth.uid() and public.can_attach(kind, parent_id));
drop policy if exists "remove attachments" on public.attachments;
create policy "remove attachments" on public.attachments for delete to authenticated
  using (public.is_admin() or (public.can_sell() and uploaded_by = auth.uid()));
grant select, insert, update, delete on public.attachments to authenticated;

-- The files themselves live in a private storage bucket (50 MB per file).
insert into storage.buckets (id, name, public, file_size_limit)
values ('attachments', 'attachments', false, 52428800)
on conflict (id) do update set public = false, file_size_limit = 52428800;
drop policy if exists "arc read files" on storage.objects;
create policy "arc read files" on storage.objects for select to authenticated
  using (bucket_id = 'attachments' and public.can_sell());
drop policy if exists "arc add files" on storage.objects;
create policy "arc add files" on storage.objects for insert to authenticated
  with check (bucket_id = 'attachments' and public.can_sell());
drop policy if exists "arc remove files" on storage.objects;
create policy "arc remove files" on storage.objects for delete to authenticated
  using (bucket_id = 'attachments' and (public.is_admin() or owner_id = auth.uid()::text));

-- ---------- Access ----------
revoke execute on function public.main_owner() from anon;
revoke execute on function public.set_member(uuid, text, boolean) from anon;
revoke execute on function public.link_agency_lead(uuid) from anon;
revoke execute on function public.unlink_agency_lead(uuid, uuid, boolean) from anon;
revoke execute on function public.create_lead(jsonb, uuid) from anon;
revoke execute on function public.ensure_client(text, jsonb) from anon;
revoke execute on function public.can_attach(text, uuid) from anon;
revoke execute on function public.convert_lead(uuid, uuid, text, text, text, text, text, numeric, date, timestamptz, text, text[]) from anon;
revoke execute on function public.log_call(uuid, text, text, timestamptz, timestamptz, text) from anon;

select 'The Arc is up to date. Owners: ' || coalesce((select string_agg(coalesce(nullif(full_name,''), email), ', ' order by created_at) from public.profiles where role = 'owner' and active), 'none')
  || '. Leads marked Dead, Bad Info, Already Opportunity or 3rd Call go to: ' || coalesce((select coalesce(nullif(full_name,''), email) from public.profiles where id = public.main_owner()), 'nobody') || '.' as result;
