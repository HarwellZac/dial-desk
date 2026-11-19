-- =====================================================================
-- The Ark version 25: "Needs Rebooked" sorts last when the Leads list is sorted by status.
-- Safe to run more than once. Paste into Supabase > SQL Editor > Run.
-- =====================================================================
alter table public.leads drop column if exists status_rank;
alter table public.leads add column status_rank int generated always as (
  case status when 'new' then 1 when 'call1' then 2 when 'call2' then 3 when 'call3' then 4 when 'engaged' then 5 when 'has_agency' then 6
    when 'on_ice' then 7 when 'already_opp' then 8 when 'gatekeeper' then 9 when 'appointment' then 10 when 'converted' then 11
    when 'bad_info' then 12 when 'dead' then 13 when 'needs_rebook' then 14 else 15 end) stored;

select 'The Ark version 25 is ready (Needs Rebooked sorts last)' as result;
