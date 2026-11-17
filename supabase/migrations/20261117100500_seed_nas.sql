-- Reference data for Shell Nasuuti (idempotent). Limits are defaults; Admin edits them in Settings.
insert into core.sites (code, name) values ('NAS', 'Shell Nasuuti') on conflict (code) do nothing;

insert into core.departments (site_id, name, default_category)
select s.id, d.name, d.cat from core.sites s,
 (values ('Shop','stock_restock'), ('Lubricants','stock_restock'), ('LPG','stock_restock'),
         ('Fuel/Forecourt','fuel_order'), ('Admin & Office','opex'), ('Utilities','opex'),
         ('Statutory & Licences','opex'), ('Staff & Wages','opex'), ('Repairs & Maintenance','opex')) d(name, cat)
where s.code = 'NAS'
on conflict (site_id, name) do nothing;

insert into payments.settings (site_id, key, value)
select s.id, v.k, v.v from core.sites s,
 (values ('petty_cash_limit','300000'::jsonb), ('any_method_limit','300000'), ('mobile_bank_ceiling','1000000'),
         ('emergency_limit','300000'), ('dup_window_days','7'), ('dup_near_pct','5'), ('dup_near_days','3'),
         ('req_age_days','14'), ('median_multiple','3'), ('urgent_share_pct','20'),
         ('approval_sla_hours','24'), ('session_hours','8')) v(k, v)
where s.code = 'NAS'
on conflict (site_id, key) do nothing;
