// Small UI helpers: bottom sheet (native <dialog>), toast re-export.
import { esc } from "./format.js";
export { toast } from "./toast.js";

// openSheet("Title", html, (el, close) => { wire up events }) -> { el, close }
export function openSheet(title, html, onMount) {
  const d = document.createElement("dialog");
  d.className = "sheet";
  d.innerHTML = `<div class="sheet-h"><h2>${esc(title)}</h2><button class="sheet-x" type="button" aria-label="Close">✕</button></div>
    <div class="sheet-b">${html}</div>`;
  document.body.appendChild(d);
  const close = () => { try { d.close(); } catch (_) {} d.remove(); };
  d.querySelector(".sheet-x").addEventListener("click", close);
  d.addEventListener("click", (e) => { if (e.target === d) close(); });
  d.addEventListener("cancel", (e) => { e.preventDefault(); close(); });
  if (typeof d.showModal === "function") d.showModal(); else d.setAttribute("open", "");
  onMount?.(d, close);
  return { el: d, close };
}

export function formData(form) {
  const o = {};
  new FormData(form).forEach((v, k) => { o[k] = v; });
  form.querySelectorAll("input[type=checkbox]").forEach((c) => { o[c.name] = c.checked; });
  return o;
}

export function showError(el, msg) {
  el.textContent = msg || "";
  el.classList.toggle("hidden", !msg);
}
