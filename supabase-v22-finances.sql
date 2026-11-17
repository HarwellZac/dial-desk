-- The Ark version 22: Finances
--   * New role "finance" (sees only the Finances tab) and a Finance access switch (profiles.finance)
--     the Owner can turn on for any admin or salesperson. Owners always have Finance access.
--   * Per Closed Won deal: invoices (payment plans), commissions (any number of salespeople),
--     allocations (TBN Linear / TBN+ / ... with a secondary allocation) and finance files.
-- Safe to run more than once. Paste into Supabase > SQL Editor > Run.

-- ---------- Role and permission ----------
alter table public.profiles drop constraint if exists profiles_role_check;
alter table public.profiles add constraint profiles_role_check check (role in ('owner','admin','salesperson','caller','finance'));
alter table public.invites drop constraint if exists invites_role_check;
alter table public.invites add constraint invites_role_check check (role in ('admin','salesperson','caller','finance'));
alter table public.profiles add column if not exists finance boolean not null default false;

-- Finance access: Owners, the Finance role, and anyone the Owner switched Finance on for.
create or replace function public.can_finance() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from profiles where id = auth.uid() and active and (role in ('owner','finance') or finance))
$$;
revoke execute on function public.can_finance() from anon;

-- (Inviting: the existing "admins create invites" policy already lets only an Owner invite anyone
--  other than callers and salespeople, so only an Owner can invite a Finance person.)

create or replace function public.set_member(p_user uuid, p_role text, p_active boolean) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_owner() then raise exception 'Only an Owner can change roles.'; end if;
  if p_user = auth.uid() then raise exception 'You can''t change your own role.'; end if;
  if p_user = public.main_owner() then raise exception 'The main Owner account can''t be changed.'; end if;
  if p_role not in ('owner','admin','salesperson','caller','finance') then raise exception 'Unknown role.'; end if;
  update public.profiles set role = p_role, active = coalesce(p_active, true) where id = p_user;
end $$;

-- The Owner turns Finance access on or off for one person.
create or replace function public.set_finance(p_user uuid, p_on boolean) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_owner() then raise exception 'Only an Owner can change Finance access.'; end if;
  update public.profiles set finance = coalesce(p_on, false) where id = p_user;
end $$;
revoke execute on function public.set_finance(uuid, boolean) from anon;

-- People can't give themselves Finance access by editing their own profile row.
create or replace function public.guard_profile_finance() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.finance is distinct from old.finance and auth.uid() is not null and not public.is_owner() then
    raise exception 'Only an Owner can change Finance access.';
  end if;
  return new;
end $$;
drop trigger if exists profiles_finance_guard on public.profiles;
create trigger profiles_finance_guard before update on public.profiles for each row execute function public.guard_profile_finance();

-- Finance people read Closed Won deals (and any deal that already has finance records).
drop policy if exists "finance reads deals" on public.opportunities;
create policy "finance reads deals" on public.opportunities for select to authenticated using (public.can_finance());

-- ---------- Invoices (a deal can have several: payment plans) ----------
create table if not exists public.deal_invoices (
  id uuid primary key default gen_random_uuid(),
  opp_id uuid not null references public.opportunities(id) on delete cascade,
  invoice_no text not null default '',
  amount numeric(14,2),
  due_date date,
  ar_submitted_on date,
  sent_on date,
  paid_on date,
  notes text not null default '',
  created_by uuid references public.profiles(id) on delete set null default auth.uid(),
  created_at timestamptz not null default now(),
  updated_by uuid references public.profiles(id) on delete set null,
  updated_at timestamptz not null default now()
);
create index if not exists deal_invoices_opp_idx on public.deal_invoices (opp_id, due_date);

-- ---------- Commissions (any number of salespeople, each with their own rate) ----------
create table if not exists public.deal_commissions (
  id uuid primary key default gen_random_uuid(),
  opp_id uuid not null references public.opportunities(id) on delete cascade,
  person_id uuid references public.profiles(id) on delete set null,
  person_name text not null default '',
  rate numeric(6,3),                 -- percent: 2, 3, 4, 7.5 or a custom percent
  manual_amount numeric(14,2),       -- Custom/Manual: a typed dollar amount instead of a percent
  paid_on date,                      -- when the commission was paid out
  notes text not null default '',
  created_by uuid references public.profiles(id) on delete set null default auth.uid(),
  created_at timestamptz not null default now(),
  updated_by uuid references public.profiles(id) on delete set null,
  updated_at timestamptz not null default now(),
  check (rate is not null or manual_amount is not null),
  check (rate is null or (rate >= 0 and rate <= 100))
);
create index if not exists deal_commissions_opp_idx on public.deal_commissions (opp_id);

