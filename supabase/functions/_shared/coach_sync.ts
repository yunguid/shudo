import type { SupabaseClient } from "jsr:@supabase/supabase-js@2.110.7";
import {
  type CoachPlanOutcome,
  type CoachPlanTrigger,
  runCoachPlan,
} from "./coach_plan.ts";
import { isValidTimezone } from "./coach_policy.ts";
import { getCoachRuns } from "./coach_rpc.ts";
import { HttpError } from "./errors.ts";
import { isUuid, TimeoutError, withTimeout } from "./http.ts";
import {
  type LocationContext,
  sanitizeLocationContext,
} from "./nearby_food.ts";

/// coach_sync: the app reports device context and asks the coach to re-plan
/// when its state changed. The plan run is idempotent per state fingerprint,
/// so a sync with nothing new costs a few queries and no model call.

export const COACH_SYNC_WAIT_MS = 25_000;

export type CoachSyncTrigger =
  | "foreground"
  | "meal_complete"
  | "activity_complete"
  | "checkin"
  | "settings"
  | "bg_refresh"
  | "chat";

const TRIGGERS: readonly CoachSyncTrigger[] = [
  "foreground",
  "meal_complete",
  "activity_complete",
  "checkin",
  "settings",
  "bg_refresh",
  "chat",
];

export type CoachSyncDevice = {
  deviceId: string;
  appVersion: string | null;
  osVersion: string | null;
  notificationStatus:
    | "authorized"
    | "denied"
    | "not_determined"
    | "provisional"
    | "ephemeral";
  locationStatus:
    | "when_in_use"
    | "denied"
    | "not_determined"
    | "restricted"
    | "always";
};

export type CoachSyncRequest = {
  trigger: CoachSyncTrigger;
  localDay: string | null;
  timezone: string;
  entryId: string | null;
  activityId: string | null;
  device: CoachSyncDevice | null;
  location: LocationContext | null;
  wait: boolean;
};

function shortText(value: unknown, max: number): string | null {
  return typeof value === "string" && value.trim()
    ? value.trim().slice(0, max)
    : null;
}

function uuidOrNull(value: unknown): string | null {
  return typeof value === "string" && isUuid(value.trim())
    ? value.trim().toLowerCase()
    : null;
}

export function parseCoachSyncRequest(value: unknown): CoachSyncRequest {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new HttpError(400, "Expected a JSON object");
  }
  const object = value as Record<string, unknown>;
  const timezone = typeof object.timezone === "string"
    ? object.timezone.trim()
    : "";
  if (!isValidTimezone(timezone)) {
    throw new HttpError(400, "timezone is not a valid IANA timezone");
  }
  const localDay = typeof object.local_day === "string" &&
      /^\d{4}-\d{2}-\d{2}$/u.test(object.local_day)
    ? object.local_day
    : null;
  const deviceSource = object.device && typeof object.device === "object"
    ? object.device as Record<string, unknown>
    : null;
  const deviceId = uuidOrNull(deviceSource?.device_id);
  const notification = deviceSource?.notification_status;
  const location = deviceSource?.location_status;
  return {
    trigger: TRIGGERS.includes(object.trigger as CoachSyncTrigger)
      ? object.trigger as CoachSyncTrigger
      : "foreground",
    localDay,
    timezone,
    entryId: uuidOrNull(object.entry_id),
    activityId: uuidOrNull(object.activity_id),
    device: deviceSource && deviceId
      ? {
        deviceId,
        appVersion: shortText(deviceSource.app_version, 32),
        osVersion: shortText(deviceSource.os_version, 32),
        notificationStatus:
          notification === "authorized" || notification === "denied" ||
            notification === "provisional" || notification === "ephemeral"
            ? notification
            : "not_determined",
        locationStatus: location === "when_in_use" || location === "denied" ||
            location === "restricted" || location === "always"
          ? location
          : "not_determined",
      }
      : null,
    location: object.location && typeof object.location === "object"
      ? sanitizeLocationContext(object.location)
      : null,
    wait: object.wait === true,
  };
}

