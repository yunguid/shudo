import type { CoachMode } from "./coach_persona.ts";

/// Pure scheduling policy for the coach's proactive texts. The model never
/// picks slots: this module decides which checkpoints exist, when they fire,
/// and whether they may notify. Same input, same plan.

export type Weekday = "sun" | "mon" | "tue" | "wed" | "thu" | "fri" | "sat";
export const WEEKDAYS: readonly Weekday[] = [
  "sun",
  "mon",
  "tue",
  "wed",
  "thu",
  "fri",
  "sat",
];

/// Structured schedule from the bio (`coach_memory.sections.schedule`).
export type CoachSchedule = {
  wake?: string | null;
  office_start?: string | null;
  office_days?: Weekday[] | null;
  lift_days?: Weekday[] | null;
  lift_time?: string | null;
  bed?: string | null;
  target_bed?: string | null;
};

export type CoachIntensity = "chill" | "locked_in" | "drill_sergeant";

export const INTENSITY_RULES: Record<
  CoachIntensity,
  { dailyCap: number; minGapMinutes: number }
> = {
  chill: { dailyCap: 4, minGapMinutes: 75 },
  locked_in: { dailyCap: 7, minGapMinutes: 75 },
  drill_sergeant: { dailyCap: 10, minGapMinutes: 40 },
};

/// The coach's day runs 04:00 to 04:00 local: a 01:00 snack belongs to the
/// day that is still being closed out.
export const COACH_DAY_BOUNDARY_MINUTES = 4 * 60;
export const POST_LOG_QUIET_MINUTES = 45;
/// Slots generated after this local time also write tomorrow's wake text.
export const TOMORROW_WAKE_AFTER_MINUTES = 18 * 60;
const SLOT_LEAD_MINUTES = 2;

export const SLOT_KEYS = [
  "wake",
  "breakfast",
  "mid_morning",
  "lunch",
  "afternoon",
  "training",
  "dinner",
  "wind_down",
] as const;
export type CoachSlotKey = typeof SLOT_KEYS[number];

export type SlotTopic =
  | "morning_plan"
  | "breakfast"
  | "snack"
  | "lunch"
  | "protein_gap"
  | "pre_workout"
  | "dinner"
  | "closeout"
  | "friend_checkin";

const SLOT_PRIORITY: Record<CoachSlotKey, number> = {
  wake: 1,
  training: 2,
  wind_down: 3,
  lunch: 4,
  afternoon: 5,
  dinner: 6,
  breakfast: 7,
  mid_morning: 8,
};

const SLOT_SHAPE: Record<
  CoachSlotKey,
  { kind: "plan" | "checkpoint" | "recap"; topic: SlotTopic; mode: CoachMode }
> = {
  wake: { kind: "plan", topic: "morning_plan", mode: "morning_plan" },
  breakfast: { kind: "checkpoint", topic: "breakfast", mode: "checkpoint_nudge" },
  mid_morning: { kind: "checkpoint", topic: "snack", mode: "checkpoint_nudge" },
  lunch: { kind: "checkpoint", topic: "lunch", mode: "checkpoint_nudge" },
  afternoon: {
    kind: "checkpoint",
    topic: "protein_gap",
    mode: "checkpoint_nudge",
  },
  training: {
    kind: "checkpoint",
    topic: "pre_workout",
    mode: "checkpoint_nudge",
  },
  dinner: { kind: "checkpoint", topic: "dinner", mode: "checkpoint_nudge" },
  wind_down: { kind: "recap", topic: "closeout", mode: "nightly_closeout" },
};

export type LocalClock = {
  /// Calendar date at the device's location.
  calendarDay: string;
  /// Minutes since local midnight (0..1439).
  minutes: number;
  /// The coach day (04:00 boundary).
  coachDay: string;
  /// Minutes since the coach day's midnight (240..1679).
  coachMinutes: number;
  weekday: Weekday;
};

function partsIn(date: Date, timezone: string): Record<string, string> {
  const parts = new Intl.DateTimeFormat("en-US", {
    timeZone: timezone,
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
    hour: "2-digit",
    minute: "2-digit",
    second: "2-digit",
    hourCycle: "h23",
  }).formatToParts(date);
  return Object.fromEntries(parts.map((part) => [part.type, part.value]));
}

