import { getState } from "../lib/store.js";
import { hasAnyAt } from "../lib/roles.js";
import { esc, dmy, dmyTime, kampalaDate } from "../lib/format.js";
import * as api from "../lib/api.js";
import { openSheet, formData, showError, toast } from "../lib/ui.js";

const VB = { shop: "Shop", petty_cash: "Petty Cash" };
const RB = { shop: "Shop", lubes: "Lubes", office: "Office" };
const pad = (n) => String(n).padStart(3, "0");

export function renderBooks(root) {
  const s = getState();
  const site = s.siteId;
  const canEdit = hasAnyAt(s.roles, "payments", site, ["cashier", "admin"]);
  let vbooks = [], rbooks = [], cancelled = [];

  root.innerHTML = `
    <h1 class="page-h">Books</h1>
    <div id="bErr" class="notice err hidden" role="alert"></div>
    <div class="sec-h"><h2>Voucher books</h2>${canEdit ? '<button class="btn yellow" id="addV">Register book</button>' : ""}</div>
    <div class="cards" id="vList"><div class="empty">Loading…</div></div>
    <div class="sec-h"><h2>Requisition books</h2>${canEdit ? '<button class="btn" id="addR">Register book</button>' : ""}</div>
    <div class="cards" id="rList"></div>
    <div class="sec-h"><h2>Cancelled vouchers</h2>${canEdit ? '<button class="btn" id="addC">Log cancelled</button>' : ""}</div>
    <div class="cards" id="cList"></div>`;
  const $ = (x) => root.querySelector(x);

  function paint() {
    $("#vList").innerHTML = vbooks.length ? vbooks.map((b) => `
      <div class="card">
        <div class="row"><span class="t">${VB[b.type]} book ${pad(b.serial_from)}–${pad(b.serial_to)}</span>
          <span class="badge ${b.status === "active" ? "green" : ""}">${b.status === "active" ? "Active" : "Closed"}</span></div>
        <div class="s">Issued ${dmy(b.issued_on)} · used ${b.used_count} of ${b.serial_to - b.serial_from + 1}
          ${b.status === "active" ? (b.next_no ? " · next number <b>" + b.next_no + "</b>" : " · <b>book full</b>") : ""}</div>
        ${canEdit && b.status === "active" ? `<div class="actions" style="margin-top:8px"><button class="btn" data-close="voucher" data-id="${b.id}">Close book</button></div>` : ""}
      </div>`).join("") : '<div class="empty">No voucher books yet. Register the one the cashier is writing in.</div>';
    $("#rList").innerHTML = rbooks.length ? rbooks.map((b) => `
      <div class="card">
        <div class="row"><span class="t">${RB[b.type]} requisitions ${pad(b.serial_from)}–${pad(b.serial_to)}</span>
          <span class="badge ${b.status === "active" ? "green" : ""}">${b.status === "active" ? "Active" : "Closed"}</span></div>
        <div class="s">Issued ${dmy(b.issued_on)}</div>
        ${canEdit && b.status === "active" ? `<div class="actions" style="margin-top:8px"><button class="btn" data-close="requisition" data-id="${b.id}">Close book</button></div>` : ""}
      </div>`).join("") : '<div class="empty">No requisition books yet.</div>';
    $("#cList").innerHTML = cancelled.length ? cancelled.map((c) => `
      <div class="card"><div class="row"><span class="t">${VB[c.voucher_books?.type] || ""} voucher ${c.voucher_no}</span>
        <span class="s">${dmyTime(c.at)}</span></div><div class="s">${esc(c.reason)}</div></div>`).join("") : '<div class="empty">None logged.</div>';
    root.querySelectorAll("[data-close]").forEach((b) => b.addEventListener("click", async () => {
      if (!confirm("Close this book? New vouchers can no longer be written from it in the portal.")) return;
      try { await api.closeBook(b.dataset.close, b.dataset.id); toast("Book closed."); load(); }
      catch (e) { showError($("#bErr"), e.message); }
    }));
  }

  async function load() {
    try {
      showError($("#bErr"), "");
      [vbooks, rbooks, cancelled] = await Promise.all([api.listVoucherBooks(site), api.listRequisitionBooks(site), api.listCancelled(site)]);
      paint();
    } catch (e) { $("#vList").innerHTML = ""; showError($("#bErr"), e.message); }
  }

  function bookForm(title, types, submit) {
    openSheet(title, `
      <form id="bf" class="form-grid">
        <label class="f">Type <select name="type">${Object.entries(types).map(([k, l]) => `<option value="${k}">${l}</option>`).join("")}</select></label>
        <div class="two">
          <label class="f">First number <input name="serial_from" type="number" inputmode="numeric" min="0" required></label>
          <label class="f">Last number <input name="serial_to" type="number" inputmode="numeric" min="0" required></label>
        </div>
        <label class="f">Date issued <input name="issued_on" type="date" value="${kampalaDate()}" required></label>
        <p id="bfErr" class="inline-err hidden" role="alert"></p>
        <div class="actions"><button class="btn primary" type="submit">Register</button></div>
      </form>`, (el, close) => {
      const err = el.querySelector("#bfErr");
      el.querySelector("#bf").addEventListener("submit", async (ev) => {
        ev.preventDefault();
        const d = formData(ev.target);
        const from = Number(d.serial_from), to = Number(d.serial_to);
        if (!(to >= from)) { showError(err, "Last number must be the same as or after the first."); return; }
        try { await submit({ site_id: site, type: d.type, serial_from: from, serial_to: to, issued_on: d.issued_on }); toast("Book registered."); close(); load(); }
        catch (e) { showError(err, e.message); }
      });
    });
  }

  $("#addV")?.addEventListener("click", () => bookForm("Register voucher book", VB, api.registerVoucherBook));
  $("#addR")?.addEventListener("click", () => bookForm("Register requisition book", RB, api.registerRequisitionBook));
  $("#addC")?.addEventListener("click", () => {
    openSheet("Log cancelled voucher", `
      <form id="cf" class="form-grid">
        <label class="f">Book <select name="book">${vbooks.map((b) => `<option value="${b.id}">${VB[b.type]} ${pad(b.serial_from)}–${pad(b.serial_to)}${b.status === "closed" ? " (closed)" : ""}</option>`).join("")}</select></label>
        <label class="f">Voucher number <input name="no" type="number" inputmode="numeric" required></label>
        <label class="f">Reason <input name="reason" placeholder="e.g. Spoilt, wrong amount written" required></label>
        <p id="cfErr" class="inline-err hidden" role="alert"></p>
        <div class="actions"><button class="btn primary" type="submit">Log it</button></div>
      </form>`, (el, close) => {
      const err = el.querySelector("#cfErr");
      el.querySelector("#cf").addEventListener("submit", async (ev) => {
        ev.preventDefault();
        const d = formData(ev.target);
        try { await api.logCancelledVoucher(d.book, Number(d.no), d.reason); toast("Logged."); close(); load(); }
        catch (e) { showError(err, e.message); }
      });
    });
  });

  load();
}
