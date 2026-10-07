import {
  FALLBACK_HEADLINE,
  homeFoodOption,
  inQuietHours,
  isLateNight,
  LATE_NIGHT_HEADLINE,
  type LocationContext,
  locationContextFromDeviceSnapshot,
  type NearbyFoodInput,
  recomputeTotals,
  researchNearbyFood,
  sanitizeLocationContext,
  type SnackItem,
} from "../_shared/nearby_food.ts";
import { assert, assertEquals } from "./assertions.ts";
import {
  fakeClaude,
  promptText,
  type RecordedRequest,
  submitToolEvents,
} from "./fake_claude.ts";
import { fakeAdmin, fakeLedger } from "./fake_rest_admin.ts";

const USER = "11111111-1111-4111-8111-111111111111";
const TOOL = "submit_snack_rec";

function location(overrides: Partial<LocationContext> = {}): LocationContext {
  return {
    captured_at: "2026-10-06T19:40:00Z",
    quality: "precise",
    locality: {
      neighborhood: "East Village",
      city: "New York",
      region: "NY",
      country: "us",
      timezone: "America/New_York",
    },
    stores: [
      {
        ref: "s2",
        name: "CVS Pharmacy",
        category: "pharmacy",
        distance_m: 480,
        walk_minutes: 6,
        walk_minutes_source: "estimate",
        address_short: "2nd Ave",
      },
      {
        ref: "s1",
        name: "7-Eleven",
        category: "convenience",
        distance_m: 210,
        walk_minutes: 3,
        walk_minutes_source: "mapkit_eta",
        address_short: "E 10th St",
      },
    ],
    ...overrides,
  };
}

function input(overrides: Partial<NearbyFoodInput> = {}): NearbyFoodInput {
  return {
    localDay: "2026-10-06",
    timezone: "America/New_York",
    localTime: "15:40",
    location: location(),
    query: null,
    remaining: { calories_kcal: 900, protein_g: 60, carbs_g: 100, fat_g: 30 },
    ...overrides,
  };
}

function item(overrides: Partial<SnackItem> = {}): SnackItem {
  return {
    name: "Core Power Elite",
    brand: "Fairlife",
    serving: "14 fl oz bottle",
    quantity: 1,
    calories_kcal: 230,
    protein_g: 42,
    carbs_g: 8,
    fat_g: 3.5,
    price_usd_est: 4.49,
    source_url: "https://www.fairlife.com/core-power-elite",
    nutrition_source: "web",
    ...overrides,
  };
}

function modelOutput(overrides: Record<string, unknown> = {}) {
  return {
    headline: "7-Eleven's a 3-min walk. Core Power plus an Uncrustable closes protein.",
    verdict: "grab",
    push_body: "7-Eleven, 3 min: Core Power + PB&J, closes your protein.",
    options: [
      {
        store_ref: "s1",
        items: [
          item({ quantity: 2 }),
          item({
            name: "Uncrustables PB&J",
            brand: "Smucker's",
            serving: "1 sandwich",
            calories_kcal: 210,
            protein_g: 6,
            carbs_g: 28,
            fat_g: 9,
            source_url: null,
            nutrition_source: "label_known",
          }),
        ],
      },
      { store_ref: "s9", items: [item()] },
      {
        store_ref: "s2",
        items: [item({ name: "Premier Protein", source_url: null, nutrition_source: "web" })],
      },
    ],
    ...overrides,
  };
}

function nearbySetup(
  options: { locationRecs?: boolean; quiet?: [string, string] } = {},
) {
  const ledger = fakeLedger();
  const fake = fakeAdmin({
    tables: {
      profiles: [{
        user_id: USER,
        location_recs_enabled: options.locationRecs ?? true,
        quiet_hours_start: options.quiet?.[0] ?? "23:00:00",
        quiet_hours_end: options.quiet?.[1] ?? "07:00:00",
        coach_profanity: "mild",
      }],
    },
    rpc: ledger.handlers,
  });
  return { ...fake, ledger };
}

// ---------------------------------------------------------------------------
// Pure helpers
// ---------------------------------------------------------------------------

Deno.test("location context is sanitized: bounded, sorted, never coordinates", () => {
  const raw = {
    ...location(),
    latitude: 40.7128,
    longitude: -74.006,
    stores: [
      ...location().stores,
      { ref: "bad ref!", name: "x", walk_minutes: 2 },
      { ref: "s3", name: "Far Away Deli", walk_minutes: 90 },
      {
        ref: "s4",
        name: "  Joe's\u0000 <Bodega>  ",
        category: "store",
        distance_m: 333,
        walk_minutes: 4,
        lat: 1,
      },
      ...Array.from({ length: 20 }, (_, index) => ({
        ref: `x${index}`,
        name: `Store ${index}`,
        walk_minutes: 10,
      })),
    ],
  };
  const context = sanitizeLocationContext(raw)!;
  assertEquals(context.stores.length, 15);
  assertEquals(context.stores[0].ref, "s1");
  assertEquals(context.stores.find((store) => store.ref === "s4")?.name, "Joe's Bodega");
  assertEquals(context.stores.find((store) => store.ref === "s4")?.distance_m, 330);
  assertEquals(context.locality.country, "US");
  const text = JSON.stringify(context);
  assert(!text.includes("40.7128") && !text.includes("lat"));
  assert(!context.stores.some((store) => store.ref === "s3"));
});

