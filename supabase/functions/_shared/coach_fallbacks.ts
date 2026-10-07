import type { SlotTopic } from "./coach_policy.ts";

/// Deterministic coach-voice copy used when the model refuses, fails, or
/// keeps breaking the guard. Ported from the app's DayNudgePolicy (lunch
/// log check, protein check, evening close-out) so nothing regresses. Every
/// figure comes from the snapshot passed in; the tests run these through
/// assertCoachCopy.

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

/** Copy for one proactive slot, or null when silence is the better call. */
export function fallbackSlotCopy(
  topic: SlotTopic,
  snapshot: FallbackSnapshot,
): FallbackCopy | null {
  if (snapshot.wellbeingHold || topic === "friend_checkin") {
    const text = "Checking in on you, not the numbers. How's today going?";
    return { body: text, push_body: text };
  }
  const name = snapshot.name ? `${snapshot.name}, ` : "";
  switch (topic) {
    case "morning_plan": {
      const text = `Morning. ${kcal(snapshot.calories.target)} cal and ${
        grams(snapshot.protein.target)
      }g protein today. Breakfast before you walk out.`;
      return { body: text, push_body: text };
    }
    case "breakfast":
      if (snapshot.mealsLogged > 0) return null;
      return {
        body: "Breakfast first, then the day. Eggs, rice, fruit, the classic.",
        push_body: "Breakfast first, then the day. Eggs, rice, fruit.",
      };
    case "snack":
      return {
        body: "Desk snack window. Yogurt, a shake, or a banana with peanut butter.",
        push_body: "Desk snack window. Yogurt, a shake, or a banana with PB.",
      };
    case "lunch":
      if (snapshot.mealsLogged === 0) {
        return {
          body: "Nothing logged yet today. Anything you ate that I don't know about?",
          push_body: "Nothing logged yet today. Anything you ate that I don't know about?",
        };
      }
      if ((snapshot.minutesSinceLastLog ?? 0) < 180) return null;
      return {
        body: "Lunch logged while it's fresh keeps the trend honest. Make it a real one.",
        push_body: "Log lunch while it's fresh. Make it a real one.",
      };
    case "protein_gap": {
      const { logged, target, remaining } = snapshot.protein;
      if (snapshot.mealsLogged === 0 || target <= 0 || logged >= target * 0.45) {
        return null;
      }
      const text = `${name}${grams(logged)}g protein logged so far. ${
        grams(remaining)
      }g more gets you to ${grams(target)}g. Log anything I missed first.`;
      return { body: text, push_body: text };
    }
    case "pre_workout":
      return {
        body: "Lift day. Eat something an hour out, then go move some weight.",
        push_body: "Lift day. Eat an hour out, then go move some weight.",
      };
    case "dinner": {
      if (snapshot.mealsLogged === 0) return null;
      const text = `About ${
        kcal(snapshot.calories.remaining)
      } cal left on today's number. Make dinner the big meal.`;
      return snapshot.calories.remaining >= 300 ? { body: text, push_body: text } : null;
    }
    case "closeout": {
      const { logged, target, remaining } = snapshot.calories;
      if (snapshot.mealsLogged > 0 && target > 0 && remaining >= Math.min(target * 0.25, 400)) {
        const text = `${kcal(logged)} cal logged, about ${
          kcal(remaining)
        } under your number. Anything still to log?`;
        return { body: text, push_body: text };
      }
      return {
        body: "Kitchen's closing. Something with milk if you're short, then bed on time.",
        push_body: "Kitchen's closing. Milk if you're short, then bed on time.",
      };
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
  if (snapshot.wellbeingHold) {
    const text = "Got it, thanks for logging it.";
    return { body: text, push_body: text };
  }
  switch (kind) {
    case "meal_ack": {
      const text = snapshot.calories.remaining > 0
        ? `Got it. ${kcal(snapshot.calories.remaining)} cal and ${
          grams(snapshot.protein.remaining)
        }g protein left today.`
        : "Got it. That covers today's number. Normal day tomorrow.";
      return { body: text, push_body: text };
    }
    case "workout_ack": {
      const text = "Session logged. Get protein in over the next couple hours, then sleep.";
      return { body: text, push_body: text };
    }
    case "weigh_in_ack": {
      const text = "Check-in's in. One day is noise; the trend decides.";
      return { body: text, push_body: text };
    }
    case "photo_feedback": {
      const text = "Photo's in. Same light, same pose, and we compare over weeks, not days.";
      return { body: text, push_body: text };
    }
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
  { name: "988 Lifeline", detail: "Call or text 988, any time", url: "https://988lifeline.org" },
];

export const WELLBEING_CARD_BODY =
  "If any of this is weighing on you, you don't have to carry it alone. ANAD Helpline: (888) 375-7767, Mon–Fri. Or call or text 988, any time.";
