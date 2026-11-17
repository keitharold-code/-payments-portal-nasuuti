import { getState } from "../lib/store.js";
import { hasAnyAt } from "../lib/roles.js";
import { esc, dmyTime } from "../lib/format.js";
import * as api from "../lib/api.js";
import { openSheet, formData, showError, toast } from "../lib/ui.js";
import { METHODS, needsConfirmation, payeeSummary, matches, findDuplicate, toPayload, validateSupplier } from "../lib/suppliers.js";

export function renderSuppliers(root) {
  const s = getState();
  const site = s.siteId;
  const canEdit = hasAnyAt(s.roles, "payments", site, ["cashier", "admin"]);
  const canConfirm = hasAnyAt(s.roles, "payments", site, ["d1", "admin"]);
  const canMerge = hasAnyAt(s.roles, "payments", site, ["admin"]);
  let list = [], q = "", filter = "all";

  root.innerHTML = `
    <h1 class="page-h">Suppliers</h1>
    <div id="sErr" class="notice err hidden" role="alert"></div>
    <div class="toolbar">
      <input type="search" id="sq" placeholder="Search name, phone, account…" aria-label="Search suppliers">
      ${canEdit ? '<button class="btn yellow" id="sAdd">Add supplier</button>' : ""}
    </div>
    <div class="seg" id="sSeg">
      <button data-f="all" aria-pressed="true">All</button>
      <button data-f="confirm" aria-pressed="false">Needs confirmation <span id="nConf"></span></button>
      <button data-f="inactive" aria-pressed="false">Inactive</button>
    </div>
    <div class="cards" id="sList"><div class="empty">Loading…</div></div>`;

  const $ = (sel) => root.querySelector(sel);

  function paint() {
    const nConf = list.filter((x) => x.active && needsConfirmation(x)).length;
    $("#nConf").textContent = nConf ? "(" + nConf + ")" : "";
    const rows = list.filter((x) => matches(x, q) &&
      (filter === "all" ? x.active : filter === "inactive" ? !x.active : x.active && needsConfirmation(x)));
    $("#sList").innerHTML = rows.length ? rows.map((x) => `
      <button class="card" data-id="${x.id}">
        <div class="row"><span class="t">${esc(x.name)}</span>
          <span>${needsConfirmation(x) ? '<span class="badge amber">Needs confirmation</span>' : ""}${x.active ? "" : '<span class="badge red">Inactive</span>'}</span></div>
        <div class="s">${esc(x.default_method ? METHODS[x.default_method] : "No default method")}${payeeSummary(x) ? " · " + esc(payeeSummary(x)) : ""}</div>
        ${x.aliases?.length ? `<div class="s">Also: ${esc(x.aliases.join(", "))}</div>` : ""}
      </button>`).join("") : `<div class="empty">${list.length ? "No suppliers match." : "No suppliers yet."}</div>`;
    $("#sList").querySelectorAll(".card").forEach((b) => b.addEventListener("click", () => detail(list.find((x) => x.id === b.dataset.id))));
  }

  async function load() {
    try { showError($("#sErr"), ""); list = await api.listSuppliers(site); paint(); }
    catch (e) { $("#sList").innerHTML = ""; showError($("#sErr"), e.message); }
  }

  $("#sq").addEventListener("input", (e) => { q = e.target.value; paint(); });
  $("#sSeg").querySelectorAll("button").forEach((b) => b.addEventListener("click", () => {
    filter = b.dataset.f;
    $("#sSeg").querySelectorAll("button").forEach((x) => x.setAttribute("aria-pressed", String(x === b)));
    paint();
  }));
  $("#sAdd")?.addEventListener("click", () => form(null));

  function detail(x) {
    const rows = [
      ["Default method", x.default_method ? METHODS[x.default_method] : "—"],
      ["Bank", [x.bank_name, x.account_name, x.account_no].filter(Boolean).join(" · ") || "—"],
      ["Mobile money", [x.momo_number, x.momo_name].filter(Boolean).join(" · ") || "—"],
      ["TIN", x.tin || "—"], ["Phone", x.phone || "—"],
      ["Details changed", x.details_changed_at ? dmyTime(x.details_changed_at) : "—"],
      ["Details confirmed", x.details_verified_at ? dmyTime(x.details_verified_at) : "—"],
    ];
    const conf = needsConfirmation(x);
    openSheet(x.name, `
      ${conf ? '<div class="notice warn">Bank or mobile money details changed and are not confirmed. No payment to this supplier can be released until Director 1 confirms.</div>' : ""}
      ${rows.map(([k, v]) => `<div class="kv"><span>${esc(k)}</span><b>${esc(v)}</b></div>`).join("")}
      ${x.aliases?.length ? `<div class="kv"><span>Also known as</span><b>${esc(x.aliases.join(", "))}</b></div>` : ""}
      <p id="dErr" class="inline-err hidden" role="alert"></p>
      <div class="actions" style="margin-top:14px">
        ${canEdit ? '<button class="btn" id="dEdit">Edit</button>' : ""}
        ${canConfirm && conf ? '<button class="btn yellow" id="dConf">Confirm details</button>' : ""}
        ${canMerge && x.active ? '<button class="btn danger" id="dMerge">Merge into…</button>' : ""}
      </div>`, (el, close) => {
      const err = el.querySelector("#dErr");
      el.querySelector("#dEdit")?.addEventListener("click", () => { close(); form(x); });
      el.querySelector("#dConf")?.addEventListener("click", async (ev) => {
        ev.target.disabled = true;
        try { await api.confirmSupplierDetails(x.id); toast("Details confirmed."); close(); load(); }
        catch (e) { showError(err, e.message); ev.target.disabled = false; }
      });
      el.querySelector("#dMerge")?.addEventListener("click", () => { close(); merge(x); });
    });
  }

  function form(x) {
    const v = x || { active: true, aliases: [] };
    const val = (k) => esc(v[k] ?? "");
    openSheet(x ? "Edit supplier" : "Add supplier", `
      <form id="sf" class="form-grid" novalidate>
        <label class="f">Name <input name="name" value="${val("name")}" autocomplete="off" required></label>
        <p id="dup" class="inline-err hidden"></p>
        <label class="f">Also known as (comma separated) <input name="aliases" value="${esc((v.aliases || []).join(", "))}"></label>
        <label class="f">Usual payment method
          <select name="default_method"><option value="">—</option>
            ${Object.entries(METHODS).map(([k, l]) => `<option value="${k}" ${v.default_method === k ? "selected" : ""}>${l}</option>`).join("")}
          </select></label>
        <fieldset><legend>Bank</legend><div class="form-grid">
          <label class="f">Bank name <input name="bank_name" value="${val("bank_name")}"></label>
          <div class="two">
            <label class="f">Account name <input name="account_name" value="${val("account_name")}"></label>
            <label class="f">Account number <input name="account_no" inputmode="numeric" value="${val("account_no")}"></label>
          </div></div></fieldset>
        <fieldset><legend>Mobile money</legend><div class="two">
          <label class="f">Number <input name="momo_number" inputmode="tel" value="${val("momo_number")}"></label>
          <label class="f">Registered name <input name="momo_name" value="${val("momo_name")}"></label>
        </div></fieldset>
        <div class="two">
          <label class="f">TIN <input name="tin" value="${val("tin")}"></label>
          <label class="f">Phone <input name="phone" inputmode="tel" value="${val("phone")}"></label>
        </div>
        ${x ? `<label class="f check"><input type="checkbox" name="active" ${v.active ? "checked" : ""}> Active</label>` : ""}
        <p class="hint">Changing bank or mobile money details needs Director 1 to confirm them before any payment can be released.</p>
        <p id="fErr" class="inline-err hidden" role="alert"></p>
        <div class="actions"><button class="btn primary" type="submit" id="fSave">Save</button></div>
      </form>`, (el, close) => {
      const f = el.querySelector("#sf"), err = el.querySelector("#fErr"), dup = el.querySelector("#dup"), save = el.querySelector("#fSave");
      const check = () => {
        const d = findDuplicate(list, f.name.value, x?.id);
        showError(dup, d ? "“" + d.name + "” already exists." : "");
        save.disabled = Boolean(d);
      };
      f.name.addEventListener("input", check);
      f.addEventListener("submit", async (ev) => {
        ev.preventDefault();
        const data = formData(f);
        const errs = validateSupplier(data);
        if (errs.length) { showError(err, errs.join(" ")); return; }
        save.disabled = true; save.textContent = "Saving…";
        try {
          await api.saveSupplier(toPayload(data, site, x?.id));
          toast(x ? "Supplier updated." : "Supplier added."); close(); load();
        } catch (e) { showError(err, e.message); save.disabled = false; save.textContent = "Save"; }
      });
    });
  }

  function merge(x) {
    const targets = list.filter((t) => t.active && t.id !== x.id);
    openSheet("Merge supplier", `
      <p>All payments and petty cash entries for <b>${esc(x.name)}</b> move to the supplier you choose. The old name is kept as an alias. This cannot be undone.</p>
      <form id="mf" class="form-grid">
        <label class="f">Merge into
          <select name="into" required><option value="">Choose…</option>${targets.map((t) => `<option value="${t.id}">${esc(t.name)}</option>`).join("")}</select></label>
        <p id="mErr" class="inline-err hidden" role="alert"></p>
        <div class="actions"><button class="btn danger" type="submit">Merge</button></div>
      </form>`, (el, close) => {
      const err = el.querySelector("#mErr");
      el.querySelector("#mf").addEventListener("submit", async (ev) => {
        ev.preventDefault();
        const into = ev.target.into.value;
        if (!into) { showError(err, "Choose a supplier."); return; }
        const t = list.find((z) => z.id === into);
        if (!confirm("Merge “" + x.name + "” into “" + t.name + "”?")) return;
        try { await api.mergeSuppliers(x.id, into); toast("Merged."); close(); load(); }
        catch (e) { showError(err, e.message); }
      });
    });
  }

  load();
}