/// The device_snapshots row for this sync: permissions, timezone, locality
/// and the latest nearby store list. Never coordinates.
export function deviceSnapshotRow(
  userId: string,
  request: CoachSyncRequest,
  now: Date,
): Record<string, unknown> | null {
  if (!request.device) return null;
  const row: Record<string, unknown> = {
    user_id: userId,
    device_id: request.device.deviceId,
    platform: "ios",
    app_version: request.device.appVersion,
    os_version: request.device.osVersion,
    timezone: request.timezone,
    notification_status: request.device.notificationStatus,
    location_status: request.device.locationStatus,
    last_seen_at: now.toISOString(),
  };
  const location = request.location;
  if (location && location.quality !== "none") {
    const country = location.locality.country?.trim().toUpperCase() ?? null;
    Object.assign(row, {
      neighborhood: location.locality.neighborhood ?? null,
      city: location.locality.city ?? null,
      region: location.locality.region ?? null,
      country_code: country && /^[A-Z]{2}$/u.test(country) ? country : null,
      nearby: location.stores,
      nearby_captured_at: location.captured_at &&
          Number.isFinite(Date.parse(location.captured_at))
        ? location.captured_at
        : now.toISOString(),
    });
  }
  return row;
}

const PLAN_TRIGGER: Record<CoachSyncTrigger, CoachPlanTrigger> = {
  foreground: "foreground",
  meal_complete: "meal_complete",
  activity_complete: "activity_complete",
  checkin: "checkin",
  settings: "settings",
  bg_refresh: "bg_refresh",
  chat: "chat",
};

export type CoachSyncDependencies = {
  observe: (promise: Promise<unknown>) => void;
  now?: () => Date;
  runPlan?: typeof runCoachPlan;
  waitMs?: number;
  pollMs?: number;
};

export type CoachSyncResponse = {
  plan_run_id: string | null;
  generated: boolean;
  server_time: string;
};

function delay(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

/// When another trigger is already planning this state, wait for that run
/// instead of starting a second one.
async function waitForRun(
  admin: SupabaseClient,
  userId: string,
  runId: string,
  deadline: number,
  pollMs: number,
): Promise<boolean> {
  while (Date.now() < deadline) {
    const [run] = await getCoachRuns(admin, { userId, runId, limit: 1 });
    if (!run) return false;
    if (!run.live) return run.status === "complete";
    await delay(pollMs);
  }
  return false;
}

export async function handleCoachSync(
  admin: SupabaseClient,
  userId: string,
  request: CoachSyncRequest,
  dependencies: CoachSyncDependencies,
): Promise<CoachSyncResponse> {
  const now = dependencies.now?.() ?? new Date();
  const row = deviceSnapshotRow(userId, request, now);
  if (row) {
    const { error } = await admin.from("device_snapshots")
      .upsert(row, { onConflict: "user_id,device_id" });
    if (error) {
      // Device context is best effort; planning still runs.
      console.warn("coach_device_snapshot_failed", { message: error.message });
    }
  }

  const plan = (dependencies.runPlan ?? runCoachPlan)(admin, {
    userId,
    trigger: PLAN_TRIGGER[request.trigger],
    entryId: request.entryId,
    activityId: request.activityId,
    foreground: request.trigger !== "bg_refresh",
    timezone: request.timezone,
  }, { now: () => now });
  const settled = plan.catch((error): CoachPlanOutcome => {
    console.error("coach_sync_plan_failed", { message: String(error) });
    return { status: "failed", runId: null, generated: false, messageIds: [] };
  });
  dependencies.observe(settled);
  const response = (outcome: CoachPlanOutcome | null, generated?: boolean) => ({
    plan_run_id: outcome?.runId ?? null,
    generated: generated ?? outcome?.generated ?? false,
    server_time: new Date().toISOString(),
  });
  if (!request.wait) return response(null);

  const waitMs = dependencies.waitMs ?? COACH_SYNC_WAIT_MS;
  const deadline = Date.now() + waitMs;
  try {
    const outcome = await withTimeout(settled, waitMs, "Coach plan");
    if (outcome.status === "running" && outcome.runId) {
      const finished = await waitForRun(
        admin,
        userId,
        outcome.runId,
        deadline,
        dependencies.pollMs ?? 1_000,
      );
      return response(outcome, finished);
    }
    return response(outcome);
  } catch (error) {
    if (error instanceof TimeoutError) return response(null);
    throw error;
  }
}
