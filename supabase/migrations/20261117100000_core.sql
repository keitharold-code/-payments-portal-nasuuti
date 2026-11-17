-- Shared reference data. The ONLY objects outside the `payments` schema.
-- Sites, per-module roles and departments serve both the sales and payments portals.
create schema if not exists core;
create schema if not exists payments;

create table core.sites (
  id uuid primary key default gen_random_uuid(),
  code text not null unique,                    -- 'NAS'
  name text not null,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  created_by uuid references auth.users(id),
  deleted_at timestamptz, deleted_by uuid
);

-- One row per (user, module, role, site): payments:cashier@NAS, sales:manager@NAS ...
-- Written only by the admin Edge Function (service role). Deactivate = active=false.
create table core.user_roles (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id),
  module text not null check (module in ('payments','sales')),
  role text not null,
  site_id uuid not null references core.sites(id),
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  created_by uuid references auth.users(id),
  deleted_at timestamptz, deleted_by uuid,
  unique (user_id, module, role, site_id),
  constraint payments_roles_valid check (module <> 'payments' or role in
    ('cashier','station_manager','d1','d2','admin','auditor','requester'))
);
create index user_roles_user on core.user_roles (user_id) where active and deleted_at is null;

create table core.departments (
  id uuid primary key default gen_random_uuid(),
  site_id uuid not null references core.sites(id),
  name text not null,
  default_category text check (default_category in ('stock_restock','fuel_order','opex')),
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  created_by uuid references auth.users(id),
  deleted_at timestamptz, deleted_by uuid,
  unique (site_id, name)
);