export function isValidTimezone(timezone: string): boolean {
  try {
    new Intl.DateTimeFormat("en-US", { timeZone: timezone }).format();
    return true;
  } catch {
    return false;
  }
}

export function addDays(day: string, count: number): string {
  const date = new Date(`${day}T00:00:00.000Z`);
  date.setUTCDate(date.getUTCDate() + count);
  return date.toISOString().slice(0, 10);
}

export function weekdayOf(day: string): Weekday {
  return WEEKDAYS[new Date(`${day}T00:00:00.000Z`).getUTCDay()];
}

export function localClock(now: Date, timezone: string): LocalClock {
  const values = partsIn(now, timezone);
  const calendarDay = `${values.year}-${values.month}-${values.day}`;
  const minutes = Number(values.hour) * 60 + Number(values.minute);
  const early = minutes < COACH_DAY_BOUNDARY_MINUTES;
  const coachDay = early ? addDays(calendarDay, -1) : calendarDay;
  return {
    calendarDay,
    minutes,
    coachDay,
    coachMinutes: early ? minutes + 1440 : minutes,
    weekday: weekdayOf(coachDay),
  };
}

/** The coach's local day for `now` (04:00 boundary). */
export function coachLocalDay(now: Date, timezone: string): string {
  return localClock(now, timezone).coachDay;
}

export function parseClock(value: string | null | undefined): number | null {
  const match = typeof value === "string"
    ? /^([01]\d|2[0-3]):([0-5]\d)(?::[0-5]\d)?$/u.exec(value.trim())
    : null;
  return match ? Number(match[1]) * 60 + Number(match[2]) : null;
}

export function formatClock(minutes: number): string {
  const normalized = ((Math.round(minutes) % 1440) + 1440) % 1440;
  return `${String(Math.floor(normalized / 60)).padStart(2, "0")}:${
    String(normalized % 60).padStart(2, "0")
  }`;
}

function offsetMs(at: Date, timezone: string): number {
  const values = partsIn(at, timezone);
  return Date.UTC(
    Number(values.year),
    Number(values.month) - 1,
    Number(values.day),
    Number(values.hour),
    Number(values.minute),
    Number(values.second),
  ) - at.getTime();
}

/// The instant at which `day` + `minutes` (may exceed 1439 for after-midnight
/// times) occurs on the wall clock in `timezone`. DST-safe: resolves twice.
export function localWallTimeToInstant(
  day: string,
  minutes: number,
  timezone: string,
): Date {
  const [year, month, date] = day.split("-").map(Number);
  const wallAsUtc = Date.UTC(year, month - 1, date, 0, Math.round(minutes));
  let instant = new Date(wallAsUtc - offsetMs(new Date(wallAsUtc), timezone));
  instant = new Date(wallAsUtc - offsetMs(instant, timezone));
  return instant;
}

/// Quiet hours wrap midnight when start > end (23:00–07:00).
export function isQuietMinute(
  minutes: number,
  quiet: { start: number; end: number },
): boolean {
  const m = ((minutes % 1440) + 1440) % 1440;
  if (quiet.start === quiet.end) return false;
  return quiet.start < quiet.end
    ? m >= quiet.start && m < quiet.end
    : m >= quiet.start || m < quiet.end;
}

/// Times after midnight but before the day boundary belong to the night.
function nightMinutes(value: number | null, fallback: number): number {
  const minutes = value ?? fallback;
  return minutes < COACH_DAY_BOUNDARY_MINUTES ? minutes + 1440 : minutes;
}

export type SlotTime = { slot_key: CoachSlotKey; minutes: number };

