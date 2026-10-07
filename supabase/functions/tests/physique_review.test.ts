import { assertCardCopy } from "../_shared/card_copy.ts";
import {
  bytesToBase64,
  type CheckinRow,
  photoIdFromPath,
  PHYSIQUE_PUSH_BODY,
  PHYSIQUE_REFUSED_MESSAGE,
  PHYSIQUE_SYSTEM,
  pickAnchorCheckin,
  pickComparisonPhotos,
  reviewPhysique,
  sanitizePhysiqueReview,
} from "../_shared/physique_review.ts";
import { assert, assertEquals } from "./assertions.ts";
import {
  fakeClaude,
  jsonTextEvents,
  messageEnd,
  messageStart,
  type RecordedRequest,
} from "./fake_claude.ts";
import { fakeAdmin, fakeLedger } from "./fake_rest_admin.ts";

const USER = "11111111-1111-4111-8111-111111111111";
const BUCKET = "weight-checkin-photos";

function photoPath(day: string, index: number): string {
  return `${USER}/${day}/progress-0000000${index}-aaaa-4aaa-8aaa-aaaaaaaaaaaa.jpg`;
}

function checkin(day: string, index: number, weightKg: number | null = null): CheckinRow {
  return {
    id: `c${index}`,
    local_day: day,
    weight_kg: weightKg,
    progress_photo_path: photoPath(day, index),
  };
}

const JPEG = new Uint8Array([0xff, 0xd8, 0xff, 0xe0, 1, 2, 3, 4]);

Deno.test("photo selection: latest recent anchor, closest ~1w/4w/12w comparisons", () => {
  const rows = [
    checkin("2026-10-05", 1, 74),
    checkin("2026-09-29", 2),
    checkin("2026-09-27", 3),
    checkin("2026-09-08", 4),
    checkin("2026-07-14", 5),
    checkin("2026-06-01", 6),
  ];
  const anchor = pickAnchorCheckin("2026-10-06", rows)!;
  assertEquals(anchor.id, "c1");
  const picked = pickComparisonPhotos(anchor, rows);
  assertEquals(picked.map((photo) => [photo.label, photo.checkin.id]), [
    ["1w", "c2"], // 6 days before beats 8 days before
    ["4w", "c4"],
    ["12w", "c5"],
  ]);
  // Nothing within six days of the anchor day → no review.
  assertEquals(pickAnchorCheckin("2026-10-20", rows), null);
  // A weight-only check-in is never the anchor.
  assertEquals(
    pickAnchorCheckin("2026-10-06", [{ ...checkin("2026-10-06", 7), progress_photo_path: null }]),
    null,
  );
});

Deno.test("photo ids come from the owned storage path; base64 is exact", () => {
  assertEquals(
    photoIdFromPath(photoPath("2026-10-05", 1)),
    "00000001-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
  );
  assertEquals(photoIdFromPath(`${USER}/2026-10-05/selfie.png`), null);
  assertEquals(bytesToBase64(new TextEncoder().encode("shudo")), btoa("shudo"));
});

function reviewOutput(overrides: Record<string, unknown> = {}) {
  return {
    comparability: { rating: "good", issues: [] },
    observations: [
      {
        region: "shoulders",
        change: "bigger",
        compared_to: "4w",
        evidence: "Delt caps look rounder against the 4-week photo.",
        confidence: "medium",
      },
      {
        region: "waist",
        change: "similar",
        compared_to: "4w",
        evidence: "Waist line looks about the same.",
        confidence: "medium",
      },
    ],
    bulk_quality: "on_track",
    headline: "Shoulders are filling out",
    coach_note:
      "Four weeks in and the delts are catching the light better while the waist holds. That's the bulk working. Keep the shakes coming and hit Upper A twice this week.",
    focus_next_week: ["Hit protein every day", "Add a set of lateral raises"],
    photo_tips: ["Same spot by the window, phone at hip height"],
    ...overrides,
  };
}

