# Dial Desk — notes for Claude

Dial Desk is the outbound calling CRM for an appointment-setting team. Callers work their assigned leads from the Leads page, log each call with a status, and book appointments ("Appointment Set!" converts the lead into an opportunity for a salesperson). Admins import ZoomInfo CSV/Excel lists, assign leads and manage the team.

## How it is built
- `index.html` is the whole app: one static page (HTML, CSS and plain JavaScript, no build step). It loads `@supabase/supabase-js` and SheetJS from CDNs.
- Data and logins live in Supabase (project `https://cioqpzsblddghiuzpbvy.supabase.co`). The page uses the **publishable** key, which is safe in client code. Never put a secret / `service_role` key in this repo.
- `supabase-setup.sql` creates every table, security rule (RLS) and database function. It must stay safe to re-run (`if not exists`, `create or replace`, `drop policy if exists`).
- `supabase-fix-owner.sql` is a one-off repair that makes the earliest login the Owner.
- Netlify (site `dialdeskcrm`, https://dialdeskcrm.netlify.app) deploys automatically from the `main` branch. `netlify.toml` publishes the repo root.

## Data model
- `profiles`: one row per person; `role` is `owner`, `admin`, `salesperson` or `caller`; `active` turns access on/off.
- `invites`: emails allowed to sign up. The first account ever created becomes the Owner; everyone else must be invited (enforced by the `handle_new_user` trigger).
- `leads`: contact fields (including revenue, employees, industry, website), `extra` (jsonb for unmapped import columns), `status`, `owner_id` (assigned caller), callback/appointment fields, `notes`.
- `calls`: one row per logged call (lead, caller, status, note, `prev` = lead state before the call). Written only through `log_call()`; `undo_call()` reverses the latest call on a lead. Logging `call3` puts the lead `on_ice` and reassigns it to the Owner (the call row keeps status `call3`).
- `lead_notes`: dated comments on a lead (author, body, created_at). Never hard-deleted: `set_note_deleted()` sets `deleted_at/deleted_by` (author or admin) and can restore; deleted notes stay visible (struck through) in history. A trigger copies the newest non-deleted note into `leads.notes/notes_at/notes_by` for the Leads page and search.
- Trash: leads are soft-deleted with `deleted_at`/`deleted_by` (admins only, enforced by the `guard_leads` trigger). Callers never see trashed leads; admins restore them or delete forever from the Trash filter on the Leads page.
- `status_rank` is a generated column giving the pipeline order for sorting.
- Converting: `convert_lead()` creates an opportunity, sets the lead to `converted` with `sales_owner_id`/`opportunity_id`; `unconvert_lead()` undoes it. Only these functions may change those fields (guard trigger + `dialdesk.bypass` setting).
- `clients` and `agencies`: shared lists (unique by lower-cased name); `ensure_client()`/`ensure_agency()` find-or-create by name.
- `opportunities` (UI says "Deal"): deal_name, client_id ("Client Name"), agency_id, owner_id (salesperson), type (`first_deal`/`returning`), stage (`prospecting`,`proposal`,`nurturing`,`closed_won`,`closed_lost`; negotiation was removed in v4), probability, amount, follow_up_date ("Follow Up"), lead_source, description, products[], lead_id, converted_by. Legacy columns close_date, next_step and contact_* still exist but the UI no longer uses them. Soft-deleted with `deleted_at` (admins only).
- `opp_contacts`: any number of contacts per deal (name, title, email, phone); soft-removed with `deleted_at` and restorable. The `log_contact()` trigger writes contact_added/removed/restored/edited rows into `change_log` (row_id = opp id).
- `opp_notes`: dated notes on deals; soft-deleted like lead notes via `set_note_deleted('opp', ...)`.
- Editing notes: `edit_note(kind 'lead'|'opp'|'call', id, body)` (author or admin) updates the text, sets `edited_at/edited_by`, and writes a `note_edited` / `call_note_edited` row to `change_log` (changes.body = [old, new], changes.note_id = [null, id]) so old wording stays in history and can be undone.
- `call_report(p_from, p_to)`: calls and appointments (calls with status appointment + leads converted_by) per caller per day in Central time; admins get everyone, others only themselves. Feeds the callers' Leads boxes (Calls today, Appts this month, Calls this month, Callbacks due) and the admin-only Reports > Call volume view.
- `caller_hours`: hours worked per caller per month (caller_id, month = 1st of month, hours), admin-only, typed in on Reports > Call volume.
- `time_entries` (version 7): one row per shift (caller_id, clock_in, clock_out, break_minutes, break_started_at, note, updated_by/at). Hours = clock_out - clock_in - break. Callers write only through `clock_in()`, `start_break()`, `end_break()`, `set_break(minutes)` and `clock_out(break)`; admins/Owner insert, edit and delete rows directly. One open shift per person (unique index `time_entries_one_open`). Shifts count on the Central-time day they start. `supabase-v7-timeclock.sql` is the stand-alone paste for this version.
- Pay (Reports > Timesheets): $18/hour + $50 per appointment that SHOWED (`PAY_RATE`, `APPT_BONUS` in index.html). The bonus comes from `appt_pay_report(from, to)` (version 8): deals with `appt_showed` = true, credited to `converted_by`, dated by the deal's `appt_at` (or the day it was marked if no date), Central time; reverted deals still count. "Booked" (from `call_report()` appts) is shown for information only. Pay periods: 1st–15th and 16th–end of month; hours are rounded to 2 decimals before multiplying.
- Version 8 deal columns: `appt_at` (copied from the lead by `convert_lead()`, editable on the deal), `appt_showed` (+ `appt_showed_at/by`, filled in by `guard_opps()`), `reverted_at/by`. The salesperson (deal owner/creator) or an admin ticks "Appointment showed" on the deal page.
- Revert to lead: `revert_opportunity(opp, reason)` (deal owner/creator salesperson or admin, deals that came from a lead). It soft-deletes the deal with `reverted_at`, puts the lead back to `pre_convert_status` with its caller, and adds a lead note with the reason. A reverted deal can't be restored; convert the lead again. `supabase-v8-appointments.sql` is the stand-alone paste for this version.
- Version 9 (`supabase-v9-reports.sql`): `status_counts()` takes the extra Leads filters (state, industry, never called / last-contact window, callback); `lead_status_report()` (admins) gives live leads per caller per status with never-called, callbacks-due and 30-day-stale counts; `reassign_lead(lead, to, note)` lets a caller hand their own lead to another active caller/admin/owner (logged in change_log as an owner_id change by them; optional note).
- Reports > Lead stats (admins): status mix with % of all leads, Active = New + 1st Call + 2nd Call, status-by-caller table (counts or %), and caller performance for a month (calls, time-clock hours, calls/hour, appts booked, calls per appt, showed, show rate, caller pay, cost per appt = pay / booked).
- Every report view has Export CSV and, for admins, Download PDF (jsPDF 2.5.2 + jspdf-autotable 3.8.2 loaded from cdnjs on first click; US Letter, landscape for wide tables; `pdfSpec()` builds each view's PDF).
- Leads list: status chips toggle and combine (several statuses at once), a Filters row (state, industry, last contact, callback) and a "Then by" second sort.
- `change_log`: edit history written by the `log_changes()` trigger on leads, opportunities and clients (field -> [old, new], who, when). `updated_by` on leads/opportunities/clients is set by `touch_updated_at()`.
- Lead statuses: `new`, `call1` (1st Call), `call2`, `call3`, `on_ice` (On Ice), `gatekeeper`, `appointment` (Appointment Set), `converted`, `dead`, `bad_info` (Bad Information).

## Permissions
- Callers see and update only leads assigned to them (admins assign them on Leads; there is no Calling/queue page and no Pull button any more). They can convert their leads with "Appointment Set!". They clock in/out and log breaks on their own Time clock tab (callers who aren't clocked in land there after signing in). On a lead they can click any detail to edit it, in the top section or the Company & contact panel (everything except the caller it's assigned to, which they change with Reassign); each change can be undone from the Undo bar, the toast, or the history. They never see opportunities; in Reports they see only their own Timesheet (no export), and the Caller column is hidden for them.
- Salespeople see every lead and every opportunity and see Reports; they edit only leads converted to them and deals they own or created. Only admins reassign deals.
- Admins (and the Owner) see everything (including every caller's timesheet, which they can edit and export), import (`import_leads()`), assign, bulk-update, export and delete.
- Only the Owner changes roles or turns access off (`set_member()`), and only the Owner can invite admins.

## UI layout (v4)
- Tabs: Leads (home for callers/admins), Opportunities (home for salespeople), Reports, Import, Team. Clicking a lead opens the lead page with ← Leads, Previous/Next (follows the Leads list order) and the Convert / Appointment Set! button at top right. "Save call & next" moves to the next lead in the Leads list.
- Logging a call: tapping a result saves immediately (no Save button) and stays on the lead; callback date (quick buttons In 2/3/7 days) saves straight to the lead. "Appointment Set!" (result button or top button) opens a short form for callers: company, contact name/email/phone, salesperson, notes (prefilled from notes and call notes); admins/salespeople get the full Convert form.
- History is never hidden: edits, calls and notes (including deleted ones) all show; field edits have an Undo button in the history.

## Making changes
- Edit `index.html`, check the script parses, commit and push to `main`; Netlify publishes in about a minute.
- Database changes: update `supabase-setup.sql` (keep it re-runnable). Claude cannot reach Supabase from its workspace, so give the user the SQL to paste into Supabase > SQL Editor > Run, and tell them exactly what result to expect.
- The users are not developers. Explain steps in plain words, one click at a time.
