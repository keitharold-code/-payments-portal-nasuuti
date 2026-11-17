// Thin data layer. Reads use RLS-filtered views/tables; every write is an RPC (database enforces the rules).
import { supabase } from "./supabase.js";
import { compressImage, sha256Hex, uuid } from "./image.js";

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

// ---- capture ----

export const listDepartments = (site) =>
  read(supabase.schema("core").from("departments").select("id, name, default_category").eq("site_id", site).eq("active", true).order("name"));
export const listSettings = (site) => read(pay().from("settings").select("key, value").eq("site_id", site));
export const findRequisition = async (bookId, serial) => {
  const rows = await read(pay().from("requisitions").select("id, department_id, approved_by_manager").eq("book_id", bookId).eq("serial_no", serial).limit(1));
  return rows[0] || null;
};
export const capturePayment = (p) => rpc("capture_payment", { p });

// Shrink, upload to the private bucket, register with the server. Returns the files row (has .id).
export async function uploadFile(site, kind, file, onStage) {
  onStage?.("Preparing photo…");
  const blob = await compressImage(file);
  const sha = await sha256Hex(blob);
  const ext = blob.type === "application/pdf" ? "pdf" : "jpg";
  const path = site + "/" + new Date().getUTCFullYear() + "/" + kind + "/" + uuid() + "." + ext;
  onStage?.("Uploading…");
  const up = await supabase.storage.from("payments-files").upload(path, blob, { contentType: blob.type, upsert: false });
  if (up.error) throw new Error(up.error.message || "Upload failed. Check your connection and try again.");
  return rpc("register_file", { _site: site, _path: path, _kind: kind, _sha256: sha });
}
export async function signedUrl(path) {
  const { data, error } = await supabase.storage.from("payments-files").createSignedUrl(path, 60);
  if (error) throw new Error(error.message);
  return data.signedUrl;
}
