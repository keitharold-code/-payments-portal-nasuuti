import { getState } from "../lib/store.js";
import { roleLabels } from "../lib/roles.js";
import { esc } from "../lib/format.js";

// Step 1 placeholder. Dashboard cards arrive with the queue (step 5); no fake numbers here.
export function renderHome(root) {
  const s = getState();
  const labels = roleLabels(s.roles, "payments");
  root.innerHTML = `
    <h1 class="page-h">Home</h1>
    <div class="chips">${labels.map((l) => `<span class="chip">${esc(l)}</span>`).join("")}</div>
    <div class="notice">Signed in as ${esc(s.profile?.full_name || "")}. Payment screens are being built step by step.</div>`;
}
