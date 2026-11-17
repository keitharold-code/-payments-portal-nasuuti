# Shell Nasuuti Payments Portal — Design for approval

Status: **proposal, no app code written.** Schema: `docs/schema-proposal.sql` (loads cleanly on Postgres 16).
Nothing below is built until Keith signs off the items in section 1.

---

## 1. Decisions needed from Keith before Phase 1

The brief ticks the open questions but gives no answers. I have assumed the defaults below. Reply "approved" or change any line.

| # | Question | Assumed default | Why |
|---|---|---|---|
| 1 | Same Supabase project, `payments` schema | **Yes** | Shared login |
| 2 | Tables outside `payments` | **3 only:** `core.sites`, `core.user_roles`, `core.departments` (+ `core.profiles` if the sales portal has none) | Minimum needed for shared login and roles. **Needs your OK.** If the sales portal already has sites/profiles/departments, I reuse them and create nothing |
| 3 | Suppliers: shared or payments? | **`payments.suppliers` for now**, exposed later through a view | The brief lists suppliers as shared, but they hold bank and MoMo numbers. Keeping them in `payments` means the sales portal cannot read them by accident. Moving them later is a view change, not a rewrite |
| 4 | Limits | UGX 300,000 petty cash / any method; 1,000,000 bank-only threshold. All editable in Settings | As briefed |
| 5 | D2 verifies when D1 is away | **No.** Only Admin (Keith) can, and still never on something they captured or will release | Keeps three distinct people on every payment. A time-boxed "delegate verifier" can be added later |
| 6 | Other Admins | Keith only | Add a second as a backup in case you are unreachable |
| 7 | Multi-site | Built multi-site (`site_id` everywhere, roles per site) | As briefed |
| 8 | Logo | Text wordmark "Shell Nasuuti — Payments" | As briefed |
| 9 | Project plan | Needs **Supabase Pro** | Daily backups and an 8-hour session limit are Pro features. Free plan has neither. Which plan is the existing project on? |

**I need access to the existing portal.** I only have this empty repo. To match it "exactly" I need its `src/style.css`, `package.json`/Vite config and its Supabase schema (especially any existing profiles/roles tables). Attach the repo or paste those files. Until then I use only the tokens in the brief.

---

## 2. Where I disagree with the brief

1. **Release and reopen as Edge Functions.** The brief says status transitions are SECURITY DEFINER functions, and also lists release and reopen as Edge Functions. Two places holding one rule is how bugs get in. **Proposal:** all transitions, including release and reopen, are database RPCs called with the user's own session. Edge Functions only do what needs the service key: create or disable users, Sheet import, Google Sheets push, notifications, signed upload URLs.
2. **`users.roles[]` and `site_ids[]` vs `user_roles(module, role)`.** The brief asks for both. Section 7 (per module) is right, so I dropped the arrays. `core.user_roles(user_id, module, role, site_id)`.
3. **A rejected voucher number is never reusable.** The brief says "a new capture is required" and also that a voucher number cannot be used twice. The signed paper voucher exists, so the retry needs a **new voucher number**. The old one stays Rejected. The (requisition, supplier) uniqueness frees up on Rejected/Cancelled so the retry is allowed.
4. **Edit-after-verification needs a transition the table doesn't list.** Verified, Scheduled and On hold go back to Captured when amount, supplier or payee details change. Added explicitly in the state machine.
5. **Query → Cancelled.** Not in the brief's table. I allow it (it is still "before verification"). Say if you don't want it.
6. **Emergency payments.** Modelled as Captured → Verified by the Station Manager, with `is_emergency`, the approval message attached, and a cap of UGX 300,000. It is still released by D2, so the only control skipped is D1. If the Station Manager captured it, the segregation rule blocks them. Do you want emergency items also excluded from bulk-verify and shown red in the weekly review? I assume yes.
7. **"Petty Cash" as a payment method vs the petty cash book.** The brief has both: small spends go in the book, but `Petty Cash` is also a payment method. I read it as: a full payment can be settled from the float (e.g. a UGX 280,000 supplier with an invoice), while routine small spends use the book. Confirm, otherwise I remove the method.
8. **Weekly "20% urgent" warning** is a week-level figure, not a per-item flag. It shows on the D1 inbox header and the dashboard, not on each payment.
9. **Splitting to dodge limits.** Not in the brief, cheap to add: a warning when one supplier's same-day payments total more than a method limit. Off by default; say if you want it.
10. **Requisition scan.** The brief hard-blocks only on the voucher scan. I require the requisition scan on the first capture against a requisition, as a warning, not a block. Say if it should block.
11. **Session timeout and phone login.** Phone + password works without paying for SMS if the Admin creates users (phone pre-confirmed). Google sign-in is allowed only for emails already provisioned by Admin; unknown Google accounts get no access.

