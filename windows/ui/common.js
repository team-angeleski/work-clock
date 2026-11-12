// Shared by every window: talk to the Rust side, and draw small pieces.
const T = window.__TAURI__;
const invoke = (cmd, args) => T.core.invoke(cmd, args);
const listen = (ev, fn) => T.event.listen(ev, e => fn(e.payload));
const $ = s => document.querySelector(s);
const esc = s => String(s ?? "").replace(/[&<>"']/g, c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));

/** Calls fn with the state now and on every change (once a second). */
function onState(fn) {
  invoke("state").then(fn);
  listen("state", fn);
}

/** A coloured letter tile standing in for an app or site icon. */
function avatar(name, size = 22) {
  const n = String(name || "?");
  let h = 0;
  for (const c of n) h = (h * 31 + c.charCodeAt(0)) % 360;
  return `<span class="avatar" style="width:${size}px;height:${size}px;font-size:${Math.round(size * 0.5)}px;` +
    `background:linear-gradient(135deg,hsl(${h} 85% 70%),hsl(${(h + 40) % 360} 80% 60%))">${esc(n.replace(/^www\./, "")[0] || "?")}</span>`;
}

/** The ring with a little face: progress to today's goal, and how you're doing. */
function ring(s, size) {
  const r = size / 2 - size * 0.08, c = 2 * Math.PI * r, w = size * 0.11;
  const p = Math.max(0, Math.min(1, s.progress || 0));
  const stroke = s.goalMet ? "url(#gGoal)" : s.offTask ? "rgba(255,107,107,.9)" : "url(#gFlow)";
  const mood = s.mood ?? 0;
  const cx = size / 2, cy = size / 2, eyeY = cy - size * 0.06, eyeDx = size * 0.11, er = size * 0.045;
  const blink = s.mode === "running" && s.onTask && Math.floor(Date.now() / 1000) % 4 === 0;
  const mouthW = size * 0.15, my = cy + size * 0.1, bend = mood * size * 0.09;
  const eyes = blink
    ? `<path d="M${cx - eyeDx - er} ${eyeY}h${er * 2}M${cx + eyeDx - er} ${eyeY}h${er * 2}" stroke="#fff" stroke-width="${size * 0.035}" stroke-linecap="round"/>`
    : `<circle cx="${cx - eyeDx}" cy="${eyeY}" r="${er}" fill="#fff"/><circle cx="${cx + eyeDx}" cy="${eyeY}" r="${er}" fill="#fff"/>`;
  return `<svg width="${size}" height="${size}" viewBox="0 0 ${size} ${size}">
    <defs>
      <linearGradient id="gFlow" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#ffb347"/><stop offset="1" stop-color="#ff5e8a"/></linearGradient>
      <linearGradient id="gGoal" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#7cf5c8"/><stop offset="1" stop-color="#21c98a"/></linearGradient>
    </defs>
    <circle cx="${cx}" cy="${cy}" r="${r}" fill="none" stroke="rgba(255,255,255,.13)" stroke-width="${w}"/>
    <circle cx="${cx}" cy="${cy}" r="${r}" fill="none" stroke="${stroke}" stroke-width="${w}" stroke-linecap="round"
      stroke-dasharray="${c * p} ${c}" transform="rotate(-90 ${cx} ${cy})" style="transition:stroke-dasharray .6s"/>
    ${eyes}
    <path d="M${cx - mouthW} ${my} Q${cx} ${my + bend} ${cx + mouthW} ${my}" fill="none" stroke="#fff" stroke-width="${size * 0.035}" stroke-linecap="round"/>
  </svg>`;
}

const DAY_LETTERS = ["M", "T", "W", "T", "F", "S", "S"];
function timeText(min) {
  const h = Math.floor(min / 60), m = min % 60, h12 = h % 12 === 0 ? 12 : h % 12;
  return `${h12}:${String(m).padStart(2, "0")}${h < 12 ? "am" : "pm"}`;
}
/** <select> of clock-in times, 4am to 2pm in 15-minute steps. */
function timeOptions(selected) {
  let out = "";
  for (let m = 240; m <= 840; m += 15) out += `<option value="${m}" ${m === selected ? "selected" : ""}>${timeText(m)}</option>`;
  return out;
}
function dayButtons(el, bits, onChange) {
  el.innerHTML = DAY_LETTERS.map((d, i) => `<button type="button" data-i="${i}" class="${bits & (1 << i) ? "on" : ""}">${d}</button>`).join("");
  el.querySelectorAll("button").forEach(b => b.onclick = () => { bits ^= 1 << +b.dataset.i; b.classList.toggle("on"); onChange(bits); });
}
