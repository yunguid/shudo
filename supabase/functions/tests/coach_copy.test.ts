import { CardCopyViolation } from "../_shared/card_copy.ts";
import {
  assertCoachCopy,
  coachCardCopyGuard,
  type CoachCopyPolicy,
  coachCopyReview,
  coachCopyViolation,
  sanitizeCoachText,
  splitBubbles,
  stripPreamble,
  unverifiedFigures,
} from "../_shared/coach_copy.ts";
import {
  CHAT_FAILURE_FALLBACK,
  CHAT_REFUSAL_FALLBACK,
  fallbackReactionCopy,
  fallbackSlotCopy,
  type FallbackSnapshot,
} from "../_shared/coach_fallbacks.ts";
import { COACH_STAPLE_FIGURES } from "../_shared/coach_persona.ts";
import type { SlotTopic } from "../_shared/coach_policy.ts";
import { assert, assertEquals } from "./assertions.ts";

/// Persona bible §7: forty bulk-context texts. Figures are illustrative
/// (2,900 cal / 170 g); in production every figure comes from the pack.
const FORTY_EXAMPLES = [
  "Morning, Luke. 2,900 cal, 170g protein. Breakfast isn't optional on a bulk: eggs, rice, fruit, the classic.",
  "Bike's done? Good. Now eat before you walk out at 9. Cardio on an empty tank is how you stay 162.",
  "Six-day week starts now. Pack two snacks before you leave. 3pm you will thank 7am you.",
  "Lift day. Big breakfast, real lunch, then we go move some weight. Theme today: eat early.",
  "Pre-workout's in. Headphones on, phone on airplane. Next hour belongs to you and the bar.",
  "Chest day. Last time: 185 for 6. Today we want 7. One rep. That's the assignment.",
  "This is the fun part. You used to live for this. Go remind yourself why.",
  "1pm and 600 cal logged. On a bulk that's a rounding error. Anything you forgot to log?",
  "55g protein by 3. You need 115 more. Greek yogurt now, double meat at dinner.",
  "Two-thirds through the day, under half your calories. That's how 172 turned into 162. Not this time.",
  "Can't face another meal? Drink it. 16 oz whole milk: 300 cal, 16g protein. Easiest rep of the day.",
  "Shake math: milk, two scoops, banana, peanut butter. About 850 cal in one glass. You were built on milk, remember?",
  "Lockdown you drank milk by the gallon. Today you need two more glasses. Low bar. Clear it.",
  "2,940 cal, 174g protein, lifted. That's a growing day. Stack thirty of those and the mirror changes.",
  "Every number in the box. Quiet days like this are how guys get big. In bed by 11 and it's perfect.",
  "Four straight days on target. That's the guy who used to meal-prep everything, coming back. Good to see him.",
  "Pizza's fine, you're bulking. Five beers isn't. That's calories that build nothing. Water, bed, normal day tomorrow.",
  "You logged every slice and every beer. Respect. No penance tomorrow, just breakfast and back on plan.",
  "Rough night on the log. Shit happens. Big protein breakfast and we're back on the rails by 10.",
  "Nothing logged since 11. Either you ate and didn't tell me, or you didn't eat. Both are problems.",
  "Six hours of silence. Voice-note it from memory. A rough guess beats a blank page.",
  "Back and biceps, 55 min, logged. Get 40g protein and a pile of carbs in the next two hours. That's where it becomes size.",
  "Rows up 10 lb from last week. Damn. That's progressive overload doing its job. Go eat like it.",
  "Third session this week, most since you moved back. The old you is waking up.",
  "Photo's in. No scale yet, so the mirror and the log are the scoreboard. Both say keep going.",
  "Up 2 lb overnight. That's last night's salt and carbs, not new tissue. The weekly trend decides. Eat normal.",
  "Down a pound on the week. On a bulk, that's a miss. One extra shake a day and we check again Sunday.",
  "Trend's up 0.4 lb a week. Textbook lean bulk. Don't touch a thing.",
  "14 photos in a row. Shoulders are fuller than day one. Same light, same pose, so it's real. Keep stacking.",
  "Can't see a change today? Nobody can, day to day. Put week 1 next to week 6 on Sunday. That's where it shows.",
  "7-Eleven's a 2-min walk. Core Power + a PB&J Uncrustable: ~380 cal, 32g protein. Closes your protein for today.",
  "Chipotle's 4 min away and you're 1,000 cal short. Burrito, double chicken. Fixes the day in one sitting.",
  "CVS on your block should have Premier shakes. Two plus a trail mix: 60g protein, ~800 cal. Drink one on the walk back.",
  "11pm and 400 short? Cereal with whole milk, then lights out. Food and sleep both count.",
  "Midnight again. You grow while you sleep, not while you scroll. Phone down, man.",
  "Rest day isn't a fasting day. The muscle gets built today, out of today's food. Hit your number.",
  "Elbow's barking? Skip heavy curls, train around it. Sharp or swelling means get it looked at. Still eat your number.",
  "Locked in: 180 is the new goal. Same pace, since slow keeps it mostly muscle. Numbers stay 2,900 / 170g.",
  "Dirty bulk to 185 by January? No. That's mostly fat and a new wardrobe. I kept you under a pound a week.",
  "How was work, actually? Six days a week is a lot. Make sure you're seeing people, not just the office and the gym.",
];

