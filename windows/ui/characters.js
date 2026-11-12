// The winner's second prize: play as a character for the day. Your clock wears it, and friends
// see the badge next to your name. Same names, lines, badges and costume layout as the Mac's
// Sources/Characters.swift.
const SKIN = "rgb(140,92,61)"; // rgb(0.55, 0.36, 0.24): the five real people
const CHARACTERS = [
  // Icons
  { id: "obama", name: "Barack Obama", line: "Yes we can.", badge: "🇺🇸", skin: SKIN },
  { id: "mlk", name: "Martin Luther King Jr.", line: "I have a dream.", badge: "🕊️", skin: SKIN },
  { id: "tyson", name: "Mike Tyson", line: "Everybody has a plan until they get punched in the mouth.", badge: "🥊", skin: SKIN },
  { id: "fifty", name: "50 Cent", line: "Get rich or die tryin'.", badge: "💰", skin: SKIN },
  { id: "icecube", name: "Ice Cube", line: "Today was a good day.", badge: "🧢", skin: SKIN, hat: "🧢" },
  // Originals
  { id: "boss", name: "Big Boss", line: "Corner office. Mine.", hat: "👑", eyes: "🕶️" },
  { id: "sergeant", name: "Drill Sergeant", line: "Fall in. The clock is running.", hat: "🪖" },
  { id: "professor", name: "The Professor", line: "Class is in session.", hat: "🎓", eyes: "👓" },
  { id: "techbro", name: "Tech Bro", line: "Shipping. Don't talk to me.", hat: "🧢", eyes: "🕶️" },
  { id: "nana", name: "Nana", line: "I made you a snack. Now get to work.", hat: "👒", eyes: "👓" },
  { id: "gentleman", name: "The Gentleman", line: "Splendid. Shall we begin?", hat: "🎩" },
  { id: "scientist", name: "Mad Scientist", line: "It's alive! Your focus, that is.", eyes: "🥽" },
  { id: "champ", name: "The Champ", line: "Undisputed.", badge: "🏆" },
];
for (const c of CHARACTERS) c.badge = c.badge || c.hat || c.eyes || "⭐️";
const CHARACTER = Object.fromEntries(CHARACTERS.map(c => [c.id, c]));

/** The costume pieces over a face `f` pixels wide, centred at (cx, cy) in a box. */
function costumeLayer(c, f, cx, cy) {
  if (!c) return "";
  // An emoji centred at an offset from the face's centre (offsets as fractions of f, like the Mac).
  const emoji = (ch, scale, dx, dy, extra = "") =>
    `<span style="position:absolute;left:${cx + dx * f}px;top:${cy + dy * f}px;font-size:${scale * f}px;line-height:1;` +
    `transform:translate(-50%,-50%) ${extra};font-family:'Segoe UI Emoji','Apple Color Emoji',sans-serif">${ch}</span>`;
  let out = "";
  if (c.eyes) out += emoji(c.eyes, 0.58, 0, -0.04);
  if (c.hat) {
    const rot = c.id === "techbro" ? -14 : c.id === "gentleman" ? 6 : 0;
    const dy = c.id === "boss" ? -0.5 : c.id === "nana" ? -0.47 : -0.43;
    const dx = c.id === "techbro" ? -0.04 : 0;
    out += emoji(c.hat, 0.6, dx, dy, `rotate(${rot}deg)` + (c.id === "icecube" ? ";filter:brightness(.3) saturate(0)" : ""));
  }
  const gloves = emoji("🥊", 0.42, -0.5, 0.3) + emoji("🥊", 0.42, 0.5, 0.3, "scaleX(-1)");
  const ink = "#1a1a1a";
  // Shapes drawn in face units: (0,0) is the face's top-left, 1 is its width.
  const svg = body => `<svg style="position:absolute;left:${cx - f / 2}px;top:${cy - f / 2}px;overflow:visible" width="${f}" height="${f}" viewBox="0 0 1 1">${body}</svg>`;
  switch (c.id) {
    case "champ":
      out += svg(`<rect x="0.04" y="0.115" width="0.92" height="0.13" rx="0.065" fill="url(#gBand)"/>
        <defs><linearGradient id="gBand" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#ff6b6b"/><stop offset="1" stop-color="#d62828"/></linearGradient></defs>`);
      out += gloves;
      break;
    case "tyson":
      // The face tattoo by his left eye, and gloves up.
      out += svg(`<g transform="translate(0.91 0.21) scale(-1 1)" fill="none" stroke="${ink}" stroke-width="0.035" stroke-linecap="round">
        <path d="M0.14 0 Q0 0 0 0.09 M0.14 0.09 Q0.028 0.09 0.028 0.18"/></g>`);
      out += gloves;
      break;
    case "mlk":
      out += svg(`<rect x="0.39" y="0.52" width="0.22" height="0.04" rx="0.02" fill="${ink}"/>`);
      out += emoji("🕊️", 0.4, 0.5, -0.42);
      break;
    case "obama":
      out += emoji("🇺🇸", 0.26, 0.36, 0.4);
      break;
    case "fifty":
      out += svg(`<defs><linearGradient id="gGold" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#ffe066"/><stop offset="1" stop-color="#e0a800"/></linearGradient></defs>
        <path d="M0.15 0.81 Q0.5 1.29 0.85 0.81" fill="none" stroke="url(#gGold)" stroke-width="0.06" stroke-linecap="round" stroke-dasharray="0.03 0.04"/>`);
      out += emoji("💰", 0.3, 0.44, 0.42);
      break;
  }
  return out;
}

/** A costumed buddy for pickers and rows. */
function characterFace(id, size) {
  return ring({ progress: 0, mood: 1, mode: "running", onTask: true, still: true, character: id, bare: true }, size);
}
