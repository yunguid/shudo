// PLACEHOLDER: replaced by lane B3. Only the SPEC §4 types and signatures
// exist here so the coach brain (lane B2) compiles; drafting fails until B3
// merges.
import type { SupabaseClient } from "jsr:@supabase/supabase-js@2.110.7";

export type TrainingPlanDoc = {
  version: 1;
  name: string;
  phase: string;
  sessions_per_week: number;
  rotation: string[];
  sessions: Array<{
    id: string;
    name: string;
    focus: string;
    est_minutes: number;
    exercises: Array<{
      name: string;
      sets: number;
      rep_min: number;
      rep_max: number;
      rest_sec: number;
      progression: string;
      increment_lb: number;
      cue: string;
    }>;
  }>;
  conditioning: {
    kind: string;
    minutes: number;
    when: string;
    optional: boolean;
  } | null;
  equipment_assumed: string[];
  notes: string;
};

export function draftTrainingPlan(
  _admin: SupabaseClient,
  _userId: string,
  _input: {
    instructions: string | null;
    reason: "first_plan" | "user_request" | "weekly";
  },
): Promise<{ planId: string; plan: TrainingPlanDoc; summary: string }> {
  return Promise.reject(new Error("Training plans are not available yet"));
}

export function nextSession(
  _plan: TrainingPlanDoc,
  _completedSessionIds: string[],
): string {
  throw new Error("Training plans are not available yet");
}