---

## 3. Data model summary

Full DDL in `docs/schema-proposal.sql`. Highlights:

- **Segregation of duties in two layers:** every transition RPC checks it, and `CHECK` constraints on `payments` (`verified_by <> captured_by`, `released_by` different from both) catch anything that slips past.
- **Cannot save an invalid state:** `CHECK`s on status vs required fields (verified needs a verifier, scheduled needs a date, released needs a releaser, closed needs reference, date paid and receipt).
- **Voucher uniqueness:** `unique (voucher_book_id, voucher_no)` on payments, petty cash entries and cancelled vouchers, plus a trigger so one number lives in only one of the three. Book ranges cannot overlap, and one active book per type per site.
- **Pay numbers:** per-site counter row locked inside the capture transaction. No gaps, never reused.
- **Supplier names:** unique per site ignoring case and punctuation (generated `name_key`).
- **Supplier bank details:** `details_changed_at` set by trigger on any payee field change. Release requires `details_verified_at >= details_changed_at` **and** the payment's snapshot equal to the current supplier details. If they differ, the cashier re-snapshots, which sends the payment back to Captured.
- **Audit:** `payment_events` (status transitions, append-only) plus `audit_log` (field-level diffs on every table, append-only via trigger). No DELETE grant anywhere.
- **State machine is a table** (`payments.transitions`) so tests read the allowed paths from the same source the RPCs use.
- **Dates and money:** `bigint` UGX, `timestamptz` UTC, Kampala conversion in views and the UI. "Today", "Overdue" and "urgent within 24 hours" are computed on the Kampala date.
- **ERP hooks:** read views `payments.queue_today` and `payments.daily_totals_by_department`, `security_invoker` so RLS still applies when the sales portal calls them.

RLS: any active payments role at a site can read that site's rows. **No** direct insert/update/delete for browser users. Files sit in a private bucket and are opened through short-lived signed URLs after the same check.

---

## 4. Screens (mobile-first)

Navigation is a bottom tab bar on phones (4 items by role + "More"), top nav on desktop. Headings in Barlow Condensed; queue colours: Overdue red, Today green, actions yellow.

| # | Screen | Roles | Phase | Notes |
|---|---|---|---|---|
| 0 | **Launcher** | all | 1 | Two tiles: Daily Sales & GP (link to existing URL, configurable) and Payments Portal |
| 1 | **Login** | all | 1 | Phone or email + password; Google for pre-approved emails; 8-hour session |
| 2 | **Home dashboard** | all, by role | 1 | Cards: Due today, Overdue, Awaiting my action, Verified not scheduled, Missing vouchers (Phase 2), Petty cash balance (Phase 2). Each card taps through to a filtered list |
| 3 | **Capture payment** | cashier | 1 | Single scrolling form: requisition book + serial → voucher book + number (next number pre-filled) → supplier type-ahead → amount → method (only allowed methods enabled for the amount) → date required → description → camera scan. Payee details shown read-only from the supplier. Inline errors. Draft kept locally if signal drops |
| 4 | **Verify inbox** | D1 (+ admin) | 1 | Card list. Open a card: scan with pinch-zoom above, entry below (side by side on desktop). Amber warnings, supplier-details-changed notice. One-tap Verify / Query / Reject (comment required for the last two). Bulk verify only for items with no warnings |
| 5 | **Payment queue** | cashier, D2, manager, admin | 1 | Groups: 1 Overdue (red), 2 Today (green), 3 Verified not scheduled, 4 Upcoming, plus **5 Released, awaiting close** (my addition, so step 8 never gets lost). Each group shows count and total UGX. Row actions: Schedule/Reschedule, Release (D2), Hold. On hold is a filter chip |
| 6 | **Release & close** | D2 / cashier | 1 | D2: release button shows the NAS-PAY number to quote in the narration. Cashier: payment ref, date paid, receipt upload, Close |
| 7 | **Payment detail** | all | 1 | Full record, scans, warnings, audit timeline (who, when, from → to, comment) |
| 8 | **My captures / Query list** | cashier | 1 | Items sent back with D1's comment, edit and resubmit |
| 9 | **Suppliers** | cashier (add/edit), D1 (confirm bank details), admin (merge) | 1 | List + search, add/edit, "needs confirmation" badge, merge duplicates (re-points history, logged), supplier statement link |
| 10 | **Books** | cashier, admin | 1 / 2 | Register requisition and voucher books, mark cancelled vouchers (Phase 2: missing-voucher explanations) |
| 11 | **Petty cash book** | cashier | 2 | Entries, running balance, float, create top-up (blocks unless entries sum exactly to the total) |
| 12 | **Weekly reconciliation** | admin (+ auditor read) | 2 | Voucher gaps, released-without-reference, emergency payments this week, sign-off. Bank statement upload is Phase 4 |
| 13 | **Reports** | admin, auditor, directors, manager | 3 | Spend by department / supplier / method / week / month, urgent share, cycle times (Captured → Verified → Released), supplier statement. CSV, XLSX, PDF, Google Sheets push |
| 14 | **Settings & users** | admin | 1 / 2 | Phase 1: users and roles. Phase 2: limits, windows, category overrides |
| 15 | **Import review** | admin | 3 | Unmatched suppliers list, dry-run reconciliation report |

