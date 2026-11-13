// An account's frame: ten hard-edged segments in one muted colour family, drawn
// from the 20 bytes of its address, as a CSS conic-gradient. The first byte
// picks the family's hue; each pair of bytes then gives a segment a small step
// away from that hue (first byte) and its lightness (second byte). The server
// computes the same string (Annuart.Randomart.frame/1), so an account looks the
// same wherever its address is shown. A recognition aid, not a proof.
const SEGMENTS = 10;

// The gradient for `address`, or null unless it is 20 bytes of 0x hex.
export function accountFrame(address) {
  if (typeof address !== "string" || !/^0x[0-9a-fA-F]{40}$/.test(address)) return null;
  const base = Math.floor(parseInt(address.slice(2, 4), 16) * 360 / 256);
  const stops = [];
  for (let i = 0; i < SEGMENTS; i++) {
    const step = parseInt(address.slice(2 + i * 4, 4 + i * 4), 16);
    const light = parseInt(address.slice(4 + i * 4, 6 + i * 4), 16);
    const hue = (base + (step % 5 - 2) * 18 + 360) % 360;
    const from = Math.floor(i * 100 / SEGMENTS);
    const to = Math.floor((i + 1) * 100 / SEGMENTS);
    stops.push(`hsl(${hue} 45% ${40 + (light % 4) * 8}%) ${from}% ${to}%`);
  }
  return `conic-gradient(${stops.join(", ")})`;
}

// Puts the frame of `address` around `el`. Leaves `el` alone for a malformed address.
export function applyFrame(el, address) {
  const frame = accountFrame(address);
  if (!frame) return el;
  el.classList.add("acct-frame");
  el.style.setProperty("--frame", frame);
  return el;
}
