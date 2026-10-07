import type { SupabaseClient } from "jsr:@supabase/supabase-js@2.110.7";
import {
  assertCardCopy,
  CARD_VOICE,
  type CardCopyGuard,
  guardedCopy,
  passesCardCopy,
  type Profanity,
} from "./card_copy.ts";
import {
  type Anthropic,
  type BetaContentBlockParam,
  callClaudeStructured,
  CLAUDE_MODELS,
  type ClaudeEffort,
  ClaudeRefusalError,
  describeClaudeError,
  imageFromBase64,
  systemBlocks,
} from "./claude.ts";
import {
  addDays,
  claimCoachRun,
  type ClaimedRun,
  completeCoachRun,
  daysBetween,
  failCoachRun,
  failureMessage,
  isLocalDay,
  localDayIn,
  LostRunLeaseError,
  POUNDS_PER_KG,
} from "./fenced_run.ts";

export const PHYSIQUE_MODEL = CLAUDE_MODELS.opus;
export const PHYSIQUE_EFFORT: ClaudeEffort = "high";
export const PHYSIQUE_TIMEOUT_MS = 120_000;
export const PHYSIQUE_BUCKET = "weight-checkin-photos";
/// Photos are downscaled on the phone (≤1600 px JPEG). Anything larger than
/// this is skipped rather than resized here (Edge CPU is precious); base64 of
/// this stays under the API's 5 MB per-image limit.
export const MAX_PHOTO_BYTES = 3_700_000;
/// Comparison targets: label → days before the anchor and the ± tolerance.
export const COMPARISON_TARGETS = [
  { label: "1w", days: 7, tolerance: 3 },
  { label: "4w", days: 28, tolerance: 5 },
  { label: "12w", days: 84, tolerance: 10 },
] as const;
/// How stale the "current" photo may be relative to the anchor day.
const ANCHOR_LOOKBACK_DAYS = 6;
const HISTORY_DAYS = 95;
const PHYSIQUE_TOOL = "submit_physique_review";

export const PHYSIQUE_REFUSED_HEADLINE = "Couldn't get a clean read this time";
export const PHYSIQUE_REFUSED_MESSAGE =
  "Couldn't get a clean read on this photo. Same spot, same light, same pose next time and I'll take another look.";
export const PHYSIQUE_PUSH_BODY =
  "Your weekly physique check is in. Take a look when you have a minute.";

export type ComparisonLabel = typeof COMPARISON_TARGETS[number]["label"];
export type Region =
  | "shoulders"
  | "chest"
  | "arms"
  | "back"
  | "waist"
  | "abs"
  | "legs"
  | "posture"
  | "overall";
const REGIONS: readonly Region[] = [
  "shoulders",
  "chest",
  "arms",
  "back",
  "waist",
  "abs",
  "legs",
  "posture",
  "overall",
];
export type Change = "bigger" | "leaner" | "similar" | "softer" | "unclear";
const CHANGES: readonly Change[] = [
  "bigger",
  "leaner",
  "similar",
  "softer",
  "unclear",
];
export type BulkQuality =
  | "clean"
  | "on_track"
  | "watch_waist"
  | "too_slow"
  | "unclear";
const BULK_QUALITIES: readonly BulkQuality[] = [
  "clean",
  "on_track",
  "watch_waist",
  "too_slow",
  "unclear",
];
const COMPARED_TO = ["today", "1w", "4w", "12w"] as const;
const CONFIDENCES = ["low", "medium", "high"] as const;

export type PhysiqueObservation = {
  region: Region;
  change: Change;
  compared_to: typeof COMPARED_TO[number];
  evidence: string;
  confidence: typeof CONFIDENCES[number];
};

export type PhysiqueReview = {
  comparability: { rating: "good" | "fair" | "poor"; issues: string[] };
  observations: PhysiqueObservation[];
  bulk_quality: BulkQuality;
  headline: string;
  coach_note: string;
  focus_next_week: string[];
  photo_tips: string[];
};

// ---------------------------------------------------------------------------
// Photo selection
// ---------------------------------------------------------------------------

