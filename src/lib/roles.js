// Roles are per module in core.user_roles (module, role, site_id).
// The browser only uses this to decide what to SHOW; the database enforces what is ALLOWED.

export const PAY_ROLES = {
  cashier: "Cashier",
  station_manager: "Station Manager",
  d1: "Director 1 (Verifier)",
  d2: "Director 2 (Payer)",
  admin: "Admin",
  auditor: "Auditor",
  requester: "Requester",
};

export function rolesFor(roles, module) {
  return [...new Set((roles || []).filter((r) => r.module === module).map((r) => r.role))];
}

export function hasAny(roles, module, wanted) {
  const mine = rolesFor(roles, module);
  return wanted.some((w) => mine.includes(w));
}

export function roleLabels(roles, module) {
  return rolesFor(roles, module).map((r) => PAY_ROLES[r] || r);
}

export function siteIds(roles, module) {
  return [...new Set((roles || []).filter((r) => r.module === module).map((r) => r.site_id))];
}
