-- FOR THE SALES PORTAL REPO (keitharold-code/shell-nasuuti), supabase/migrations/. Not applied by the payments repo.
--
-- Problem: handle_new_auth_user() gives EVERY new auth.users row an active sales profile with role 'entry'
-- (write access to daily_entries). Once the Payments Portal shares this Supabase project:
--   * every payments-only user (cashier, D2, auditor...) would silently get sales write access;
--   * with Google sign-in enabled, any Google account that signs in would get it too.
--
-- Fix:
--   1. Payments users are created with user_metadata.module = 'payments' -> no sales profile at all.
--   2. Users who were NOT invited (self sign-up, Google, anything else) get an INACTIVE 'viewer' profile:
--      every sales RLS policy requires an active profile, so they see and change nothing until an admin
--      activates them in the sales Admin screen.
--   3. Invited users (the sales admin's inviteUserByEmail flow) behave exactly as before: active 'entry'.
--
-- Also do in the Supabase dashboard: Authentication -> Sign In / Providers -> turn OFF
-- "Allow new users to sign up". Both portals create users by invitation / admin API, and Google sign-in
-- then only works for people who already exist.
--
-- Test on a throwaway invited user before relying on it: invited_at must be set at insert time for the
-- invited path to stay active. If it is not, invited users arrive inactive (safe failure) and the admin
-- activates them once.

create or replace function handle_new_auth_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if coalesce(new.raw_user_meta_data ->> 'module', '') = 'payments' then
    return new;
  end if;

  insert into profiles (id, full_name, role, is_active)
  values (
    new.id,
    coalesce(new.raw_user_meta_data ->> 'full_name', new.email, 'New user'),
    case when new.invited_at is not null then 'entry' else 'viewer' end,
    new.invited_at is not null
  )
  on conflict (id) do nothing;
  return new;
end;
$$;
