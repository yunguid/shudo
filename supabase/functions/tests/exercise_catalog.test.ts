import {
  customExerciseKey,
  EXERCISE_CATALOG,
  EXERCISE_KEYS,
  exerciseKeyFor,
  findExercise,
} from "../_shared/exercise_catalog.ts";
import { assert, assertEquals } from "./assertions.ts";

Deno.test("catalog has about sixty uniquely keyed lifts with sane metadata", () => {
  assert(EXERCISE_CATALOG.length >= 60, `only ${EXERCISE_CATALOG.length} lifts`);
  assertEquals(new Set(EXERCISE_KEYS).size, EXERCISE_KEYS.length);
  for (const exercise of EXERCISE_CATALOG) {
    assert(/^[a-z][a-z0-9_]{1,39}$/.test(exercise.key), exercise.key);
    assert(exercise.incrementLb >= 0 && exercise.incrementLb <= 20, exercise.key);
    assert(exercise.name.length > 0);
  }
});

Deno.test("gym shorthand, plurals, and punctuation resolve to catalog lifts", () => {
  assertEquals(findExercise("bench")?.key, "barbell_bench_press");
  assertEquals(findExercise("Bench Press")?.key, "barbell_bench_press");
  assertEquals(findExercise("Pull-ups")?.key, "pull_up");
  assertEquals(findExercise("incline db press")?.key, "incline_dumbbell_press");
  assertEquals(findExercise("RDLs")?.key, "romanian_deadlift");
  assertEquals(findExercise("Farmer's walk")?.key, "farmers_carry");
  assertEquals(findExercise("lateral raises")?.key, "lateral_raise");
  assertEquals(findExercise("barbell_row")?.key, "barbell_row");
});

Deno.test("fuzzy matching uses multi-word phrases only", () => {
  assertEquals(
    findExercise("paused barbell bench press")?.key,
    "barbell_bench_press",
  );
  assertEquals(findExercise("heavy incline bench press")?.key, "incline_barbell_bench_press");
  // A lone word inside a longer phrase must not match ("incline" ≠ bench).
  assertEquals(findExercise("incline treadmill walk"), null);
  assertEquals(findExercise("paused barbell bench press", { fuzzy: false }), null);
});

Deno.test("unknown lifts get a stable custom slug and suggested keys are honored", () => {
  assertEquals(customExerciseKey("Zercher Carry!"), "custom:zercher_carry");
  assertEquals(exerciseKeyFor("Zercher carry"), "custom:zercher_carry");
  assertEquals(exerciseKeyFor("whatever", "hack_squat"), "hack_squat");
  // The model said custom after seeing the catalog: only exact names remap.
  assertEquals(exerciseKeyFor("Leg press", "custom"), "leg_press");
  assertEquals(
    exerciseKeyFor("paused leg press thing", "custom"),
    "custom:paused_leg_press_thing",
  );
  assertEquals(exerciseKeyFor("Sissy squat", "custom:sissy_squat"), "custom:sissy_squat");
});
