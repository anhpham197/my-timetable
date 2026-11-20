# Timetable

A public timetable and booking page designed for GitHub Pages. Every visit opens the sanitized public schedule, even when the owner has a saved sign-in session. Choose **Owner sign in** to open the private timetable and manage booking requests.

## Connect the owner sign-in and shared data

The page uses Supabase Auth and Postgres with Row Level Security. GitHub Pages serves the frontend; Supabase verifies the owner and stores shared schedule data. The database returns only sanitized public rows to signed-out visitors.

1. Create a Supabase project and run [`supabase/schema.sql`](supabase/schema.sql) in its SQL Editor.
2. Deploy the site to GitHub Pages so you have its final URL, such as `https://<username>.github.io/<repository>/`.
3. Create a GitHub OAuth App under **GitHub Settings → Developer settings → OAuth Apps**. Set its homepage URL to your deployed page. For its authorization callback URL, copy the GitHub callback shown in Supabase under **Authentication → Sign In / Providers → GitHub**. It looks like `https://<project-ref>.supabase.co/auth/v1/callback`.
4. In Supabase **Authentication → Sign In / Providers → GitHub**, enable GitHub and enter the OAuth App's client ID and client secret. In **Authentication → URL Configuration**, set the Site URL to your deployed GitHub Pages URL and add that URL to the allowed redirect URLs. See the [Supabase GitHub sign-in guide](https://supabase.com/docs/guides/auth/social-sign-in/auth-github).
5. In `supabase-config.js`, set your project URL and **publishable key** from the Supabase dashboard. Publishable keys are intended for browser use; never put a Supabase secret or service-role key in this file. See [Supabase API keys](https://supabase.com/docs/guides/getting-started/api-keys). If you don't want to edit locally, open this file on GitHub.com, use the edit button, and commit the change there.
6. Deploy the config change, open your timetable, and choose **Owner sign in**. GitHub will ask you to authorize the app and return you to the timetable. The first sign-in creates your Supabase Auth user; until ownership is assigned, the page will sign that account out.
7. In Supabase **Authentication → Users**, copy that user's UUID. In the SQL Editor, assign it as the owner:

   ```sql
   insert into private.timetable_settings (singleton, owner_id)
   values (true, 'PASTE-YOUR-AUTH-USER-UUID-HERE')
   on conflict (singleton) do update set owner_id = excluded.owner_id;
   ```

8. Choose **Owner sign in** again. That sign-in opens your owner timetable; future visits still start on the public schedule until you choose **Owner sign in**. Visitors can request an open time without an account by providing their name and email.

For local use, serve this folder over HTTP (for example, `python3 -m http.server 8000`) and open `http://localhost:8000`.

## Privacy and access

- Anyone can read the public schedule through a database function that changes private names to “Unavailable”.
- Visitors can submit booking requests without signing in; requests stay pending in the owner's inbox until accepted or declined. The owner inbox refreshes while the owner view is open.
- Only the configured Supabase Auth user ID, associated with your GitHub sign-in, can read private event names, edit slots, or manage requests. The database enforces this with Row Level Security.
- The Supabase publishable key is visible in the page by design. The schema does not grant public access to raw timetable or booking tables.
- Keep the `private` schema out of Supabase's exposed API schemas. The policies use it only for an owner check. See [Supabase Row Level Security](https://supabase.com/docs/guides/database/postgres/row-level-security).
