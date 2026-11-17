import { esc } from "../lib/format.js";
import { getState } from "../lib/store.js";
import { rolesFor } from "../lib/roles.js";

const SALES_URL = import.meta.env.VITE_SALES_PORTAL_URL || "";

export function renderLauncher(root) {
  const s = getState();
  const canPay = rolesFor(s.roles, "payments").length > 0;
  const sales = SALES_URL
    ? `<a class="tile" href="${esc(SALES_URL)}"><h2>Daily Sales &amp; Gross Profit</h2><p>Fuel, shop, lubes and LPG sales.</p></a>`
    : `<div class="tile off"><h2>Daily Sales &amp; Gross Profit</h2><p>Link not set yet (VITE_SALES_PORTAL_URL).</p></div>`;
  const pay = canPay
    ? `<a class="tile" href="#/payments/home"><h2>Payments Portal</h2><p>Vouchers, approvals, payment queue.</p></a>`
    : `<div class="tile off"><h2>Payments Portal</h2><p>No access on this account. Ask Keith.</p></div>`;
  root.innerHTML = `<h1 class="page-h">Choose a portal</h1><div class="tiles">${sales}${pay}</div>`;
}
