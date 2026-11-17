// Pure helpers for the supplier screens (no DOM, no network) so they can be unit-tested.

export const METHODS = {
  bank_transfer: "Bank transfer",
  mobile_money: "Mobile money",
  cheque: "Cheque",
  petty_cash: "Petty cash",
};

// Same idea as the database's name_key: ignore case, spaces and punctuation.
export function norm(s) {
  return String(s || "").toLowerCase().replace(/[^\p{L}\p{N}]/gu, "");
}

// Bank / mobile money details exist and nobody other than the editor has confirmed the latest change.
export function needsConfirmation(s) {
  if (!s.details_changed_at) return false;
  if (!s.details_verified_at) return true;
  return Date.parse(s.details_verified_at) < Date.parse(s.details_changed_at);
}

export function payeeSummary(s) {
  const parts = [];
  if (s.bank_name || s.account_no) parts.push([s.bank_name, s.account_no].filter(Boolean).join(" · "));
  if (s.momo_number) parts.push("MoMo " + s.momo_number + (s.momo_name ? " (" + s.momo_name + ")" : ""));
  return parts.join(" | ");
}

export function matches(s, q) {
  const n = norm(q);
  if (!n) return true;
  return [s.name, ...(s.aliases || []), s.phone, s.account_no, s.momo_number].some((x) => norm(x).includes(n));
}

export function findDuplicate(list, name, excludeId) {
  const n = norm(name);
  if (!n) return null;
  return list.find((s) => s.id !== excludeId && norm(s.name) === n) || null;
}

export function toPayload(form, site, id) {
  const aliases = String(form.aliases || "").split(",").map((x) => x.trim()).filter(Boolean);
  const p = {
    name: String(form.name || "").trim(),
    aliases,
    default_method: form.default_method || "",
    bank_name: form.bank_name || "", account_name: form.account_name || "", account_no: form.account_no || "",
    momo_number: form.momo_number || "", momo_name: form.momo_name || "",
    tin: form.tin || "", phone: form.phone || "",
    active: form.active !== false,
  };
  return id ? { ...p, id } : { ...p, site_id: site };
}

export function validateSupplier(form) {
  const errs = [];
  if (!String(form.name || "").trim()) errs.push("Name is required.");
  if (form.bank_name && !form.account_no) errs.push("Add the account number for the bank.");
  if (form.account_no && !form.account_name) errs.push("Add the account name.");
  if (form.momo_number && !/^\+?\d{9,15}$/.test(String(form.momo_number).replace(/[\s-]/g, "")))
    errs.push("Mobile money number should be digits only.");
  return errs;
}
