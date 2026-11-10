-- Dial Desk version 12: "New lead" button for callers and admins.
-- Paste this whole file into Supabase > SQL Editor and click Run. It is safe to run more than once.

-- Adds one lead by hand. Callers' new leads are always assigned to themselves;
-- admins (and the Owner) can assign it to anyone or leave it unassigned. Salespeople can't add leads.
create or replace function public.create_lead(p jsonb, p_owner uuid default null)
returns uuid language plpgsql security definer set search_path = public as $$
declare
  pk text; mk text; ek text; own uuid; new_id uuid; hit public.leads%rowtype;
begin
  if not (public.is_admin() or (public.is_member() and not public.can_sell())) then
    raise exception 'Only callers and admins can add leads.';
  end if;
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
    raise exception 'This lead is already in Dial Desk (% · %). Ask an admin if you need it.',
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
revoke execute on function public.create_lead(jsonb, uuid) from anon;

select 'Dial Desk version 12 is installed' as result;
