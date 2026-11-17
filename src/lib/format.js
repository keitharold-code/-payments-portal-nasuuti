// Display helpers. UGX: thousand separators, no decimals. Dates dd/mm/yyyy.
// All "today" logic uses Africa/Kampala, never the phone's own timezone.

export const TZ = "Africa/Kampala";

export function ugx(n) {
  return Math.round(Number(n) || 0).toLocaleString("en-US");
}

export function esc(s) {
  return String(s ?? "").replace(
    /[&<>"']/g,
    (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]
  );
}

// "YYYY-MM-DD" for an instant, as seen in Kampala.
export function kampalaDate(d = new Date()) {
  const p = new Intl.DateTimeFormat("en-CA", {
    timeZone: TZ, year: "numeric", month: "2-digit", day: "2-digit",
  }).format(d);
  return p; // en-CA formats as YYYY-MM-DD
}

export function dmy(s) {
  if (!s) return "";
  const [y, m, d] = String(s).slice(0, 10).split("-");
  return d + "/" + m + "/" + y;
}

// timestamptz string -> "dd/mm/yyyy HH:MM" in Kampala
export function dmyTime(ts) {
  if (!ts) return "";
  const d = new Date(ts);
  const time = new Intl.DateTimeFormat("en-GB", {
    timeZone: TZ, hour: "2-digit", minute: "2-digit", hour12: false,
  }).format(d);
  return dmy(kampalaDate(d)) + " " + time;
}

export function addDays(s, n) {
  const d = new Date(s + "T12:00:00Z");
  d.setUTCDate(d.getUTCDate() + n);
  return d.toISOString().slice(0, 10);
}

// Phone or email -> what Supabase signInWithPassword expects.
// Uganda: 0772123456 / 772123456 / +256772123456 / 256772123456 -> +256772123456
export function parseLogin(input) {
  const v = String(input || "").trim();
  if (v.includes("@")) return { email: v.toLowerCase() };
  let d = v.replace(/[\s()-]/g, "");
  if (d.startsWith("+")) d = d.slice(1);
  if (d.startsWith("00")) d = d.slice(2);
  if (d.startsWith("0")) d = "256" + d.slice(1);
  else if (/^7\d{8}$/.test(d)) d = "256" + d;
  if (!/^\d{11,15}$/.test(d)) return { error: "Enter an email or a phone number." };
  return { phone: "+" + d };
}
