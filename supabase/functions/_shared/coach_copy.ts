import {
  assertCardCopy,
  type CardCopyGuard,
  CardCopyViolation,
} from "./card_copy.ts";
import type { CoachMode } from "./coach_persona.ts";

/// Safety and voice guard for every string the coach writes (persona §9).
/// assertNeutralGeneratedCopy stays on data surfaces; this guard allows the
/// first person and the name Shudo, and instead blocks what matters for a
/// coach: slurs, compensation advice, medical claims, unverified numbers.

export type CoachProfanity = "off" | "mild" | "salty";
export type CoachSafetyFlag = "none" | "wellbeing" | "medical" | "injury";

export type CoachCopyCode =
  | "slur"
  | "sexual"
  | "insult"
  | "extreme_diet"
  | "medical"
  | "politics"
  | "impersonation"
  | "profanity_level"
  | "emoji"
  | "unverified_figure"
  | "stale_time"
  | "tic"
  | "url"
  | "contact"
  | "format"
  | "length"
  | "machinery"
  | "preamble"
  | "verbose";

/// Codes that only shape the voice. Everything else is a safety failure that
/// must never reach the thread.
export const SOFT_COACH_COPY_CODES: ReadonlySet<CoachCopyCode> = new Set([
  "tic",
]);

/// Voice codes: worth one rewrite, but copy that fails only these is still
/// safe to show, so a failed rewrite keeps it instead of going silent.
export const VOICE_COACH_COPY_CODES: ReadonlySet<CoachCopyCode> = new Set([
  "tic",
  "machinery",
  "preamble",
  "verbose",
]);

export class CoachCopyViolation extends Error {
  constructor(
    readonly code: CoachCopyCode,
    readonly field: string,
    detail = "",
  ) {
    super(
      `Coach copy violation ${code} in ${field}${detail ? `: ${detail}` : ""}`,
    );
  }
}

export type CoachCopyPolicy = {
  mode: CoachMode;
  profanity: CoachProfanity;
  emojiAllowed: boolean;
  /// Numbers the copy may cite (context pack figures plus staples). Any
  /// number with a cal/g/lb/kg unit must sit within ±10% of one of these.
  allowedFigures: readonly number[];
  /// True when push_body may reach the lock screen.
  pushCapable: boolean;
  /// Chat "why" answers may run to 900 characters.
  longForm?: boolean;
  /// Off only for server-grounded card text whose numbers come from data.
  verifyFigures?: boolean;
  /// Genuine milestones may carry one exclamation point.
  milestone?: boolean;
  /// False checks safety and hard limits only (voice codes are skipped).
  voice?: boolean;
};

export type CoachRenderOutput = {
  skip: boolean;
  bubbles: string[];
  push_body: string | null;
  day_theme?: string | null;
  safety_flag?: CoachSafetyFlag;
};

export const COACH_BUBBLE_MAX_CHARS = 280;
/// Lock-screen line: aim for 90, past 110 earns one rewrite, 150 is the
/// hard stop.
export const COACH_PUSH_TARGET_CHARS = 90;
export const COACH_PUSH_VOICE_CHARS = 110;
export const COACH_PUSH_MAX_CHARS = 150;

const MODE_LIMITS: Record<CoachMode, { total: number; bubbles: number }> = {
  chat_reply: { total: 600, bubbles: 3 },
  checkpoint_nudge: { total: 400, bubbles: 2 },
  morning_plan: { total: 400, bubbles: 2 },
  nightly_closeout: { total: 400, bubbles: 2 },
  checkin_ack: { total: 350, bubbles: 2 },
  profile_update: { total: 350, bubbles: 2 },
  snack_recommendation: { total: 350, bubbles: 2 },
  workout_ack: { total: 200, bubbles: 1 },
  meal_ack: { total: 200, bubbles: 1 },
};

