-- =====================================================================
-- The Arc, version 21: notes on agencies
-- Paste this whole file into Supabase > SQL Editor > New query and click Run. It is safe to run more than once.
-- =====================================================================
create table if not exists public.agency_notes (
  id bigint generated always as identity primary key,
  agency_id uuid not null references public.agencies(id) on delete cascade,
  author_id uuid references public.profiles(id) on delete set null default auth.uid(),
  body text not null check (length(btrim(body)) > 0),
  created_at timestamptz not null default now(),
  deleted_at timestamptz,
  deleted_by uuid references public.profiles(id) on delete set null,
  edited_at timestamptz,
  edited_by uuid references public.profiles(id) on delete set null
);
create index if not exists agency_notes_agency_idx on public.agency_notes (agency_id, created_at desc);

-- Salespeople, admins and the Owner read and add agency notes. Only the author or an admin edits or deletes one
-- (through edit_note / set_note_deleted below; there is no direct update or delete).
alter table public.agency_notes enable row level security;
drop policy if exists "read agency notes" on public.agency_notes;
create policy "read agency notes" on public.agency_notes for select to authenticated using (public.can_sell());
drop policy if exists "add agency notes" on public.agency_notes;
create policy "add agency notes" on public.agency_notes for insert to authenticated
  with check (public.can_sell() and author_id = auth.uid());
grant select, insert on public.agency_notes to authenticated;
grant usage, select on sequence public.agency_notes_id_seq to authenticated;

-- Deleting and editing notes now covers agency notes too (kind 'agency').
create or replace function public.set_note_deleted(p_kind text, p_id bigint, p_deleted boolean) returns void
language plpgsql security definer set search_path = public as $$
declare a uuid;
begin
  if not public.is_member() then raise exception 'Please sign in again.'; end if;
  if p_kind = 'lead' then select author_id into a from public.lead_notes where id = p_id;
  elsif p_kind = 'opp' then select author_id into a from public.opp_notes where id = p_id;
  elsif p_kind = 'client' then select author_id into a from public.client_notes where id = p_id;
  elsif p_kind = 'agency' then select author_id into a from public.agency_notes where id = p_id;
  else raise exception 'Unknown note.'; end if;
  if not found then raise exception 'That note no longer exists.'; end if;
  if not (public.is_admin() or a = auth.uid()) then raise exception 'You can only delete your own notes.'; end if;
  if p_kind = 'lead' then
    update public.lead_notes set deleted_at = case when p_deleted then now() end, deleted_by = case when p_deleted then auth.uid() end where id = p_id;
  elsif p_kind = 'client' then
    update public.client_notes set deleted_at = case when p_deleted then now() end, deleted_by = case when p_deleted then auth.uid() end where id = p_id;
  elsif p_kind = 'agency' then
    update public.agency_notes set deleted_at = case when p_deleted then now() end, deleted_by = case when p_deleted then auth.uid() end where id = p_id;
  else
    update public.opp_notes set deleted_at = case when p_deleted then now() end, deleted_by = case when p_deleted then auth.uid() end where id = p_id;
  end if;
end $$;

create or replace function public.edit_note(p_kind text, p_id bigint, p_body text) returns void
language plpgsql security definer set search_path = public as $$
declare a uuid; old_body text; rid uuid; tbl text;
begin
  if not public.is_member() then raise exception 'Please sign in again.'; end if;
  if p_kind = 'lead' then
    select author_id, body, lead_id into a, old_body, rid from public.lead_notes where id = p_id; tbl := 'leads';
  elsif p_kind = 'opp' then
    select author_id, body, opp_id into a, old_body, rid from public.opp_notes where id = p_id; tbl := 'opportunities';
  elsif p_kind = 'client' then
    select author_id, body, client_id into a, old_body, rid from public.client_notes where id = p_id; tbl := 'clients';
  elsif p_kind = 'agency' then
    select author_id, body, agency_id into a, old_body, rid from public.agency_notes where id = p_id; tbl := 'agencies';
  elsif p_kind = 'call' then
    select caller_id, note, lead_id into a, old_body, rid from public.calls where id = p_id; tbl := 'leads';
  else raise exception 'Unknown note.'; end if;
  if not found then raise exception 'That note no longer exists.'; end if;
  if not (public.is_admin() or a = auth.uid()) then raise exception 'You can only edit your own notes.'; end if;
  if p_kind <> 'call' and coalesce(btrim(p_body), '') = '' then raise exception 'A note can''t be empty. Use Delete instead.'; end if;
  if coalesce(old_body, '') = coalesce(p_body, '') then return; end if;
  if p_kind = 'lead' then
    update public.lead_notes set body = p_body, edited_at = now(), edited_by = auth.uid() where id = p_id;
  elsif p_kind = 'opp' then
    update public.opp_notes set body = p_body, edited_at = now(), edited_by = auth.uid() where id = p_id;
  elsif p_kind = 'client' then
    update public.client_notes set body = p_body, edited_at = now(), edited_by = auth.uid() where id = p_id;
  elsif p_kind = 'agency' then
    update public.agency_notes set body = p_body, edited_at = now(), edited_by = auth.uid() where id = p_id;
  else
    update public.calls set note = coalesce(p_body, ''), edited_at = now(), edited_by = auth.uid() where id = p_id;
  end if;
  if rid is not null then
    insert into public.change_log (table_name, row_id, action, changed_by, changes)
    values (tbl, rid, case when p_kind = 'call' then 'call_note_edited' else 'note_edited' end, auth.uid(),
      jsonb_build_object('body', jsonb_build_array(old_body, p_body), 'note_id', jsonb_build_array(null, p_id)));
  end if;
end $$;

revoke execute on function public.set_note_deleted(text, bigint, boolean) from anon;
revoke execute on function public.edit_note(text, bigint, text) from anon;

select 'Agency notes are ready' as result;
