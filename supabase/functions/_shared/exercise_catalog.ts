/// Curated lift catalog shared by the activity analyzer, PR detection and the
/// training-plan generator. Keys are stable identifiers stored in
/// `activities.details.exercises[].key` and `training_plans.plan`; never
/// rename one (add an alias instead). Lifts outside the catalog get a
/// deterministic `custom:<slug>` key so PRs still track across sessions.

export type LoadType =
  | "barbell"
  | "dumbbell_each"
  | "machine"
  | "cable"
  | "bodyweight"
  | "bodyweight_plus"
  | "kettlebell"
  | "smith";

export type MuscleGroup =
  | "chest"
  | "back"
  | "shoulders"
  | "biceps"
  | "triceps"
  | "forearms"
  | "quads"
  | "hamstrings"
  | "glutes"
  | "calves"
  | "core"
  | "full_body";

export type CatalogExercise = {
  key: string;
  name: string;
  aliases: readonly string[];
  muscle: MuscleGroup;
  load: LoadType;
  /// Default double-progression jump, per dumbbell for `dumbbell_each`.
  incrementLb: number;
  compound: boolean;
};

function lift(
  key: string,
  name: string,
  muscle: MuscleGroup,
  load: LoadType,
  incrementLb: number,
  compound: boolean,
  aliases: string[] = [],
): CatalogExercise {
  return { key, name, aliases, muscle, load, incrementLb, compound };
}

