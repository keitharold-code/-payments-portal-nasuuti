// Minimal pub-sub store — same pattern as the Daily Sales portal.
const state = {
  session: null,
  profile: null, // { id, full_name, is_active } from public.profiles (shared with the sales portal)
  roles: [],     // [{ module, role, site_id }] from core.user_roles
  sites: [],     // [{ id, code, name }]
  siteId: null,  // active site
  ready: false,  // profile + roles loaded
  loadError: null,
};
const listeners = new Set();
export const getState = () => state;
export function setState(patch) {
  Object.assign(state, patch);
  listeners.forEach((fn) => fn(state));
}
export function subscribe(fn) {
  listeners.add(fn);
  return () => listeners.delete(fn);
}
