# Dial Desk setup

About 20 minutes. Do these in order.

## 1. Set up the database (Supabase)
1. Open your Supabase project and click **SQL Editor** in the left sidebar.
2. Click **New query**, paste everything from `supabase-setup.sql`, and click **Run**. You should see "Success. No rows returned."
3. Go to **Authentication > Sign In / Providers > Email** and turn **off** "Confirm email". (Only invited emails can sign up, so confirmation isn't needed, and the free plan sends very few emails per hour.)

## 2. Put the site online (Netlify)
1. Make a folder on your computer called `dial-desk` and put `index.html` inside it.
2. In Netlify, click **Add new site > Deploy manually** and drag the `dial-desk` folder onto the page.
3. Netlify gives you an address like `something-123.netlify.app`. Under **Site configuration > Change site name**, rename it, for example `dialdesk-crm`.

## 3. Tell Supabase your site address
1. In Supabase, go to **Authentication > URL Configuration**.
2. Set **Site URL** to your Netlify address (for example `https://dialdesk-crm.netlify.app`) and save. This makes password-reset emails link back to Dial Desk.

## 4. Create your account first
1. Open your site and click **Create your account**.
2. The first account created becomes the **Owner**. Do this before anyone else.

## 5. Invite your team
1. In Dial Desk, open **Team**, enter each person's email, choose Caller or Admin, and click **Invite**.
2. Send them the site address. They click **Create your account** and use the invited email.
3. Only the owner can invite admins or change roles.

## 6. Bring over your current leads
1. In the Claude version of Dial Desk, open **Lead board** and click **Export CSV**.
2. In the new Dial Desk, open **Import** and drop that file in.

## Optional: use crm.tbnadvertising.com
1. In Netlify, open **Domain management > Add a domain** and enter `crm.tbnadvertising.com`.
2. In GoDaddy DNS for tbnadvertising.com, add a **CNAME** record: Name `crm`, Value your Netlify address (for example `dialdesk-crm.netlify.app`).
3. Update the Supabase **Site URL** to `https://crm.tbnadvertising.com`.

## Updating Dial Desk later
When I send you a new `index.html`, open your site in Netlify, go to **Deploys**, and drag the folder with the new file onto the page.
