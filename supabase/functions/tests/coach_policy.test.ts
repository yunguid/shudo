import {
  coachLocalDay,
  type CoachSchedule,
  expectedPaceShare,
  isQuietMinute,
  localClock,
  localWallTimeToInstant,
  planCoachSlots,
  type SlotPlanInput,
  slotTimesForDay,
} from "../_shared/coach_policy.ts";
import { assert, assertEquals } from "./assertions.ts";

/// Luke's schedule from his bio: office 09:30 six days a week, lifting four
/// evenings, bed 23:30 with an earlier target.
const LUKE: CoachSchedule = {
  wake: "07:00",
  office_start: "09:30",
  office_days: ["mon", "tue", "wed", "thu", "fri", "sat"],
  lift_days: ["mon", "wed", "fri", "sat"],
  lift_time: "18:15",
  bed: "23:30",
  target_bed: "23:00",
};
const NY = "America/New_York";

function input(overrides: Partial<SlotPlanInput>): SlotPlanInput {
  return {
    now: new Date("2026-10-05T10:00:00Z"), // Monday 06:00 EDT
    timezone: NY,
    schedule: LUKE,
    intensity: "locked_in",
    quietHours: { start: "23:00", end: "07:00" },
    lastLogAt: null,
    ...overrides,
  };
}

const keys = (slots: ReturnType<typeof planCoachSlots>) =>
  slots.map((slot) =>
    slot.day === "tomorrow" ? `tomorrow:${slot.slot_key}` : slot.slot_key
  );

Deno.test("slot times follow Luke's lift-day schedule", () => {
  assertEquals(
    slotTimesForDay(LUKE, "2026-10-05").map((slot) => slot.slot_key),
    [
      "wake",
      "breakfast",
      "mid_morning",
      "lunch",
      "afternoon",
      "training",
      "dinner",
      "wind_down",
    ],
  );
  const times = Object.fromEntries(
    slotTimesForDay(LUKE, "2026-10-05").map((
      slot,
    ) => [slot.slot_key, slot.minutes]),
  );
  assertEquals(times.wake, 7 * 60 + 10);
  assertEquals(times.breakfast, 8 * 60 + 40); // 50 min before the office
  assertEquals(times.training, 18 * 60); // 15 min before the lift
  assertEquals(times.wind_down, 22 * 60 + 30); // 30 min before target bed
});

Deno.test("rest days drop training and move breakfast off the office clock", () => {
  const sunday = slotTimesForDay(LUKE, "2026-10-04");
  assertEquals(sunday.some((slot) => slot.slot_key === "training"), false);
  assertEquals(
    sunday.find((slot) => slot.slot_key === "breakfast")?.minutes,
    8 * 60 + 30,
  );
});

Deno.test("locked_in caps the day at seven texts, dropping the lowest priority", () => {
  const slots = planCoachSlots(input({}));
  assertEquals(keys(slots), [
    "wake",
    "breakfast",
    "lunch",
    "afternoon",
    "training",
    "dinner",
    "wind_down",
  ]);
  assertEquals(slots[0].deliver_at, "2026-10-05T11:10:00.000Z");
  assertEquals(slots[0].deliver_local, "07:10");
  assertEquals(slots[0].mode, "morning_plan");
  assertEquals(slots.at(-1)?.mode, "nightly_closeout");
  assert(slots.every((slot) => slot.notify), "No slot falls in quiet hours");
});

Deno.test("intensity sets the cap: chill keeps four, drill sergeant keeps all", () => {
  assertEquals(keys(planCoachSlots(input({ intensity: "chill" }))), [
    "wake",
    "lunch",
    "training",
    "wind_down",
  ]);
  assertEquals(
    planCoachSlots(input({ intensity: "drill_sergeant" })).length,
    8,
  );
});

Deno.test("nothing is scheduled within 45 minutes after a log", () => {
  const slots = planCoachSlots(input({
    now: new Date("2026-10-05T16:40:00Z"), // 12:40 EDT
    lastLogAt: new Date("2026-10-05T16:30:00Z"), // logged 12:30
    deliveredToday: 3,
  }));
  assertEquals(keys(slots), ["afternoon", "training", "dinner", "wind_down"]);
});

