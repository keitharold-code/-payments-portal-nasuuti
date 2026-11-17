// Pure rules for the capture screen. The database is the authority; these mirror it so the cashier
// sees problems immediately instead of after a round trip on a slow connection.
import { addDays } from "./format.js";
import { METHODS } from "./suppliers.js";

export const DEFAULT_LIMITS = { any_method_limit: 300000, mobile_bank_ceiling: 1000000, petty_cash_limit: 300000 };
const ALL = ["bank_transfer", "mobile_money", "cheque", "petty_cash"];

export function limitsFrom(rows) {
  const L = { ...DEFAULT_LIMITS };
  for (const r of rows || []) if (r.key in L && Number.isFinite(Number(r.value))) L[r.key] = Number(r.value);
  return L;
}

export function parseAmount(s) {
  const d = String(s ?? "").replace(/[^\d]/g, "");
  return d ? Number(d) : 0;
}
export function formatAmount(n) {
  return n > 0 ? Math.round(n).toLocaleString("en-US") : "";
}

export function allowedMethods(amount, L = DEFAULT_LIMITS) {
  if (!(amount > 0)) return ALL.slice();
  if (amount > L.mobile_bank_ceiling) return ["bank_transfer", "cheque"];
  if (amount > L.any_method_limit) return ["bank_transfer", "mobile_money"];
  return amount > L.petty_cash_limit ? ALL.filter((m) => m !== "petty_cash") : ALL.slice();
}

const fmt = (n) => "UGX " + Math.round(n).toLocaleString("en-US");
export function methodHint(amount, L = DEFAULT_LIMITS) {
  if (amount > L.mobile_bank_ceiling) return "Above " + fmt(L.mobile_bank_ceiling) + ": bank transfer or cheque only.";
  if (amount > L.any_method_limit) return "Above " + fmt(L.any_method_limit) + ": mobile money or bank transfer only.";
  return "";
}

export function deriveUrgency(dateRequired, today) {
  if (!dateRequired) return "normal";
  return dateRequired <= addDays(today, 1) ? "urgent" : "normal";
}

// Which payee details apply to the chosen method; returns { ok, lines[], missing }
export function payeeFor(sup, method) {
  if (!sup || !method) return { ok: false, lines: [], missing: "" };
  if (method === "bank_transfer") {
    const ok = Boolean(sup.bank_name && sup.account_no);
    return { ok, lines: ok ? [sup.bank_name + " · " + sup.account_no, sup.account_name || ""].filter(Boolean) : [],
      missing: ok ? "" : "This supplier has no bank details. Add them in Suppliers first." };
  }
  if (method === "mobile_money") {
    const ok = Boolean(sup.momo_number);
    return { ok, lines: ok ? [sup.momo_number, sup.momo_name || ""].filter(Boolean) : [],
      missing: ok ? "" : "This supplier has no mobile money number. Add it in Suppliers first." };
  }
  return { ok: true, lines: [METHODS[method] === "Cheque" ? "Payable to " + sup.name : "Paid from the cash float"], missing: "" };
}

// f: raw form values. ctx: { vbooks, rbooks, supplier, limits, deptName, scanReady, today }
export function validateCapture(f, ctx) {
  const e = {};
  const rb = ctx.rbooks.find((b) => b.id === f.requisition_book_id);
  const vb = ctx.vbooks.find((b) => b.id === f.voucher_book_id);
  if (!rb) e.requisition_book_id = "Choose the requisition book.";
  const rs = String(f.requisition_serial || "");
  if (!/^\d{1,3}$/.test(rs)) e.requisition_serial = "Enter the 3-digit requisition number.";
  else if (rb && (Number(rs) < rb.serial_from || Number(rs) > rb.serial_to))
    e.requisition_serial = "Must be between " + rb.serial_from + " and " + rb.serial_to + ".";
  if (!f.department_id) e.department_id = "Choose the department.";
  if (!vb) e.voucher_book_id = "Choose the voucher book.";
  const vn = String(f.voucher_no || "");
  if (!/^\d+$/.test(vn)) e.voucher_no = "Enter the voucher number.";
  else if (vb && (Number(vn) < vb.serial_from || Number(vn) > vb.serial_to))
    e.voucher_no = "Must be between " + vb.serial_from + " and " + vb.serial_to + ".";
  if (!ctx.supplier) e.supplier_id = "Choose a supplier from the list.";
  const amt = parseAmount(f.amount);
  if (!(amt > 0)) e.amount = "Enter the amount.";
  if (!f.method) e.method = "Choose how it will be paid.";
  else if (amt > 0 && !allowedMethods(amt, ctx.limits).includes(f.method))
    e.method = f.method === "petty_cash" ? "Petty cash is limited to " + fmt(ctx.limits.petty_cash_limit) + "."
      : methodHint(amt, ctx.limits) || "This method is not allowed for this amount.";
  else if (f.method === "petty_cash" && ctx.deptName === "Staff & Wages") e.method = "Salaries cannot be paid from petty cash.";
  else if (ctx.supplier) {
    const p = payeeFor(ctx.supplier, f.method);
    if (!p.ok && p.missing) e.method = p.missing;
  }
  if (!f.date_required) e.date_required = "Enter the date required.";
  if (!String(f.description || "").trim()) e.description = "Add a short description.";
  if (!ctx.scanReady) e.scan = "Attach a photo of the signed voucher.";
  return e;
}
