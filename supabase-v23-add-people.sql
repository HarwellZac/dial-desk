-- =====================================================================
-- The Ark version 23: add people without an email, invite them later
--   * Owners and admins can add a person by name only. They show up everywhere right away
--     (assign leads, timesheets, reports) but can't sign in yet (profiles.email is blank).
--   * Later, "Invite" gives that person an email. When they create their account with it,
--     the account takes over everything already recorded under their name.
--   * Same rules as inviting: admins add/invite callers and salespeople; only an Owner adds
--     or invites admins and Finance people.
-- Safe to run more than once. Paste into Supabase > SQL Editor > Run.
-- =====================================================================

-- A person added without an email has no login yet, so their profile isn't tied to a login.
do $$
declare c text;
begin
  for c in select conname from pg_constraint
    where conrelid = 'public.profiles'::regclass and contype = 'f' and confrelid = 'auth.users'::regclass
  loop
    execute format('alter table public.profiles drop constraint %I', c);
  end loop;
end $$;
alter table public.profiles alter column email drop not null;

-- An invite can be for a person who is already on the team without a login.
alter table public.invites add column if not exists profile_id uuid references public.profiles(id) on delete cascade;
create unique index if not exists invites_profile_one on public.invites (profile_id) where profile_id is not null;
-- Invites for someone already on the team go through invite_member(), which checks their role.
drop policy if exists "admins create invites" on public.invites;
create policy "admins create invites" on public.invites for insert to authenticated
  with check (public.is_admin() and profile_id is null and (role in ('caller','salesperson') or public.is_owner()));

-- Who may add or invite someone with this role.
create or replace function public.can_add_role(p_role text) returns boolean
language sql stable security definer set search_path = public as $$
  select public.is_admin() and (p_role in ('caller','salesperson') or (public.is_owner() and p_role in ('admin','finance')))
$$;
revoke execute on function public.can_add_role(text) from anon;

-- Invite a person who has no login yet (or change the email on their invite).
create or replace function public.invite_member(p_user uuid, p_email text) returns void
language plpgsql security definer set search_path = public as $$
declare p public.profiles%rowtype; e text := lower(btrim(coalesce(p_email, '')));
begin
  select * into p from public.profiles where id = p_user;
  if not found then raise exception 'That person isn''t on the team.'; end if;
  if p.email is not null then raise exception '% already has an account.', p.full_name; end if;
  if not public.can_add_role(p.role) then raise exception 'Only an Owner can invite admins, Owners and Finance people.'; end if;
  if e !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then raise exception 'Type a valid email address.'; end if;
  if exists (select 1 from public.profiles where lower(email) = e) then
    raise exception '% already belongs to someone on the team.', e;
  end if;
  if exists (select 1 from public.invites where email = e and profile_id is distinct from p_user) then
    raise exception '% has already been invited.', e;
  end if;
  delete from public.invites where profile_id = p_user;
  insert into public.invites (email, role, invited_by, profile_id) values (e, p.role, auth.uid(), p_user);
end $$;
revoke execute on function public.invite_member(uuid, text) from anon;

-- Add a person by name. With an email they are invited at the same time; without one, invite them later.
create or replace function public.add_member(p_name text, p_role text, p_email text default null) returns uuid
language plpgsql security definer set search_path = public as $$
declare nid uuid := gen_random_uuid();
begin
  if not public.can_add_role(p_role) then
    if public.is_admin() then raise exception 'Only an Owner can add admins and Finance people.'; end if;
    raise exception 'Only admins and Owners can add people.';
  end if;
  if btrim(coalesce(p_name, '')) = '' then raise exception 'Type a name.'; end if;
  insert into public.profiles (id, email, full_name, role) values (nid, null, left(btrim(p_name), 80), p_role);
  if btrim(coalesce(p_email, '')) <> '' then perform public.invite_member(nid, p_email); end if;
  return nid;
end $$;
revoke execute on function public.add_member(text, text, text) from anon;

-- Move everything recorded under a no-login person onto their new account, then remove the stand-in.
-- Only called by handle_new_user (no one can run it from the page).
create or replace function public.merge_member(p_old uuid, p_new uuid, p_email text) returns void
language plpgsql security definer set search_path = public as $$
declare r record; has boolean; done text[] := '{}'; t text;
begin
  insert into public.profiles
  select (jsonb_populate_record(null::public.profiles,
    to_jsonb(o) || jsonb_build_object('id', p_new, 'email', lower(p_email)))).*
  from public.profiles o where o.id = p_old;

  -- Every column that points at a person. Triggers are paused on those tables so this
  -- doesn't show up as edits in history or bump "last updated".
  for r in
    select c.conrelid::regclass::text as tbl, a.attname as col
    from pg_constraint c join pg_attribute a on a.attrelid = c.conrelid and a.attnum = c.conkey[1]
    where c.contype = 'f' and c.confrelid = 'public.profiles'::regclass and array_length(c.conkey, 1) = 1
  loop
    execute format('select exists (select 1 from %s where %I = $1)', r.tbl, r.col) into has using p_old;
    if has then
      if not r.tbl = any(done) then
        execute format('alter table %s disable trigger user', r.tbl);
        done := done || r.tbl;
      end if;
      execute format('update %s set %I = $1 where %I = $2', r.tbl, r.col, r.col) using p_new, p_old;
    end if;
  end loop;

  -- Person ids saved inside edit history and call Undo data.
  if not 'change_log' = any(done) and not 'public.change_log' = any(done) then
    alter table public.change_log disable trigger user; done := done || 'change_log'::text;
  end if;
  update public.change_log set changes = replace(changes::text, p_old::text, p_new::text)::jsonb
    where changes::text like '%' || p_old::text || '%';
  if not 'calls' = any(done) and not 'public.calls' = any(done) then
    alter table public.calls disable trigger user; done := done || 'calls'::text;
  end if;
  update public.calls set prev = replace(prev::text, p_old::text, p_new::text)::jsonb
    where prev is not null and prev::text like '%' || p_old::text || '%';

  foreach t in array done loop
    execute format('alter table %s enable trigger user', t);
  end loop;

  delete from public.profiles where id = p_old;
end $$;
revoke execute on function public.merge_member(uuid, uuid, text) from public, anon, authenticated;

-- New sign-ups: first account is the owner; everyone else must be invited.
-- An invite for someone already on the team (added without an email) becomes that person.
create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  inv public.invites%rowtype;
begin
  if not exists (select 1 from public.profiles) then
    insert into public.profiles (id, email, full_name, role)
    values (new.id, lower(new.email), coalesce(new.raw_user_meta_data->>'full_name', ''), 'owner');
    return new;
  end if;
  select * into inv from public.invites where email = lower(new.email);
  if not found then
    raise exception 'NOT_INVITED: % has not been invited to The Ark', new.email;
  end if;
  delete from public.invites where email = lower(new.email);
  if inv.profile_id is not null and exists (select 1 from public.profiles where id = inv.profile_id and email is null) then
    perform public.merge_member(inv.profile_id, new.id, new.email);
  else
    insert into public.profiles (id, email, full_name, role)
    values (new.id, lower(new.email), coalesce(new.raw_user_meta_data->>'full_name', ''), inv.role);
  end if;
  return new;
end $$;
drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users
  for each row execute function public.handle_new_user();

select 'The Ark version 23 is ready (add people without an email)' as result;
