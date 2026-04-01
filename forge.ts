#!/usr/bin/env bun
/**
 * better-buddy forge — Find your perfect companion salt
 *
 * Brute-forces a 15-character salt string that, combined with your account UUID,
 * produces a Claude Code companion with your exact desired traits.
 *
 * Usage:
 *   bun run forge.ts                          # Interactive prompts
 *   bun run forge.ts --uuid YOUR_UUID         # Skip UUID prompt
 *   bun run forge.ts --species dragon --rarity legendary --eye ✦ --hat crown --shiny
 *   bun run forge.ts --count 10               # Find 10 matches
 *   bun run forge.ts --current                # Show your current companion
 *
 * Requires Bun (https://bun.sh) — Claude Code uses Bun.hash internally,
 * and we must match the same hash function.
 */

import { randomBytes } from "crypto";
import { parseArgs } from "util";
import a from "ansis";

// ═══════════════════════════════════════════════════════════════════════════════
// COMPANION GENERATION (exact port from Claude Code src/buddy/)
// ═══════════════════════════════════════════════════════════════════════════════

const ORIGINAL_SALT = "friend-2026-401";

const SPECIES = [
  "duck", "goose", "blob", "cat", "dragon", "octopus", "owl", "penguin",
  "turtle", "snail", "ghost", "axolotl", "capybara", "cactus", "robot",
  "rabbit", "mushroom", "chonk",
] as const;
type Species = (typeof SPECIES)[number];

const RARITIES = ["common", "uncommon", "rare", "epic", "legendary"] as const;
type Rarity = (typeof RARITIES)[number];

const EYES = ["·", "✦", "×", "◉", "@", "°"] as const;
type Eye = (typeof EYES)[number];

const HATS = [
  "none", "crown", "tophat", "propeller", "halo", "wizard", "beanie", "tinyduck",
] as const;
type Hat = (typeof HATS)[number];

const STAT_NAMES = ["DEBUGGING", "PATIENCE", "CHAOS", "WISDOM", "SNARK"] as const;
type StatName = (typeof STAT_NAMES)[number];

const RARITY_WEIGHTS: Record<Rarity, number> = {
  common: 60, uncommon: 25, rare: 10, epic: 4, legendary: 1,
};

const RARITY_FLOOR: Record<Rarity, number> = {
  common: 5, uncommon: 15, rare: 25, epic: 35, legendary: 50,
};

const RARITY_STARS: Record<Rarity, string> = {
  common: "★", uncommon: "★★", rare: "★★★", epic: "★★★★", legendary: "★★★★★",
};

// Rarity style functions — each returns a styled string
const RARITY_STYLE: Record<Rarity, (s: string) => string> = {
  common:    (s) => a.dim(s),
  uncommon:  (s) => a.green(s),
  rare:      (s) => a.cyan(s),
  epic:      (s) => a.magenta(s),
  legendary: (s) => a.yellow(s),
};
const RARITY_BOLD: Record<Rarity, (s: string) => string> = {
  common:    (s) => a.dim(s),
  uncommon:  (s) => a.green.bold(s),
  rare:      (s) => a.cyan.bold(s),
  epic:      (s) => a.magenta.bold(s),
  legendary: (s) => a.yellow.bold(s),
};
const RARITY_EMOJI: Record<Rarity, string> = {
  common: "·", uncommon: "◆", rare: "◈", epic: "✦", legendary: "♛",
};

