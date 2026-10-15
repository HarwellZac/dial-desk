-- =====================================================================
-- Dial Desk update: time clock and caller timesheets (version 7)
-- Paste into Supabase > SQL Editor > New query > Run.
-- Safe to run more than once. Nothing existing is changed or removed.
-- (The same SQL is also in supabase-setup.sql.)
-- =====================================================================

-- =====================================================================
-- Version 7: time clock (clock in / out, breaks) and caller timesheets
-- =====================================================================
-- One row per shift. Hours worked = clock_out - clock_in - break_minutes.
create table if not exists public.time_entries (
  id bigserial primary key,
  caller_id uuid not null references public.profiles(id) on delete cascade,
  clock_in timestamptz not null,
  clock_out timestamptz,
  break_minutes int not null default 0,
  break_started_at timestamptz,
  note text not null default '',
  created_by uuid references public.profiles(id) on delete set null default auth.uid(),
  created_at timestamptz not null default now(),
  updated_by uuid references public.profiles(id) on delete set null,
  updated_at timestamptz not null default now(),
  constraint time_entries_out_after_in check (clock_out is null or clock_out > clock_in),
  constraint time_entries_break_ok check (break_minutes between 0 and 1440),
  constraint time_entries_break_fits check (clock_out is null or extract(epoch from (clock_out - clock_in)) >= break_minutes * 60)
);
-- A person can only have one open shift at a time.
create unique index if not exists time_entries_one_open on public.time_entries (caller_id) where clock_out is null;
create index if not exists time_entries_caller_in on public.time_entries (caller_id, clock_in);
create index if not exists time_entries_in on public.time_entries (clock_in);
drop trigger if exists time_entries_touch on public.time_entries;
create trigger time_entries_touch before update on public.time_entries
  for each row execute function public.touch_updated_at();

-- Callers see only their own shifts; admins and the owner see and edit everyone's.
-- Callers never write to the table directly: they use clock_in(), start_break(), end_break(), set_break() and clock_out().
alter table public.time_entries enable row level security;
drop policy if exists "read time" on public.time_entries;
create policy "read time" on public.time_entries for select to authenticated
  using (public.is_member() and (caller_id = auth.uid() or public.is_admin()));
drop policy if exists "admins add time" on public.time_entries;
create policy "admins add time" on public.time_entries for insert to authenticated with check (public.is_admin());
drop policy if exists "admins edit time" on public.time_entries;
create policy "admins edit time" on public.time_entries for update to authenticated using (public.is_admin()) with check (public.is_admin());
drop policy if exists "admins remove time" on public.time_entries;
create policy "admins remove time" on public.time_entries for delete to authenticated using (public.is_admin());

create or replace function public.clock_in() returns public.time_entries
language plpgsql security definer set search_path = public as $$
declare r public.time_entries;
begin
  if not public.is_member() then raise exception 'Sign in to Dial Desk first.'; end if;
  if exists (select 1 from public.time_entries where caller_id = auth.uid() and clock_out is null) then
    raise exception 'You are already clocked in.';
  end if;
  insert into public.time_entries (caller_id, clock_in, created_by) values (auth.uid(), now(), auth.uid()) returning * into r;
  return r;
end $$;

create or replace function public.start_break() returns public.time_entries
language plpgsql security definer set search_path = public as $$
declare r public.time_entries;
begin
  select * into r from public.time_entries where caller_id = auth.uid() and clock_out is null for update;
  if not found then raise exception 'Clock in first.'; end if;
  if r.break_started_at is not null then raise exception 'You are already on a break.'; end if;
  update public.time_entries set break_started_at = now() where id = r.id returning * into r;
  return r;
end $$;

create or replace function public.end_break() returns public.time_entries
language plpgsql security definer set search_path = public as $$
declare r public.time_entries;
begin
  select * into r from public.time_entries where caller_id = auth.uid() and clock_out is null for update;
  if not found then raise exception 'You are not clocked in.'; end if;
  if r.break_started_at is null then raise exception 'You are not on a break.'; end if;
  update public.time_entries
     set break_minutes = least(1440, break_minutes + greatest(0, round(extract(epoch from (now() - break_started_at)) / 60)::int)),
         break_started_at = null
   where id = r.id returning * into r;
  return r;
end $$;

-- Type in the break length directly (0 if no break, or any odd amount). Replaces any running break timer.
create or replace function public.set_break(p_minutes int) returns public.time_entries
language plpgsql security definer set search_path = public as $$
declare r public.time_entries;
begin
  if p_minutes is null or p_minutes < 0 or p_minutes > 1440 then raise exception 'Enter break minutes from 0 to 1440.'; end if;
  update public.time_entries set break_minutes = p_minutes, break_started_at = null
   where caller_id = auth.uid() and clock_out is null returning * into r;
  if not found then raise exception 'You are not clocked in.'; end if;
  return r;
end $$;

-- Clock out. p_break = total break minutes for the shift (null = use the break timer).
create or replace function public.clock_out(p_break int default null) returns public.time_entries
language plpgsql security definer set search_path = public as $$
declare r public.time_entries; mins int;
begin
  select * into r from public.time_entries where caller_id = auth.uid() and clock_out is null for update;
  if not found then raise exception 'You are not clocked in.'; end if;
  mins := coalesce(p_break, r.break_minutes + case when r.break_started_at is null then 0
            else greatest(0, round(extract(epoch from (now() - r.break_started_at)) / 60)::int) end);
  if mins < 0 or mins > 1440 then raise exception 'Enter break minutes from 0 to 1440.'; end if;
  if extract(epoch from (now() - r.clock_in)) < mins * 60 then
    raise exception 'The break is longer than the shift. Lower the break minutes.';
  end if;
  update public.time_entries set clock_out = now(), break_minutes = mins, break_started_at = null
   where id = r.id returning * into r;
  return r;
end $$;

-- ---------- Access (row level security above still decides who sees what) ----------
grant select, insert, update, delete on public.time_entries to authenticated;
grant usage, select on sequence public.time_entries_id_seq to authenticated;
grant execute on function public.clock_in(), public.start_break(), public.end_break(), public.set_break(int), public.clock_out(int) to authenticated;
revoke execute on function public.clock_in() from anon;
revoke execute on function public.start_break() from anon;
revoke execute on function public.end_break() from anon;
revoke execute on function public.set_break(int) from anon;
revoke execute on function public.clock_out(int) from anon;

select 'Time clock is ready' as result;