export const EXERCISE_CATALOG: readonly CatalogExercise[] = [
  // Chest
  lift(
    "barbell_bench_press",
    "Barbell bench press",
    "chest",
    "barbell",
    5,
    true,
    [
      "bench",
      "bench press",
      "flat bench",
      "flat bench press",
      "bb bench",
      "barbell bench",
    ],
  ),
  lift(
    "incline_barbell_bench_press",
    "Incline barbell bench press",
    "chest",
    "barbell",
    5,
    true,
    [
      "incline",
      "incline bench",
      "incline bench press",
      "incline barbell press",
    ],
  ),
  lift(
    "dumbbell_bench_press",
    "Dumbbell bench press",
    "chest",
    "dumbbell_each",
    5,
    true,
    ["db bench", "dumbbell bench", "flat dumbbell press", "db press"],
  ),
  lift(
    "incline_dumbbell_press",
    "Incline dumbbell press",
    "chest",
    "dumbbell_each",
    5,
    true,
    [
      "incline db",
      "incline db press",
      "incline dumbbell",
      "incline dumbbell bench",
    ],
  ),
  lift(
    "decline_bench_press",
    "Decline bench press",
    "chest",
    "barbell",
    5,
    true,
    [
      "decline bench",
    ],
  ),
  lift(
    "machine_chest_press",
    "Machine chest press",
    "chest",
    "machine",
    10,
    true,
    [
      "chest press",
      "hammer strength chest press",
    ],
  ),
  lift("cable_fly", "Cable fly", "chest", "cable", 5, false, [
    "cable flye",
    "cable crossover",
    "crossover",
    "cable flys",
  ]),
  lift("pec_deck", "Pec deck", "chest", "machine", 10, false, [
    "pec fly",
    "machine fly",
    "pec dec",
  ]),
  lift("dumbbell_fly", "Dumbbell fly", "chest", "dumbbell_each", 5, false, [
    "db fly",
    "dumbbell flye",
  ]),
  lift("dip", "Dip", "chest", "bodyweight_plus", 5, true, [
    "dips",
    "chest dip",
    "weighted dip",
    "parallel bar dip",
  ]),
  lift("push_up", "Push-up", "chest", "bodyweight", 0, true, [
    "pushup",
    "push ups",
    "press up",
  ]),
  // Back
  lift("deadlift", "Deadlift", "back", "barbell", 10, true, [
    "conventional deadlift",
    "deads",
    "dl",
  ]),
  lift(
    "romanian_deadlift",
    "Romanian deadlift",
    "hamstrings",
    "barbell",
    10,
    true,
    [
      "rdl",
      "romanian",
      "stiff leg deadlift",
      "sldl",
    ],
  ),
  lift("barbell_row", "Barbell row", "back", "barbell", 5, true, [
    "bent over row",
    "bb row",
    "pendlay row",
    "bent row",
  ]),
  lift("dumbbell_row", "Dumbbell row", "back", "dumbbell_each", 5, true, [
    "db row",
    "one arm row",
    "single arm row",
    "one arm dumbbell row",
  ]),
  lift("seated_cable_row", "Seated cable row", "back", "cable", 10, true, [
    "cable row",
    "seated row",
    "low row",
  ]),
  lift("lat_pulldown", "Lat pulldown", "back", "cable", 10, true, [
    "pulldown",
    "lat pull",
    "lat pull down",
    "wide grip pulldown",
  ]),
  lift("pull_up", "Pull-up", "back", "bodyweight_plus", 5, true, [
    "pullup",
    "pull ups",
    "weighted pull up",
  ]),
  lift("chin_up", "Chin-up", "back", "bodyweight_plus", 5, true, [
    "chinup",
    "chin ups",
  ]),
  lift("t_bar_row", "T-bar row", "back", "barbell", 10, true, ["tbar row"]),
  lift(
    "chest_supported_row",
    "Chest-supported row",
    "back",
    "dumbbell_each",
    5,
    true,
    ["seal row", "incline row", "chest supported dumbbell row"],
  ),
  lift("machine_row", "Machine row", "back", "machine", 10, true, [
    "hammer strength row",
    "iso row",
  ]),
  lift("face_pull", "Face pull", "shoulders", "cable", 5, false, ["facepull"]),
  lift(
    "straight_arm_pulldown",
    "Straight-arm pulldown",
    "back",
    "cable",
    5,
    false,
    ["straight arm pushdown", "lat prayer"],
  ),
  lift("barbell_shrug", "Barbell shrug", "back", "barbell", 10, false, [
    "shrug",
    "shrugs",
  ]),
  lift("dumbbell_shrug", "Dumbbell shrug", "back", "dumbbell_each", 5, false, [
    "db shrug",
  ]),
  lift(
    "back_extension",
    "Back extension",
    "back",
    "bodyweight_plus",
    5,
    false,
    [
      "hyperextension",
      "hyper",
    ],
  ),
  // Shoulders
  lift("overhead_press", "Overhead press", "shoulders", "barbell", 5, true, [
    "ohp",
    "military press",
    "standing press",
    "barbell overhead press",
    "shoulder press barbell",
  ]),
  lift(
    "dumbbell_shoulder_press",
    "Dumbbell shoulder press",
    "shoulders",
    "dumbbell_each",
    5,
    true,
    ["db shoulder press", "seated dumbbell press", "shoulder press", "db ohp"],
  ),
  lift(
    "machine_shoulder_press",
    "Machine shoulder press",
    "shoulders",
    "machine",
    10,
    true,
  ),
  lift("arnold_press", "Arnold press", "shoulders", "dumbbell_each", 5, true),
  lift(
    "lateral_raise",
    "Lateral raise",
    "shoulders",
    "dumbbell_each",
    2.5,
    false,
    [
      "side raise",
      "lat raise",
      "side lateral",
      "side laterals",
      "dumbbell lateral raise",
    ],
  ),
  lift(
    "cable_lateral_raise",
    "Cable lateral raise",
    "shoulders",
    "cable",
    2.5,
    false,
  ),
  lift(
    "rear_delt_fly",
    "Rear delt fly",
    "shoulders",
    "dumbbell_each",
    2.5,
    false,
    [
      "reverse fly",
      "rear delt",
      "reverse pec deck",
      "rear delt raise",
    ],
  ),
  lift("upright_row", "Upright row", "shoulders", "barbell", 5, false),
  // Arms
  lift("barbell_curl", "Barbell curl", "biceps", "barbell", 5, false, [
    "bb curl",
    "straight bar curl",
  ]),
  lift("ez_bar_curl", "EZ-bar curl", "biceps", "barbell", 5, false, [
    "ez curl",
    "ezbar curl",
  ]),
  lift("dumbbell_curl", "Dumbbell curl", "biceps", "dumbbell_each", 5, false, [
    "db curl",
    "bicep curl",
    "biceps curl",
    "curl",
  ]),
  lift("hammer_curl", "Hammer curl", "biceps", "dumbbell_each", 5, false, [
    "hammers",
  ]),
  lift("preacher_curl", "Preacher curl", "biceps", "machine", 5, false),
  lift(
    "incline_dumbbell_curl",
    "Incline dumbbell curl",
    "biceps",
    "dumbbell_each",
    5,
    false,
    ["incline curl"],
  ),
  lift("cable_curl", "Cable curl", "biceps", "cable", 5, false),
  lift("tricep_pushdown", "Triceps pushdown", "triceps", "cable", 5, false, [
    "pushdown",
    "rope pushdown",
    "cable pushdown",
    "tricep pushdown",
    "triceps pushdown",
  ]),
  lift(
    "overhead_tricep_extension",
    "Overhead triceps extension",
    "triceps",
    "cable",
    5,
    false,
    ["overhead extension", "overhead tricep extension", "french press"],
  ),
  lift("skull_crusher", "Skull crusher", "triceps", "barbell", 5, false, [
    "skullcrusher",
    "lying tricep extension",
    "lying triceps extension",
  ]),
  lift(
    "close_grip_bench_press",
    "Close-grip bench press",
    "triceps",
    "barbell",
    5,
    true,
    ["close grip bench", "cgbp"],
  ),
  lift("wrist_curl", "Wrist curl", "forearms", "dumbbell_each", 2.5, false),
  // Legs
  lift("back_squat", "Back squat", "quads", "barbell", 10, true, [
    "squat",
    "barbell squat",
    "high bar squat",
    "low bar squat",
  ]),
  lift("front_squat", "Front squat", "quads", "barbell", 10, true),
  lift("hack_squat", "Hack squat", "quads", "machine", 10, true),
  lift("leg_press", "Leg press", "quads", "machine", 20, true),
  lift(
    "bulgarian_split_squat",
    "Bulgarian split squat",
    "quads",
    "dumbbell_each",
    5,
    true,
    ["bss", "split squat", "bulgarian", "rear foot elevated split squat"],
  ),
  lift("walking_lunge", "Walking lunge", "quads", "dumbbell_each", 5, true, [
    "lunge",
    "lunges",
    "dumbbell lunge",
  ]),
  lift("goblet_squat", "Goblet squat", "quads", "dumbbell_each", 5, true),
  lift("leg_extension", "Leg extension", "quads", "machine", 10, false, [
    "quad extension",
  ]),
  lift("lying_leg_curl", "Lying leg curl", "hamstrings", "machine", 5, false, [
    "leg curl",
    "hamstring curl",
  ]),
  lift("seated_leg_curl", "Seated leg curl", "hamstrings", "machine", 5, false),
  lift("hip_thrust", "Hip thrust", "glutes", "barbell", 10, true, [
    "barbell hip thrust",
    "glute bridge",
  ]),
  lift("good_morning", "Good morning", "hamstrings", "barbell", 5, true),
  lift("step_up", "Step-up", "quads", "dumbbell_each", 5, true, ["stepup"]),
  lift(
    "standing_calf_raise",
    "Standing calf raise",
    "calves",
    "machine",
    10,
    false,
    ["calf raise", "calf raises"],
  ),
  lift(
    "seated_calf_raise",
    "Seated calf raise",
    "calves",
    "machine",
    10,
    false,
  ),
  // Core and full body
  lift(
    "hanging_leg_raise",
    "Hanging leg raise",
    "core",
    "bodyweight",
    0,
    false,
    [
      "leg raise",
      "hanging knee raise",
    ],
  ),
  lift("cable_crunch", "Cable crunch", "core", "cable", 5, false),
  lift("ab_wheel", "Ab wheel rollout", "core", "bodyweight", 0, false, [
    "ab rollout",
    "ab wheel",
  ]),
  lift(
    "kettlebell_swing",
    "Kettlebell swing",
    "full_body",
    "kettlebell",
    5,
    true,
    [
      "kb swing",
    ],
  ),
  lift(
    "farmers_carry",
    "Farmer's carry",
    "forearms",
    "dumbbell_each",
    5,
    true,
    [
      "farmers walk",
      "farmer carry",
    ],
  ),
  lift("power_clean", "Power clean", "full_body", "barbell", 5, true, [
    "clean",
  ]),
];

