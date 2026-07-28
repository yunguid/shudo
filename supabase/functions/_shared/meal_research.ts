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
  /\b(?:look\s*up|look\s+(?:it|this|that|them)\s+up|google|browse|research)\b/i,
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

/// Copy contract with the iOS client (EntryResearchPresentation in
/// shudo/NativeExperiencePolicies.swift). The client parses these exact
/// strings out of analysis_notes to render provenance; change them together.
export const RESEARCH_SOURCES_PREFIX = "Online sources: ";
export const RESEARCH_VERIFIED_LINKLESS_DISCLOSURE =
  "Checked against online sources.";
export const RESEARCH_UNAVAILABLE_DISCLOSURE =
  "Online lookup was unavailable, so these nutrition values are estimates rather than verified restaurant facts.";
export const RESEARCH_EMPTY_DISCLOSURE =
  "No authoritative online nutrition source was found, so unverified values are clearly treated as estimates.";

const MAX_NOTES_CHARACTERS = 1_000;
const MAX_SOURCE_LINE_CHARACTERS = 760;
const MAX_LINKED_SOURCE_URL_CHARACTERS = 360;
const MAX_LINKED_SOURCES = 3;

function unicodePrefix(value: string, maxCharacters: number): string {
  return Array.from(value).slice(0, maxCharacters).join("");
}

function markdownUrl(value: string): string {
  return value.replaceAll("(", "%28").replaceAll(")", "%29");
}

/**
 * Builds the sources line so it always fits the notes budget whole: overlong
 * URLs are skipped and links stop before the line could ever be truncated
 * mid-markdown, which would render as broken syntax on the client.
 */
function sourceLinks(sources: WebSearchSource[]): string {
  let line = "";
  let linked = 0;
  for (const { url } of sources) {
    if (linked >= MAX_LINKED_SOURCES) break;
    if (Array.from(url).length > MAX_LINKED_SOURCE_URL_CHARACTERS) continue;
    const hostname = new URL(url).hostname.replace(/^www\./, "");
    const link = `[${hostname}](${markdownUrl(url)})`;
    const candidate = line ? `${line}, ${link}` : link;
    if (
      Array.from(RESEARCH_SOURCES_PREFIX + candidate).length + 1 >
        MAX_SOURCE_LINE_CHARACTERS
    ) break;
    line = candidate;
    linked += 1;
  }
  return line;
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

  const verified = research.used && !research.degraded &&
    research.sources.length > 0;
  let disclosure: string;
  if (research.degraded || !research.used) {
    disclosure = RESEARCH_UNAVAILABLE_DISCLOSURE;
  } else if (research.sources.length === 0) {
    disclosure = RESEARCH_EMPTY_DISCLOSURE;
  } else {
    const links = sourceLinks(research.sources);
    disclosure = links
      ? `${RESEARCH_SOURCES_PREFIX}${links}.`
      : RESEARCH_VERIFIED_LINKLESS_DISCLOSURE;
  }
  // The disclosure is the point of the research feature, so it gets the notes
  // budget first and the model's prose is trimmed to whatever remains. Links
  // are never cut mid-markdown.
  const proseBudget = Math.max(
    0,
    Math.min(
      650,
      MAX_NOTES_CHARACTERS - Array.from(disclosure).length - 2,
    ),
  );
  const existing = unicodePrefix(
    verified ? escapeMarkdown(modelNotes ?? "") : modelNotes ?? "",
    proseBudget,
  );
  const notes = [existing, disclosure].filter(Boolean).join("\n\n");

  if (verified) {
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