-- ---------- Allocations (on the deal, not the invoice) ----------
create table if not exists public.deal_allocations (
  id uuid primary key default gen_random_uuid(),
  opp_id uuid not null references public.opportunities(id) on delete cascade,
  allocation text not null check (length(btrim(allocation)) > 0),
  secondary text not null default 'None',
  amount numeric(14,2),
  notes text not null default '',
  created_by uuid references public.profiles(id) on delete set null default auth.uid(),
  created_at timestamptz not null default now(),
  updated_by uuid references public.profiles(id) on delete set null,
  updated_at timestamptz not null default now()
);
create index if not exists deal_allocations_opp_idx on public.deal_allocations (opp_id);

-- updated_at / updated_by on every edit
create or replace function public.touch_fin() returns trigger
language plpgsql set search_path = public as $$
begin new.updated_at := now(); new.updated_by := auth.uid(); return new; end $$;
drop trigger if exists deal_invoices_touch on public.deal_invoices;
create trigger deal_invoices_touch before update on public.deal_invoices for each row execute function public.touch_fin();
drop trigger if exists deal_commissions_touch on public.deal_commissions;
create trigger deal_commissions_touch before update on public.deal_commissions for each row execute function public.touch_fin();
drop trigger if exists deal_allocations_touch on public.deal_allocations;
create trigger deal_allocations_touch before update on public.deal_allocations for each row execute function public.touch_fin();

-- Only Finance people read or change any of it.
alter table public.deal_invoices enable row level security;
alter table public.deal_commissions enable row level security;
alter table public.deal_allocations enable row level security;
drop policy if exists "finance invoices" on public.deal_invoices;
create policy "finance invoices" on public.deal_invoices for all to authenticated using (public.can_finance()) with check (public.can_finance());
drop policy if exists "finance commissions" on public.deal_commissions;
create policy "finance commissions" on public.deal_commissions for all to authenticated using (public.can_finance()) with check (public.can_finance());
drop policy if exists "finance allocations" on public.deal_allocations;
create policy "finance allocations" on public.deal_allocations for all to authenticated using (public.can_finance()) with check (public.can_finance());
grant select, insert, update, delete on public.deal_invoices, public.deal_commissions, public.deal_allocations to authenticated;

-- ---------- Finance files (attachments kind 'fin', stored under fin/<deal id>/) ----------
alter table public.attachments drop constraint if exists attachments_kind_check;
alter table public.attachments add constraint attachments_kind_check check (kind in ('opp','client','agency','fin'));

create or replace function public.can_attach(p_kind text, p_id uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select case when p_kind = 'fin' then public.can_finance()
    else public.is_admin() or (public.can_sell() and case p_kind
      when 'agency' then true
      when 'opp' then exists (select 1 from public.opportunities o where o.id = p_id and o.deleted_at is null and (o.owner_id = auth.uid() or o.created_by = auth.uid()))
      when 'client' then exists (select 1 from public.clients c where c.id = p_id and (c.owner_id = auth.uid() or c.created_by = auth.uid()))
      else false end) end
$$;

drop policy if exists "read attachments" on public.attachments;
create policy "read attachments" on public.attachments for select to authenticated
  using (case when kind = 'fin' then public.can_finance() else public.can_sell() end);
drop policy if exists "remove attachments" on public.attachments;
create policy "remove attachments" on public.attachments for delete to authenticated
  using (case when kind = 'fin' then public.can_finance()
    else public.is_admin() or (public.can_sell() and uploaded_by = auth.uid()) end);

drop policy if exists "arc read files" on storage.objects;
create policy "arc read files" on storage.objects for select to authenticated
  using (bucket_id = 'attachments' and case when name like 'fin/%' then public.can_finance() else public.can_sell() end);
drop policy if exists "arc add files" on storage.objects;
create policy "arc add files" on storage.objects for insert to authenticated
  with check (bucket_id = 'attachments' and case when name like 'fin/%' then public.can_finance() else public.can_sell() end);
drop policy if exists "arc remove files" on storage.objects;
create policy "arc remove files" on storage.objects for delete to authenticated
  using (bucket_id = 'attachments' and case when name like 'fin/%' then public.can_finance()
    else (public.is_admin() or owner_id = auth.uid()::text) end);

select 'Finances are set up' as result;