Deno.test("review sanitizer enforces caps, enums, and respectful body copy", () => {
  const review = sanitizePhysiqueReview(
    reviewOutput({
      observations: [
        ...reviewOutput().observations,
        {
          region: "abs",
          change: "softer",
          compared_to: "1w",
          evidence: "Looking flabby around the middle.",
          confidence: "high",
        },
        {
          region: "face",
          change: "bigger",
          compared_to: "1w",
          evidence: "Face looks fuller.",
          confidence: "high",
        },
      ],
      headline: "Looking sexy this week",
      coach_note: "You're about 14% body fat now.",
      focus_next_week: ["One", "Two", "Three", "Four"],
      bulk_quality: "legendary",
    }),
    assertCardCopy,
    "mild",
  );
  assertEquals(review.observations.length, 2);
  assertEquals(review.observations.map((item) => item.region), ["shoulders", "waist"]);
  assertEquals(review.headline, "Weekly physique check is in");
  assert(review.coach_note.startsWith("Photo's logged."));
  assertEquals(review.focus_next_week, ["One", "Two", "Three"]);
  assertEquals(review.bulk_quality, "unclear");
});

Deno.test("the physique prompt is neck-down, fitness-only, with no body-fat guesses", () => {
  assert(PHYSIQUE_SYSTEM.includes("Look only from the neck down"));
  assert(PHYSIQUE_SYSTEM.includes("non-sexual fitness analysis"));
  assert(PHYSIQUE_SYSTEM.includes("Never estimate body-fat percentage"));
  assert(PHYSIQUE_SYSTEM.includes("Never comment on genitals"));
});

function physiqueSetup(
  options: { enabled?: boolean; rows?: CheckinRow[]; claimStatus?: string } = {},
) {
  const ledger = fakeLedger({ claimStatus: options.claimStatus });
  const reviews: Array<Record<string, unknown>> = [];
  const rows = options.rows ?? [
    checkin("2026-10-05", 1, 74.0),
    checkin("2026-09-28", 2, 73.6),
    checkin("2026-09-08", 3, null),
  ];
  const objects: Record<string, Uint8Array> = {};
  for (const row of rows) {
    if (row.progress_photo_path) objects[row.progress_photo_path] = JPEG;
  }
  const fake = fakeAdmin({
    tables: {
      profiles: [{
        user_id: USER,
        timezone: "America/New_York",
        units: "imperial",
        goal_type: "gain",
        weight_kg: 73.71,
        target_weight_kg: 79.38,
        physique_ai_review_enabled: options.enabled ?? true,
        coach_profanity: "mild",
      }],
      weight_checkins: rows.map((row) => ({ ...row, user_id: USER })),
    },
    storage: { [BUCKET]: objects },
    rpc: {
      ...ledger.handlers,
      save_body_review(args) {
        reviews.push(args);
        return "saved";
      },
    },
  });
  return { ...fake, ledger, reviews };
}

