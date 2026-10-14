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
- `calls`: one row per logged call (lead, caller, status, note, `prev` = lead state before the call). Written only through `log_call()`; `undo_call()` reverses the latest call on a lead.
- `lead_notes`: dated comments on a lead (author, body, created_at). Never hard-deleted: `set_note_deleted()` sets `deleted_at/deleted_by` (author or admin) and can restore; deleted notes stay visible (struck through) in history. A trigger copies the newest non-deleted note into `leads.notes/notes_at/notes_by` for the Leads page and search.
- Trash: leads are soft-deleted with `deleted_at`/`deleted_by` (admins only, enforced by the `guard_leads` trigger). Callers never see trashed leads; admins restore them or delete forever from the Trash filter on the Leads page.
- `status_rank` is a generated column giving the pipeline order for sorting.
- Converting: `convert_lead()` creates an opportunity, sets the lead to `converted` with `sales_owner_id`/`opportunity_id`; `unconvert_lead()` undoes it. Only these functions may change those fields (guard trigger + `dialdesk.bypass` setting).
- `clients` and `agencies`: shared lists (unique by lower-cased name); `ensure_client()`/`ensure_agency()` find-or-create by name.
- `opportunities` (UI says "Deal"): deal_name, client_id ("Client Name"), agency_id, owner_id (salesperson), type (`first_deal`/`returning`), stage (`prospecting`,`proposal`,`nurturing`,`closed_won`,`closed_lost`; negotiation was removed in v4), probability, amount, follow_up_date ("Follow Up"), lead_source, description, products[], lead_id, converted_by. Legacy columns close_date, next_step and contact_* still exist but the UI no longer uses them. Soft-deleted with `deleted_at` (admins only).
- `opp_contacts`: any number of contacts per deal (name, title, email, phone); soft-removed with `deleted_at` and restorable. The `log_contact()` trigger writes contact_added/removed/restored/edited rows into `change_log` (row_id = opp id).
- `opp_notes`: dated notes on deals; soft-deleted like lead notes via `set_note_deleted('opp', ...)`.
- `change_log`: edit history written by the `log_changes()` trigger on leads, opportunities and clients (field -> [old, new], who, when). `updated_by` on leads/opportunities/clients is set by `touch_updated_at()`.
- Lead statuses: `new`, `call1` (1st Call), `call2`, `call3`, `gatekeeper`, `appointment` (Appointment Set), `converted`, `dead`, `bad_info` (Bad Information).

## Permissions
- Callers see and update only leads assigned to them (admins assign them on Leads; there is no Calling/queue page and no Pull button any more). They can convert their leads with "Appointment Set!". They never see opportunities or reports, and the Caller column is hidden for them.
- Salespeople see every lead and every opportunity and see Reports; they edit only leads converted to them and deals they own or created. Only admins reassign deals.
- Admins (and the Owner) see everything, import (`import_leads()`), assign, bulk-update, export and delete.
- Only the Owner changes roles or turns access off (`set_member()`), and only the Owner can invite admins.

## UI layout (v4)
- Tabs: Leads (home for callers/admins), Opportunities (home for salespeople), Reports, Import, Team. Clicking a lead opens the lead page with ← Leads, Previous/Next (follows the Leads list order) and the Convert / Appointment Set! button at top right. "Save call & next" moves to the next lead in the Leads list.
- History is never hidden: edits, calls and notes (including deleted ones) all show; field edits have an Undo button in the history.

## Making changes
- Edit `index.html`, check the script parses, commit and push to `main`; Netlify publishes in about a minute.
- Database changes: update `supabase-setup.sql` (keep it re-runnable). Claude cannot reach Supabase from its workspace, so give the user the SQL to paste into Supabase > SQL Editor > Run, and tell them exactly what result to expect.
- The users are not developers. Explain steps in plain words, one click at a time.
