# Dial Desk — notes for Claude

Dial Desk is the outbound calling CRM for an appointment-setting team. Callers work a queue of leads, log each call with a status, and book appointments for sales reps. Admins import ZoomInfo CSV/Excel lists, assign leads and manage the team.

## How it is built
- `index.html` is the whole app: one static page (HTML, CSS and plain JavaScript, no build step). It loads `@supabase/supabase-js` and SheetJS from CDNs.
- Data and logins live in Supabase (project `https://cioqpzsblddghiuzpbvy.supabase.co`). The page uses the **publishable** key, which is safe in client code. Never put a secret / `service_role` key in this repo.
- `supabase-setup.sql` creates every table, security rule (RLS) and database function. It must stay safe to re-run (`if not exists`, `create or replace`, `drop policy if exists`).
- `supabase-fix-owner.sql` is a one-off repair that makes the earliest login the Owner.
- Netlify (site `dialdeskcrm`, https://dialdeskcrm.netlify.app) deploys automatically from the `main` branch. `netlify.toml` publishes the repo root.

## Data model
- `profiles`: one row per person; `role` is `owner`, `admin` or `caller`; `active` turns access on/off.
- `invites`: emails allowed to sign up. The first account ever created becomes the Owner; everyone else must be invited (enforced by the `handle_new_user` trigger).
- `leads`: contact fields, `extra` (jsonb for unmapped import columns), `status`, `owner_id` (assigned caller), callback/appointment fields, `notes`.
- `calls`: one row per logged call (lead, caller, status, note). Written only through `log_call()`.
- Statuses: `new`, `call1` (1st Call), `call2`, `call3`, `gatekeeper`, `appointment` (Appointment Set), `dead`, `bad_info` (Bad Information).

## Permissions
- Callers see and update only leads assigned to them; they pull unassigned leads with `pull_leads()`.
- Admins (and the Owner) see everything, import (`import_leads()`), assign, bulk-update, export and delete.
- Only the Owner changes roles or turns access off (`set_member()`), and only the Owner can invite admins.

## Making changes
- Edit `index.html`, check the script parses, commit and push to `main`; Netlify publishes in about a minute.
- Database changes: update `supabase-setup.sql` (keep it re-runnable). Claude cannot reach Supabase from its workspace, so give the user the SQL to paste into Supabase > SQL Editor > Run, and tell them exactly what result to expect.
- The users are not developers. Explain steps in plain words, one click at a time.
