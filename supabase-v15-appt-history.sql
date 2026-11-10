-- Dial Desk version 15: the old CSR Details sheet's appointments, shown on Reports > Appointments.
-- These are names and details only (no leads or deals are created), so they don't change pay or the Deals page.

-- >>> The sheet cuts off two last names. Type the full names between the quotes before you click Run. <<<
create temp table if not exists _names (k text primary key, v text);
delete from _names;
insert into _names values
  ('jeremy',  'Jeremy McCas'),
  ('trenton', 'Trenton Hatl');

-- Version 15: appointments from the old CSR Details sheet (Reports > Appointments)
create table if not exists public.appt_history (
  id bigserial primary key,
  company text not null default '',
  contact text not null default '',
  sales_rep text not null default '',
  csr text not null default '',
  appt_date date,
  qualified boolean not null default false,
  notes text not null default '',
  created_at timestamptz not null default now(),
  unique (company, appt_date)
);
alter table public.appt_history enable row level security;
drop policy if exists "read appt history" on public.appt_history;
create policy "read appt history" on public.appt_history for select to authenticated using (public.can_sell());
drop policy if exists "admins add appt history" on public.appt_history;
create policy "admins add appt history" on public.appt_history for insert to authenticated with check (public.is_admin());
drop policy if exists "admins edit appt history" on public.appt_history;
create policy "admins edit appt history" on public.appt_history for update to authenticated using (public.is_admin()) with check (public.is_admin());
drop policy if exists "admins delete appt history" on public.appt_history;
create policy "admins delete appt history" on public.appt_history for delete to authenticated using (public.is_admin());

-- Let signed-in users reach the table (Supabase does not do this on its own for new tables in this project).
grant select, insert, update, delete on public.appt_history to authenticated;
grant usage, select on sequence public.appt_history_id_seq to authenticated;