export type CheckinRow = {
  id: string;
  local_day: string;
  weight_kg: number | string | null;
  progress_photo_path: string | null;
};

export type SelectedPhoto = {
  label: "today" | ComparisonLabel;
  checkin: CheckinRow;
};

/** Latest photo check-in on/before the anchor day, within the lookback. */
export function pickAnchorCheckin(
  anchorDay: string,
  rows: CheckinRow[],
): CheckinRow | null {
  const earliest = addDays(anchorDay, -ANCHOR_LOOKBACK_DAYS);
  return rows
    .filter((row) =>
      row.progress_photo_path && row.local_day <= anchorDay &&
      row.local_day >= earliest
    )
    .sort((left, right) => right.local_day.localeCompare(left.local_day))[0] ??
    null;
}

/** Closest photo to ~7/28/84 days before the anchor, each used once. */
export function pickComparisonPhotos(
  anchor: CheckinRow,
  rows: CheckinRow[],
): SelectedPhoto[] {
  const used = new Set<string>([anchor.id]);
  const selected: SelectedPhoto[] = [];
  for (const target of COMPARISON_TARGETS) {
    let best: { row: CheckinRow; distance: number } | null = null;
    for (const row of rows) {
      if (!row.progress_photo_path || used.has(row.id)) continue;
      const before = daysBetween(row.local_day, anchor.local_day);
      if (before <= 0) continue;
      const distance = Math.abs(before - target.days);
      if (distance > target.tolerance) continue;
      if (
        !best || distance < best.distance ||
        (distance === best.distance && row.local_day > best.row.local_day)
      ) {
        best = { row, distance };
      }
    }
    if (best) {
      used.add(best.row.id);
      selected.push({ label: target.label, checkin: best.row });
    }
  }
  return selected;
}

