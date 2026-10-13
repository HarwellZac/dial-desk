-- =====================================================================
-- Dial Desk: make the first login the Owner
-- Paste into Supabase > SQL Editor > New query > Run.
-- Safe to run more than once.
-- =====================================================================

-- 1. Make sure signed-in users can reach the Dial Desk tables and actions.
--    (Row level security still decides what each person can see.)
grant usage on schema public to anon, authenticated;
grant select, insert, update, delete on all tables in schema public to authenticated;
grant usage, select on all sequences in schema public to authenticated;
grant execute on all functions in schema public to authenticated;

-- 2. If nobody is the Owner yet, make the earliest login the Owner.
insert into public.profiles (id, email, full_name, role, active)
select u.id, lower(u.email), coalesce(u.raw_user_meta_data->>'full_name', ''), 'owner', true
from auth.users u
where not exists (select 1 from public.profiles where role = 'owner')
order by u.created_at
limit 1
on conflict (id) do update set role = 'owner', active = true;

-- 3. Show the result. You should see your email with role "owner".
select p.email, p.role, p.active,
       (select count(*) from pg_trigger where tgname = 'on_auth_user_created') as signup_rule_installed
from public.profiles p
order by p.created_at;
