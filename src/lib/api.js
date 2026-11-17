// Thin data layer. Reads use RLS-filtered views/tables; every write is an RPC (database enforces the rules).
import { supabase } from "./supabase.js";

const pay = () => supabase.schema("payments");

function friendly(e) {
  if (e.code === "PGRST202") return "The server is not up to date. Ask Keith to apply the latest database migration.";
  if (e.code === "PGRST106" || /schema must be one of/i.test(e.message || ""))
    return "The payments schema is not exposed yet (Supabase Settings, API, Exposed schemas).";
  if (e.code === "42501" && /permission denied/i.test(e.message || "")) return "You do not have access to this.";
  return e.message || "Something went wrong.";
}
async function rpc(name, args) {
  const { data, error } = await pay().rpc(name, args);
  if (error) throw new Error(friendly(error));
  return data;
}
async function read(q) {
  const { data, error } = await q;
  if (error) throw new Error(friendly(error));
  return data || [];
}

export const listSuppliers = (site) =>
  read(pay().from("suppliers")
    .select("id, name, aliases, default_method, bank_name, account_name, account_no, momo_number, momo_name, tin, phone, active, details_changed_at, details_verified_at")
    .eq("site_id", site).order("name"));
export const saveSupplier = (p) => rpc("save_supplier", { p });
export const confirmSupplierDetails = (id) => rpc("confirm_supplier_details", { _id: id });
export const mergeSuppliers = (from, into) => rpc("merge_suppliers", { _from: from, _into: into });

export const listVoucherBooks = (site) =>
  read(pay().from("voucher_book_usage").select("*").eq("site_id", site).order("issued_on", { ascending: false }).order("serial_from", { ascending: false }));
export const listRequisitionBooks = (site) =>
  read(pay().from("requisition_books").select("id, type, serial_from, serial_to, issued_on, status")
    .eq("site_id", site).order("issued_on", { ascending: false }));
export const listCancelled = (site) =>
  read(pay().from("cancelled_vouchers").select("id, voucher_no, reason, at, voucher_books(type, serial_from)")
    .eq("site_id", site).order("at", { ascending: false }).limit(30));
export const registerVoucherBook = (p) => rpc("register_voucher_book", { p });
export const registerRequisitionBook = (p) => rpc("register_requisition_book", { p });
export const closeBook = (kind, id) => rpc("close_book", { _kind: kind, _id: id });
export const logCancelledVoucher = (book, no, reason) => rpc("log_cancelled_voucher", { _book: book, _no: no, _reason: reason });