/// The illustrative pack behind the examples.
const EXAMPLE_FIGURES = [
  2900,
  170,
  600,
  55,
  115,
  850,
  2940,
  174,
  40,
  10,
  2,
  0.4,
  380,
  32,
  1000,
  60,
  800,
  ...COACH_STAPLE_FIGURES,
];

function policy(overrides: Partial<CoachCopyPolicy> = {}): CoachCopyPolicy {
  return {
    mode: "checkpoint_nudge",
    profanity: "mild",
    emojiAllowed: false,
    allowedFigures: EXAMPLE_FIGURES,
    pushCapable: true,
    ...overrides,
  };
}

function violationCode(text: string, overrides: Partial<CoachCopyPolicy> = {}) {
  return coachCopyViolation(
    { skip: false, bubbles: [text], push_body: null },
    policy(overrides),
  )?.code ?? null;
}

function pushViolationCode(
  text: string,
  overrides: Partial<CoachCopyPolicy> = {},
) {
  return coachCopyViolation(
    { skip: false, bubbles: [text], push_body: text },
    policy(overrides),
  )?.code ?? null;
}

Deno.test("all forty persona examples pass the coach guard as bubble and push", () => {
  assertEquals(FORTY_EXAMPLES.length, 40);
  for (const example of FORTY_EXAMPLES) {
    // Every example is safe on the lock screen and a clean bubble.
    const safety = coachCopyViolation(
      { skip: false, bubbles: [example], push_body: example },
      policy({ voice: false }),
    );
    assert(safety === null, `${safety?.message}: ${example}`);
    const bubble = coachCopyViolation(
      { skip: false, bubbles: [example], push_body: null },
      policy(),
    );
    assert(bubble === null, `${bubble?.message}: ${example}`);
    // As a push, only the few past 110 characters earn a tightening pass.
    const push = coachCopyViolation(
      { skip: false, bubbles: [example], push_body: example },
      policy(),
    );
    const expected = Array.from(example).length > 110 ? "verbose" : null;
    assert((push?.code ?? null) === expected, `${push?.message}: ${example}`);
  }
});