Deno.test("device snapshots supply stores only while fresh", () => {
  const row = {
    city: "New York",
    region: "NY",
    country_code: "US",
    timezone: "America/New_York",
    nearby: location().stores,
    nearby_captured_at: "2026-10-06T19:00:00Z",
  };
  const fresh = locationContextFromDeviceSnapshot(row, Date.parse("2026-10-06T20:00:00Z"))!;
  assertEquals(fresh.stores.length, 2);
  const stale = locationContextFromDeviceSnapshot(row, Date.parse("2026-10-07T01:00:00Z"))!;
  assertEquals(stale.stores, []);
  assertEquals(stale.locality.city, "New York");
});

Deno.test("quiet hours wrap midnight; late night includes 23:00-05:00", () => {
  assertEquals(inQuietHours("23:30", "23:00:00", "07:00:00"), true);
  assertEquals(inQuietHours("06:59", "23:00", "07:00"), true);
  assertEquals(inQuietHours("07:00", "23:00", "07:00"), false);
  assertEquals(inQuietHours("13:00", "12:00", "14:00"), true);
  assertEquals(isLateNight("23:10", null, null), true);
  assertEquals(isLateNight("22:00", "21:30", "06:00"), true);
  assertEquals(isLateNight("15:40", "23:00", "07:00"), false);
});

Deno.test("totals are item macros × quantity, recomputed on the server", () => {
  const totals = recomputeTotals(
    [item({ quantity: 2 }), item({ calories_kcal: 210, protein_g: 6, carbs_g: 28, fat_g: 9 })],
    { calories_kcal: 900, protein_g: 60, carbs_g: 100, fat_g: 30 },
  );
  assertEquals(totals.combined, {
    calories_kcal: 670,
    protein_g: 90,
    carbs_g: 44,
    fat_g: 16,
  });
  assertEquals(totals.remaining_after, {
    calories_kcal: 230,
    protein_g: -30,
    carbs_g: 56,
    fat_g: 14,
  });
});

Deno.test("the kitchen fallback closes protein with staples", () => {
  const option = homeFoodOption({
    calories_kcal: 900,
    protein_g: 60,
    carbs_g: 100,
    fat_g: 30,
  });
  assertEquals(option.store_ref, "home");
  assertEquals(option.maps_query, "");
  assertEquals(option.items.map((entry) => entry.name), [
    "Whey protein",
    "Whole milk",
    "Peanut butter",
    "Banana",
  ]);
  assertEquals(option.items[1].quantity, 2);
  assertEquals(option.combined.calories_kcal, 715);
  assertEquals(option.combined.protein_g, 48.3);
  const small = homeFoodOption({ calories_kcal: 160, protein_g: 5, carbs_g: 30, fat_g: 2 });
  assertEquals(small.items.map((entry) => entry.name), ["Banana"]);
});

// ---------------------------------------------------------------------------
// researchNearbyFood
// ---------------------------------------------------------------------------

Deno.test("under 100 kcal left: no snack, no model, no ledger", async () => {
  const env = nearbySetup();
  const requests: RecordedRequest[] = [];
  const payload = await researchNearbyFood(env.admin as never, USER, input({
    remaining: { calories_kcal: 80, protein_g: 4, carbs_g: 10, fat_g: 2 },
  }), { client: fakeClaude([], requests) });
  assertEquals(payload.verdict, "no_snack_needed");
  assertEquals(payload.options, []);
  assertEquals(requests.length, 0);
  assertEquals(env.rpcCalls.length, 0);
});

Deno.test("late at night the answer is the kitchen, never a store run", async () => {
  const env = nearbySetup();
  const requests: RecordedRequest[] = [];
  const payload = await researchNearbyFood(env.admin as never, USER, input({
    localTime: "23:20",
  }), { client: fakeClaude([], requests) });
  assertEquals(payload.headline, LATE_NIGHT_HEADLINE);
  assertEquals(payload.verdict, "grab");
  assertEquals(payload.options.map((option) => option.store_ref), ["home"]);
  assertEquals(requests.length, 0);
});