Deno.test("proactive texts keep a 75 minute gap from the last one delivered", () => {
  const slots = planCoachSlots(input({
    now: new Date("2026-10-05T16:35:00Z"), // 12:35 EDT
    lastProactiveAt: new Date("2026-10-05T16:30:00Z"),
    deliveredToday: 2,
  }));
  assertEquals(slots.some((slot) => slot.slot_key === "lunch"), false);
});

Deno.test("evening plans also write tomorrow's wake text", () => {
  const slots = planCoachSlots(input({
    now: new Date("2026-10-06T00:00:00Z"), // Monday 20:00 EDT
    deliveredToday: 5,
  }));
  assertEquals(keys(slots), ["wind_down", "tomorrow:wake"]);
  const wake = slots[1];
  assertEquals(wake.local_day, "2026-10-06");
  assertEquals(wake.deliver_at, "2026-10-06T11:10:00.000Z");
});

Deno.test("the coach day ends at 04:00, not midnight", () => {
  const lateNight = new Date("2026-10-06T05:30:00Z"); // 01:30 EDT Tuesday
  assertEquals(coachLocalDay(lateNight, NY), "2026-10-05");
  const clock = localClock(lateNight, NY);
  assertEquals(clock.calendarDay, "2026-10-06");
  assertEquals(clock.coachMinutes, 25 * 60 + 30);
  assertEquals(
    coachLocalDay(new Date("2026-10-06T08:30:00Z"), NY),
    "2026-10-06",
  );
  const slots = planCoachSlots(input({ now: lateNight, deliveredToday: 7 }));
  assertEquals(keys(slots), ["tomorrow:wake"]);
  assertEquals(slots[0].local_day, "2026-10-06");
});

Deno.test("quiet hours keep the text but silence the notification", () => {
  const slots = planCoachSlots(
    input({ quietHours: { start: "22:00", end: "07:00" } }),
  );
  assertEquals(
    slots.find((slot) => slot.slot_key === "wind_down")?.notify,
    false,
  );
  assertEquals(isQuietMinute(23 * 60, { start: 22 * 60, end: 7 * 60 }), true);
  assertEquals(isQuietMinute(6 * 60, { start: 22 * 60, end: 7 * 60 }), true);
  assertEquals(isQuietMinute(12 * 60, { start: 22 * 60, end: 7 * 60 }), false);
});

Deno.test("falling well behind pace on a bulk earns one extra text", () => {
  const base = input({
    now: new Date("2026-10-05T20:30:00Z"), // 16:30 EDT
    deliveredToday: 7,
  });
  assertEquals(planCoachSlots(base).length, 0);
  const behind = planCoachSlots({
    ...base,
    pace: {
      caloriesLogged: 500,
      caloriesTarget: 2900,
      proteinLogged: 40,
      proteinTarget: 170,
    },
  });
  assertEquals(keys(behind), ["training"]);
  assertEquals(expectedPaceShare(13 * 60), 0.35);
  assertEquals(expectedPaceShare(19 * 60 + 45), 0.8);
});

Deno.test("a wellbeing hold leaves only two friend check-ins", () => {
  const slots = planCoachSlots(input({ wellbeingHold: true }));
  assertEquals(keys(slots), ["wake", "wind_down"]);
  assert(slots.every((slot) => slot.topic === "friend_checkin"));
});

Deno.test("local wall times convert across daylight saving changes", () => {
  assertEquals(
    localWallTimeToInstant("2026-11-01", 7 * 60 + 10, NY).toISOString(),
    "2026-11-01T12:10:00.000Z",
  );
  assertEquals(
    localWallTimeToInstant("2026-03-08", 7 * 60 + 10, NY).toISOString(),
    "2026-03-08T11:10:00.000Z",
  );
  assertEquals(
    localWallTimeToInstant("2026-10-05", 24 * 60 + 30, NY).toISOString(),
    "2026-10-06T04:30:00.000Z",
  );
});
