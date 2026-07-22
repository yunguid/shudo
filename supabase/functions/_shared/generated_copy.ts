export const NEUTRAL_PRODUCT_COPY_INSTRUCTION =
  "Write as neutral product copy. Never speak as Shudo, mention Shudo as a person, or use I/we/my/our as the writer.";

// Generated product copy never needs to name the product as a speaker. Rejecting
// the name itself also covers new personifying verbs without maintaining a
// fragile verb allowlist (for example, "Shudo observed" or "Shudo advises").
const PRODUCT_SPEAKER_PATTERN = /\bshudo\b/iu;

// Catch writer voice rather than every pronoun occurrence so a food or brand
// name containing "I" or "My" is not rejected. Keeping this non-global makes
// repeated validations deterministic in Deno.
const FIRST_PERSON_WRITER_PATTERN =
  /\b(?:(?:i|we)(?:['’](?:d|ll|m|re|ve))?\s+(?:(?:can|could|did|do|had|have|should|will|would)\s+)?(?:am|are|believ(?:e|es|ed|ing)|calculat(?:e|es|ed|ing)|cho(?:ose|se|sen|osing)|estimat(?:e|es|ed|ing)|finds?|found|notic(?:e|es|ed|ing)|observ(?:e|es|ed|ing)|recommend(?:s|ed|ing)?|see|suggest(?:s|ed|ing)?|think(?:s|ing)?|thought)|(?:my|our)\s+(?:analysis|assessment|calculation|estimate|finding|observation|recommendation|summary|suggestion|view))\b/iu;

const GENERIC_PERSONIFIED_PRODUCT_PATTERN =
  /\b(?:the\s+)?(?:app|product|tracker)\s+(?:advis(?:e|es|ed|ing)|believ(?:e|es|ed|ing)|calculat(?:e|es|ed|ing)|finds?|found|notic(?:e|es|ed|ing)|observ(?:e|es|ed|ing)|recommend(?:s|ed|ing)?|sa(?:y|ys|id)|suggest(?:s|ed|ing)?|think(?:s|ing)?|thought|want(?:s|ed|ing)?)\b/iu;

export function assertNeutralGeneratedCopy(
  value: string,
  label: string,
): string {
  if (
    PRODUCT_SPEAKER_PATTERN.test(value) ||
    FIRST_PERSON_WRITER_PATTERN.test(value) ||
    GENERIC_PERSONIFIED_PRODUCT_PATTERN.test(value)
  ) {
    throw new Error(`Invalid ${label}: personified product copy`);
  }
  return value;
}
