-- =====================================================================
-- Dial Desk update: lead stats, combined lead filters, callers can reassign (version 9)
-- Paste into Supabase > SQL Editor > New query > Run.
-- Run the version 7 and version 8 SQL first if you haven't yet.
-- Safe to run more than once. Nothing is deleted.
-- (The same SQL is also in supabase-setup.sql.)
-- =====================================================================

-- =====================================================================
-- Version 9: lead stats report, combined lead filters, callers can reassign their leads
-- =====================================================================
-- Status counts for the Leads chips, now honoring the extra filters (state, industry, last contact, callback).
drop function if exists public.status_counts(uuid, boolean, text, boolean);
create or replace function public.status_counts(p_owner uuid default null, p_unassigned boolean default false,
  p_search text default '', p_trash boolean default false, p_state text default '', p_industry text default '',
  p_never boolean default false, p_last_before timestamptz default null, p_last_after timestamptz default null,
  p_callback text default '')
returns table (status text, n bigint) language sql stable set search_path = public as $$
  select l.status, count(*) from public.leads l
  where (l.deleted_at is not null) = coalesce(p_trash, false)
    and (p_owner is null or l.owner_id = p_owner)
    and (not coalesce(p_unassigned, false) or l.owner_id is null)
    and (coalesce(p_search, '') = '' or l.search_text like '%' || p_search || '%')
    and (coalesce(p_state, '') = '' or l.state ilike p_state)
    and (coalesce(p_industry, '') = '' or l.industry ilike '%' || p_industry || '%')
    and (not coalesce(p_never, false) or l.last_call_at is null)
    and (p_last_before is null or l.last_call_at < p_last_before)
    and (p_last_after is null or l.last_call_at >= p_last_after)
    and (coalesce(p_callback, '') = ''
      or (p_callback = 'due' and l.callback_at <= now())
      or (p_callback = 'upcoming' and l.callback_at > now())
      or (p_callback = 'none' and l.callback_at is null))
  group by l.status
$$;

-- Lead stats (admins): live leads per caller per status, with never-called, overdue-callback and gone-cold counts.
create or replace function public.lead_status_report()
returns table (owner_id uuid, status text, n bigint, never_called bigint, callbacks_due bigint, stale30 bigint)
language sql stable security definer set search_path = public as $$
  select l.owner_id, l.status, count(*),
    count(*) filter (where l.last_call_at is null),
    count(*) filter (where l.callback_at <= now() and l.status in ('new','call1','call2','call3','gatekeeper')),
    count(*) filter (where l.last_call_at < now() - interval '30 days' and l.status in ('new','call1','call2','call3','gatekeeper'))
  from public.leads l
  where public.is_admin() and l.deleted_at is null
  group by l.owner_id, l.status
$$;

-- Callers can hand one of their leads to someone else. It shows in the lead's history as a change of Caller, by them.
create or replace function public.reassign_lead(p_lead uuid, p_to uuid, p_note text default '') returns void
language plpgsql security definer set search_path = public as $$
declare l public.leads%rowtype; why text := btrim(coalesce(p_note, ''));
begin
  if not public.is_member() then raise exception 'Please sign in again.'; end if;
  select * into l from public.leads where id = p_lead for update;
  if not found or l.deleted_at is not null then raise exception 'That lead is no longer available.'; end if;
  if not (public.is_admin() or l.owner_id = auth.uid()) then raise exception 'You can only reassign your own leads.'; end if;
  if not exists (select 1 from public.profiles where id = p_to and active and role in ('caller','admin','owner')) then
    raise exception 'Choose an active caller.';
  end if;
  if l.owner_id is not distinct from p_to then raise exception 'That lead is already assigned to them.'; end if;
  update public.leads set owner_id = p_to where id = p_lead;
  if why <> '' then
    insert into public.lead_notes (lead_id, author_id, body) values (p_lead, auth.uid(), 'Reassigned: ' || why);
  end if;
end $$;

-- ---------- Access ----------
grant execute on function public.status_counts(uuid, boolean, text, boolean, text, text, boolean, timestamptz, timestamptz, text),
  public.lead_status_report(), public.reassign_lead(uuid, uuid, text) to authenticated;
revoke execute on function public.lead_status_report() from anon;
revoke execute on function public.reassign_lead(uuid, uuid, text) from anon;

select 'Dial Desk version 9 is ready' as result;
