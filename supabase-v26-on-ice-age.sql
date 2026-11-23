-- =====================================================================
-- The Ark version 26: how long leads have been On Ice (Reusable after 6 months)
--   * leads.on_ice_at = when the lead went On Ice (3rd Call). Set automatically whenever a
--     lead becomes On Ice, cleared when it leaves On Ice.
--   * on_ice_report(): every live On Ice lead with that date, for Reports > Lead stats.
-- Safe to run more than once. Paste into Supabase > SQL Editor > Run.
-- =====================================================================

alter table public.leads add column if not exists on_ice_at timestamptz;
create index if not exists leads_on_ice_idx on public.leads (on_ice_at) where status = 'on_ice';

create or replace function public.stamp_on_ice() returns trigger
language plpgsql as $$
begin
  if new.status = 'on_ice' then
    if tg_op = 'INSERT' or old.status is distinct from 'on_ice' or new.on_ice_at is null then
      new.on_ice_at := coalesce(case when tg_op = 'UPDATE' and old.status = 'on_ice' then old.on_ice_at end, now());
    end if;
  else
    new.on_ice_at := null;
  end if;
  return new;
end $$;
drop trigger if exists leads_on_ice on public.leads;
create trigger leads_on_ice before insert or update of status, on_ice_at on public.leads
  for each row execute function public.stamp_on_ice();

-- Leads already On Ice: the date of their 3rd Call, else when the history shows them going On Ice,
-- else their last call, else when they were added (imported On Ice).
alter table public.leads disable trigger user;
update public.leads l set on_ice_at = coalesce(
    (select max(c.created_at) from public.calls c where c.lead_id = l.id and c.status = 'call3'),
    (select max(h.created_at) from public.change_log h where h.row_id = l.id and h.changes->'status'->>1 = 'on_ice'),
    l.last_call_at, l.created_at)
 where l.status = 'on_ice' and l.on_ice_at is null;
alter table public.leads enable trigger user;

create or replace function public.on_ice_report()
returns table (id uuid, company text, first_name text, last_name text, phone text, mobile text, company_phone text,
  owner_id uuid, on_ice_at timestamptz, last_call_at timestamptz, attempts int)
language sql stable security definer set search_path = public as $$
  select l.id, l.company, l.first_name, l.last_name, l.phone, l.mobile, l.company_phone, l.owner_id,
    coalesce(l.on_ice_at, l.last_call_at, l.created_at), l.last_call_at, l.attempts
  from public.leads l
  where public.is_admin() and l.deleted_at is null and l.status = 'on_ice'
  order by coalesce(l.on_ice_at, l.last_call_at, l.created_at)
$$;
revoke execute on function public.on_ice_report() from anon;

select 'The Ark version 26 is ready (On Ice age, Reusable leads)' as result;
