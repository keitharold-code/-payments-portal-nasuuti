// Client-side image preparation: shrink phone photos to <= 1.5 MB before upload (slow 3G, low-end Android).

export const MAX_BYTES = 1.5 * 1024 * 1024;

async function loadBitmap(file) {
  if (typeof createImageBitmap === "function") {
    try { return await createImageBitmap(file, { imageOrientation: "from-image" }); } catch (_) { /* fall through */ }
  }
  return new Promise((resolve, reject) => {
    const img = new Image(), url = URL.createObjectURL(file);
    img.onload = () => { URL.revokeObjectURL(url); resolve(img); };
    img.onerror = () => { URL.revokeObjectURL(url); reject(new Error("Could not read this photo.")); };
    img.src = url;
  });
}
const toBlob = (canvas, q) => new Promise((res) => canvas.toBlob(res, "image/jpeg", q));

export async function compressImage(file, maxBytes = MAX_BYTES, maxDim = 2000) {
  if (file.type === "application/pdf") {
    if (file.size > maxBytes) throw new Error("This PDF is over 1.5 MB. Take a photo of the paper instead.");
    return file;
  }
  const bmp = await loadBitmap(file);
  const w0 = bmp.width || bmp.naturalWidth, h0 = bmp.height || bmp.naturalHeight;
  let scale = Math.min(1, maxDim / Math.max(w0, h0));
  let quality = 0.8;
  for (let i = 0; i < 10; i++) {
    const c = document.createElement("canvas");
    c.width = Math.max(1, Math.round(w0 * scale)); c.height = Math.max(1, Math.round(h0 * scale));
    const ctx = c.getContext("2d");
    ctx.fillStyle = "#fff"; ctx.fillRect(0, 0, c.width, c.height);   // JPEG has no transparency
    ctx.drawImage(bmp, 0, 0, c.width, c.height);
    const blob = await toBlob(c, quality);
    if (blob && blob.size <= maxBytes) return blob;
    if (quality > 0.55) quality -= 0.1; else scale *= 0.8;
  }
  throw new Error("Could not make this photo small enough. Try again.");
}

export async function sha256Hex(blob) {
  try {
    const buf = await blob.arrayBuffer();
    const d = await crypto.subtle.digest("SHA-256", buf);
    return Array.from(new Uint8Array(d)).map((b) => b.toString(16).padStart(2, "0")).join("");
  } catch (_) { return ""; }       // insecure context or old browser: the hash check is only a warning aid
}

export function uuid() {
  if (crypto.randomUUID) return crypto.randomUUID();
  return "xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx".replace(/[xy]/g, (c) => {
    const r = (Math.random() * 16) | 0; return (c === "x" ? r : (r & 3) | 8).toString(16);
  });
}