/// Text-message length per mode. Past this it reads like an essay and gets
/// one rewrite; the hard limits above still bind.
export const MODE_VOICE_LIMITS: Record<CoachMode, number> = {
  chat_reply: 360,
  checkpoint_nudge: 220,
  morning_plan: 300,
  nightly_closeout: 300,
  checkin_ack: 260,
  profile_update: 260,
  snack_recommendation: 260,
  workout_ack: 160,
  meal_ack: 160,
};

const SLUR_PATTERN =
  /\b(?:fag(?:got)?s?|retard(?:ed|s)?|tranny|trannies|nigg(?:a|er)s?|spics?|chinks?|kikes?|dykes?|wetbacks?|pussy|pussies|bitch(?:es|y)?|cunts?|whores?|sluts?|twats?|dick(?:head)?s?)\b/iu;
const SEXUAL_PATTERN =
  /\b(?:sexy|sexual|horny|porn\w*|nudes?|naked|get(?:ting)? laid|hook ?up|boobs|tits|booty|thicc|(?:chicks|girls|ladies|women)\s+(?:will|are gonna|gonna|love|dig|notice))\b/iu;
const INSULT_PATTERNS = [
  /\byou(?:'re|’re| are| look| looked|'ve gotten| have gotten)\s+(?:so |such |really |too |kind of |a )?(?:fat|disgusting|pathetic|worthless|lazy|soft|weak|skinny|scrawny|tiny|ugly|gross|a (?:loser|failure|slob|joke|mess))\b/iu,
  /\byou\s+(?:dumbass|jackass|asshole|idiot|moron|loser|piece of shit|lazy ass|fat ass)\b/iu,
  /\b(?:fuck|screw)\s+(?:you|off)\b/iu,
];
const EXTREME_DIET_PATTERNS = [
  /\bskip(?:ping)?\s+(?:breakfast|lunch|dinner|a meal|meals|eating)\b/iu,
  /\bdon['’]?t eat (?:anything|until|after|till)\b/iu,
  /\bfast(?:ing)?\s+(?:until|till|for \d)/iu,
  /\bwater cut/iu,
  /\bburn (?:it|that|them) off\b/iu,
  /\bearn (?:your|that|the) (?:food|meal|meals|carbs|calories|dinner|pizza)\b/iu,
  /\bmake up for (?:it|that|yesterday|today)\b/iu,
  /\beat (?:it |that |them )?back\b/iu,
  /\bstarv/iu,
  /\bpurg/iu,
  /\blaxative/iu,
  /\bdiuretic/iu,
  /\bthrow(?:ing)? up\b/iu,
  /\beat until (?:you['’]re |you are )?sick\b/iu,
  /\bfat burner/iu,
  /\bdiet pill/iu,
];
const MEDICAL_PATTERN =
  /\b(?:diagnos\w*|prescri\w*|medication\w*|insulin|thyroid|testosterone|trt|steroids?|sarms?|peptides?|glp-?1|semaglutide|ozempic|tirzepatide|\d+\s?(?:mg|mcg|iu)\b)/iu;
const DOSING_PATTERN =
  /\b\d+(?:\.\d+)?\s?(?:g|grams?|scoops?)\s+(?:of\s+)?(?:creatine|caffeine|pre-?workout)\b/iu;
const MEDICAL_REFERRAL_PATTERN =
  /\b(?:doctor|get it (?:checked|looked at)|professional|physician|clinic)\b/iu;
const MEDICAL_ASSERTION_PATTERN =
  /\byou (?:probably |likely |might |may )?have\b/iu;
const POLITICS_PATTERN =
  /\b(?:democrats?|republicans?|liberals?|leftists?|woke|maga|trump|biden|harris|feminis\w*|alpha males?|beta males?|sigma|red ?pill\w*|manosphere|conservatives?)\b/iu;
const IMPERSONATION_PATTERNS = [
  /\b(?:i['’]?m|i am|this is)\s+sam\b/iu,
  /\bsulek\s+(?:says|said|would say)\b/iu,
  /\bas sam (?:would|always) say/iu,
];
const MILD_PROFANITY_PATTERN =
  /\b(?:damn(?:ed|it)?|dammit|hell|shit(?:ty|s)?|bullshit|ass(?:es)?|badass|half-?assed|hardass|crap(?:py)?|piss(?:ed)?)\b/giu;
const SALTY_PROFANITY_PATTERN =
  /\b(?:fuck\w*|motherfuck\w*|goddamn\w*|bastards?)\b/giu;
const STALE_TIME_PATTERN = /\b(?:right now|just now|just logged)\b/iu;
const TIC_PATTERN =
  /\b(?:let['’]?s go|you got this|crush(?:ed|ing)? it|beast mode|grind(?:ing)?|no excuses|journey|fuel your body|great job|don['’]?t forget|bro|king|champ|buddy|my guy)\b/iu;
const URL_PATTERN = /(?:https?:\/\/|www\.)/iu;
/// The coach reacts; he never narrates the machinery: tools, models, saving
/// and logging mechanics, estimates in flight, IDs, or confidence scores.
/// A bare "Logged." is a reaction, not narration, and stays allowed.
const MACHINERY_PATTERNS = [
  /\bI(?:['’]ve| have| just| already|['’]ll| will| went ahead and)?\s+(?:logged|log|recorded|record|saved|save|stored|store|noted|note|filed|file|queued|queue|updated|update)\b/iu,
  /\b(?:logged|saved|stored|noted|filed|recorded)\s+(?:it|that|this|them)\s+for you\b/iu,
  /\b(?:saved|stored|added|noted|filed|logged|put)\s+(?:it\s+|that\s+|this\s+)?(?:to|in|into|under)\s+(?:your|my|the)\s+(?:bio|memory|notes|profile|file|records?|database|system)\b/iu,
  /\bmy\s+(?:memory|notes|database|records|context|system|tools?)\b/iu,
  /\b(?:tool calls?|function calls?|language model|context pack|live state|system (?:note|prompt|message))\b/iu,
  /\b(?:Claude|Sonnet|Anthropic|OpenAI|ChatGPT|GPT|LLM|API|JSON)\b/u,
  /\b(?:estimat(?:e|es)\s+(?:lands?|comes? in|will|is (?:still )?(?:coming|pending|in progress))|(?:still |currently |now )(?:estimating|analy[sz]ing|processing|crunching)|in the background|once (?:the )?(?:analysis|estimate) (?:is )?(?:done|finishes|lands|comes in))\b/iu,
  /\bconfidence\s+(?:score|level|rating)\b|\b\d{1,3}\s?%\s+(?:confiden\w*|sure|certain)\b/iu,
  /\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b/iu,
  /\b(?:entry|activity|message|meal|request|run)[_ ]id\b/iu,
];
/// Assistant throat-clearing at the start of a text.
const PREAMBLE_PATTERN =
  /^(?:(?:great|good|fair|nice)\s+question\b|(?:sure|of course|absolutely|certainly|definitely|happy to help|no problem)\s*[,.!:—–-]|(?:sure thing|understood|will do)\b|(?:thanks|thank you) for (?:sharing|letting me know|the update|telling me)\b|here(?:['’]s| is) (?:the|your|a) (?:plan|breakdown|rundown|summary|update)\b|(?:ok|okay|alright),? so\b)/iu;

/// Drops assistant throat-clearing from the start of a text ("Great
/// question! Eat at 3." → "Eat at 3."). Text that is only a preamble stays.
export function stripPreamble(text: string): string {
  const trimmed = text.trim();
  const match =
    /^(?:(?:great|good|fair|nice)\s+question|sure thing|sure|of course|absolutely|certainly|definitely|happy to help|no problem|understood|will do|(?:ok|okay|alright),? so)\s*[.!,:—–-]*\s*/iu
      .exec(trimmed);
  if (!match || !PREAMBLE_PATTERN.test(trimmed)) return trimmed;
  const rest = trimmed.slice(match[0].length).trim();
  if (rest.length < 2) return trimmed;
  return rest.charAt(0).toUpperCase() + rest.slice(1);
}
const PHONE_PATTERN = /\(?\b\d{3}\)?[\s.-]\d{3}[\s.-]\d{4}\b/u;
const FORMAT_PATTERNS = [
  /\*\*|__/u,
  /(?:^|\n)\s*#{1,6}\s/u,
  /(?:^|\n)\s*[-*•]\s+\S/u,
  /(?:^|\n)\s*\d+[.)]\s+\S/u,
  /(?:^|\s)#[A-Za-z]\w*/u,
];
const EMOJI_PATTERN = /\p{Extended_Pictographic}/gu;
const EMOJI_ALLOWLIST = new Set(["👊", "🔥", "🥩"]);

/// Number + unit, e.g. "2,900 cal", "170g", "~380 cal", "0.4 lb".
const FIGURE_PATTERN =
  /(?<![\w.,])(\d{1,3}(?:,\d{3})+|\d+(?:\.\d+)?)\s?(kcal|calories|calorie|cals?|grams?|g|lbs?|pounds?|kgs?|kilos?)\b/giu;

type FigureUnit = "energy" | "grams" | "weight";

function figureUnit(raw: string): FigureUnit {
  const unit = raw.toLowerCase();
  if (unit.startsWith("k") && unit !== "kcal") return "weight";
  if (unit === "kcal" || unit.startsWith("cal")) return "energy";
  if (unit === "g" || unit.startsWith("gram")) return "grams";
  return "weight";
}

const ABSOLUTE_TOLERANCE: Record<FigureUnit, number> = {
  energy: 10,
  grams: 2,
  weight: 0.5,
};

/** Every figure with a unit in `text` that no allowed number supports. */
export function unverifiedFigures(
  text: string,
  allowedFigures: readonly number[],
): string[] {
  const failures: string[] = [];
  for (const match of text.matchAll(FIGURE_PATTERN)) {
    const value = Number(match[1].replaceAll(",", ""));
    if (!Number.isFinite(value)) continue;
    const tolerance = ABSOLUTE_TOLERANCE[figureUnit(match[2])];
    const supported = allowedFigures.some((allowed) =>
      Number.isFinite(allowed) &&
      Math.abs(value - allowed) <= Math.max(Math.abs(allowed) * 0.1, tolerance)
    );
    if (!supported) failures.push(match[0]);
  }
  return failures;
}

function profanityCounts(text: string): { mild: number; salty: number } {
  return {
    mild: [...text.matchAll(MILD_PROFANITY_PATTERN)].length,
    salty: [...text.matchAll(SALTY_PROFANITY_PATTERN)].length,
  };
}

/** Normalizes model text: trims, drops bracketed stamps, collapses spaces. */
export function sanitizeCoachText(value: string): string {
  return value
    .replace(/\r\n?/gu, "\n")
    .split("\n")
    .map((line) =>
      line.replace(/^\s*\[[^\]\n]{1,40}\]\s*/u, "").replace(/[ \t]+/gu, " ")
        .trimEnd()
    )
    .join("\n")
    .replace(/\n{3,}/gu, "\n\n")
    .trim();
}

/** Splits a reply into at most `max` bubbles at blank lines. */
export function splitBubbles(value: string, max = 3): string[] {
  const parts = sanitizeCoachText(value).split(/\n\s*\n/u)
    .map((part) => part.replace(/\s*\n\s*/gu, " ").trim())
    .filter(Boolean);
  if (parts.length <= max) return parts;
  return [...parts.slice(0, max - 1), parts.slice(max - 1).join(" ")];
}

function checkText(
  text: string,
  field: string,
  policy: CoachCopyPolicy,
  push: boolean,
): CoachCopyViolation | null {
  if (SLUR_PATTERN.test(text)) return new CoachCopyViolation("slur", field);
  if (SEXUAL_PATTERN.test(text)) return new CoachCopyViolation("sexual", field);
  if (INSULT_PATTERNS.some((pattern) => pattern.test(text))) {
    return new CoachCopyViolation("insult", field);
  }
  if (EXTREME_DIET_PATTERNS.some((pattern) => pattern.test(text))) {
    return new CoachCopyViolation("extreme_diet", field);
  }
  if (DOSING_PATTERN.test(text)) {
    return new CoachCopyViolation("medical", field, "dosing");
  }
  if (MEDICAL_PATTERN.test(text)) {
    if (
      push || !MEDICAL_REFERRAL_PATTERN.test(text) ||
      MEDICAL_ASSERTION_PATTERN.test(text)
    ) {
      return new CoachCopyViolation("medical", field);
    }
  }
  if (POLITICS_PATTERN.test(text)) {
    return new CoachCopyViolation("politics", field);
  }
  if (IMPERSONATION_PATTERNS.some((pattern) => pattern.test(text))) {
    return new CoachCopyViolation("impersonation", field);
  }
  const profanity = profanityCounts(text);
  const total = profanity.mild + profanity.salty;
  if (
    (policy.profanity === "off" && total > 0) ||
    (policy.profanity === "mild" && profanity.salty > 0) ||
    total > 1 ||
    (push && profanity.salty > 0)
  ) {
    return new CoachCopyViolation("profanity_level", field);
  }
  const emoji = [...text.matchAll(EMOJI_PATTERN)].map((match) => match[0]);
  if (
    emoji.length > 0 &&
    (!policy.emojiAllowed || emoji.length > 1 ||
      !emoji.every((value) => EMOJI_ALLOWLIST.has(value)))
  ) {
    return new CoachCopyViolation("emoji", field);
  }
  if (URL_PATTERN.test(text)) return new CoachCopyViolation("url", field);
  if (PHONE_PATTERN.test(text)) return new CoachCopyViolation("contact", field);
  if (FORMAT_PATTERNS.some((pattern) => pattern.test(text))) {
    return new CoachCopyViolation("format", field);
  }
  const unverified = policy.verifyFigures === false
    ? []
    : unverifiedFigures(text, policy.allowedFigures);
  if (unverified.length > 0) {
    return new CoachCopyViolation(
      "unverified_figure",
      field,
      unverified.slice(0, 3).join(", "),
    );
  }
  if (push && STALE_TIME_PATTERN.test(text)) {
    return new CoachCopyViolation("stale_time", field);
  }
  if (policy.voice === false) return null;
  if (MACHINERY_PATTERNS.some((pattern) => pattern.test(text))) {
    return new CoachCopyViolation("machinery", field);
  }
  if (PREAMBLE_PATTERN.test(text.trim())) {
    return new CoachCopyViolation("preamble", field);
  }
  const exclamations = [...text.matchAll(/!/gu)].length;
  const allowedExclamations = policy.milestone || policy.mode === "chat_reply"
    ? 1
    : 0;
  if (
    TIC_PATTERN.test(text) || exclamations > allowedExclamations ||
    [...text.matchAll(/\?/gu)].length > 1
  ) {
    return new CoachCopyViolation("tic", field);
  }
  return null;
}

/** The first violation in a rendered message, or null when it is clean. */
export function coachCopyViolation(
  output: CoachRenderOutput,
  policy: CoachCopyPolicy,
): CoachCopyViolation | null {
  if (output.skip) return null;
  const limits = MODE_LIMITS[policy.mode];
  const total = policy.mode === "chat_reply" && policy.longForm
    ? 900
    : limits.total;
  if (output.bubbles.length === 0) {
    return new CoachCopyViolation("length", "bubbles", "empty");
  }
  if (output.bubbles.length > limits.bubbles) {
    return new CoachCopyViolation("length", "bubbles", "too many bubbles");
  }
  let characters = 0;
  for (const [index, bubble] of output.bubbles.entries()) {
    const field = `bubbles[${index}]`;
    const length = Array.from(bubble).length;
    characters += length;
    if (!bubble.trim()) return new CoachCopyViolation("length", field, "empty");
    // Chat "why" answers may run longer in each bubble; totals still bind.
    const bubbleLimit = policy.mode === "chat_reply" && policy.longForm
      ? 450
      : COACH_BUBBLE_MAX_CHARS;
    if (length > bubbleLimit) return new CoachCopyViolation("length", field);
    const violation = checkText(bubble, field, policy, false);
    if (violation) return violation;
  }
  if (characters > total) {
    return new CoachCopyViolation(
      "length",
      "bubbles",
      `${characters} > ${total}`,
    );
  }
  if (output.push_body !== null) {
    const push = output.push_body;
    if (
      !push.trim() || Array.from(push).length > COACH_PUSH_MAX_CHARS ||
      /[\r\n]/u.test(push)
    ) {
      return new CoachCopyViolation("length", "push_body");
    }
    const violation = checkText(push, "push_body", policy, true);
    if (violation) return violation;
  }
  if (output.day_theme) {
    if (Array.from(output.day_theme).length > 80) {
      return new CoachCopyViolation("length", "day_theme");
    }
    const violation = checkText(output.day_theme, "day_theme", policy, false);
    if (violation) return violation;
  }
  if (policy.voice !== false) {
    const voiceLimit = policy.mode === "chat_reply" && policy.longForm
      ? total
      : MODE_VOICE_LIMITS[policy.mode];
    if (characters > voiceLimit) {
      return new CoachCopyViolation(
        "verbose",
        "bubbles",
        `${characters} > ${voiceLimit}`,
      );
    }
    if (
      output.push_body !== null &&
      Array.from(output.push_body).length > COACH_PUSH_VOICE_CHARS
    ) {
      return new CoachCopyViolation(
        "verbose",
        "push_body",
        `${Array.from(output.push_body).length} > ${COACH_PUSH_VOICE_CHARS}`,
      );
    }
  }
  return null;
}

/**
 * Safety first, voice second: null when clean, the safety violation when
 * there is one, otherwise the voice violation (safe to show if a rewrite
 * can't fix it).
 */
export function coachCopyReview(
  output: CoachRenderOutput,
  policy: CoachCopyPolicy,
): { safety: CoachCopyViolation | null; voice: CoachCopyViolation | null } {
  const safety = coachCopyViolation(output, { ...policy, voice: false });
  if (safety) return { safety, voice: null };
  return { safety: null, voice: coachCopyViolation(output, policy) };
}

/** Throws CoachCopyViolation unless the message passes every rule. */
export function assertCoachCopy(
  output: CoachRenderOutput,
  policy: CoachCopyPolicy,
): CoachRenderOutput {
  const violation = coachCopyViolation(output, policy);
  if (violation) throw violation;
  return output;
}

/** Guard for one standalone string (a card line, a recap body). */
export function assertCoachText(
  text: string,
  policy: CoachCopyPolicy,
  field = "text",
): string {
  const violation = checkText(text, field, policy, false);
  if (violation) throw violation;
  return text;
}

/// Safety-only subset for internal coach memory (digests, notes): voice
/// rules don't apply, but compensation, insults and medical claims never get
/// stored for a later prompt to repeat.
export function coachMemorySafetyViolation(text: string): CoachCopyCode | null {
  if (SLUR_PATTERN.test(text)) return "slur";
  if (INSULT_PATTERNS.some((pattern) => pattern.test(text))) return "insult";
  if (EXTREME_DIET_PATTERNS.some((pattern) => pattern.test(text))) {
    return "extreme_diet";
  }
  if (POLITICS_PATTERN.test(text)) return "politics";
  if (URL_PATTERN.test(text)) return "url";
  return null;
}

/// The one voice guard for card text written by the Train / Body / Nearby
/// workloads (plan intro, physique note, snack headline): their structural
/// card rules (length, body-fat guesses, body shaming) plus every coach copy
/// rule. Numbers on cards are server-grounded, so figures aren't re-verified.
export const coachCardCopyGuard: CardCopyGuard = (text, field, options) => {
  const value = assertCardCopy(text, field, options);
  const violation = checkText(value, field, {
    mode: "snack_recommendation",
    profanity: options.profanity ?? "off",
    emojiAllowed: false,
    allowedFigures: [],
    pushCapable: false,
    verifyFigures: false,
  }, false);
  if (violation) throw new CardCopyViolation(violation.code, field);
  return value;
};
