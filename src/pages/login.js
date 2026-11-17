import { signIn, signInGoogle } from "../lib/session.js";
import { supabaseConfigured } from "../lib/supabase.js";

export function renderLogin(root) {
  root.innerHTML = `
    <div class="loginwrap">
      <div class="loginbox">
        <h1>Shell Nasuuti — Payments</h1>
        <p class="sub">Sign in with your phone or email.</p>
        ${!supabaseConfigured ? '<p class="err">Not connected to Supabase. Set VITE_SUPABASE_URL and VITE_SUPABASE_ANON_KEY.</p>' : ""}
        <div id="loginErr" class="err hidden" role="alert"></div>
        <form id="loginForm">
          <label class="f">Phone or email
            <input id="who" autocomplete="username" inputmode="email" autocapitalize="off" required>
          </label>
          <label class="f">Password
            <input type="password" id="password" autocomplete="current-password" required>
          </label>
          <button class="btn primary" type="submit" style="width:100%" id="loginBtn">Sign in</button>
        </form>
        <div class="or">or</div>
        <button class="btn google" id="googleBtn" type="button">Sign in with Google</button>
      </div>
    </div>`;
  const err = root.querySelector("#loginErr");
  const show = (m) => { err.textContent = m; err.classList.remove("hidden"); };
  const btn = root.querySelector("#loginBtn");
  root.querySelector("#loginForm").addEventListener("submit", async (e) => {
    e.preventDefault();
    err.classList.add("hidden");
    btn.disabled = true; btn.textContent = "Signing in…";
    try { await signIn(root.querySelector("#who").value, root.querySelector("#password").value); }
    catch (x) { show(x.message); }
    finally { btn.disabled = false; btn.textContent = "Sign in"; }
  });
  root.querySelector("#googleBtn").addEventListener("click", async () => {
    try { await signInGoogle(); } catch (x) { show(x.message || "Google sign-in failed."); }
  });
}