/// `<uid>/<day>/progress-<uuid>.jpg` → `<uuid>` (the body_review run key).
export function photoIdFromPath(path: string): string | null {
  const match =
    /\/progress-([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\.jpg$/
      .exec(path);
  return match?.[1] ?? null;
}

export function bytesToBase64(bytes: Uint8Array): string {
  let binary = "";
  const chunk = 0x8000;
  for (let offset = 0; offset < bytes.length; offset += chunk) {
    binary += String.fromCharCode(...bytes.subarray(offset, offset + chunk));
  }
  return btoa(binary);
}

function isJpeg(bytes: Uint8Array): boolean {
  return bytes.length > 3 && bytes[0] === 0xff && bytes[1] === 0xd8 &&
    bytes[2] === 0xff;
}

async function downloadPhoto(
  admin: SupabaseClient,
  path: string,
): Promise<string | null> {
  const { data, error } = await admin.storage.from(PHYSIQUE_BUCKET).download(
    path,
  );
  if (error || !data) return null;
  const bytes = new Uint8Array(await data.arrayBuffer());
  if (bytes.length === 0 || bytes.length > MAX_PHOTO_BYTES || !isJpeg(bytes)) {
    return null;
  }
  return bytesToBase64(bytes);
}

// ---------------------------------------------------------------------------
// Output validation
// ---------------------------------------------------------------------------

function asRecord(value: unknown): Record<string, unknown> {
  return value && typeof value === "object" && !Array.isArray(value)
    ? value as Record<string, unknown>
    : {};
}

function enumValue<T extends string>(
  value: unknown,
  allowed: readonly T[],
): T | null {
  return typeof value === "string" &&
      (allowed as readonly string[]).includes(value)
    ? value as T
    : null;
}

function cleanText(value: unknown, maxCharacters: number): string | null {
  if (typeof value !== "string") return null;
  const text = value.replace(/\s+/g, " ").trim();
  return text ? Array.from(text).slice(0, maxCharacters).join("") : null;
}

function guardedList(
  guard: CardCopyGuard,
  value: unknown,
  field: string,
  maxItems: number,
  maxChars: number,
): string[] {
  const items = Array.isArray(value) ? value : [];
  return items
    .map((item) => cleanText(item, maxChars))
    .filter((item): item is string =>
      item !== null && passesCardCopy(guard, item, field, { maxChars })
    )
    .slice(0, maxItems);
}

/**
 * Enforces the review contract the API cannot: list and length caps, enum
 * values, and the respectful-body copy guard. List items that fail the guard
 * are dropped; a failing headline or note falls back to a safe template.
 */
export function sanitizePhysiqueReview(
  payload: unknown,
  guard: CardCopyGuard,
  profanity: Profanity,
): PhysiqueReview {
  const raw = asRecord(payload);
  const comparability = asRecord(raw.comparability);
  const observations: PhysiqueObservation[] = [];
  for (
    const observationPayload of Array.isArray(raw.observations)
      ? raw.observations
      : []
  ) {
    if (observations.length >= 6) break;
    const observation = asRecord(observationPayload);
    const region = enumValue(observation.region, REGIONS);
    const change = enumValue(observation.change, CHANGES);
    const evidence = cleanText(observation.evidence, 200);
    if (
      !region || !change || !evidence ||
      !passesCardCopy(guard, evidence, "physique.evidence", { maxChars: 200 })
    ) {
      continue;
    }
    observations.push({
      region,
      change,
      compared_to: enumValue(observation.compared_to, COMPARED_TO) ?? "today",
      evidence,
      confidence: enumValue(observation.confidence, CONFIDENCES) ?? "low",
    });
  }
  const rating =
    enumValue(comparability.rating, ["good", "fair", "poor"] as const) ??
      "fair";
  return {
    comparability: {
      rating,
      issues: guardedList(
        guard,
        comparability.issues,
        "physique.issues",
        3,
        160,
      ),
    },
    observations,
    bulk_quality: enumValue(raw.bulk_quality, BULK_QUALITIES) ?? "unclear",
    headline: guardedCopy(
      guard,
      cleanText(raw.headline, 400),
      "physique.headline",
      { maxChars: 120, profanity: "off" },
      rating === "poor"
        ? "Hard to compare this week"
        : "Weekly physique check is in",
    ),
    coach_note: guardedCopy(
      guard,
      cleanText(raw.coach_note, 2_000),
      "physique.coach_note",
      { maxChars: 600, profanity },
      "Photo's logged. The trend over weeks is what counts, so keep the same spot, same light, same pose, and keep eating.",
    ),
    focus_next_week: guardedList(
      guard,
      raw.focus_next_week,
      "physique.focus",
      3,
      160,
    ),
    photo_tips: guardedList(
      guard,
      raw.photo_tips,
      "physique.photo_tips",
      3,
      160,
    ),
  };
}

// ---------------------------------------------------------------------------
// Prompt
// ---------------------------------------------------------------------------

export const PHYSIQUE_SYSTEM = [
  "You review progress photos for one adult man who submits them himself, in underwear, in the same pose each day, to track his own lean bulk in his training app. This is a non-sexual fitness analysis for his own progress tracking.",
  "Look only from the neck down. Ignore the face, identity, tattoos, the room, and anything else not related to training. Never identify him or comment on who he is.",
  "Comment only on training-relevant features: shoulder and delt cap, chest fullness, arm size, lat and back width, waist and lower-ab softness, posture, symmetry, and legs if visible.",
  "Never comment on genitals, attractiveness, skin, moles, hair, or anything medical or sexual. Never estimate body-fat percentage. Never compare him to other people or to ideal bodies. Describe visible change neutrally.",
  "Lighting, pump, water, and pose shift day to day. Rate comparability honestly, name the issues, lower confidence when photos don't line up, and never invent change. If no change is visible yet, say so plainly.",
  "On a bulk, size in the shoulders, chest, arms, and back is the goal. Use watch_waist when the waist looks like it is growing faster than the shoulders and chest; too_slow when nothing has changed over four or more weeks and the weight trend is flat; unclear when the photos can't support a call.",
  "Up to 6 observations, each with short visible evidence. compared_to says which image the change is measured against ('today' for single-photo notes). focus_next_week: up to 3 behavioral levers (training, food, sleep). photo_tips: up to 3 ways to make the next photo more comparable.",
  "headline: at most 100 characters, plain. coach_note: at most 500 characters in Shudo's voice, honest and encouraging, about effort, habits, and the trend, never about how he looks as a person.",
  CARD_VOICE,
  `Finish by calling ${PHYSIQUE_TOOL} exactly once.`,
].join("\n");

export const PHYSIQUE_RESPONSE_SCHEMA = {
  type: "object",
  additionalProperties: false,
  properties: {
    comparability: {
      type: "object",
      additionalProperties: false,
      properties: {
        rating: { type: "string", enum: ["good", "fair", "poor"] },
        issues: { type: "array", items: { type: "string" } },
      },
      required: ["rating", "issues"],
    },
    observations: {
      type: "array",
      items: {
        type: "object",
        additionalProperties: false,
        properties: {
          region: { type: "string", enum: [...REGIONS] },
          change: { type: "string", enum: [...CHANGES] },
          compared_to: { type: "string", enum: [...COMPARED_TO] },
          evidence: { type: "string" },
          confidence: { type: "string", enum: [...CONFIDENCES] },
        },
        required: ["region", "change", "compared_to", "evidence", "confidence"],
      },
    },
    bulk_quality: { type: "string", enum: [...BULK_QUALITIES] },
    headline: { type: "string" },
    coach_note: { type: "string" },
    focus_next_week: { type: "array", items: { type: "string" } },
    photo_tips: { type: "array", items: { type: "string" } },
  },
  required: [
    "comparability",
    "observations",
    "bulk_quality",
    "headline",
    "coach_note",
    "focus_next_week",
    "photo_tips",
  ],
} as const;

function toNumber(value: unknown): number | null {
  const number = typeof value === "string" ? Number(value) : value;
  return typeof number === "number" && Number.isFinite(number) ? number : null;
}

function formatWeight(kg: number | null, imperial: boolean): string | null {
  if (kg === null) return null;
  return imperial
    ? `${Math.round(kg * POUNDS_PER_KG * 10) / 10} lb`
    : `${Math.round(kg * 10) / 10} kg`;
}

const LABEL_TEXT: Record<SelectedPhoto["label"], string> = {
  today: "this check-in",
  "1w": "about 1 week earlier",
  "4w": "about 4 weeks earlier",
  "12w": "about 12 weeks earlier",
};

// ---------------------------------------------------------------------------
// Entry point
// ---------------------------------------------------------------------------

export type PhysiqueReviewDependencies = {
  client?: Anthropic;
  now?: () => number;
  timeoutMs?: number;
  copyGuard?: CardCopyGuard;
};

type PhysiqueProfile = {
  timezone: string | null;
  units: string | null;
  goal_type: string | null;
  weight_kg: number | string | null;
  target_weight_kg: number | string | null;
  physique_ai_review_enabled: boolean | null;
  coach_profanity: string | null;
};

/**
 * Weekly or on-demand physique review (Opus, high effort, vision). Requires
 * the user's opt-in (`physique_ai_review_enabled`; the run ledger enforces it
 * too). Sends base64 photos fetched with the service role — the current
 * check-in plus the closest to ~7/28/84 days earlier — saves the result on
 * the check-in via `save_body_review`, and posts a `photo_feedback` card. A
 * model refusal is stored as a failed review with a friendly message and is
 * never retried. Other failures fail the run and rethrow.
 */
export async function reviewPhysique(
  admin: SupabaseClient,
  userId: string,
  input: { anchorDay: string; kind: "weekly" | "on_demand" },
  dependencies: PhysiqueReviewDependencies = {},
): Promise<void> {
  if (!isLocalDay(input.anchorDay)) {
    throw new Error("anchorDay must be YYYY-MM-DD");
  }
  const now = dependencies.now ?? Date.now;
  const guard = dependencies.copyGuard ?? assertCardCopy;

  const { data: profileData, error: profileError } = await admin.from(
    "profiles",
  )
    .select(
      "timezone,units,goal_type,weight_kg,target_weight_kg,physique_ai_review_enabled,coach_profanity",
    )
    .eq("user_id", userId)
    .maybeSingle();
  if (profileError) throw profileError;
  const profile = profileData as PhysiqueProfile | null;
  if (!profile?.physique_ai_review_enabled) {
    console.info("physique_review_skipped", { reason: "disabled" });
    return;
  }

  const { data: rowsData, error: rowsError } = await admin.from(
    "weight_checkins",
  )
    .select("id,local_day,weight_kg,progress_photo_path")
    .eq("user_id", userId)
    .gte("local_day", addDays(input.anchorDay, -HISTORY_DAYS))
    .lte("local_day", input.anchorDay)
    .order("local_day", { ascending: false })
    .limit(120);
  if (rowsError) throw rowsError;
  const rows = (rowsData ?? []) as CheckinRow[];
  const anchor = pickAnchorCheckin(input.anchorDay, rows);
  const anchorPhotoId = anchor?.progress_photo_path
    ? photoIdFromPath(anchor.progress_photo_path)
    : null;
  if (!anchor || !anchorPhotoId) {
    console.info("physique_review_skipped", { reason: "no_recent_photo" });
    return;
  }

  const claim = await claimCoachRun(admin, {
    userId,
    operation: "body_review",
    localDay: anchor.local_day,
    checkpointKey: `body_review:${anchorPhotoId}`,
    triggerSource: input.kind === "weekly" ? "schedule" : "user",
    leaseSeconds: 300,
    now,
  });
  if (!claim.claimed) {
    console.info("physique_review_skipped", { reason: claim.status });
    return;
  }
  const run: ClaimedRun = claim.run;
  const imperial = profile.units !== "metric";
  const profanity: Profanity = profile.coach_profanity === "salty"
    ? "salty"
    : profile.coach_profanity === "off"
    ? "off"
    : "mild";
  const today = localDayIn(profile.timezone, new Date(now()));
  const anchorPath = anchor.progress_photo_path!;
  const anchorWeightKg = toNumber(anchor.weight_kg);

  const post = async (
    review: Record<string, unknown>,
    body: string,
    card: Record<string, unknown>,
    result: { model: string | null; messageId: string | null },
  ) => {
    const { data: saved, error: saveError } = await admin.rpc(
      "save_body_review",
      {
        p_run_id: run.runId,
        p_claim_token: run.claimToken,
        p_checkin_id: anchor.id,
        p_review: review,
        p_model: result.model,
      },
    );
    if (saveError) throw saveError;
    if (saved !== "saved") throw new LostRunLeaseError("Physique review");
    const notify = input.kind === "weekly";
    await completeCoachRun(admin, run, {
      result: {
        checkin_id: anchor.id,
        status: review.status,
        bulk_quality:
          (review.result as PhysiqueReview | undefined)?.bulk_quality ??
            null,
      },
      messages: [{
        kind: "photo_feedback",
        body,
        local_day: today,
        notify,
        payload: {
          local_day: anchor.local_day,
          photo_path: anchorPath,
          weight_kg: anchorWeightKg,
          review_kind: input.kind,
          review: card,
          ...(notify ? { push_body: PHYSIQUE_PUSH_BODY } : {}),
        },
      }],
      model: result.model,
      providerResponseId: result.messageId,
      label: "Physique review",
    });
  };

  try {
    const comparisons = pickComparisonPhotos(anchor, rows);
    const selected: SelectedPhoto[] = [
      { label: "today", checkin: anchor },
      ...comparisons,
    ];
    const downloads = await Promise.all(
      selected.map(async (photo) => ({
        photo,
        base64: await downloadPhoto(admin, photo.checkin.progress_photo_path!),
      })),
    );
    if (!downloads[0].base64) {
      throw new Error("Current check-in photo is unavailable");
    }
    const usable = downloads.filter((item) => item.base64);

    const content: BetaContentBlockParam[] = [];
    usable.forEach((item, index) => {
      const weight = formatWeight(
        toNumber(item.photo.checkin.weight_kg),
        imperial,
      );
      content.push({
        type: "text",
        text: `Image ${index + 1}: ${
          LABEL_TEXT[item.photo.label]
        } (${item.photo.checkin.local_day}${
          weight ? `, weigh-in ${weight}` : ""
        })`,
      });
      content.push(imageFromBase64(item.base64!));
    });
    const weights = rows
      .filter((row) =>
        toNumber(row.weight_kg) !== null &&
        row.local_day >= addDays(anchor.local_day, -28)
      )
      .map((row) => ({
        day: row.local_day,
        weight: formatWeight(toNumber(row.weight_kg), imperial),
      }))
      .slice(0, 28);
    content.push({
      type: "text",
      text: [
        `Review type: ${
          input.kind === "weekly" ? "weekly check" : "requested now"
        }.`,
        `Goal: ${
          profile.goal_type === "gain"
            ? "lean bulk"
            : profile.goal_type ?? "unknown"
        }; current ${
          formatWeight(toNumber(profile.weight_kg), imperial) ?? "unknown"
        }, target ${
          formatWeight(toNumber(profile.target_weight_kg), imperial) ??
            "unknown"
        }.`,
        weights.length
          ? `Weigh-ins over the last 4 weeks (data): ${JSON.stringify(weights)}`
          : "No weigh-ins yet (no scale); judge from photos and say how confident you can be.",
        usable.length === 1
          ? "Only the current photo is available: describe the starting point and set comparisons aside."
          : "Compare the current photo against the earlier ones.",
      ].join("\n"),
    });

    let review: PhysiqueReview;
    let model: string | null = null;
    let messageId: string | null = null;
    try {
      const result = await callClaudeStructured({
        workload: "body_review",
        model: PHYSIQUE_MODEL,
        effort: PHYSIQUE_EFFORT,
        system: systemBlocks([{ text: PHYSIQUE_SYSTEM, cache: true }]),
        messages: [{ role: "user", content }],
        schema: PHYSIQUE_RESPONSE_SCHEMA,
        schemaName: PHYSIQUE_TOOL,
        maxTokens: 16_000,
        timeoutMs: dependencies.timeoutMs ?? PHYSIQUE_TIMEOUT_MS,
        client: dependencies.client,
      });
      review = sanitizePhysiqueReview(result.output, guard, profanity);
      model = result.model;
      messageId = result.messageId;
    } catch (callError) {
      if (callError instanceof ClaudeRefusalError) {
        console.warn("physique_review_refused", {
          category: callError.category,
        });
        await post(
          {
            status: "failed",
            error_code: "refused",
            message: PHYSIQUE_REFUSED_MESSAGE,
            kind: input.kind,
            photo_path: anchorPath,
            anchor_day: anchor.local_day,
            generated_at: new Date(now()).toISOString(),
          },
          PHYSIQUE_REFUSED_MESSAGE,
          {
            status: "failed",
            headline: PHYSIQUE_REFUSED_HEADLINE,
            observations: [],
            bulk_quality: "unclear",
          },
          { model: PHYSIQUE_MODEL, messageId: null },
        );
        return;
      }
      throw describeClaudeError(callError, "Physique review");
    }

    const compared = usable.slice(1).map((item) => ({
      label: item.photo.label,
      local_day: item.photo.checkin.local_day,
    }));
    await post(
      {
        status: "complete",
        kind: input.kind,
        photo_path: anchorPath,
        anchor_day: anchor.local_day,
        compared,
        result: review,
        headline: review.headline,
        coach_note: review.coach_note,
        generated_at: new Date(now()).toISOString(),
      },
      review.coach_note,
      {
        status: "complete",
        headline: review.headline,
        observations: review.observations,
        bulk_quality: review.bulk_quality,
        comparability: review.comparability.rating,
        focus_next_week: review.focus_next_week,
        photo_tips: review.photo_tips,
        compared,
      },
      { model, messageId },
    );
  } catch (error) {
    if (error instanceof LostRunLeaseError) {
      console.warn("physique_review_lease_lost", { runId: run.runId });
      return;
    }
    await failCoachRun(
      admin,
      run,
      failureMessage(error, "Physique review failed"),
    );
    throw error;
  }
}
