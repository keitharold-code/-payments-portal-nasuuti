import { getState } from "../lib/store.js";
import { esc, ugx, kampalaDate } from "../lib/format.js";
import * as api from "../lib/api.js";
import { toast, showError } from "../lib/ui.js";
import { METHODS, matches, needsConfirmation } from "../lib/suppliers.js";
import { DEFAULT_LIMITS, limitsFrom, parseAmount, formatAmount, allowedMethods, methodHint, deriveUrgency, payeeFor, validateCapture } from "../lib/capture.js";

const RB = { shop: "Shop", lubes: "Lubes", office: "Office" };
const VB = { shop: "Shop", petty_cash: "Petty Cash" };
const BOOK_DEPT = { shop: "Shop", lubes: "Lubricants", office: "Admin & Office" };
const pad = (n) => String(n).padStart(3, "0");
const DRAFT_KEY = "pay.capture.draft";
const DRAFT_FIELDS = ["requisition_book_id", "requisition_serial", "department_id", "requisition_date", "voucher_book_id", "amount", "method", "date_required", "description"];

export function renderCapture(root) {
  const site = getState().siteId;
  const today = kampalaDate();
  const S = { rbooks: [], vbooks: [], depts: [], suppliers: [], limits: { ...DEFAULT_LIMITS }, supplier: null,
              scan: { id: null, state: "none" }, reqScan: { id: null, state: "none" }, existingReq: null };

  root.innerHTML = `
    <h1 class="page-h">Capture payment</h1>
    <div id="cErr" class="notice err hidden" role="alert"></div>
    <div id="cBody"><div class="empty">Loading…</div></div>`;
  const $ = (s) => root.querySelector(s);

  async function load() {
    try {
      const [rbooks, vbooks, depts, suppliers, settings] = await Promise.all([
        api.listRequisitionBooks(site), api.listVoucherBooks(site), api.listDepartments(site), api.listSuppliers(site), api.listSettings(site)]);
      S.rbooks = rbooks.filter((b) => b.status === "active");
      S.vbooks = vbooks.filter((b) => b.status === "active");
      S.depts = depts; S.suppliers = suppliers.filter((x) => x.active); S.limits = limitsFrom(settings);
      if (!S.rbooks.length || !S.vbooks.length) {
        $("#cBody").innerHTML = `<div class="notice warn">Register an active ${!S.vbooks.length ? "voucher" : "requisition"} book first (Books screen).</div>`;
        return;
      }
      draw();
    } catch (e) { $("#cBody").innerHTML = ""; showError($("#cErr"), e.message); }
  }

  function draw() {
    $("#cBody").innerHTML = `
    <form id="cf" novalidate class="form-grid">
      <section class="block form-grid"><h2>1 · Requisition</h2>
        <div class="two">
          <label class="f">Book <select name="requisition_book_id">${S.rbooks.map((b) => `<option value="${b.id}">${RB[b.type]} ${pad(b.serial_from)}–${pad(b.serial_to)}</option>`).join("")}</select></label>
          <label class="f">Number <input name="requisition_serial" inputmode="numeric" maxlength="3" autocomplete="off"></label>
        </div>
        <p class="inline-err hidden" data-e="requisition_book_id"></p><p class="inline-err hidden" data-e="requisition_serial"></p>
        <div class="two">
          <label class="f">Department <select name="department_id"><option value="">Choose…</option>${S.depts.map((d) => `<option value="${d.id}">${esc(d.name)}</option>`).join("")}</select></label>
          <label class="f">Date raised <input type="date" name="requisition_date" max="${today}"></label>
        </div>
        <p class="inline-err hidden" data-e="department_id"></p><p class="hint" id="reqNote"></p>
        <label class="f check"><input type="checkbox" name="approved_by_manager" checked> Station Manager has signed the requisition</label>
        <div id="reqScanBox"></div>
      </section>

      <section class="block form-grid"><h2>2 · Voucher</h2>
        <div class="two">
          <label class="f">Book <select name="voucher_book_id">${S.vbooks.map((b) => `<option value="${b.id}">${VB[b.type]} ${pad(b.serial_from)}–${pad(b.serial_to)}</option>`).join("")}</select></label>
          <label class="f">Voucher number <input name="voucher_no" inputmode="numeric" autocomplete="off"></label>
        </div>
        <p class="inline-err hidden" data-e="voucher_book_id"></p><p class="inline-err hidden" data-e="voucher_no"></p>
      </section>

      <section class="block form-grid"><h2>3 · Payee and amount</h2>
        <div class="f" id="supBox">
          <label class="f">Supplier <input id="supQ" autocomplete="off" placeholder="Start typing the name…"></label>
          <div id="supPick" class="cards hidden" role="listbox"></div>
          <div id="supChosen" class="card hidden"></div>
        </div>
        <p class="inline-err hidden" data-e="supplier_id"></p>
        <label class="f">Amount (UGX) <input name="amount" inputmode="numeric" autocomplete="off" placeholder="0"></label>
        <p class="inline-err hidden" data-e="amount"></p>
        <label class="f">Pay by <select name="method"></select></label>
        <p class="hint" id="methodHint"></p><p class="inline-err hidden" data-e="method"></p>
        <div id="payee" class="notice hidden"></div>
      </section>

      <section class="block form-grid"><h2>4 · Details</h2>
        <div class="two">
          <label class="f">Date required <input type="date" name="date_required" value="${today}"></label>
          <div class="f"><span>Urgency</span><b id="urg" style="display:block;padding:10px 0"></b></div>
        </div>
        <p class="inline-err hidden" data-e="date_required"></p>
        <label class="f">What is it for? <textarea name="description" rows="2" maxlength="300" placeholder="e.g. 20 cartons soft drinks"></textarea></label>
        <p class="inline-err hidden" data-e="description"></p>
      </section>

      <section class="block form-grid"><h2>5 · Signed voucher</h2>
        <div id="scanBox"></div><p class="inline-err hidden" data-e="scan"></p>
      </section>

      <p id="fErr" class="inline-err hidden" role="alert"></p>
      <div class="actions"><button class="btn primary" type="submit" id="cSubmit" style="min-width:200px">Capture payment</button></div>
    </form>`;
    wire();
    restoreDraft();
    onBookChange(); syncMethods(); paintUrgency(); paintPayee(); renderScan("scan"); renderScan("reqScan");
  }

  const F = () => $("#cf");
  const val = (n) => F().elements[n]?.value ?? "";

  function raw() {
    const f = {};
    for (const el of F().elements) if (el.name) f[el.name] = el.type === "checkbox" ? el.checked : el.value;
    return f;
  }
  function saveDraft() {
    try { const f = raw(), d = {}; DRAFT_FIELDS.forEach((k) => { d[k] = f[k]; }); localStorage.setItem(DRAFT_KEY, JSON.stringify(d)); } catch (_) {}
  }
  function restoreDraft() {
    try {
      const d = JSON.parse(localStorage.getItem(DRAFT_KEY) || "null"); if (!d) return;
      DRAFT_FIELDS.forEach((k) => { const el = F().elements[k]; if (el && d[k] != null && d[k] !== "") el.value = d[k]; });
    } catch (_) {}
  }
  const clearDraft = () => { try { localStorage.removeItem(DRAFT_KEY); } catch (_) {} };

  let currentErrors = {};
  function setErrors(errs) {
    currentErrors = errs;
    root.querySelectorAll("[data-e]").forEach((p) => {
      const m = errs[p.dataset.e]; p.textContent = m || ""; p.classList.toggle("hidden", !m);
    });
  }

  // ----- requisition book / department / next voucher number -----
  function onBookChange() {
    const rb = S.rbooks.find((b) => b.id === val("requisition_book_id"));
    const want = rb && BOOK_DEPT[rb.type];
    const dep = S.depts.find((d) => d.name === want);
    if (dep && !S.existingReq && !val("department_id")) F().elements.department_id.value = dep.id;
    const vb = S.vbooks.find((b) => b.id === val("voucher_book_id"));
    if (vb && vb.next_no && !val("voucher_no")) F().elements.voucher_no.value = vb.next_no;
  }
  async function lookupRequisition() {
    S.existingReq = null; $("#reqNote").textContent = ""; F().elements.department_id.disabled = false;
    const n = val("requisition_serial");
    if (!/^\d{1,3}$/.test(n)) return;
    try {
      const r = await api.findRequisition(val("requisition_book_id"), Number(n));
      if (r) {
        S.existingReq = r; F().elements.department_id.value = r.department_id; F().elements.department_id.disabled = true;
        $("#reqNote").textContent = "This requisition is already recorded. Adding another payment to it.";
      }
    } catch (_) { /* the server re-checks everything */ }
  }

  // ----- supplier type-ahead -----
  function paintSupplier() {
    const box = $("#supChosen"), q = $("#supQ");
    if (S.supplier) {
      const s = S.supplier;
      box.innerHTML = `<div class="row"><span class="t">${esc(s.name)}</span><button type="button" class="linklike" id="supClear">Change</button></div>
        ${needsConfirmation(s) ? '<div class="s"><span class="badge amber">Bank details awaiting confirmation</span></div>' : ""}`;
      box.classList.remove("hidden"); q.parentElement.classList.add("hidden"); $("#supPick").classList.add("hidden");
      $("#supClear").addEventListener("click", () => { S.supplier = null; q.value = ""; paintSupplier(); syncMethods(); paintPayee(); q.focus(); });
    } else { box.classList.add("hidden"); q.parentElement.classList.remove("hidden"); }
  }
  function onSupplierInput() {
    const q = $("#supQ").value, pick = $("#supPick");
    if (!q.trim()) { pick.classList.add("hidden"); return; }
    const rows = S.suppliers.filter((s) => matches(s, q)).slice(0, 8);
    pick.innerHTML = rows.length
      ? rows.map((s) => `<button type="button" class="card" role="option" data-id="${s.id}"><span class="t">${esc(s.name)}</span></button>`).join("")
      : '<div class="empty">No match. Add the supplier in Suppliers first.</div>';
    pick.classList.remove("hidden");
    pick.querySelectorAll("button").forEach((b) => b.addEventListener("click", () => {
      S.supplier = S.suppliers.find((s) => s.id === b.dataset.id);
      const dm = S.supplier.default_method;
      if (dm && allowedMethods(parseAmount(val("amount")), S.limits).includes(dm)) F().elements.method.value = dm;
      paintSupplier(); syncMethods(); paintPayee();
    }));
  }

  // ----- amount -> allowed methods, payee panel, urgency -----
  function syncMethods() {
    const amt = parseAmount(val("amount")), sel = F().elements.method, keep = sel.value;
    const ok = allowedMethods(amt, S.limits);
    sel.innerHTML = '<option value="">Choose…</option>' + ["bank_transfer", "mobile_money", "cheque", "petty_cash"]
      .map((m) => `<option value="${m}" ${ok.includes(m) ? "" : "disabled"}>${METHODS[m]}</option>`).join("");
    sel.value = ok.includes(keep) ? keep : (S.supplier && ok.includes(S.supplier.default_method) ? S.supplier.default_method : "");
    $("#methodHint").textContent = methodHint(amt, S.limits);
    paintPayee();
  }
  function paintPayee() {
    const box = $("#payee"), m = val("method");
    if (!S.supplier || !m) { box.classList.add("hidden"); return; }
    const p = payeeFor(S.supplier, m);
    box.className = "notice " + (p.ok ? "" : "err");
    box.innerHTML = p.ok ? `<b>Pay to</b><br>${p.lines.map(esc).join("<br>")}` : esc(p.missing);
  }
  function paintUrgency() {
    const u = deriveUrgency(val("date_required"), today);
    const el = $("#urg"); el.textContent = u === "urgent" ? "Urgent" : "Normal"; el.style.color = u === "urgent" ? "var(--signal)" : "inherit";
  }

  // ----- scans -----
  function renderScan(which) {
    const st = S[which], box = $(which === "scan" ? "#scanBox" : "#reqScanBox"), label = which === "scan" ? "Take photo of signed voucher" : "Add photo of requisition (optional)";
    const status = { none: "", prep: "Preparing photo…", up: "Uploading…", done: "Photo attached ✓", fail: st.error || "Upload failed." }[st.state] ?? "";
    box.innerHTML = `
      <div class="actions"><label class="btn ${which === "scan" ? "yellow" : ""}" style="cursor:pointer">${st.state === "done" ? "Retake photo" : label}
        <input type="file" accept="image/*" capture="environment" hidden data-scan="${which}"></label>
        <span class="s ${st.state === "fail" ? "inline-err" : ""}" role="status">${esc(status)}</span></div>
      ${st.preview ? `<img src="${st.preview}" alt="Photo preview" style="max-width:100%;max-height:220px;margin-top:8px;border-radius:8px;border:1px solid var(--line)">` : ""}`;
    box.querySelector("input").addEventListener("change", (e) => pickFile(which, e.target.files[0]));
  }
  async function pickFile(which, file) {
    if (!file) return;
    const st = S[which]; st.id = null; st.error = ""; st.state = "prep";
    if (st.preview) URL.revokeObjectURL(st.preview);
    st.preview = file.type.startsWith("image/") ? URL.createObjectURL(file) : "";
    renderScan(which);
    try {
      const rec = await api.uploadFile(site, which === "scan" ? "voucher" : "requisition", file, (m) => { st.state = m.startsWith("Prep") ? "prep" : "up"; renderScan(which); });
      st.id = rec.id; st.state = "done";
      if (which === "scan") setErrors({ ...currentErrors, scan: "" });
    } catch (e) { st.state = "fail"; st.error = e.message; }
    renderScan(which);
  }

  // ----- submit -----
  async function submit(ev) {
    ev.preventDefault();
    const f = raw(); f.department_id = val("department_id");
    const dept = S.depts.find((d) => d.id === f.department_id);
    const errs = validateCapture(f, { rbooks: S.rbooks, vbooks: S.vbooks, supplier: S.supplier, limits: S.limits, deptName: dept?.name, scanReady: Boolean(S.scan.id) });
    setErrors(errs);
    const first = Object.keys(errs)[0];
    if (first) {
      showError($("#fErr"), "Fix the highlighted fields.");
      root.querySelector(`[data-e="${first}"]`)?.scrollIntoView({ block: "center", behavior: "smooth" });
      return;
    }
    showError($("#fErr"), "");
    const btn = $("#cSubmit"); btn.disabled = true; btn.textContent = "Capturing…";
    try {
      const r = await api.capturePayment({
        site_id: site, requisition_book_id: f.requisition_book_id, requisition_serial: Number(f.requisition_serial),
        department_id: f.department_id, requisition_date: f.requisition_date || "", approved_by_manager: Boolean(f.approved_by_manager),
        requisition_scan_file_id: S.reqScan.id || "", voucher_book_id: f.voucher_book_id, voucher_no: Number(f.voucher_no),
        supplier_id: S.supplier.id, description: f.description, amount_ugx: parseAmount(f.amount), method: f.method,
        date_required: f.date_required, voucher_scan_file_id: S.scan.id });
      clearDraft(); done(r);
    } catch (e) { showError($("#fErr"), e.message); btn.disabled = false; btn.textContent = "Capture payment"; }
  }

  function done(r) {
    $("#cBody").innerHTML = `
      <div class="card" style="border-top:4px solid var(--go)">
        <div class="s">Captured</div>
        <div class="t" style="font-size:30px">${esc(r.pay_no)}</div>
        <div class="s">${esc(S.supplier.name)} · UGX ${ugx(r.amount_ugx)} · ${esc(METHODS[r.method])}</div>
        <p>Director 1 will verify it next. Quote <b>${esc(r.pay_no)}</b> in the bank or mobile money narration, or write it on the cash slip, when it is paid.</p>
        ${(r.flags || []).length ? `<p class="hint">Warnings for Director 1: ${esc(r.flags.join(", "))}</p>` : ""}
        <div class="actions"><button class="btn yellow" id="again">Capture another</button></div>
      </div>`;
    $("#again").addEventListener("click", () => { S.supplier = null; S.scan = { id: null, state: "none" }; S.reqScan = { id: null, state: "none" }; load(); });
  }

  function wire() {
    const f = F();
    f.addEventListener("submit", submit);
    f.addEventListener("input", (e) => {
      if (e.target.name === "amount") { const n = parseAmount(e.target.value); e.target.value = formatAmount(n); syncMethods(); }
      if (e.target.name === "date_required") paintUrgency();
      if (e.target.name === "method") paintPayee();
      if (e.target.id === "supQ") onSupplierInput();
      saveDraft();
    });
    f.elements.requisition_book_id.addEventListener("change", () => { f.elements.department_id.value = ""; lookupRequisition().then(onBookChange); });
    f.elements.requisition_serial.addEventListener("blur", lookupRequisition);
    f.elements.voucher_book_id.addEventListener("change", () => { f.elements.voucher_no.value = ""; onBookChange(); });
  }

  load();
}
