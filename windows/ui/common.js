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

/** The ring with the buddy inside: progress to today's goal, and how you're doing (Views.swift Ring + Face).
 *  `s.character` dresses the buddy in today's costume; `s.bare` leaves out the ring. */
function ring(s, size) {
  const line = size * 0.12, r = (size - line) / 2, c = 2 * Math.PI * r;
  const p = Math.max(0.002, Math.min(1, s.progress || 0));
  const active = s.mode === "running" && s.onTask;
  const stroke = active ? (s.goalMet ? "url(#gGoal)" : "url(#gFlow)") : s.offTask ? "rgba(255,107,107,.7)" : "rgba(160,160,170,.7)";
  const cx = size / 2, cy = size / 2;
  const ch = s.character ? CHARACTER[s.character] : null;
  const w = size * 0.7, x0 = cx - w / 2, y0 = cy - w / 2;
  // Face colour: status tint, or the character's skin with a lighter top.
  const tint = s.offTask ? [255, 90, 90] : s.goalMet ? [52, 199, 89] : active ? [255, 149, 0] : [150, 150, 158];
  const mix = (rgb, k) => `rgb(${rgb.map(v => Math.round(v + (255 - v) * k)).join(",")})`;
  const top = ch && ch.skin ? "rgb(161,121,96)" : mix(tint, 0.55);
  const bottom = ch && ch.skin ? ch.skin : mix(tint, 0.25);
  const mood = Math.max(-1, Math.min(1, s.mood ?? 0)), ink = "#1f1f1f";
  const id = "f" + Math.random().toString(36).slice(2, 8);
  const eyeY = y0 + w * (0.5 - 0.06 + (mood < 0 ? 0.03 : 0));
  const blink = active && !s.still && Math.floor(Date.now() / 1000) % 4 === 0;
  let eyes = "";
  for (const side of [-1, 1]) {
    if (mood > 0.85) {
      const ex = cx + side * w * 0.185, ew = w * 0.17, eh = w * 0.09;
      eyes += `<path d="M${ex - ew / 2} ${eyeY + eh / 2} Q${ex} ${eyeY - eh} ${ex + ew / 2} ${eyeY + eh / 2}" fill="none" stroke="${ink}" stroke-width="${w * 0.07}" stroke-linecap="round"/>`;
    } else {
      const ex = cx + side * w * 0.18, rx = w * 0.07, ry = w * (mood < 0 ? 0.075 : 0.095) * (blink ? 0.12 : 1);
      eyes += `<ellipse cx="${ex}" cy="${eyeY}" rx="${rx}" ry="${ry}" fill="${ink}"/>`;
      if (!blink) eyes += `<circle cx="${ex + rx * 0.35}" cy="${eyeY - ry * 0.45}" r="${w * 0.0275}" fill="#fff"/>`;
    }
  }
  const blushA = 0.75 * Math.max(mood, 0);
  const blush = blushA > 0 ? [-1, 1].map(sd => `<ellipse cx="${cx + sd * w * 0.295}" cy="${y0 + w * 0.6}" rx="${w * 0.085}" ry="${w * 0.05}" fill="rgba(255,105,180,${blushA})"/>`).join("") : "";
  const my = y0 + w * 0.67, mw = w * 0.1, bend = mood * w * 0.1;
  const mouth = `<path d="M${cx - mw} ${my - bend / 2} Q${cx} ${my + bend} ${cx + mw} ${my - bend / 2}" fill="none" stroke="${ink}" stroke-width="${w * 0.065}" stroke-linecap="round"/>`;
  const ringSvg = s.bare ? "" : `
      <circle cx="${cx}" cy="${cy}" r="${r}" fill="none" stroke="rgba(255,255,255,.13)" stroke-width="${line}"/>
      <circle cx="${cx}" cy="${cy}" r="${r}" fill="none" stroke="${stroke}" stroke-width="${line}" stroke-linecap="round"
        stroke-dasharray="${c * p} ${c}" transform="rotate(-90 ${cx} ${cy})" style="transition:stroke-dasharray .6s"/>`;
  return `<div style="position:relative;width:${size}px;height:${size}px;flex:none">
    <svg width="${size}" height="${size}" viewBox="0 0 ${size} ${size}" style="overflow:visible">
      <defs>
        <linearGradient id="gFlow" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#ffb347"/><stop offset="1" stop-color="#ff5e8a"/></linearGradient>
        <linearGradient id="gGoal" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#7cf5c8"/><stop offset="1" stop-color="#21c98a"/></linearGradient>
        <linearGradient id="${id}" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="${top}"/><stop offset="1" stop-color="${bottom}"/></linearGradient>
      </defs>${ringSvg}
      <circle cx="${cx}" cy="${cy}" r="${w / 2}" fill="url(#${id})"/>
      ${blush}${eyes}${mouth}
    </svg>${costumeLayer(ch, w, cx, cy)}</div>`;
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
