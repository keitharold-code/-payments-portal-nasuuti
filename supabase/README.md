# Supabase (Payments Portal)

Same Supabase project as the Daily Sales & Gross Profit portal. Objects: schema `payments` (everything),
schema `core` (sites, user_roles, departments only).

## Applying migrations
The sales repo already uses versions `0001`-`0005` in the shared migration history, so these files are
timestamp-named to avoid collisions. Because the CLI would see the sales versions as "missing locally",
apply them with the **SQL Editor** (paste each file, in filename order) or `psql "$DATABASE_URL" -f <file>`.
Do not run `supabase db push` from this repo.

Order: `20261117100000_core` -> `..100100_payments_tables` -> `..100200_payments_guards`
-> `..100300_rls_grants` -> `..100400_storage` -> `..100500_seed_nas` -> `..100600_rpc_suppliers_books` -> `..100650_fix_audit_settings` -> `..100700_files_and_capture`.

Before creating any payments user, apply `docs/sales-portal-fix/0006_new_users_not_sales_entry.sql`
in the sales project (see its header), and turn off "Allow new users to sign up".

After applying: Settings -> API -> **Exposed schemas**: add `core` and `payments`.

## Database tests
`npm run test:db` (needs PostgreSQL 16 binaries) spins up a throwaway Postgres with Supabase-style stubs,
applies every migration, and runs `supabase/tests/NN_*.sql`. Writes are only possible through RPCs
(added with capture / verify / release), so these tests prove the row-level rules those RPCs sit on.

## Payments users
Created by the admin Edge Function (later step) with `user_metadata = {module: 'payments', full_name}`,
so the sales portal's new-user trigger gives them no sales profile.
