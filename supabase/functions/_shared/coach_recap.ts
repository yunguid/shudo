import type { SupabaseClient } from "jsr:@supabase/supabase-js@2.110.7";
import { assertCoachText } from "./coach_copy.ts";
import {
  coachLocalDay,
  isQuietMinute,
  isValidTimezone,
  localClock,
  localWallTimeToInstant,
  parseClock,
} from "./coach_policy.ts";
import { postCoachMessage } from "./coach_rpc.ts";

/// When the weekly summary (Opus) lands, the coach texts a short recap that
/// points at it. Deterministic copy from the computed metrics; one message
/// per week (dedupe key weekly:<week_start>), held until quiet hours end.

export type WeeklyRecapMetrics = {
  days_logged: number;
  average_calories_kcal: number;
  average_protein_g: number;
  target_calories_kcal: number;
  target_protein_g: number;
};

function weekLabel(weekStart: string): string {
  return new Intl.DateTimeFormat("en-US", {
    month: "short",
    day: "numeric",
    timeZone: "UTC",
  }).format(new Date(`${weekStart}T00:00:00Z`));
}

function calories(value: number): string {
  return (Math.round(value / 10) * 10).toLocaleString("en-US");
}

export function weeklyRecapCopy(
  weekStart: string,
  metrics: WeeklyRecapMetrics,
): { body: string; push_body: string } {
  const label = weekLabel(weekStart);
  if (metrics.days_logged <= 0) {
    return {
      body:
        `Week of ${label} is in. Quiet week on the log, so there's nothing to grade. Fresh week: log every meal and we'll have real numbers.`,
      push_body: `Week of ${label} is in. Fresh week: log every meal.`,
    };
  }
  const days = metrics.days_logged === 1
    ? "1 day"
    : `${metrics.days_logged} days`;
  return {
    body: `Week of ${label} is in: ${days} logged, averaging ${
      calories(metrics.average_calories_kcal)
    } cal and ${
      Math.round(metrics.average_protein_g)
    }g protein. The full recap is on the Body tab.`,
    push_body: `Week of ${label} recap is in: ${days} logged, ${
      calories(metrics.average_calories_kcal)
    } cal a day.`,
  };
}

type RecapProfile = {
  coach_enabled: boolean | null;
  timezone: string | null;
  coach_profanity: string | null;
  quiet_hours_start: string | null;
  quiet_hours_end: string | null;
};

/// Delivery time: now, or the end of tonight's quiet hours.
export function recapDeliverAt(now: Date, profile: RecapProfile): Date {
  const timezone = profile.timezone && isValidTimezone(profile.timezone)
    ? profile.timezone
    : "UTC";
  const quiet = {
    start: parseClock(profile.quiet_hours_start) ?? 23 * 60,
    end: parseClock(profile.quiet_hours_end) ?? 7 * 60,
  };
  const clock = localClock(now, timezone);
  if (!isQuietMinute(clock.minutes, quiet)) return now;
  const day = clock.minutes >= quiet.end
    ? new Date(now.getTime() + 86_400_000)
    : now;
  const endDay = localClock(day, timezone).calendarDay;
  const deliver = localWallTimeToInstant(endDay, quiet.end, timezone);
  return deliver.getTime() > now.getTime() ? deliver : now;
}

export async function postWeeklyRecapMessage(
  admin: SupabaseClient,
  args: {
    userId: string;
    summaryId: string;
    weekStart: string;
    headline: string;
    metrics: WeeklyRecapMetrics;
  },
  now: Date = new Date(),
): Promise<void> {
  const { data, error } = await admin.from("profiles")
    .select(
      "coach_enabled,timezone,coach_profanity,quiet_hours_start,quiet_hours_end",
    )
    .eq("user_id", args.userId)
    .maybeSingle();
  if (error) throw error;
  const profile = data as RecapProfile | null;
  if (!profile?.coach_enabled) return;
  const copy = weeklyRecapCopy(args.weekStart, args.metrics);
  const policy = {
    mode: "nightly_closeout" as const,
    profanity: "off" as const,
    emojiAllowed: false,
    allowedFigures: [
      args.metrics.days_logged,
      Math.round(args.metrics.average_calories_kcal / 10) * 10,
      Math.round(args.metrics.average_protein_g),
    ],
    pushCapable: true,
  };
  assertCoachText(copy.body, policy, "recap.body");
  assertCoachText(copy.push_body, policy, "recap.push_body");
  const deliverAt = recapDeliverAt(now, profile);
  const timezone = profile.timezone && isValidTimezone(profile.timezone)
    ? profile.timezone
    : "UTC";
  await postCoachMessage(admin, {
    userId: args.userId,
    kind: "recap",
    body: copy.body,
    payload: {
      kind: "week",
      summary_id: args.summaryId,
      week_start: args.weekStart,
      headline: args.headline,
      days_logged: args.metrics.days_logged,
      kcal: args.metrics.average_calories_kcal,
      protein_g: args.metrics.average_protein_g,
      kcal_target: args.metrics.target_calories_kcal,
      protein_target_g: args.metrics.target_protein_g,
      push_body: copy.push_body,
    },
    localDay: coachLocalDay(deliverAt, timezone),
    dedupeKey: `weekly:${args.weekStart}`,
    notify: true,
    deliverAt: deliverAt.toISOString(),
  });
}
