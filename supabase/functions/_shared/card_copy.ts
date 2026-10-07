/// Voice block and a conservative guard for the coach-voiced fields that the
/// Train / Body / Nearby workloads write into cards (plan intro, physique
/// note, snack headline). The full persona and `assertCoachCopy` belong to the
/// coach-brain lane; every entry point here accepts an injected guard so the
/// shared one can replace `assertCardCopy` without touching these modules.

export type Profanity = "off" | "mild" | "salty";

/// Condensed from the coach persona (voice bible §1, §3). Stable text only:
/// no names, dates or numbers, so it stays a cacheable system prefix.
export const CARD_VOICE = [
  "Voice: you are Shudo, an old-school, warm, dry-humored strength coach texting one lifter in his own app. Write in first person, plain American English, short sentences, fragments fine.",
  "Lead with the point or the number. At most one question. No exclamation points, emojis, hashtags, markdown, lists, or links.",
  "Never use 'bro', 'king', 'champ', 'buddy', or 'my guy'. Skip hype clichés: let's go, you got this, crush it, beast mode, grind, no excuses, journey, fuel your body, great job.",
  "Praise is specific and earned. Criticism targets behavior, never who he is or how he looks.",
  "Hard lines: never push skipped meals, fasting, compensation, 'earning' or 'burning off' food, or eating past discomfort. No medical claims, diagnoses, medication, supplements beyond protein powder, creatine and pre-workout per the label. No politics, religion, or culture-war framing. Never claim to be a real person.",
  "Use only numbers present in the provided data. Keep it clean: no profanity in card text.",
].join("\n");

export class CardCopyViolation extends Error {
  constructor(readonly code: string, readonly field: string) {
    super(`Card copy rejected (${code}) in ${field}`);
  }
}

export type CardCopyOptions = { maxChars: number; profanity?: Profanity };
export type CardCopyGuard = (
  text: string,
  field: string,
  options: CardCopyOptions,
) => string;

const URL_PATTERN = /https?:\/\/|www\./iu;
const EMOJI_PATTERN = /\p{Extended_Pictographic}/u;
const MARKDOWN_PATTERN = /(^|\n)\s*(?:[-*•]\s|#{1,6}\s|\d+[.)]\s)|\*\*|__|`/u;
const BANNED_ADDRESS_PATTERN = /\b(?:bro|king|champ|buddy|my guy)\b/iu;
const POLITICS_PATTERN =
  /\b(?:democrat|republican|liberal|leftist|woke|maga|trump|biden|feminis\w*|alpha male|beta male|sigma|red ?pill|manosphere)\b/iu;
const EXTREME_DIET_PATTERN =
  /\b(?:skip(?:ping)? (?:breakfast|lunch|dinner|a meal|meals)|don['’]?t eat (?:anything|until|after)|fast(?:ing)? (?:until|till|for \d)|water cut|burn (?:it|that) off|earn (?:your|that) (?:food|meal|carbs)|make up for it|starv\w*|purg\w*|laxative\w*|diuretic\w*|throw(?:ing)? up|eat until (?:you['’]re )?sick|fat burner\w*|diet pill\w*)\b/iu;
const MEDICAL_PATTERN =
  /\b(?:diagnos\w*|prescri\w*|medication\w*|insulin|thyroid|testosterone|trt|steroid\w*|sarms?|peptide\w*|glp-?1|semaglutide|ozempic|gyno\w*|gynecomastia|\d+\s?mg)\b/iu;
const BODY_SHAMING_PATTERN =
  /\b(?:ugly|gross|disgusting|pathetic|worthless|flabby|chubby|scrawny|puny|skinny[- ]fat|fatass|lard|blubber|beer belly|moobs|man boobs|sexy|hot body|attractive|unattractive|handsome|genital\w*|penis|bulge|crotch)\b/iu;
const INSULT_PATTERN =
  /\byou(?:['’]re| are| look)\s+(?:so |a |like a )?(?:fat|disgusting|pathetic|worthless|lazy|soft|weak|a (?:loser|failure|slob))\b/iu;
const BODY_FAT_GUESS_PATTERN =
  /\b\d{1,2}\s?%\s*(?:body ?fat|bf)\b|\bbody ?fat\b[^.]{0,20}\d{1,2}\s?%/iu;
const MILD_PROFANITY = /\b(?:damn|hell|shit\w*|ass|crap)\b/iu;
const STRONG_PROFANITY = /\bf+u+c+k\w*|\bmotherf\w*|\bcunt\b|\bbitch\w*/iu;
const CLICHE_PATTERN =
  /\b(?:let['’]?s go|you got this|crush(?:ing)? it|beast mode|no excuses|fuel your body|great job)\b/iu;

/** Throws CardCopyViolation; returns the trimmed text when it passes. */
export function assertCardCopy(
  text: string,
  field: string,
  options: CardCopyOptions,
): string {
  const value = (text ?? "").replace(/\s+/g, " ").trim();
  const fail = (code: string): never => {
    throw new CardCopyViolation(code, field);
  };
  if (!value) fail("empty");
  if (Array.from(value).length > options.maxChars) fail("length");
  if (URL_PATTERN.test(value)) fail("url");
  if (EMOJI_PATTERN.test(value)) fail("emoji");
  if (value.includes("!")) fail("exclamation");
  if (MARKDOWN_PATTERN.test(text)) fail("markdown");
  if (BANNED_ADDRESS_PATTERN.test(value)) fail("address");
  if (POLITICS_PATTERN.test(value)) fail("politics");
  if (EXTREME_DIET_PATTERN.test(value)) fail("extreme_diet");
  if (MEDICAL_PATTERN.test(value)) fail("medical");
  if (BODY_SHAMING_PATTERN.test(value) || INSULT_PATTERN.test(value)) {
    fail("body_shaming");
  }
  if (BODY_FAT_GUESS_PATTERN.test(value)) fail("body_fat_guess");
  if (STRONG_PROFANITY.test(value)) fail("profanity");
  if ((options.profanity ?? "off") === "off" && MILD_PROFANITY.test(value)) {
    fail("profanity");
  }
  if (CLICHE_PATTERN.test(value)) fail("cliche");
  return value;
}

/** Runs the guard; returns the fallback (already safe) text on violation. */
export function guardedCopy(
  guard: CardCopyGuard,
  text: unknown,
  field: string,
  options: CardCopyOptions,
  fallback: string,
): string {
  if (typeof text !== "string") return fallback;
  try {
    return guard(text, field, options);
  } catch (error) {
    if (error instanceof CardCopyViolation) {
      console.warn("card_copy_rejected", { field, code: error.code });
    } else {
      console.warn("card_copy_rejected", { field });
    }
    return fallback;
  }
}

/** True when the text passes the guard (list items are filtered with this). */
export function passesCardCopy(
  guard: CardCopyGuard,
  text: unknown,
  field: string,
  options: CardCopyOptions,
): text is string {
  if (typeof text !== "string") return false;
  try {
    guard(text, field, options);
    return true;
  } catch {
    return false;
  }
}