/** Default slot clock times for one coach day, from the bio schedule. */
export function slotTimesForDay(
  schedule: CoachSchedule,
  day: string,
): SlotTime[] {
  const weekday = weekdayOf(day);
  const wake = parseClock(schedule.wake) ?? 7 * 60;
  const officeDays = schedule.office_days?.length
    ? schedule.office_days
    : (["mon", "tue", "wed", "thu", "fri"] as Weekday[]);
  const officeDay = officeDays.includes(weekday);
  const officeStart = parseClock(schedule.office_start) ?? 9 * 60;
  const liftDay = (schedule.lift_days ?? []).includes(weekday);
  const liftTime = parseClock(schedule.lift_time) ?? 18 * 60;
  const bed = nightMinutes(
    parseClock(schedule.target_bed) ?? parseClock(schedule.bed),
    23 * 60,
  );

  const times: SlotTime[] = [{ slot_key: "wake", minutes: wake + 10 }];
  const breakfast = officeDay
    ? Math.max(wake + 40, officeStart - 50)
    : wake + 90;
  times.push({ slot_key: "breakfast", minutes: breakfast });
  times.push({
    slot_key: "mid_morning",
    minutes: Math.max(11 * 60, breakfast + 120),
  });
  times.push({ slot_key: "lunch", minutes: 13 * 60 });
  times.push({ slot_key: "afternoon", minutes: 15 * 60 + 30 });
  let dinner = 19 * 60 + 45;
  if (liftDay) {
    const training = Math.max(liftTime - 15, 13 * 60 + 30);
    times.push({ slot_key: "training", minutes: training });
    dinner = Math.max(dinner, training + 90);
  }
  times.push({ slot_key: "dinner", minutes: dinner });
  times.push({
    slot_key: "wind_down",
    minutes: Math.max(bed - 30, dinner + 75, 21 * 60 + 30),
  });
  return times.sort((left, right) => left.minutes - right.minutes);
}

/// Expected share of the day's food by a local time, for a bulk where the
/// big risk is under-eating (13:00 35%, 16:00 55%, 19:45 80%).
export function expectedPaceShare(minutes: number, wakeMinutes = 7 * 60): number {
  const points: Array<[number, number]> = [
    [wakeMinutes, 0],
    [13 * 60, 0.35],
    [16 * 60, 0.55],
    [19 * 60 + 45, 0.8],
    [22 * 60, 0.95],
  ];
  if (minutes <= points[0][0]) return 0;
  for (let index = 1; index < points.length; index += 1) {
    const [x1, y1] = points[index];
    const [x0, y0] = points[index - 1];
    if (minutes <= x1) return y0 + (y1 - y0) * (minutes - x0) / (x1 - x0);
  }
  return 0.95;
}

export type CoachPace = {
  caloriesLogged: number;
  caloriesTarget: number;
  proteinLogged: number;
  proteinTarget: number;
};

/// More than 15 points behind the expected share earns one extra slot.
export function isBehindPace(
  pace: CoachPace | null,
  minutes: number,
  wakeMinutes?: number,
): boolean {
  if (!pace || minutes < 11 * 60) return false;
  const expected = expectedPaceShare(minutes, wakeMinutes);
  const share = (logged: number, target: number) =>
    target > 0 ? logged / target : 1;
  return share(pace.caloriesLogged, pace.caloriesTarget) < expected - 0.15 ||
    share(pace.proteinLogged, pace.proteinTarget) < expected - 0.15;
}

export type SlotPlanInput = {
  now: Date;
  timezone: string;
  schedule: CoachSchedule;
  intensity: CoachIntensity;
  quietHours: { start: string; end: string };
  /// Latest meal, activity, or check-in the user logged.
  lastLogAt: Date | null;
  /// Most recent proactive (slot) message already delivered.
  lastProactiveAt?: Date | null;
  /// Proactive messages already delivered on the current coach day.
  deliveredToday?: number;
  pace?: CoachPace | null;
  wellbeingHold?: boolean;
};

export type PlannedSlot = {
  slot_key: CoachSlotKey;
  day: "today" | "tomorrow";
  local_day: string;
  deliver_local: string;
  deliver_at: string;
  notify: boolean;
  kind: "plan" | "checkpoint" | "recap";
  topic: SlotTopic;
  mode: CoachMode;
};