Deno.test("unsafe or off-voice copy is rejected with the right code", () => {
  const cases: Array<[string, string]> = [
    ["You're so fat right now. Lay off the pizza.", "insult"],
    ["Don't be a pussy, finish the plate.", "slur"],
    ["The girls will notice those arms.", "sexual"],
    ["Skip dinner tonight and you'll be fine.", "extreme_diet"],
    ["Fast until noon tomorrow to make up for it.", "extreme_diet"],
    ["Big day. Burn it off in the morning.", "extreme_diet"],
    ["Eat until you're sick tonight. Bulk season.", "extreme_diet"],
    ["Try a fat burner to lean out before summer.", "extreme_diet"],
    ["Take 200mg of caffeine before you lift.", "medical"],
    ["5g of creatine every morning, no excuses on that.", "medical"],
    ["You probably have a thyroid problem. See a doctor.", "medical"],
    ["Trump would be proud of that bench.", "politics"],
    ["Alpha males don't skip leg day.", "politics"],
    ["I'm Sam and I say eat more.", "impersonation"],
    ["Damn, that's a shit day on the log.", "profanity_level"],
    ["Fucking eat your dinner.", "profanity_level"],
    ["🔥 Big day today.", "emoji"],
    ["Check https://example.com for the menu.", "url"],
    ["Call (555) 123-4567 if you need help.", "contact"],
    ["**Big day.** Eat early.", "format"],
    ["- Eat breakfast\n- Eat lunch", "format"],
    ["Fuel up today #gains", "format"],
    ["3,500 cal today and we're good.", "unverified_figure"],
    ["Get 255g protein in by lunch.", "unverified_figure"],
    ["Let's go, you got this.", "tic"],
    ["Great job today, champ.", "tic"],
    ["Big day! Eat up!", "tic"],
    ["Hungry? Tired? Eat something.", "tic"],
  ];
  for (const [text, code] of cases) {
    assertEquals(violationCode(text), code);
  }
});

Deno.test("medical words are allowed in a bubble only alongside a referral", () => {
  assertEquals(
    violationCode(
      "If the medication makes you queasy, ask your doctor about timing meals.",
    ),
    null,
  );
  assertEquals(
    pushViolationCode("If the medication makes you queasy, ask your doctor."),
    "medical",
  );
});

Deno.test("profanity follows the setting and never goes salty on the lock screen", () => {
  assertEquals(
    violationCode("Rough night. Shit happens.", { profanity: "off" }),
    "profanity_level",
  );
  assertEquals(
    violationCode("Rough night. Shit happens.", { profanity: "mild" }),
    null,
  );
  assertEquals(
    violationCode("That set was fucking heavy.", { profanity: "salty" }),
    null,
  );
  assertEquals(
    pushViolationCode("That set was fucking heavy.", { profanity: "salty" }),
    "profanity_level",
  );
  // Words that merely contain a profane substring stay clean.
  assertEquals(
    violationCode("Hello from class. Pass the shell pasta.", {
      profanity: "off",
    }),
    null,
  );
});

Deno.test("push bodies are one line and at most 150 characters", () => {
  const long = `Morning. ${"Eat early and often. ".repeat(8)}`.trim();
  assertEquals(
    coachCopyViolation(
      { skip: false, bubbles: ["Morning."], push_body: long },
      policy(),
    )?.code,
    "length",
  );
  assertEquals(
    coachCopyViolation(
      { skip: false, bubbles: ["Morning."], push_body: "Morning.\nEat." },
      policy(),
    )?.code,
    "length",
  );
  assertEquals(
    pushViolationCode("Right now you're 600 cal short. Fix it."),
    "stale_time",
  );
});

Deno.test("mode limits bound bubbles and totals", () => {
  const bubble = "Eat a real lunch. Rice, chicken, something green.";
  assertEquals(
    coachCopyViolation(
      { skip: false, bubbles: [bubble, bubble], push_body: null },
      policy({ mode: "workout_ack" }),
    )?.code,
    "length",
  );
  const essay = "Here's the reasoning on calories. ".repeat(20).trim();
  assertEquals(
    coachCopyViolation(
      { skip: false, bubbles: [essay], push_body: null },
      policy({ mode: "chat_reply" }),
    )
      ?.code,
    "length",
  );
  assertEquals(
    coachCopyViolation({ skip: true, bubbles: [], push_body: null }, policy()),
    null,
  );
  assertEquals(
    assertCoachCopy(
      { skip: false, bubbles: [bubble], push_body: null },
      policy(),
    ).bubbles,
    [bubble],
  );
});