Deno.test("weekly review sends labeled base64 photos to Opus and posts photo feedback", async () => {
  const env = physiqueSetup();
  const requests: RecordedRequest[] = [];
  await reviewPhysique(env.admin as never, USER, {
    anchorDay: "2026-10-06",
    kind: "weekly",
  }, { client: fakeClaude([jsonTextEvents(reviewOutput())], requests) });

  assertEquals(requests.length, 1);
  assertEquals(requests[0].model, "claude-opus-5-5");
  assertEquals((requests[0].output_config as { effort?: string }).effort, "high");
  const content = requests[0].messages?.[0].content as Array<Record<string, unknown>>;
  const images = content.filter((block) => block.type === "image");
  assertEquals(images.length, 3);
  const source = images[0].source as Record<string, unknown>;
  assertEquals(source.type, "base64");
  assertEquals(source.media_type, "image/jpeg");
  assertEquals(source.data, bytesToBase64(JPEG));
  // Labels precede images; no signed URL ever leaves the server.
  assertEquals(content[0].type, "text");
  assert(String(content[0].text).includes("this check-in (2026-10-05, weigh-in 163.1 lb)"));
  assert(!JSON.stringify(requests[0]).includes("https://storage.test"));
  assertEquals(
    env.storageCalls.filter((call) => call.operation === "sign").length,
    0,
  );

  const claim = env.ledger.claims[0];
  assertEquals(claim.p_operation, "body_review");
  assertEquals(claim.p_checkpoint_key, "body_review:00000001-aaaa-4aaa-8aaa-aaaaaaaaaaaa");
  assertEquals(claim.p_local_day, "2026-10-05");
  assertEquals(claim.p_trigger_source, "schedule");

  assertEquals(env.reviews.length, 1);
  assertEquals(env.reviews[0].p_checkin_id, "c1");
  const saved = env.reviews[0].p_review as Record<string, unknown>;
  assertEquals(saved.status, "complete");
  assertEquals(saved.photo_path, photoPath("2026-10-05", 1));
  assertEquals(
    (saved.compared as Array<Record<string, unknown>>).map((item) => item.label),
    ["1w", "4w"],
  );

  const messages = env.ledger.completed[0].p_messages as Array<Record<string, unknown>>;
  assertEquals(messages[0].kind, "photo_feedback");
  assertEquals(messages[0].notify, true);
  const payload = messages[0].payload as Record<string, unknown>;
  assertEquals(payload.push_body, PHYSIQUE_PUSH_BODY);
  assertEquals(payload.local_day, "2026-10-05");
  assertEquals(payload.weight_kg, 74);
  const review = payload.review as Record<string, unknown>;
  assertEquals(review.headline, "Shoulders are filling out");
  assertEquals(review.bulk_quality, "on_track");
  assert(String(messages[0].body).startsWith("Four weeks in"));
});

Deno.test("a refusal becomes a failed review with a friendly message, not a retry", async () => {
  const env = physiqueSetup();
  await reviewPhysique(env.admin as never, USER, {
    anchorDay: "2026-10-06",
    kind: "on_demand",
  }, { client: fakeClaude([[messageStart("claude-opus-5-5"), ...messageEnd("refusal")]]) });
  assertEquals(env.ledger.failed.length, 0);
  const saved = env.reviews[0].p_review as Record<string, unknown>;
  assertEquals(saved.status, "failed");
  assertEquals(saved.error_code, "refused");
  assertEquals(saved.photo_path, photoPath("2026-10-05", 1));
  const message = (env.ledger.completed[0].p_messages as Array<Record<string, unknown>>)[0];
  assertEquals(message.body, PHYSIQUE_REFUSED_MESSAGE);
  assertEquals(message.notify, false);
  assertEquals(env.ledger.claims[0].p_trigger_source, "user");
});

Deno.test("opt-out, no recent photo, or an owned run means no model call", async () => {
  for (
    const env of [
      physiqueSetup({ enabled: false }),
      physiqueSetup({ rows: [checkin("2026-09-01", 1)] }),
      physiqueSetup({ claimStatus: "complete" }),
      physiqueSetup({ claimStatus: "disabled" }),
    ]
  ) {
    const requests: RecordedRequest[] = [];
    await reviewPhysique(env.admin as never, USER, {
      anchorDay: "2026-10-06",
      kind: "weekly",
    }, { client: fakeClaude([jsonTextEvents(reviewOutput())], requests) });
    assertEquals(requests.length, 0);
    assertEquals(env.reviews.length, 0);
  }
});

Deno.test("a missing current photo or a model error fails the run and throws", async () => {
  const missing = physiqueSetup();
  delete missing.storage[BUCKET][photoPath("2026-10-05", 1)];
  let thrown: unknown = null;
  try {
    await reviewPhysique(missing.admin as never, USER, {
      anchorDay: "2026-10-06",
      kind: "weekly",
    }, { client: fakeClaude([jsonTextEvents(reviewOutput())]) });
  } catch (error) {
    thrown = error;
  }
  assert(thrown instanceof Error);
  assertEquals(missing.ledger.failed.length, 1);

  const broken = physiqueSetup();
  thrown = null;
  try {
    await reviewPhysique(broken.admin as never, USER, {
      anchorDay: "2026-10-06",
      kind: "weekly",
    }, { client: fakeClaude([529]) });
  } catch (error) {
    thrown = error;
  }
  assert(thrown instanceof Error);
  assertEquals(broken.ledger.failed.length, 1);
  assertEquals(broken.reviews.length, 0);
});
