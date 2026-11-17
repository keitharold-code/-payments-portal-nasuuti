-- =====================================================================
-- Shell Nasuuti Payments Portal — DRAFT SCHEMA FOR APPROVAL (not a migration yet)
-- Postgres 16 / Supabase. Money = bigint UGX. Timestamps = timestamptz (UTC).
-- Sections:
--   A. core.*      shared with the sales portal  (NEEDS KEITH'S CONFIRMATION)
--   B. payments.*  everything else
--   C. integrity rules enforced by constraints/triggers
--   D. RPC (SECURITY DEFINER) function list — signatures only, bodies in phase 1
--   E. RLS + storage approach
-- Conventions on every table unless noted:
--   id uuid pk, created_at, updated_at, created_by, deleted_at, deleted_by (soft delete only)
--   site_id on every business table. No DELETE grants for any role.
-- =====================================================================

create extension if not exists pgcrypto;
create extension if not exists btree_gist;    -- voucher range overlap constraint
create extension if not exists pg_trgm;       -- fuzzy supplier match (import + type-ahead)
create schema if not exists core;
create schema if not exists payments;

-- ---------------------------------------------------------------------
-- A. CORE (shared reference data).  Only these 3 objects live outside `payments`.
--    If the sales portal already has equivalents (sites / profiles / departments),
--    we REUSE them and create nothing here. Needs a look at the existing schema.
-- ---------------------------------------------------------------------
create table core.sites (
  id uuid primary key default gen_random_uuid(),
  code text not null unique,                    -- 'NAS'
  name text not null,                           -- 'Shell Nasuuti'
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  created_by uuid references auth.users(id),
  deleted_at timestamptz, deleted_by uuid
);

-- Per-module roles. Replaces users.roles[] / users.site_ids[] from the brief:
-- one row per (user, module, role, site). e.g. payments:cashier @ NAS, sales:manager @ NAS.
create table core.user_roles (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id),
  module text not null check (module in ('payments','sales')),
  role text not null,                           -- payments: cashier|station_manager|d1|d2|admin|auditor|requester
  site_id uuid not null references core.sites(id),
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  created_by uuid references auth.users(id),
  deleted_at timestamptz, deleted_by uuid,
  unique (user_id, module, role, site_id)
);
create index on core.user_roles (user_id) where active and deleted_at is null;

-- Profiles: REUSE public.profiles (id, full_name, role, is_active) from the sales portal.
-- Confirmed by reading that repo. Payments never touches profiles.role (sales-only column).
-- Phone lives in auth.users.phone. No core.profiles table is created.

create table core.departments (
  id uuid primary key default gen_random_uuid(),
  site_id uuid not null references core.sites(id),
  name text not null,
  default_category text check (default_category in ('stock_restock','fuel_order','opex')),
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  created_by uuid, deleted_at timestamptz, deleted_by uuid,
  unique (site_id, name)
);
-- seed: Shop, Lubricants, LPG, Fuel/Forecourt, Admin & Office, Utilities,
--       Statutory & Licences, Staff & Wages, Repairs & Maintenance

-- ---------------------------------------------------------------------
-- B. PAYMENTS
-- ---------------------------------------------------------------------
create type payments.payment_status as enum
  ('captured','query','verified','scheduled','on_hold','released','closed','rejected','cancelled');
create type payments.pay_method as enum
  ('bank_transfer','mobile_money','cheque','petty_cash');
create type payments.urgency as enum ('normal','urgent');
create type payments.category as enum ('stock_restock','fuel_order','opex');
create type payments.req_book_type as enum ('shop','lubes','office');
create type payments.voucher_book_type as enum ('shop','petty_cash');

