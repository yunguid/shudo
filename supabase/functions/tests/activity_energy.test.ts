import {
  type ActivityEnergyInput,
  DEFAULT_BODY_WEIGHT_KG,
  estimateActiveEnergy,
  metFor,
  resolveBodyWeight,
  restingKcalPerHour,
} from "../_shared/activity_energy.ts";
import { assert, assertEquals } from "./assertions.ts";

function input(
  overrides: Partial<ActivityEnergyInput> = {},
): ActivityEnergyInput {
  return {
    kind: "strength",
    intensity: "moderate",
    metCode: null,
    durationMin: 60,
    workingSets: 0,
    deviceActiveKcal: null,
    deviceTotalKcal: null,
    deviceLabel: null,
    bodyWeightKg: 80,
    bodyWeightSource: "weigh_in",
    heightCm: null,
    ...overrides,
  };
}

Deno.test("body weight prefers the latest weigh-in, then the profile, then 75 kg", () => {
  assertEquals(resolveBodyWeight(74.2, 73.7), { kg: 74.2, source: "weigh_in" });
  assertEquals(resolveBodyWeight(null, 73.7), { kg: 73.7, source: "profile" });
  assertEquals(resolveBodyWeight(null, null), {
    kg: DEFAULT_BODY_WEIGHT_KG,
    source: "default",
  });
  // Implausible values are ignored rather than trusted.
  assertEquals(resolveBodyWeight(5, 900).source, "default");
});

Deno.test("MET burn is net of resting: (MET − 1) × kg × hours", () => {
  const hardLift = estimateActiveEnergy(input({ intensity: "hard" }));
  assertEquals(hardLift.method, "met");
  assertEquals(hardLift.met, 6);
  assertEquals(hardLift.activeKcal, 400); // (6 − 1) × 80 × 1
  assertEquals(hardLift.durationEstimated, false);

  // Luke's ten-minute easy morning bike at the profile weight.
  const bike = estimateActiveEnergy(
    input({
      kind: "cycle",
      intensity: "easy",
      durationMin: 10,
      bodyWeightKg: 73.7,
      bodyWeightSource: "profile",
    }),
  );
  assertEquals(bike.activeKcal, 31); // 2.5 × 73.7 × 10/60 = 30.7
  assert(bike.confidence <= 0.75);
});

Deno.test("a specific MET code beats the kind and intensity table", () => {
  assertEquals(metFor("run", "easy", "run_7mph"), 11);
  assertEquals(metFor("run", "max", null), 11.5);
  const run = estimateActiveEnergy(
    input({ kind: "run", metCode: "run_6mph", durationMin: 30 }),
  );
  assertEquals(run.activeKcal, Math.round(8.8 * 80 * 0.5));
});

Deno.test("a lift without a duration is estimated from working sets", () => {
  const result = estimateActiveEnergy(
    input({ durationMin: null, workingSets: 12 }),
  );
  assertEquals(result.durationEstimated, true);
  assertEquals(result.durationMinUsed, 30);
  assertEquals(result.activeKcal, 160); // (5 − 1) × 80 × 0.5
  assert(result.confidence <= 0.45);
});

Deno.test("cardio with no duration and no device numbers has no burn", () => {
  const result = estimateActiveEnergy(
    input({ kind: "walk", durationMin: null }),
  );
  assertEquals(result.activeKcal, null);
  assertEquals(result.confidence, 0);
});

Deno.test("device active calories win; gym consoles are discounted", () => {
  const watch = estimateActiveEnergy(
    input({ deviceActiveKcal: 312, deviceLabel: "apple_watch" }),
  );
  assertEquals(watch, {
    activeKcal: 312,
    method: "device",
    met: null,
    weightKgUsed: 80,
    durationMinUsed: 60,
    durationEstimated: false,
    confidence: 0.9,
  });
  const console = estimateActiveEnergy(
    input({ deviceActiveKcal: 400, deviceLabel: "gym_machine" }),
  );
  assertEquals(console.activeKcal, 340);
  assertEquals(console.confidence, 0.6);
});

Deno.test("device total calories subtract resting burn for the session", () => {
  const resting = restingKcalPerHour(80, 180);
  assertEquals(Math.round(resting * 100) / 100, 69.67);
  const result = estimateActiveEnergy(
    input({
      kind: "cardio",
      durationMin: 30,
      deviceTotalKcal: 300,
      deviceLabel: "apple_watch",
      heightCm: 180,
    }),
  );
  assertEquals(result.method, "device");
  assertEquals(result.activeKcal, Math.round(300 - resting / 2));
  // Without a duration, a conservative share of the total is used.
  const noDuration = estimateActiveEnergy(
    input({ kind: "cardio", durationMin: null, deviceTotalKcal: 300 }),
  );
  assertEquals(noDuration.activeKcal, 240);
  assertEquals(noDuration.confidence, 0.5);
});

Deno.test("default body weight caps confidence at 0.4", () => {
  const result = estimateActiveEnergy(
    input({ bodyWeightKg: 75, bodyWeightSource: "default" }),
  );
  assertEquals(result.confidence, 0.4);
  assertEquals(result.weightKgUsed, 75);
});
