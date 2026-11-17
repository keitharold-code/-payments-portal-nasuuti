import { getState } from "./lib/store.js";
import { signOut } from "./lib/session.js";
import { register, allRoutes, path, renderRoute } from "./lib/router.js";
import { rolesFor } from "./lib/roles.js";
import { esc } from "./lib/format.js";
import { renderLauncher } from "./pages/launcher.js";
import { renderHome } from "./pages/home.js";
import { renderSuppliers } from "./pages/suppliers.js";
import { renderBooks } from "./pages/books.js";

// Each module registers its own routes. Roles are payments roles; omit `roles` = any signed-in user.
register({ path: "/launcher", render: renderLauncher });
register({ path: "/payments/home", title: "Home", nav: true, payments: true, render: renderHome });
register({ path: "/payments/suppliers", title: "Suppliers", nav: true, payments: true, render: renderSuppliers });
register({ path: "/payments/books", title: "Books", nav: true, payments: true, render: renderBooks });

function visible(r) {
  if (!r.payments) return true;
  const mine = rolesFor(getState().roles, "payments");
  if (!mine.length) return false;
  return !r.roles || r.roles.some((x) => mine.includes(x));
}

export function mountApp(root) {
  const s = getState();
  const p = path();
  const route = allRoutes().find((r) => r.path === p);
  const navRoutes = allRoutes().filter((r) => r.nav && visible(r));
  const blocked = route && !visible(route);

  const navBtn = (r) => `<button role="tab" data-go="${r.path}" aria-selected="${r.path === p}">${esc(r.title)}</button>`;
  root.innerHTML = `
    <header class="bar"><div class="bar-in">
      <div class="brand">
        <h1 class="wordmark"><a href="#/launcher" style="color:inherit;text-decoration:none">Shell Nasuuti — Payments</a></h1>
        <p class="who">${esc(s.profile?.full_name || "")}</p>
      </div>
      <nav class="tabs" role="tablist">${navRoutes.map(navBtn).join("")}<button class="signout" id="signout">Sign out</button></nav>
    </div></header>
    <main id="view"></main>
    <nav class="bottomnav" role="tablist">${navRoutes.map(navBtn).join("")}<button id="signout2">Sign out</button></nav>`;

  root.querySelectorAll("[data-go]").forEach((b) => b.addEventListener("click", () => (location.hash = "#" + b.dataset.go)));
  root.querySelector("#signout").addEventListener("click", signOut);
  root.querySelector("#signout2").addEventListener("click", signOut);

  const view = root.querySelector("#view");
  if (blocked) view.innerHTML = '<div class="notice err">You do not have access to this screen.</div>';
  else renderRoute(view, {});
}
