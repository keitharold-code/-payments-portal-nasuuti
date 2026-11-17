// Tiny hash router. Routes: { path, title, roles?: [..payments roles], render(root, ctx) }
// Hash routing keeps Vercel config trivial and works for every branch preview URL.
const routes = [];
let current = null;

export function register(route) { routes.push(route); }
export function allRoutes() { return routes; }
export function path() { return (location.hash || "#/launcher").replace(/^#/, "") || "/launcher"; }
export function go(p) { location.hash = "#" + p; }
export function match() { return routes.find((r) => r.path === path()) || null; }

export function renderRoute(root, ctx) {
  const r = match();
  if (!r) { go("/launcher"); return; }
  current = r;
  r.render(root, ctx);
}
export function currentRoute() { return current; }
