# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

The Ark (formerly The Arc, and before that Dial Desk; the repo keeps the old name) is the outbound calling CRM for an appointment-setting team. Callers work their assigned leads, log each call with a status, and book appointments ("Appointment Set!" converts the lead into a Deal for a salesperson). Admins import ZoomInfo CSV/Excel lists, assign leads, manage the team and read reports.

The users are not developers. Explain steps in plain words, one click at a time.

## Commands
There is no build, lint or test suite. The only check is that the inline script parses:
```
node -e "const s=require('fs').readFileSync('index.html','utf8');[...s.matchAll(/<script>([\s\S]*?)<\/script>/g)].forEach(m=>new Function(m[1]));console.log('OK')"
```
- `git` is not on PATH on this machine. Use GitHub Desktop's copy: `& "$env:LOCALAPPDATA\GitHubDesktop\app-<version>\resources\app\git\cmd\git.exe"` (find the version folder with `Get-ChildItem $env:LOCALAPPDATA\GitHubDesktop -Filter git.exe -Recurse`). Remote: `github.com/HarwellZac/dial-desk`.
- Deploy = commit and push to `main`. Netlify (site `thearkcrm`, https://thearkcrm.netlify.app; was thearccrm, before that dialdeskcrm) publishes the repo root in about a minute (`netlify.toml`). `SETUP.md` still describes manual drag-and-drop deploys; that is out of date.

## How it is built
- `index.html` is the whole app: HTML, CSS and plain JavaScript in one file, no framework, no build step. CDN libraries: `@supabase/supabase-js`, SheetJS (imports).
- `pdf-tools.js` = jsPDF 2.5.2 + jspdf-autotable 3.8.2 served from the site itself (TBN's network blocks cdnjs). `pdfLib()` loads it when an admin opens Reports; cdnjs/jsDelivr/unpkg are only fallbacks. PDFs are saved with `saveBlob()` (a download link), not jsPDF's `doc.save()`.
- Data and logins live in Supabase (project `https://cioqpzsblddghiuzpbvy.supabase.co`). The page uses the **publishable** key, which is safe in client code. Never put a secret / `service_role` key in this repo.
- Security is enforced in the database (RLS policies, guard triggers, `security definer` functions), not in the page. Hiding a button is never enough; a permission change needs SQL.

### Code map of `index.html`
- Top of `<script>`: config (`SUPABASE_URL`, `SUPABASE_KEY`, `sb` client, `BOOKING_URL`), then constants: `STATUSES` (labels), `STATUS_ORDER`, `OPEN`, `TO_OWNER` (statuses that hand the lead to the Owner), `FIELDS` (import column aliases for auto-mapping), `EDIT_FIELDS`, `PATH` (status bar steps), `PAY_RATE`/`APPT_BONUS`.
- Global state objects: `me`, `people` (profiles by id), `cur` (open lead), `board` (Leads filters/sort/selection), `rep` (Deals filters), `clock`, `imp`.
- Start-up: `sb.auth.onAuthStateChange` + `getSession()` → `enter()` (loads profile and `people`, `applyRole()`, picks the landing tab) or the sign-in screen.
- Navigation: `setTab(t)` → `allowed(t)` → `showTab(t)` toggles `#tab-<name>` sections. Tab buttons carry `data-tab`. `applyRole()` shows/hides elements by attribute: `data-admin`, `data-sell` (salespeople + admins), `data-rep` (can see Reports), `data-callonly`, `data-call` (hidden for salespeople).
- Each view is a `loadX()` (fetch from Supabase) + `renderX()` (build HTML) pair: `loadBoard/renderBoard` (Leads), `openLead → selectLead → renderLead` (lead page: `renderHead`, `renderPath`, `renderNotes`, `renderDetails`, `renderAbout`, `renderUndoBar`), `loadOpps/renderOpps` + `openOpp/renderOppDetail` (Deals), `loadAgencies/renderAgencies`, `loadClock/renderClock`, `loadReports/renderReport` with sub-views (`loadCallVolume`, `loadTimesheet`, `loadLeadStats`, `loadAppts`), `loadTeam`, `renderImport`.
- Helpers: `$` (querySelector), `toast(msg, opt)` (also carries Undo), `pdfSpec()` (PDF layout per report view).

## Database
- `supabase-setup.sql` is the full schema: every table, RLS policy, trigger and function. It must stay safe to re-run (`if not exists`, `create or replace`, `drop policy if exists`).
- `supabase-vNN-<topic>.sql` files are stand-alone pastes for each version that changed the database (v7–v26). `supabase-fix-owner.sql` is a one-off repair that makes the earliest login the Owner.
- To change the database:
  1. Write a new `supabase-vNN-<topic>.sql` with just the change (also re-runnable).
  2. Fold the same change into `supabase-setup.sql`.
  3. New tables need explicit grants (`grant select, insert, update, delete on public.<table> to authenticated;` plus its sequence), or the page gets "permission denied".
  4. Claude cannot reach Supabase. Give the user the SQL to paste into Supabase > SQL Editor > Run, and say exactly what result to expect.
- Protected fields: conversion fields (`sales_owner_id`, `opportunity_id`, status `converted`) may only change through `convert_lead()`/`unconvert_lead()`/`revert_opportunity()`; guard triggers (`guard_leads`, `guard_opps`) enforce this, with the `dialdesk.bypass` setting letting those functions through.
- Times and days are Central time in every report function.

## Data model
- `profiles`: one row per person; `role` is `owner`, `admin`, `salesperson` or `caller`; `active` turns access on/off. `set_member()` (Owner only) changes role/access; `set_member_name()` renames (Owner anyone, admins callers/salespeople, anyone themselves).
- `invites`: emails allowed to sign up. The first account ever becomes the Owner; everyone else must be invited (`handle_new_user` trigger). Only the Owner can invite admins.
- People without a login (v23): `add_member(name, role, email?)` adds a profile with `email` null (not tied to `auth.users`; that FK was dropped). They appear in every people list but can't sign in. `invite_member(user, email)` adds an `invites` row with `profile_id`; on sign-up `handle_new_user` calls `merge_member(old, new, email)`, which copies the profile to the new login id, repoints every FK column that references `profiles` (user triggers paused on those tables), rewrites the old id inside `change_log.changes` and `calls.prev`, and deletes the stand-in. Role rules: `can_add_role()` (admins: caller/salesperson; Owner also admin/finance). Team page: "Add without email" button (`addPersonForm`), Invite/Change/Cancel invite on the person's row (`invitePersonForm`, `noLoginCell`).
- `leads`: contact fields, `about` (About company), `agency_name/contact/phone/email` (set with Has Agency), `extra` (jsonb of unmapped import columns), `status`, `status_rank` (generated, pipeline order for sorting), `owner_id` (assigned caller), callback/appointment fields, `notes/notes_at/notes_by` (copy of the newest live note, kept by a trigger), `source`. Soft-deleted with `deleted_at/deleted_by` (admins only; Trash filter on Leads restores or deletes forever). Created by `import_leads()` or `create_lead(p, p_owner)` (callers' leads go to themselves; refuses a phone/mobile/email that matches a live lead and names who has it; `source` = "Added by <name>").
- Lead statuses: `new`, `call1`, `call2`, `call3`, `engaged`, `has_agency`, `on_ice`, `already_opp`, `appointment`, `converted`, `dead`, `bad_info`, plus `gatekeeper` (old leads only, never offered). Logging any of `TO_OWNER` (`call3`, `already_opp`, `dead`, `bad_info`) reassigns the lead to the Owner; `call3` also sets `on_ice` (the call row keeps `call3`, and the status bar shows On Ice as 3rd Call).
- `calls`: one row per logged call (lead, caller, status, note, `prev` = lead state before). Written only via `log_call()`; `undo_call()` reverses the latest. `reassign_lead(lead, to, note)` lets a caller hand their lead to another active caller/admin/owner.
- `lead_notes`, `opp_notes`, `client_notes`, `agency_notes`: dated notes, never hard-deleted. `set_note_deleted(kind, id, ...)` soft-deletes/restores (author or admin); `edit_note(kind 'lead'|'opp'|'client'|'agency'|'call', id, body)` edits and logs `note_edited`/`call_note_edited` in `change_log` (changes.body = [old, new]).
- `change_log`: edit history from the `log_changes()` trigger on leads, opportunities and clients (field → [old, new], who, when) and from `log_contact()` on `opp_contacts`. Field edits are undoable from history. `touch_updated_at()` sets `updated_by`.
- `opportunities` (UI: "Deals"; code and tables still say opp/opportunities): deal_name, client_id, agency_id (none = "Direct"), owner_id (salesperson), type (`first_deal`/`returning`), stage (`prospecting` shown as "Qualifying", `proposal`, `nurturing`, `closed_won`, `closed_lost`), probability, amount, follow_up_date, `lead_source` (shown "Deal Source"; `convert_lead()` sets "Call Center"), products[], lead_id, `converted_by` (the CSR), `appt_at`, `appt_showed` (+ `_at/_by`), `appt_company`, `contact_name`, `appt_notes`, `reverted_at/by`. Legacy close_date, next_step and contact_* are unused. Soft-deleted with `deleted_at` (admins).
  - `convert_lead()` creates the deal (copies `appt_at`, fills blank agency details and client description). Moving Qualifying → Proposal ticks `appt_showed` (in `guard_opps()`); only admins change `converted_by` or the owner.
  - `revert_opportunity(opp, reason)`: soft-deletes with `reverted_at`, returns the lead to `pre_convert_status` and its caller, adds a lead note. Allowed for the deal owner/creator, admins, and the booking caller while the deal is still Qualifying and not showed. Reverted deals can't be restored.
- `opp_contacts`: any number per deal; soft-removed and restorable.
- `clients`, `agencies`: shared lists, unique by lower-cased name; `ensure_client()`/`ensure_agency()` find-or-create.
- `time_entries`: one row per shift (clock_in, clock_out, break_minutes, break_started_at, note). Callers write only via `clock_in()`, `start_break()`, `end_break()`, `set_break(minutes)`, `clock_out(break)`; admins edit rows directly. One open shift per person (`time_entries_one_open`). A shift counts on the day it starts.
- `caller_hours`: hand-typed hours per caller per month (admins, Reports > Call volume).
- `appt_history`: appointments from the old CSR Details sheet or added by hand (`source='manual'`, `added_by`); names are text, no lead/deal behind them, so they don't count toward pay. Salespeople/admins read; admins edit/delete.
- Report functions: `call_report(from, to)` (calls and appointments per caller per day; admins get everyone), `appt_pay_report(from, to)` (showed deals per CSR, dated by `appt_at`; reverted deals still count), `status_counts()` (Leads chip counts with all Leads filters), `lead_status_report()` (admins: live leads per caller per status with never-called, callbacks-due, 30-day-stale counts).

## Version 19 (The Arc, now The Ark)
- More than one Owner (Dan Newman). `main_owner()` = the first Owner account; nobody can change it, and callers' 3rd Call / Already Opportunity / Dead / Bad Info leads go to it (`mainOwner()` in the page). Salespeople keep their own leads.
- Has Agency: `link_agency_lead(lead)` makes the agency its own lead for the same caller (or links an existing one by name/phone/email), filling `agency_for` (companies it represents) and `agency_lead_id` on the client lead; `unlink_agency_lead()` is the Undo.
- Salespeople add leads (`create_lead`, they own them): New Lead button on the Leads page; New Deal in the top bar (`#newdealtop`, `data-salesonly`).
- Clients tab (`loadClients/renderClients/openClient`, `openClientForm`): clients have `owner_id`, `agency_id`, `client_source`, `client_type` (labelled Deal Type), `follow_up_date`. Salespeople edit only clients they own or created (`canEditClient`, RLS, `guard_clients`).
- `billing_contact` / `content_contact` jsonb ({name, phone, email}) on deals, clients and agencies (`contactFields`, `readContacts`, `ctHtml`). Agencies have `source` (Agency Source).
- Deal forms: "Client Source" (stored in `lead_source`), "Deal Type" (`first_deal` New Client, `returning`, `new_returning_agency`). `wireAutofill()` fills the client source, contacts and deal type when an agency or existing client is picked. Salespeople get no "Other products" box.
- Stages show Qualifying → Nurturing → Proposal/Price Quote → Closed (`STAGE_ORDER`).
- Client notes (v20): `client_notes` table, same rules as deal notes (`set_note_deleted`/`edit_note` kind 'client'); `renderClientNotes()` shows notes + edits on the client page.
- Agency notes (v21): `agency_notes` table, same pattern (kind 'agency'); salespeople/admins read and add (`can_sell()`), author or admin edits/deletes. `renderAgencyNotes()` on the agency page (`openAgency`).
- Files panels are `.filesbox` inside each page (`#opp-detail`, `#cl-detail`, `#ag-detail`); `loadFiles()` looks inside the page being shown, because hidden pages keep their old HTML.
- `followBox()/wireFollow()` (date + 7 days / 30 days / 6 months) on deals and clients. `filesPanel()/loadFiles()`: `attachments` table + private storage bucket `attachments` (50 MB/file).
- Reports > Call volume: Dates filter (`cv.range`, `cvRange()`): today, yesterday, this/last week, last 7/30 days, picked dates, or a whole month (only whole months take typed hours).
- Reports > Deals: stage table, likelihood to close, products (`dealTables`), and By quarter for admins (`quarterTable`); all in the PDF.

## Version 22 (Finances)
- Who: `can_finance()` (SQL) / `canFinance()` (page) = Owners, the new `finance` role, or anyone with `profiles.finance` = true. Only an Owner switches it (`set_finance(user, on)`, "Finance access" column on Team; guard trigger `guard_profile_finance`). Admins do NOT get it automatically. The Finance role sees only the Finances tab (`isFinRole()`; Leads tab, search and New Lead hidden; `allowed()` returns only 'fin'). View as previews never show Finances.
- Tab `fin` (`#tab-fin`): `loadFin()` → `loadFinData()` (deals that are Closed Won or already have finance rows) → `renderFinList()` (KPIs, status chips, table) or `renderFinReports()`; `openFin(id)` → `renderFinDetail()`. Deal pages show a "Finances" button on Closed Won deals for finance people.
- Tables: `deal_invoices` (invoice_no, amount, due_date, ar_submitted_on, sent_on, paid_on, notes), `deal_commissions` (person_id or person_name, `rate` % or `manual_amount` $, paid_on), `deal_allocations` (allocation, secondary, optional amount). RLS: can_finance() only. Finance files = `attachments` kind `fin`, storage path `fin/<deal id>/…`.
- Client and agency pages show an Invoices panel (every invoice on that client's/agency's deals) for `canFinance()` people: `finInvPanel()` + `loadFinInvPanel(box, deals)`; a row opens the deal in Finances.
- Finance labels, titles and buttons use Title Case (every word capitalized).
- Lists in the page: `ALLOCATIONS`, `ALLOC_SECONDARY`, `COM_PRESETS` (2, 3, 4, 7.5). Commission = manual amount, or deal amount × rate; "earned so far" = commission × share of the deal collected.
- Reports (Finances > Reports): Receivables (aging, as of today), Collections (by paid date), Commissions, Allocations, Closed Won deals (by close date). Export CSV; no PDF yet.

## Version 24 (agencies, Needs Rebooked, Agreement Submitted, deleting)
- Callers' Leads list hides `CALLER_HIDDEN` (On Ice, Bad Info, Already Opportunity, Has Agency, Dead, Converted): chips, counts and rows (`filtered()`, `renderBoard()`). Callers' top bar no longer shows "Appts this month".
- Lead status `needs_rebook` ("Needs Rebooked"): last in `STATUS_ORDER` (chips: right after Appointment Set for callers) and last in `status_rank` (v25). Deal page "Needs Rebooked" box (`canRebook`, `rebookOpp`) calls `revert_opportunity(opp, reason, p_rebook => true)`: deal owner/creator salesperson or admin, not Closed Won. Revert/rebook always returns leads to their caller (`owner_id = coalesce(owner_id, converted_by)`).
- `leads.is_agency` = "Has Agency" box at the top of the lead (`#isagency` in `renderHead`) = this lead IS an agency; its `agency_for` shows beside it. `link_agency_lead(lead, p_client)` ticks it on the agency lead, adds the agency to `agencies` (Call Center source, contact details) and the Client name to `agencies.agency_for` via `add_agency_client()`. The Has Agency form has a "Client" box (defaults to the lead's company); the agency form has one too.
- `convert_lead()` on an agency lead: ensures the agency from the lead's details and makes one deal per name in `agency_for` (deal name "Client - ..."), each through the agency, converting each client's own lead (`agency_lead_id` = agency lead, name match either way) to its deal. `revert_opportunity()` sends all live non-won deals of an agency lead back together; `unconvert_lead()` removes every deal the conversion made.
- Deal stage `agreement` ("Agreement Submitted", 90%). Only admins/Owners set or leave Closed Won (`guard_opps`, `canStage()`, `stageChoices()`).
- Deleting (admins/Owners): lead page "Delete lead" (to the Trash), deals (existing), `delete_client()` (soft: `clients.deleted_at`, its deals soft-deleted; `ensure_client()` revives by name; `loadLookups()` hides deleted), `delete_agency()` (hard; clients/deals become Direct; returns file paths for the page to remove from storage). `confirmDelete()` is the confirm box.
- Files panels accept drag and drop (`loadFiles`, `.filesbox.drop`).

## Version 26 (Lead stats, On Ice age, Thanksgiving)
- Reports > Lead stats: activity picker `#lsrange` (`ls.range`: last7 default, week, lastweek, month, or a YYYY-MM) via `lsRange()`; never earlier than `TRACK_START` ('2026-11-16', when the team switched over from testing). Live leads = `LIVE` (New, 1st Call, 2nd Call, Engaged, Has Agency); never-called / callbacks / 30-day counts use live leads only. Other statuses are listed under "Not counted as live".
- `leads.on_ice_at`: set by trigger `stamp_on_ice()` whenever a lead becomes On Ice, cleared when it leaves (backfilled from the 3rd Call date). `on_ice_report()` (admins) lists live On Ice leads. 6+ months On Ice = Reusable Lead (`REUSE_MONTHS`, `iceAge()`, `isReusable()`): On Ice panel on Lead stats (age buckets + list, `renderIce()`), shown on the lead page and in the Leads list "Next step" column.
- Thanksgiving: Caller view only (`isCaller()`, so a View as caller preview shows it too), Nov 1–28 only (`THX_ON()`); from Nov 29 none of it runs and the site looks as it did before. `applyThx()` (called from `applyRole()`, sign-out, and hourly) toggles `body.thx`: warm tint, autumn stripe, turkey on the logo, leaf after page titles, orange New Lead/active tab, coffee cup on Start break, leaves drifting once, and a turkey-and-coffee buddy bottom-left with rotating messages (click for a new one; × hides it for the day, `localStorage` `ark_thx_hide_<date>`). `thxBurst()` showers leaves when a caller books an appointment.

## Pay rules
$18/hour + $50 per appointment that SHOWED (`PAY_RATE`, `APPT_BONUS`). Hours = clock_out − clock_in − break, rounded to 2 decimals before multiplying. Pay periods: 1st–15th and 16th–end of month. "Booked" appointments are shown for information only.

## Permissions
- **Callers** see and edit only leads assigned to them (any field except the assignee, which they change with Reassign). They book with Appointment Set!, use the Time clock tab (landing there if not clocked in, otherwise Leads), and in Reports see only their own Timesheet (no export, Caller column hidden). They never see deals.
- **Salespeople** see every lead and deal, Agencies and Reports (Appointments is their default report); they edit only leads converted to them and deals they own or created, and tick "Appointment showed". They land on Deals filtered to their own. No New lead button.
- **Admins and the Owner** see and edit everything: import, assign, bulk-update, export, Trash, every timesheet, Team, PDF downloads.
- **View as (admins and the Owner):** a dropdown to the right of New lead in the top bar (Admin/Owner view, Caller view, Salesperson view). `setViewAs()` swaps `me.role` while `me.realRole` keeps the real one, so every `isAdmin()/isCaller()/isSales()/canSell()` check follows the preview; the choice is kept in `sessionStorage` (`dd_viewas`) for that browser tab only. An orange bar under the top bar says which view is on and has "Back to admin view". It is a page-only preview: the database still gives the admin full access, so anything done in a preview (logging calls, clocking in) is real and saved under the admin's own name. Caller view shows only leads assigned to the admin (the Leads list and global search filter on `owner_id`).

## Current UI
- Tabs: Leads, Deals, Clients, Agencies, Time clock, Reports, Import, Team (shown by role). Top bar is one row on screens wider than 1000px: logo, tabs, search (shrinks, 360px max), "New lead" (not salespeople), the View as dropdown (`#viewas`, admins/Owner), avatar, Sign out. As the window narrows it drops the name (<1500px), tab icons and the Sign out label (<1340px) and the logo text (<1120px); below 1000px it wraps and search takes its own row. Leads list has combinable status chips, a Filters row (state, industry, last contact, callback), a "Then by" second sort, Export CSV and (admins) Import Leads.
- Lead page: ← Leads, Previous/Next (follows the Leads list order), Appointment Set! / Convert at top right. Order: status bar (`#plog`, `renderPath()`) → `.leadtop` [lead header | `.side` with Notes and `#pcb` (Call back date + Next lead, hidden when empty)] → Company & contact (admins/salespeople) → About company. Clicking a status step calls `logCall()` at once; only the assigned caller and admins can click it. Converted leads show a Converted box (with "Undo appointment" for the booking caller).
- Lead header boxes, two per row: Direct phone | Mobile, Website | Email, Industry | Job title, Company phone | City · State · ZIP. Company name has a Copy button.
- Notes default to Notes only (notes + calls with a note) with an "All activity" switch. History is never hidden: deleted notes show struck through; edits show old wording.
- Appointment Set! needs date and time, contact name/title/email/phone, salesperson and optional Agency; "Notes for the salesperson" starts with the latest note. A "Book appointment" link (`BOOKING_URL`) sits beside it.
- Reports: Appointments (one row per live deal with a CSR, merged with `appt_history` rows, "Add appointment" for admins, every cell editable), Call volume, Timesheets, Lead stats. Every view has Export CSV and, for admins, Download PDF (US Letter, landscape for wide tables).
- CSS gotcha: `#pnotes`/`#pdetails`/`#plog` still have old `grid-area` names; `.lead #id{grid-area:auto}` cancels them. Remove that rule and panels land in stray grid columns.

## Leftover files
`files.zip` and `supabase-v15-appt-history (2).sql` look like stray downloads (the duplicate is a near-identical copy of `supabase-v15-appt-history.sql`; the un-numbered file is the one to keep). Ask the user before deleting them.
