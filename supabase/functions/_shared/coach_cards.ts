import type { SupabaseClient } from "jsr:@supabase/supabase-js@2.110.7";
import { numeric } from "./coach_context.ts";
import { applyGoalSnapshot, type GoalSnapshot } from "./coach_goals.ts";
import { parseMemorySections, renderMemoryDocument } from "./coach_memory.ts";
import {
  activateTrainingPlanRpc,
  COACH_MESSAGE_COLUMNS,
  type CoachMessageRow,
  discardTrainingPlanDraftRpc,
  saveCoachMemoryRpc,
} from "./coach_rpc.ts";
import { HttpError } from "./errors.ts";

/// Deterministic card actions (Apply / Discard / Undo / Activate): no model
/// call, idempotent by status, and every write re-checks ownership.

export type CoachCardActionKind =
  | "goal_change"
  | "training_plan"
  | "bio_update"
  | "nearby";
export type CoachCardDecision = "apply" | "discard" | "undo" | "activate";

export type CoachCardAction = {
  kind: CoachCardActionKind;
  id: string;
  decision: CoachCardDecision;
};

export type CardActionDependencies = {
  now?: () => Date;
  /// Logs a snack the coach recommended as a text meal ("Ate it").
  logMealText?: (
    description: string,
    clientRequestId: string,
  ) => Promise<string>;
  /// Refreshes the coach plan after a state change.
  refreshPlan?: () => void;
};

const MESSAGE_KIND: Record<CoachCardActionKind, string> = {
  goal_change: "goal_change",
  training_plan: "training_plan",
  bio_update: "profile_update",
  nearby: "snack_rec",
};

const PAYLOAD_ID_FIELD: Record<CoachCardActionKind, string> = {
  goal_change: "change_id",
  training_plan: "plan_id",
  bio_update: "change_id",
  nearby: "rec_id",
};

async function findCardMessages(
  admin: SupabaseClient,
  userId: string,
  action: CoachCardAction,
): Promise<CoachMessageRow[]> {
  const kind = MESSAGE_KIND[action.kind];
  const byId = await admin.from("coach_messages")
    .select(COACH_MESSAGE_COLUMNS)
    .eq("user_id", userId)
    .eq("kind", kind)
    .eq("id", action.id)
    .limit(1);
  if (byId.error) throw byId.error;
  if (byId.data && byId.data.length > 0) return byId.data as CoachMessageRow[];
  const byPayload = await admin.from("coach_messages")
    .select(COACH_MESSAGE_COLUMNS)
    .eq("user_id", userId)
    .eq("kind", kind)
    .eq(`payload->>${PAYLOAD_ID_FIELD[action.kind]}`, action.id)
    .order("deliver_at", { ascending: false })
    .limit(5);
  if (byPayload.error) throw byPayload.error;
  return (byPayload.data ?? []) as CoachMessageRow[];
}

async function updatePayload(
  admin: SupabaseClient,
  userId: string,
  message: CoachMessageRow,
  patch: Record<string, unknown>,
): Promise<CoachMessageRow> {
  const { data, error } = await admin.from("coach_messages")
    .update({ payload: { ...message.payload, ...patch } })
    .eq("id", message.id)
    .eq("user_id", userId)
    .select(COACH_MESSAGE_COLUMNS)
    .maybeSingle();
  if (error) throw error;
  if (!data) throw new HttpError(404, "That card is gone");
  return data as CoachMessageRow;
}

function snapshot(value: unknown): GoalSnapshot {
  const object = value && typeof value === "object"
    ? value as Record<string, unknown>
    : {};
  return {
    goal_type: object.goal_type === "lose" || object.goal_type === "gain"
      ? object.goal_type
      : "maintain",
    target_weight_kg:
      object.target_weight_kg === null || object.target_weight_kg === undefined
        ? null
        : numeric(object.target_weight_kg),
    goal_date: typeof object.goal_date === "string" ? object.goal_date : null,
    calories_kcal: numeric(object.calories_kcal),
    protein_g: numeric(object.protein_g),
    carbs_g: numeric(object.carbs_g),
    fat_g: numeric(object.fat_g),
  };
}