Cut for Phase 1: Missing vouchers card, petty cash, reconciliation and reports. Everything else needed for "the cashier can run a full day of payments".

---

## 5. Build plan and tests

Layout: `index.html`, `src/{main.js,style.css,store.js,router.js,api/,views/,components/}`, `supabase/{migrations,functions,tests,seed.sql}`, `scripts/import-sheet/`, `docs/`. Vite 5, es2019, `vercel.json`.

Order inside Phase 1, each step merged and tested before the next:

1. Scaffold, brand tokens, store, router, launcher, login, role gate
2. Migrations: core + payments tables, RLS, audit triggers, seed
3. Suppliers + Books screens
4. Capture RPC + screen (image compression to ≤ 1.5 MB, private upload)
5. Verify, schedule, release, close RPCs + Verify inbox + Queue + Detail
6. Phase 1 acceptance run on a phone-size viewport

Tests:
- **Database (pgTAP, local Supabase):** acceptance tests 1, 2, 3, 4, 5, 6, 7, 8, 9 run as SQL against the RPCs with real role JWTs. This is where the rules live, so this is where they are proven.
- **End-to-end (Playwright, 390 px viewport):** test 1 end to end through the UI with five users, plus capture under 60 seconds, mobile layout, queue colours.
- **Import (Phase 3):** test 10 runs the dry run on a fixture Sheet export and asserts equal monthly counts and UGX totals.
- CI on every branch; Vercel preview per branch.

---

## 6. Risks I would watch

- **Parallel run needs a cut-over rule.** Two systems for two weeks means double entry for the cashier. Name one owner per day for reconciling Sheet vs portal, or the "identical totals" test becomes unprovable.
- **Scans are the weak control.** The system proves a scan exists, not that it is the right paper. A hash check for the same image reused on two payments is in the schema (`files.sha256`); a human still compares the scan to the entry.
- **Admin is a single point of trust.** Keith can verify and reopen. Every reopen is logged with a reason and appears in the weekly review; I suggest the Auditor sees them first.
- **Supabase plan** (item 9 above) decides whether "daily backups" is a promise or a hope.

---

## 7. Update after reading the existing portal (Phase 1, step 1)

- Existing portal uses `public.profiles(id, full_name, role in admin|entry|viewer, is_active)`. Payments **reuses it**; `core.profiles` is dropped. Outside `payments` we create only `core.sites`, `core.user_roles`, `core.departments`.
- **Risk to fix before creating payments users:** the sales portal has a trigger on `auth.users` that gives every new user the sales role `entry`. Creating a payments-only user (e.g. the Auditor) would silently give them write access to sales data. Proposed fix (needs Keith's OK, touches the sales project): change the trigger default to `viewer`, or skip it when `raw_user_meta_data->>'module' = 'payments'`.
- Supabase dashboard: add `core` and `payments` to **Settings → API → Exposed schemas** so the browser client can call them (RLS still applies).