function slotFor(
  slot: SlotTime,
  day: string,
  dayLabel: "today" | "tomorrow",
  input: SlotPlanInput,
  quiet: { start: number; end: number },
): PlannedSlot {
  const shape = input.wellbeingHold
    ? {
      kind: "checkpoint" as const,
      topic: "friend_checkin" as const,
      mode: "checkpoint_nudge" as const,
    }
    : SLOT_SHAPE[slot.slot_key];
  return {
    slot_key: slot.slot_key,
    day: dayLabel,
    local_day: day,
    deliver_local: formatClock(slot.minutes),
    deliver_at: localWallTimeToInstant(day, slot.minutes, input.timezone)
      .toISOString(),
    notify: !isQuietMinute(slot.minutes, quiet),
    ...shape,
  };
}

/**
 * The remaining proactive slots for the current coach day (plus tomorrow's
 * wake text after 18:00): post-log quiet, minimum spacing, the intensity
 * cap (raised by one when behind pace), and quiet hours (notify=false).
 */
export function planCoachSlots(input: SlotPlanInput): PlannedSlot[] {
  const clock = localClock(input.now, input.timezone);
  const rules = INTENSITY_RULES[input.intensity] ?? INTENSITY_RULES.locked_in;
  const quiet = {
    start: parseClock(input.quietHours.start) ?? 23 * 60,
    end: parseClock(input.quietHours.end) ?? 7 * 60,
  };
  const nowMs = input.now.getTime();
  const lastLogMs = input.lastLogAt?.getTime() ?? null;
  const allowedKeys: ReadonlySet<CoachSlotKey> = input.wellbeingHold
    ? new Set<CoachSlotKey>(["wake", "wind_down"])
    : new Set(SLOT_KEYS);

  const candidates = slotTimesForDay(input.schedule, clock.coachDay)
    .filter((slot) => allowedKeys.has(slot.slot_key))
    .map((slot) => slotFor(slot, clock.coachDay, "today", input, quiet))
    .filter((slot) => {
      const at = Date.parse(slot.deliver_at);
      if (at < nowMs + SLOT_LEAD_MINUTES * 60_000) return false;
      if (
        lastLogMs !== null && at >= lastLogMs &&
        at < lastLogMs + POST_LOG_QUIET_MINUTES * 60_000
      ) return false;
      return true;
    });

  const wakeMinutes = parseClock(input.schedule.wake) ?? 7 * 60;
  const behind = !input.wellbeingHold &&
    isBehindPace(input.pace ?? null, clock.coachMinutes, wakeMinutes);
  const baseCap = input.wellbeingHold ? 2 : rules.dailyCap;
  const remaining = Math.max(
    0,
    baseCap + (behind ? 1 : 0) - (input.deliveredToday ?? 0),
  );
  const gapMs = rules.minGapMinutes * 60_000;
  const anchors: number[] = input.lastProactiveAt
    ? [input.lastProactiveAt.getTime()]
    : [];
  const accepted: PlannedSlot[] = [];
  const byPriority = [...candidates].sort((left, right) =>
    SLOT_PRIORITY[left.slot_key] - SLOT_PRIORITY[right.slot_key]
  );
  for (const slot of byPriority) {
    if (accepted.length >= remaining) break;
    const at = Date.parse(slot.deliver_at);
    const tooClose = [...anchors, ...accepted.map((kept) => Date.parse(kept.deliver_at))]
      .some((other) => Math.abs(other - at) < gapMs);
    if (tooClose) continue;
    accepted.push(slot);
  }

  if (clock.coachMinutes >= TOMORROW_WAKE_AFTER_MINUTES) {
    const tomorrow = addDays(clock.coachDay, 1);
    const wake = slotTimesForDay(input.schedule, tomorrow)
      .find((slot) => slot.slot_key === "wake");
    if (wake) {
      const planned = slotFor(wake, tomorrow, "tomorrow", input, quiet);
      if (Date.parse(planned.deliver_at) > nowMs) accepted.push(planned);
    }
  }

  return accepted.sort((left, right) =>
    Date.parse(left.deliver_at) - Date.parse(right.deliver_at)
  );
}

/** Mode used to render a slot's copy. */
export function slotMode(slotKey: CoachSlotKey): CoachMode {
  return SLOT_SHAPE[slotKey].mode;
}