export const EXERCISE_KEYS: readonly string[] = EXERCISE_CATALOG.map((
  exercise,
) => exercise.key);

const BY_KEY = new Map(
  EXERCISE_CATALOG.map((exercise) => [exercise.key, exercise]),
);

export function normalizeExerciseName(value: string): string {
  return value
    .toLowerCase()
    .normalize("NFKD")
    .replace(/[̀-ͯ]/g, "")
    .replace(/&/g, " and ")
    .replace(/['’]/g, "")
    .replace(/[^a-z0-9]+/g, " ")
    .trim()
    .replace(/\s+/g, " ");
}

function singularize(phrase: string): string {
  return phrase.split(" ").map((word) =>
    word.length > 3 && word.endsWith("s") && !word.endsWith("ss")
      ? word.slice(0, -1)
      : word
  ).join(" ");
}

const PHRASE_INDEX: Array<{ phrase: string; exercise: CatalogExercise }> = [];
const EXACT_INDEX = new Map<string, CatalogExercise>();
for (const exercise of EXERCISE_CATALOG) {
  const phrases = [
    exercise.key.replace(/_/g, " "),
    exercise.name,
    ...exercise.aliases,
  ].map(normalizeExerciseName);
  for (const phrase of phrases) {
    for (const variant of new Set([phrase, singularize(phrase)])) {
      if (!EXACT_INDEX.has(variant)) EXACT_INDEX.set(variant, exercise);
      PHRASE_INDEX.push({ phrase: variant, exercise });
    }
  }
}
// Longest phrases first so "incline bench press" beats "bench press".
PHRASE_INDEX.sort((left, right) => right.phrase.length - left.phrase.length);

export function exerciseByKey(key: string): CatalogExercise | null {
  return BY_KEY.get(key) ?? null;
}

/**
 * Resolves a key, display name, or dictated phrase to a catalog lift. Exact
 * matches (including simple plurals) win. With `fuzzy` (the default) the
 * longest multi-word catalog phrase contained as whole words also matches
 * ("paused barbell bench press" → bench press). Single words never match
 * inside a longer phrase: "incline treadmill walk" must not become a bench.
 */
export function findExercise(
  nameOrKey: string,
  options: { fuzzy?: boolean } = {},
): CatalogExercise | null {
  if (!nameOrKey) return null;
  const direct = BY_KEY.get(nameOrKey.trim());
  if (direct) return direct;
  const normalized = normalizeExerciseName(nameOrKey);
  if (!normalized) return null;
  const exact = EXACT_INDEX.get(normalized) ??
    EXACT_INDEX.get(singularize(normalized));
  if (exact) return exact;
  if (options.fuzzy === false) return null;
  const padded = ` ${singularize(normalized)} `;
  for (const { phrase, exercise } of PHRASE_INDEX) {
    if (!phrase.includes(" ")) continue;
    if (padded.includes(` ${phrase} `)) return exercise;
  }
  return null;
}

export function customExerciseKey(name: string): string {
  const slug = normalizeExerciseName(name).replace(/ /g, "_").slice(0, 40)
    .replace(/_+$/g, "");
  return `custom:${slug || "exercise"}`;
}

/**
 * Catalog key for a lift, or a stable `custom:<slug>` for anything else. A
 * valid suggested catalog key wins; a model that said "custom" only gets
 * remapped on an exact name match (it already looked at the catalog).
 */
export function exerciseKeyFor(
  name: string,
  suggestedKey?: string | null,
): string {
  if (suggestedKey && BY_KEY.has(suggestedKey)) return suggestedKey;
  if (suggestedKey && /^custom:[a-z0-9_]{1,40}$/.test(suggestedKey)) {
    return findExercise(name, { fuzzy: false })?.key ?? suggestedKey;
  }
  const fuzzy = suggestedKey !== "custom";
  return findExercise(name, { fuzzy })?.key ?? customExerciseKey(name);
}

/** Compact catalog listing for prompts: `key: Name (muscle)`. */
export function catalogPromptListing(): string {
  return EXERCISE_CATALOG.map((exercise) =>
    `${exercise.key}: ${exercise.name} (${exercise.muscle})`
  ).join("\n");
}
