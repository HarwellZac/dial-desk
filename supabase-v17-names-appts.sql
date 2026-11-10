-- Dial Desk version 17: rename team members, and add appointments by hand on Reports > Appointments.
-- Paste this whole file into Supabase > SQL Editor and click Run. It is safe to run more than once.

-- Owner can rename anyone; admins can rename callers and salespeople.
create or replace function public.set_member_name(p_user uuid, p_name text) returns void
language plpgsql security definer set search_path = public as $$
declare r text;
begin
  select role into r from public.profiles where id = p_user;
  if r is null then raise exception 'That person isn''t on the team.'; end if;
  if not (public.is_owner() or (public.is_admin() and r in ('caller','salesperson')) or p_user = auth.uid()) then
    raise exception 'Only the Owner can rename admins.';
  end if;
  if btrim(coalesce(p_name, '')) = '' then raise exception 'Type a name.'; end if;
  update public.profiles set full_name = left(btrim(p_name), 80) where id = p_user;
end $$;
revoke execute on function public.set_member_name(uuid, text) from anon;

-- Appointments added by hand live with the sheet appointments (names only, no lead or deal).
alter table public.appt_history add column if not exists source text not null default 'sheet';
alter table public.appt_history add column if not exists added_by uuid references public.profiles(id) on delete set null;
grant select, insert, update, delete on public.appt_history to authenticated;
grant usage, select on sequence public.appt_history_id_seq to authenticated;

select 'Dial Desk version 17 is installed' as result;