function mulberry32(seed: number): () => number {
  let a = seed >>> 0;
  return function () {
    a |= 0;
    a = (a + 0x6d2b79f5) | 0;
    let t = Math.imul(a ^ (a >>> 15), 1 | a);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

function hashString(s: string): number {
  if (typeof Bun !== "undefined") {
    return Number(BigInt(Bun.hash(s)) & 0xffffffffn);
  }
  // FNV-1a fallback — WARNING: won't match production Claude Code
  let h = 2166136261;
  for (let i = 0; i < s.length; i++) {
    h ^= s.charCodeAt(i);
    h = Math.imul(h, 16777619);
  }
  return h >>> 0;
}

function pick<T>(rng: () => number, arr: readonly T[]): T {
  return arr[Math.floor(rng() * arr.length)]!;
}

function rollRarity(rng: () => number): Rarity {
  let roll = rng() * 100;
  for (const rarity of RARITIES) {
    roll -= RARITY_WEIGHTS[rarity];
    if (roll < 0) return rarity;
  }
  return "common";
}

function rollStats(rng: () => number, rarity: Rarity): Record<StatName, number> {
  const floor = RARITY_FLOOR[rarity];
  const peak = pick(rng, STAT_NAMES);
  let dump = pick(rng, STAT_NAMES);
  while (dump === peak) dump = pick(rng, STAT_NAMES);
  const stats = {} as Record<StatName, number>;
  for (const name of STAT_NAMES) {
    if (name === peak) {
      stats[name] = Math.min(100, floor + 50 + Math.floor(rng() * 30));
    } else if (name === dump) {
      stats[name] = Math.max(1, floor - 10 + Math.floor(rng() * 15));
    } else {
      stats[name] = floor + Math.floor(rng() * 40);
    }
  }
  return stats;
}

type Bones = {
  rarity: Rarity;
  species: Species;
  eye: Eye;
  hat: Hat;
  shiny: boolean;
  stats: Record<StatName, number>;
};

function generate(userId: string, salt: string): Bones {
  const rng = mulberry32(hashString(userId + salt));
  const rarity = rollRarity(rng);
  return {
    rarity,
    species: pick(rng, SPECIES) as Species,
    eye: pick(rng, EYES) as Eye,
    hat: (rarity === "common" ? "none" : pick(rng, HATS)) as Hat,
    shiny: rng() < 0.01,
    stats: rollStats(rng, rarity),
  };
}

// ═══════════════════════════════════════════════════════════════════════════════
// DISPLAY
// ═══════════════════════════════════════════════════════════════════════════════

// ── Box drawing card renderer ────────────────────────────────────────────────

const HAT_LINES: Record<string, string> = {
  crown:    " \\^^^/ ",
  tophat:   " [___] ",
  propeller:"  -+-  ",
  halo:     " (   ) ",
  wizard:   "  /^\\  ",
  beanie:   " (___) ",
  tinyduck: "  ,>   ",
};

const SPRITES: Record<string, string[]> = {
  duck:     ["  .__  ", " <(.)_ ", "  (__/ "],
  goose:    ["  (.)> ", "   ||  ", " _(__)_"],
  blob:     [" .---. ", "( . . )", " `---´ "],
  cat:      [" /\\_/\\ ", "( . . )", " (  ω )"],
  dragon:   [" /^  ^\\ ", "< .  . >", " `-vv-´"],
  octopus:  [" .----. ", "( .  . )", " /\\/\\/\\"],
  owl:      [" /\\  /\\ ", "((.)(.))", " ( >< )"],
  penguin:  [" .---. ", " (. .)", "/(   )\\"],
  turtle:   [" _,--._ ", "( .  . )", "/[____]\\"],
  snail:    [" .  .--.", " \\ (@ )", " \\_`-´ "],
  ghost:    [" .----. ", "/ .  . \\", " ~`~~`~ "],
  axolotl:  ["}(____){", "}( .. ){", " (.--.) "],
  capybara: [" n____n ", "( .  . )", "(  oo  )"],
  cactus:   ["n ____ n", "||.  .||", "|_|  |_|"],
  robot:    [" .[||]. ", "[ .  . ]", "[ ==== ]"],
  rabbit:   [" (\\__/) ", "( .  . )", "=(  . )="],
  mushroom: [" -oOOo- ", "(______)", " |.  .| "],
  chonk:    [" /\\  /\\ ", "( .  . )", "(  ..  )"],
};

function renderCard(bones: Bones, salt?: string, _index?: number): void {
  const c = RARITY_STYLE[bones.rarity];
  const cb = RARITY_BOLD[bones.rarity];
  const re = RARITY_EMOJI[bones.rarity];
  const W = 25;

  // Terminal column width — accounts for wide chars (emoji, stars, box-drawing)
  const colWidth = (s: string) => {
    let w = 0;
    for (const ch of a.strip(s)) {
      const cp = ch.codePointAt(0)!;
      // Emoji and misc symbols: 2 columns
      if (cp >= 0x1F000 || cp === 0x2728 || cp === 0x2728) w += 2;
      // Stars ★ (U+2605) and other dingbats: 1 col in most terminals
      else w += 1;
    }
    return w;
  };
  const pad = (s: string, w: number) => s + " ".repeat(Math.max(0, w - colWidth(s)));

  const hr  = c("─".repeat(W));
  const edge = (l: string, r: string) => ` ${c(l)}${hr}${c(r)}`;
  const row = (content: string) => ` ${c("│")} ${pad(content, W - 1)}${c("│")}`;

  // Sprite
  const sprite = SPRITES[bones.species] ?? [" ???  ", " ???  ", " ???  "];
  const eyeSprite = sprite[1]!.replace(/\./g, bones.eye);

  console.log(edge("╭", "╮"));

  // Header: rarity badge
  const shiny = bones.shiny ? " ✨" : "";
  console.log(row(cb(`${re} ${bones.rarity.toUpperCase()} ${RARITY_STARS[bones.rarity]}${shiny}`)));
  console.log(edge("├", "┤"));

  // Creature: hat + sprite
  const hatLine = bones.hat !== "none" ? HAT_LINES[bones.hat] : undefined;
  if (hatLine) console.log(row(c(pad(hatLine, W - 1))));
  console.log(row(c(pad(sprite[0]!, W - 1))));
  console.log(row(c(pad(eyeSprite, W - 1))));
  console.log(row(c(pad(sprite[2]!, W - 1))));

  // Species + traits
  const hatStr = bones.hat !== "none" ? bones.hat : "";
  console.log(row(`${a.bold(bones.species)} ${a.dim(`${bones.eye} ${hatStr}`)}`));
  console.log(edge("├", "┤"));

  // Stats
  for (const [stat, val] of Object.entries(bones.stats)) {
    const bw = 10;
    const filled = Math.round((val / 100) * bw);
    const bar = c("━".repeat(filled)) + a.dim("╌".repeat(bw - filled));
    const peak = val >= 80, dump = val <= 15;
    const mk = peak ? c("▲") : dump ? a.dim("▼") : " ";
    console.log(row(`${a.dim(stat.substring(0, 3))} ${bar} ${a.bold(val.toString().padStart(3))}${mk}`));
  }

  // Salt
  if (salt) {
    console.log(edge("├", "┤"));
    console.log(row(`${a.dim("salt")} ${a.bold(salt)}`));
  }

  console.log(edge("╰", "╯"));
}

// ═══════════════════════════════════════════════════════════════════════════════
// CLI
// ═══════════════════════════════════════════════════════════════════════════════

function printHelp(): void {
  console.log(`
${a.bold.open}better-buddy forge${a.reset} — Find your perfect companion salt

${a.bold.open}USAGE${a.reset}
  bun run forge.ts [options]

${a.bold.open}OPTIONS${a.reset}
  --uuid <id>        Your account UUID or userID (required)
  --current          Show your current companion and exit
  --species <name>   Target species (${SPECIES.join(", ")})
  --rarity <name>    Target rarity (${RARITIES.join(", ")})
  --eye <char>       Target eye style (${EYES.join(" ")})
  --hat <name>       Target hat (${HATS.join(", ")})
  --shiny            Require shiny (1% chance — increases search time ~100×)
  --no-shiny         Require NOT shiny
  --min-<stat> <n>   Minimum stat value (e.g., --min-chaos 80)
  --count <n>        Number of matches to find (default: 5)
  --max <n>          Maximum attempts in millions (default: 500)
  --help             Show this help

${a.bold.open}FINDING YOUR UUID${a.reset}
  Your Claude config is at one of:
    ~/.claude/.config
    ~/.claude.json
    $CLAUDE_CONFIG_DIR/.claude.json (if CLAUDE_CONFIG_DIR is set)

  Look for: oauthAccount.accountUuid (OAuth users)
  Or:       userID (non-OAuth users)

${a.bold.open}EXAMPLES${a.reset}
  # See what you currently have
  bun run forge.ts --uuid "your-uuid-here" --current

  # Find a legendary shiny dragon with crown
  bun run forge.ts --uuid "your-uuid-here" --species dragon --rarity legendary --eye ✦ --hat crown --shiny

  # Find any epic creature with high chaos
  bun run forge.ts --uuid "your-uuid-here" --rarity epic --min-chaos 80

  # Just want a cat, don't care about anything else
  bun run forge.ts --uuid "your-uuid-here" --species cat --count 3

${a.bold.open}RARITY WEIGHTS${a.reset}
  common 60% │ uncommon 25% │ rare 10% │ epic 4% │ legendary 1%

${a.bold.open}AFTER FORGING${a.reset}
  Use patch.sh to apply your chosen salt to the Claude binary:
    ./patch.sh --salt "YOUR_15_CHAR_SALT"
`);
}

// Parse args
const { values } = parseArgs({
  args: process.argv.slice(2),
  options: {
    uuid:       { type: "string" },
    current:    { type: "boolean", default: false },
    species:    { type: "string" },
    rarity:     { type: "string" },
    eye:        { type: "string" },
    hat:        { type: "string" },
    shiny:      { type: "boolean" },
    "no-shiny": { type: "boolean" },
    "min-debugging": { type: "string" },
    "min-patience":  { type: "string" },
    "min-chaos":     { type: "string" },
    "min-wisdom":    { type: "string" },
    "min-snark":     { type: "string" },
    count:      { type: "string", default: "5" },
    max:        { type: "string", default: "500" },
    help:       { type: "boolean", default: false },
  },
  strict: true,
});

if (values.help) {
  printHelp();
  process.exit(0);
}

// ── Try to auto-detect UUID ──────────────────────────────────────────────────
function autoDetectUuid(): string | null {
  const paths = [
    `${process.env.HOME}/.claude/.config`,
    `${process.env.HOME}/.claude.json`,
  ];
  // Add CLAUDE_CONFIG_DIR if set (e.g., custom Claude Code config directory)
  if (process.env.CLAUDE_CONFIG_DIR) {
    paths.push(`${process.env.CLAUDE_CONFIG_DIR}/.claude.json`);
  }
  for (const p of paths) {
    try {
      const data = JSON.parse(require("fs").readFileSync(p, "utf8"));
      if (data.oauthAccount?.accountUuid) return data.oauthAccount.accountUuid;
      if (data.userID) return data.userID;
    } catch {}
  }
  return null;
}

let uuid = values.uuid;
if (!uuid) {
  uuid = autoDetectUuid();
  if (uuid) {
    console.log(a.dim(`Auto-detected UUID: ${uuid}\n`));
  } else {
    console.error("❌ Could not auto-detect your UUID. Pass --uuid YOUR_UUID");
    console.error("   Find it in: ~/.claude/.config → oauthAccount.accountUuid or userID");
    process.exit(1);
  }
}

// ── Show current ─────────────────────────────────────────────────────────────
if (values.current) {
  renderCard(generate(uuid, ORIGINAL_SALT));
  process.exit(0);
}

// ── Validate desired traits ──────────────────────────────────────────────────
const desired: {
  species: Species | null;
  rarity: Rarity | null;
  eye: Eye | null;
  hat: Hat | null;
  shiny: boolean | null;
  minStats: Record<string, number>;
} = {
  species: null,
  rarity: null,
  eye: null,
  hat: null,
  shiny: null,
  minStats: {},
};

if (values.species) {
  if (!SPECIES.includes(values.species as Species)) {
    console.error(`❌ Unknown species: ${values.species}`);
    console.error(`   Options: ${SPECIES.join(", ")}`);
    process.exit(1);
  }
  desired.species = values.species as Species;
}

if (values.rarity) {
  if (!RARITIES.includes(values.rarity as Rarity)) {
    console.error(`❌ Unknown rarity: ${values.rarity}`);
    console.error(`   Options: ${RARITIES.join(", ")}`);
    process.exit(1);
  }
  desired.rarity = values.rarity as Rarity;
}

if (values.eye) {
  if (!EYES.includes(values.eye as Eye)) {
    console.error(`❌ Unknown eye: ${values.eye}`);
    console.error(`   Options: ${EYES.join(" ")}`);
    process.exit(1);
  }
  desired.eye = values.eye as Eye;
}

if (values.hat) {
  if (!HATS.includes(values.hat as Hat)) {
    console.error(`❌ Unknown hat: ${values.hat}`);
    console.error(`   Options: ${HATS.join(", ")}`);
    process.exit(1);
  }
  desired.hat = values.hat as Hat;
}

if (values.shiny) desired.shiny = true;
if (values["no-shiny"]) desired.shiny = false;

for (const stat of STAT_NAMES) {
  const key = `min-${stat.toLowerCase()}` as keyof typeof values;
  const val = values[key];
  if (val) {
    const n = parseInt(val as string, 10);
    if (isNaN(n) || n < 0 || n > 100) {
      console.error(`❌ Invalid min-${stat.toLowerCase()}: ${val} (must be 0-100)`);
      process.exit(1);
    }
    desired.minStats[stat] = n;
  }
}

// Check at least one constraint
const hasConstraint = desired.species || desired.rarity || desired.eye ||
  desired.hat || desired.shiny !== null || Object.keys(desired.minStats).length > 0;

if (!hasConstraint) {
  console.error("❌ No traits specified. Use --species, --rarity, --eye, --hat, --shiny, or --min-<stat>.");
  console.error("   Run with --help to see options, or --current to see your current companion.");
  process.exit(1);
}

// ── Search ───────────────────────────────────────────────────────────────────
const FIND_COUNT = parseInt(values.count!, 10);
const MAX_ATTEMPTS = parseInt(values.max!, 10) * 1_000_000;
const REPORT_EVERY = 5_000_000;

function matches(bones: Bones): boolean {
  if (desired.species !== null && bones.species !== desired.species) return false;
  if (desired.rarity !== null && bones.rarity !== desired.rarity) return false;
  if (desired.eye !== null && bones.eye !== desired.eye) return false;
  if (desired.hat !== null && bones.hat !== desired.hat) return false;
  if (desired.shiny !== null && bones.shiny !== desired.shiny) return false;
  for (const [stat, min] of Object.entries(desired.minStats)) {
    if ((bones.stats[stat as StatName] ?? 0) < min) return false;
  }
  return true;
}

function estimateOdds(): string {
  let p = 1;
  if (desired.species) p *= 1 / SPECIES.length;
  if (desired.rarity) p *= RARITY_WEIGHTS[desired.rarity] / 100;
  if (desired.eye) p *= 1 / EYES.length;
  if (desired.hat) p *= 1 / HATS.length;
  if (desired.shiny === true) p *= 0.01;
  else if (desired.shiny === false) p *= 0.99;
  return `~1 in ${Math.round(1 / p).toLocaleString()}`;
}

const CHARS = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_";
function randomSalt(): string {
  let s = "";
  const bytes = randomBytes(15);
  for (let i = 0; i < 15; i++) s += CHARS[bytes[i]! % CHARS.length];
  return s;
}

// ── Banner ───────────────────────────────────────────────────────────────────

// ── Search banner ────────────────────────────────────────────────────────────

const targetParts: string[] = [];
if (desired.rarity) targetParts.push(desired.rarity);
if (desired.shiny === true) targetParts.push("shiny");
if (desired.species) targetParts.push(desired.species);
if (desired.eye) targetParts.push(`${desired.eye} eyes`);
if (desired.hat && desired.hat !== "none") targetParts.push(desired.hat);
for (const [s, v] of Object.entries(desired.minStats)) {
  if (v > 0) targetParts.push(`${s.substring(0,3).toLowerCase()}≥${v}`);
}

console.log(a.dim(`searching for ${a.bold(targetParts.join(" "))} · odds ${estimateOdds()} · max ${(MAX_ATTEMPTS / 1_000_000).toFixed(0)}M\n`));

// ── Run ──────────────────────────────────────────────────────────────────────

const results: { salt: string; bones: Bones }[] = [];
const start = performance.now();

for (let i = 1; i <= MAX_ATTEMPTS; i++) {
  const salt = randomSalt();
  const bones = generate(uuid, salt);

  if (matches(bones)) {
    results.push({ salt, bones });
    renderCard(bones, salt, results.length);
    if (results.length >= FIND_COUNT) break;
  }

  if (i % REPORT_EVERY === 0) {
    const elapsed = ((performance.now() - start) / 1000).toFixed(1);
    const rate = Math.round(i / ((performance.now() - start) / 1000));
    console.log(
      a.dim(`  ${(i / 1_000_000).toFixed(0)}M attempts | ${elapsed}s | ${rate.toLocaleString()}/sec | ${results.length} found`),
    );
  }
}

const totalElapsed = ((performance.now() - start) / 1000).toFixed(1);

if (results.length === 0) {
  console.log(a.dim(`\nno matches in ${(MAX_ATTEMPTS / 1_000_000).toFixed(0)}M attempts (${totalElapsed}s) — try relaxing constraints`));
} else {
  console.log(a.dim(`${results.length} found in ${totalElapsed}s`));
}