-- The 63 appointments from the sheet (51 qualified). Safe to run again: rows already added are skipped.
insert into public.appt_history (company, contact, sales_rep, csr, appt_date, qualified, notes) values
  ('Oklahoma City Community Foundation', 'Dan Martel', (select v from _names where k='jeremy'), 'Lucy Wentz', date '2026-03-06', true, ''),
  ('Toys for Tots', 'Ted Silvester', (select v from _names where k='jeremy'), 'Helen Keylada', date '2026-03-11', true, ''),
  ('Center Square', 'Chris Krug', 'Jared Boyd', 'Helen Keylada', date '2026-03-11', true, ''),
  ('Make-A-Wish Idaho', 'Josh Peterson', (select v from _names where k='jeremy'), 'Helen Keylada', date '2026-03-16', true, ''),
  ('Set Free Alaska', 'Jason Manalli', (select v from _names where k='jeremy'), 'Helen Keylada', date '2026-03-24', true, ''),
  ('Harper Collins', 'Eric Mullett', (select v from _names where k='jeremy'), 'Helen Keylada', date '2026-03-26', true, ''),
  ('The Dove Media', '', 'Jared Boyd', 'Helen Keylada', date '2026-03-27', true, ''),
  ('Canton Christian Home', 'Lauren Koch', (select v from _names where k='jeremy'), 'Helen Keylada', date '2026-03-31', true, ''),
  ('Heritage Christian Services', 'Mackenzie Schayes', (select v from _names where k='jeremy'), 'Helen Keylada', date '2026-04-06', true, 'Paid by Jeremy'),
  ('Salvation Army - Lerma Agency', 'Teddy Berlin', (select v from _names where k='jeremy'), 'Helen Keylada', date '2026-04-07', true, ''),
  ('Holly Hall', 'Melba Hamilton Breed', (select v from _names where k='jeremy'), 'Helen Keylada', date '2026-04-08', true, ''),
  ('Christian Tours', 'Mellonee Owenby', (select v from _names where k='jeremy'), 'Helen Keylada', date '2026-04-13', true, ''),
  ('Tyndale', 'Josh Odum', (select v from _names where k='jeremy'), 'Helen Keylada', date '2026-04-20', true, ''),
  ('Feed the Children', 'Bob Harstad', (select v from _names where k='jeremy'), 'Helen Keylada', date '2026-04-28', true, ''),
  ('Harvest House Publishers', 'Logan Mertz', 'Jared Boyd', 'Helen Keylada', date '2026-05-05', true, ''),
  ('Open Doors US', 'Kayla Phillips', 'Jared Boyd', 'Helen Keylada', date '2026-05-12', true, ''),
  ('Giving Tuesday', 'Shareeza Bhola', (select v from _names where k='jeremy'), 'Lucy Wentz', date '2026-05-12', true, 'Double Bonus'),
  ('Trove Inc', 'Richard Forbus', (select v from _names where k='jeremy'), 'Lucy Wentz', date '2026-05-26', false, ''),
  ('Covenant Eyes', 'Karen Potter', 'Jared Boyd', 'Lucy Wentz', date '2026-06-02', true, ''),
  ('Eventide Investments', 'Julie Jarrett', (select v from _names where k='jeremy'), 'Lucy Wentz', date '2026-06-04', true, ''),
  ('Abba House', 'Jennifer Kohlmayer', (select v from _names where k='jeremy'), 'Lilah Vicena', date '2026-06-05', true, ''),
  ('World Help', 'Amanda Mattingly', (select v from _names where k='jeremy'), 'Helen Keylada', date '2026-06-08', true, ''),
  ('Young Israel', 'Zev', 'Kyle Souza', 'Lilah Vicena', date '2026-06-09', false, ''),
  ('Native Partnership', 'Kevin Lightfoot', (select v from _names where k='jeremy'), 'Lucy Wentz', date '2026-06-10', true, 'Double Bonus'),
  ('Feed the Poor', 'Peter Oriyomi', 'Jared Boyd', 'Lucy Wentz', date '2026-06-16', true, ''),
  ('Center Square', 'Chris Krug', (select v from _names where k='jeremy'), 'Talia Williams', date '2026-06-16', true, ''),
  ('Baptist Health / Media Counselors', 'Cheryl Gudowitz', (select v from _names where k='jeremy'), 'Lilah Vicena', date '2026-06-23', true, ''),
  ('Texas Council for Family Violence', 'Patricia', 'Jared Boyd', 'Talia Williams', date '2026-06-25', true, ''),
  ('Charles E Smith Life Community', 'Erika Heiney', 'Kyle Souza', 'Lilah Vicena', date '2026-07-02', true, ''),
  ('Walker Area Community Foundation', 'Paul Kennedy', (select v from _names where k='jeremy'), 'Lucy Wentz', date '2026-07-06', true, ''),
  ('Wycliffe', 'Angela Towle', (select v from _names where k='jeremy'), 'Talia Williams', date '2026-07-07', true, ''),
  ('Jewish Pro-Life Foundation', 'Cecily Routman', 'Kyle Souza', 'Lilah Vicena', date '2026-07-20', true, ''),
  ('National Society of Black Engineers', 'Devon Smith', (select v from _names where k='jeremy'), (select v from _names where k='trenton'), date '2026-07-30', true, ''),
  ('Israel Innovation Fund', 'Adam Bellos', 'Kyle Souza', (select v from _names where k='trenton'), date '2026-08-04', true, ''),
  ('6 Million Voices', 'Rabbi Michael Beyo', 'Kyle Souza', (select v from _names where k='trenton'), date '2026-08-10', true, ''),
  ('Charlie Health', 'Garret Thomas', (select v from _names where k='jeremy'), 'Lilah Vicena', date '2026-08-11', true, ''),
  ('Lawrence Family Jewish Community Center', 'Jonathan Cane', 'Kyle Souza', 'Lilah Vicena', date '2026-08-13', true, ''),
  ('Community Action Partnership of Kern', 'Natalie Pinon', (select v from _names where k='jeremy'), 'Trinity Clark', date '2026-08-20', false, 'Dead'),
  ('Community Access Unlimited', 'Amanda Panchery', 'Jared Boyd', 'Trinity Clark', date '2026-08-25', true, ''),
  ('Child Evangelism Fellowship', 'Tasha Dunne', (select v from _names where k='jeremy'), 'Trinity Clark', date '2026-08-25', true, ''),
  ('Jewish Federation of Reading', 'Amanda Wertz', 'Kyle Souza', (select v from _names where k='trenton'), date '2026-08-26', true, ''),
  ('Lighthouse for the Blind of Houston', 'Angie Pickering', 'Jared Boyd', 'Lucy Wentz', date '2026-09-03', true, 'Rescheduled due to sales rep cancellation'),
  ('Lionsgate', 'Diana Huang', (select v from _names where k='jeremy'), 'Helen Keylada', date '2026-09-04', true, ''),
  ('Mission House Road', 'Claudia Pina', (select v from _names where k='jeremy'), 'Lucy Wentz', date '2026-09-14', true, ''),
  ('CommQuest Services', 'Jennifer Bako', (select v from _names where k='jeremy'), (select v from _names where k='trenton'), date '2026-09-17', false, 'Dead'),
  ('Jewish Voice Ministries International', 'Amy James', 'Jared Boyd', (select v from _names where k='trenton'), date '2026-09-29', true, ''),
  ('Christ Gospel Mission', 'Dr. Vijay Gadepe', 'Kyle Souza', (select v from _names where k='trenton'), date '2026-09-29', false, 'no show, rescheduling'),
  ('Fellowship of Israel Related Ministries (FIRM)', 'Benjamin Kroese', 'Kyle Souza', 'Lilah Vicena', date '2026-10-01', false, '1/2'),
  ('Stand United 4 Christ', 'Stephanie Rogers', 'Kyle Souza', 'Trinity Clark', date '2026-10-05', true, ''),
  ('Grace School of Theology', 'Jay Richardson', (select v from _names where k='jeremy'), 'Lucy Wentz', date '2026-10-06', true, ''),
  ('North Bay Children''s Center', 'Lisa Campbell', (select v from _names where k='jeremy'), 'Trinity Clark', date '2026-10-15', false, ''),
  ('Unto', 'Faith Kidd', (select v from _names where k='jeremy'), 'Lucy Wentz', date '2026-10-15', true, ''),
  ('Generation Hope', 'Jay Shepley', 'Jared Boyd', 'Trinity Clark', date '2026-10-16', false, ''),
  ('Blessings of Hope', 'Kris Pursel', (select v from _names where k='jeremy'), 'Helen Keylada', date '2026-10-16', false, ''),
  ('Build Wealth MN', 'Kandice Nelson', (select v from _names where k='jeremy'), (select v from _names where k='trenton'), date '2026-10-19', true, ''),
  ('All About Hope', 'Cindy Costa', (select v from _names where k='jeremy'), 'Trinity Clark', date '2026-10-20', true, ''),
  ('Youth For Christ', 'Estevan Azocar', (select v from _names where k='jeremy'), (select v from _names where k='trenton'), date '2026-10-22', true, ''),
  ('Orange County Rescue Mission', 'Joanne Sanglir', (select v from _names where k='jeremy'), 'Lucy Wentz', date '2026-10-26', true, ''),
  ('National Faith Advisory Board', 'Jennifer Anderson', (select v from _names where k='jeremy'), 'Trinity Clark', date '2026-10-30', true, ''),
  ('Tyndale House Publishers', 'Josiah Diaz', (select v from _names where k='jeremy'), 'Helen Keylada', date '2026-11-04', true, ''),
  ('Life is Hard Marriage is Easy LLC', 'Kerry Michael St. Martin', 'Kyle Souza', (select v from _names where k='trenton'), date '2026-11-12', false, ''),
  ('Salem Media', 'Brad Davies', (select v from _names where k='jeremy'), 'Trinity Clark', date '2026-11-13', false, ''),
  ('A Door of Hope', 'William Babbino', (select v from _names where k='jeremy'), 'Trinity Clark', date '2026-11-20', false, '')
on conflict (company, appt_date) do nothing;

select count(*) || ' sheet appointments are in Dial Desk' as result from public.appt_history;