Deno.test("research validates stores, recomputes totals, and keeps queries city-level", async () => {
  const env = nearbySetup();
  const requests: RecordedRequest[] = [];
  const payload = await researchNearbyFood(
    env.admin as never,
    USER,
    input({ query: "something with protein" }),
    {
      client: fakeClaude([
        submitToolEvents(TOOL, modelOutput(), {
          search: true,
          sources: ["https://www.fairlife.com/core-power-elite"],
        }),
      ], requests),
    },
  );

  // Request shape: Sonnet medium, web search ≤4 with city-level location.
  assertEquals(requests[0].model, "claude-sonnet-5-5");
  assertEquals((requests[0].output_config as { effort?: string }).effort, "medium");
  const tools = requests[0].tools ?? [];
  assertEquals(tools[0].max_uses, 4);
  assertEquals(tools[0].user_location, {
    type: "approximate",
    city: "New York",
    region: "NY",
    country: "US",
    timezone: "America/New_York",
  });
  const prompt = promptText(requests[0]);
  assert(!prompt.includes("East Village"), "neighborhood never leaves the server");
  assert(prompt.includes('"ref":"s1"') && prompt.includes("7-Eleven"));
  assert(prompt.includes("untrusted"));
  const schema = tools[1].input_schema as Record<string, unknown>;
  assert(JSON.stringify(schema).includes('"enum":["s1","s2","home"]'));

  assertEquals(payload.verdict, "grab");
  assertEquals(payload.options.map((option) => option.store_ref), ["s1", "s2"]);
  const top = payload.options[0];
  assertEquals(top.store_name, "7-Eleven");
  assertEquals(top.walk_minutes, 3);
  assertEquals(top.maps_query, "7-Eleven, E 10th St");
  assertEquals(top.combined, {
    calories_kcal: 670,
    protein_g: 90,
    carbs_g: 44,
    fat_g: 16,
  });
  assertEquals(top.remaining_after.calories_kcal, 230);
  // "web" without a source page is downgraded to an estimate.
  assertEquals(payload.options[1].items[0].nutrition_source, "estimate");
  assertEquals(payload.sources, ["https://www.fairlife.com/core-power-elite"]);
  assert(payload.headline.startsWith("7-Eleven's a 3-min walk"));
  assert(payload.push_body?.startsWith("7-Eleven, 3 min"));

  assertEquals(env.ledger.claims[0].p_operation, "nearby_research");
  assert(String(env.ledger.claims[0].p_checkpoint_key).startsWith("nearby:"));
  assertEquals(env.ledger.completed.length, 1);
  assertEquals(env.ledger.completed[0].p_messages, []);
});

Deno.test("without location consent no stores or locality reach the model", async () => {
  const env = nearbySetup({ locationRecs: false });
  const requests: RecordedRequest[] = [];
  const payload = await researchNearbyFood(env.admin as never, USER, input(), {
    client: fakeClaude([
      submitToolEvents(TOOL, modelOutput({
        options: [{ store_ref: "any", items: [item({ source_url: null, nutrition_source: "label_known" })] }],
      })),
    ], requests),
  });
  const prompt = promptText(requests[0]);
  assert(!prompt.includes("7-Eleven") && !prompt.includes("New York"));
  assertEquals((requests[0].tools ?? [])[0].user_location, undefined);
  assertEquals(payload.options[0].store_ref, "any");
  assertEquals(payload.options[0].store_name, "Any convenience store");
  assertEquals(payload.options[0].maps_query, "convenience store");
});

Deno.test("big overshoots are dropped and off-voice headlines replaced", async () => {
  const env = nearbySetup();
  const payload = await researchNearbyFood(env.admin as never, USER, input({
    remaining: { calories_kcal: 400, protein_g: 30, carbs_g: 40, fat_g: 10 },
  }), {
    client: fakeClaude([
      submitToolEvents(TOOL, modelOutput({
        headline: "LET'S GO! Grab it!",
        push_body: "Visit https://example.com",
        options: [
          {
            store_ref: "s1",
            items: [item({ name: "Party pizza", calories_kcal: 1400, quantity: 1 })],
          },
          { store_ref: "s2", items: [item({ source_url: null, nutrition_source: "estimate" })] },
        ],
      })),
    ]),
  });
  assertEquals(payload.options.map((option) => option.store_ref), ["s2"]);
  assertEquals(payload.headline, "CVS Pharmacy is 6 min away and should have what you need.");
  assertEquals(payload.push_body, null);
});

Deno.test("model failures fall back to the kitchen and fail the run", async () => {
  const env = nearbySetup();
  const payload = await researchNearbyFood(env.admin as never, USER, input(), {
    client: fakeClaude([500]),
  });
  assertEquals(payload.headline, FALLBACK_HEADLINE);
  assertEquals(payload.options[0].store_ref, "home");
  assertEquals(env.ledger.failed.length, 1);
  assertEquals(env.ledger.completed.length, 0);
});

Deno.test("a budget-blocked claim falls back without calling the model", async () => {
  const fake = fakeAdmin({
    tables: {
      profiles: [{ user_id: USER, location_recs_enabled: true }],
    },
    rpc: {
      claim_coach_run() {
        throw new Error("project_ai_budget_exceeded");
      },
    },
  });
  const requests: RecordedRequest[] = [];
  const payload = await researchNearbyFood(fake.admin as never, USER, input(), {
    client: fakeClaude([], requests),
  });
  assertEquals(requests.length, 0);
  assertEquals(payload.options[0].store_ref, "home");
});