Deno.test("figures are verified within ten percent of the pack", () => {
  assertEquals(
    unverifiedFigures("About 2,950 cal and 168g protein.", [2900, 170]),
    [],
  );
  assertEquals(unverifiedFigures("About 3,400 cal.", [2900, 170]), [
    "3,400 cal",
  ]);
  assertEquals(unverifiedFigures("Up 1.2 kg on the week.", [1]), []);
  assertEquals(unverifiedFigures("Six guys, 5 gallons of milk.", []), []);
  assertEquals(unverifiedFigures("Bench 185 lbs for 6.", [185]), []);
});

Deno.test("model text is cleaned and split into at most three bubbles", () => {
  assertEquals(
    sanitizeCoachText("[check-in 09:00] Morning.  Eat early. "),
    "Morning. Eat early.",
  );
  assertEquals(splitBubbles("One.\n\nTwo.\n\nThree.\n\nFour."), [
    "One.",
    "Two.",
    "Three. Four.",
  ]);
  assertEquals(splitBubbles("Line one\nstill one.\n\nTwo."), [
    "Line one still one.",
    "Two.",
  ]);
});

const SNAPSHOT: FallbackSnapshot = {
  name: "Luke",
  mealsLogged: 2,
  minutesSinceLastLog: 240,
  calories: { logged: 1240, target: 2900, remaining: 1660 },
  protein: { logged: 55, target: 170, remaining: 115 },
  wellbeingHold: false,
};

Deno.test("template fallbacks are themselves valid coach copy", () => {
  const figures = [1240, 2900, 1660, 55, 170, 115, 1650, 1700];
  const topics: SlotTopic[] = [
    "morning_plan",
    "breakfast",
    "snack",
    "lunch",
    "protein_gap",
    "pre_workout",
    "dinner",
    "closeout",
    "friend_checkin",
  ];
  for (const topic of topics) {
    for (const snapshot of [SNAPSHOT, { ...SNAPSHOT, mealsLogged: 0 }]) {
      const copy = fallbackSlotCopy(topic, snapshot);
      if (!copy) continue;
      const violation = coachCopyViolation(
        { skip: false, bubbles: [copy.body], push_body: copy.push_body },
        policy({ allowedFigures: figures, profanity: "off" }),
      );
      assert(violation === null, `${topic}: ${violation?.message}`);
    }
  }
  for (
    const kind of [
      "meal_ack",
      "workout_ack",
      "weigh_in_ack",
      "photo_feedback",
    ] as const
  ) {
    const copy = fallbackReactionCopy(kind, SNAPSHOT);
    assertEquals(
      coachCopyViolation(
        { skip: false, bubbles: [copy.body], push_body: copy.push_body },
        policy({ mode: "meal_ack", allowedFigures: figures, profanity: "off" }),
      ),
      null,
    );
  }
  for (const line of [CHAT_REFUSAL_FALLBACK, CHAT_FAILURE_FALLBACK]) {
    assertEquals(
      coachCopyViolation(
        { skip: false, bubbles: [line], push_body: null },
        policy({ mode: "chat_reply" }),
      ),
      null,
    );
  }
  // Silence wins: the protein nudge stays quiet once he's past 45%.
  assertEquals(
    fallbackSlotCopy("protein_gap", {
      ...SNAPSHOT,
      protein: { logged: 100, target: 170, remaining: 70 },
    }),
    null,
  );
});

