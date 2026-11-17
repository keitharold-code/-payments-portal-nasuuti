import "./style.css";
import "./payments.css";
import { getState, subscribe } from "./lib/store.js";
import { init } from "./lib/session.js";
import { renderLogin } from "./pages/login.js";
import { mountApp } from "./app.js";
import { esc } from "./lib/format.js";
import { signOut } from "./lib/session.js";

const root = document.getElementById("app");
let last = "";

function render() {
  const s = getState();
  const key = [s.session?.user?.id, s.ready, s.loadError, s.siteId, s.roles.length, location.hash].join("|");
  if (key === last) return;
  last = key;

  if (!s.session) return renderLogin(root);
  if (!s.ready) { root.innerHTML = '<div class="loginwrap"><div class="notice">Loading…</div></div>'; return; }
  if (s.loadError) {
    root.innerHTML = `<div class="loginwrap"><div class="loginbox"><h1>Can't load your access</h1><p class="err">${esc(s.loadError)}</p><button class="btn" id="so">Sign out</button></div></div>`;
    root.querySelector("#so").addEventListener("click", signOut);
    return;
  }
  mountApp(root);
}

subscribe(render);
window.addEventListener("hashchange", render);
init().then(render);
