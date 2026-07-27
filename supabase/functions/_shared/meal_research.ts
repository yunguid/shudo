import type { ParsedAnalysis } from "./analysis.ts";

export type MealResearchMode = "none" | "optional" | "required";

export type WebSearchSource = {
  url: string;
};

export type MealResearchResult = {
  requested: boolean;
  used: boolean;
  degraded: boolean;
  sources: WebSearchSource[];
};

const EXPLICIT_LOOKUP_PATTERNS = [
  /\b(?:look\s*up|google|browse|research)\b/i,
  /\bsearch(?:\s+(?:online|the\s+web|the\s+internet|for))?\b/i,
  /\bcheck\s+(?:online|the\s+web|the\s+internet|the\s+(?:restaurant|menu|nutrition)\s+(?:site|website))\b/i,
  /\b(?:find|get|check)\b.{0,80}\b(?:nutrition(?:al)?(?:\s+facts?)?|calories?|macros?|menu\s+item)\b/i,
  /\b(?:online|on\s+the\s+web|on\s+the\s+internet|official\s+(?:menu|nutrition)|restaurant\s+website|nutrition\s+website)\b/i,
];

const RESTAURANT_CONTEXT_PATTERNS = [
  /\b(?:restaurant|menu\s+item|take[ -]?out|drive[ -]?thru|fast[ -]?food)\b/i,
  /\b(?:from|at|ordered\s+from)\s+(?:the\s+)?[\p{Lu}][\p{L}\p{N}&'’.\-]*(?:\s+[\p{Lu}][\p{L}\p{N}&'’.\-]*){0,3}/u,
  /\b[\p{Lu}][\p{L}]+(?:['’]s)\b/u,
];

const GROUNDED_LABEL_PATTERN =
  /\b(?:scanned\s+nutrition\s+label|nutrition\s+label\s+per\s+serving)\b/i;

/**
 * Routes only likely restaurant/current-information captures to web search.
 * Explicit lookup language is forced; restaurant cues make search available
 * while leaving the final choice to the model. Quoted barcode-label facts stay
 * on the existing fast path unless the user separately asks for research.
 */
export function mealResearchMode(
  description: string,
  analysisContext: string | null = null,
): MealResearchMode {
  const input = [description, analysisContext].filter(Boolean).join("\n")
    .trim();
  if (!input) return "none";
  if (EXPLICIT_LOOKUP_PATTERNS.some((pattern) => pattern.test(input))) {
    return "required";
  }
  if (GROUNDED_LABEL_PATTERN.test(input)) return "none";
  return RESTAURANT_CONTEXT_PATTERNS.some((pattern) => pattern.test(input))
    ? "optional"
    : "none";
}

function safeSourceUrl(value: unknown): string | null {
  if (typeof value !== "string" || value.length > 2_000) return null;
  try {
    const url = new URL(value);
    if (url.protocol !== "https:" && url.protocol !== "http:") return null;
    if (!url.hostname || url.username || url.password) return null;
    url.hash = "";
    return url.toString();
  } catch {
    return null;
  }
}

/** Extracts only safe URL metadata; retrieved titles and page text are untrusted. */
export function responseWebSearchMetadata(
  response: Record<string, unknown>,
): { used: boolean; sources: WebSearchSource[] } {
  let used = false;
  const urls = new Set<string>();
  const output = Array.isArray(response.output) ? response.output : [];
  for (const candidate of output) {
    if (
      !candidate || typeof candidate !== "object" || Array.isArray(candidate)
    ) {
      continue;
    }
    const item = candidate as Record<string, unknown>;
    if (item.type !== "web_search_call") continue;
    used = true;
    const action = item.action && typeof item.action === "object" &&
        !Array.isArray(item.action)
      ? item.action as Record<string, unknown>
      : null;
    const sourceCandidates = [
      ...(Array.isArray(action?.sources) ? action.sources : []),
      ...(Array.isArray(item.sources) ? item.sources : []),
    ];
    for (const sourceCandidate of sourceCandidates) {
      if (
        !sourceCandidate || typeof sourceCandidate !== "object" ||
        Array.isArray(sourceCandidate)
      ) continue;
      const source = sourceCandidate as Record<string, unknown>;
      const url = safeSourceUrl(source.url);
      if (url) urls.add(url);
    }
  }
  return {
    used,
    sources: Array.from(urls).slice(0, 5).map((url) => ({ url })),
  };
}

function unicodePrefix(value: string, maxCharacters: number): string {
  return Array.from(value).slice(0, maxCharacters).join("");
}

function markdownUrl(value: string): string {
  return value.replaceAll("(", "%28").replaceAll(")", "%29");
}

function sourceLinks(sources: WebSearchSource[]): string {
  return sources.slice(0, 3).map(({ url }) => {
    const hostname = new URL(url).hostname.replace(/^www\./, "");
    return `[${hostname}](${markdownUrl(url)})`;
  }).join(", ");
}

function modelNotesWithoutReservedSources(value: string | null): string | null {
  const notes = value?.split(/\n\s*Online sources:/i, 1)[0].trim() ?? "";
  return notes || null;
}

function escapeMarkdown(value: string): string {
  return value.replace(/https?:\/\/\S+/gi, "[link omitted]")
    .replace(/[\\`*_[\]<>]/g, "\\$&");
}

/**
 * Adds bounded, clickable provenance without changing the stored meal schema.
 * When research was unavailable or empty, confidence is capped and the notes
 * explicitly distinguish the result from verified restaurant nutrition.
 */
export function applyMealResearchResult(
  analysis: ParsedAnalysis,
  research: MealResearchResult,
): ParsedAnalysis {
  const modelNotes = modelNotesWithoutReservedSources(analysis.notes);
  const sanitizedAnalysis = modelNotes === analysis.notes
    ? analysis
    : { ...analysis, notes: modelNotes };
  if (!research.requested || (!research.used && !research.degraded)) {
    return sanitizedAnalysis;
  }

  let disclosure: string;
  if (research.degraded || !research.used) {
    disclosure =
      "Online lookup was unavailable, so these nutrition values are estimates rather than verified restaurant facts.";
  } else if (research.sources.length === 0) {
    disclosure =
      "No authoritative online nutrition source was found, so unverified values are clearly treated as estimates.";
  } else {
    disclosure = `Online sources: ${sourceLinks(research.sources)}.`;
  }
  const existing = unicodePrefix(
    research.sources.length > 0 && research.used && !research.degraded
      ? escapeMarkdown(modelNotes ?? "")
      : modelNotes ?? "",
    650,
  );
  const notes = unicodePrefix(
    [existing, disclosure].filter(Boolean).join("\n\n"),
    1_000,
  );

  if (research.used && research.sources.length > 0 && !research.degraded) {
    return { ...sanitizedAnalysis, notes };
  }
  return {
    ...sanitizedAnalysis,
    confidence: Math.min(analysis.confidence, 0.5),
    items: analysis.items.map((item) => ({
      ...item,
      confidence: Math.min(item.confidence, 0.5),
    })),
    notes,
  };
}