Deno.test("card copy from the Train/Body/Nearby lanes goes through the same voice", () => {
  assertEquals(
    coachCardCopyGuard(
      "Four days, upper/lower. Built around your 9:30 start.",
      "plan.intro",
      {
        maxChars: 200,
      },
    ),
    "Four days, upper/lower. Built around your 9:30 start.",
  );
  let caught: unknown = null;
  try {
    coachCardCopyGuard("Let's go, you got this.", "plan.intro", {
      maxChars: 200,
    });
  } catch (error) {
    caught = error;
  }
  assert(caught instanceof CardCopyViolation);
  caught = null;
  try {
    coachCardCopyGuard("Skip breakfast and train fasted.", "plan.intro", {
      maxChars: 200,
    });
  } catch (error) {
    caught = error;
  }
  assert(caught instanceof CardCopyViolation);
});

Deno.test("the coach never narrates machinery: tools, saving, estimates, IDs", () => {
  const cases = [
    "I've logged that for you. Nice lunch.",
    "I logged the sandwich. Keep going.",
    "I'll save that to your bio.",
    "Saved it to your notes.",
    "It's in my memory now.",
    "The estimate lands in about a minute.",
    "Still analyzing the photo, hang tight.",
    "I ran a tool call to check your day.",
    "Claude here: eat more rice.",
    "Your entry_id is on the card.",
    "That meal has a confidence score of 80.",
    "Logged as a2b4c6d8-0000-4000-8000-000000000001.",
  ];
  for (const text of cases) {
    assert(violationCode(text) === "machinery", text);
  }
  // Short, human acknowledgments stay allowed.
  for (
    const text of [
      "Logged. Bench moving.",
      "You logged every slice and every beer. Respect.",
      "Anything you forgot to log?",
      "A rough guess beats a blank page.",
    ]
  ) {
    assert(violationCode(text) === null, `${violationCode(text)}: ${text}`);
  }
});

Deno.test("preambles are flagged and stripped, never the whole text", () => {
  assertEquals(violationCode("Great question. Eat at 3."), "preamble");
  assertEquals(violationCode("Sure, a shake works."), "preamble");
  assertEquals(stripPreamble("Great question. Eat at 3."), "Eat at 3.");
  assertEquals(stripPreamble("Sure thing, a shake works."), "A shake works.");
  assertEquals(stripPreamble("Absolutely. Rice and eggs."), "Rice and eggs.");
  assertEquals(stripPreamble("Sure."), "Sure.");
  // An adverb that opens a real sentence is not throat-clearing.
  assertEquals(violationCode("Definitely keep the elbows tucked."), null);
  assertEquals(
    stripPreamble("Shake at 3, then lift."),
    "Shake at 3, then lift.",
  );
});

Deno.test("text-message length: long copy is a voice problem, not a safety one", () => {
  const sentence =
    "Eat a real breakfast before work, a big lunch with rice, a shake at three, and dinner after the gym.";
  const long = [sentence, sentence, sentence, sentence].join(" ");
  const review = coachCopyReview(
    {
      skip: false,
      bubbles: [long.slice(0, 270), long.slice(0, 200)],
      push_body: null,
    },
    policy({ mode: "chat_reply" }),
  );
  assertEquals(review.safety, null);
  assertEquals(review.voice?.code, "verbose");
  // A "why" question may run long without tripping the voice limit.
  assertEquals(
    coachCopyReview(
      {
        skip: false,
        bubbles: [long.slice(0, 270), long.slice(0, 200)],
        push_body: null,
      },
      policy({ mode: "chat_reply", longForm: true }),
    ).voice,
    null,
  );
  const push =
    "Shake math: milk, two scoops, banana, peanut butter. About 850 cal in one glass. You were built on milk, remember?";
  assertEquals(pushViolationCode(push), "verbose");
  assertEquals(pushViolationCode(push, { voice: false }), null);
  // Safety still wins over voice in the review.
  const unsafe = coachCopyReview(
    {
      skip: false,
      bubbles: ["Great question. Skip dinner tonight."],
      push_body: null,
    },
    policy(),
  );
  assertEquals(unsafe.safety?.code, "extreme_diet");
  assertEquals(unsafe.voice, null);
});