-- Files (scans, receipts). Bucket is private; access via signed URLs.
create table payments.files (
  id uuid primary key default gen_random_uuid(),
  site_id uuid not null references core.sites(id),
  storage_path text not null unique,            -- {site}/{yyyy}/{kind}/{uuid}.jpg
  kind text not null check (kind in ('voucher','requisition','receipt','petty_cash','cancelled_voucher','emergency_approval','import')),
  mime text not null,
  size_bytes int not null check (size_bytes <= 1572864),   -- 1.5 MB
  sha256 text,                                  -- detects the same scan reused on two payments
  uploaded_by uuid not null references auth.users(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  created_by uuid, deleted_at timestamptz, deleted_by uuid
);

create table payments.requisition_books (
  id uuid primary key default gen_random_uuid(),
  site_id uuid not null references core.sites(id),
  type payments.req_book_type not null,
  serial_from int not null, serial_to int not null,
  issued_on date not null,
  status text not null default 'active' check (status in ('active','closed')),
  created_at timestamptz not null default now(), updated_at timestamptz not null default now(),
  created_by uuid, deleted_at timestamptz, deleted_by uuid,
  check (serial_from >= 0 and serial_to >= serial_from and serial_to <= 999)   -- 3-digit serials
);
-- requisition books: several may be active (one per department in use)

create table payments.voucher_books (
  id uuid primary key default gen_random_uuid(),
  site_id uuid not null references core.sites(id),
  type payments.voucher_book_type not null,
  serial_from int not null, serial_to int not null,
  issued_on date not null,
  status text not null default 'active' check (status in ('active','closed')),
  created_at timestamptz not null default now(), updated_at timestamptz not null default now(),
  created_by uuid, deleted_at timestamptz, deleted_by uuid,
  check (serial_from >= 0 and serial_to >= serial_from)
);
create unique index voucher_books_one_active on payments.voucher_books (site_id, type)
  where status = 'active' and deleted_at is null;
-- ranges of two books of the same type+site must not overlap (exclusion constraint):
alter table payments.voucher_books add constraint voucher_books_no_overlap
  exclude using gist (site_id with =, type with =, int4range(serial_from, serial_to, '[]') with &&)
  where (deleted_at is null);       -- requires btree_gist

create table payments.suppliers (
  id uuid primary key default gen_random_uuid(),
  site_id uuid not null references core.sites(id),
  name text not null,
  name_key text generated always as (lower(regexp_replace(name, '[^[:alnum:]]', '', 'g'))) stored,
  aliases text[] not null default '{}',
  default_method payments.pay_method,
  bank_name text, account_name text, account_no text,
  momo_number text, momo_name text,
  tin text, phone text,
  active boolean not null default true,
  details_changed_at timestamptz,               -- set by trigger when a payee field changes
  details_verified_by uuid references auth.users(id),
  details_verified_at timestamptz,              -- release needs verified_at >= changed_at
  merged_into uuid references payments.suppliers(id),
  created_at timestamptz not null default now(), updated_at timestamptz not null default now(),
  created_by uuid, deleted_at timestamptz, deleted_by uuid
);
create unique index suppliers_name_unique on payments.suppliers (site_id, name_key) where deleted_at is null;
create index suppliers_trgm on payments.suppliers using gin (name gin_trgm_ops);

create table payments.requisitions (
  id uuid primary key default gen_random_uuid(),
  site_id uuid not null references core.sites(id),
  book_id uuid not null references payments.requisition_books(id),
  serial_no int not null,
  department_id uuid not null references core.departments(id),
  raised_by_name text,
  approved_by_manager boolean not null default false,
  date_raised date,
  scan_file_id uuid references payments.files(id),
  legacy_ref text,
  created_at timestamptz not null default now(), updated_at timestamptz not null default now(),
  created_by uuid, deleted_at timestamptz, deleted_by uuid,
  unique (book_id, serial_no)
);

-- Per-site counters: pay numbers allocated inside the capture transaction => no gaps, never reused.
create table payments.site_counters (
  site_id uuid not null references core.sites(id),
  name text not null,                           -- 'pay_no'
  last_value bigint not null default 0,
  primary key (site_id, name)
);

create table payments.payments (
  id uuid primary key default gen_random_uuid(),
  site_id uuid not null references core.sites(id),
  pay_no text not null,                         -- NAS-PAY-000123
  legacy_ref text,                              -- NAS-REQ-... from the Sheet
  requisition_id uuid not null references payments.requisitions(id),
  voucher_book_id uuid not null references payments.voucher_books(id),
  voucher_no int not null,
  supplier_id uuid not null references payments.suppliers(id),
  description text not null,
  amount_ugx bigint not null check (amount_ugx > 0),
  method payments.pay_method not null,
  payee_details_snapshot jsonb not null,        -- frozen copy of supplier payee fields at capture
  date_required date not null,
  urgency payments.urgency not null,            -- derived in RPC
  category payments.category not null,          -- derived from department; admin override
  category_overridden boolean not null default false,
  status payments.payment_status not null default 'captured',
  is_emergency boolean not null default false,
  emergency_note text, emergency_file_id uuid references payments.files(id),
  captured_at timestamptz not null default now(),
  captured_by uuid not null references auth.users(id),
  verified_by uuid references auth.users(id), verified_at timestamptz, d1_comment text,
  scheduled_date date, scheduled_by uuid references auth.users(id),
  hold_reason text,
  released_by uuid references auth.users(id), released_at timestamptz,
  payment_ref text, date_paid date, closed_by uuid references auth.users(id), closed_at timestamptz,
  voucher_scan_file_id uuid not null references payments.files(id),
  receipt_file_id uuid references payments.files(id),
  flags text[] not null default '{}',           -- computed warnings: dup_possible, req_old, amount_3x, date_before_capture
  topup_id uuid,                                -- set when this payment IS a petty-cash top-up
  created_at timestamptz not null default now(), updated_at timestamptz not null default now(),
  created_by uuid, deleted_at timestamptz, deleted_by uuid,

  unique (site_id, pay_no),
  unique (voucher_book_id, voucher_no),                         -- never reused, even if rejected
  -- Segregation of duties, enforced at row level as a last line of defence:
  constraint sod_verify  check (verified_by is null or verified_by <> captured_by),
  constraint sod_release check (released_by is null or (released_by <> verified_by and released_by <> captured_by)),
  -- State consistency:
  constraint verified_has_who   check (status not in ('verified','scheduled','released','closed') or verified_by is not null),
  constraint scheduled_has_date check (status not in ('scheduled','released','closed') or scheduled_date is not null),
  constraint released_has_who   check (status not in ('released','closed') or (released_by is not null and released_at is not null)),
  constraint closed_has_proof   check (status <> 'closed' or (payment_ref is not null and date_paid is not null and receipt_file_id is not null))
);
-- (requisition, supplier) once among live payments; a rejected/cancelled one frees the slot:
create unique index payments_req_supplier_live on payments.payments (requisition_id, supplier_id)
  where status not in ('rejected','cancelled') and deleted_at is null;
create index payments_queue on payments.payments (site_id, status, scheduled_date);
create index payments_supplier on payments.payments (supplier_id, captured_at desc);
create index payments_dupe on payments.payments (supplier_id, amount_ugx, captured_at);

-- Append-only transition log (one row per status change, incl. capture: from_status null)
create table payments.payment_events (
  id uuid primary key default gen_random_uuid(),
  site_id uuid not null references core.sites(id),
  payment_id uuid not null references payments.payments(id),
  from_status payments.payment_status,
  to_status payments.payment_status not null,
  user_id uuid not null references auth.users(id),
  comment text,
  at timestamptz not null default now()
);
create index on payments.payment_events (payment_id, at);

-- Generic field-level audit (covers edits that do not change status, settings, suppliers, books…)
create table payments.audit_log (
  id bigint generated always as identity primary key,
  site_id uuid,
  table_name text not null, row_id uuid not null,
  action text not null check (action in ('insert','update','soft_delete')),
  old_row jsonb, new_row jsonb,
  user_id uuid, at timestamptz not null default now()
);
-- Both log tables: trigger blocks UPDATE/DELETE/TRUNCATE; app roles have INSERT via triggers only.

create table payments.petty_cash_floats (
  id uuid primary key default gen_random_uuid(),
  site_id uuid not null references core.sites(id),
  float_amount bigint not null check (float_amount > 0),
  custodian_user_id uuid not null references auth.users(id),
  active boolean not null default true,
  created_at timestamptz not null default now(), updated_at timestamptz not null default now(),
  created_by uuid, deleted_at timestamptz, deleted_by uuid
);
create unique index one_active_float on payments.petty_cash_floats (site_id) where active and deleted_at is null;

create table payments.petty_cash_topups (
  id uuid primary key default gen_random_uuid(),
  site_id uuid not null references core.sites(id),
  float_id uuid not null references payments.petty_cash_floats(id),
  period_from date not null, period_to date not null,
  total_ugx bigint not null check (total_ugx > 0),
  payment_id uuid references payments.payments(id),
  created_at timestamptz not null default now(), updated_at timestamptz not null default now(),
  created_by uuid, deleted_at timestamptz, deleted_by uuid,
  check (period_to >= period_from)
);
alter table payments.payments add constraint payments_topup_fk
  foreign key (topup_id) references payments.petty_cash_topups(id);

create table payments.petty_cash_entries (
  id uuid primary key default gen_random_uuid(),
  site_id uuid not null references core.sites(id),
  float_id uuid not null references payments.petty_cash_floats(id),
  voucher_book_id uuid not null references payments.voucher_books(id),   -- must be a petty_cash book
  voucher_no int not null,
  entry_date date not null,
  department_id uuid references core.departments(id),
  supplier_id uuid references payments.suppliers(id),
  payee_text text,
  description text not null,
  amount_ugx bigint not null check (amount_ugx > 0),    -- ceiling checked in RPC (setting)
  scan_file_id uuid references payments.files(id),
  topup_id uuid references payments.petty_cash_topups(id),   -- set when included in a top-up
  created_at timestamptz not null default now(), updated_at timestamptz not null default now(),
  created_by uuid, deleted_at timestamptz, deleted_by uuid,
  unique (voucher_book_id, voucher_no),
  check (supplier_id is not null or payee_text is not null)
);

create table payments.cancelled_vouchers (
  id uuid primary key default gen_random_uuid(),
  site_id uuid not null references core.sites(id),
  voucher_book_id uuid not null references payments.voucher_books(id),
  voucher_no int not null,
  reason text not null,
  cancelled_by uuid not null references auth.users(id),
  at timestamptz not null default now(),
  scan_file_id uuid references payments.files(id),
  created_at timestamptz not null default now(), updated_at timestamptz not null default now(),
  created_by uuid, deleted_at timestamptz, deleted_by uuid,
  unique (voucher_book_id, voucher_no)
);
-- trigger on payments / petty_cash_entries / cancelled_vouchers: a (book,no) may appear in only ONE of the three.

create table payments.settings (
  site_id uuid not null references core.sites(id),
  key text not null,
  value jsonb not null,
  updated_at timestamptz not null default now(), updated_by uuid,
  primary key (site_id, key)
);
-- defaults: petty_cash_limit=300000, mobile_bank_ceiling=1000000, any_method_limit=300000,
-- dup_window_days=7, dup_near_pct=5, dup_near_days=3, req_age_days=14, median_multiple=3,
-- urgent_share_pct=20, emergency_limit=300000, approval_sla_hours=24, session_hours=8

create table payments.reconciliations (
  id uuid primary key default gen_random_uuid(),
  site_id uuid not null references core.sites(id),
  week_start date not null,
  voucher_gaps_found int not null default 0,
  released_no_ref int not null default 0,
  unmatched_bank_lines int,                     -- phase 4
  signed_off_by uuid references auth.users(id), signed_off_at timestamptz,
  notes text,
  created_at timestamptz not null default now(), updated_at timestamptz not null default now(),
  created_by uuid, deleted_at timestamptz, deleted_by uuid,
  unique (site_id, week_start)
);

-- Supplier merge log (history is re-pointed; this keeps the audit of who merged what)
create table payments.supplier_merges (
  id uuid primary key default gen_random_uuid(),
  site_id uuid not null references core.sites(id),
  from_supplier_id uuid not null, into_supplier_id uuid not null,
  payments_repointed int not null,
  merged_by uuid not null, at timestamptz not null default now()
);

-- Import staging (phase 3): unmatched rows wait here for a human decision
create table payments.import_staging (
  id uuid primary key default gen_random_uuid(),
  site_id uuid not null, batch_id uuid not null,
  sheet_tab text not null, sheet_row int not null,
  raw jsonb not null, supplier_guess uuid, match_score real,
  resolution text check (resolution in ('pending','matched','new_supplier','skipped')) default 'pending',
  created_at timestamptz not null default now()
);

-- ---------------------------------------------------------------------
-- C. STATE MACHINE (table-driven so tests can read it)
-- ---------------------------------------------------------------------
create table payments.transitions (
  from_status payments.payment_status,          -- null = creation
  to_status payments.payment_status not null,
  allowed_role text not null                    -- d1|d2|cashier|station_manager|admin
);
create unique index transitions_uq on payments.transitions (from_status, to_status, allowed_role) nulls not distinct;
insert into payments.transitions values
  (null,        'captured',  'cashier'),
  ('captured',  'verified',  'd1'),
  ('captured',  'rejected',  'd1'),
  ('captured',  'query',     'd1'),
  ('captured',  'cancelled', 'cashier'),
  ('captured',  'verified',  'station_manager'),   -- emergency only, <= limit, flag set
  ('query',     'captured',  'cashier'),           -- after cashier edits
  ('query',     'rejected',  'd1'),
  ('query',     'cancelled', 'cashier'),           -- ASSUMPTION: brief says "before verification"
  ('verified',  'scheduled', 'cashier'),
  ('verified',  'on_hold',   'd1'), ('verified','on_hold','d2'),
  ('verified',  'rejected',  'd1'),
  ('scheduled', 'scheduled', 'cashier'),           -- reschedule
  ('scheduled', 'released',  'd2'),
  ('scheduled', 'on_hold',   'cashier'), ('scheduled','on_hold','d2'), ('scheduled','on_hold','d1'),
  ('on_hold',   'scheduled', 'd1'), ('on_hold','scheduled','d2'),
  ('on_hold',   'rejected',  'd1'), ('on_hold','rejected','d2'),
  ('released',  'closed',    'cashier'),
  ('closed',    'released',  'admin'),             -- reopen, reason required
  -- edit-after-verification reset (brief §3 last paragraph; not in its table, added explicitly)
  ('verified',  'captured',  'cashier'), ('scheduled','captured','cashier'), ('on_hold','captured','cashier');

-- ---------------------------------------------------------------------
-- D. RPC LIST (all SECURITY DEFINER, set search_path = '', check has_role + SoD + limits,
--    write payment_events in the same transaction). Browser never UPDATEs payments directly.
-- ---------------------------------------------------------------------
-- payments.capture_payment(p jsonb)                -> payments            allocates pay_no, derives urgency/category/flags, snapshots payee
-- payments.edit_payment(id, patch jsonb)           -> payments            only captured|query; after verification => resets to captured, clears verified_*
-- payments.verify_payment(id, comment)             -> payments            D1; SoD; supplier details must be verified or flagged
-- payments.query_payment(id, comment) / reject_payment(id, comment)
-- payments.cancel_payment(id, reason)              -> payments + cancelled_vouchers row
-- payments.schedule_payment(id, date)              -> payments            cashier; date >= today (Kampala) on first schedule
-- payments.hold_payment(id, reason) / unhold_payment(id, date)
-- payments.release_payment(id)                     -> payments            D2; verified_by <> me; scheduled_date not null; supplier details confirmed
-- payments.close_payment(id, ref, date_paid, receipt_file_id)
-- payments.reopen_payment(id, reason)              -> admin only
-- payments.emergency_payment(id, note, file_id)    -> station_manager, <= emergency_limit
-- payments.confirm_supplier_details(supplier_id)   -> D1; cannot be the user who last edited them
-- payments.merge_suppliers(from, into)             -> admin
-- payments.create_topup(period_from, period_to)    -> sums unlinked entries; creates the payment through capture_payment
-- payments.log_cancelled_voucher(book, no, reason, file_id)
-- payments.signoff_reconciliation(week_start, notes) -> admin
-- Read helpers / views (security_invoker): queue_today(site), queue_groups(site), missing_vouchers(site),
--    daily_totals_by_department(site, from, to), supplier_statement(supplier, from, to),
--    duplicate_candidates(payment_id), dashboard_cards(site)

-- ---------------------------------------------------------------------
-- E. RLS / STORAGE
-- ---------------------------------------------------------------------
-- helper: payments.has_role(role text, site uuid) stable security definer reads core.user_roles
-- SELECT policy on every payments.* table: user has ANY active payments role at row.site_id
--   (suppliers bank details & payee snapshot: same; auditors read-only).
-- INSERT/UPDATE/DELETE policies: none for authenticated. Writes only via the RPCs above
--   (and Edge Functions using the service role for: user admin, imports, Sheets push, notifications).
-- Storage bucket `payments-files`: private; path starts with site_id; no direct read policy,
--   clients ask a function for a signed URL (60 s) after the same site/role check.