async function goalChangeAction(
  admin: SupabaseClient,
  userId: string,
  message: CoachMessageRow,
  decision: CoachCardDecision,
  dependencies: CardActionDependencies,
): Promise<CoachMessageRow[]> {
  const status = message.payload.status;
  const before = snapshot(message.payload.before);
  const after = snapshot(message.payload.after);
  const today = (dependencies.now?.() ?? new Date()).toISOString().slice(0, 10);
  if (decision === "apply") {
    if (status === "applied") return [message];
    if (status !== "needs_confirmation") {
      throw new HttpError(409, "This change can't be applied now");
    }
    const result = await applyGoalSnapshot(admin, userId, before, after, {
      today: message.local_day ?? today,
      currentWeightKg: null,
    });
    if (result === "conflict") {
      throw new HttpError(
        409,
        "Your goals changed since this card. Ask the coach again.",
      );
    }
    dependencies.refreshPlan?.();
    return [await updatePayload(admin, userId, message, { status: "applied" })];
  }
  if (decision === "discard") {
    if (status === "discarded") return [message];
    if (status !== "needs_confirmation") {
      throw new HttpError(409, "This change was already applied");
    }
    return [
      await updatePayload(admin, userId, message, { status: "discarded" }),
    ];
  }
  if (decision === "undo") {
    if (status === "undone") return [message];
    if (status !== "applied") {
      throw new HttpError(409, "Nothing to undo on this card");
    }
    const result = await applyGoalSnapshot(admin, userId, after, before, {
      today: message.local_day ?? today,
      currentWeightKg: null,
    });
    if (result === "conflict") {
      throw new HttpError(
        409,
        "Your goals changed again since this card, so it can't be undone.",
      );
    }
    dependencies.refreshPlan?.();
    return [await updatePayload(admin, userId, message, { status: "undone" })];
  }
  throw new HttpError(400, "Unsupported decision for a goal change");
}

async function bioUpdateAction(
  admin: SupabaseClient,
  userId: string,
  message: CoachMessageRow,
  decision: CoachCardDecision,
  dependencies: CardActionDependencies,
): Promise<CoachMessageRow[]> {
  if (decision !== "undo") {
    throw new HttpError(400, "Bio changes can only be undone");
  }
  if (message.payload.status === "undone") return [message];
  const undoVersion = Number(message.payload.undo_version);
  const appliedVersion = Number(message.payload.memory_version);
  if (!Number.isInteger(undoVersion) || !Number.isInteger(appliedVersion)) {
    throw new HttpError(409, "This bio change can't be undone");
  }
  const { data: current, error } = await admin.from("coach_memory")
    .select("version")
    .eq("user_id", userId)
    .maybeSingle();
  if (error) throw error;
  const currentVersion = Number(
    (current as { version?: number } | null)?.version ?? 0,
  );
  if (currentVersion !== appliedVersion) {
    throw new HttpError(
      409,
      "The bio changed again since this card, so it can't be undone.",
    );
  }
  let sections = parseMemorySections({});
  if (undoVersion > 0) {
    const { data: revision, error: revisionError } = await admin
      .from("coach_memory_revisions")
      .select("sections")
      .eq("user_id", userId)
      .eq("version", undoVersion)
      .maybeSingle();
    if (revisionError) throw revisionError;
    if (!revision) throw new HttpError(409, "The earlier bio version is gone");
    sections = parseMemorySections(
      (revision as { sections: unknown }).sections,
    );
  }
  const saved = await saveCoachMemoryRpc(admin, {
    userId,
    expectedVersion: currentVersion,
    document: renderMemoryDocument(sections),
    sections: sections as unknown as Record<string, unknown>,
    source: "undo",
    changeSummary: `Undo of bio update to version ${appliedVersion}`,
    messageId: message.id,
  });
  if (saved.status !== "saved") {
    throw new HttpError(409, "The bio changed at the same time. Try again.");
  }
  dependencies.refreshPlan?.();
  return [
    await updatePayload(admin, userId, message, {
      status: "undone",
      restored_version: saved.version,
    }),
  ];
}

async function trainingPlanAction(
  admin: SupabaseClient,
  userId: string,
  planId: string,
  messages: CoachMessageRow[],
  decision: CoachCardDecision,
  dependencies: CardActionDependencies,
): Promise<CoachMessageRow[]> {
  if (decision === "activate" || decision === "apply") {
    const status = await activateTrainingPlanRpc(admin, userId, planId);
    if (status !== "activated" && status !== "already_active") {
      throw new HttpError(
        status === "not_found" ? 404 : 409,
        "That plan can't be activated anymore.",
      );
    }
    dependencies.refreshPlan?.();
    return await Promise.all(
      messages.map((message) =>
        updatePayload(admin, userId, message, { status: "active" })
      ),
    );
  }
  if (decision === "discard") {
    const status = await discardTrainingPlanDraftRpc(admin, userId, planId);
    if (status === "not_found") throw new HttpError(404, "That plan is gone");
    if (status !== "rejected") {
      throw new HttpError(
        409,
        "That plan is already active. Ask the coach to change it.",
      );
    }
    return await Promise.all(
      messages.map((message) =>
        updatePayload(admin, userId, message, { status: "rejected" })
      ),
    );
  }
  throw new HttpError(400, "Unsupported decision for a training plan");
}

