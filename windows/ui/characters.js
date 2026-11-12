// The winner's second prize: play as a legend for the day. Your clock wears it (head only), and
// friends see the badge next to your name. Each day you win unlocks one, yours to keep.
// Names, lines, colours and proportions follow the Mac's Sources/Characters.swift.
const rgb = (r, g, b) => [Math.round(r * 255), Math.round(g * 255), Math.round(b * 255)];
const CHARACTERS = [
  { id: "obama", name: "Barack Obama", line: "Yes we can.", badge: "🇺🇸", skin: rgb(0.60, 0.40, 0.27), hair: [rgb(0.32, 0.32, 0.32), 0.27] },
  { id: "mlk", name: "Martin Luther King Jr.", line: "I have a dream.", badge: "🕊️", skin: rgb(0.50, 0.32, 0.21), hair: [rgb(0.09, 0.09, 0.09), 0.29] },
  { id: "tyson", name: "Mike Tyson", line: "Everybody has a plan until they get punched in the mouth.", badge: "🥊", skin: rgb(0.47, 0.30, 0.20), hair: [rgb(0.08, 0.08, 0.08), 0.2] },
  { id: "fifty", name: "50 Cent", line: "Get rich or die tryin'.", badge: "💰", skin: rgb(0.45, 0.29, 0.19) },
  { id: "icecube", name: "Ice Cube", line: "Today was a good day.", badge: "🧢", skin: rgb(0.52, 0.34, 0.22) },
];
const CHARACTER = Object.fromEntries(CHARACTERS.map(c => [c.id, c]));

/** Characters are switched off for now (as on the Mac, Costume.enabled): everyone gets the basic
 *  buddy. The picker, the costume on the clock and panel header, and the friend badges all go
 *  through this switch; the code stays for when they come back. */
const CHARACTERS_ENABLED = false;
/** Today's costume for a character id, or null when characters are off or the id is unknown. */
const costumeOf = id => (CHARACTERS_ENABLED && id && CHARACTER[id]) || null;
const INK = "#1a1a1a";
const css = c => `rgb(${c.join(",")})`;
/** Mix a colour toward white (k > 0) or black (k < 0). */
const shade = (c, k) => css(c.map(v => Math.round(k >= 0 ? v + (255 - v) * k : v * (1 + k))));
let uid = 0;
const nid = p => `${p}${++uid}`;

/** Ears sit behind the face: `w` is the face's width, centred at (cx, cy). */
function earsSvg(c, w, cx, cy) {
  if (!c) return "";
  const y = cy + w * 0.03;
  let out = "";
  for (const side of [-1, 1]) {
    const x = cx + side * w * 0.485;
    out += `<ellipse cx="${x}" cy="${y}" rx="${w * 0.085}" ry="${w * 0.11}" fill="${css(c.skin)}"/>` +
           `<ellipse cx="${x}" cy="${y}" rx="${w * 0.035}" ry="${w * 0.055}" fill="rgba(0,0,0,.18)"/>`;
  }
  if (c.id === "fifty") { // a diamond stud on his right ear (the viewer's right)
    const id = nid("glow");
    out += `<defs><filter id="${id}"><feGaussianBlur stdDeviation="${Math.max(0.5, w * 0.02)}"/></filter></defs>` +
      `<circle cx="${cx + w * 0.485}" cy="${cy + w * 0.135}" r="${w * 0.045}" fill="#fff" filter="url(#${id})"/>` +
      `<circle cx="${cx + w * 0.485}" cy="${cy + w * 0.135}" r="${w * 0.035}" fill="#fff"/>`;
  }
  return out;
}

/** Everything on top of the head: hair, cap, moustache, tattoo, shine. */
function costumeSvg(c, w, cx, cy) {
  if (!c) return "";
  let out = "";
  if (c.hair) {
    const [color, depth] = c.hair, clip = nid("hair"), g = nid("hg");
    const top = cy - w * 0.51;
    out += `<defs><clipPath id="${clip}"><ellipse cx="${cx}" cy="${top + 0.1 * depth * w}" rx="${w * 0.625}" ry="${depth * w}"/></clipPath>
      <linearGradient id="${g}" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="${shade(color, 0.12)}"/><stop offset="1" stop-color="${css(color)}"/></linearGradient></defs>
      <circle cx="${cx}" cy="${cy}" r="${w * 0.51}" fill="url(#${g})" clip-path="url(#${clip})"/>`;
  }
  switch (c.id) {
    case "icecube": { // black cap: crown, brim across the forehead, silver button
      const clip = nid("cap"), g = nid("cg"), r = w * 0.53, ccy = cy - w * 0.02, top = ccy - r;
      out += `<defs><clipPath id="${clip}"><rect x="${cx - r}" y="${top}" width="${2 * r}" height="${w * 0.36}"/></clipPath>
        <linearGradient id="${g}" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="rgb(46,46,46)"/><stop offset="1" stop-color="rgb(31,31,31)"/></linearGradient></defs>
        <circle cx="${cx}" cy="${ccy}" r="${r}" fill="url(#${g})" clip-path="url(#${clip})"/>
        <rect x="${cx - w * 0.5}" y="${cy - w * 0.215}" width="${w}" height="${w * 0.13}" rx="${w * 0.065}" fill="rgb(51,51,51)"/>
        <circle cx="${cx}" cy="${cy - w * 0.33}" r="${w * 0.045}" fill="rgb(191,191,191)"/>`;
      break;
    }
    case "mlk":
      out += `<rect x="${cx - w * 0.11}" y="${cy + w * 0.02}" width="${w * 0.22}" height="${w * 0.04}" rx="${w * 0.02}" fill="${INK}"/>`;
      break;
    case "tyson": { // the face tattoo by his left eye
      const W = w * 0.13, H = w * 0.16, x = cx + w * 0.33 - W / 2, y = cy - w * 0.14 - H / 2;
      out += `<path transform="translate(${x} ${y})" d="M0 0 Q${W} 0 ${W} ${H / 2} M${0.1 * W} ${H / 2} Q${0.8 * W} ${H / 2} ${0.85 * W} ${H}"
        fill="none" stroke="${INK}" stroke-width="${w * 0.03}" stroke-linecap="round"/>`;
      break;
    }
    case "fifty": // shaved head: a little shine
      out += `<ellipse cx="${cx - w * 0.16}" cy="${cy - w * 0.36}" rx="${w * 0.15}" ry="${w * 0.05}" fill="rgba(255,255,255,.22)"
        transform="rotate(-20 ${cx - w * 0.16} ${cy - w * 0.36})"/>`;
      break;
  }
  return out;
}

