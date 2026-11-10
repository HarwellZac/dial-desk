-- Dial Desk version 18: full names for Jeremy McCaslin and Trenton Hatley on the Appointments report.
-- Paste this whole file into Supabase > SQL Editor and click Run. It is safe to run more than once.

-- Sheet and hand-added appointments
update public.appt_history set sales_rep = 'Jeremy McCaslin' where sales_rep ilike 'jeremy mcc%' or btrim(sales_rep) ilike 'jeremy';
update public.appt_history set csr       = 'Trenton Hatley'  where csr ilike 'trenton hat%' or btrim(csr) ilike 'trenton';
update public.appt_history set sales_rep = 'Trenton Hatley'  where sales_rep ilike 'trenton hat%';
update public.appt_history set csr       = 'Jeremy McCaslin' where csr ilike 'jeremy mcc%';

-- Trenton's Dial Desk account, so his sheet appointments line up with him (only if exactly one Trenton is on the team)
update public.profiles set full_name = 'Trenton Hatley'
where (full_name ilike 'trenton%' or (btrim(full_name) = '' and email ilike 'trenton%'))
  and (select count(*) from public.profiles where full_name ilike 'trenton%' or (btrim(full_name) = '' and email ilike 'trenton%')) = 1;

select (select count(*) from public.appt_history where sales_rep = 'Jeremy McCaslin') || ' appointments for Jeremy McCaslin, '
    || (select count(*) from public.appt_history where csr = 'Trenton Hatley') || ' for Trenton Hatley. Trenton''s account: '
    || coalesce((select string_agg(coalesce(nullif(full_name,''), email), ', ') from public.profiles where full_name = 'Trenton Hatley'), 'not renamed, use Rename on the Team page')
  as result;