/// "Ate it": logs the first recommended option as a text meal using the
/// card's own (server-recomputed) numbers.
export function snackMealDescription(
  payload: Record<string, unknown>,
): string | null {
  const options = Array.isArray(payload.options) ? payload.options : [];
  const option = options[0] as Record<string, unknown> | undefined;
  const items = Array.isArray(option?.items)
    ? option.items as Record<string, unknown>[]
    : [];
  if (!option || items.length === 0) return null;
  const parts = items.slice(0, 6).map((item) => {
    const name = [item.brand, item.name].filter((value) =>
      typeof value === "string" && value
    )
      .join(" ");
    return `${numeric(item.quantity) || 1} × ${name} (${
      String(item.serving ?? "1 serving")
    }; label: ${Math.round(numeric(item.calories_kcal))} kcal, ${
      Math.round(numeric(item.protein_g))
    } g protein, ${Math.round(numeric(item.carbs_g))} g carbs, ${
      Math.round(numeric(item.fat_g))
    } g fat)`;
  });
  return `${parts.join("; ")} from ${
    String(option.store_name ?? "a nearby store")
  }`;
}

async function nearbyAction(
  admin: SupabaseClient,
  userId: string,
  message: CoachMessageRow,
  decision: CoachCardDecision,
  dependencies: CardActionDependencies,
): Promise<CoachMessageRow[]> {
  if (decision === "discard") {
    if (message.payload.status === "dismissed") return [message];
    return [
      await updatePayload(admin, userId, message, { status: "dismissed" }),
    ];
  }
  if (decision !== "apply") {
    throw new HttpError(400, "Unsupported decision for a snack card");
  }
  if (typeof message.payload.entry_id === "string") return [message];
  const description = snackMealDescription(message.payload);
  if (!description || !dependencies.logMealText) {
    throw new HttpError(409, "There's nothing on this card to log");
  }
  const entryId = await dependencies.logMealText(description, message.id);
  return [
    await updatePayload(admin, userId, message, {
      status: "logged",
      entry_id: entryId,
    }),
  ];
}

export async function handleCardAction(
  admin: SupabaseClient,
  userId: string,
  action: CoachCardAction,
  dependencies: CardActionDependencies = {},
): Promise<CoachMessageRow[]> {
  const messages = await findCardMessages(admin, userId, action);
  if (action.kind === "training_plan") {
    const planId = typeof messages[0]?.payload.plan_id === "string"
      ? messages[0].payload.plan_id as string
      : action.id;
    return await trainingPlanAction(
      admin,
      userId,
      planId,
      messages,
      action.decision,
      dependencies,
    );
  }
  const message = messages[0];
  if (!message) throw new HttpError(404, "That card is gone");
  switch (action.kind) {
    case "goal_change":
      return await goalChangeAction(
        admin,
        userId,
        message,
        action.decision,
        dependencies,
      );
    case "bio_update":
      return await bioUpdateAction(
        admin,
        userId,
        message,
        action.decision,
        dependencies,
      );
    case "nearby":
      return await nearbyAction(
        admin,
        userId,
        message,
        action.decision,
        dependencies,
      );
  }
}

const KINDS: CoachCardActionKind[] = [
  "goal_change",
  "training_plan",
  "bio_update",
  "nearby",
];
const DECISIONS: CoachCardDecision[] = ["apply", "discard", "undo", "activate"];

export function parseCardAction(value: unknown): CoachCardAction {
  const object = value && typeof value === "object"
    ? value as Record<string, unknown>
    : {};
  const id = typeof object.id === "string"
    ? object.id.trim().toLowerCase()
    : "";
  if (
    !KINDS.includes(object.kind as CoachCardActionKind) ||
    !DECISIONS.includes(object.decision as CoachCardDecision) ||
    !/^[0-9a-f-]{36}$/u.test(id)
  ) {
    throw new HttpError(400, "Card action is invalid");
  }
  return {
    kind: object.kind as CoachCardActionKind,
    id,
    decision: object.decision as CoachCardDecision,
  };
}