/** An emoji centred at (x, y) in a box. */
const emojiAt = (ch, size, x, y, flip = false) =>
  `<span style="position:absolute;left:${x}px;top:${y}px;font-size:${size}px;line-height:1;transform:translate(-50%,-50%)${flip ? " scaleX(-1)" : ""};` +
  `font-family:'Segoe UI Emoji','Apple Color Emoji',sans-serif;pointer-events:none">${ch}</span>`;

/** Head and shoulders, dressed the part. `s` is the head size; the box is 1.5s square. */
function portrait(id, s) {
  const c = CHARACTER[id];
  if (!c) return "";
  const W = s * 1.5, cx = W / 2;
  const neckColor = shade(c.skin, -0.12);
  // Shoulders: 1.45s wide, from y .88s down, top corners rounded .42s.
  const sx = cx - s * 0.725, sy = s * 0.88, sw = s * 1.45, sh = s * 0.62, rr = s * 0.42;
  const shoulders = `M${sx} ${sy + sh} V${sy + rr} Q${sx} ${sy} ${sx + rr} ${sy} H${sx + sw - rr} Q${sx + sw} ${sy} ${sx + sw} ${sy + rr} V${sy + sh} Z`;
  let outfit = "";
  if (id === "obama" || id === "mlk") { // dark suit, white shirt, tie
    const suit = id === "obama" ? css(rgb(0.12, 0.16, 0.28)) : css(rgb(0.16, 0.16, 0.16));
    const tie = id === "obama" ? css(rgb(0.2, 0.35, 0.75)) : css(rgb(0.45, 0.1, 0.12));
    const tw = s * 0.12, th = s * 0.36, tx = cx - tw / 2, ty = sy + s * 0.04;
    outfit = `<path d="${shoulders}" fill="${suit}"/>
      <path d="M${cx - s * 0.21} ${sy} H${cx + s * 0.21} L${cx} ${sy + s * 0.36} Z" fill="#fff"/>
      <path d="M${tx + tw * 0.2} ${ty} H${tx + tw * 0.8} L${tx + tw} ${ty + th * 0.85} L${cx} ${ty + th} L${tx} ${ty + th * 0.85} Z" fill="${tie}"/>`;
  } else {
    const fifty = id === "fifty";
    outfit = `<path d="${shoulders}" fill="${fifty ? "rgb(245,245,245)" : "rgb(33,33,33)"}"
        ${fifty ? `stroke="rgba(0,0,0,.15)" stroke-width="${Math.max(1, s * 0.02)}"` : ""}/>
      <ellipse cx="${cx}" cy="${sy}" rx="${s * 0.18}" ry="${s * 0.1}" fill="${neckColor}"/>`;
  }
  const neck = `<rect x="${cx - s * 0.16}" y="${s * 0.8}" width="${s * 0.32}" height="${s * 0.25}" fill="${neckColor}"/>`;
  const head = earsSvg(c, s, cx, s / 2) + faceSvg({ mood: 1, still: true, character: id }, s, cx, s / 2) + costumeSvg(c, s, cx, s / 2);
  let chain = "", extras = "";
  if (id === "fifty") {
    const g = nid("gold"), x0 = cx - s * 0.25, y0 = s * 0.9;
    chain = `<defs><linearGradient id="${g}" x1="0" y1="0" x2="1" y2="0"><stop offset="0" stop-color="#ffd60a"/><stop offset="1" stop-color="#ff9f0a"/></linearGradient></defs>
      <path d="M${x0} ${y0} Q${cx} ${y0 + s * 0.504} ${x0 + s * 0.5} ${y0}" fill="none" stroke="url(#${g})" stroke-width="${s * 0.06}" stroke-linecap="round" stroke-dasharray="${s * 0.035} ${s * 0.03}"/>
      <text x="${cx}" y="${s * 1.25}" text-anchor="middle" dominant-baseline="central" font-size="${s * 0.16}" font-weight="900" fill="#ffd60a" font-family="Segoe UI, system-ui, sans-serif">$</text>`;
  }
  if (id === "obama") extras = emojiAt("🇺🇸", s * 0.16, cx - s * 0.32, s * 1.12);
  if (id === "mlk") extras = emojiAt("🕊️", s * 0.32, cx + s * 0.58, s * 0.14);
  if (id === "tyson") extras = emojiAt("🥊", s * 0.38, cx - s * 0.5, s * 0.97) + emojiAt("🥊", s * 0.38, cx + s * 0.5, s * 0.97, true);
  return `<div style="position:relative;width:${W}px;height:${W}px;flex:none">
    <svg width="${W}" height="${W}" viewBox="0 0 ${W} ${W}" style="overflow:visible">${outfit}${neck}${head}${chain}</svg>${extras}</div>`;
}
