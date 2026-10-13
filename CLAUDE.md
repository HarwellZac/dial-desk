# Dial Desk — notes for Claude

Dial Desk is the outbound calling CRM for an appointment-setting team. Callers work a queue of leads, log each call with a status, and book appointments for sales reps. Admins import ZoomInfo CSV/Excel lists, assign leads and manage the team.

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
- `lead_notes`: dated comments on a lead (author, body, created_at). A trigger copies the newest note into `leads.notes/notes_at/notes_by` for the Lead board and search.
- Trash: leads are soft-deleted with `deleted_at`/`deleted_by` (admins only, enforced by the `guard_leads` trigger). Callers never see trashed leads; admins restore them or delete forever from the Trash filter on the Lead board.
- `status_rank` is a generated column giving the pipeline order for sorting.
- Converting: `convert_lead()` creates an opportunity, sets the lead to `converted` with `sales_owner_id`/`opportunity_id`; `unconvert_lead()` undoes it. Only these functions may change those fields (guard trigger + `dialdesk.bypass` setting).
- `clients` and `agencies`: shared lists (unique by lower-cased name); `ensure_client()`/`ensure_agency()` find-or-create by name.
- `opportunities` (UI says "Deal"): deal_name, client_id ("Client Name"), agency_id, owner_id (salesperson), type (`first_deal`/`returning`), stage (`prospecting`,`proposal`,`negotiation`,`nurturing`,`closed_won`,`closed_lost`), probability, amount, close_date, lead_source, next_step, description, products[], primary contact fields, lead_id, converted_by. Soft-deleted with `deleted_at` (admins only).
- `opp_notes`: dated notes on deals.
- `change_log`: edit history written by the `log_changes()` trigger on leads, opportunities and clients (field -> [old, new], who, when). `updated_by` on leads/opportunities/clients is set by `touch_updated_at()`.
- Lead statuses: `new`, `call1` (1st Call), `call2`, `call3`, `gatekeeper`, `appointment` (Appointment Set), `converted`, `dead`, `bad_info` (Bad Information).

## Permissions
- Callers see and update only leads assigned to them; they pull unassigned leads with `pull_leads()` and can convert their leads. They never see opportunities or reports.
- Salespeople see every lead and every opportunity and see Reports; they edit only leads converted to them and deals they own or created. Only admins reassign deals.
- Admins (and the Owner) see everything, import (`import_leads()`), assign, bulk-update, export and delete.
- Only the Owner changes roles or turns access off (`set_member()`), and only the Owner can invite admins.

## Making changes
- Edit `index.html`, check the script parses, commit and push to `main`; Netlify publishes in about a minute.
- Database changes: update `supabase-setup.sql` (keep it re-runnable). Claude cannot reach Supabase from its workspace, so give the user the SQL to paste into Supabase > SQL Editor > Run, and tell them exactly what result to expect.
- The users are not developers. Explain steps in plain words, one click at a time.
