import type { SlotTopic } from "./coach_policy.ts";

/// Deterministic coach-voice copy used when the model refuses, fails, or
/// keeps breaking the guard. Ported from the app's DayNudgePolicy (lunch
/// log check, protein check, evening close-out) so nothing regresses. Each
/// line reads like a friend's text on a lock screen: no preamble, one idea,
/// at most 90 characters. Every figure comes from the snapshot passed in;
/// the tests run these through assertCoachCopy.

export type FallbackSnapshot = {
  name: string | null;
  mealsLogged: number;
  minutesSinceLastLog: number | null;
  calories: { logged: number; target: number; remaining: number };
  protein: { logged: number; target: number; remaining: number };
  wellbeingHold: boolean;
};

export type FallbackCopy = { body: string; push_body: string };

function kcal(value: number): string {
  return Math.max(0, Math.round(value / 10) * 10).toLocaleString("en-US");
}

function grams(value: number): string {
  return String(Math.max(0, Math.round(value)));
}

function same(text: string): FallbackCopy {
  return { body: text, push_body: text };
}

/** Copy for one proactive slot, or null when silence is the better call. */
export function fallbackSlotCopy(
  topic: SlotTopic,
  snapshot: FallbackSnapshot,
): FallbackCopy | null {
  if (snapshot.wellbeingHold || topic === "friend_checkin") {
    return same("Checking in on you, not the numbers. How's today going?");
  }
  switch (topic) {
    case "morning_plan":
      return same("Morning. Eat before you walk out and the rest gets easy.");
    case "breakfast":
      if (snapshot.mealsLogged > 0) return null;
      return same("Breakfast first. Eggs, rice, fruit, the classic.");
    case "snack":
      return same("Snack window. Yogurt, a shake, or a banana with PB.");
    case "lunch":
      if (snapshot.mealsLogged === 0) {
        return same(
          "Nothing logged yet. Anything you ate that I don't know about?",
        );
      }
      if ((snapshot.minutesSinceLastLog ?? 0) < 180) return null;
      return same("Make lunch a real one, and log it while it's fresh.");
    case "protein_gap": {
      const { logged, target, remaining } = snapshot.protein;
      if (
        snapshot.mealsLogged === 0 || target <= 0 || logged >= target * 0.45
      ) {
        return null;
      }
      return same(
        `${grams(logged)}g protein so far, ${
          grams(remaining)
        }g to go. Anything I missed?`,
      );
    }
    case "pre_workout":
      return same("Lift day. Eat an hour out, then go move some weight.");
    case "dinner": {
      if (snapshot.mealsLogged === 0) return null;
      return snapshot.calories.remaining >= 300
        ? same(
          `About ${
            kcal(snapshot.calories.remaining)
          } cal left. Make dinner the big one.`,
        )
        : null;
    }
    case "closeout": {
      const { target, remaining } = snapshot.calories;
      if (
        snapshot.mealsLogged > 0 && target > 0 &&
        remaining >= Math.min(target * 0.25, 400)
      ) {
        return same(
          `About ${kcal(remaining)} cal short tonight. Anything still to log?`,
        );
      }
      return same("Kitchen's closing. Milk if you're short, then bed on time.");
    }
    default:
      return null;
  }
}

export type ReactionKind =
  | "meal_ack"
  | "workout_ack"
  | "weigh_in_ack"
  | "photo_feedback";

export function fallbackReactionCopy(
  kind: ReactionKind,
  snapshot: FallbackSnapshot,
): FallbackCopy {
  if (snapshot.wellbeingHold) return same("Thanks for logging it.");
  switch (kind) {
    case "meal_ack":
      if (snapshot.calories.remaining <= 0) {
        return same("That covers today's number. Normal day tomorrow.");
      }
      return same(
        `${snapshot.mealsLogged <= 1 ? "Good start. " : ""}${
          kcal(snapshot.calories.remaining)
        } cal and ${grams(snapshot.protein.remaining)}g protein to go.`,
      );
    case "workout_ack":
      return same("Good work. Protein in the next couple hours, then sleep.");
    case "weigh_in_ack":
      return same("One weigh-in is noise. The trend decides.");
    case "photo_feedback":
      return same("Photo's in. Same light, same pose; we judge it in weeks.");
  }
}

/// In-character line when the chat model declines.
export const CHAT_REFUSAL_FALLBACK =
  "That one's outside my lane. Ask me about food, training, or your day.";

/// In-character line when a chat turn runs out of time or breaks.
export const CHAT_FAILURE_FALLBACK =
  "Lost my train of thought there. Hit me again.";

/// Static, server-written support card for the wellbeing hold. Never model
/// output; phone numbers live only here.
export const WELLBEING_RESOURCES = [
  {
    name: "ANAD Helpline",
    detail: "(888) 375-7767, Mon–Fri",
    url: "https://anad.org/get-support/eating-disorders-helpline/",
  },
  {
    name: "988 Lifeline",
    detail: "Call or text 988, any time",
    url: "https://988lifeline.org",
  },
];

export const WELLBEING_CARD_BODY =
  "If any of this is weighing on you, you don't have to carry it alone. ANAD Helpline: (888) 375-7767, Mon–Fri. Or call or text 988, any time.";
