import { supabase } from "./supabase.js";
import { getState, setState } from "./store.js";
import { parseLogin } from "./format.js";

const SESSION_HOURS = 8;

async function loadAccess(session) {
  if (!session) { setState({ profile: null, roles: [], sites: [], siteId: null, ready: true, loadError: null }); return; }
  setState({ ready: false, loadError: null });
  try {
    const uid = session.user.id;
    const [p, r] = await Promise.all([
      supabase.from("profiles").select("id, full_name, is_active").eq("id", uid).maybeSingle(),
      supabase.schema("core").from("user_roles").select("module, role, site_id")
        .eq("user_id", uid).eq("active", true).is("deleted_at", null),
    ]);
    if (p.error) throw p.error;
    if (r.error) throw r.error;
    const roles = r.data || [];
    let sites = [];
    if (roles.length) {
      const s = await supabase.schema("core").from("sites").select("id, code, name")
        .in("id", [...new Set(roles.map((x) => x.site_id))]).eq("active", true);
      if (s.error) throw s.error;
      sites = s.data || [];
    }
    setState({ profile: p.data, roles, sites, siteId: sites[0]?.id ?? null, ready: true });
  } catch (e) {
    setState({ profile: null, roles: [], sites: [], ready: true, loadError: e.message || String(e) });
  }
}

// 8-hour limit from the server-stamped sign-in time (works without a paid Supabase plan).
function expired(session) {
  const t = Date.parse(session?.user?.last_sign_in_at || "");
  return Number.isFinite(t) && Date.now() - t > SESSION_HOURS * 3600 * 1000;
}

export async function init() {
  supabase.auth.onAuthStateChange((event, session) => {
    if (event === "TOKEN_REFRESHED" || event === "INITIAL_SESSION") return;
    handle(session);
  });
  const { data } = await supabase.auth.getSession();
  await handle(data.session);
  setInterval(async () => {
    const { data: d } = await supabase.auth.getSession();
    if (d.session && expired(d.session)) signOut();
  }, 60000);
}

async function handle(session) {
  if (session && expired(session)) { await supabase.auth.signOut(); session = null; }
  const prev = getState().session?.user?.id;
  setState({ session });
  if ((session?.user?.id ?? null) !== (prev ?? null) || !getState().ready) await loadAccess(session);
}

export async function signIn(identifier, password) {
  const id = parseLogin(identifier);
  if (id.error) throw new Error(id.error);
  const { error } = await supabase.auth.signInWithPassword({ ...id, password });
  if (error) throw new Error("Wrong details. Check and try again.");
}

export async function signInGoogle() {
  const { error } = await supabase.auth.signInWithOAuth({
    provider: "google", options: { redirectTo: window.location.origin },
  });
  if (error) throw error;
}

export async function signOut() {
  await supabase.auth.signOut();
  setState({ session: null, profile: null, roles: [], sites: [], siteId: null, ready: true });
}
